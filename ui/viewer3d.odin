package musictagger

// Looking at a 3D model.
//
// raylib loads glTF, OBJ and MagicaVoxel itself; every other format is turned
// into a GLB once by preview_job.py (see preview.odin) and loaded from the
// cache. The model is drawn into an off-screen texture with a simple light,
// so it reads as a solid rather than a flat silhouette, over a floor grid that
// gives it a sense of size.
//
// Drag to turn it, the wheel to come closer, right-drag (or Shift-drag) to
// move it. Double-click puts the camera back.

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

@(private)
Model_View :: struct {
	index:    int,
	key:      u64,
	loaded:   bool,
	model:    rl.Model,
	from_cache: bool, // loaded from the converted GLB rather than the file
	center:   rl.Vector3,
	radius:   f32,
	floor_y:  f32,
	tris:     int,
	verts:    int,

	yaw, pitch, dist: f32,
	pan:      rl.Vector3,
	wire:     bool,
	spin:     bool,
	dragging: int, // 0 none, 1 turn, 2 move

	rt:       rl.RenderTexture2D,
	rt_w, rt_h: i32,
	shader:   rl.Shader,
	shader_ok: bool,
}

@(private)
model_view: Model_View = {index = -1}

// raylib's own loaders.
@(private)
raylib_loads_model :: proc(ext: string) -> bool {
	switch ext {
	case ".glb", ".gltf", ".obj", ".vox", ".iqm", ".m3d": return true
	}
	return false
}

MODEL_VS :: `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragNormal;
out vec3 fragPos;
void main() {
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragNormal = vec3(matNormal * vec4(vertexNormal, 0.0));
    fragPos = vec3(matModel * vec4(vertexPosition, 1.0));
    gl_Position = mvp * vec4(vertexPosition, 1.0);
}`

// Smooth normals when the file has them, the face's own when it does not,
// turned towards the viewer for the back of a one-sided surface. A key light,
// a fill from below and a little ambient: enough to read the shape.
MODEL_FS :: `#version 330
in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
in vec3 fragPos;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec3 viewPos;
out vec4 finalColor;
void main() {
    vec4 base = texture(texture0, fragTexCoord) * colDiffuse * fragColor;
    if (base.a < 0.1) discard;
    vec3 n = fragNormal;
    if (dot(n, n) < 1e-6) n = cross(dFdx(fragPos), dFdy(fragPos));
    n = normalize(n);
    vec3 v = normalize(viewPos - fragPos);
    if (dot(n, v) < 0.0) n = -n;
    vec3 key = normalize(vec3(0.45, 0.85, 0.35));
    vec3 fill = normalize(vec3(-0.6, -0.2, -0.5));
    float d = max(dot(n, key), 0.0) * 0.75 + max(dot(n, fill), 0.0) * 0.18 + 0.28;
    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0) * 0.18;
    finalColor = vec4(base.rgb * d + rim, base.a);
}`

@(private)
model_shader :: proc() -> (rl.Shader, bool) {
	if !model_view.shader_ok {
		model_view.shader = rl.LoadShaderFromMemory(MODEL_VS, MODEL_FS)
		model_view.shader_ok = rl.IsShaderValid(model_view.shader)
	}
	return model_view.shader, model_view.shader_ok
}

@(private)
unload_model_view :: proc() {
	if model_view.loaded { rl.UnloadModel(model_view.model) }
	model_view.loaded = false
	model_view.index = -1
}

// Makes sure the model for `index` is loaded. Returns what to say instead
// when it is not (yet).
@(private)
ensure_model :: proc(index: int) -> (ok: bool, message: string) {
	t := &lib.tracks[index]
	key := track_key(t)
	if model_view.loaded && model_view.key == key { return true, "" }
	if model_view.loaded && model_view.key != key { unload_model_view() }

	path := ""
	from_cache := false
	if raylib_loads_model(t.ext) && is_ascii(t.path) {
		path = t.path
	} else {
		// Converted once, then read from the cache. raylib opens files by name
		// through the C library, which on Windows cannot open a path with
		// characters outside the system code page, so those go this way too.
		state, err := request_asset(t, .Mesh)
		switch state {
		case .Ready:
			path = asset_path(t, .Mesh)
			from_cache = true
		case .Pending, .Unknown:
			return false, "Preparing the model…"
		case .Failed:
			return false, err != "" ? err : "This model could not be opened."
		}
	}

	m := rl.LoadModel(strings.clone_to_cstring(path, context.temp_allocator))
	if m.meshCount == 0 || m.meshes == nil {
		rl.UnloadModel(m)
		if !from_cache && raylib_loads_model(t.ext) {
			// raylib could not read it; trimesh often can.
			if state, err := request_asset(t, .Mesh); state == .Failed { return false, err }
			return false, "Preparing the model…"
		}
		return false, "This model has nothing to draw."
	}

	model_view = {
		index = index, key = key, loaded = true, model = m, from_cache = from_cache,
		rt = model_view.rt, rt_w = model_view.rt_w, rt_h = model_view.rt_h,
		shader = model_view.shader, shader_ok = model_view.shader_ok,
		wire = model_view.wire, spin = model_view.spin,
	}
	box := rl.GetModelBoundingBox(m)
	model_view.center  = (box.min + box.max) * 0.5
	model_view.radius  = max(rl.Vector3Length(box.max - box.min) * 0.5, 0.001)
	model_view.floor_y = box.min.y
	for i in 0 ..< int(m.meshCount) {
		model_view.tris  += int(m.meshes[i].triangleCount)
		model_view.verts += int(m.meshes[i].vertexCount)
	}
	reset_model_camera()

	if shader, sok := model_shader(); sok {
		for i in 0 ..< int(m.materialCount) { m.materials[i].shader = shader }
	}
	// Blockbench and voxel art are pixel art: keep the pixels square.
	if t.ext == ".bbmodel" || t.ext == ".vox" {
		for i in 0 ..< int(m.materialCount) {
			rl.SetTextureFilter(m.materials[i].maps[rl.MaterialMapIndex.ALBEDO].texture, .POINT)
		}
	}
	return true, ""
}

