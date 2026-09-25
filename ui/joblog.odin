package musictagger

// A log of what the jobs actually did, written beside the .exe.
//
// The window shows a progress bar and a one-line status. When a job fails for a
// reason nobody anticipated, that line is gone in a frame and the Python
// traceback — which was on the pipe all along — is thrown away by the reader,
// which only keeps lines that parse as JSON.
//
// That cost a round trip with someone else's machine: tagging "did nothing",
// and there was no way to find out why except to guess. Everything the child
// process says now lands in `logs\musictagger.log`, JSON and tracebacks alike,
// with the command that started it and the code it exited with.
//
// It is on by default. A few kilobytes per run is a fair price for being able
// to answer the question at all, and the file is capped so it cannot grow
// without limit.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

LOG_MAX_BYTES :: 512 * 1024

@(private)
log_path :: proc(allocator := context.temp_allocator) -> string {
	return join_path({project_root(), "logs", "musictagger.log"}, allocator)
}

// Appends one line, with the time in front of it.
log_line :: proc(text: string) {
	dir := join_path({project_root(), "logs"}, context.temp_allocator)
	if !os.exists(dir) {
		if os.make_directory(dir) != nil { return }
	}

	path := log_path()

	// Rolled rather than trimmed: keeping the tail of a text file in place
	// means rewriting all of it, and the previous run is worth keeping anyway.
	if info, err := os.stat(path, context.temp_allocator); err == nil {
		if info.size > LOG_MAX_BYTES {
			old := join_path({project_root(), "logs", "musictagger.prev.log"},
			                 context.temp_allocator)
			os.remove(old)
			os.rename(path, old)
		}
	}

	now := time.now()
	h, m, s := time.clock_from_time(now)
	stamp := fmt.tprintf("%02d:%02d:%02d  %s\n", h, m, s, text)

	handle, err := os.open(path, os.O_WRONLY | os.O_CREATE | os.O_APPEND)
	if err != nil { return }
	defer os.close(handle)
	os.write_string(handle, stamp)
}

logf :: proc(format: string, args: ..any) {
	log_line(fmt.tprintf(format, ..args))
}

// Everything worth knowing about this installation, written once at startup.
//
// Nearly every "it does not work on my machine" report so far has come down to
// one of these five lines being wrong, and none of them are visible from inside
// the window.
log_environment :: proc() {
	logf("---- Music Tagger starting ----")
	logf("build        %s", build_label())
	logf("app folder   %s", project_root())

	py := python_exe()
	logf("python       %s%s", py, os.exists(py) ? "" : "   MISSING - run setup.bat")

	model := join_path({project_root(), "model", "tagger.pkl"}, context.temp_allocator)
	logf("model        %s%s", model, os.exists(model) ? "" : "   MISSING")

	ff := ffmpeg_exe()
	logf("ffmpeg       %s%s", ff,
	     ffmpeg_available() ? "" : "   NOT FOUND - nothing can be decoded")

	script := job_script()
	logf("tag_job.py   %s%s", script, os.exists(script) ? "" : "   MISSING")
}

// The raw bytes a job wrote, split into lines. Tracebacks arrive here too:
// stderr shares the pipe, and the JSON reader discards anything it cannot
// parse, so this is the only place they are kept.
log_job_output :: proc(chunk: []byte) {
	text := string(chunk)
	for line in strings.split_lines_iterator(&text) {
		trimmed := strings.trim_space(line)
		if len(trimmed) == 0 { continue }

		// A result line carries every tag's score and runs to about two
		// thousand characters. Nine hundred of those would roll the log twice
		// over and take the header with it — which is the part that says what
		// is missing. The event and the file survive the cut; the scores were
		// never what anyone reads this for.
		if len(trimmed) > 300 {
			trimmed = fmt.tprintf("%s… (%d more characters)",
			                      trimmed[:300], len(trimmed) - 300)
		}
		log_line(strings.concatenate({"  | ", trimmed}, context.temp_allocator))
	}
}
