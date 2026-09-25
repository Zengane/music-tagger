package musictagger

// Thumbnails the window draws itself.
//
// ffmpeg cannot picture a 3D model or a PDF. The analysis makes thumbnails for
// both, but only once it has run; before then these tiles would be blank. So
// once the preview pipeline has a mesh (or a PDF's first page), the model is
// rendered here, off screen, from a three-quarter view with the same light as
// the viewer, and saved under the thumbnail's name. One a frame, so a folder
// of models fills in steadily without the window stalling.

import "core:strings"
import rl "vendor:raylib"

Local_Thumb :: enum { Done, Waiting, Failed }

render_local_thumbnail :: proc(index: int, dest: string) -> Local_Thumb {
	t := &lib.tracks[index]
	#partial switch t.kind {
	case .Model:    return render_model_thumbnail(t, dest)
	case .Document: return t.ext == ".pdf" ? render_page_thumbnail(t, dest) : .Failed
	}
	return .Failed
}

@(private)
render_page_thumbnail :: proc(t: ^Track, dest: string) -> Local_Thumb {
	state, _ := request_asset(t, .Pages)
	switch state {
	case .Pending, .Unknown: return .Waiting
	case .Failed:            return .Failed
	case .Ready:
	}
	if thumbs.renders >= 1 { return .Waiting }
	thumbs.renders += 1
	img := rl.LoadImage(strings.clone_to_cstring(page_path(t, 1), context.temp_allocator))
	if img.data == nil { return .Failed }
	defer rl.UnloadImage(img)
	s := min(f32(THUMB_EDGE) / f32(img.width), f32(THUMB_EDGE) / f32(img.height), 1)
	rl.ImageResize(&img, max(i32(f32(img.width) * s), 1), max(i32(f32(img.height) * s), 1))
	return rl.ExportImage(img, strings.clone_to_cstring(dest, context.temp_allocator)) ? .Done : .Failed
}

@(private)
render_model_thumbnail :: proc(t: ^Track, dest: string) -> Local_Thumb {
	path := ""
	if raylib_loads_model(t.ext) && is_ascii(t.path) {
		path = t.path
	} else {
		state, _ := request_asset(t, .Mesh)
		switch state {
		case .Pending, .Unknown: return .Waiting
		case .Failed:            return .Failed
		case .Ready:             path = asset_path(t, .Mesh)
		}
	}
	if thumbs.renders >= 1 { return .Waiting }
	thumbs.renders += 1

	m := rl.LoadModel(strings.clone_to_cstring(path, context.temp_allocator))
	if m.meshCount == 0 || m.meshes == nil {
		rl.UnloadModel(m)
		return .Failed
	}
	defer rl.UnloadModel(m)
	if shader, ok := model_shader(); ok {
		for i in 0 ..< int(m.materialCount) { m.materials[i].shader = shader }
	}
	if t.ext == ".bbmodel" || t.ext == ".vox" {
		for i in 0 ..< int(m.materialCount) {
			rl.SetTextureFilter(m.materials[i].maps[rl.MaterialMapIndex.ALBEDO].texture, .POINT)
		}
	}

	box := rl.GetModelBoundingBox(m)
	centre := (box.min + box.max) * 0.5
	radius := max(rl.Vector3Length(box.max - box.min) * 0.5, 0.001)
	// Three-quarter view from a little above: yaw 35°, pitch 22°.
	dir := rl.Vector3{0.528, 0.375, 0.762}
	eye := centre + dir * (radius * 3.0)
	cam := rl.Camera3D{position = eye, target = centre, up = {0, 1, 0}, fovy = 40, projection = .PERSPECTIVE}
	if shader, ok := model_shader(); ok {
		pos := eye
		rl.SetShaderValue(shader, rl.GetShaderLocation(shader, "viewPos"), &pos, .VEC3)
	}

	rt := rl.LoadRenderTexture(THUMB_EDGE, THUMB_EDGE)
	defer rl.UnloadRenderTexture(rt)
	if ui.clip_count > 0 { rl.EndScissorMode() }
	rl.BeginTextureMode(rt)
	rl.ClearBackground(WAVE_BG)
	rl.BeginMode3D(cam)
	rl.DrawModel(m, {}, 1, rl.WHITE)
	rl.EndMode3D()
	rl.EndTextureMode()
	if ui.clip_count > 0 {
		c := ui.clips[ui.clip_count - 1]
		rl.BeginScissorMode(i32(c.x), i32(c.y), i32(max(c.width, 0)), i32(max(c.height, 0)))
	}

	img := rl.LoadImageFromTexture(rt.texture)
	defer rl.UnloadImage(img)
	rl.ImageFlipVertical(&img)
	return rl.ExportImage(img, strings.clone_to_cstring(dest, context.temp_allocator)) ? .Done : .Failed
}
