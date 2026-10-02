package musictagger

// Downloads: playlists and videos in, tagged and filed music out.
//
//   ┌──────────────────────────────────────────────────────────────────────┐
//   │ ← Library  [ paste links, press Enter ]   Audio|Video  Format ▾  ⬇ All │
//   │ All 4  Ready 2  Downloading 1  Done 1  Failed 0     📁 H:\Music  Options │
//   ├──────────────────────────────────────────────────────┬───────────────┤
//   │ ▣ Lethal League Blaze      Game OST ▾  Audio  Best ▾  │ options       │
//   │   20 tracks · 1 h 9 min · → H:\Music\Game OSTs\Lethal │               │
//   │   ▾ 01 Beverly Chills — AAron EVO        2:38   done  │               │
//   ├──────────────────────────────────────────────────────┴───────────────┤
//   │ yt-dlp 2026.08.19 · up to date                                        │
//   └──────────────────────────────────────────────────────────────────────┘
//
// Laid out like Stacher, which the owner uses: one box for links, one card per
// link. Each playlist gets its own folder. Every step can be changed before it
// runs: the name (guessed from the playlist, with "OST" and "Soundtrack" taken
// out), the category and so the folder, audio or video, the format, which
// tracks, and each track's title and artist.
//
// The work is done by download_job.py: `probe` reads what a link holds and
// guesses the names, `run` downloads, tags and files. yt-dlp itself is a
// separate program, updated when the app starts and installed into bin\ when
// it is missing.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

Dl_Mode       :: enum u8 { Audio, Video }
Dl_Category   :: enum u8 { Game, Music, Video, Other }
Dl_State      :: enum u8 { Probing, Probe_Failed, Ready, Queued, Running, Done, Stopped }
Dl_Track_State :: enum u8 { Waiting, Downloading, Tagging, Done, Skipped, Failed }
Ytdlp_State   :: enum u8 { Unknown, Updating, Checking, Ready, Missing, Installing, Failed }
Dl_Tool       :: enum u8 { None, Update, Version, Install }

// M4A first, and the default: the owner edits in Premiere, which does not open
// Opus, and "best" on YouTube is Opus. YouTube also serves AAC, which goes
// into the M4A as it is, so the default loses nothing to a conversion.
// Saved files from before (version 1) had "best" first; load_downloads maps.
DL_AUDIO_FORMATS := [?]string{"m4a", "best", "mp3", "flac", "opus", "wav"}
DL_AUDIO_FORMAT_NAMES := [?]cstring{"M4A for Premiere", "Original (Opus)", "MP3 320", "FLAC", "Opus", "WAV"}
DL_AUDIO_FORMAT_TIPS := [?]string{
	"M4A (AAC). Opens in Premiere and everywhere. YouTube's own AAC stream, kept as it is: nothing converted.",
	"The original stream, not converted: on YouTube usually Opus, which Premiere does not open.",
	"MP3 at 320 kbps. Opens everywhere. Converted from the original, so a little is lost.",
	"FLAC. Lossless container for the original sound; large. Premiere does not open it.",
	"Opus. Small and very good; Premiere does not open it.",
	"WAV. Uncompressed; very large, no cover art.",
}
// What the files of each choice end in, to see which files are in another
// format. "" for the original stream, which can be anything.
DL_AUDIO_FORMAT_EXTS := [?]string{".m4a", "", ".mp3", ".flac", ".opus", ".wav"}
DL_VIDEO_QUALITIES := [?]string{"best", "2160", "1440", "1080", "720", "480"}
DL_VIDEO_QUALITY_NAMES := [?]cstring{"Best quality", "4K", "1440p", "1080p", "720p", "480p"}
DL_CATEGORY_NAMES := [Dl_Category]cstring{.Game = "Game OST", .Music = "Music", .Video = "Video", .Other = "Other"}
DL_PATTERNS := [?]string{"auto", "artist-title", "title-artist", "title"}
DL_PATTERN_NAMES := [?]cstring{"Titles: automatic", "Titles: Artist - Title", "Titles: Title - Artist", "Titles: keep whole"}
DL_BROWSERS := [?]string{"", "firefox", "chrome", "edge", "brave", "opera", "vivaldi"}
DL_BROWSER_NAMES := [?]cstring{"No cookies", "Firefox", "Chrome", "Edge", "Brave", "Opera", "Vivaldi"}

Dl_Track :: struct {
	id, url, original, title, artist: string, // owned
	duration: f32,
	number:   int,
	chapter:  int, // 1-based, when the track is a chapter of one long video
	// The same video earlier in the playlist, by position (1-based), or 0.
	// Worked out here, not saved: see dl_mark_duplicates.
	duplicate_of: int,
	// Fetch again in the card's format, replacing the file at `path`.
	replace: bool,
	selected: bool,
	state:    Dl_Track_State,
	pct:      f32,
	speed:    f32,
	eta:      f32,
	path, message: string, // owned
}

Dl_Item :: struct {
	key, url, title, uploader, thumb, year, message: string, // owned
	// One long video with chapters: the tracks are its chapters, and `split`
	// says whether they become separate files or the video stays whole.
	video_id, video_url, video_title: string, // owned
	chapters:      bool,
	split:         bool,
	name, album_artist: Text_Field,
	playlist:      bool,
	category:      Dl_Category,
	mode:          Dl_Mode,
	audio_format:  int,
	video_quality: int,
	premiere:      bool, // H.264 and AAC in MP4, for editing
	pattern:       int,
	state:         Dl_State,
	expanded:      bool,
	tracks:        [dynamic]Dl_Track,
	done, skipped, failed: int,
	texture:       rl.Texture2D,
	texture_tried: bool,
}

// The options' text boxes. Their contents are the settings.
Dl_Field :: enum u8 {
	Root, Folder_Game, Folder_Music, Folder_Video, Folder_Other,
	Name_Audio, Name_Video, Genre, Noise, Rate, Extra,
}

DL_FIELD_DEFAULTS := [Dl_Field]string{
	.Root         = "",
	.Folder_Game  = "Game OSTs/{album}",
	.Folder_Music = "Music/{album}",
	.Folder_Video = "Videos/{album}",
	.Folder_Other = "Downloads/{album}",
	.Name_Audio   = "{track:02} - {title}",
	.Name_Video   = "{title}",
	.Genre        = "Game Soundtrack",
	.Noise        = "",
	.Rate         = "",
	.Extra        = "",
}

Dl_Menu :: enum u8 { None, Category, Format, Header_Format, Pattern, Browser, Parallel }
Dl_Filter :: enum u8 { All, Ready, Active, Done, Failed }

// A file replaced by the same track in another format. The library still
// lists the old one until it is swapped for the new one; see apply_retired.
Dl_Retired :: struct {
	old, new: string, // owned
	until: f64,
}

Dl_Pending_Tag :: struct {
	folder, tag: string, // owned
	until: f64,
}

dl: struct {
	open:          bool,
	loaded:        bool,
	items:         [dynamic]Dl_Item,
	url:           Text_Field,
	fields:        [Dl_Field]Text_Field,
	// Defaults for new links, set from the header.
	mode:          Dl_Mode,
	audio_format:  int,
	video_quality: int,
	premiere:      bool,
	pattern:       int,
	browser:       int,
	parallel:      int,
	cover, square_cover, tags, subtitles: bool,
	add_to_library, game_tag: bool,

	options_open:  bool,
	filter:        Dl_Filter,
	scroll:        Scroll,
	opt_scroll:    Scroll,
	content_h:     f32,
	opt_h:         f32,
	menu:          Context_Menu,
	menu_kind:     Dl_Menu,
	// The one track title being edited, if any.
	edit_item, edit_track: int,
	edit_artist:   bool,
	edit_field:    Text_Field,

	probe:         Stream,
	probing:       bool,
	probe_buf:     [dynamic]u8,
	probe_pending: [dynamic]string,
	probe_urls:    [dynamic]string, // the ones the running probe is reading

	run:           Stream,
	running:       bool,
	stopping:      bool,
	run_buf:       [dynamic]u8,

	tool:          Stream,
	tool_kind:     Dl_Tool,
	tool_buf:      [dynamic]u8,
	ytdlp:         Ytdlp_State,
	ytdlp_version: string,
	ytdlp_note:    string,

	pending_tags:  [dynamic]Dl_Pending_Tag,
	retired:       [dynamic]Dl_Retired,
	save_at:       f64, // when to write downloads.json, 0 for nothing waiting
	next_key:      int,
} = {
	edit_item = -1, edit_track = -1,
	parallel = 3, cover = true, square_cover = true, tags = true,
	add_to_library = true, game_tag = true,
}

// ── finding yt-dlp ──────────────────────────────────────────────────────────

// bin\ beside the app first (where the app installs it), then PATH.
ytdlp_exe :: proc() -> string {
	return tool_path("yt-dlp")
}

@(private="file")
ytdlp_install_target :: proc() -> string {
	return join_path({project_root(), "bin", fmt.tprintf("yt-dlp%s", EXE_SUFFIX)})
}

@(private="file")
ytdlp_release_url :: proc() -> string {
	base := "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
	when ODIN_OS == .Windows {
		return strings.concatenate({base, "yt-dlp.exe"}, context.temp_allocator)
	} else when ODIN_OS == .Darwin {
		return strings.concatenate({base, "yt-dlp_macos"}, context.temp_allocator)
	} else when ODIN_ARCH == .arm64 {
		return strings.concatenate({base, "yt-dlp_linux_aarch64"}, context.temp_allocator)
	} else {
		return strings.concatenate({base, "yt-dlp_linux"}, context.temp_allocator)
	}
}

// The job runs with the AI environment's Python when there is one, and any
// Python 3 otherwise: it needs nothing outside the standard library.
@(private="file")
dl_python :: proc() -> string {
	if os.exists(python_exe()) { return python_exe() }
	when ODIN_OS == .Windows { return "python" } else { return "python3" }
}

@(private="file")
tool_start :: proc(kind: Dl_Tool, args: []string) -> bool {
	clear(&dl.tool_buf)
	s, ok := stream_start(args, background = false)
	if !ok { return false }
	dl.tool = s
	dl.tool_kind = kind
	return true
}

// Called once at start-up: bring yt-dlp up to date, or fetch it.
downloads_startup :: proc() {
	load_downloads()
	dl.ytdlp = .Updating
	set_owned(&dl.ytdlp_note, "Checking for a yt-dlp update...")
	if !tool_start(.Update, {ytdlp_exe(), "-U"}) {
		ytdlp_install()
	}
}

ytdlp_install :: proc() {
	target := ytdlp_install_target()
	bin := join_path({project_root(), "bin"})
	if !os.exists(bin) { _ = os.make_directory(bin) }
	tmp := strings.concatenate({target, ".download"}, context.temp_allocator)
	dl.ytdlp = .Installing
	set_owned(&dl.ytdlp_note, "yt-dlp was not found. Downloading it into bin...")
	// curl ships with Windows 10 and later, macOS and every Linux desktop, so
	// this needs neither Python nor an installer.
	if !tool_start(.Install, {"curl", "-L", "--fail", "-sS", "-o", tmp, ytdlp_release_url()}) {
		dl.ytdlp = .Missing
		set_owned(&dl.ytdlp_note, "yt-dlp is missing and curl could not run. Put yt-dlp in the bin folder.")
	}
}

