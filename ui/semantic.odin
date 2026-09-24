package musictagger

// Search by description: the client for search_server.py.
//
// The ordinary search box matches names, tags, captions and text read out of
// pictures, instantly and without any model. When a query reads like a
// description — two or more plain words — or when it finds nothing at all,
// it is also sent to the search server, which compares it with what every
// file looks like, sounds like and says. Its answers are added after the
// exact matches, best first, so nothing the box already found moves.
//
// The server is started on first use and kept running while the library is
// open: loading the text models takes seconds and a search has to answer
// while you type. It is restarted when the library changes, told to reload
// after an analysis run, and stops on its own after twenty idle minutes.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

SEMANTIC_DEBOUNCE :: 0.35 // seconds of no typing before a query is sent

@(private)
Semantic :: struct {
	stream:     Stream,
	running:    bool,
	ready:      bool,
	failed:     bool,   // could not start; not retried until the library changes
	partial:    [dynamic]u8,
	next_id:    int,
	sent_id:    int,
	sent_query: string, // owned
	want_query: string, // owned: what the box says now
	want_since: f64,
	hits_query: string, // owned: the query the hits below answer
	hits:       [dynamic]Semantic_Hit,
	list_file:  string,
	status:     string, // owned: what to say in the status line
}

Semantic_Hit :: struct { index: int, score: f32 }

@(private)
semantic: Semantic

// Whether a query should also be asked of the server.
semantic_wanted :: proc(query: string, exact_hits: int) -> bool {
	plain := 0
	for word in query_terms(query) {
		if len(word) == 0 { continue }
		switch word[0] {
		case '+', '-', '|': continue
		}
		if strings.contains(word, ":") { continue }
		plain += 1
	}
	if plain == 0 { return false }
	return plain >= 2 || exact_hits == 0
}

// The hits for `query`, if the server has answered it. Called by the filter.
semantic_hits_for :: proc(query: string) -> []Semantic_Hit {
	if semantic.hits_query != "" && semantic.hits_query == query { return semantic.hits[:] }
	return nil
}

// Asks for `query`. Sent after the typing pauses.
request_semantic :: proc(query: string) {
	if query == semantic.want_query { return }
	if query == "" {
		delete(semantic.want_query)
		semantic.want_query = ""
		return
	}
	delete(semantic.want_query)
	semantic.want_query = strings.clone(query)
	semantic.want_since = rl.GetTime()
}

semantic_status :: proc() -> string { return semantic.status }

