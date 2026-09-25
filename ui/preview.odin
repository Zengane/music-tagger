package musictagger

// What the previews need, made once and cached.
//
// A thumbnail (thumbs.odin) is enough for a tile. The preview panel and the
// big viewer want more, and each kind of file wants something different:
//
//   Large   a picture up to 2048 pixels, for images and a video's still.
//           ffmpeg.
//   Strip   twelve frames of a video side by side, for scrubbing a tile by
//           moving the pointer across it. ffmpeg.
//   Mesh    a GLB of any 3D model the window cannot load itself: STL, FBX,
//           Blockbench, MagicaVoxel... preview_job.py.
//   Pages   a PDF's pages as pictures. preview_job.py.
//   Text    the words of a .docx, .odt or .rtf. preview_job.py.
//
// All of them land in cache/<kind>/ under the same key as the thumbnails, so a
// file is only ever converted once. The work happens on one background thread,
// newest request first, so whatever was clicked last is what gets made next.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

Preview_Kind :: enum u8 { Large, Strip, Mesh, Pages, Text }

Asset_State :: enum u8 { Unknown, Pending, Ready, Failed }

STRIP_FRAMES :: 12
STRIP_W      :: 256
STRIP_H      :: 144
LARGE_EDGE   :: 2048
BIG_TEXTURES :: 10

@(private)
Asset :: struct {
	state:    Asset_State,
	error:    string, // owned; why it failed, in words for the panel
	duration: f32,    // a strip's clip length, learnt while making it
	pages:    int,    // a document's page count
}

@(private)
Asset_Job :: struct {
	key:   u64,
	kind:  Preview_Kind,
	src:   string, // owned
	out:   string, // owned
	video: bool,
}

@(private)
Asset_Done :: struct {
	key:      u64,
	kind:     Preview_Kind,
	ok:       bool,
	error:    string, // owned
	duration: f32,
	pages:    int,
}

@(private)
Big_Texture :: struct {
	path: string, // owned
	tex:  rl.Texture2D,
	used: u64,
}

@(private)
Previews :: struct {
	mutex:  sync.Mutex,
	cond:   sync.Cond,
	queue:  [dynamic]Asset_Job,
	done:   [dynamic]Asset_Done,
	worker: ^thread.Thread,
	quit:   bool,
	assets: map[u64]Asset, // asset_id(file key, kind)
	big:    [dynamic]Big_Texture,
	clock:  u64,
	loads:  int, // big textures loaded this frame
}

@(private)
previews: Previews

@(private)
asset_id :: proc(key: u64, kind: Preview_Kind) -> u64 { return key ~ (u64(kind) + 1) * 0x9E3779B97F4A7C15 }

track_key :: proc(t: ^Track) -> u64 { return hash_key(t.path, t.size, t.mtime) }

asset_path :: proc(t: ^Track, kind: Preview_Kind, allocator := context.temp_allocator) -> string {
	key := track_key(t)
	switch kind {
	case .Large: return join_path({cache_dir("large"),  fmt.tprintf("%016x.png", key)}, allocator)
	case .Strip: return join_path({cache_dir("strips"), fmt.tprintf("%016x.png", key)}, allocator)
	case .Mesh:  return join_path({cache_dir("meshes"), fmt.tprintf("%016x.glb", key)}, allocator)
	case .Pages: return join_path({cache_dir("pages"),  fmt.tprintf("%016x", key)}, allocator)
	case .Text:  return join_path({cache_dir("text"),   fmt.tprintf("%016x.txt", key)}, allocator)
	}
	return ""
}

// Where a PDF's page is, once drawn. Pages count from one.
page_path :: proc(t: ^Track, page: int) -> string {
	return join_path({asset_path(t, .Pages), fmt.tprintf("page-%03d.png", page)})
}

// Whether an asset is ready, asking for it if it has not been asked for yet.
// `error` says why, when it failed.
request_asset :: proc(t: ^Track, kind: Preview_Kind) -> (state: Asset_State, error: string) {
	id := asset_id(track_key(t), kind)
	a := previews.assets[id]
	switch a.state {
	case .Ready, .Pending: return a.state, ""
	case .Failed:          return .Failed, a.error
	case .Unknown:
	}

	out := asset_path(t, kind)
	done_marker := kind == .Pages ? join_path({out, "pages.json"}) : out
	if os.exists(done_marker) {
		a.state = .Ready
		if kind == .Pages { a.pages = read_page_count(done_marker) }
		previews.assets[id] = a
		return .Ready, ""
	}

	a.state = .Pending
	previews.assets[id] = a
	if previews.worker == nil {
		previews.quit = false
		previews.worker = thread.create_and_start(asset_worker)
	}
	sync.mutex_lock(&previews.mutex)
	append(&previews.queue, Asset_Job{
		key = track_key(t), kind = kind, src = strings.clone(t.path), out = strings.clone(out),
		video = t.kind == .Video,
	})
	sync.cond_signal(&previews.cond)
	sync.mutex_unlock(&previews.mutex)
	return .Pending, ""
}

