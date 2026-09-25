package musictagger

// Playing video.
//
// ffmpeg decodes the picture on a background thread, straight to RGBA frames
// down a pipe, at the size the preview needs rather than the file's own. The
// sound is the video's audio track, converted once to a cached WAV (like an
// .m4a is) and played by the ordinary player, so the dock's transport, the
// volume, the speed and the waveform all work on a video exactly as they do on
// a song. When there is sound, it is the clock the picture follows; a silent
// clip keeps its own.
//
// Seeking restarts ffmpeg at the new time. That is cheaper than it sounds:
// ffmpeg jumps to the nearest keyframe and decodes forward, which for any
// ordinary clip is a few frames.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

VIDEO_MAX_W :: 1280
VIDEO_MAX_H :: 720
VIDEO_MAX_FPS :: 30

@(private)
Video :: struct {
	active:   bool,
	index:    int,
	path:     string, // owned
	key:      u64,

	// Learnt by the decoder thread from ffprobe, then fixed.
	probed:   bool,
	failed:   bool,
	w, h:     int,
	fps:      f32,
	duration: f32,
	has_audio: bool,

	// The clock, when there is no sound to follow.
	playing:  bool,
	clock_at:   f32, // media time at clock_wall
	clock_wall: f64,

	decoder:  ^thread.Thread,
	mutex:    sync.Mutex,
	quit:     bool,
	seek:     f32,
	seek_pending: bool,
	frame:    []u8, // the newest decoded frame, guarded by mutex
	frame_new: bool,
	frame_time: f32,

	tex:      rl.Texture2D,
	has_tex:  bool,
	shown:    int, // frames uploaded; none yet means show the still instead

	// The clock as the main thread last saw it, for the decoder thread. raylib's
	// audio is not to be asked from another thread.
	pub_time:    f32,
	pub_wall:    f64,
	pub_playing: bool,
	pub_speed:   f32,

	// The sound, converted in the background.
	audio_thread: ^thread.Thread,
	audio_done:   bool, // set by the audio thread
	audio_path:   string,
	audio_loaded: bool,
}

@(private)
video: Video

video_active :: proc() -> bool { return video.active }

// Starts showing (and, when `play`, playing) a video.
video_open :: proc(index: int, play: bool) {
	video_close()
	t := &lib.tracks[index]
	video.active   = true
	video.index    = index
	video.path     = strings.clone(t.path)
	video.key      = track_key(t)
	video.playing  = play
	video.clock_at = 0
	video.clock_wall = rl.GetTime()
	video.quit     = false
	video.pub_playing = play
	video.pub_wall    = rl.GetTime()
	video.pub_speed   = player.speed
	video.decoder   = thread.create_and_start(video_decoder)

	video.audio_path = strings.clone(join_path({cache_dir("preview"), fmt.tprintf("%016x.wav", video.key)}))
	video.audio_thread = thread.create_and_start(video_audio_worker)
}

video_close :: proc() {
	if !video.active && video.decoder == nil { return }
	sync.mutex_lock(&video.mutex)
	video.quit = true
	sync.mutex_unlock(&video.mutex)
	if video.decoder != nil {
		thread.join(video.decoder)
		thread.destroy(video.decoder)
	}
	if video.audio_thread != nil {
		// A conversion in progress runs to the end; it is cached for next time.
		thread.join(video.audio_thread)
		thread.destroy(video.audio_thread)
	}
	if video.has_tex { rl.UnloadTexture(video.tex) }
	delete(video.frame)
	delete(video.path)
	delete(video.audio_path)
	video = {}
}

// Where the video is, in seconds.
video_time :: proc() -> f32 {
	if video.audio_loaded { return rl.GetMusicTimePlayed(player.music) }
	if !video.playing { return video.clock_at }
	return video.clock_at + f32(rl.GetTime() - video.clock_wall) * player.speed
}

video_toggle :: proc() {
	if !video.active { return }
	if video.playing {
		video.clock_at = video_time()
		video.playing = false
		if video.audio_loaded { rl.PauseMusicStream(player.music) }
	} else {
		if video.duration > 0 && video_time() >= video.duration - 0.05 { video_seek(0) }
		video.clock_wall = rl.GetTime()
		video.playing = true
		if video.audio_loaded { rl.ResumeMusicStream(player.music) }
	}
	player.playing = video.playing
}

video_seek :: proc(seconds: f32) {
	if !video.active { return }
	target := clamp(seconds, 0, max(video.duration - 0.04, 0))
	video.clock_at   = target
	video.clock_wall = rl.GetTime()
	if video.audio_loaded { rl.SeekMusicStream(player.music, target) }
	sync.mutex_lock(&video.mutex)
	video.seek = target
	video.seek_pending = true
	video.pub_time = target
	video.pub_wall = rl.GetTime()
	sync.mutex_unlock(&video.mutex)
}

