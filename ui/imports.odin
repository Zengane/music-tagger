package musictagger
import "core:encoding/json"
import "core:strings"
import "core:fmt"
import "core:path/filepath"
folder_copy: struct {
    running: bool,
    stream: Stream,
    source, destination, error: string,
    partial: [dynamic]byte,
    done, total: int,
}
start_folder_copy :: proc(source: string, effects: bool) {
    set_owned(&folder_copy.source, source)
    set_owned(&folder_copy.destination, "")
    set_owned(&folder_copy.error, "")
    clear(&folder_copy.partial)
    folder_copy.done = 0; folder_copy.total = 0
    args := make([dynamic]string, 0, 8, context.temp_allocator)
    append(&args, python_exe(), join_path({project_root(), "import_folder_job.py"}), "--source", source, "--library", lib.root)
    if effects { append(&args, "--effects") }
    folder_copy.stream, folder_copy.running = stream_start(args[:], project_root())
    if !folder_copy.running { toast("Could not start folder import") }
}
poll_folder_copy :: proc() {
    if !folder_copy.running { return }
    buf: [8192]byte
    for {
        n, _ := stream_read(&folder_copy.stream, buf[:])
        if n == 0 { break }
        append(&folder_copy.partial, ..buf[:n])
    }
    consumed := 0
    for c, i in folder_copy.partial {
        if c != '\n' { continue }
        line := folder_copy.partial[consumed:i]
        consumed = i+1
        raw, err := json.parse(line, .JSON, false, context.temp_allocator)
        if err != nil { continue }
        obj, ok := raw.(json.Object)
        if !ok { continue }
        switch json_str(obj, "event") {
        case "progress": folder_copy.done = int(json_num(obj,"done")); folder_copy.total = int(json_num(obj,"total"))
        case "done": set_owned(&folder_copy.destination, json_str(obj,"folder"))
        case "error": set_owned(&folder_copy.error, json_str(obj,"message"))
        }
    }
    if consumed > 0 {
        remaining := len(folder_copy.partial)-consumed
        copy(folder_copy.partial[:remaining], folder_copy.partial[consumed:])
        resize(&folder_copy.partial, remaining)
    }
    if !stream_finished(&folder_copy.stream) { return }
    code := folder_copy.stream.exit_code
    stream_close(&folder_copy.stream)
    folder_copy.running = false
    if code != 0 || folder_copy.destination == "" { toast(fmt.tprintf("Import failed: %s", folder_copy.error)); return }
    // Existing external references follow the copy, retaining unsaved edits.
    for &t in lib.tracks {
        if !path_under_root(folder_copy.source, t.path) { continue }
        rel, err := filepath.rel(folder_copy.source, t.path, context.temp_allocator)
        if err != nil { continue }
        t.path = strings.clone(join_path({folder_copy.destination, rel}), lib_allocator())
        t.rel = strings.clone(import_prefix(lib.root, t.path), lib_allocator())
        if t.media_kind == "" { t.is_sfx = is_skipped_dir(strings.to_lower(t.rel, context.temp_allocator)) }
        t.haystack = strings.clone(strings.to_lower(t.rel, context.temp_allocator), lib_allocator())
    }
    for i := len(imported_folders)-1; i >= 0; i -= 1 {
        if path_under_root(folder_copy.source, imported_folders[i]) { delete(imported_folders[i]); ordered_remove(&imported_folders,i) }
    }
    invalidate_music_map()
    start_scan(folder_copy.destination, true, true, additive = true)
    toast("Copied into the library; indexing new files. Originals kept.")
}
stop_folder_copy :: proc() {
    if folder_copy.running { stream_kill(&folder_copy.stream); stream_close(&folder_copy.stream); folder_copy.running = false }
}