asset_info :: proc(t: ^Track, kind: Preview_Kind) -> (duration: f32, pages: int) {
	a := previews.assets[asset_id(track_key(t), kind)]
	return a.duration, a.pages
}

@(private)
read_page_count :: proc(path: string) -> int {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return 0 }
	Info :: struct { total: int, written: int }
	info: Info
	if json.unmarshal(raw, &info, allocator = context.temp_allocator) != nil { return 0 }
	return info.written
}

// Called once a frame: takes in what the worker finished.
begin_preview_frame :: proc() {
	previews.loads = 0
	sync.mutex_lock(&previews.mutex)
	done := make([]Asset_Done, len(previews.done), context.temp_allocator)
	copy(done, previews.done[:])
	clear(&previews.done)
	sync.mutex_unlock(&previews.mutex)

	for d in done {
		id := asset_id(d.key, d.kind)
		a := previews.assets[id]
		if a.error != "" { delete(a.error) }
		a.state    = d.ok ? .Ready : .Failed
		a.error    = d.error
		a.duration = d.duration
		a.pages    = d.pages
		previews.assets[id] = a
		// A video's length comes free with its filmstrip.
		if d.kind == .Strip && d.duration > 0 {
			for &t in lib.tracks {
				if t.kind == .Video && t.duration <= 0 && track_key(&t) == d.key { t.duration = d.duration }
			}
		}
	}
}

// The texture for a picture on disk, from a small cache of big ones. Loads at
// most two a frame, so opening a long PDF does not stall the window.
big_texture :: proc(path: string) -> (rl.Texture2D, bool) {
	previews.clock += 1
	for &b in previews.big {
		if b.path == path { b.used = previews.clock; return b.tex, true }
	}
	if previews.loads >= 2 || !os.exists(path) { return {}, false }
	previews.loads += 1
	tex := rl.LoadTexture(strings.clone_to_cstring(path, context.temp_allocator))
	if tex.id == 0 { return {}, false }
	rl.GenTextureMipmaps(&tex)
	rl.SetTextureFilter(tex, .TRILINEAR)
	entry := Big_Texture{strings.clone(path), tex, previews.clock}
	if len(previews.big) < BIG_TEXTURES {
		append(&previews.big, entry)
	} else {
		oldest := 0
		for b, i in previews.big { if b.used < previews.big[oldest].used { oldest = i } }
		rl.UnloadTexture(previews.big[oldest].tex)
		delete(previews.big[oldest].path)
		previews.big[oldest] = entry
	}
	return tex, true
}

// Draws one frame of a video's filmstrip, `frac` of the way through, fitted in
// `r`. False until the strip exists (it is asked for here).
draw_filmstrip_frame :: proc(index: int, frac: f32, r: Rect) -> bool {
	t := &lib.tracks[index]
	if t.kind != .Video { return false }
	state, _ := request_asset(t, .Strip)
	if state != .Ready { return false }
	tex, ok := big_texture(asset_path(t, .Strip))
	if !ok { return false }
	frames := max(int(tex.width) / STRIP_W, 1)
	i := clamp(int(frac * f32(frames)), 0, frames - 1)
	src := rl.Rectangle{f32(i * STRIP_W), 0, STRIP_W, f32(tex.height)}
	s := min(r.width / STRIP_W, r.height / f32(tex.height))
	w, h := STRIP_W * s, f32(tex.height) * s
	rl.DrawTexturePro(tex, src, {r.x + (r.width - w) * 0.5, r.y + (r.height - h) * 0.5, w, h}, {}, 0, rl.WHITE)
	return true
}

// The biggest picture there is of a file: the large one when made, the
// thumbnail meanwhile.
best_picture :: proc(index: int) -> (rl.Texture2D, bool) {
	t := &lib.tracks[index]
	if t.kind == .Image || t.kind == .Video {
		if ffmpeg_can_thumb(t) {
			if state, _ := request_asset(t, .Large); state == .Ready {
				if tex, ok := big_texture(asset_path(t, .Large)); ok { return tex, true }
			}
		}
	}
	return thumbnail(index)
}

stop_previews :: proc() {
	if previews.worker == nil { return }
	sync.mutex_lock(&previews.mutex)
	previews.quit = true
	sync.cond_signal(&previews.cond)
	sync.mutex_unlock(&previews.mutex)
	thread.join(previews.worker)
	thread.destroy(previews.worker)
	previews.worker = nil
}

