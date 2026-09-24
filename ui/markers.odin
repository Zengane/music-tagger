package musictagger

import "base:runtime"
import "core:encoding/json"
import "core:os"
import "core:strings"
import rl "vendor:raylib"

marker_track: int = -1
marker_edit: int = -1
marker_drag: int = -1

load_track_cues :: proc(t: ^Track, alloc: runtime.Allocator) {
    t.cues.allocator = alloc
    raw, err := os.read_entire_file(sidecar_path(t.path, context.temp_allocator), context.temp_allocator)
    if err != nil { return }
    data: struct { musicTaggerMarkers: []Cue, musicTaggerKind: string, description: string, musicTaggerText: string }
    if json.unmarshal(strip_bom(raw), &data, allocator = context.temp_allocator) != nil { return }
    // For pictures the description is what they show; searchable like a name.
    if t.kind != .Audio {
        if data.description != "" { t.caption = strings.clone(data.description, alloc) }
        if data.musicTaggerText != "" { t.ocr = strings.clone(data.musicTaggerText, alloc) }
    }
    if t.kind == .Audio && (data.musicTaggerKind == "music" || data.musicTaggerKind == "sfx") {
        t.media_kind = strings.clone(data.musicTaggerKind, alloc)
        t.is_sfx = data.musicTaggerKind == "sfx"
    }
    for cue in data.musicTaggerMarkers {
        if !(cue.at >= 0) || cue.at > 86400 { continue }
        append(&t.cues, Cue{cue.at, strings.clone(cue.name, alloc)})
    }
}

mark_cues_dirty :: proc(t: ^Track) {
    t.dirty = true
    t.cues_dirty = true
    invalidate_dirty_count()
}

edit_marker :: proc(track, cue: int) {
    marker_track = track
    marker_edit = cue
    open_tag_editor(.Edit_Marker, "", "")
    field_set(&app.editor_field, lib.tracks[track].cues[cue].name)
}

add_playhead_marker :: proc() {
    if player.track < 0 || player.track >= len(lib.tracks) { return }
    t := &lib.tracks[player.track]
    t.cues.allocator = lib_allocator()
    append(&t.cues, Cue{player_position(), strings.clone("Swell", lib_allocator())})
    mark_cues_dirty(t)
    // Drain the shortcut character before the newly focused field reads it.
    for rl.GetCharPressed() != 0 {}
    edit_marker(player.track, len(t.cues) - 1)
}

draw_marker_controls :: proc(t: ^Track, x, y, w: f32) -> f32 {
    cy := y
    if t.is_sfx { cy = draw_split_controls(t, x, cy, w) }
    section_label(x, cy, "MARKERS")
    cy += px(20)
    if button(rect(x, cy, w, px(24)), "Add at playhead (M)", .Ghost, app.selected == player.track) { add_playhead_marker() }
    cy += px(28)
    remove := -1
    for cue, i in t.cues {
        if button(rect(x, cy, max(w - px(65), px(30)), px(24)), strings.clone_to_cstring(cue.name, context.temp_allocator), .Ghost) { edit_marker(app.selected, i) }
        if icon_button(rect(x + w - px(58), cy, px(24), px(24)), .Play) && app.selected == player.track { seek_to(cue.at) }
        if icon_button(rect(x + w - px(28), cy, px(24), px(24)), .Trash) { remove = i }
        cy += px(28)
    }
    if remove >= 0 { ordered_remove(&t.cues, remove); mark_cues_dirty(t) }
    return cy + px(12)
}

handle_marker_input :: proc(r: Rect) -> bool {
    if player.track < 0 || player.track >= len(lib.tracks) { marker_drag = -1; return false }
    t := &lib.tracks[player.track]
    if marker_drag >= 0 {
        if marker_drag < len(t.cues) {
            t.cues[marker_drag].at = clamp(x_to_seconds(r, ui.mouse.x), 0, player.duration)
            mark_cues_dirty(t)
        }
        if !ui.held { marker_drag = -1; ui.captured = nil }
        return true
    }
    if app.tag_editor { return false }
    for cue, i in t.cues {
        x := seconds_to_x(r, cue.at)
        if !hovered(rect(x - px(5), r.y, px(15), px(RULER_H))) { continue }
        if rl.IsMouseButtonPressed(.RIGHT) { edit_marker(player.track, i); return true }
        if ui.clicked { marker_drag = i; ui.clicked = false; ui.captured = rawptr(&marker_drag); return true }
    }
    if len(t.cues) == 0 && t.features.valid {
        at := t.is_sfx ? t.features.hit : t.features.drop
        x := seconds_to_x(r, at)
        if at > 0 && hovered(rect(x - px(5), r.y, px(15), px(RULER_H))) && ui.clicked {
            t.cues.allocator = lib_allocator()
            append(&t.cues, Cue{at, strings.clone(t.is_sfx ? "Hit" : "Swell", lib_allocator())})
            mark_cues_dirty(t)
            marker_drag = len(t.cues) - 1
            ui.clicked = false
            ui.captured = rawptr(&marker_drag)
            return true
        }
    }
    return false
}

draw_user_markers :: proc(r: Rect) {
    if player.track < 0 || player.track >= len(lib.tracks) { return }
    start, length := player_view()
    for cue in lib.tracks[player.track].cues {
        if cue.at < start || cue.at > start + length { continue }
        x := seconds_to_x(r, cue.at)
        fill(rect(x, r.y, max(px(1), 1), r.height), ACCENT)
        tri({x, r.y}, {x + px(9), r.y + px(5)}, {x, r.y + px(11)}, ACCENT)
        if hovered(rect(x - px(6), r.y, px(18), r.height)) {
            draw_text(.Regular, strings.clone_to_cstring(cue.name, context.temp_allocator), x + px(11), r.y, FS_LABEL, ACCENT)
        }
    }
}
