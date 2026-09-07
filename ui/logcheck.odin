package musictagger

// Drives a real tagging job with no window, so the log can be read back.
//
// The point of the log is that it answers "why did nothing happen" on a machine
// nobody can reach. That is only true if it actually records the run, so this
// runs one and checks what came out.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

run_log_check :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	log_environment()

	start_scan(folder, true, true)
	for !poll_scan() { }
	rebuild_view()
	if len(lib.tracks) == 0 {
		fmt.println("no tracks — skipped")
		return 1
	}

	start_analyze({0})
	deadline := time.now()
	for job.phase == .Loading || job.phase == .Running {
		poll_job()
		if time.duration_seconds(time.since(deadline)) > 300 { break }
	}
	fmt.printf("job finished in phase %v\n", job.phase)

	path := join_path({project_root(), "logs", "musictagger.log"}, context.temp_allocator)
	check("the log file exists", os.exists(path), path)

	raw, err := os.read_entire_file(path, context.temp_allocator)
	check("it can be read", err == nil)
	if err != nil {
		fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
		return failures == 0 ? 0 : 1
	}
	text := string(raw)

	check("it names the app folder", strings.contains(text, "app folder"))
	check("it says where python is", strings.contains(text, "python "))
	check("it says where ffmpeg is", strings.contains(text, "ffmpeg "))
	check("it records the job starting", strings.contains(text, "analyze:"))
	check("it keeps what the job said", strings.contains(text, "  | "))
	check("it records the exit code", strings.contains(text, "analyze finished"))

	fmt.println("\n---- the log ----")
	lines := strings.split_lines(text, context.temp_allocator)
	shown := 0
	for line in lines {
		if len(strings.trim_space(line)) == 0 { continue }
		fmt.println(line)
		shown += 1
		if shown >= 24 { fmt.printf("... %d more lines\n", len(lines) - shown); break }
	}

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}
