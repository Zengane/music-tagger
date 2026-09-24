package musictagger

// Throwing a file away, and forgetting it.
//
// Going through a soundtrack means deciding you do not want two thirds of it,
// and that is only a comfortable thing to do if a mistake is recoverable. So
// nothing is really deleted: the file goes to the recycle bin, where Windows
// has already built the undo.
//
// The sidecar goes with it. Leaving one behind means a folder slowly fills with
// tag files for music that is not there any more, and the next scan has to
// wonder what they are.

import "core:os"
import "core:strings"
import win32 "core:sys/windows"

// SHFileOperation's flags and codes.
@(private) FO_DELETE          :: u32(0x0003)
@(private) FOF_ALLOWUNDO      :: u16(0x0040)
@(private) FOF_NOCONFIRMATION :: u16(0x0010)
@(private) FOF_SILENT         :: u16(0x0004)
@(private) FOF_NOERRORUI      :: u16(0x0400)

@(private)
SHFILEOPSTRUCTW :: struct {
	hwnd:                  win32.HWND,
	wFunc:                 u32,
	pFrom:                 win32.wstring,
	pTo:                   win32.wstring,
	fFlags:                u16,
	fAnyOperationsAborted: win32.BOOL,
	hNameMappings:         rawptr,
	lpszProgressTitle:     win32.wstring,
}

@(private)
Recycle :: struct {
	file_operation: proc "system" (op: ^SHFILEOPSTRUCTW) -> win32.INT,
	loaded: bool,
	ready:  bool,
}

@(private)
recycle: Recycle

// shell32 at run time, like everything else here: linking it collides with
// raylib's own `CloseWindow`.
@(private)
load_recycle :: proc() {
	if recycle.loaded { return }
	recycle.loaded = true

	shell32 := win32.LoadLibraryW(win32.utf8_to_wstring("shell32.dll", context.temp_allocator))
	if shell32 == nil { return }
	f := win32.GetProcAddress(shell32, "SHFileOperationW")
	if f == nil { return }

	recycle.file_operation = auto_cast f
	recycle.ready = true
}

// Sends one file, and its sidecar, to the recycle bin.
//
// The path list SHFileOperation takes is double-null-terminated — one null
// after each name and another after the last. Getting that wrong reads past
// the end of the buffer, so the terminator is built by hand rather than left
// to a string conversion.
recycle_file :: proc(path: string) -> bool {
	load_recycle()
	if !recycle.ready || path == "" { return false }

	names := make([dynamic]string, 0, 2, context.temp_allocator)
	append(&names, path)
	if sidecar := sidecar_path(path); sidecar != "" && os.exists(sidecar) {
		append(&names, sidecar)
	}

	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for name in names {
		strings.write_string(&b, name)
		strings.write_byte(&b, 0)
	}
	strings.write_byte(&b, 0)

	// Converted by hand: the usual helper stops at the first null, and this
	// list is nothing but nulls.
	wide := win32.utf8_to_utf16(strings.to_string(b), context.temp_allocator)
	if len(wide) == 0 { return false }

	op := SHFILEOPSTRUCTW{
		wFunc  = FO_DELETE,
		pFrom  = win32.wstring(raw_data(wide)),
		fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI,
	}
	return recycle.file_operation(&op) == 0
}