@(private="file")
poll_tool :: proc() {
	if dl.tool_kind == .None { return }
	buf: [4096]byte
	for {
		n, eof := stream_read(&dl.tool, buf[:])
		if n > 0 { append(&dl.tool_buf, ..buf[:n]); continue }
		if !eof && !stream_finished(&dl.tool) { return }
		break
	}
	code := dl.tool.exit_code
	stream_close(&dl.tool)
	kind := dl.tool_kind
	dl.tool_kind = .None
	out := strings.trim_space(string(dl.tool_buf[:]))

	switch kind {
	case .None:
	case .Update:
		note := "yt-dlp is up to date"
		if strings.contains(out, "Updated yt-dlp to") { note = "yt-dlp was updated" }
		if code != 0 { note = "yt-dlp could not update itself; using the installed version" }
		set_owned(&dl.ytdlp_note, note)
		dl.ytdlp = .Checking
		if !tool_start(.Version, {ytdlp_exe(), "--version"}) { ytdlp_install() }
	case .Version:
		if code == 0 && out != "" {
			set_owned(&dl.ytdlp_version, out)
			dl.ytdlp = .Ready
		} else {
			ytdlp_install()
		}
	case .Install:
		target := ytdlp_install_target()
		tmp := strings.concatenate({target, ".download"}, context.temp_allocator)
		info, err := os.stat(tmp, context.temp_allocator)
		if code != 0 || err != nil || info.size < 1_000_000 {
			_ = os.remove(tmp)
			dl.ytdlp = .Failed
			set_owned(&dl.ytdlp_note, "Could not download yt-dlp. Check the internet connection, or put yt-dlp in the bin folder.")
			return
		}
		_ = os.remove(target)
		if os.rename(tmp, target) != nil {
			dl.ytdlp = .Failed
			set_owned(&dl.ytdlp_note, "Downloaded yt-dlp but could not move it into bin.")
			return
		}
		when ODIN_OS != .Windows { _, _, _ = run_capture({"chmod", "+x", target}, context.temp_allocator) }
		set_owned(&dl.ytdlp_note, "yt-dlp installed into bin")
		dl.ytdlp = .Checking
		if !tool_start(.Version, {target, "--version"}) {
			dl.ytdlp = .Failed
			set_owned(&dl.ytdlp_note, "yt-dlp was downloaded but does not start")
		}
	}
}

ytdlp_busy :: proc() -> bool {
	return dl.ytdlp == .Updating || dl.ytdlp == .Checking || dl.ytdlp == .Installing || dl.ytdlp == .Unknown
}

// ── adding links ────────────────────────────────────────────────────────────

// Every link in a piece of text: one per line, or several on a line.
@(private="file")
links_in :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 8, allocator)
	rest := text
	for len(rest) > 0 {
		cut := strings.index_any(rest, " \t\r\n,;")
		word := cut < 0 ? rest : rest[:cut]
		rest = cut < 0 ? "" : rest[cut + 1:]
		word = strings.trim(word, "\"'<>()[]")
		if strings.has_prefix(word, "http://") || strings.has_prefix(word, "https://") {
			append(&out, word)
		} else if strings.has_prefix(word, "www.") || strings.has_prefix(word, "youtu.be/") ||
		          strings.has_prefix(word, "youtube.com/") || strings.has_prefix(word, "music.youtube.com/") {
			append(&out, strings.concatenate({"https://", word}, allocator))
		}
	}
	return out[:]
}

add_download_links :: proc(text: string) -> int {
	added := 0
	for link in links_in(text) {
		dup := false
		for &it in dl.items { if it.url == link { dup = true; break } }
		if dup { continue }
		it: Dl_Item
		dl.next_key += 1
		it.key = strings.clone(fmt.tprintf("d%d-%d", int(rl.GetTime() * 1000) % 1_000_000, dl.next_key))
		it.url = strings.clone(link)
		it.title = strings.clone(link)
		it.state = .Probing
		it.mode = dl.mode
		it.audio_format = dl.audio_format
		it.video_quality = dl.video_quality
		it.premiere = dl.premiere
		it.pattern = dl.pattern
		it.category = dl.mode == .Video ? .Video : .Game
		append(&dl.items, it)
		append(&dl.probe_pending, strings.clone(link))
		added += 1
	}
	if added > 0 { dl_save_soon() }
	return added
}

@(private="file")
reprobe :: proc(it: ^Dl_Item) {
	it.state = .Probing
	set_owned(&it.message, "")
	append(&dl.probe_pending, strings.clone(it.url))
}

@(private="file")
start_probe :: proc() {
	if dl.probing || len(dl.probe_pending) == 0 || ytdlp_busy() { return }
	args := make([dynamic]string, 0, 16 + len(dl.probe_pending), context.temp_allocator)
	append(&args, dl_python(), join_path({project_root(), "download_job.py"}), "probe",
	       "--ytdlp", ytdlp_exe(), "--ffmpeg", ffmpeg_exe(), "--thumbs", cache_dir("downloads"))
	if b := DL_BROWSERS[dl.browser]; b != "" { append(&args, "--cookies", b) }
	if noise := strings.trim_space(field_string(&dl.fields[.Noise])); noise != "" { append(&args, "--noise", noise) }
	// One pattern per run: links read together share the first one's.
	pattern := dl.pattern
	for &it in dl.items { if it.url == dl.probe_pending[0] { pattern = it.pattern; break } }
	append(&args, "--pattern", DL_PATTERNS[pattern])
	for u in dl.probe_urls { delete(u) }
	clear(&dl.probe_urls)
	for u in dl.probe_pending {
		append(&args, u)
		append(&dl.probe_urls, u)
	}
	clear(&dl.probe_pending)
	clear(&dl.probe_buf)
	s, ok := stream_start(args[:], project_root(), background = false)
	if !ok {
		for u in dl.probe_urls {
			for &it in dl.items {
				if it.url == u && it.state == .Probing {
					it.state = .Probe_Failed
					set_owned(&it.message, "Python did not start. Run setup, or install Python 3.")
				}
			}
		}
		return
	}
	dl.probe = s
	dl.probing = true
}

// Reads whatever complete lines a job has printed so far.
@(private="file")
drain :: proc(s: ^Stream, buf: ^[dynamic]u8, handle: proc(obj: json.Object)) -> (finished: bool) {
	chunk: [16384]byte
	for {
		n, eof := stream_read(s, chunk[:])
		if n > 0 { append(buf, ..chunk[:n]); continue }
		finished = eof || stream_finished(s)
		break
	}
	// Whole lines only; a probe of a long playlist is one line of hundreds of
	// kilobytes and arrives in many reads.
	last := -1
	for i := len(buf) - 1; i >= 0; i -= 1 { if buf[i] == '\n' { last = i; break } }
	if last >= 0 || finished {
		end := finished ? len(buf) : last + 1
		for line in strings.split_lines(string(buf[:end]), context.temp_allocator) {
			if strings.trim_space(line) == "" { continue }
			raw, err := json.parse(transmute([]byte)line, .JSON, false, context.temp_allocator)
			if err != nil { continue }
			if obj, ok := raw.(json.Object); ok { handle(obj) }
		}
		remove_range(buf, 0, end)
	}
	return
}

@(private="file")
json_bool :: proc(obj: json.Object, key: string) -> bool {
	if v, has := obj[key]; has { if b, ok := v.(json.Boolean); ok { return bool(b) } }
	return false
}

@(private="file")
on_probe :: proc(obj: json.Object) {
	if json_str(obj, "event") != "probe" { return }
	url := json_str(obj, "url")
	for &it in dl.items {
		if it.url != url || it.state != .Probing { continue }
		if !json_bool(obj, "ok") {
			it.state = .Probe_Failed
			set_owned(&it.message, json_str(obj, "message"))
			return
		}
		set_owned(&it.title, json_str(obj, "title"))
		set_owned(&it.uploader, json_str(obj, "uploader"))
		set_owned(&it.thumb, json_str(obj, "thumb"))
		set_owned(&it.year, json_str(obj, "year"))
		set_owned(&it.message, "")
		it.playlist = json_str(obj, "kind") == "playlist"
		field_set(&it.name, json_str(obj, "name"))
		field_set(&it.album_artist, json_str(obj, "album_artist"))
		if it.mode == .Audio {
			it.category = json_str(obj, "category") == "game" ? .Game : .Music
		}
		dl_clear_tracks(&it)
		// Each entry: the title as uploaded ("original") and the one read
		// out of it ("title", "artist", "track"); see download_job.py.
		if v, has := obj["entries"]; has {
			if arr, ok := v.(json.Array); ok {
				for e in arr {
					eo, is_obj := e.(json.Object)
					if !is_obj { continue }
					t: Dl_Track
					t.id = strings.clone(json_str(eo, "id"))
					t.url = strings.clone(json_str(eo, "url"))
					t.original = strings.clone(json_str(eo, "original"))
					title := json_str(eo, "title")
					t.title = strings.clone(title != "" ? title : json_str(eo, "id"))
					t.artist = strings.clone(json_str(eo, "artist"))
					t.duration = f32(json_num(eo, "duration"))
					t.number = int(json_num(eo, "track"))
					t.selected = true
					append(&it.tracks, t)
				}
			}
		}
		set_owned(&it.video_id, json_str(obj, "id"))
		set_owned(&it.video_url, "")
		set_owned(&it.video_title, "")
		if len(it.tracks) > 0 {
			set_owned(&it.video_url, it.tracks[0].url)
			set_owned(&it.video_title, it.tracks[0].title)
		}
		it.chapters = false
		if v, has := obj["chapters"]; has && !it.playlist {
			if arr, ok := v.(json.Array); ok && len(arr) >= 2 {
				dl_clear_tracks(&it)
				for e in arr {
					eo, is_obj := e.(json.Object)
					if !is_obj { continue }
					t: Dl_Track
					t.id = strings.clone(json_str(eo, "id"))
					t.url = strings.clone(json_str(eo, "url"))
					t.original = strings.clone(json_str(eo, "original"))
					t.title = strings.clone(json_str(eo, "title"))
					t.artist = strings.clone(json_str(eo, "artist"))
					t.duration = f32(json_num(eo, "duration"))
					t.number = int(json_num(eo, "track"))
					t.chapter = int(json_num(eo, "chapter"))
					t.selected = true
					append(&it.tracks, t)
				}
				it.chapters = true
				it.split = true
			}
		}
		dl_mark_duplicates(&it, true)
		// One video on its own is not track 1 of anything.
		if !it.playlist && !it.chapters { for &t in it.tracks { t.number = 0 } }
		it.state = .Ready
		dl_save_soon()
		return
	}
}

// The card's line once a run ends: files, and why the count is not the
// playlist's length when it is not.
dl_set_summary :: proc(it: ^Dl_Item) {
	files, repeats := 0, 0
	for &t in it.tracks {
		if t.duplicate_of > 0 { repeats += 1; continue }
		if (t.state == .Done || t.state == .Skipped) && t.path != "" { files += 1 }
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "%d files", files)
	if repeats > 0 { fmt.sbprintf(&b, " (%d videos are in the playlist twice)", repeats) }
	if it.failed > 0 { fmt.sbprintf(&b, ", %d failed", it.failed) }
	set_owned(&it.message, strings.to_string(b))
}

// Marks each video that already appeared earlier on the card. With `untick`,
// repeats not yet downloaded are unticked (a fresh probe, or a queue saved
// before this existed): downloading one would only find its first copy.
dl_mark_duplicates :: proc(it: ^Dl_Item, untick: bool) {
	first := make(map[string]int, len(it.tracks), context.temp_allocator)
	for &t, i in it.tracks {
		t.duplicate_of = 0
		if t.id == "" { continue }
		if at, seen := first[t.id]; seen {
			t.duplicate_of = at + 1
			if untick && t.state != .Done {
				t.selected = false
				if t.state == .Skipped || t.state == .Waiting { t.state = .Waiting }
			}
		} else {
			first[t.id] = i
		}
	}
}

@(private="file")
dl_clear_tracks :: proc(it: ^Dl_Item) {
	for &t in it.tracks {
		delete(t.id); delete(t.url); delete(t.original); delete(t.title)
		delete(t.artist); delete(t.path); delete(t.message)
	}
	clear(&it.tracks)
}

@(private="file")
dl_free_item :: proc(it: ^Dl_Item) {
	dl_clear_tracks(it)
	delete(it.tracks)
	delete(it.key); delete(it.url); delete(it.title); delete(it.uploader)
	delete(it.thumb); delete(it.year); delete(it.message)
	delete(it.video_id); delete(it.video_url); delete(it.video_title)
	delete(it.name.buf); delete(it.album_artist.buf)
	if it.texture.id != 0 { rl.UnloadTexture(it.texture) }
}

