package musictagger

// Sending a sound straight to Premiere.
//
// Dragging a file works, and rendering a selection out to a WAV works, but
// both leave the editor doing the last step by hand — and the rendered clip is
// a second copy of audio that already exists on disk. This is the step that
// removes: the selection is placed on the timeline, the media is the original
// file, and the handles are still there to trim back out to.
//
// How it gets there: the Zen Drop panel already runs a loopback listener
// inside Premiere for Listary. It has been taught to take a span and a sync
// point as well as a path, so this is one HTTP GET to 127.0.0.1 and nothing
// new has to run. Nothing here is reachable from off this machine.
//
//   GET /drop?path=<file>&mode=timeline&in=<s>&out=<s>&mark=<s>
//
// The port is read from Zen Drop's own settings.json rather than typed in
// twice, which is the same thing its bridge executable does.

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

PREMIERE_DEFAULT_PORT :: 47821

// Where Zen Drop keeps the port. The panel, its settings dialog, its bridge
// exe and now this all read the one file.
@(private)
zendrop_settings_path :: proc(allocator := context.temp_allocator) -> string {
	appdata := user_config_dir()
	if appdata == "" { return "" }
	return join_path({appdata, "Zengane", "Zen Drop", "settings.json"}, allocator)
}

// The port Zen Drop is listening on, or the default when it has never been
// changed. A missing file is not a failure: it means the panel is on defaults.
premiere_port :: proc() -> int {
	path := zendrop_settings_path()
	if path == "" { return PREMIERE_DEFAULT_PORT }

	raw, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil || len(raw) == 0 { return PREMIERE_DEFAULT_PORT }

	text := string(raw)
	key := "\"port\""
	at := strings.index(text, key)
	if at < 0 { return PREMIERE_DEFAULT_PORT }

	rest := text[at + len(key):]
	colon := strings.index_byte(rest, ':')
	if colon < 0 { return PREMIERE_DEFAULT_PORT }
	rest = rest[colon + 1:]

	start := 0
	for start < len(rest) && (rest[start] == ' ' || rest[start] == '\t') { start += 1 }
	end := start
	for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' { end += 1 }
	if end == start { return PREMIERE_DEFAULT_PORT }

	value, parsed := strconv.parse_int(rest[start:end])
	if !parsed || value < 1024 || value > 65535 { return PREMIERE_DEFAULT_PORT }
	return value
}

// Percent-encoding for a query value. Everything that is not plainly safe is
// escaped, which matters because these paths carry spaces, ampersands and
// every accent the library has in it.
@(private)
url_encode :: proc(s: string, allocator := context.temp_allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	HEX := "0123456789ABCDEF"
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9',
		     c == '-', c == '_', c == '.', c == '~':
			strings.write_byte(&b, c)
		case:
			strings.write_byte(&b, '%')
			strings.write_byte(&b, HEX[c >> 4])
			strings.write_byte(&b, HEX[c & 0xF])
		}
	}
	return strings.to_string(b)
}

// One request, one answer, then the socket closes.
//
// Everything is bounded: the listener is on this machine, so a request that
// has not answered in a couple of seconds is not slow, it is not there. The
// timeout is what turns "Premiere is not running" into a message rather than a
// frozen interface.
@(private)
http_get :: proc(port: int, path: string) -> (body: string, ok: bool) {
	endpoint := net.Endpoint{
		address = net.IP4_Loopback,
		port    = port,
	}

	sock, err := net.dial_tcp_from_endpoint(endpoint)
	if err != nil { return "", false }
	defer net.close(sock)

	net.set_option(sock, .Send_Timeout,    2 * time.Second)
	net.set_option(sock, .Receive_Timeout, 5 * time.Second)

	request := fmt.tprintf(
		"GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\nUser-Agent: MusicTagger\r\n\r\n",
		path, port)

	sent := 0
	for sent < len(request) {
		n, serr := net.send_tcp(sock, transmute([]byte)request[sent:])
		if serr != nil || n <= 0 { return "", false }
		sent += n
	}

	reply: [dynamic]byte
	reply.allocator = context.temp_allocator
	buf: [1024]byte
	for {
		n, rerr := net.recv_tcp(sock, buf[:])
		if rerr != nil || n <= 0 { break }
		append(&reply, ..buf[:n])
		if len(reply) > 64 * 1024 { break }
	}
	if len(reply) == 0 { return "", false }

	text := string(reply[:])
	// The status line first, then whatever came after the blank line.
	if !strings.has_prefix(text, "HTTP/") { return "", false }
	space := strings.index_byte(text, ' ')
	if space < 0 || len(text) < space + 4 { return "", false }
	code := text[space + 1:][:3]

	payload := ""
	if split := strings.index(text, "\r\n\r\n"); split >= 0 {
		head := text[:split]
		payload = text[split + 4:]
		// Node sends short replies chunked, so the body arrives wrapped in
		// its lengths: "7\r\nzendrop\r\n0\r\n\r\n". Unwrapped, because the
		// message is shown to the user and the framing is not part of it.
		if strings.contains(strings.to_lower(head, context.temp_allocator), "transfer-encoding: chunked") {
			payload = dechunk(payload)
		}
	}
	return strings.clone(payload, context.temp_allocator), code == "200"
}

