package musictagger

// Which build this is.
//
// build.bat and build.sh pass the git commit with -define:BUILD_ID=...; the
// compile time comes from the compiler. Both show in the title bar and in
// Settings → About, so "is this the new version?" has an answer on screen
// rather than a guess — a build that failed leaves the old .exe in place, and
// that looked exactly like a fix that did not work.

import "core:fmt"
import "core:time"

BUILD_ID :: #config(BUILD_ID, "dev")

// "935ba80 · 25 Sep 2026 14:02 UTC"
build_label :: proc(allocator := context.temp_allocator) -> string {
	t := time.Time{_nsec = ODIN_COMPILE_TIMESTAMP}
	y, mo, d := time.date(t)
	h, mi, _ := time.clock(t)
	months := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	return fmt.aprintf("%s · %d %s %d %02d:%02d UTC", BUILD_ID, d, months[int(mo) - 1], y, h, mi,
	                   allocator = allocator)
}
