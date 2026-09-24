package musictagger

// Small facts that differ between Windows, macOS and Linux, in one place.

import "core:os"
import "core:strings"

when ODIN_OS == .Windows {
	EXE_SUFFIX  :: ".exe"
	SETUP_HINT  :: "Python is not set up. Run setup.bat next to MusicTagger.exe."
	SHOW_IN_FILE_MANAGER :: "Show in Explorer"
	// NTFS compares names without regard to case.
	PATHS_FOLD_CASE :: true
} else when ODIN_OS == .Darwin {
	EXE_SUFFIX  :: ""
	SETUP_HINT  :: "Python is not set up. Run setup.sh next to the app."
	SHOW_IN_FILE_MANAGER :: "Show in Finder"
	// APFS and HFS+ are case-insensitive by default.
	PATHS_FOLD_CASE :: true
} else {
	EXE_SUFFIX  :: ""
	SETUP_HINT  :: "Python is not set up. Run setup.sh next to the app."
	SHOW_IN_FILE_MANAGER :: "Show in file manager"
	// ext4, btrfs and xfs are case-sensitive: Song.wav and song.wav are two
	// different files, and folding them together would lose one.
	PATHS_FOLD_CASE :: false
}

// Whether two paths name the same file, by this platform's rules.
path_equal :: proc(a, b: string) -> bool {
	when PATHS_FOLD_CASE {
		return strings.equal_fold(a, b)
	} else {
		return a == b
	}
}

// A path as a map key: lowercased only where the file system ignores case.
path_key :: proc(p: string, allocator := context.temp_allocator) -> string {
	when PATHS_FOLD_CASE {
		return strings.to_lower(p, allocator)
	} else {
		return p
	}
}

// Where per-user application settings live: %APPDATA% on Windows,
// ~/Library/Application Support on macOS, $XDG_CONFIG_HOME (or ~/.config) on
// Linux. Other Zengane tools keep their settings here too.
user_config_dir :: proc() -> string {
	when ODIN_OS == .Windows {
		return os.get_env("APPDATA", context.temp_allocator)
	} else when ODIN_OS == .Darwin {
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" { return "" }
		return join_path({home, "Library", "Application Support"})
	} else {
		if xdg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); xdg != "" { return xdg }
		home := os.get_env("HOME", context.temp_allocator)
		if home == "" { return "" }
		return join_path({home, ".config"})
	}
}
