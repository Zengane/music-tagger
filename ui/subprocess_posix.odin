#+build linux, darwin, freebsd, openbsd, netbsd
package musictagger

// Running ffmpeg and Python on macOS and Linux.
//
// The same two shapes as the Windows version, with the same promises:
//   run_capture  — start it, read all of stdout, wait. Blocking.
//   Stream       — start it and read stdout in pieces across frames, never
//                  blocking the window.
//
// posix_spawn rather than fork: the app has worker threads, and fork in a
// threaded program may only call async-signal-safe functions before exec.
// posix_spawn does the dup2 and chdir itself, in the right order, and on macOS
// it is also the fast path.
//
// There is no console window to hide here, so none of the Windows flags have a
// counterpart. stdin is /dev/null unless the caller asks for a pipe, for the
// same reason as on Windows: a child that probes stdin must not hang on it.

import "core:c"
import "core:strings"
import "core:sys/posix"

Stream :: struct {
	pid:        posix.pid_t,
	read_fd:    posix.FD,
	write_fd:   posix.FD, // the child's stdin, when started with `with_stdin`
	running:    bool,
	reaped:     bool,
	exit_code:  u32,
}

// Opaque, and a different size on each libc: 80 bytes on glibc, one pointer on
// macOS. Oversized and aligned so any of them fits.
@(private)
Spawn_File_Actions :: struct #align(16) { _: [256]byte }

when ODIN_OS == .Darwin {
	foreign import spawnlib "system:System.framework"
} else {
	foreign import spawnlib "system:c"
}

@(private, default_calling_convention = "c")
foreign spawnlib {
	posix_spawn_file_actions_init     :: proc(fa: ^Spawn_File_Actions) -> c.int ---
	posix_spawn_file_actions_destroy  :: proc(fa: ^Spawn_File_Actions) -> c.int ---
	posix_spawn_file_actions_adddup2  :: proc(fa: ^Spawn_File_Actions, fd, newfd: c.int) -> c.int ---
	posix_spawn_file_actions_addclose :: proc(fa: ^Spawn_File_Actions, fd: c.int) -> c.int ---
	posix_spawn_file_actions_addopen  :: proc(fa: ^Spawn_File_Actions, fd: c.int, path: cstring, oflag: c.int, mode: c.uint) -> c.int ---
	// Not in POSIX 2008, but in glibc since 2.29 and macOS since 10.15.
	posix_spawn_file_actions_addchdir_np :: proc(fa: ^Spawn_File_Actions, path: cstring) -> c.int ---
}

when ODIN_OS == .Darwin {
	@(private, default_calling_convention = "c")
	foreign spawnlib {
		_NSGetEnviron :: proc() -> ^[^]cstring ---
	}
	@(private)
	current_environ :: proc() -> [^]cstring { return _NSGetEnviron()^ }
} else {
	@(private)
	foreign spawnlib {
		environ: [^]cstring
	}
	@(private)
	current_environ :: proc() -> [^]cstring { return environ }
}