// ── where things go ─────────────────────────────────────────────────────────

// A name every file system accepts. Forbidden characters become their
// full-width look-alikes, as yt-dlp and download_job.py do.
dl_safe_name :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for c in s {
		switch c {
		case '<':  strings.write_rune(&b, '＜')
		case '>':  strings.write_rune(&b, '＞')
		case ':':  strings.write_rune(&b, '：')
		case '"':  strings.write_rune(&b, '＂')
		case '/':  strings.write_rune(&b, '⧸')
		case '\\': strings.write_rune(&b, '⧹')
		case '|':  strings.write_rune(&b, '｜')
		case '?':  strings.write_rune(&b, '？')
		case '*':  strings.write_rune(&b, '＊')
		case:
			if c >= 32 { strings.write_rune(&b, c) }
		}
	}
	out := strings.trim_right(strings.trim_space(strings.to_string(b)), ". ")
	return out == "" ? "_" : out
}

dl_root :: proc() -> string {
	return strings.trim_space(field_string(&dl.fields[.Root]))
}

@(private="file")
category_field :: proc(c: Dl_Category) -> Dl_Field {
	switch c {
	case .Game:  return .Folder_Game
	case .Music: return .Folder_Music
	case .Video: return .Folder_Video
	case .Other: return .Folder_Other
	}
	return .Folder_Other
}

// The folder a card's files go into: the root, then the category's template
// with {album}, {artist}, {uploader}, {year} and {playlist} filled in.
dl_folder :: proc(it: ^Dl_Item, allocator := context.temp_allocator) -> string {
	template := field_string(&dl.fields[category_field(it.category)])
	if strings.trim_space(template) == "" { template = "{album}" }
	album := strings.trim_space(field_string(&it.name))
	if album == "" { album = it.title }
	artist := strings.trim_space(field_string(&it.album_artist))
	if artist == "" { artist = it.uploader }
	b := strings.builder_make(context.temp_allocator)
	rest := template
	for len(rest) > 0 {
		open := strings.index_byte(rest, '{')
		if open < 0 { strings.write_string(&b, rest); break }
		close := strings.index_byte(rest[open:], '}')
		if close < 0 { strings.write_string(&b, rest); break }
		strings.write_string(&b, rest[:open])
		key := rest[open + 1:open + close]
		if colon := strings.index_byte(key, ':'); colon >= 0 { key = key[:colon] }
		switch key {
		case "album", "game", "name": strings.write_string(&b, dl_safe_name(album))
		case "artist", "album_artist": strings.write_string(&b, dl_safe_name(artist))
		case "uploader", "channel":   strings.write_string(&b, dl_safe_name(it.uploader))
		case "year":                  strings.write_string(&b, it.year)
		case "playlist", "title":     strings.write_string(&b, dl_safe_name(it.title))
		}
		rest = rest[open + close + 1:]
	}
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&parts, dl_root())
	for p in strings.split_multi(strings.to_string(b), {"/", "\\"}, context.temp_allocator) {
		p := strings.trim_space(p)
		if p != "" && p != "." && p != ".." { append(&parts, p) }
	}
	return join_path(parts[:], allocator)
}

// ── running ─────────────────────────────────────────────────────────────────

Dl_Plan_Track :: struct {
	id, url, title, artist: string,
	track, chapter: int,
	uid: int, // the track's position on the card: ids repeat in playlists
	replace: string, // the file a new format replaces, or ""
}

Dl_Plan_Item :: struct {
	key, url, mode, audio_format, audio_quality, video_quality, video_codec: string,
	folder, filename, album, album_artist, genre, year: string,
	disc, total: int,
	embed_thumb, square_cover, metadata, subtitles: bool,
	split_chapters: bool,
	video_id, video_url: string,
	tracks: []Dl_Plan_Track,
}

Dl_Plan :: struct {
	ytdlp, ffmpeg, staging, manifest, cookies, rate, extra: string,
	parallel: int,
	items: []Dl_Plan_Item,
}

@(private="file")
start_run :: proc() {
	if dl.running || ytdlp_busy() { return }
	if dl.ytdlp != .Ready { return }
	items := make([dynamic]Dl_Plan_Item, 0, 8, context.temp_allocator)
	for &it in dl.items {
		if it.state != .Queued { continue }
		tracks := make([dynamic]Dl_Plan_Track, 0, len(it.tracks), context.temp_allocator)
		for &t, ti in it.tracks {
			if t.replace && t.path != "" {
				append(&tracks, Dl_Plan_Track{t.id, t.url, t.title, t.artist, t.number, t.chapter, ti, t.path})
			} else {
				if !t.selected || t.state == .Done || t.state == .Skipped { continue }
				append(&tracks, Dl_Plan_Track{t.id, t.url, t.title, t.artist, t.number, t.chapter, ti, ""})
			}
			t.state = .Waiting
			t.pct = 0
			set_owned(&t.message, "")
		}
		// Kept whole: one file, named after the card.
		if it.chapters && !it.split {
			clear(&tracks)
			title := strings.trim_space(field_string(&it.name))
			if it.video_title != "" && it.video_title != title { title = it.video_title }
			append(&tracks, Dl_Plan_Track{it.video_id, it.video_url, title, "", 0, 0, -1, ""})
		}
		fmt_index := clamp(it.audio_format, 0, len(DL_AUDIO_FORMATS) - 1)
		genre := it.category == .Game ? strings.trim_space(field_string(&dl.fields[.Genre])) : ""
		append(&items, Dl_Plan_Item{
			key           = it.key,
			url           = it.url,
			mode          = it.mode == .Audio ? "audio" : "video",
			audio_format  = DL_AUDIO_FORMATS[fmt_index],
			// MP3 at 320; M4A at 256 only when it has to be converted (YouTube's
			// own AAC is kept as it is).
			audio_quality = DL_AUDIO_FORMATS[fmt_index] == "mp3" ? "320K" : (DL_AUDIO_FORMATS[fmt_index] == "m4a" ? "256K" : "0"),
			video_quality = DL_VIDEO_QUALITIES[clamp(it.video_quality, 0, len(DL_VIDEO_QUALITIES) - 1)],
			video_codec   = it.premiere ? "premiere" : "any",
			folder        = dl_folder(&it),
			filename      = field_string(&dl.fields[it.mode == .Audio ? .Name_Audio : .Name_Video]),
			album         = strings.trim_space(field_string(&it.name)),
			album_artist  = strings.trim_space(field_string(&it.album_artist)),
			genre         = genre,
			year          = it.year,
			total         = it.playlist || (it.chapters && it.split) ? len(it.tracks) : 0,
			split_chapters = it.chapters && it.split,
			video_id      = it.video_id,
			video_url     = it.video_url,
			embed_thumb   = dl.cover,
			square_cover  = dl.square_cover,
			metadata      = dl.tags,
			subtitles     = dl.subtitles,
			tracks        = tracks[:],
		})
		it.state = .Running
		it.done = 0
		it.skipped = 0
		it.failed = 0
	}
	if len(items) == 0 { return }
	plan := Dl_Plan{
		ytdlp    = ytdlp_exe(),
		ffmpeg   = ffmpeg_exe(),
		staging  = join_path({cache_dir("downloads"), "incoming"}),
		manifest = join_path({cache_dir("downloads"), "done.json"}),
		cookies  = DL_BROWSERS[dl.browser],
		rate     = strings.trim_space(field_string(&dl.fields[.Rate])),
		extra    = strings.trim_space(field_string(&dl.fields[.Extra])),
		parallel = dl.parallel,
		items    = items[:],
	}
	data, err := json.marshal(plan, {}, context.temp_allocator)
	plan_path := join_path({cache_dir("downloads"), "plan.json"})
	if err != nil || os.write_entire_file(plan_path, data) != nil {
		dl_fail_running("Could not write the download plan")
		return
	}
	clear(&dl.run_buf)
	s, ok := stream_start({dl_python(), join_path({project_root(), "download_job.py"}), "run",
	                       "--plan", plan_path, "--watch-stdin"}, project_root(), true, background = false)
	if !ok {
		dl_fail_running("Python did not start. Run setup, or install Python 3.")
		return
	}
	dl.run = s
	dl.running = true
	dl.stopping = false
}

@(private="file")
dl_fail_running :: proc(message: string) {
	for &it in dl.items {
		if it.state == .Running {
			it.state = .Stopped
			set_owned(&it.message, message)
		}
	}
}

stop_downloads :: proc() {
	if dl.running && !dl.stopping {
		// The job stops its own yt-dlp and ffmpeg; killing only Python would
		// leave them writing.
		_ = stream_write(&dl.run, transmute([]byte)string("stop\n"))
		stream_close_stdin(&dl.run)
		dl.stopping = true
	}
}

// At exit: ask nicely, then make sure.
shutdown_downloads :: proc() {
	save_downloads()
	if dl.running {
		stop_downloads()
		for _ in 0 ..< 40 {
			if stream_finished(&dl.run) { break }
			time.sleep(50 * time.Millisecond)
		}
		stream_kill(&dl.run)
		stream_close(&dl.run)
		dl.running = false
	}
	if dl.probing { stream_kill(&dl.probe); stream_close(&dl.probe); dl.probing = false }
	if dl.tool_kind != .None { stream_kill(&dl.tool); stream_close(&dl.tool); dl.tool_kind = .None }
}

@(private="file")
find_item :: proc(key: string) -> ^Dl_Item {
	for &it in dl.items { if it.key == key { return &it } }
	return nil
}

@(private="file")
on_run :: proc(obj: json.Object) {
	switch json_str(obj, "event") {
	case "track":
		it := find_item(json_str(obj, "key"))
		if it == nil { return }
		id := json_str(obj, "id")
		whole := it.chapters && !it.split && id == it.video_id
		// By position when the job says it: a playlist can hold the same
		// video twice, and matching by id updated the first copy twice and
		// left the second waiting forever.
		uid, has_uid := json_int(obj, "uid")
		for &t, ti in it.tracks {
			if has_uid && uid >= 0 && !whole {
				if ti != uid { continue }
			} else if (t.id != id && !whole) || !t.selected {
				continue
			}
			switch json_str(obj, "state") {
			case "downloading":
				t.state = .Downloading
				t.pct = f32(json_num(obj, "pct"))
				t.speed = f32(json_num(obj, "speed"))
				t.eta = f32(json_num(obj, "eta"))
			case "tagging":
				t.state = .Tagging
				t.pct = 100
			case "done":
				t.state = .Done
				t.pct = 100
				t.replace = false
				if json_str(obj, "replaced") == "recycled" && t.path != "" {
					append(&dl.retired, Dl_Retired{strings.clone(t.path), strings.clone(json_str(obj, "path")), rl.GetTime() + 600})
				}
				set_owned(&t.path, json_str(obj, "path"))
				if json_str(obj, "replaced") == "kept" {
					set_owned(&t.message, "The old file could not go to the Recycle Bin; it is still beside the new one.")
				}
			case "skipped":
				t.state = .Skipped
				t.pct = 100
				t.replace = false
				set_owned(&t.path, json_str(obj, "path"))
			case "error":
				t.state = .Failed
				set_owned(&t.message, json_str(obj, "message"))
			}
			if !whole { break }
		}
		it.done, it.skipped, it.failed = 0, 0, 0
		for &t in it.tracks {
			#partial switch t.state {
			case .Done:    it.done += 1
			case .Skipped: it.skipped += 1
			case .Failed:  it.failed += 1
			}
		}
	case "item":
		it := find_item(json_str(obj, "key"))
		if it == nil || json_str(obj, "state") != "done" { return }
		it.state = .Done
		folder := json_str(obj, "folder")
		dl_set_summary(it)
		dl_after_item(it, folder)
		dl_save_soon()
	case "error":
		dl_fail_running(json_str(obj, "message"))
	}
}