// Undo HTTP chunked framing: a hex length, the bytes, repeat until zero.
// Anything malformed hands back what is left, which is more useful in a
// message than an empty string.
@(private)
dechunk :: proc(body: string) -> string {
	out: strings.Builder
	strings.builder_init(&out, context.temp_allocator)

	rest := body
	for {
		line_end := strings.index(rest, "\r\n")
		if line_end < 0 { break }

		size, ok := strconv.parse_int(strings.trim_space(rest[:line_end]), 16)
		if !ok { return body }
		if size == 0 { break }

		start := line_end + 2
		if start + size > len(rest) { break }
		strings.write_string(&out, rest[start:start + size])

		rest = rest[start + size:]
		if strings.has_prefix(rest, "\r\n") { rest = rest[2:] }
	}
	return strings.to_string(out)
}

// True when the panel answers. Used to word the failure properly rather than
// blaming the wrong thing.
premiere_available :: proc() -> bool {
	body, ok := http_get(premiere_port(), "/ping")
	return ok && strings.contains(body, "zendrop")
}

// Send a track to the timeline.
//
// `from` and `to` are seconds into the file; pass 0 and 0 for the whole thing.
// `mark` is where a marker goes, in the same source time, or a negative number
// for none. The playhead in Premiere decides where it lands, which is what an
// editor expects: put the playhead where the sound goes, then send.
send_to_premiere :: proc(t: ^Track, from, to: f32, mark: f32 = -1) -> (message: string, ok: bool) {
	port := premiere_port()

	q: strings.Builder
	strings.builder_init(&q, context.temp_allocator)
	fmt.sbprintf(&q, "/drop?mode=timeline&path=%s", url_encode(t.path))
	ranged := to > from
	if ranged {
		fmt.sbprintf(&q, "&in=%.3f&out=%.3f", from, to)
	}
	if mark >= 0 {
		fmt.sbprintf(&q, "&mark=%.3f", mark)
	}

	body, sent := http_get(port, strings.to_string(q))
	if !sent {
		// Two different problems, and the difference is the whole message: a
		// panel that is not open is a thing to go and open, a refused path is
		// a thing to look at.
		if body == "" {
			return fmt.tprintf("Premiere did not answer on port %d — is the Zen Drop panel open?", port), false
		}
		return fmt.tprintf("Premiere refused it: %s", strings.trim_space(body)), false
	}

	if ranged {
		return fmt.tprintf("sent %s to Premiere%s", fmt_time(to - from), mark >= 0 ? " with a marker" : ""), true
	}
	return fmt.tprintf("sent %s to Premiere", display_text(t.name)), true
}

// `--premiere [file]`: is the panel there, and what would be sent to it.
//
// The failure this exists for is the silent one: the button says it sent
// something and nothing appears in Premiere. This says which half is wrong.
run_premiere_check :: proc(file: string) -> int {
	port := premiere_port()
	fmt.printf("Zen Drop settings: %s\n", zendrop_settings_path())
	fmt.printf("port: %d\n", port)

	body, ok := http_get(port, "/ping")
	if ok {
		fmt.printf("panel answered: %s\n", strings.trim_space(body))
	} else {
		fmt.printf("no answer on 127.0.0.1:%d — open the Zen Drop panel in Premiere\n", port)
	}

	if file != "" {
		fmt.printf("would send: /drop?mode=timeline&path=%s&in=1.500&out=3.250&mark=1.700\n",
		           url_encode(file))
	}
	return ok ? 0 : 1
}

