package musictagger

// Scoring the drop detector against real answers.
//
// The drop has been rewritten three times and judged each time by reading a
// column of numbers and deciding whether they felt right. That is not a way to
// improve anything: two of those rewrites made some tracks better and others
// worse, and there was no way to tell which had happened.
//
// So `drops.txt` holds the answers — a time and enough of a filename to find
// it — and this compares the detector against them. One number comes out, the
// median error, and that number is the thing to make smaller.
//
//     mtag-test.exe --dropcheck <library>
//
// Nothing here changes the detector. It only says how wrong it is, which is the
// part that was missing.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

Drop_Answer :: struct {
	seconds: f32,
	needle:  string, // lowercased, matched against the path
	line:    int,
}

// "12.5", "0:12.5" and "1:02" all mean what they look like.
@(private)
parse_timestamp :: proc(text: string) -> (f32, bool) {
	if colon := strings.index_byte(text, ':'); colon > 0 {
		minutes, ok_m := strconv.parse_f32(text[:colon])
		seconds, ok_s := strconv.parse_f32(text[colon + 1:])
		if !ok_m || !ok_s { return 0, false }
		return minutes * 60 + seconds, true
	}
	value, ok := strconv.parse_f32(text)
	return value, ok
}

@(private)
read_answers :: proc(path: string) -> ([]Drop_Answer, bool) {
	raw, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { return nil, false }

	out := make([dynamic]Drop_Answer, 0, 64, context.temp_allocator)
	for line, i in strings.split_lines(string(raw), context.temp_allocator) {
		trimmed := strings.trim_space(line)
		if trimmed == "" || trimmed[0] == '#' { continue }

		// The time, then everything after the first run of spaces.
		space := strings.index_any(trimmed, " \t")
		if space <= 0 { continue }
		seconds, ok := parse_timestamp(trimmed[:space])
		if !ok { continue }

		needle := strings.trim_space(trimmed[space:])
		if needle == "" { continue }

		append(&out, Drop_Answer{
			seconds = seconds,
			needle  = strings.to_lower(needle, context.temp_allocator),
			line    = i + 1,
		})
	}
	return out[:], true
}

// Which track an answer is about. Ambiguous names are reported rather than
// guessed at — an answer matched to the wrong track is worse than a missing
// one, because it quietly poisons the score.
@(private)
find_answer_track :: proc(needle: string) -> (int, int) {
	found := -1
	count := 0
	for &t, i in lib.tracks {
		if !strings.contains(t.haystack, needle) { continue }
		count += 1
		if found < 0 { found = i }
	}
	return found, count
}

run_drop_check :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}

	answers_path := join_path({project_root(), "drops.txt"}, context.temp_allocator)
	answers, read_ok := read_answers(answers_path)
	if !read_ok {
		fmt.printf("no answers at %s\n", answers_path)
		return 1
	}
	if len(answers) == 0 {
		fmt.printf("%s has no answers in it yet.\n\n", answers_path)
		fmt.println("Add lines of \"<seconds> <part of the filename>\" and run this again.")
		return 1
	}

	start_scan(folder, true, false)
	for !poll_scan() { }
	rebuild_view()

	// Measure anything that is not measured yet. A drop cannot be scored
	// against a track whose waveform has never been read, and reporting those
	// as failures would blame the detector for a missing cache.
	start_warmup(lib.tracks[:])
	for {
		_, _, running := warmup_progress()
		if !running { break }
		time.sleep(200 * time.Millisecond)
	}
	stop_warmup()
	load_all_features()

	fmt.printf("%d answers in drops.txt\n\n", len(answers))
	fmt.printf("%9s %9s %9s %6s   %s\n", "wanted", "found", "off by", "bpm", "track")

	errors := make([dynamic]f32, 0, len(answers), context.temp_allocator)
	missing, ambiguous, unmeasured := 0, 0, 0

	for answer in answers {
		index, matches := find_answer_track(answer.needle)
		if matches == 0 {
			fmt.printf("%9.2f %9s %9s   line %d: nothing matches %q\n",
			           answer.seconds, "-", "-", answer.line, answer.needle)
			missing += 1
			continue
		}
		if matches > 1 {
			fmt.printf("%9.2f %9s %9s   line %d: %q matches %d tracks\n",
			           answer.seconds, "-", "-", answer.line, answer.needle, matches)
			ambiguous += 1
			continue
		}

		t := &lib.tracks[index]
		if !t.features.valid {
			fmt.printf("%9.2f %9s %9s   %s (not measured)\n",
			           answer.seconds, "-", "-", short_name(display_text(t.name), 44))
			unmeasured += 1
			continue
		}

		off := abs(t.features.drop - answer.seconds)
		append(&errors, off)
		fmt.printf("%9.2f %9.2f %9.2f %6.1f   %s\n", answer.seconds, t.features.drop, off,
		           t.features.tempo, short_name(display_text(t.name), 44))
	}

	if len(errors) == 0 {
		fmt.println("\nnothing could be scored")
		return 1
	}

	slice.sort(errors[:])
	median := errors[len(errors) / 2]

	// How many land close enough to cut to. A second is about two beats at 120,
	// which is the point at which an editor would nudge it rather than trust it.
	within_1, within_3 := 0, 0
	total: f32
	for e in errors {
		total += e
		if e <= 1 { within_1 += 1 }
		if e <= 3 { within_3 += 1 }
	}

	fmt.printf("\n%d scored", len(errors))
	if missing > 0    { fmt.printf(", %d not found", missing) }
	if ambiguous > 0  { fmt.printf(", %d ambiguous", ambiguous) }
	if unmeasured > 0 { fmt.printf(", %d unmeasured", unmeasured) }
	fmt.println()

	fmt.printf("  median off by   %6.2f s\n", median)
	fmt.printf("  mean off by     %6.2f s\n", total / f32(len(errors)))
	fmt.printf("  worst           %6.2f s\n", errors[len(errors) - 1])
	fmt.printf("  within 1 s      %6d of %d\n", within_1, len(errors))
	fmt.printf("  within 3 s      %6d of %d\n", within_3, len(errors))

	fmt.println("\nThe median is the number to make smaller.")
	return 0
}

// Cut to a length, in characters. The one in the self test is private to it,
// and this is two lines.
@(private)
short_name :: proc(text: string, limit: int) -> string {
	if len(text) <= limit { return text }
	return fmt.tprintf("%s…", text[:limit])
}