// A child that exits while we are writing to its stdin raises SIGPIPE, whose
// default action is to kill this process. Ignored once, before the first spawn.
@(private)
ignore_sigpipe :: proc() {
	@(static) done: bool
	if done { return }
	done = true
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

// Starts `args[0]` with stdout (and stderr) on a pipe. `args[0]` is looked up
// on PATH when it has no slash in it, as a shell would.
stream_start :: proc(args: []string, working_dir := "", with_stdin := false) -> (s: Stream, ok: bool) {
	if len(args) == 0 { return {}, false }
	ignore_sigpipe()

	out_pipe: [2]posix.FD
	if posix.pipe(&out_pipe) != .OK { return {}, false }

	in_pipe := [2]posix.FD{-1, -1}
	if with_stdin {
		if posix.pipe(&in_pipe) != .OK {
			posix.close(out_pipe[0]); posix.close(out_pipe[1])
			return {}, false
		}
	}

	argv := make([]cstring, len(args) + 1, context.temp_allocator)
	for a, i in args { argv[i] = strings.clone_to_cstring(a, context.temp_allocator) }
	argv[len(args)] = nil

	fa: Spawn_File_Actions
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)

	if with_stdin {
		posix_spawn_file_actions_adddup2(&fa, c.int(in_pipe[0]), 0)
		posix_spawn_file_actions_addclose(&fa, c.int(in_pipe[1]))
	} else {
		posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", c.int(posix.O_RDONLY), 0)
	}
	posix_spawn_file_actions_adddup2(&fa, c.int(out_pipe[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, c.int(out_pipe[1]), 2)
	posix_spawn_file_actions_addclose(&fa, c.int(out_pipe[0]))
	if working_dir != "" {
		posix_spawn_file_actions_addchdir_np(&fa, strings.clone_to_cstring(working_dir, context.temp_allocator))
	}

	pid: posix.pid_t
	err := posix.posix_spawnp(&pid, argv[0], &fa, nil, raw_data(argv), current_environ())

	// The parent keeps only its own ends, or the pipe never reaches EOF.
	posix.close(out_pipe[1])
	if with_stdin { posix.close(in_pipe[0]) }

	if err != .NONE {
		posix.close(out_pipe[0])
		if with_stdin { posix.close(in_pipe[1]) }
		return {}, false
	}

	// Our ends must not leak into the next child we start.
	posix.fcntl(out_pipe[0], .SETFD, posix.FD_CLOEXEC)
	if with_stdin { posix.fcntl(in_pipe[1], .SETFD, posix.FD_CLOEXEC) }

	return Stream{pid = pid, read_fd = out_pipe[0], write_fd = in_pipe[1], running = true}, true
}

// Reads whatever is already in the pipe, up to `len(buf)`. Never blocks:
// returns 0 when there is nothing waiting yet, and sets `eof` once the child
// has closed its end.
stream_read :: proc(s: ^Stream, buf: []byte) -> (n: int, eof: bool) {
	if !s.running || len(buf) == 0 { return 0, !s.running }
	pfd := posix.pollfd{fd = s.read_fd, events = {.IN}}
	ready := posix.poll(&pfd, 1, 0)
	if ready <= 0 { return 0, false }
	return stream_read_wait(s, buf)
}

// Blocks until the child writes something or closes the pipe.
stream_read_wait :: proc(s: ^Stream, buf: []byte) -> (n: int, eof: bool) {
	if !s.running { return 0, true }
	for {
		got := posix.read(s.read_fd, raw_data(buf), c.size_t(len(buf)))
		if got > 0 { return int(got), false }
		if got == 0 { return 0, true }
		if posix.errno() == .EINTR { continue }
		return 0, true
	}
}

// Writes to the child's stdin. Only for streams started `with_stdin`.
stream_write :: proc(s: ^Stream, data: []byte) -> bool {
	if !s.running || s.write_fd < 0 { return false }
	sent := 0
	for sent < len(data) {
		remaining := data[sent:]
		n := posix.write(s.write_fd, raw_data(remaining), c.size_t(len(remaining)))
		if n < 0 {
			if posix.errno() == .EINTR { continue }
			return false
		}
		sent += int(n)
	}
	return true
}

// True once the child has exited. Fills in `exit_code`.
stream_finished :: proc(s: ^Stream) -> bool {
	if !s.running || s.reaped { return true }
	status: c.int
	got := posix.waitpid(s.pid, &status, {.NOHANG})
	if got == 0 { return false }
	s.reaped = true
	if got < 0 { s.exit_code = 1; return true }
	if posix.WIFEXITED(status) {
		s.exit_code = u32(posix.WEXITSTATUS(status))
	} else {
		s.exit_code = 1
	}
	return true
}

stream_close :: proc(s: ^Stream) {
	if !s.running { return }
	if s.read_fd >= 0 { posix.close(s.read_fd) }
	if s.write_fd >= 0 { posix.close(s.write_fd); s.write_fd = -1 }
	// Reap it if it has gone, so it does not linger as a zombie. One that is
	// still running is reaped by the next close on the same stream, or by the
	// kernel when this process exits.
	if !s.reaped {
		status: c.int
		if posix.waitpid(s.pid, &status, {.NOHANG}) != 0 { s.reaped = true }
	}
	s.running = false
}

// Closes the child's stdin, which tells a reader loop to finish.
stream_close_stdin :: proc(s: ^Stream) {
	if s.write_fd >= 0 { posix.close(s.write_fd); s.write_fd = -1 }
}

stream_kill :: proc(s: ^Stream) {
	if s.running && !s.reaped {
		posix.kill(s.pid, .SIGKILL)
		status: c.int
		posix.waitpid(s.pid, &status, {})
		s.reaped = true
	}
	stream_close(s)
}

// Runs a command to completion and returns everything it wrote to stdout.
// Blocking, so it belongs on a worker thread, never in a frame.
run_capture :: proc(args: []string, allocator := context.allocator) -> (out: []byte, exit_code: u32, ok: bool) {
	s, started := stream_start(args)
	if !started { return nil, 0, false }

	acc: [dynamic]byte
	acc.allocator = allocator
	chunk: [64 * 1024]byte
	for {
		n, eof := stream_read_wait(&s, chunk[:])
		if n > 0 { append(&acc, ..chunk[:n]); continue }
		if eof { break }
	}

	// The pipe is closed, so the child is on its way out.
	if !s.reaped {
		status: c.int
		if posix.waitpid(s.pid, &status, {}) > 0 {
			s.exit_code = posix.WIFEXITED(status) ? u32(posix.WEXITSTATUS(status)) : 1
		} else {
			s.exit_code = 1
		}
		s.reaped = true
	}
	code := s.exit_code
	stream_close(&s)
	// A program that is not there at all spawns fine and exits 127.
	if code == 127 && len(acc) == 0 { return acc[:], code, false }
	return acc[:], code, true
}
