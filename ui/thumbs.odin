package musictagger

// Pictures of pictures: thumbnails for images, video, 3D models and documents.
//
// A thumbnail is a small PNG in cache/thumbs, named by the same key as the
// waveform cache (`hash_key` over path, size and mtime). Two things write them:
//
//   this file   images and video, with ffmpeg, in the background, as soon as
//               a tile needs one. No Python, so browsing works before any
//               analysis has run.
//   media_job   everything it analyses, including 3D models and PDFs, which
//               ffmpeg cannot draw. It uses the same name, so the next time a
//               tile asks, the file is simply there.
//
// PNG and not JPEG because raylib is built without a JPEG decoder.
//
// Textures live on the GPU and are loaded on the drawing thread, a few per
// frame, into a cache that forgets the least recently drawn. A folder of ten
// thousand images never holds more than THUMB_TEXTURES of them.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

THUMB_EDGE      :: 320
THUMB_TEXTURES  :: 384
THUMB_LOADS_PER_FRAME :: 6

Thumb_State :: enum u8 { Unknown, Queued, Ready, Failed }

@(private)
Thumb_Job :: struct {
	index: int,
	epoch: int,
	path:  string, // owned
	out:   string, // owned
	video: bool,
}

@(private)
Thumb_Done :: struct { index: int, epoch: int, ok: bool }

@(private)
Thumb_Texture :: struct { index: int, tex: rl.Texture2D, used: u64 }

@(private)
Thumbs :: struct {
	mutex:   sync.Mutex,
	cond:    sync.Cond,
	queue:   [dynamic]Thumb_Job,
	done:    [dynamic]Thumb_Done,
	worker:  ^thread.Thread,
	quit:    bool,
	epoch:   int, // bumped whenever the library is replaced; stale work is dropped
	cache:   [dynamic]Thumb_Texture,
	clock:   u64,
	loads:   int, // this frame
	renders: int, // models and pages drawn into thumbnails this frame
}

@(private)
thumbs: Thumbs

thumb_file_for :: proc(t: ^Track, allocator := context.temp_allocator) -> string {
	return join_path({cache_dir("thumbs"), fmt.tprintf("%016x.png", hash_key(t.path, t.size, t.mtime))}, allocator)
}

// Whether a file kind has a picture at all.
has_thumbnail :: proc(t: ^Track) -> bool { return t.kind != .Audio }

// ffmpeg can draw these itself; the rest wait for the analysis.
@(private)
ffmpeg_can_thumb :: proc(t: ^Track) -> bool {
	switch t.kind {
	case .Image:
		switch t.ext {
		case ".svg", ".ai", ".eps", ".psd", ".heic", ".heif": return false
		}
		return true
	case .Video: return true
	case .Audio, .Model, .Document: return false
	}
	return false
}

// The texture for a track, if it is ready. Asks for one to be made if not.
thumbnail :: proc(index: int) -> (rl.Texture2D, bool) {
	if index < 0 || index >= len(lib.tracks) { return {}, false }
	t := &lib.tracks[index]
	if !has_thumbnail(t) { return {}, false }
	thumbs.clock += 1

	for &c in thumbs.cache {
		if c.index == index { c.used = thumbs.clock; return c.tex, true }
	}

	state := Thumb_State(t.thumb_state)
	if state == .Unknown || state == .Ready {
		path := thumb_file_for(t)
		if os.exists(path) {
			t.thumb_state = u8(Thumb_State.Ready)
			if thumbs.loads >= THUMB_LOADS_PER_FRAME { return {}, false }
			thumbs.loads += 1
			tex := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
			if tex.id == 0 { t.thumb_state = u8(Thumb_State.Failed); return {}, false }
			rl.SetTextureFilter(tex, .BILINEAR)
			remember_texture(index, tex)
			return tex, true
		}
		if state == .Ready { t.thumb_state = u8(Thumb_State.Unknown) }
		if ffmpeg_can_thumb(t) {
			queue_thumbnail(index)
		} else {
			// Models and PDFs are drawn here, from what the previews make.
			switch render_local_thumbnail(index, path) {
			case .Done:    // on disk now; loaded next frame
			case .Waiting: // the mesh or the pages are still being made
			case .Failed:  t.thumb_state = u8(Thumb_State.Failed)
			}
		}
	}
	return {}, false
}