// Into the library, and the game tag waiting for the scan.
@(private="file")
dl_after_item :: proc(it: ^Dl_Item, folder: string) {
	if it.done == 0 || folder == "" { return }
	if !dl.add_to_library { return }
	if lib.root == "" || !path_under_root(lib.root, folder) {
		toast(fmt.tprintf("%s saved to %s (not inside the open library)", field_string(&it.name), folder))
		return
	}
	queue_folder_import(folder)
	if dl.game_tag && it.category == .Game && it.mode == .Audio {
		name := strings.trim_space(field_string(&it.name))
		if name == "" { return }
		tag := tag_for_game_words(tokenise(strings.concatenate({name, ".x"}, context.temp_allocator)), name)
		if tag == "" { return }
		append(&dl.pending_tags, Dl_Pending_Tag{strings.clone(folder), strings.clone(tag), rl.GetTime() + 600})
	}
}

// Once the scan has the new files, they get their game tag — in memory, like
// any tag added by hand. Save writes it, as with everything else.
@(private="file")
apply_pending_tags :: proc() {
	if len(dl.pending_tags) == 0 || scan.running || len(import_folder_queue) > 0 { return }
	for i := len(dl.pending_tags) - 1; i >= 0; i -= 1 {
		p := dl.pending_tags[i]
		tagged := 0
		for &t in lib.tracks {
			if !path_under_root(p.folder, t.path) { continue }
			has_game := false
			for existing in t.tags { if tag_kind(existing) == .Game { has_game = true; break } }
			if has_game { continue }
			if group_of_tag(p.tag) == nil { create_tag("Game", p.tag) }
			add_tag_to_track(&t, p.tag)
			tagged += 1
		}
		if tagged > 0 || rl.GetTime() > p.until {
			if tagged > 0 {
				count_tags()
				search.dirty = true
				toast(fmt.tprintf("%s added to %d new files. Press Save to write it.", p.tag, tagged))
			}
			delete(p.folder)
			delete(p.tag)
			ordered_remove(&dl.pending_tags, i)
		}
	}
}

// Once the scan has the new file, the old entry hands over its tags and
// markers, saved or not, and leaves the library. Without this the library kept
// listing the Opus files after they went to the Recycle Bin, and Save would
// have written sidecars for files that are not there.
@(private="file")
apply_retired :: proc() {
	if len(dl.retired) == 0 || scan.running || len(import_folder_queue) > 0 { return }
	by_path := make(map[string]int, len(lib.tracks), context.temp_allocator)
	for &t, i in lib.tracks { by_path[path_key(t.path)] = i }
	gone := make([dynamic]int, 0, len(dl.retired), context.temp_allocator)
	moved := 0
	for i := len(dl.retired) - 1; i >= 0; i -= 1 {
		r := dl.retired[i]
		old_i, has_old := by_path[path_key(r.old)]
		new_i, has_new := by_path[path_key(r.new)]
		if has_old && !has_new && rl.GetTime() < r.until { continue } // the scan is still to come
		if has_old && has_new && !os.exists(r.old) {
			old_t, new_t := &lib.tracks[old_i], &lib.tracks[new_i]
			for tag in old_t.tags {
				already := false
				for have in new_t.tags { if have == tag { already = true; break } }
				if !already { add_tag_to_track(new_t, tag) }
			}
			if len(new_t.cues) == 0 && len(old_t.cues) > 0 {
				for c in old_t.cues { append(&new_t.cues, c) }
				new_t.cues_dirty = true
			}
			moved += 1
		}
		if has_old && !os.exists(r.old) { append(&gone, old_i) }
		delete(r.old)
		delete(r.new)
		ordered_remove(&dl.retired, i)
	}
	if len(gone) == 0 { return }
	slice.sort(gone[:])
	slice.reverse(gone[:])
	for index in gone { forget_track(index) }
	clear(&app.selection)
	app.selected = -1
	app.anchor = -1
	if player.track >= len(lib.tracks) { stop_playback() }
	count_tags()
	search.dirty = true
	invalidate_tagging()
	invalidate_nodes()
	toast(fmt.tprintf("%d files replaced by their new format; tags moved to them", moved))
}

// ── each frame ──────────────────────────────────────────────────────────────

poll_downloads :: proc() {
	poll_tool()
	if dl.probing && drain(&dl.probe, &dl.probe_buf, on_probe) {
		stream_close(&dl.probe)
		dl.probing = false
		// Anything the probe did not answer for failed without a word.
		for u in dl.probe_urls {
			for &it in dl.items {
				if it.url == u && it.state == .Probing {
					it.state = .Probe_Failed
					set_owned(&it.message, "Could not read this link")
				}
			}
		}
	}
	start_probe()
	if dl.running && drain(&dl.run, &dl.run_buf, on_run) {
		stream_close(&dl.run)
		dl.running = false
		stopped := dl.stopping
		dl.stopping = false
		for &it in dl.items {
			if it.state == .Running {
				it.state = .Stopped
				set_owned(&it.message, stopped ? "Stopped. Resume fetches what is missing." : "The download job ended early")
			}
			for &t in it.tracks {
				if t.state == .Downloading || t.state == .Tagging { t.state = .Waiting }
			}
		}
		dl_save_soon()
	}
	start_run()
	apply_retired()
	apply_pending_tags()
	if dl.save_at > 0 && rl.GetTime() > dl.save_at { save_downloads() }
}

downloads_active :: proc() -> int {
	n := 0
	for &it in dl.items { if it.state == .Running || it.state == .Queued || it.state == .Probing { n += 1 } }
	return n
}

// ── saving the queue ────────────────────────────────────────────────────────

Dl_Saved_Track :: struct {
	id, url, original, title, artist, path: string,
	duration: f32,
	number, state, chapter: int,
	selected, replace: bool,
}

Dl_Saved_Item :: struct {
	key, url, title, uploader, thumb, year, name, album_artist, message: string,
	video_id, video_url, video_title: string,
	playlist, premiere, expanded, chapters, split: bool,
	category, mode, audio_format, video_quality, pattern, state: int,
	done, skipped, failed: int,
	tracks: []Dl_Saved_Track,
}

Dl_Saved :: struct {
	version: int,
	fields: map[string]string,
	mode, audio_format, video_quality, pattern, browser, parallel: int,
	premiere, cover, square_cover, tags, subtitles, add_to_library, game_tag, options_open: bool,
	items: []Dl_Saved_Item,
}

@(private="file")
downloads_path :: proc() -> string {
	return join_path({project_root(), "downloads.json"})
}

dl_save_soon :: proc() {
	if dl.save_at == 0 { dl.save_at = rl.GetTime() + 1.0 }
}

save_downloads :: proc() {
	dl.save_at = 0
	if !dl.loaded { return }
	s: Dl_Saved
	s.version = 2 // 2: M4A first in the audio formats
	s.fields = make(map[string]string, 16, context.temp_allocator)
	for f in Dl_Field { s.fields[fmt.tprint(f)] = field_string(&dl.fields[f]) }
	s.mode = int(dl.mode); s.audio_format = dl.audio_format; s.video_quality = dl.video_quality
	s.pattern = dl.pattern; s.browser = dl.browser; s.parallel = dl.parallel
	s.premiere = dl.premiere; s.cover = dl.cover; s.square_cover = dl.square_cover; s.tags = dl.tags
	s.subtitles = dl.subtitles; s.add_to_library = dl.add_to_library; s.game_tag = dl.game_tag
	s.options_open = dl.options_open
	items := make([]Dl_Saved_Item, len(dl.items), context.temp_allocator)
	for &it, i in dl.items {
		tracks := make([]Dl_Saved_Track, len(it.tracks), context.temp_allocator)
		for &t, j in it.tracks {
			tracks[j] = {t.id, t.url, t.original, t.title, t.artist, t.path, t.duration, t.number, int(t.state), t.chapter, t.selected, t.replace}
		}
		items[i] = {
			it.key, it.url, it.title, it.uploader, it.thumb, it.year,
			field_string(&it.name), field_string(&it.album_artist), it.message,
			it.video_id, it.video_url, it.video_title,
			it.playlist, it.premiere, it.expanded, it.chapters, it.split,
			int(it.category), int(it.mode), it.audio_format, it.video_quality, it.pattern, int(it.state),
			it.done, it.skipped, it.failed, tracks,
		}
	}
	s.items = items
	data, err := json.marshal(s, {pretty = true}, context.temp_allocator)
	if err != nil { return }
	tmp := strings.concatenate({downloads_path(), ".tmp"}, context.temp_allocator)
	if os.write_entire_file(tmp, data) == nil {
		_ = os.remove(downloads_path())
		_ = os.rename(tmp, downloads_path())
	}
}

// A saved audio format, as an index into today's list. Version 1 saved them in
// the order best, mp3, flac, m4a, opus, wav; "best" (Opus on YouTube) becomes
// M4A, because Premiere cannot open Opus and that is what the owner hit.
@(private="file")
dl_audio_format_from :: proc(saved, version: int) -> int {
	if version >= 2 { return clamp(saved, 0, len(DL_AUDIO_FORMATS) - 1) }
	old_to_new := [6]int{0, 2, 3, 0, 4, 5}
	return old_to_new[clamp(saved, 0, 5)]
}

load_downloads :: proc() {
	defer dl.loaded = true
	for f in Dl_Field { field_set(&dl.fields[f], DL_FIELD_DEFAULTS[f]) }
	data, err := os.read_entire_file(downloads_path(), context.temp_allocator)
	if err != nil { return }
	s: Dl_Saved
	s.parallel = 3
	if json.unmarshal(data, &s, allocator = context.temp_allocator) != nil { return }
	for f in Dl_Field {
		if v, ok := s.fields[fmt.tprint(f)]; ok { field_set(&dl.fields[f], v) }
	}
	dl.mode = Dl_Mode(clamp(s.mode, 0, 1))
	dl.audio_format = dl_audio_format_from(s.audio_format, s.version)
	dl.video_quality = clamp(s.video_quality, 0, len(DL_VIDEO_QUALITIES) - 1)
	dl.pattern = clamp(s.pattern, 0, len(DL_PATTERNS) - 1)
	dl.browser = clamp(s.browser, 0, len(DL_BROWSERS) - 1)
	dl.parallel = clamp(s.parallel, 1, 8)
	dl.premiere = s.premiere; dl.cover = s.cover; dl.square_cover = s.square_cover; dl.tags = s.tags
	dl.subtitles = s.subtitles; dl.add_to_library = s.add_to_library; dl.game_tag = s.game_tag
	dl.options_open = s.options_open
	for &si in s.items {
		it: Dl_Item
		it.key = strings.clone(si.key); it.url = strings.clone(si.url); it.title = strings.clone(si.title)
		it.uploader = strings.clone(si.uploader); it.thumb = strings.clone(si.thumb)
		it.year = strings.clone(si.year); it.message = strings.clone(si.message)
		field_set(&it.name, si.name)
		field_set(&it.album_artist, si.album_artist)
		it.playlist = si.playlist; it.premiere = si.premiere; it.expanded = si.expanded
		it.chapters = si.chapters; it.split = si.split
		it.video_id = strings.clone(si.video_id); it.video_url = strings.clone(si.video_url)
		it.video_title = strings.clone(si.video_title)
		it.category = Dl_Category(clamp(si.category, 0, len(Dl_Category) - 1))
		it.mode = Dl_Mode(clamp(si.mode, 0, 1))
		it.audio_format = dl_audio_format_from(si.audio_format, s.version)
		it.video_quality = clamp(si.video_quality, 0, len(DL_VIDEO_QUALITIES) - 1)
		it.pattern = clamp(si.pattern, 0, len(DL_PATTERNS) - 1)
		it.state = Dl_State(clamp(si.state, 0, len(Dl_State) - 1))
		it.done, it.skipped, it.failed = si.done, si.skipped, si.failed
		for &st in si.tracks {
			t: Dl_Track
			t.id = strings.clone(st.id); t.url = strings.clone(st.url); t.original = strings.clone(st.original)
			t.title = strings.clone(st.title); t.artist = strings.clone(st.artist); t.path = strings.clone(st.path)
			t.duration = st.duration; t.number = st.number; t.selected = st.selected; t.chapter = st.chapter
			t.replace = st.replace
			t.state = Dl_Track_State(clamp(st.state, 0, len(Dl_Track_State) - 1))
			if t.state == .Downloading || t.state == .Tagging { t.state = .Waiting }
			append(&it.tracks, t)
		}
		dl_mark_duplicates(&it, true)
		if it.state == .Done { dl_set_summary(&it) }
		// Work cut off by closing the app waits to be resumed, not restarted
		// behind the owner's back.
		switch it.state {
		case .Running, .Queued:
			it.state = .Stopped
			set_owned(&it.message, "Stopped when the app closed. Resume fetches what is missing.")
		case .Probing:
			append(&dl.probe_pending, strings.clone(it.url))
		case .Probe_Failed, .Ready, .Done, .Stopped:
		}
		append(&dl.items, it)
	}
}