// Once a frame, on the main thread: a new picture to the GPU, the sound in
// once it is ready, and what happens at the end.
video_update :: proc() {
	if !video.active { return }

	sync.mutex_lock(&video.mutex)
	if video.probed && !video.has_tex && video.w > 0 {
		img := rl.GenImageColor(i32(video.w), i32(video.h), rl.BLACK)
		video.tex = rl.LoadTextureFromImage(img)
		rl.UnloadImage(img)
		rl.SetTextureFilter(video.tex, .BILINEAR)
		video.has_tex = true
	}
	if video.frame_new && video.has_tex && len(video.frame) == video.w * video.h * 4 {
		rl.UpdateTexture(video.tex, raw_data(video.frame))
		video.frame_new = false
		video.shown += 1
	}
	probed := video.probed
	video.pub_time    = video_time()
	video.pub_wall    = rl.GetTime()
	video.pub_playing = video.playing
	video.pub_speed   = player.speed
	sync.mutex_unlock(&video.mutex)

	if probed && player.duration <= 0 { player.duration = video.duration }
	if probed && video.duration > 0 && lib.tracks[video.index].duration <= 0 {
		lib.tracks[video.index].duration = video.duration
	}

	// The sound, the moment it exists, picking up where the picture is.
	if video.audio_done && !video.audio_loaded && video.has_audio && os.exists(video.audio_path) {
		if data, err := os.read_entire_file(video.audio_path, context.allocator); err == nil {
			player.music = rl.LoadMusicStreamFromMemory(".wav", raw_data(data), i32(len(data)))
			if rl.IsMusicValid(player.music) {
				player.backing = data
				player.loaded  = true
				player.music.looping = false
				at := video_time()
				rl.SetMusicVolume(player.music, player.muted ? 0 : player.volume)
				rl.SetMusicPitch(player.music, player.speed)
				rl.PlayMusicStream(player.music)
				rl.SeekMusicStream(player.music, at)
				if !video.playing { rl.PauseMusicStream(player.music) }
				video.audio_loaded = true
			} else {
				delete(data)
			}
		}
	}

	// The end.
	if video.playing && video.duration > 0 && video_time() >= video.duration - 0.03 {
		if player.loop {
			video_seek(0)
		} else {
			video.clock_at = video.duration
			video.playing  = false
			player.playing = false
			if video.audio_loaded { rl.PauseMusicStream(player.music) }
		}
	}
}

// The current picture, once there is one. Until the first frame arrives the
// still is better than black.
video_texture :: proc(index: int) -> (rl.Texture2D, bool) {
	if !video.active || video.index != index || !video.has_tex || video.shown == 0 { return {}, false }
	return video.tex, true
}

// Whether the video could not be opened at all.
video_failed :: proc(index: int) -> bool {
	return video.active && video.index == index && video.failed
}

// The decoder's idea of now, from what the main thread last published.
@(private)
decoder_clock :: proc() -> f32 {
	sync.mutex_lock(&video.mutex)
	defer sync.mutex_unlock(&video.mutex)
	if !video.pub_playing { return video.pub_time }
	return video.pub_time + f32(rl.GetTime() - video.pub_wall) * max(video.pub_speed, 0.01)
}

// ── the decoder thread ──────────────────────────────────────────────────────

@(private)
video_probe :: proc(path: string) -> (w, h: int, fps, duration: f32, has_audio, ok: bool) {
	out, code, ran := run_capture({
		ffprobe_exe(), "-v", "error", "-show_entries", "stream=codec_type,width,height,avg_frame_rate:format=duration",
		"-of", "default=noprint_wrappers=1", path,
	}, context.temp_allocator)
	if !ran || code != 0 { return }
	for line in strings.split_lines(string(out), context.temp_allocator) {
		eq := strings.index_byte(line, '=')
		if eq < 0 { continue }
		k, v := line[:eq], strings.trim_space(line[eq + 1:])
		switch k {
		case "codec_type": if v == "audio" { has_audio = true }
		case "width":  if n, parsed := strconv.parse_int(v); parsed && w == 0 { w = n }
		case "height": if n, parsed := strconv.parse_int(v); parsed && h == 0 { h = n }
		case "avg_frame_rate":
			if slash := strings.index_byte(v, '/'); slash > 0 && fps == 0 {
				a, _ := strconv.parse_f32(v[:slash])
				b, _ := strconv.parse_f32(v[slash + 1:])
				if b > 0 && a > 0 { fps = a / b }
			}
		case "duration": if d, parsed := strconv.parse_f32(v); parsed { duration = d }
		}
	}
	ok = w > 0 && h > 0
	return
}

