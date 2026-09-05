package musictagger

// The mark.
//
// Five bars rising to a centre that is a different colour. It says the two
// things the program is about at once: this is audio, and the moment that
// matters has been found. That amber bar is the hit point, which is the thing
// the app measures and the thing an editor lines a cut up with.
//
// It is drawn from geometry rather than loaded from a file, so there is one
// definition and it is sharp at every size. The window icon is rendered at
// startup and the `.ico` for the executable comes out of the same procedure —
// `MusicTagger.exe --make-icon` writes it, and build.bat calls that.
//
// Everything is in fractions of the canvas, so the shape holds together at 16
// pixels as well as at 256. At 16 the bars are two pixels wide and still read
// as a waveform, which is the size that decides whether a mark works.

import "core:fmt"
import "core:os"
import rl "vendor:raylib"

LOGO_BG     :: rl.Color{ 17,  21,  27, 255}
LOGO_BAR    :: rl.Color{ 76, 194, 255, 255}
LOGO_HIT    :: rl.Color{255, 190,  72, 255}

// Bar heights as a fraction of the canvas, centre bar last so it draws on top.
// Symmetric, rising to the middle: a shape, not a random waveform.
@(private)
LOGO_BARS := [5]f32{0.30, 0.54, 0.86, 0.54, 0.30}

// Renders the mark at `size` square, with transparent corners.
render_logo :: proc(size: i32) -> rl.Image {
	img := rl.GenImageColor(size, size, rl.Color{0, 0, 0, 0})
	s := f32(size)

	// The rounded ground. Below about 20 pixels the rounding is a pixel or two
	// and reads as noise, so it is squared off instead.
	radius := s * 0.22
	if size < 20 { radius = 0 }
	rounded_square(&img, {0, 0, s, s}, radius, LOGO_BG)

	// Five bars across the middle sixty per cent of the width.
	span   := s * 0.62
	left   := (s - span) * 0.5
	bar_w  := max(span / 9, 1)
	gap    := (span - bar_w * 5) / 4
	centre := s * 0.5

	for height, i in LOGO_BARS {
		h := s * height * 0.62
		x := left + f32(i) * (bar_w + gap)
		col := i == 2 ? LOGO_HIT : LOGO_BAR

		// Rounded ends, but only when there are pixels to spare for them.
		bar := rl.Rectangle{x, centre - h * 0.5, bar_w, h}
		if bar_w >= 4 {
			rounded_square(&img, bar, bar_w * 0.5, col)
		} else {
			rl.ImageDrawRectangleRec(&img, bar, col)
		}
	}
	return img
}

// A filled rectangle with rounded corners, drawn into an image.
//
// raylib draws rounded rectangles to the screen but not into an image, so the
// corners are done here: inside the corner circles, or outside the corner
// boxes entirely.
@(private)
rounded_square :: proc(img: ^rl.Image, r: rl.Rectangle, radius: f32, col: rl.Color) {
	rad := min(radius, min(r.width, r.height) * 0.5)
	if rad <= 0.5 {
		rl.ImageDrawRectangleRec(img, r, col)
		return
	}

	// The straight parts first.
	rl.ImageDrawRectangleRec(img, {r.x + rad, r.y, r.width - rad * 2, r.height}, col)
	rl.ImageDrawRectangleRec(img, {r.x, r.y + rad, rad, r.height - rad * 2}, col)
	rl.ImageDrawRectangleRec(img, {r.x + r.width - rad, r.y + rad, rad, r.height - rad * 2}, col)

	// Then the four corners.
	rl.ImageDrawCircleV(img, {r.x + rad, r.y + rad}, i32(rad), col)
	rl.ImageDrawCircleV(img, {r.x + r.width - rad, r.y + rad}, i32(rad), col)
	rl.ImageDrawCircleV(img, {r.x + rad, r.y + r.height - rad}, i32(rad), col)
	rl.ImageDrawCircleV(img, {r.x + r.width - rad, r.y + r.height - rad}, i32(rad), col)
}

// ── the window icon ─────────────────────────────────────────────────────────

set_window_icon :: proc() {
	sizes := [?]i32{16, 32, 48, 64, 128, 256}
	images := make([]rl.Image, len(sizes), context.temp_allocator)
	for size, i in sizes { images[i] = render_logo(size) }

	rl.SetWindowIcons(raw_data(images), i32(len(images)))
	for &img in images { rl.UnloadImage(img) }
}

// ── the executable icon ─────────────────────────────────────────────────────

// Writes a Windows .ico holding the mark at six sizes.
//
// The container is a header, one directory entry per image, and the image data
// after them. Every entry here is a PNG, which Windows has accepted since
// Vista and which keeps the file small and the alpha exact.
write_ico :: proc(path: string) -> bool {
	sizes := [?]i32{16, 32, 48, 64, 128, 256}

	Blob :: struct { data: []byte, size: i32 }
	blobs := make([]Blob, len(sizes), context.temp_allocator)

	for size, i in sizes {
		img := render_logo(size)
		defer rl.UnloadImage(img)

		length: i32
		raw := rl.ExportImageToMemory(img, ".png", &length)
		if raw == nil || length <= 0 { return false }
		defer rl.MemFree(raw)

		// Copied out: raylib's buffer is freed at the end of this iteration.
		copy_bytes := make([]byte, int(length), context.temp_allocator)
		src := ([^]u8)(raw)
		for j in 0 ..< int(length) { copy_bytes[j] = src[j] }
		blobs[i] = Blob{data = copy_bytes, size = size}
	}

	HEADER  :: 6
	ENTRY   :: 16
	offset := HEADER + ENTRY * len(blobs)

	out: [dynamic]byte
	out.allocator = context.temp_allocator

	put16 :: proc(out: ^[dynamic]byte, v: int) {
		append(out, u8(v & 0xFF), u8((v >> 8) & 0xFF))
	}
	put32 :: proc(out: ^[dynamic]byte, v: int) {
		append(out, u8(v & 0xFF), u8((v >> 8) & 0xFF), u8((v >> 16) & 0xFF), u8((v >> 24) & 0xFF))
	}

	put16(&out, 0) // reserved
	put16(&out, 1) // 1 = icon
	put16(&out, len(blobs))

	for blob in blobs {
		// 256 is written as zero: the field is one byte and 256 does not fit.
		append(&out, blob.size >= 256 ? 0 : u8(blob.size)) // width
		append(&out, blob.size >= 256 ? 0 : u8(blob.size)) // height
		append(&out, 0) // colours in palette
		append(&out, 0) // reserved
		put16(&out, 1)  // colour planes
		put16(&out, 32) // bits per pixel
		put32(&out, len(blob.data))
		put32(&out, offset)
		offset += len(blob.data)
	}
	for blob in blobs { append(&out, ..blob.data) }

	return os.write_entire_file(path, out[:]) == nil
}

// `--make-icon [path]`: renders the mark and writes the .ico the build embeds.
run_make_icon :: proc(path: string) -> int {
	// A window is needed because the image routines live in raylib, but it
	// never has to appear.
	rl.SetConfigFlags({.WINDOW_HIDDEN})
	rl.InitWindow(64, 64, "icon")
	defer rl.CloseWindow()

	dest := path == "" ? join_path({project_root(), "MusicTagger.ico"}, context.temp_allocator) : path
	if !write_ico(dest) {
		fmt.printf("could not write %s\n", dest)
		return 1
	}
	fmt.printf("wrote %s\n", dest)
	return 0
}