@(private)
remember_texture :: proc(index: int, tex: rl.Texture2D) {
	if len(thumbs.cache) < THUMB_TEXTURES {
		append(&thumbs.cache, Thumb_Texture{index, tex, thumbs.clock})
		return
	}
	oldest := 0
	for c, i in thumbs.cache { if c.used < thumbs.cache[oldest].used { oldest = i } }
	rl.UnloadTexture(thumbs.cache[oldest].tex)
	thumbs.cache[oldest] = Thumb_Texture{index, tex, thumbs.clock}
}

// Called once per frame by the main loop.
begin_thumbnail_frame :: proc() {
	thumbs.loads = 0
	thumbs.renders = 0
	sync.mutex_lock(&thumbs.mutex)
	done := make([]Thumb_Done, len(thumbs.done), context.temp_allocator)
	copy(done, thumbs.done[:])
	clear(&thumbs.done)
	sync.mutex_unlock(&thumbs.mutex)
	for d in done {
		if d.epoch != thumbs.epoch || d.index >= len(lib.tracks) { continue }
		lib.tracks[d.index].thumb_state = u8(d.ok ? Thumb_State.Ready : Thumb_State.Failed)
	}
}

// A new picture is on disk (after an analysis): drop the old texture.
forget_thumbnail :: proc(index: int) {
	for c, i in thumbs.cache {
		if c.index == index {
			rl.UnloadTexture(c.tex)
			unordered_remove(&thumbs.cache, i)
			break
		}
	}
	if index >= 0 && index < len(lib.tracks) { lib.tracks[index].thumb_state = u8(Thumb_State.Unknown) }
}

// The library was replaced: every index means something else now.
clear_thumbnails :: proc() {
	for c in thumbs.cache { rl.UnloadTexture(c.tex) }
	clear(&thumbs.cache)
	sync.mutex_lock(&thumbs.mutex)
	thumbs.epoch += 1
	for j in thumbs.queue { delete(j.path); delete(j.out) }
	clear(&thumbs.queue)
	clear(&thumbs.done)
	sync.mutex_unlock(&thumbs.mutex)
}

@(private)
queue_thumbnail :: proc(index: int) {
	t := &lib.tracks[index]
	t.thumb_state = u8(Thumb_State.Queued)
	if thumbs.worker == nil {
		thumbs.quit = false
		thumbs.worker = thread.create_and_start(thumb_worker)
	}
	sync.mutex_lock(&thumbs.mutex)
	append(&thumbs.queue, Thumb_Job{
		index = index, epoch = thumbs.epoch,
		path = strings.clone(t.path), out = strings.clone(thumb_file_for(t)),
		video = t.kind == .Video,
	})
	sync.cond_signal(&thumbs.cond)
	sync.mutex_unlock(&thumbs.mutex)
}

stop_thumbnails :: proc() {
	if thumbs.worker == nil { return }
	sync.mutex_lock(&thumbs.mutex)
	thumbs.quit = true
	sync.cond_signal(&thumbs.cond)
	sync.mutex_unlock(&thumbs.mutex)
	thread.join(thumbs.worker)
	thread.destroy(thumbs.worker)
	thumbs.worker = nil
	for c in thumbs.cache { rl.UnloadTexture(c.tex) }
	clear(&thumbs.cache)
}

@(private)
thumb_worker :: proc() {
	for {
		sync.mutex_lock(&thumbs.mutex)
		for len(thumbs.queue) == 0 && !thumbs.quit { sync.cond_wait(&thumbs.cond, &thumbs.mutex) }
		if thumbs.quit { sync.mutex_unlock(&thumbs.mutex); return }
		// Newest first: the tiles asked for last are the ones on screen now.
		job := pop(&thumbs.queue)
		sync.mutex_unlock(&thumbs.mutex)

		ok := make_thumbnail(job.path, job.out, job.video)
		free_all(context.temp_allocator)

		sync.mutex_lock(&thumbs.mutex)
		append(&thumbs.done, Thumb_Done{job.index, job.epoch, ok})
		sync.mutex_unlock(&thumbs.mutex)
		delete(job.path)
		delete(job.out)
	}
}

