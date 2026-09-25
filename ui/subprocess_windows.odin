package musictagger

// Running ffmpeg and Python without a console window appearing.
//
// `core:os`'s process_start does not pass CREATE_NO_WINDOW to CreateProcessW,
// so every child would flash a black terminal on top of the app — the same
// bug the Python version had to fix. CreateProcessW is called directly here so
// the flag can be set.
//
// Two shapes are offered:
//   run_capture  — start it, read all of stdout, wait. For ffprobe and short
//                  ffmpeg jobs whose whole output is wanted.
//   Stream       — start it and read stdout in pieces across frames, so a long
//                  job (decoding a track, tagging a library) reports progress
//                  while it runs and never blocks the window.

import "core:strings"
import win32 "core:sys/windows"

@(private) BELOW_NORMAL_PRIORITY_CLASS :: 0x00004000

Stream :: struct {
	process:    win32.HANDLE,
	read_pipe:  win32.HANDLE,
	write_pipe: win32.HANDLE, // the child's stdin, when started `with_stdin`
	running:    bool,
	exit_code:  u32,
}

@(private)
build_command_line :: proc(args: []string, allocator := context.temp_allocator) -> string {
	// Quote any argument holding a space. Paths in this library contain
	// spaces, brackets and full-width punctuation, so nothing may go bare.
	b := strings.builder_make(allocator)
	for arg, i in args {
		if i > 0 { strings.write_byte(&b, ' ') }
		needs_quotes := len(arg) == 0 || strings.contains_any(arg, " \t\"")
		if !needs_quotes {
			strings.write_string(&b, arg)
			continue
		}
		strings.write_byte(&b, '"')
		backslashes := 0
		for c in transmute([]byte)arg {
			switch c {
			case '\\':
				backslashes += 1
			case '"':
				// Escape the run of backslashes, then the quote itself.
				for _ in 0 ..< backslashes * 2 + 1 { strings.write_byte(&b, '\\') }
				backslashes = 0
				strings.write_byte(&b, '"')
			case:
				for _ in 0 ..< backslashes { strings.write_byte(&b, '\\') }
				backslashes = 0
				strings.write_byte(&b, c)
			}
		}
		for _ in 0 ..< backslashes * 2 { strings.write_byte(&b, '\\') }
		strings.write_byte(&b, '"')
	}
	return strings.to_string(b)
}