@(private)
video_decoder :: proc() {
	w, h, fps, duration, has_audio, ok := video_probe(video.path)
	free_all(context.temp_allocator)
	if !ok {
		sync.mutex_lock(&video.mutex)
		video.failed = true
		video.probed = true
		sync.mutex_unlock(&video.mutex)
		return
	}
	// Fitted in the preview size, even numbers for the scaler.
	s := min(f32(VIDEO_MAX_W) / f32(w), f32(VIDEO_MAX_H) / f32(h), 1)
	dw := max(int(f32(w) * s) &~ 1, 2)
	dh := max(int(f32(h) * s) &~ 1, 2)
	rate := fps > 0 ? min(fps, VIDEO_MAX_FPS) : 25

	sync.mutex_lock(&video.mutex)
	video.w, video.h = dw, dh
	video.fps = rate
	video.duration = duration
	video.has_audio = has_audio
	video.frame = make([]u8, dw * dh * 4)
	video.probed = true
	sync.mutex_unlock(&video.mutex)

	buf := make([]u8, dw * dh * 4)
	defer delete(buf)
	start: f32 = 0

	outer: for {
		stream, started := stream_start({
			ffmpeg_exe(), "-v", "quiet", "-nostats", "-nostdin", "-ss", fmt.tprintf("%.3f", start),
			"-i", video.path, "-an", "-sn", "-vf", fmt.tprintf("scale=%d:%d,fps=%.3f", dw, dh, rate),
			"-pix_fmt", "rgba", "-f", "rawvideo", "-",
		})
		free_all(context.temp_allocator)
		if !started {
			sync.mutex_lock(&video.mutex)
			video.failed = true
			sync.mutex_unlock(&video.mutex)
			return
		}

		frame_i := 0
		for {
			// Stop or jump?
			sync.mutex_lock(&video.mutex)
			quit := video.quit
			jump := video.seek_pending
			if jump { start = video.seek; video.seek_pending = false }
			sync.mutex_unlock(&video.mutex)
			if quit { stream_kill(&stream); return }
			if jump { stream_kill(&stream); continue outer }

			// One whole frame.
			filled := 0
			eof := false
			for filled < len(buf) {
				n, done := stream_read_wait(&stream, buf[filled:])
				if n > 0 { filled += n }
				if done && n == 0 { eof = true; break }
			}
			if eof {
				stream_close(&stream)
				// Wait at the end for a seek back, or to be closed.
				for {
					sync.mutex_lock(&video.mutex)
					q, j := video.quit, video.seek_pending
					sync.mutex_unlock(&video.mutex)
					if q { return }
					if j { continue outer }
					time.sleep(15 * time.Millisecond)
				}
			}

			at := start + f32(frame_i) / rate
			frame_i += 1

			// Hold it until it is due. The first frame after a jump is shown at
			// once, so a paused video still shows where it was moved to.
			for frame_i > 1 {
				sync.mutex_lock(&video.mutex)
				q, j := video.quit, video.seek_pending
				sync.mutex_unlock(&video.mutex)
				if q || j { break }
				if at <= decoder_clock() + 0.01 { break }
				time.sleep(4 * time.Millisecond)
			}
			// Far behind (a slow disk, a huge file): skip it to catch up.
			if frame_i > 1 && at < decoder_clock() - 0.25 { continue }

			sync.mutex_lock(&video.mutex)
			copy(video.frame, buf)
			video.frame_new  = true
			video.frame_time = at
			sync.mutex_unlock(&video.mutex)
		}
	}
}

// Converts the sound once, into the same cache the player uses for .m4a.
@(private)
video_audio_worker :: proc() {
	defer { video.audio_done = true }
	if os.exists(video.audio_path) { return }
	tmp := strings.concatenate({video.audio_path, ".tmp.wav"}, context.temp_allocator)
	_, code, ran := run_capture({
		ffmpeg_exe(), "-v", "error", "-nostdin", "-y", "-i", video.path, "-vn", "-acodec", "pcm_s16le", tmp,
	}, context.temp_allocator)
	if ran && code == 0 && os.exists(tmp) {
		if info, err := os.stat(tmp, context.temp_allocator); err == nil && info.size > 64 {
			os.rename(tmp, video.audio_path)
		}
	}
	os.remove(tmp)
	free_all(context.temp_allocator)
}