reset_model_camera :: proc() {
	model_view.yaw   = 35
	model_view.pitch = 22
	model_view.dist  = 3.2
	model_view.pan   = {}
}

@(private)
is_ascii :: proc(s: string) -> bool {
	for i in 0 ..< len(s) { if s[i] >= 0x80 { return false } }
	return true
}

// Draws the model in `r`. With `interactive`, the pointer turns and moves it.
draw_model_view :: proc(r: Rect, index: int, interactive: bool) {
	fill_round(r, WAVE_BG, 4)
	ok, message := ensure_model(index)
	if !ok {
		draw_centred_message(r, message)
		return
	}
	mv := &model_view

	// Input.
	if interactive {
		over := hovered(r)
		if over && ui.clicked {
			shift := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
			mv.dragging = shift ? 2 : 1
			ui.captured = rawptr(mv)
		}
		if over && rl.IsMouseButtonPressed(.RIGHT) {
			mv.dragging = 2
			ui.captured = rawptr(mv)
		}
		if ui.captured == rawptr(mv) {
			d := rl.GetMouseDelta()
			if mv.dragging == 1 && rl.IsMouseButtonDown(.LEFT) {
				mv.yaw   -= d.x * 0.4
				mv.pitch  = clamp(mv.pitch + d.y * 0.4, -85, 85)
				mv.spin   = false
			} else if mv.dragging == 2 && (rl.IsMouseButtonDown(.RIGHT) || rl.IsMouseButtonDown(.LEFT)) {
				// Along the screen's own axes, scaled so the model follows the
				// pointer at any distance.
				scale := mv.radius * mv.dist * 1.2 / max(r.height, 1)
				yaw := math.to_radians(mv.yaw)
				right := rl.Vector3{math.cos(yaw), 0, -math.sin(yaw)}
				mv.pan -= right * (d.x * scale)
				mv.pan.y += d.y * scale
			} else {
				mv.dragging = 0
				ui.captured = nil
			}
		}
		if over && ui.wheel != 0 {
			mv.dist = clamp(mv.dist * math.pow(0.88, ui.wheel), 0.4, 12)
			ui.wheel = 0
		}
		if over && rl.IsMouseButtonPressed(.LEFT) && double_clicked(rawptr(mv)) { reset_model_camera() }
		if over { ui.hover_cursor = mv.dragging == 2 ? .RESIZE_ALL : .DEFAULT }
	}
	if mv.spin { mv.yaw += rl.GetFrameTime() * 20 }

	// The picture, rendered at the size it is shown.
	scale := rl.GetWindowScaleDPI().x
	w := i32(r.width * scale)
	h := i32(r.height * scale)
	if w < 8 || h < 8 { return }
	if mv.rt_w != w || mv.rt_h != h {
		if mv.rt.id != 0 { rl.UnloadRenderTexture(mv.rt) }
		mv.rt = rl.LoadRenderTexture(w, h)
		mv.rt_w, mv.rt_h = w, h
	}

	yaw   := math.to_radians(mv.yaw)
	pitch := math.to_radians(mv.pitch)
	dist  := mv.radius * mv.dist
	target := mv.center + mv.pan
	eye := target + rl.Vector3{math.cos(pitch) * math.sin(yaw), math.sin(pitch), math.cos(pitch) * math.cos(yaw)} * dist
	cam := rl.Camera3D{position = eye, target = target, up = {0, 1, 0}, fovy = 40, projection = .PERSPECTIVE}

	if shader, sok := model_shader(); sok {
		loc := rl.GetShaderLocation(shader, "viewPos")
		pos := eye
		rl.SetShaderValue(shader, loc, &pos, .VEC3)
	}

	// The scissor is in screen space and would cut the off-screen picture too.
	if ui.clip_count > 0 { rl.EndScissorMode() }
	rl.BeginTextureMode(mv.rt)
	rl.ClearBackground(WAVE_BG)
	rl.BeginMode3D(cam)
	draw_floor_grid(mv.center.x, mv.floor_y, mv.center.z, mv.radius)
	if mv.wire {
		rl.DrawModelWires(mv.model, {}, 1, rl.Color{150, 200, 255, 255})
	} else {
		rl.DrawModel(mv.model, {}, 1, rl.WHITE)
	}
	rl.EndMode3D()
	rl.EndTextureMode()
	if ui.clip_count > 0 {
		c := ui.clips[ui.clip_count - 1]
		rl.BeginScissorMode(i32(c.x), i32(c.y), i32(max(c.width, 0)), i32(max(c.height, 0)))
	}

	// Render textures are upside down.
	rl.DrawTexturePro(mv.rt.texture, {0, 0, f32(w), -f32(h)}, {r.x, r.y, r.width, r.height}, {}, 0, rl.WHITE)
}