// One frame, shrunk to fit THUMB_EDGE, written as PNG. For video a frame a
// couple of seconds in is tried first, past any fade from black, then the
// first frame for clips shorter than that.
make_thumbnail :: proc(src, dest: string, video: bool) -> bool {
	scale := fmt.tprintf("scale=%d:%d:force_original_aspect_ratio=decrease", THUMB_EDGE, THUMB_EDGE)
	tmp := strings.concatenate({dest, ".tmp.png"}, context.temp_allocator)
	attempts := video ? 2 : 1
	for attempt in 0 ..< attempts {
		args := make([dynamic]string, 0, 16, context.temp_allocator)
		append(&args, ffmpeg_exe(), "-v", "error", "-nostdin", "-y")
		if video && attempt == 0 { append(&args, "-ss", "2") }
		append(&args, "-i", src, "-frames:v", "1", "-vf", scale, "-f", "image2", "-vcodec", "png", tmp)
		_, code, started := run_capture(args[:], context.temp_allocator)
		if started && code == 0 && os.exists(tmp) {
			if info, err := os.stat(tmp, context.temp_allocator); err == nil && info.size > 0 {
				os.remove(dest)
				return os.rename(tmp, dest) == nil
			}
		}
		os.remove(tmp)
	}
	return false
}

// Draws a texture fitted inside `r`, centred, keeping its aspect ratio.
draw_texture_fit :: proc(tex: rl.Texture2D, r: Rect, tint := rl.WHITE) -> Rect {
	if tex.width <= 0 || tex.height <= 0 { return r }
	s := min(r.width / f32(tex.width), r.height / f32(tex.height))
	w, h := f32(tex.width) * s, f32(tex.height) * s
	dst := rect(r.x + (r.width - w) * 0.5, r.y + (r.height - h) * 0.5, w, h)
	rl.DrawTexturePro(tex, {0, 0, f32(tex.width), f32(tex.height)}, {dst.x, dst.y, dst.width, dst.height},
	                  {0, 0}, 0, tint)
	return dst
}

// A short word for what a file is, for tiles and rows with no picture yet.
kind_label :: proc(t: ^Track) -> string {
	switch t.kind {
	case .Audio:    return t.is_sfx ? "SFX" : "AUDIO"
	case .Image:    return "IMAGE"
	case .Video:    return "VIDEO"
	case .Model:    return "3D"
	case .Document: return "DOC"
	}
	return ""
}

// Word-wrapped text that stops at `bottom`, ending in an ellipsis if it had to.
// Returns the y below the last line drawn.
draw_wrapped_block :: proc(text: string, x, y, w, bottom: f32, size: f32, col: rl.Color) -> f32 {
	line_height := line_h(size) + px(2)
	cy := y
	b := strings.builder_make(context.temp_allocator)
	words := strings.fields(text, context.temp_allocator)
	for word, i in words {
		trial := strings.to_string(b)
		candidate := len(trial) == 0 ? word : strings.concatenate({trial, " ", word}, context.temp_allocator)
		if text_w(.Auto, strings.clone_to_cstring(candidate, context.temp_allocator), size) <= w || len(trial) == 0 {
			strings.builder_reset(&b)
			strings.write_string(&b, candidate)
			continue
		}
		if cy + line_height * 2 > bottom {
			// Last line that fits: say there is more.
			draw_text(.Auto, elide_right(strings.concatenate({trial, " …"}, context.temp_allocator), w, size), x, cy, size, col)
			return cy + line_height
		}
		draw_text(.Auto, strings.clone_to_cstring(trial, context.temp_allocator), x, cy, size, col)
		cy += line_height
		strings.builder_reset(&b)
		strings.write_string(&b, word)
		_ = i
	}
	if rest := strings.to_string(b); len(rest) > 0 && cy + line_height <= bottom + line_height {
		draw_text(.Auto, strings.clone_to_cstring(rest, context.temp_allocator), x, cy, size, col)
		cy += line_height
	}
	return cy
}