// Starts `args[0]` with stdout on a pipe and no console window.
// stderr is discarded: these tools are chatty and the app reports failure by
// the exit code and by having no usable output.
stream_start :: proc(args: []string, working_dir := "", with_stdin := false) -> (s: Stream, ok: bool) {
	sa := win32.SECURITY_ATTRIBUTES{
		nLength        = size_of(win32.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	read_pipe, write_pipe: win32.HANDLE
	if !win32.CreatePipe(&read_pipe, &write_pipe, &sa, 0) { return {}, false }

	// The child inherits only the write end; keeping the read end private is
	// what lets ReadFile see end-of-file when the child exits.
	win32.SetHandleInformation(read_pipe, win32.HANDLE_FLAG_INHERIT, 0)

	cmd_line := build_command_line(args)
	cmd_w := win32.utf8_to_wstring(cmd_line, context.temp_allocator)
	if cmd_w == nil {
		win32.CloseHandle(read_pipe)
		win32.CloseHandle(write_pipe)
		return {}, false
	}
	dir_w: win32.LPCWSTR
	if working_dir != "" {
		dir_w = win32.utf8_to_wstring(working_dir, context.temp_allocator)
	}

	// With STARTF_USESTDHANDLES every handle must be real. A NULL stdin is not
	// "no input" — it is an invalid handle, and a child that reads or even
	// probes stdin can hang on it. NUL is the correct empty input.
	// A caller that wants to talk to the child gets a pipe instead.
	null_in, stdin_write: win32.HANDLE
	if with_stdin {
		if !win32.CreatePipe(&null_in, &stdin_write, &sa, 0) {
			win32.CloseHandle(read_pipe)
			win32.CloseHandle(write_pipe)
			return {}, false
		}
		win32.SetHandleInformation(stdin_write, win32.HANDLE_FLAG_INHERIT, 0)
	} else {
		null_in = win32.CreateFileW(
			win32.utf8_to_wstring("NUL", context.temp_allocator),
			win32.GENERIC_READ,
			win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
			&sa, win32.OPEN_EXISTING, 0, nil,
		)
	}
	defer if null_in != win32.INVALID_HANDLE_VALUE && null_in != nil { win32.CloseHandle(null_in) }

	startup := win32.STARTUPINFOW{
		cb         = size_of(win32.STARTUPINFOW),
		dwFlags    = win32.STARTF_USESTDHANDLES,
		hStdOutput = write_pipe,
		hStdError  = write_pipe,
		hStdInput  = null_in,
	}
	info: win32.PROCESS_INFORMATION
	spawned := win32.CreateProcessW(
		nil, cmd_w, nil, nil, true,
		// Below normal: analysis, waveforms and thumbnails all run while you
		// work, and the desktop and the program you edit in come first.
		win32.CREATE_NO_WINDOW | win32.CREATE_UNICODE_ENVIRONMENT | BELOW_NORMAL_PRIORITY_CLASS,
		nil, dir_w, &startup, &info,
	)

	// The parent must drop the write end or the pipe never reaches EOF.
	win32.CloseHandle(write_pipe)

	if !spawned {
		win32.CloseHandle(read_pipe)
		if stdin_write != nil { win32.CloseHandle(stdin_write) }
		return {}, false
	}
	win32.CloseHandle(info.hThread)
	return Stream{process = info.hProcess, read_pipe = read_pipe, write_pipe = stdin_write, running = true}, true
}

// Reads whatever is already in the pipe, up to `len(buf)`. Never blocks:
// returns 0 when there is nothing waiting yet, and sets `eof` once the child
// has closed its end.
stream_read :: proc(s: ^Stream, buf: []byte) -> (n: int, eof: bool) {
	if !s.running { return 0, true }

	available: win32.DWORD
	if !win32.PeekNamedPipe(s.read_pipe, nil, 0, nil, &available, nil) {
		return 0, true // the child closed the pipe
	}
	if available == 0 { return 0, false }

	want := min(u32(len(buf)), u32(available))
	read: win32.DWORD
	if !win32.ReadFile(s.read_pipe, raw_data(buf), want, &read, nil) {
		return 0, true
	}
	return int(read), false
}

// Blocks until the child writes something or closes the pipe.
//
// `run_capture` used to poll `stream_read` and `Sleep(1)` between attempts.
// Windows rounds a 1 ms sleep up to the timer resolution — about 15 ms — and a
// decode delivers megabytes through a 64 KB pipe, so a job that ffmpeg
// finishes in 0.12 s was taking 15 s of almost pure sleeping. Waveform
// generation ran at four files a minute because of it.
//
// A blocking read has none of that: the OS wakes the thread when there is
// something to read. The polling version is still what the frame loop uses,
// because that one must never block.
stream_read_wait :: proc(s: ^Stream, buf: []byte) -> (n: int, eof: bool) {
	if !s.running { return 0, true }
	read: win32.DWORD
	if !win32.ReadFile(s.read_pipe, raw_data(buf), u32(len(buf)), &read, nil) {
		return 0, true // the child closed its end: ERROR_BROKEN_PIPE
	}
	if read == 0 { return 0, true }
	return int(read), false
}

// True once the child has exited. Fills in `exit_code`.
stream_finished :: proc(s: ^Stream) -> bool {
	if !s.running { return true }
	if win32.WaitForSingleObject(s.process, 0) != win32.WAIT_OBJECT_0 { return false }
	code: win32.DWORD
	win32.GetExitCodeProcess(s.process, &code)
	s.exit_code = u32(code)
	return true
}

// Writes to the child's stdin. Only for streams started `with_stdin`.
stream_write :: proc(s: ^Stream, data: []byte) -> bool {
	if !s.running || s.write_pipe == nil { return false }
	sent := 0
	for sent < len(data) {
		wrote: win32.DWORD
		if !win32.WriteFile(s.write_pipe, raw_data(data[sent:]), u32(len(data) - sent), &wrote, nil) { return false }
		sent += int(wrote)
	}
	return true
}

// Closes the child's stdin, which tells a reader loop to finish.
stream_close_stdin :: proc(s: ^Stream) {
	if s.write_pipe != nil { win32.CloseHandle(s.write_pipe); s.write_pipe = nil }
}

stream_close :: proc(s: ^Stream) {
	if !s.running { return }
	stream_close_stdin(s)
	if s.read_pipe != nil { win32.CloseHandle(s.read_pipe) }
	if s.process   != nil { win32.CloseHandle(s.process) }
	s.running = false
}

stream_kill :: proc(s: ^Stream) {
	if s.running && s.process != nil { win32.TerminateProcess(s.process, 1) }
	stream_close(s)
}

// Runs a command to completion and returns everything it wrote to stdout.
// Blocking, so it belongs on a worker thread, never in a frame.
run_capture :: proc(args: []string, allocator := context.allocator) -> (out: []byte, exit_code: u32, ok: bool) {
	s, started := stream_start(args)
	if !started { return nil, 0, false }
	defer stream_close(&s)

	acc: [dynamic]byte
	acc.allocator = allocator
	chunk: [64 * 1024]byte

	// Reads block, so this loop spends its time waiting on the OS rather than
	// waking up to find nothing. It ends when the child closes the pipe, which
	// it does when it exits.
	for {
		n, eof := stream_read_wait(&s, chunk[:])
		if n > 0 {
			append(&acc, ..chunk[:n])
			continue
		}
		if eof { break }
	}

	// The pipe is closed, so the child is on its way out; this returns almost
	// immediately.
	win32.WaitForSingleObject(s.process, 5000)
	_ = stream_finished(&s)
	return acc[:], s.exit_code, true
}