@(private)
start_search_server :: proc() -> bool {
	if semantic.running { return true }
	if semantic.failed || !lib.scanned || len(lib.tracks) == 0 { return false }
	script := join_path({project_root(), "search_server.py"})
	if !os.exists(python_exe()) || !os.exists(script) {
		semantic.failed = true
		set_owned(&semantic.status, "search by description needs the Python setup")
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	for &t in lib.tracks {
		strings.write_string(&b, t.path)
		strings.write_byte(&b, '\n')
	}
	path := join_path({cache_dir("jobs"), "search-paths.txt"})
	if os.write_entire_file(path, transmute([]byte)strings.to_string(b)) != nil {
		semantic.failed = true
		return false
	}
	s, ok := stream_start({python_exe(), script, "--paths-from", path}, project_root(), true)
	if !ok {
		semantic.failed = true
		set_owned(&semantic.status, "could not start the search server")
		return false
	}
	logf("search server started for %d files", len(lib.tracks))
	semantic.stream = s
	semantic.running = true
	semantic.ready = false
	clear(&semantic.partial)
	set_owned(&semantic.status, "loading search")
	return true
}

stop_search_server :: proc() {
	if !semantic.running { return }
	stream_close_stdin(&semantic.stream)
	stream_kill(&semantic.stream)
	semantic.running = false
	semantic.ready = false
}

// The library changed: the server's list of files is out of date.
restart_search_server :: proc() {
	stop_search_server()
	semantic.failed = false
	delete(semantic.hits_query)
	semantic.hits_query = ""
	clear(&semantic.hits)
	delete(semantic.sent_query)
	semantic.sent_query = ""
}

// Analysis wrote new vectors: have the server read them.
reload_search_server :: proc() {
	if !semantic.running { return }
	msg := "{\"reload\": true}\n"
	stream_write(&semantic.stream, transmute([]byte)msg)
	delete(semantic.hits_query)
	semantic.hits_query = ""
	delete(semantic.sent_query)
	semantic.sent_query = ""
}

// Called once per frame.
poll_search_server :: proc() {
	// Send the latest query once typing has paused.
	if semantic.want_query != "" && semantic.want_query != semantic.sent_query &&
	   rl.GetTime() - semantic.want_since >= SEMANTIC_DEBOUNCE {
		if start_search_server() {
			semantic.next_id += 1
			b := strings.builder_make(context.temp_allocator)
			fmt.sbprintf(&b, "{{\"id\": %d, \"query\": ", semantic.next_id)
			write_json_string(&b, semantic.want_query)
			strings.write_string(&b, ", \"limit\": 400}\n")
			if stream_write(&semantic.stream, transmute([]byte)strings.to_string(b)) {
				semantic.sent_id = semantic.next_id
				delete(semantic.sent_query)
				semantic.sent_query = strings.clone(semantic.want_query)
				set_owned(&semantic.status, "searching by description…")
			} else {
				stop_search_server()
			}
		}
	}

	if !semantic.running { return }
	buf: [16 * 1024]byte
	for {
		n, eof := stream_read(&semantic.stream, buf[:])
		if n > 0 {
			append(&semantic.partial, ..buf[:n])
			continue
		}
		if eof || stream_finished(&semantic.stream) {
			stream_close(&semantic.stream)
			semantic.running = false
			semantic.ready = false
			logf("search server exited")
		}
		break
	}
	start := 0
	for i in 0 ..< len(semantic.partial) {
		if semantic.partial[i] != '\n' { continue }
		handle_semantic_line(string(semantic.partial[start:i]))
		start = i + 1
	}
	if start > 0 { remove_range(&semantic.partial, 0, start) }
}

@(private)
handle_semantic_line :: proc(line: string) {
	trimmed := strings.trim_space(line)
	if len(trimmed) == 0 || trimmed[0] != '{' { return }
	value, err := json.parse(transmute([]byte)trimmed, .JSON, false, context.temp_allocator)
	if err != nil { return }
	obj, ok := value.(json.Object)
	if !ok { return }
	switch json_str(obj, "event") {
	case "ready":
		semantic.ready = true
		set_owned(&semantic.status, "")
	case "loading":
		set_owned(&semantic.status, json_str(obj, "detail"))
	case "warning":
		set_owned(&semantic.status, json_str(obj, "message"))
		logf("search server: %s", json_str(obj, "message"))
	case "error":
		set_owned(&semantic.status, json_str(obj, "message"))
		logf("search server error: %s", json_str(obj, "message"))
	case "hits":
		id, _ := json_int(obj, "id")
		if id != semantic.sent_id { return } // an answer to a query already replaced
		clear(&semantic.hits)
		if raw, has := obj["hits"]; has {
			if arr, is_arr := raw.(json.Array); is_arr {
				for entry in arr {
					pair, is_pair := entry.(json.Array)
					if !is_pair || len(pair) < 2 { continue }
					index := -1
					#partial switch v in pair[0] {
					case json.Integer: index = int(v)
					case json.Float:   index = int(v)
					}
					score: f32
					#partial switch v in pair[1] {
					case json.Integer: score = f32(v)
					case json.Float:   score = f32(v)
					}
					if index >= 0 && index < len(lib.tracks) {
						append(&semantic.hits, Semantic_Hit{index, score})
					}
				}
			}
		}
		delete(semantic.hits_query)
		semantic.hits_query = strings.clone(json_str(obj, "query"))
		set_owned(&semantic.status, "")
		search.dirty = true
	}
}
