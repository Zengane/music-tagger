package musictagger

// Small Windows-only pieces that have a counterpart in platform_posix.odin.

import "core:fmt"

// Opens Explorer with the file selected. `/select,` needs the path as one
// argument, quoted, which the command-line builder already handles.
reveal_in_file_manager :: proc(path: string) {
	s, ok := stream_start({"explorer.exe", fmt.tprintf("/select,%s", path)})
	if !ok {
		toast("could not open Explorer")
		return
	}
	// Explorer returns immediately and leaves the window to its own process.
	stream_close(&s)
}