@(private)
draw_floor_grid :: proc(cx, y, cz, radius: f32) {
	step := grid_step(radius)
	n := 10
	col := rl.Color{48, 56, 68, 255}
	for i in -n ..= n {
		o := f32(i) * step
		rl.DrawLine3D({cx + o, y, cz - f32(n) * step}, {cx + o, y, cz + f32(n) * step}, col)
		rl.DrawLine3D({cx - f32(n) * step, y, cz + o}, {cx + f32(n) * step, y, cz + o}, col)
	}
}

// A round number of units, so the grid means something: 1, 2, 5, 10...
@(private)
grid_step :: proc(radius: f32) -> f32 {
	raw := radius / 4
	p := math.pow(10, math.floor(math.log10(max(raw, 1e-6))))
	for m in ([]f32{1, 2, 5, 10}) { if raw <= m * p { return m * p } }
	return 10 * p
}

// The controls under a model: wireframe, turntable, reset, and its size.
draw_model_toolbar :: proc(r: Rect, index: int) {
	mv := &model_view
	x := r.x
	if !(mv.loaded && mv.index == index) { return }
	b := rect(x, r.y, px(28), r.height)
	tip(b, "Wireframe")
	if toggle_icon(b, .Grid, mv.wire) { mv.wire = !mv.wire }
	x += px(32)
	b = rect(x, r.y, px(28), r.height)
	tip(b, "Turntable")
	if toggle_icon(b, .Rotate, mv.spin) { mv.spin = !mv.spin }
	x += px(32)
	b = rect(x, r.y, px(28), r.height)
	tip(b, "Reset the camera (or double-click the model)")
	if icon_button(b, .Refresh) { reset_model_camera() }
	x += px(38)
	info := fmt.ctprintf("%s triangles", thousands(mv.tris))
	draw_text_mid(.Regular, info, x, r.y, r.height, FS_SMALL, TEXT_FAINT)
}

thousands :: proc(n: int) -> string {
	if n < 1000 { return fmt.tprintf("%d", n) }
	if n < 1_000_000 { return fmt.tprintf("%.1fk", f32(n) / 1000) }
	return fmt.tprintf("%.1fM", f32(n) / 1_000_000)
}

draw_centred_message :: proc(r: Rect, message: string) {
	lines := wrap_text(message, min(r.width - px(32), px(420)), FS_SMALL)
	h := line_h(FS_SMALL) + px(4)
	y := r.y + (r.height - h * f32(len(lines))) * 0.5
	for line in lines {
		label := strings.clone_to_cstring(line, context.temp_allocator)
		lw := text_w(.Auto, label, FS_SMALL)
		draw_text(.Auto, label, r.x + (r.width - lw) * 0.5, y, FS_SMALL, TEXT_FAINT)
		y += h
	}
}

// Splits text into lines no wider than `width`, at spaces, keeping the
// paragraph breaks it already has.
wrap_text :: proc(text: string, width: f32, size: f32) -> []string {
	out := make([dynamic]string, 0, 8, context.temp_allocator)
	for para in strings.split_lines(text, context.temp_allocator) {
		words := strings.fields(para, context.temp_allocator)
		if len(words) == 0 { append(&out, ""); continue }
		line := words[0]
		for word in words[1:] {
			candidate := strings.concatenate({line, " ", word}, context.temp_allocator)
			if text_w(.Auto, strings.clone_to_cstring(candidate, context.temp_allocator), size) > width {
				append(&out, line)
				line = word
			} else {
				line = candidate
			}
		}
		append(&out, line)
	}
	return out[:]
}

// True on the second press at the same place within the double-click time.
double_clicked :: proc(id: rawptr) -> bool {
	@(static) last_id: rawptr
	@(static) last_time: f64
	now := rl.GetTime()
	hit := last_id == id && now - last_time < 0.4
	last_id, last_time = id, hit ? 0 : now
	return hit
}