// ── drawing ─────────────────────────────────────────────────────────────────

DL_HEADER_H :: 62.0
DL_BAR_H    :: 40.0
DL_STATUS_H :: 26.0
DL_OPTIONS_W :: 340.0
DL_CARD_H   :: 112.0
DL_TRACK_H  :: 26.0

// The whole screen, in place of the library's panels.
draw_downloads :: proc(r: Rect) {
	fill(r, BG)
	header := rect(r.x, r.y, r.width, px(DL_HEADER_H))
	bar := rect(r.x, header.y + header.height, r.width, px(DL_BAR_H))
	status := rect(r.x, r.y + r.height - px(DL_STATUS_H), r.width, px(DL_STATUS_H))
	body_y := bar.y + bar.height
	body_h := status.y - body_y
	opt_w := dl.options_open ? min(px(DL_OPTIONS_W), r.width * 0.45) : 0
	list := rect(r.x, body_y, r.width - opt_w, body_h)
	options := rect(r.x + r.width - opt_w, body_y, opt_w, body_h)

	draw_dl_header(header)
	draw_dl_bar(bar)
	draw_dl_list(list)
	if opt_w > 0 { draw_dl_options(options) }
	draw_dl_status(status)
	hline(r.x, bar.y, r.width)
	hline(r.x, body_y, r.width)
	hline(r.x, status.y, r.width)
	if opt_w > 0 { vline(options.x, body_y, body_h) }

	if dl.menu.open {
		begin_modal()
		draw_dl_menu()
		end_modal()
	}

	// Escape goes back to the library when nothing is being typed.
	if rl.IsKeyPressed(.ESCAPE) && ui.focus == nil && !dl.menu.open { dl.open = false }
	// Ctrl V anywhere on the screen adds the links on the clipboard, as in
	// Stacher, without clicking into the box first.
	ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
	if ctrl && rl.IsKeyPressed(.V) && (ui.focus == nil || ui.focus == rawptr(&dl.url)) {
		clip := string(rl.GetClipboardText())
		if n := add_download_links(clip); n > 0 {
			field_set(&dl.url, "")
			toast(n == 1 ? "1 link added" : fmt.tprintf("%d links added", n))
		}
	}
}

@(private="file")
segmented :: proc(r: Rect, labels: []cstring, current: int) -> int {
	fill_round(r, PANEL_2)
	outline_round(r, LINE)
	cell_w := r.width / f32(len(labels))
	chosen := -1
	for label, i in labels {
		cell := rect(r.x + cell_w * f32(i), r.y, cell_w, r.height)
		on := i == current
		if on { fill_round(inset(cell, px(2)), ACCENT_DK, 4) }
		else if hovered(cell) { ui.hover_cursor = .POINTING_HAND }
		tw := text_w(.Regular, label, FS_SMALL)
		draw_text_mid(.Regular, label, cell.x + (cell.width - tw) * 0.5, cell.y, cell.height, FS_SMALL, on ? ACCENT : TEXT_DIM)
		if clicked_in(cell) { chosen = i }
	}
	return chosen
}

// A button that opens a menu: label and a small caret.
@(private="file")
drop_button :: proc(r: Rect, label: cstring, enabled := true) -> bool {
	clicked := button(r, "", .Normal, enabled)
	draw_text_mid(.Regular, label, r.x + px(10), r.y, r.height, FS_SMALL, enabled ? TEXT : TEXT_FAINT)
	draw_icon(.Caret_Down, rect(r.x + r.width - px(20), r.y + (r.height - px(14)) * 0.5, px(14), px(14)), TEXT_DIM)
	return clicked
}

@(private="file")
open_dl_menu :: proc(kind: Dl_Menu, subject: int) {
	dl.menu_kind = kind
	open_context_menu(&dl.menu, subject)
}

@(private="file")
format_label :: proc(mode: Dl_Mode, audio_format, video_quality: int, premiere: bool) -> cstring {
	if mode == .Audio { return DL_AUDIO_FORMAT_NAMES[audio_format] }
	q := DL_VIDEO_QUALITY_NAMES[video_quality]
	return premiere ? fmt.ctprintf("%s · MP4", q) : q
}

@(private="file")
draw_dl_header :: proc(r: Rect) {
	fill(r, PANEL)
	cy := r.y + (r.height - px(36)) * 0.5
	x := r.x + px(PAD)

	back := rect(x, cy + px(4), px(96), px(28))
	tip(back, "Back to the library (Esc)")
	if button(back, "", .Ghost) { dl.open = false }
	draw_icon(.Prev, rect(back.x + px(4), back.y, px(18), back.height), TEXT_DIM)
	draw_text_mid(.Regular, "Library", back.x + px(26), back.y, back.height, FS_BODY, TEXT_DIM)
	x += back.width + px(GAP)

	// From the right edge inward.
	edge := r.x + r.width - px(PAD)
	all_w := px(140)
	ready := 0
	for &it in dl.items { if it.state == .Ready || it.state == .Stopped { ready += 1 } }
	all := rect(edge - all_w, cy + px(2), all_w, px(32))
	tip(all, "Download every card that is ready, one folder per link")
	if icon_label_button(all, .Import, ready > 0 ? fmt.ctprintf("Download %d", ready) : "Download all", .Primary, ready > 0) {
		dl_queue_all()
	}
	edge = all.x - px(GAP)

	fmt_w := px(132)
	f := rect(edge - fmt_w, cy + px(4), fmt_w, px(28))
	tip(f, "Format for new links, and for every card not yet started")
	if drop_button(f, format_label(dl.mode, dl.audio_format, dl.video_quality, dl.premiere)) {
		open_dl_menu(.Header_Format, -1)
	}
	edge = f.x - px(GAP)

	mode_w := px(124)
	m := rect(edge - mode_w, cy + px(4), mode_w, px(28))
	tip(m, "Audio or video, for new links and every card not yet started")
	if pick := segmented(m, {"Audio", "Video"}, int(dl.mode)); pick >= 0 {
		dl.mode = Dl_Mode(pick)
		for &it in dl.items {
			if it.state == .Ready || it.state == .Probing || it.state == .Probe_Failed {
				it.mode = dl.mode
				if dl.mode == .Video && it.category == .Game { it.category = .Video }
				if dl.mode == .Audio && it.category == .Video { it.category = .Game }
			}
		}
		dl_save_soon()
	}
	edge = m.x - px(GAP * 2)

	// The link box takes the rest.
	box := rect(x, cy, edge - x, px(36))
	focused := ui.focus == rawptr(&dl.url)
	fill_round(box, PANEL_2, 6)
	outline_round(box, focused ? ACCENT : LINE, 6)
	draw_icon(.Plus, rect(box.x + px(8), box.y, px(18), box.height), TEXT_FAINT)
	field := rect(box.x + px(32), box.y, box.width - px(40), box.height)
	_ = text_field(&dl.url, field, "Paste links and press Enter: playlists, videos, several at once")
	if focused && enter_pressed() {
		text := field_string(&dl.url)
		if n := add_download_links(text); n > 0 {
			field_set(&dl.url, "")
		} else if strings.trim_space(text) != "" {
			toast("That is not a link. Links start with https://")
		}
	}
}

@(private="file")
dl_matches :: proc(it: ^Dl_Item, f: Dl_Filter) -> bool {
	switch f {
	case .All:    return true
	case .Ready:  return it.state == .Ready || it.state == .Stopped || it.state == .Probing
	case .Active: return it.state == .Queued || it.state == .Running
	case .Done:   return it.state == .Done
	case .Failed: return it.state == .Probe_Failed || it.failed > 0
	}
	return true
}

@(private="file")
dl_queue_all :: proc() {
	if !dl_have_root() { return }
	for &it in dl.items {
		if it.state == .Ready || it.state == .Stopped { it.state = .Queued }
	}
	dl_save_soon()
}

// The first download asks where downloads go; nothing is written anywhere
// the owner has not chosen.
@(private="file")
dl_have_root :: proc() -> bool {
	if dl_root() != "" && os.exists(dl_root()) { return true }
	if path, ok := choose_folder("Where should downloads go?"); ok {
		field_set(&dl.fields[.Root], path)
		delete(path)
		dl_save_soon()
		return true
	}
	toast("Choose a folder for downloads first (the folder button)")
	return false
}

@(private="file")
draw_dl_bar :: proc(r: Rect) {
	fill(r, PANEL)
	x := r.x + px(PAD)
	cy := r.y + (r.height - px(26)) * 0.5
	names := [Dl_Filter]string{.All = "All", .Ready = "Ready", .Active = "Downloading", .Done = "Done", .Failed = "Failed"}
	for f in Dl_Filter {
		n := 0
		for &it in dl.items { if dl_matches(&it, f) { n += 1 } }
		label := fmt.ctprintf("%s  %d", names[f], n)
		w := text_w(.Regular, label, FS_SMALL) + px(20)
		b := rect(x, cy, w, px(26))
		on := dl.filter == f
		if on { fill_round(b, ACCENT_DK, 13) } else if hovered(b) { fill_round(b, PANEL_3, 13); ui.hover_cursor = .POINTING_HAND }
		draw_text_mid(.Regular, label, b.x + px(10), b.y, b.height, FS_SMALL, on ? ACCENT : TEXT_DIM)
		if clicked_in(b) { dl.filter = f }
		x += w + px(4)
	}

	edge := r.x + r.width - px(PAD)
	ob := rect(edge - px(96), cy, px(96), px(26))
	tip(ob, "Folders, file names, tags, cookies and more")
	if dl.options_open { fill_round(ob, ACCENT_DK, 4) }
	if button(ob, "", .Ghost) { dl.options_open = !dl.options_open; dl_save_soon() }
	draw_icon(.Settings, rect(ob.x + px(6), ob.y, px(16), ob.height), dl.options_open ? ACCENT : TEXT_DIM)
	draw_text_mid(.Regular, "Options", ob.x + px(28), ob.y, ob.height, FS_SMALL, dl.options_open ? ACCENT : TEXT_DIM)
	edge = ob.x - px(GAP)

	if dl.running || downloads_active() > 0 {
		sb := rect(edge - px(84), cy, px(84), px(26))
		if button(sb, dl.stopping ? "Stopping" : "Stop all", .Danger, dl.running && !dl.stopping) {
			for &it in dl.items { if it.state == .Queued { it.state = .Stopped } }
			stop_downloads()
		}
		edge = sb.x - px(GAP)
	}

	root := dl_root()
	label := root == "" ? "Choose a download folder" : root
	room := clamp(edge - x - px(GAP * 2), px(120), px(420))
	text := elide_left(label, room - px(36), FS_SMALL)
	w := text_w(.Regular, text, FS_SMALL) + px(36)
	fb := rect(edge - w, cy, w, px(26))
	tip(fb, root == "" ? "Pick the folder downloads go into" : fmt.tprintf("Downloads go into %s. Click to change.", root))
	if button(fb, "", .Normal) {
		if path, ok := choose_folder("Where should downloads go?"); ok {
			field_set(&dl.fields[.Root], path)
			delete(path)
			dl_save_soon()
		}
	}
	draw_icon(.Folder, rect(fb.x + px(8), fb.y, px(16), fb.height), FOLDER_C)
	draw_text_mid(.Regular, text, fb.x + px(28), fb.y, fb.height, FS_SMALL, root == "" ? WARN_C : TEXT)
}

