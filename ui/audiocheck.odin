package musictagger

// Which files the player will hand to raylib as-is, and which it will convert.
//
// ".wav" is not one format, and the one the player was trusting blindly covers
// only 72% of this library. `DoorBell11.wav` is 8-bit unsigned, where silence is
// 128 rather than 0, and it played as noise. This walks the library and reports
// what each WAV actually is, so the split can be checked against the files
// rather than assumed.

import "core:fmt"
import "core:os"
import "core:strings"

run_audio_check :: proc(folder: string) -> int {
	if !os.is_dir(folder) {
		fmt.printf("not a folder: %s\n", folder)
		return 1
	}
	start_scan(folder, true, true)
	for !poll_scan() { }

	native, converted, total := 0, 0, 0
	shown := 0
	fmt.println("files the player will convert rather than trust:")
	for &t in lib.tracks {
		if t.ext != ".wav" { continue }
		total += 1
		if wav_is_plain_16bit(t.path) {
			native += 1
			continue
		}
		converted += 1
		if shown < 8 {
			fmt.printf("    %s\n", t.rel)
			shown += 1
		}
	}
	fmt.printf("\n%d WAV files: %d played as-is, %d converted first\n",
	           total, native, converted)

	check("some WAVs are plain 16-bit", native > 0)
	check("and the odd ones are caught", converted > 0)

	// The one that was reported garbled must be on the converted side.
	found := false
	for &t in lib.tracks {
		if !strings.has_suffix(strings.to_lower(t.name), "doorbell11.wav") { continue }
		found = true
		check("DoorBell11.wav is not played as-is", !wav_is_plain_16bit(t.path))
		path, ext, ok := playable_path(&t)
		check("it converts to something playable", ok, path)
		check("and comes back as a .wav", ext == ".wav", ext)
		if ok {
			check("the converted file is plain 16-bit", wav_is_plain_16bit(path))
		}
	}
	if !found { fmt.println("        DoorBell11.wav not in this library — skipped") }

	fmt.printf("\n%s\n", failures == 0 ? "all checks passed" : "checks failed")
	return failures == 0 ? 0 : 1
}
