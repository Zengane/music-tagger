package musictagger

// The card that follows the cursor during a drag.
//
// Without one, Windows shows only a small copy arrow and nothing about what is
// being carried. The shell will draw a bitmap for us if it is given one: create
// `CLSID_DragDropHelper`, hand it a bitmap and the data object, and it stores
// the picture in that object and paints it for the length of the drag.
//
// The bitmap is a DIB drawn by hand rather than through GDI text calls. The
// only thing on it besides a rounded panel is the track name, and drawing text
// means fonts, device contexts and a second set of failure modes; instead the
// text is rendered by the same font atlas the rest of the interface uses, read
// back off the GPU, and composited in. It is the app's own type, which is also
// how it ends up looking like it belongs to the app.
//
// Everything here is best-effort. If any step fails the drag still runs — it
// just falls back to the plain cursor it had before.

import "core:strings"
import win32 "core:sys/windows"
import rl "vendor:raylib"

@(private) DRAG_CARD_W :: 260
@(private) DRAG_CARD_H :: 44

@(private)
SHDRAGIMAGE :: struct {
	sizeDragImage: win32.SIZE,
	ptOffset:      win32.POINT,
	hbmpDragImage: win32.HBITMAP,
	crColorKey:    win32.COLORREF,
}

@(private)
IDragSourceHelper_Vtbl :: struct {
	QueryInterface:       proc "system" (this: rawptr, riid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT,
	AddRef:               proc "system" (this: rawptr) -> win32.ULONG,
	Release:              proc "system" (this: rawptr) -> win32.ULONG,
	InitializeFromBitmap: proc "system" (this: rawptr, img: ^SHDRAGIMAGE, data: rawptr) -> win32.HRESULT,
	InitializeFromWindow: proc "system" (this: rawptr, hwnd: win32.HWND, pt: ^win32.POINT, data: rawptr) -> win32.HRESULT,
}

@(private)
IDragSourceHelper :: struct {
	vtbl: ^IDragSourceHelper_Vtbl,
}

@(private)
CLSID_DragDropHelper := win32.GUID{
	0x4657278A, 0x411B, 0x11D2, {0x83, 0x9A, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0},
}
@(private)
IID_IDragSourceHelper := win32.GUID{
	0xDE5BF786, 0x477A, 0x11D2, {0x83, 0x9D, 0x00, 0xC0, 0x4F, 0xD9, 0x18, 0xD0},
}

@(private)
BITMAPINFOHEADER :: struct {
	biSize:          win32.DWORD,
	biWidth:         win32.LONG,
	biHeight:        win32.LONG,
	biPlanes:        win32.WORD,
	biBitCount:      win32.WORD,
	biCompression:   win32.DWORD,
	biSizeImage:     win32.DWORD,
	biXPelsPerMeter: win32.LONG,
	biYPelsPerMeter: win32.LONG,
	biClrUsed:       win32.DWORD,
	biClrImportant:  win32.DWORD,
}

@(private)
Drag_Image_Api :: struct {
	co_create:     proc "system" (clsid: ^win32.GUID, outer: rawptr, ctx: win32.DWORD, iid: ^win32.GUID, out: ^rawptr) -> win32.HRESULT,
	create_dib:    proc "system" (dc: rawptr, info: ^BITMAPINFOHEADER, usage: win32.UINT, bits: ^rawptr, section: rawptr, offset: win32.DWORD) -> win32.HBITMAP,
	delete_object: proc "system" (obj: rawptr) -> win32.BOOL,
	ready:         bool,
	tried:         bool,
}

@(private)
drag_api: Drag_Image_Api

@(private)
load_drag_image_api :: proc() -> bool {
	if drag_api.tried { return drag_api.ready }
	drag_api.tried = true

	ole32 := win32.LoadLibraryW(win32.utf8_to_wstring("ole32.dll", context.temp_allocator))
	gdi32 := win32.LoadLibraryW(win32.utf8_to_wstring("gdi32.dll", context.temp_allocator))
	if ole32 == nil || gdi32 == nil { return false }

	co_create := win32.GetProcAddress(ole32, "CoCreateInstance")
	create    := win32.GetProcAddress(gdi32, "CreateDIBSection")
	del       := win32.GetProcAddress(gdi32, "DeleteObject")
	if co_create == nil || create == nil || del == nil { return false }

	drag_api.co_create     = auto_cast co_create
	drag_api.create_dib    = auto_cast create
	drag_api.delete_object = auto_cast del
	drag_api.ready = true
	return true
}

// Renders the card with raylib and reads the pixels back.
//
// Drawing it the same way as the rest of the interface means it matches: same
// panel colour, same font, same rounded corner. Rendering to a texture and
// reading it back costs one small download from the GPU, once per drag.
@(private)
render_drag_card :: proc(label: string, count: int) -> (rl.Image, bool) {
	w := i32(px(DRAG_CARD_W))
	h := i32(px(DRAG_CARD_H))

	target := rl.LoadRenderTexture(w, h)
	if target.id == 0 { return {}, false }
	defer rl.UnloadRenderTexture(target)

	rl.BeginTextureMode(target)
	rl.ClearBackground({0, 0, 0, 0})

	card := Rect{0, 0, f32(w), f32(h)}
	fill_round(card, rl.Color{28, 32, 39, 245}, 6)
	outline_round(card, ACCENT, 6)

	// A little waveform mark, so the card reads as audio at a glance.
	bar_x := px(12)
	for i in 0 ..< 7 {
		bar_h := px(f32(6 + (i * 5) % 14))
		rl.DrawRectangleRec({bar_x + f32(i) * px(4), f32(h) * 0.5 - bar_h * 0.5, px(2), bar_h},
		                    ACCENT)
	}

	text_x := bar_x + px(38)
	max_w := f32(w) - text_x - px(12)
	draw_text(.Auto, elide_right(display_text(label), max_w, FS_SMALL),
	          text_x, f32(h) * 0.5 - px(13), FS_SMALL, TEXT)

	sub: cstring = count > 1 ? fmt_count(count) : "1 file"
	draw_text(.Regular, sub, text_x, f32(h) * 0.5 + px(1), FS_SMALL, TEXT_FAINT)

	rl.EndTextureMode()

	image := rl.LoadImageFromTexture(target.texture)
	// A render texture is stored bottom-up relative to what we drew.
	rl.ImageFlipVertical(&image)
	return image, image.data != nil
}

@(private)
fmt_count :: proc(n: int) -> cstring {
	@(static) buf: [32]byte
	s := strings.builder_from_bytes(buf[:])
	strings.write_int(&s, n)
	strings.write_string(&s, " files")
	return strings.unsafe_string_to_cstring(strings.to_string(s))
}

// Attaches a drag image to `data_object`. Best-effort: a failure anywhere just
// means the drag runs with the plain cursor.
attach_drag_image :: proc(data_object: rawptr, label: string, count: int) {
	if !load_drag_image_api() { return }

	image, drawn := render_drag_card(label, count)
	if !drawn { return }
	defer rl.UnloadImage(image)

	// raylib gives RGBA; a DIB wants BGRA, premultiplied so the shell can
	// alpha-blend it.
	rl.ImageFormat(&image, .UNCOMPRESSED_R8G8B8A8)
	pixels := ([^]u8)(image.data)

	header := BITMAPINFOHEADER{
		biSize      = size_of(BITMAPINFOHEADER),
		biWidth     = win32.LONG(image.width),
		biHeight    = win32.LONG(image.height), // positive: bottom-up, as the shell expects
		biPlanes    = 1,
		biBitCount  = 32,
		biCompression = 0, // BI_RGB
	}

	bits: rawptr
	bitmap := drag_api.create_dib(nil, &header, 0, &bits, nil, 0)
	if bitmap == nil || bits == nil { return }

	dst := ([^]u8)(bits)
	width  := int(image.width)
	height := int(image.height)
	for y in 0 ..< height {
		// Bottom-up destination, top-down source.
		src_row := (height - 1 - y) * width * 4
		dst_row := y * width * 4
		for x in 0 ..< width {
			r := pixels[src_row + x * 4 + 0]
			g := pixels[src_row + x * 4 + 1]
			b := pixels[src_row + x * 4 + 2]
			a := pixels[src_row + x * 4 + 3]
			// Premultiplied, or the shell draws a bright halo around the card.
			dst[dst_row + x * 4 + 0] = u8(int(b) * int(a) / 255)
			dst[dst_row + x * 4 + 1] = u8(int(g) * int(a) / 255)
			dst[dst_row + x * 4 + 2] = u8(int(r) * int(a) / 255)
			dst[dst_row + x * 4 + 3] = a
		}
	}

	helper_ptr: rawptr
	hr := drag_api.co_create(&CLSID_DragDropHelper, nil, CLSCTX_INPROC,
	                         &IID_IDragSourceHelper, &helper_ptr)
	if hr != S_OK_HR || helper_ptr == nil {
		drag_api.delete_object(rawptr(bitmap))
		return
	}
	helper := (^IDragSourceHelper)(helper_ptr)

	img := SHDRAGIMAGE{
		sizeDragImage = {win32.LONG(image.width), win32.LONG(image.height)},
		// Held just below and right of the pointer, clear of the copy arrow.
		ptOffset      = {win32.LONG(-px(18)), win32.LONG(f32(image.height) * 0.5)},
		hbmpDragImage = bitmap,
		crColorKey    = 0xFFFFFFFF, // CLR_INVALID: use the alpha channel
	}

	// The helper takes the bitmap when it succeeds, and leaves it when it does
	// not.
	if helper.vtbl.InitializeFromBitmap(helper, &img, data_object) != S_OK_HR {
		drag_api.delete_object(rawptr(bitmap))
	}
	helper.vtbl.Release(helper)
}