@(private="file")
fmt_duration :: proc(seconds: f32) -> string {
	s := int(seconds)
	if s >= 3600 { return fmt.tprintf("%d h %d min", s / 3600, (s % 3600) / 60) }
	if s >= 60 { return fmt.tprintf("%d:%02d", s / 60, s % 60) }
	return fmt.tprintf("0:%02d", s)
}

@(private="file")
card_height :: proc(it: ^Dl_Item) -> f32 {
	h := px(DL_CARD_H)
	if it.expanded && len(it.tracks) > 0 {
		h += px(40) + px(DL_TRACK_H) * f32(len(it.tracks)) + px(8)
	}
	return h
}

@(private="file")
draw_dl_list :: proc(r: Rect) {
	if len(dl.items) == 0 {
		draw_dl_empty(r)
		return
	}
	scroll_area(&dl.scroll, r, dl.content_h)
	inner := rect(r.x + px(PAD), r.y, r.width - px(PAD) * 2 - scroll_gutter(r, dl.content_h), r.height)
	begin_clip(r)
	y := r.y + px(PAD) - dl.scroll.offset
	remove := -1
	for &it, i in dl.items {
		if !dl_matches(&it, dl.filter) { continue }
		h := card_height(&it)
		if y + h >= r.y && y <= r.y + r.height {
			if draw_dl_card(&it, i, rect(inner.x, y, inner.width, h)) { remove = i }
		}
		y += h + px(GAP)
	}
	end_clip()
	dl.content_h = y + dl.scroll.offset - r.y + px(PAD)
	scroll_bar_over(&dl.scroll, r, dl.content_h)
	if remove >= 0 {
		dl_free_item(&dl.items[remove])
		ordered_remove(&dl.items, remove)
		dl.edit_item = -1
		dl_save_soon()
	}
}

@(private="file")
draw_dl_empty :: proc(r: Rect) {
	cx := r.x + r.width * 0.5
	y := r.y + r.height * 0.32
	lines := [?]cstring{
		"Paste a playlist or video link above and press Enter.",
		"Each playlist gets its own folder, named after the game or album.",
		"You can change every name, the format and the tracks before it starts.",
	}
	draw_icon(.Import, rect(cx - px(22), y - px(56), px(44), px(44)), TEXT_FAINT)
	for l, i in lines {
		w := text_w(i == 0 ? .Bold : .Regular, l, FS_BODY)
		draw_text(i == 0 ? .Bold : .Regular, l, cx - w * 0.5, y + px(24) * f32(i), FS_BODY, i == 0 ? TEXT : TEXT_DIM)
	}
	if dl.ytdlp == .Missing || dl.ytdlp == .Failed {
		w := text_w(.Regular, "Install yt-dlp", FS_BODY) + px(40)
		if button(rect(cx - w * 0.5, y + px(96), w, px(30)), "Install yt-dlp", .Primary) { ytdlp_install() }
	}
}

// Returns true when the card's remove button was pressed.
@(private="file")
draw_dl_card :: proc(it: ^Dl_Item, index: int, r: Rect) -> bool {
	fill_round(r, PANEL, 8)
	outline_round(r, LINE_SOFT, 8)
	removed := false

	// ── the picture ──
	th := px(72)
	tw := th * 16 / 9
	thumb := rect(r.x + px(12), r.y + px(12), tw, th)
	if !it.texture_tried && it.thumb != "" && os.exists(it.thumb) {
		it.texture_tried = true
		it.texture = rl.LoadTexture(strings.clone_to_cstring(it.thumb, context.temp_allocator))
		if it.texture.id != 0 { rl.SetTextureFilter(it.texture, .BILINEAR) }
	}
	if it.texture.id != 0 {
		src := rl.Rectangle{0, 0, f32(it.texture.width), f32(it.texture.height)}
		// Cover the box, cropping the long side.
		want := tw / th
		have := src.width / max(src.height, 1)
		if have > want { cut := src.width - src.height * want; src.x += cut * 0.5; src.width -= cut }
		else { cut := src.height - src.width / want; src.y += cut * 0.5; src.height -= cut }
		rl.DrawTexturePro(it.texture, src, thumb, {0, 0}, 0, rl.WHITE)
	} else {
		fill_round(thumb, PANEL_2, 4)
		draw_icon(it.mode == .Audio ? .Music : .Video, inset(thumb, px(24)), TEXT_FAINT)
	}
	if it.playlist || it.chapters {
		badge := fmt.ctprintf("%d", len(it.tracks))
		bw := text_w(.Bold, badge, FS_SMALL) + px(12)
		b := rect(thumb.x + thumb.width - bw - px(4), thumb.y + thumb.height - px(20), bw, px(16))
		fill_round(b, rl.Color{0, 0, 0, 190}, 3)
		draw_text_mid(.Bold, badge, b.x + px(6), b.y, b.height, FS_SMALL, TEXT)
	}

	x := thumb.x + thumb.width + px(14)
	right := r.x + r.width - px(12)

	// ── the actions, right ──
	close_b := rect(right - px(26), r.y + px(10), px(26), px(26))
	tip(close_b, it.state == .Running ? "Stop it first" : "Remove from the list (files already downloaded stay)")
	if it.state != .Running && it.state != .Queued {
		if icon_button(close_b, .Close) { removed = true }
	}
	exp := rect(close_b.x - px(30), close_b.y, px(26), px(26))
	if len(it.tracks) > 0 {
		tip(exp, it.expanded ? "Hide the tracks" : "Show the tracks: choose them, fix titles and artists")
		if icon_button(exp, it.expanded ? .Caret_Up : .Caret_Down) { it.expanded = !it.expanded; dl_save_soon() }
	}
	action_w := px(118)
	act := rect(exp.x - action_w - px(6), r.y + px(10), action_w, px(28))
	switch it.state {
	case .Probing:
		_ = button(act, "Reading...", .Normal, false)
	case .Probe_Failed:
		if button(act, "Try again") { reprobe(it) }
	case .Ready:
		if icon_label_button(act, .Import, "Download", .Primary, dl.ytdlp == .Ready) {
			if dl_have_root() { it.state = .Queued; dl_save_soon() }
		}
	case .Queued:
		if button(act, "Waiting...", .Ghost) { it.state = .Ready }
		tip(act, "Waiting for the downloads before it. Click to take it out of the queue.")
	case .Running:
		if button(act, dl.stopping ? "Stopping" : "Stop", .Danger, !dl.stopping) { stop_downloads() }
	case .Stopped:
		if icon_label_button(act, .Import, "Resume", .Primary, dl.ytdlp == .Ready) {
			if dl_have_root() { it.state = .Queued; dl_save_soon() }
		}
	case .Done:
		// Tracks ticked after the first run: offer them, rather than the folder.
		more := 0
		for &t in it.tracks { if t.selected && t.state != .Done && t.state != .Skipped { more += 1 } }
		other := dl_other_format(it)
		if more > 0 {
			if icon_label_button(act, .Import, fmt.ctprintf("Get %d more", more), .Primary, dl.ytdlp == .Ready) {
				it.state = .Queued
				dl_save_soon()
			}
		} else if other > 0 {
			// Files in another format than the card's: fetch them again in
			// this one. The old file goes to the Recycle Bin and its tags
			// move to the new file.
			ext := DL_AUDIO_FORMAT_EXTS[it.audio_format]
			label := fmt.ctprintf("Replace %d as %s", other, strings.to_upper(ext[1:], context.temp_allocator))
			act.x -= px(40)
			act.width += px(40)
			tip(act, fmt.tprintf("%d files here are not %s. Download them again as %s; the old files go to the Recycle Bin and keep their tags.",
			                     other, ext, ext))
			if icon_label_button(act, .Refresh, label, .Primary, dl.ytdlp == .Ready) {
				for &t in it.tracks {
					if dl_track_needs_format(it, &t) { t.replace = true; t.state = .Waiting }
				}
				it.state = .Queued
				dl_save_soon()
			}
		} else if icon_label_button(act, .Folder_Open, "Open folder") {
			reveal_in_file_manager(dl_first_path(it))
		}
	}

	// ── the name, editable ──
	row1 := r.y + px(10)
	name_w := max(act.x - x - px(GAP), px(120))
	ctl_w := min(px(360), name_w * 0.55)
	nb := rect(x, row1, name_w - ctl_w - px(GAP), px(28))
	focused := ui.focus == rawptr(&it.name)
	editable := it.state != .Running && it.state != .Queued
	fill_round(nb, focused ? PANEL_2 : PANEL, 4)
	if focused || hovered(nb) { outline_round(nb, focused ? ACCENT : LINE, 4) }
	tip(nb, "Game or album name: the folder, the album tag and the game tag. Click to change.")
	if editable {
		if text_field(&it.name, rect(nb.x + px(8), nb.y, nb.width - px(16), nb.height), "Name") { dl_save_soon() }
	} else {
		draw_text_mid(.Bold, elide_right(field_string(&it.name), nb.width - px(16), FS_BODY), nb.x + px(8), nb.y, nb.height, FS_BODY, TEXT)
	}
	if it.state == .Probing {
		draw_text_mid(.Regular, elide_right(it.url, nb.width - px(16), FS_SMALL), nb.x + px(8), nb.y, nb.height, FS_SMALL, TEXT_FAINT)
	}

	// Category, audio or video, format.
	cx := nb.x + nb.width + px(GAP)
	cat_w := ctl_w * 0.34
	cat := rect(cx, row1, cat_w, px(28))
	tip(cat, "What it is. Decides the folder it goes into (Options)")
	if drop_button(cat, DL_CATEGORY_NAMES[it.category], editable) { open_dl_menu(.Category, index) }
	mode := rect(cat.x + cat.width + px(4), row1, ctl_w * 0.30, px(28))
	if editable {
		if pick := segmented(mode, {"Audio", "Video"}, int(it.mode)); pick >= 0 {
			it.mode = Dl_Mode(pick)
			if it.mode == .Video && it.category == .Game { it.category = .Video }
			if it.mode == .Audio && it.category == .Video { it.category = .Game }
			dl_save_soon()
		}
	} else {
		_ = segmented(mode, {"Audio", "Video"}, int(it.mode))
	}
	fb := rect(mode.x + mode.width + px(4), row1, ctl_w - cat_w - mode.width - px(8), px(28))
	tip(fb, it.mode == .Audio ? DL_AUDIO_FORMAT_TIPS[it.audio_format] : "Video quality. MP4 is H.264 and AAC, which Premiere opens.")
	if drop_button(fb, format_label(it.mode, it.audio_format, it.video_quality, it.premiere), editable) {
		open_dl_menu(.Format, index)
	}

	// ── what it is and where it goes ──
	row2 := row1 + px(36)
	total: f32
	for &t in it.tracks { if t.selected { total += t.duration } }
	selected := 0
	for &t in it.tracks { if t.selected { selected += 1 } }
	facts: string
	switch {
	case it.state == .Probing:
		facts = "Reading the link..."
	case it.state == .Probe_Failed:
		facts = it.message
	case it.playlist:
		facts = fmt.tprintf("%s  ·  %d of %d tracks  ·  %s%s", it.title, selected, len(it.tracks), fmt_duration(total),
		                    it.uploader != "" ? fmt.tprintf("  ·  %s", it.uploader) : "")
	case it.chapters && it.split:
		facts = fmt.tprintf("%s  ·  %d of %d chapters, one file each  ·  %s%s", it.title, selected, len(it.tracks),
		                    fmt_duration(total), it.uploader != "" ? fmt.tprintf("  ·  %s", it.uploader) : "")
	case it.chapters:
		whole: f32
		for &t in it.tracks { whole += t.duration }
		facts = fmt.tprintf("%s  ·  one file, %d chapters kept as markers  ·  %s", it.title, len(it.tracks), fmt_duration(whole))
	case:
		facts = fmt.tprintf("%s  ·  %s%s", it.title, fmt_duration(total), it.uploader != "" ? fmt.tprintf("  ·  %s", it.uploader) : "")
	}
	draw_text(.Regular, elide_right(facts, right - x, FS_SMALL), x + px(8), row2, FS_SMALL,
	          it.state == .Probe_Failed ? BAD_C : TEXT_DIM)

	row3 := row2 + px(22)
	if it.state != .Probing && it.state != .Probe_Failed {
		folder := dl_root() == "" ? "Choose a download folder first" : dl_folder(it)
		draw_icon(.Folder, rect(x + px(6), row3 - px(1), px(14), px(16)), FOLDER_C)
		status := dl_status_text(it)
		sw := text_w(.Regular, status, FS_SMALL)
		draw_text(.Regular, elide_left(folder, right - x - px(30) - sw - px(16), FS_SMALL), x + px(26), row3, FS_SMALL, TEXT_FAINT)
		draw_text(.Regular, status, right - sw, row3, FS_SMALL, it.failed > 0 ? WARN_C : (it.state == .Done ? GOOD_C : TEXT_DIM))
	}

	// ── progress ──
	if it.state == .Running || it.state == .Done || (it.state == .Stopped && it.done + it.skipped > 0) {
		sel := max(selected, 1)
		partial: f32
		for &t in it.tracks {
			if t.selected && (t.state == .Downloading || t.state == .Tagging) { partial += t.pct / 100 }
		}
		frac := clamp((f32(it.done + it.skipped + it.failed) + partial) / f32(sel), 0, 1)
		bar := rect(x + px(8), r.y + px(DL_CARD_H) - px(14), right - x - px(8), px(4))
		fill_round(bar, PANEL_3, 2)
		col := it.failed > 0 ? WARN_C : (it.state == .Done ? GOOD_C : ACCENT)
		fill_round(rect(bar.x, bar.y, bar.width * frac, bar.height), col, 2)
	}

	if it.expanded && len(it.tracks) > 0 {
		draw_dl_tracks(it, index, rect(r.x + px(12), r.y + px(DL_CARD_H), r.width - px(24), r.height - px(DL_CARD_H)))
	}
	return removed
}