// Trim what Premiere just placed down to the selection.
//
// Premiere hands an extension no drop position, so a drag cannot be caught and
// placed by hand. This is the way round it: Windows drops the original file,
// Premiere puts the whole thing wherever the pointer let go, and then this
// reaches in and trims that clip to the part that was wanted, leaving it
// exactly where it landed. It is the drop the editor asked for, done in two
// steps instead of one.
trim_in_premiere :: proc(t: ^Track, from, to: f32, mark: f32 = -1) -> (message: string, ok: bool) {
	if to <= from { return "no selection to trim to", false }
	port := premiere_port()

	q: strings.Builder
	strings.builder_init(&q, context.temp_allocator)
	fmt.sbprintf(&q, "/trim?path=%s&in=%.3f&out=%.3f", url_encode(t.path), from, to)
	if mark >= 0 { fmt.sbprintf(&q, "&mark=%.3f", mark) }

	body, sent := http_get(port, strings.to_string(q))
	if !sent {
		if body == "" {
			return fmt.tprintf("dropped, but Premiere did not answer on port %d", port), false
		}
		return fmt.tprintf("dropped, but the trim was refused: %s", strings.trim_space(body)), false
	}
	// The panel answers as soon as it has queued the work; whether the trim
	// itself worked shows up in the panel's own log.
	return fmt.tprintf("dropped %s — trimming it to your selection", fmt_time(to - from)), true
}

// Put the original file where a rendered placeholder just landed.
//
// The placeholder is exactly as long as the selection, so Premiere shows the
// right length from the moment it is dropped and nothing to its right is ever
// covered by a full-length song. The swap then replaces it with the original,
// trimmed to the same span, so the timeline ends up referring to the real file
// with its handles intact.
//
// Failing is survivable by design: the placeholder is the correct audio, so a
// refused swap leaves a working edit that happens to use a rendered copy.
swap_in_premiere :: proc(t: ^Track, placeholder: string, from, to: f32, mark: f32 = -1) -> (message: string, ok: bool) {
	if to <= from { return "no selection to place", false }
	port := premiere_port()

	q: strings.Builder
	strings.builder_init(&q, context.temp_allocator)
	fmt.sbprintf(&q, "/swap?placeholder=%s&path=%s&in=%.3f&out=%.3f",
	             url_encode(placeholder), url_encode(t.path), from, to)
	if mark >= 0 { fmt.sbprintf(&q, "&mark=%.3f", mark) }

	body, sent := http_get(port, strings.to_string(q))
	if !sent {
		if body == "" {
			return fmt.tprintf("dropped, but Premiere did not answer on port %d", port), false
		}
		return fmt.tprintf("dropped, but the swap was refused: %s", strings.trim_space(body)), false
	}
	return fmt.tprintf("dropped %s — swapping in the original", fmt_time(to - from)), true
}

// Where the marker goes for a given range.
//
// The measured hit is the right answer when it falls inside the range. It very
// often does not: for an effect the hit is usually at the very start of the
// file, so trimming off the silence before it — which is the first thing anyone
// does — left the hit outside the selection and no marker was sent at all.
// That is why sending part of an effect arrived unmarked.
//
// So when the hit is outside, the loudest moment inside the range is used
// instead, read from the waveform peaks that are already in memory. For a
// transition effect that is the frame the cut lines up with, which is the whole
// reason for the marker.
mark_for_range :: proc(t: ^Track, from, to: f32) -> f32 {
	if to <= from { return -1 }
	if len(t.cues) > 0 {
		best: f32 = -1
		for cue in t.cues {
			if cue.at >= from && cue.at <= to && (best < 0 || cue.at < best) { best = cue.at }
		}
		return best
	}

	f := t.features
	if !f.valid { return -1 }

	// A song's marker is a property of the song.
	//
	// The drop is where the arrangement arrives. That is a fact about the
	// track, not about what you happen to have selected, so if the selection
	// does not contain it there is no marker to send — inventing one from
	// whatever is loudest inside the selection made the marker move as the
	// selection moved, which is the opposite of a sync point.
	if !t.is_sfx {
		return (f.drop > 0 && f.drop >= from && f.drop <= to) ? f.drop : -1
	}

	// An effect is different, and the difference is real rather than a
	// convenience. Its marker is the moment it lands, and an effect file is
	// usually silence followed by the sound — so the measured hit sits at the
	// very start, and trimming that silence off is the first thing anyone
	// does. Asking again inside the trimmed range gives the same answer for
	// the same reason: it is still "where this sound lands".
	if f.hit >= from && f.hit <= to { return f.hit }

	// Only the loaded track has its peaks to hand.
	if player.track < 0 || player.track >= len(lib.tracks) { return -1 }
	if &lib.tracks[player.track] != t || !player.has_peaks { return -1 }

	duration := max(player.duration, 0.001)
	values := peak_channel(player.peaks, 0)
	if len(values) == 0 { return -1 }

	lo := clamp(int(from / duration * f32(len(values))), 0, len(values) - 1)
	hi := clamp(int(to   / duration * f32(len(values))), lo + 1, len(values))

	best, at := u8(0), lo
	for i in lo ..< hi {
		if values[i] > best { best, at = values[i], i }
	}
	// Nothing above the noise floor: a marker on silence would be worse than
	// no marker at all.
	if best < 24 { return -1 }
	return f32(at) / f32(len(values)) * duration
}
