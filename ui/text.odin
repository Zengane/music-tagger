package musictagger

// Turning a filename on disk into something that can be drawn.
//
// Tracks ripped from YouTube carry characters Windows does not allow in a
// filename, swapped for look-alikes that it does: "⧸" for a slash, "？" for a
// question mark, "＂" for a quote. They are not decoration and they are not
// Japanese — they are punctuation wearing a disguise, and no interface font
// carries them.
//
// So they are folded back to the ASCII they stand for, for display only. The
// path on disk is never touched: it is what every file operation uses, and
// rewriting it would break the sidecar, the caches, and the file itself.

import "core:strings"
import "core:unicode/utf8"

// Look-alikes and the character each one is standing in for.
//
// The fullwidth forms are what Windows tools substitute; U+29F8 is what
// yt-dlp uses for a slash.
@(private)
LOOKALIKES := [][2]rune{
	{'⧸',      '/'},  // U+29F8 big solidus
	{'／',      '/'},  // U+FF0F fullwidth solidus
	{'＼',      '\\'}, // U+FF3C fullwidth reverse solidus
	{'｜',      '|'},  // U+FF5C fullwidth vertical line
	{'＂',      '"'},  // U+FF02 fullwidth quotation mark
	{'？',      '?'},  // U+FF1F fullwidth question mark
	{'：',      ':'},  // U+FF1A fullwidth colon
	{'＊',      '*'},  // U+FF0A fullwidth asterisk
	{'＜',      '<'},  // U+FF1C fullwidth less-than
	{'＞',      '>'},  // U+FF1E fullwidth greater-than
	{'∕',      '/'},  // U+2215 division slash
	{'⁄',      '/'},  // U+2044 fraction slash
}

@(private)
fold_lookalike :: proc(c: rune) -> (rune, bool) {
	for pair in LOOKALIKES {
		if pair[0] == c { return pair[1], true }
	}
	return c, false
}

// True when the string holds a look-alike that would otherwise draw as a gap.
has_lookalike :: proc(s: string) -> bool {
	for c in s {
		if _, folded := fold_lookalike(c); folded { return true }
	}
	return false
}

// The readable form of a path or filename. Allocated in the temp allocator, so
// it is good for the frame that made it and no longer.
//
// Strings without a look-alike are returned as they are: the common case
// should not pay for a rebuild.
display_text :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !has_lookalike(s) { return s }

	b := strings.builder_make(allocator)
	for c in s {
		folded, _ := fold_lookalike(c)
		strings.write_rune(&b, folded)
	}
	return strings.to_string(b)
}

// The same, as a cstring ready to draw.
display_cstring :: proc(s: string, allocator := context.temp_allocator) -> cstring {
	return strings.clone_to_cstring(display_text(s, allocator), allocator)
}

// Whether a string still needs the wide face after folding — that is, whether
// it contains real CJK.
//
// The first version of this tested raw bytes for anything above 0xE0, which
// also caught an en dash and a curly apostrophe. Most track names have one, so
// most of the list was being drawn in Yu Gothic with metrics the layout had
// measured against Segoe UI, and the names ran over the tag column.
has_cjk :: proc(s: string) -> bool {
	for c in s {
		if c >= 0x2E80 {
			if _, folded := fold_lookalike(c); !folded { return true }
		}
	}
	return false
}

// The characters the atlases have to cover, once folding has been applied.
runes_of :: proc(s: string, set: ^map[rune]bool) {
	for c in s {
		folded, _ := fold_lookalike(c)
		set[folded] = true
	}
	_ = utf8.RUNE_ERROR
}