// A downloaded track whose file is not in the card's audio format.
dl_track_needs_format :: proc(it: ^Dl_Item, t: ^Dl_Track) -> bool {
	if it.mode != .Audio || t.duplicate_of > 0 || t.path == "" { return false }
	if t.state != .Done && t.state != .Skipped { return false }
	want := DL_AUDIO_FORMAT_EXTS[clamp(it.audio_format, 0, len(DL_AUDIO_FORMAT_EXTS) - 1)]
	if want == "" { return false }
	// No os.exists here: this runs every frame, for every track, on what may
	// be a spinning disk. A file gone since is reported by the job instead.
	return !strings.equal_fold(filepath.ext(t.path), want)
}

dl_other_format :: proc(it: ^Dl_Item) -> int {
	n := 0
	for &t in it.tracks { if dl_track_needs_format(it, &t) { n += 1 } }
	return n
}

@(private="file")
dl_first_path :: proc(it: ^Dl_Item) -> string {
	for &t in it.tracks { if t.path != "" && os.exists(t.path) { return t.path } }
	return dl_folder(it)
}

@(private="file")
dl_status_text :: proc(it: ^Dl_Item) -> cstring {
	switch it.state {
	case .Probing, .Probe_Failed: return ""
	case .Ready:   return dl.ytdlp == .Ready ? "Ready" : "Waiting for yt-dlp"
	case .Queued:  return "In the queue"
	case .Running:
		speed: f32
		for &t in it.tracks { if t.state == .Downloading { speed += t.speed } }
		sel := 0
		for &t in it.tracks { if t.selected { sel += 1 } }
		if speed > 0 {
			return fmt.ctprintf("%d of %d  ·  %.1f MB/s", it.done + it.skipped, sel, speed / 1_000_000)
		}
		return fmt.ctprintf("%d of %d", it.done + it.skipped, sel)
	case .Stopped: return it.message != "" ? fmt.ctprintf("%s", it.message) : "Stopped"
	case .Done:    return fmt.ctprintf("%s", it.message)
	}
	return ""
}

@(private="file")
dl_commit_edit :: proc() {
	if dl.edit_item < 0 { return }
	defer { dl.edit_item = -1; dl.edit_track = -1 }
	if dl.edit_item >= len(dl.items) { return }
	it := &dl.items[dl.edit_item]
	if dl.edit_track < 0 || dl.edit_track >= len(it.tracks) { return }
	t := &it.tracks[dl.edit_track]
	value := strings.trim_space(field_string(&dl.edit_field))
	if dl.edit_artist { set_owned(&t.artist, value) } else if value != "" { set_owned(&t.title, value) }
	dl_save_soon()
}

@(private="file")
draw_dl_tracks :: proc(it: ^Dl_Item, index: int, r: Rect) {
	hline(r.x, r.y, r.width, LINE_SOFT)
	editable := it.state != .Running && it.state != .Queued
	y := r.y + px(8)

	// Settings for this card's tracks.
	pb := rect(r.x, y, px(180), px(26))
	tip(pb, "How titles are read: 'Artist - Title' or 'Title - Artist'. Changing it reads the link again.")
	if drop_button(pb, DL_PATTERN_NAMES[it.pattern], editable) { open_dl_menu(.Pattern, index) }
	bx := pb.x + pb.width + px(GAP)
	if button(rect(bx, y, px(78), px(26)), "All", .Ghost, editable) {
		for &t in it.tracks { t.selected = true }
		dl_save_soon()
	}
	if button(rect(bx + px(80), y, px(78), px(26)), "None", .Ghost, editable) {
		for &t in it.tracks { t.selected = false }
		dl_save_soon()
	}
	ax := bx + px(170)
	draw_text_mid(.Regular, "Album artist", ax, y, px(26), FS_SMALL, TEXT_DIM)
	aw := text_w(.Regular, "Album artist", FS_SMALL) + px(8)
	afield := rect(ax + aw, y, min(px(220), r.x + r.width - ax - aw), px(26))
	fill_round(afield, PANEL_2, 4)
	outline_round(afield, ui.focus == rawptr(&it.album_artist) ? ACCENT : LINE, 4)
	if editable {
		if text_field(&it.album_artist, rect(afield.x + px(6), afield.y, afield.width - px(12), afield.height), "none") { dl_save_soon() }
	}
	if it.chapters {
		split := it.split
		sx := afield.x + afield.width + px(16)
		label: cstring = "One file per chapter"
		if editable {
			if checkbox(sx, y + px(4), label, &split) { it.split = split; dl_save_soon() }
		} else {
			_ = checkbox(sx, y + px(4), label, &split)
		}
		tip(rect(sx, y, text_w(.Regular, label, FS_SMALL) + px(24), px(26)),
		    "On: each chapter becomes its own tagged track. Off: one file for the whole video.")
	}
	y += px(34)

	num_w := px(34)
	dur_w := px(56)
	state_w := px(150)
	artist_w := (r.width - num_w - dur_w - state_w - px(30)) * 0.32
	title_w := r.width - num_w - dur_w - state_w - artist_w - px(30)
	for &t, ti in it.tracks {
		row := rect(r.x, y, r.width, px(DL_TRACK_H))
		if hovered(row) { fill_round(row, PANEL_2, 4) }
		cb := t.selected
		if editable {
			if checkbox(row.x + px(4), row.y + px(4), "", &cb) { t.selected = cb; dl_save_soon() }
		} else {
			_ = checkbox(row.x + px(4), row.y + px(4), "", &cb)
		}
		col := t.selected ? TEXT : TEXT_FAINT
		nx := row.x + px(26)
		if t.number > 0 { draw_text_mid(.Regular, fmt.ctprintf("%02d", t.number), nx, row.y, row.height, FS_SMALL, TEXT_DIM) }

		// Title and artist: click to change.
		tx := nx + num_w
		title_r := rect(tx, row.y, title_w, row.height)
		artist_r := rect(tx + title_w + px(8), row.y, artist_w, row.height)
		editing_here := dl.edit_item == index && dl.edit_track == ti
		for part in 0 ..< 2 {
			cell := part == 0 ? title_r : artist_r
			is_artist := part == 1
			if editing_here && dl.edit_artist == is_artist {
				fill_round(cell, PANEL_3, 4)
				outline_round(cell, ACCENT, 4)
				_ = text_field(&dl.edit_field, rect(cell.x + px(4), cell.y, cell.width - px(8), cell.height), is_artist ? "Artist" : "Title")
				if enter_pressed() || ui.focus != rawptr(&dl.edit_field) { dl_commit_edit() }
				continue
			}
			value := is_artist ? t.artist : t.title
			if value == "" && is_artist { value = "—" }
			draw_text_mid(part == 0 ? .Regular : .Regular, elide_right(value, cell.width - px(8), FS_SMALL),
			              cell.x + px(4), cell.y, cell.height, FS_SMALL, is_artist ? TEXT_DIM : col)
			if editable && hovered(cell) {
				ui.hover_cursor = .IBEAM
				tip(cell, is_artist ? "Artist. Click to change." : fmt.tprintf("Was: %s. Click to change.", t.original))
			}
			if editable && clicked_in(cell) {
				dl_commit_edit()
				dl.edit_item = index
				dl.edit_track = ti
				dl.edit_artist = is_artist
				field_set(&dl.edit_field, is_artist ? t.artist : t.title)
				field_select_all(&dl.edit_field)
				ui.focus = rawptr(&dl.edit_field)
			}
		}
		dx := artist_r.x + artist_r.width + px(8)
		draw_text_mid(.Regular, fmt.ctprintf("%s", fmt_duration(t.duration)), dx, row.y, row.height, FS_SMALL, TEXT_DIM)

		sx := row.x + row.width - state_w
		switch t.state {
		case .Waiting:
			if t.duplicate_of > 0 {
				draw_text_mid(.Regular, fmt.ctprintf("repeat of %02d", t.duplicate_of), sx, row.y, row.height, FS_SMALL, TEXT_FAINT)
				tip(rect(sx, row.y, state_w, row.height), "The same video is earlier in the playlist, so this copy is unticked.")
			} else if it.state == .Running && t.selected {
				draw_text_mid(.Regular, "waiting", sx, row.y, row.height, FS_SMALL, TEXT_FAINT)
			}
		case .Downloading:
			bar := rect(sx, row.y + row.height * 0.5 - px(2), state_w - px(52), px(4))
			fill_round(bar, PANEL_3, 2)
			fill_round(rect(bar.x, bar.y, bar.width * clamp(t.pct / 100, 0, 1), bar.height), ACCENT, 2)
			draw_text_mid(.Regular, fmt.ctprintf("%.0f%%", t.pct), bar.x + bar.width + px(6), row.y, row.height, FS_SMALL, TEXT_DIM)
		case .Tagging:
			draw_text_mid(.Regular, "tagging", sx, row.y, row.height, FS_SMALL, ACCENT)
		case .Done:
			draw_text_mid(.Regular, "done", sx, row.y, row.height, FS_SMALL, GOOD_C)
		case .Skipped:
			draw_text_mid(.Regular, "already there", sx, row.y, row.height, FS_SMALL, TEXT_DIM)
		case .Failed:
			draw_text_mid(.Regular, elide_right(fmt.tprintf("failed: %s", t.message), state_w, FS_SMALL), sx, row.y, row.height, FS_SMALL, BAD_C)
			state_r := rect(sx, row.y, state_w, row.height)
			tip(state_r, t.message)
		}
		if (t.state == .Done || t.state == .Skipped) && t.path != "" {
			state_r := rect(sx, row.y, state_w, row.height)
			tip(state_r, fmt.tprintf("%s. Click to show it.", t.path))
			if clicked_in(state_r) { reveal_in_file_manager(t.path) }
		}
		y += px(DL_TRACK_H)
	}
}