// The library changed: queued work is for files that may be gone, and the
// failures may not apply any more.
clear_previews :: proc() {
	sync.mutex_lock(&previews.mutex)
	for j in previews.queue { delete(j.src); delete(j.out) }
	clear(&previews.queue)
	sync.mutex_unlock(&previews.mutex)
	for _, a in previews.assets { if a.error != "" { delete(a.error) } }
	clear(&previews.assets)
}

// ── the worker ──────────────────────────────────────────────────────────────

@(private)
asset_worker :: proc() {
	for {
		sync.mutex_lock(&previews.mutex)
		for len(previews.queue) == 0 && !previews.quit { sync.cond_wait(&previews.cond, &previews.mutex) }
		if previews.quit { sync.mutex_unlock(&previews.mutex); return }
		job := pop(&previews.queue)
		sync.mutex_unlock(&previews.mutex)

		d := Asset_Done{key = job.key, kind = job.kind}
		switch job.kind {
		case .Large: d.ok = make_large(job.src, job.out, job.video)
		case .Strip: d.ok, d.duration = make_strip(job.src, job.out)
		case .Mesh, .Pages, .Text:
			d.ok, d.error, d.pages = run_preview_job(job)
		}
		if !d.ok && d.error == "" {
			d.error = strings.clone(ffmpeg_available() ? "could not be read" : "ffmpeg is not installed")
		}
		free_all(context.temp_allocator)

		sync.mutex_lock(&previews.mutex)
		append(&previews.done, d)
		sync.mutex_unlock(&previews.mutex)
		delete(job.src)
		delete(job.out)
	}
}

@(private)
make_large :: proc(src, dest: string, video: bool) -> bool {
	// Only ever shrinks: a small picture stays its own size.
	scale := fmt.tprintf("scale='min(iw,%d)':'min(ih,%d)':force_original_aspect_ratio=decrease:flags=lanczos",
	                     LARGE_EDGE, LARGE_EDGE)
	tmp := strings.concatenate({dest, ".tmp.png"}, context.temp_allocator)
	for attempt in 0 ..< (video ? 2 : 1) {
		args := make([dynamic]string, 0, 16, context.temp_allocator)
		append(&args, ffmpeg_exe(), "-v", "error", "-nostdin", "-y")
		if video && attempt == 0 { append(&args, "-ss", "1") }
		append(&args, "-i", src, "-frames:v", "1", "-vf", scale, "-f", "image2", "-vcodec", "png", tmp)
		_, code, started := run_capture(args[:], context.temp_allocator)
		if started && code == 0 && os.exists(tmp) {
			os.remove(dest)
			return os.rename(tmp, dest) == nil
		}
		os.remove(tmp)
	}
	return false
}

@(private)
make_strip :: proc(src, dest: string) -> (ok: bool, duration: f32) {
	duration = probe_duration(src)
	if duration <= 0 { return false, 0 }
	tmp := strings.concatenate({dest, ".tmp.png"}, context.temp_allocator)
	// Frames spread evenly through the clip, each padded to one size so the
	// strip is a row of equal cells.
	vf := fmt.tprintf("fps=%.6f,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black,tile=%dx1",
	                  f32(STRIP_FRAMES) / duration, STRIP_W, STRIP_H, STRIP_W, STRIP_H, STRIP_FRAMES)
	_, code, started := run_capture({
		ffmpeg_exe(), "-v", "error", "-nostdin", "-y", "-i", src, "-an", "-vf", vf,
		"-frames:v", "1", "-f", "image2", "-vcodec", "png", tmp,
	}, context.temp_allocator)
	if started && code == 0 && os.exists(tmp) {
		os.remove(dest)
		return os.rename(tmp, dest) == nil, duration
	}
	os.remove(tmp)
	return false, duration
}

@(private)
run_preview_job :: proc(job: Asset_Job) -> (ok: bool, error: string, pages: int) {
	py := python_exe()
	if !os.exists(py) {
		return false, strings.clone("The Python side is not set up yet; run setup to preview this."), 0
	}
	what: string
	switch job.kind {
	case .Mesh:  what = "mesh"
	case .Pages: what = "pages"
	case .Text:  what = "text"
	case .Large, .Strip:
	}
	out, _, started := run_capture({py, join_path({project_root(), "preview_job.py"}), what, job.src, job.out},
	                               context.temp_allocator)
	if !started { return false, strings.clone("could not start Python"), 0 }

	// The answer is the last line that is JSON.
	Reply :: struct { ok: bool, error: string, written: int }
	lines := strings.split_lines(string(out), context.temp_allocator)
	for i := len(lines) - 1; i >= 0; i -= 1 {
		line := strings.trim_space(lines[i])
		if !strings.has_prefix(line, "{") { continue }
		reply: Reply
		if json.unmarshal(transmute([]byte)line, &reply, allocator = context.temp_allocator) != nil { break }
		return reply.ok, strings.clone(reply.error), reply.written
	}
	return false, strings.clone("the preview job gave no answer"), 0
}
