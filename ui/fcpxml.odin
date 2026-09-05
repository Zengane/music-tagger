package musictagger

// Handing Premiere a range without cutting the file.
//
// Dragging a rendered clip works, but it is destructive in the way that
// matters: what lands on the timeline is a new file, trimmed and padded, and
// the original is no longer what the edit refers to. Extending the selection
// later means going back to this app and exporting again.
//
// Premiere reads Final Cut Pro 7 XML. That format describes a sequence that
// *references* media with in and out points, so the file that gets imported is
// the whole original and only the chosen range is placed. Nothing is rendered,
// nothing is padded, and the handles either side are still there to trim into.
//
// So a selection drag carries a small .xml instead of a .wav. Premiere takes
// it as a sequence; the media in the project is the full-length original.
//
// This is the one part of the program that cannot be checked from here —
// whether a given Premiere build accepts an XML by drop is Premiere's
// business. The trimmed-file behaviour is still there behind a toggle for when
// it does not.

import "core:fmt"
import "core:os"
import "core:strings"

// The timebase the sequence is written in.
//
// Audio positions are frames in FCP7 XML, so a rate has to be chosen. 30 with
// no drop-frame keeps the arithmetic exact and lands within a thirtieth of a
// second of the chosen range, which no one is going to hear.
FCP_TIMEBASE :: 30

@(private)
seconds_to_frames :: proc(seconds: f32) -> int {
	return max(int(seconds * FCP_TIMEBASE + 0.5), 0)
}

// A path as the XML wants it: file://localhost/H:/Media/…, percent-escaped.
@(private)
path_to_url :: proc(path: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "file://localhost/")

	for c in transmute([]byte)path {
		switch {
		case c == '\\':
			strings.write_byte(&b, '/')
		case c == '/' || c == ':' ||
		     (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		     (c >= '0' && c <= '9') ||
		     c == '-' || c == '_' || c == '.' || c == '~':
			strings.write_byte(&b, c)
		case:
			// Everything else, including every byte of a multi-byte character,
			// goes through as a percent escape. Track names here contain
			// Japanese and full-width punctuation, and an unescaped one makes
			// the whole document unreadable.
			fmt.sbprintf(&b, "%%%02X", c)
		}
	}
	return strings.to_string(b)
}

@(private)
write_xml_text :: proc(b: ^strings.Builder, s: string) {
	for c in transmute([]byte)s {
		switch c {
		case '&':  strings.write_string(b, "&amp;")
		case '<':  strings.write_string(b, "&lt;")
		case '>':  strings.write_string(b, "&gt;")
		case '"':  strings.write_string(b, "&quot;")
		case '\'': strings.write_string(b, "&apos;")
		case:      strings.write_byte(b, c)
		}
	}
}