@(private="file")
opt_label :: proc(x, y: f32, text: cstring) -> f32 {
	draw_text(.Regular, text, x, y, FS_SMALL, TEXT_DIM)
	return y + px(18)
}

@(private="file")
opt_field :: proc(f: Dl_Field, x, y, w: f32, placeholder: cstring) -> f32 {
	box := rect(x, y, w, px(28))
	fill_round(box, PANEL_2, 4)
	outline_round(box, ui.focus == rawptr(&dl.fields[f]) ? ACCENT : LINE, 4)
	if text_field(&dl.fields[f], rect(box.x + px(8), box.y, box.width - px(16), box.height), placeholder) { dl_save_soon() }
	return y + px(34)
}

@(private="file")
opt_check :: proc(x, y: f32, label: cstring, value: ^bool, hint := "") -> f32 {
	if checkbox(x, y, label, value) { dl_save_soon() }
	if hint != "" { tip(rect(x, y, px(260), px(18)), hint) }
	return y + px(24)
}

@(private="file")
draw_dl_options :: proc(r: Rect) {
	fill(r, PANEL)
	scroll_area(&dl.opt_scroll, r, dl.opt_h)
	begin_clip(r)
	x := r.x + px(PAD)
	w := r.width - px(PAD) * 2 - scroll_gutter(r, dl.opt_h)
	y := r.y + px(PAD) - dl.opt_scroll.offset

	section_label(x, y, "WHERE FILES GO")
	y += px(22)
	y = opt_label(x, y, "Download folder")
	fb := rect(x, y, w, px(28))
	if button(fb, "", .Normal) {
		if path, ok := choose_folder("Where should downloads go?"); ok {
			field_set(&dl.fields[.Root], path)
			delete(path)
			dl_save_soon()
		}
	}
	root := dl_root()
	draw_icon(.Folder, rect(fb.x + px(8), fb.y, px(16), fb.height), FOLDER_C)
	draw_text_mid(.Regular, elide_left(root == "" ? "Choose..." : root, w - px(40), FS_SMALL), fb.x + px(30), fb.y, fb.height, FS_SMALL, TEXT)
	y += px(36)
	draw_text(.Regular, "Folder inside it, by category. {album} is the card's name;", x, y, FS_SMALL, TEXT_FAINT)
	y += px(16)
	draw_text(.Regular, "also {artist}, {uploader}, {year}, {playlist}.", x, y, FS_SMALL, TEXT_FAINT)
	y += px(22)
	y = opt_label(x, y, "Game OST")
	y = opt_field(.Folder_Game, x, y, w, "Game OSTs/{album}")
	y = opt_label(x, y, "Music")
	y = opt_field(.Folder_Music, x, y, w, "Music/{album}")
	y = opt_label(x, y, "Video")
	y = opt_field(.Folder_Video, x, y, w, "Videos/{album}")
	y = opt_label(x, y, "Other")
	y = opt_field(.Folder_Other, x, y, w, "Downloads/{album}")

	y += px(8)
	section_label(x, y, "FILE NAMES")
	y += px(22)
	draw_text(.Regular, "{track:02}, {title}, {artist}, {album}, {disc}, {year}", x, y, FS_SMALL, TEXT_FAINT)
	y += px(20)
	y = opt_label(x, y, "Audio")
	y = opt_field(.Name_Audio, x, y, w, "{track:02} - {title}")
	y = opt_label(x, y, "Video")
	y = opt_field(.Name_Video, x, y, w, "{title}")

	y += px(8)
	section_label(x, y, "TAGS")
	y += px(22)
	y = opt_check(x, y, "Write tags (title, artist, album, track)", &dl.tags)
	y = opt_check(x, y, "Embed the thumbnail as cover art", &dl.cover)
	y = opt_check(x, y, "Crop the cover square", &dl.square_cover, "YouTube pictures are wide; album covers are square")
	y = opt_check(x, y, "Subtitles in videos", &dl.subtitles)
	y = opt_label(x, y, "Genre for game soundtracks")
	y = opt_field(.Genre, x, y, w, "Game Soundtrack")
	y = opt_label(x, y, "Also remove these words from names (commas)")
	y = opt_field(.Noise, x, y, w, "remastered, ver., arrange")

	y += px(8)
	section_label(x, y, "AFTER DOWNLOADING")
	y += px(22)
	y = opt_check(x, y, "Add new files to the open library", &dl.add_to_library,
	              "When the download folder is inside the open library, the new folder is scanned in")
	y = opt_check(x, y, "Tag game soundtracks with their game", &dl.game_tag,
	              "Adds the game tag to the new files. Like any tag, it is written when you press Save.")

	y += px(8)
	section_label(x, y, "DOWNLOADING")
	y += px(22)
	y = opt_label(x, y, "At the same time")
	pb := rect(x, y, px(120), px(28))
	if drop_button(pb, fmt.ctprintf("%d downloads", dl.parallel)) { open_dl_menu(.Parallel, -1) }
	y += px(36)
	y = opt_label(x, y, "Sign in with a browser's cookies (age-restricted, members-only)")
	bb := rect(x, y, px(160), px(28))
	if drop_button(bb, DL_BROWSER_NAMES[dl.browser]) { open_dl_menu(.Browser, -1) }
	y += px(36)
	y = opt_label(x, y, "Speed limit (for example 5M), empty for none")
	y = opt_field(.Rate, x, y, w, "no limit")
	y = opt_label(x, y, "More yt-dlp options")
	y = opt_field(.Extra, x, y, w, "--sponsorblock-remove all")

	y += px(8)
	section_label(x, y, "YT-DLP")
	y += px(22)
	draw_text(.Regular, fmt.ctprintf("%s", dl.ytdlp_version != "" ? dl.ytdlp_version : "not found"), x, y, FS_SMALL, TEXT_DIM)
	y += px(20)
	ub := rect(x, y, px(150), px(28))
	if button(ub, "Check for update", .Normal, !ytdlp_busy() && !dl.running) {
		dl.ytdlp = .Updating
		set_owned(&dl.ytdlp_note, "Checking for a yt-dlp update...")
		if !tool_start(.Update, {ytdlp_exe(), "-U"}) { ytdlp_install() }
	}
	y += px(40)

	end_clip()
	dl.opt_h = y + dl.opt_scroll.offset - r.y
	scroll_bar_over(&dl.opt_scroll, r, dl.opt_h)
}

@(private="file")
draw_dl_status :: proc(r: Rect) {
	fill(r, PANEL)
	x := r.x + px(PAD)
	dot_col := GOOD_C
	switch dl.ytdlp {
	case .Unknown, .Updating, .Checking, .Installing: dot_col = WARN_C
	case .Missing, .Failed: dot_col = BAD_C
	case .Ready:
	}
	rl.DrawCircleV({x + px(4), r.y + r.height * 0.5}, px(4), dot_col)
	x += px(14)
	text: string
	switch dl.ytdlp {
	case .Ready:
		text = fmt.tprintf("yt-dlp %s  ·  %s", dl.ytdlp_version, dl.ytdlp_note)
	case .Unknown, .Updating, .Checking, .Installing, .Missing, .Failed:
		text = dl.ytdlp_note
	}
	draw_text_mid(.Regular, elide_right(text, r.width * 0.6, FS_SMALL), x, r.y, r.height, FS_SMALL, TEXT_DIM)
	if dl.ytdlp == .Missing || dl.ytdlp == .Failed {
		b := rect(x + text_w(.Regular, elide_right(text, r.width * 0.6, FS_SMALL), FS_SMALL) + px(12), r.y + px(2), px(110), r.height - px(4))
		if button(b, "Install yt-dlp", .Primary) { ytdlp_install() }
	}
	right := fmt.ctprintf("%d at a time  ·  %s", dl.parallel, dl.running ? "downloading" : (dl.probing ? "reading links" : "idle"))
	rw := text_w(.Regular, right, FS_SMALL)
	draw_text_mid(.Regular, right, r.x + r.width - px(PAD) - rw, r.y, r.height, FS_SMALL, TEXT_FAINT)
}

@(private="file")
draw_dl_menu :: proc() {
	i := dl.menu.subject
	it: ^Dl_Item = nil
	if i >= 0 && i < len(dl.items) { it = &dl.items[i] }
	switch dl.menu_kind {
	case .None:
	case .Category:
		if it == nil { dl.menu.open = false; return }
		checks := [4]bool{}
		checks[int(it.category)] = true
		if pick := context_menu(&dl.menu, {"Game OST", "Music", "Video", "Other"}, checks[:]); pick >= 0 {
			it.category = Dl_Category(pick)
			dl_save_soon()
		}
	case .Format, .Header_Format:
		mode := it != nil ? it.mode : dl.mode
		if mode == .Audio {
			checks: [len(DL_AUDIO_FORMATS)]bool
			checks[it != nil ? it.audio_format : dl.audio_format] = true
			if pick := context_menu(&dl.menu, DL_AUDIO_FORMAT_NAMES[:], checks[:]); pick >= 0 {
				if it != nil { it.audio_format = pick } else { dl_header_format(pick, -1, dl.premiere) }
				dl_save_soon()
			}
		} else {
			names: [len(DL_VIDEO_QUALITY_NAMES) + 1]cstring
			checks: [len(DL_VIDEO_QUALITY_NAMES) + 1]bool
			for n, j in DL_VIDEO_QUALITY_NAMES { names[j] = n }
			names[len(names) - 1] = "MP4 for Premiere (H.264, AAC)"
			checks[it != nil ? it.video_quality : dl.video_quality] = true
			checks[len(checks) - 1] = it != nil ? it.premiere : dl.premiere
			if pick := context_menu(&dl.menu, names[:], checks[:]); pick >= 0 {
				if pick == len(names) - 1 {
					if it != nil { it.premiere = !it.premiere } else { dl_header_format(-1, -1, !dl.premiere) }
				} else {
					if it != nil { it.video_quality = pick } else { dl_header_format(-1, pick, dl.premiere) }
				}
				dl_save_soon()
			}
		}
	case .Pattern:
		if it == nil { dl.menu.open = false; return }
		checks: [len(DL_PATTERN_NAMES)]bool
		checks[it.pattern] = true
		if pick := context_menu(&dl.menu, DL_PATTERN_NAMES[:], checks[:]); pick >= 0 && pick != it.pattern {
			it.pattern = pick
			dl.pattern = pick
			reprobe(it)
			dl_save_soon()
		}
	case .Browser:
		checks: [len(DL_BROWSER_NAMES)]bool
		checks[dl.browser] = true
		if pick := context_menu(&dl.menu, DL_BROWSER_NAMES[:], checks[:]); pick >= 0 {
			dl.browser = pick
			dl_save_soon()
		}
	case .Parallel:
		names := [?]cstring{"1 download", "2 downloads", "3 downloads", "4 downloads", "6 downloads", "8 downloads"}
		values := [?]int{1, 2, 3, 4, 6, 8}
		checks: [len(values)]bool
		for v, j in values { checks[j] = v == dl.parallel }
		if pick := context_menu(&dl.menu, names[:], checks[:]); pick >= 0 {
			dl.parallel = values[pick]
			dl_save_soon()
		}
	}
}

// The header's format applies to new links and every card not yet started.
@(private="file")
dl_header_format :: proc(audio, video: int, premiere: bool) {
	if audio >= 0 { dl.audio_format = audio }
	if video >= 0 { dl.video_quality = video }
	dl.premiere = premiere
	for &it in dl.items {
		if it.state != .Ready && it.state != .Probing && it.state != .Probe_Failed { continue }
		if audio >= 0 { it.audio_format = audio }
		if video >= 0 { it.video_quality = video }
		it.premiere = premiere
	}
}
