package musictagger

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

split_job: struct {
    stream: Stream,
    running, applying, ready: bool,
    path, detail, folder: string,
    count, done: int,
    clips: [][2]f64,
    page: int,
    noise: int,
    silence: int,
    partial: [dynamic]byte,
}

split_plan_path :: proc() -> string { return join_path({cache_dir("jobs"), "split-plan.json"}) }
start_split :: proc(t: ^Track, apply: bool) {
    if folder_copy.running { toast("Wait for the folder import to finish"); return }
    if split_job.running { return }
    if apply && (!split_job.ready || t.path != split_job.path) { return }
    if !apply { set_owned(&split_job.path, t.path); split_job.ready = false; split_job.count = 0 }
    args := make([dynamic]string, 0, 12, context.temp_allocator)
    append(&args, python_exe(), join_path({project_root(), "sfx_split_job.py"}), "--plan", split_plan_path())
    if apply { append(&args, "--apply") } else {
        append(&args, "--path", t.path, "--noise", fmt.tprintf("%d", -40 + split_job.noise * 10), "--silence", fmt.tprintf("%.2f", 0.35 + f64(split_job.silence) * 0.15))
    }
    split_job.applying = apply
    split_job.done = 0
    clear(&split_job.partial)
    set_owned(&split_job.folder, "")
    set_owned(&split_job.detail, apply ? "Creating separate WAV files..." : "Finding silences...")
    split_job.stream, split_job.running = stream_start(args[:], project_root())
    if !split_job.running { set_owned(&split_job.detail, "Could not start the splitting job") }
}

poll_split :: proc() {
    if !split_job.running { return }
    buf: [8192]byte
    for {
        n, eof := stream_read(&split_job.stream, buf[:])
        if n > 0 {
            append(&split_job.partial, ..buf[:n])
            continue
        }
        if !eof && !stream_finished(&split_job.stream) { return }
        break
    }
    code := split_job.stream.exit_code
    stream_close(&split_job.stream)
    split_job.running = false
    received := false
    for line in strings.split_lines(string(split_job.partial[:]), context.temp_allocator) {
        raw, err := json.parse(transmute([]byte)line, .JSON, false, context.temp_allocator)
        if err != nil { continue }
        obj, ok := raw.(json.Object)
        if !ok { continue }
        switch json_str(obj, "event") {
        case "plan":
            received = true
            delete(split_job.clips)
            split_job.clips = nil
            split_job.page = 0
            data, e := os.read_entire_file(split_plan_path(), context.temp_allocator)
            plan: struct { clips: [][2]f64 }
            if e == nil && json.unmarshal(data, &plan) == nil { split_job.clips = plan.clips }

            split_job.count = int(json_num(obj, "count"))
            split_job.ready = split_job.count > 0
            set_owned(&split_job.detail, fmt.tprintf("%d sounds found. Preview below, then create files.", split_job.count))
        case "done":
            received = true
            set_owned(&split_job.folder, json_str(obj, "folder"))
            set_owned(&split_job.detail, "Created WAV files; originals kept")
            split_job.ready = false
            queue_folder_import(split_job.folder, true)
        case "error":
            received = true
            set_owned(&split_job.detail, json_str(obj, "message"))
            split_job.ready = false
        }
    }
    if !received { set_owned(&split_job.detail, fmt.tprintf("Splitting stopped (code %d); check Python and ffmpeg", code)); split_job.ready = false }
}

stop_split :: proc() { if split_job.running { stream_kill(&split_job.stream); stream_close(&split_job.stream); split_job.running = false } }

draw_split_controls :: proc(t: ^Track, x, y, w: f32) -> f32 {
    cy := y
    section_label(x, cy, "SPLIT AT SILENCES")
    cy += px(20)
    if button(rect(x, cy, w * 0.48, px(24)), fmt.ctprintf("Noise: %d dB", -40 + split_job.noise * 10), .Ghost, !split_job.running) {
        split_job.noise = (split_job.noise + 2) % 3 - 1
        split_job.ready = false
    }
    if button(rect(x + w * 0.50, cy, w * 0.50, px(24)), fmt.ctprintf("Silence: %.2fs", 0.35 + f64(split_job.silence) * 0.15), .Ghost, !split_job.running) {
        split_job.silence = (split_job.silence + 1) % 4
        split_job.ready = false
    }
    cy += px(28)
    if button(rect(x, cy, w, px(26)), split_job.running ? "Cancel splitting" : "Find silences", .Ghost) {
        if split_job.running { stop_split(); set_owned(&split_job.detail, "Cancelled; completed files kept") } else { start_split(t, false) }
    }
    cy += px(32)
    if split_job.path == t.path {
        draw_text(.Regular, elide_right(split_job.detail, w, FS_SMALL), x, cy, FS_SMALL, TEXT_DIM)
        cy += px(20)
        if split_job.ready && !split_job.running {
            first := min(split_job.page * 8, len(split_job.clips))
            last := min(first + 8, len(split_job.clips))
            for clip, i in split_job.clips[first:last] {
                if button(rect(x, cy, w, px(22)), fmt.ctprintf("%d   %s - %s", first+i+1, fmt_time(f32(clip[0])), fmt_time(f32(clip[1]))), .Ghost, player.track == app.selected) {
                    player.sel_start = f32(clip[0]); player.sel_end = f32(clip[1]); seek_to(f32(clip[0]))
                }
                cy += px(24)
            }
            if len(split_job.clips) > 8 {
                if button(rect(x, cy, w/2, px(22)), "Previous", .Ghost, first > 0) { split_job.page -= 1 }
                if button(rect(x+w/2, cy, w/2, px(22)), "Next", .Ghost, last < len(split_job.clips)) { split_job.page += 1 }
                cy += px(24)
            }
            if button(rect(x, cy, w, px(26)), fmt.ctprintf("Create %d WAV files", split_job.count), .Primary) { start_split(t, true) }
            cy += px(32)
        }
    }
    return cy + px(12)
}