// Writes a one-clip sequence referencing `t` between `from` and `to`.
//
// Returns the path of the file written.
write_range_xml :: proc(t: ^Track, from, to: f32, mark := true) -> (string, bool) {
	total_frames := seconds_to_frames(max(t.duration, to))
	in_frames    := seconds_to_frames(from)
	out_frames   := max(seconds_to_frames(to), in_frames + 1)
	length       := out_frames - in_frames

	base := strings.trim_suffix(t.name, t.ext)
	title := fmt.tprintf("%s [%s-%s]", base, fmt_time(from), fmt_time(to))

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	strings.write_string(&b, "<!DOCTYPE xmeml>\n")
	strings.write_string(&b, "<xmeml version=\"4\">\n")

	fmt.sbprintf(&b, "  <sequence id=\"mtag-seq\">\n")
	strings.write_string(&b, "    <name>")
	write_xml_text(&b, title)
	strings.write_string(&b, "</name>\n")
	fmt.sbprintf(&b, "    <duration>%d</duration>\n", length)
	fmt.sbprintf(&b, "    <rate><timebase>%d</timebase><ntsc>FALSE</ntsc></rate>\n", FCP_TIMEBASE)
	strings.write_string(&b, "    <timecode>\n")
	fmt.sbprintf(&b, "      <rate><timebase>%d</timebase><ntsc>FALSE</ntsc></rate>\n", FCP_TIMEBASE)
	strings.write_string(&b, "      <frame>0</frame>\n      <displayformat>NDF</displayformat>\n")
	strings.write_string(&b, "    </timecode>\n")
	strings.write_string(&b, "    <media>\n      <audio>\n")
	// A format block on the sequence itself. Premiere is more willing to
	// accept a document that says what the sequence is than one that leaves
	// it to be inferred from the clip.
	strings.write_string(&b, "        <format>\n")
	strings.write_string(&b, "          <samplecharacteristics><depth>16</depth><samplerate>48000</samplerate></samplecharacteristics>\n")
	strings.write_string(&b, "        </format>\n")
	strings.write_string(&b, "        <track>\n")

	strings.write_string(&b, "          <clipitem id=\"mtag-clip\">\n")
	strings.write_string(&b, "            <name>")
	write_xml_text(&b, t.name)
	strings.write_string(&b, "</name>\n")
	fmt.sbprintf(&b, "            <duration>%d</duration>\n", total_frames)
	fmt.sbprintf(&b, "            <rate><timebase>%d</timebase><ntsc>FALSE</ntsc></rate>\n", FCP_TIMEBASE)
	// Placed at the head of the sequence; in and out are where in the source
	// file it comes from, which is what keeps the whole file referenced.
	fmt.sbprintf(&b, "            <start>0</start>\n")
	fmt.sbprintf(&b, "            <end>%d</end>\n", length)
	fmt.sbprintf(&b, "            <in>%d</in>\n", in_frames)
	fmt.sbprintf(&b, "            <out>%d</out>\n", out_frames)

	strings.write_string(&b, "            <file id=\"mtag-file\">\n")
	strings.write_string(&b, "              <name>")
	write_xml_text(&b, t.name)
	strings.write_string(&b, "</name>\n")
	strings.write_string(&b, "              <pathurl>")
	write_xml_text(&b, path_to_url(t.path))
	strings.write_string(&b, "</pathurl>\n")
	fmt.sbprintf(&b, "              <rate><timebase>%d</timebase><ntsc>FALSE</ntsc></rate>\n", FCP_TIMEBASE)
	fmt.sbprintf(&b, "              <duration>%d</duration>\n", total_frames)
	strings.write_string(&b, "              <media><audio>\n")
	strings.write_string(&b, "                <samplecharacteristics><depth>16</depth><samplerate>48000</samplerate></samplecharacteristics>\n")
	strings.write_string(&b, "                <channelcount>2</channelcount>\n")
	strings.write_string(&b, "              </audio></media>\n")
	strings.write_string(&b, "            </file>\n")

	strings.write_string(&b, "            <sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>\n")

	// A marker on the sync point, for effects meant to land on a cut.
	//
	// Marker positions are relative to the clip, so the in point comes off
	// the hit. A hit outside the selected range is left out rather than
	// clamped to an edge, where it would be wrong and look deliberate.
	if mark && t.features.valid && t.features.hit >= from && t.features.hit <= to {
		hit_frames := seconds_to_frames(t.features.hit) - in_frames
		if hit_frames >= 0 && hit_frames <= length {
			strings.write_string(&b, "            <marker>\n")
			strings.write_string(&b, "              <name>hit</name>\n")
			strings.write_string(&b, "              <comment>loudest point</comment>\n")
			fmt.sbprintf(&b, "              <in>%d</in>\n", hit_frames)
			strings.write_string(&b, "              <out>-1</out>\n")
			strings.write_string(&b, "            </marker>\n")
		}
	}

	strings.write_string(&b, "          </clipitem>\n")
	strings.write_string(&b, "        </track>\n")
	strings.write_string(&b, "      </audio>\n    </media>\n  </sequence>\n")
	strings.write_string(&b, "</xmeml>\n")

	name := fmt.tprintf("%s.xml", sanitise_filename(title))
	dest := join_path({cache_dir("ranges"), name}, context.allocator)
	if werr := os.write_entire_file(dest, transmute([]byte)strings.to_string(b)); werr != nil {
		delete(dest)
		return "", false
	}
	return dest, true
}
