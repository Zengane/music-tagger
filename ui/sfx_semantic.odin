package musictagger

// The effects map: where `sfx_map_job.py` put each sound, which group it is
// in, and its nearest neighbours.
//
// It is meant to work the way the music map does. Dots are placed by what a
// model hears, coloured by the group they belong to, and the groups are
// signposted. On top of that, an effect knows the twenty sounds closest to it
// (read from the embedding, not the plane), so picking one draws lines to its
// nearest sounds and the arrow keys hop along them: Right goes to the closest
// one not yet heard, Left goes back.
//
// Nothing here writes tags. The job keeps the map it replaced next to the new
// one, and Undo swaps the two.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:math"
import rl "vendor:raylib"

sfx_sound_map: Music_Map

// The signposts the map job worked out, in map coordinates.
Sfx_Region :: struct {
    label:  string,
    pos:    [2]f32,
    count:  int,
    spread: f32,
}
sfx_regions: [dynamic]Sfx_Region

// What the job found besides positions. Rows are the job's own order; they
// are resolved to library tracks each time the map is laid out, because the
// library can be rescanned underneath them.
Sfx_Map_Extra :: struct {
    encoder:      string,
    row_of:       map[string]int, // path key -> row
    row_key:      [dynamic]string, // row -> path key (the same strings as row_of's keys)
    group_name:   [dynamic]string, // per row
    nn:           [dynamic]i32,    // `k` per row, closest first
    k:            int,
    track_of_row: [dynamic]int,    // -1 when the file is not in the library
    dot_of_track: map[int]int,     // where a track's dot is in `nodes.dots`
}
sfx_extra: Sfx_Map_Extra

// The way back along a run of hops.
sfx_hop: struct {
    trail:  [dynamic]int,
    follow: bool, // pan to the selected dot when it is off screen
}

// How many of the nearest sounds are drawn around the selected one.
SFX_HOP_SHOW :: 8

sfx_sound_path :: proc() -> string { return join_path({project_root(),"model","sfx-soundmap.json"}) }
sfx_prev_path :: proc() -> string { return join_path({project_root(),"model","sfx-soundmap.prev.json"}) }

reset_sfx_sound_map :: proc() {
    for key in sfx_sound_map.points { delete(key) }
    clear(&sfx_sound_map.points); sfx_sound_map.loaded=false
    for r in sfx_regions { delete(r.label) }
    clear(&sfx_regions)
    for key in sfx_extra.row_of { delete(key) }
    clear(&sfx_extra.row_of)
    clear(&sfx_extra.row_key)
    for name in sfx_extra.group_name { delete(name) }
    clear(&sfx_extra.group_name)
    clear(&sfx_extra.nn); clear(&sfx_extra.track_of_row); clear(&sfx_extra.dot_of_track)
    delete(sfx_extra.encoder); sfx_extra.encoder=""
    sfx_extra.k=0
}

load_sfx_sound_map :: proc() {
    if sfx_sound_map.loaded { return }
    sfx_sound_map.loaded=true
    raw,err:=os.read_entire_file(sfx_sound_path(),context.temp_allocator)
    if err!=nil { return }
    doc: struct {
        encoder: string,
        points: map[string][2]f32,
        regions: []struct { label: string, group: int, pos: [2]f32, count: int, spread: f32 },
        paths: []string,
        group: []int,
        nn: [][]i32,
    }
    if json.unmarshal(raw,&doc,allocator=context.temp_allocator)!=nil { return }
    for path,xy in doc.points { sfx_sound_map.points[strings.clone(path_key(path),context.allocator)]={xy[0],xy[1]} }
    sfx_sound_map.found=len(sfx_sound_map.points)>0
    sfx_extra.encoder=strings.clone(doc.encoder)

    names:=make(map[int]string,context.temp_allocator)
    for r in doc.regions {
        names[r.group]=r.label
        append(&sfx_regions, Sfx_Region{
            label  = strings.clone(r.label, context.allocator),
            pos    = r.pos,
            count  = r.count,
            spread = r.spread,
        })
    }
    // Rows only when the three lists agree; a map from before groups existed
    // simply has none, and still draws.
    if len(doc.paths)==len(doc.group) && len(doc.paths)==len(doc.nn) {
        sfx_extra.k=len(doc.nn)>0 ? len(doc.nn[0]) : 0
        for path,row in doc.paths {
            key:=strings.clone(path_key(path))
            sfx_extra.row_of[key]=row
            append(&sfx_extra.row_key,key)
            append(&sfx_extra.group_name,strings.clone(names[doc.group[row]]))
            for j in 0..<sfx_extra.k { append(&sfx_extra.nn,j<len(doc.nn[row]) ? doc.nn[row][j] : -1) }
        }
    }
}

// How many effects in the library the map has no place for yet.
sfx_unmapped :: proc() -> (unmapped, effects: int) {
    load_sfx_sound_map()
    for &t in lib.tracks {
        if !t.is_sfx { continue }
        effects+=1
        if _,ok:=sfx_sound_map.points[path_key(t.path)]; !ok { unmapped+=1 }
    }
    return
}

start_sfx_map :: proc() {
    if map_job.running || folder_copy.running || scan.running || filing_busy() || job.phase==.Running || job.phase==.Loading { toast("Finish the current job before sorting the effects"); return }
    paths:=make([dynamic]string,0,len(lib.tracks),context.temp_allocator)
    for t in lib.tracks { if t.is_sfx { append(&paths,t.path) } }
    if len(paths)<4 { toast("At least four sound effects are needed"); return }
    path:=join_path({cache_dir("jobs"),"sfx-map-paths.txt"})
    if os.write_entire_file(path,transmute([]byte)strings.join(paths[:],"\n",context.temp_allocator))!=nil { toast("Could not write SFX map input"); return }
    stream,ok:=stream_start({python_exe(),join_path({project_root(),"sfx_map_job.py"}),"--paths-from",path,"--out",sfx_sound_path()},project_root())
    if !ok { toast("Could not start sorting the effects"); return }
    map_job.stream=stream; map_job.running=true; map_job.failed=false; map_job.placed=0
    clear(&map_job.partial)
    set_owned(&map_job.detail,"Reading cached sound analysis")
}

// Whether there is an earlier map to go back to.
sfx_can_undo :: proc() -> bool { return os.exists(sfx_prev_path()) }

// Swaps the map with the one it replaced. Doing it twice is a redo.
undo_sfx_map :: proc() {
    if map_job.running { toast("Wait for the map job to finish"); return }
    cur,prev:=sfx_sound_path(),sfx_prev_path()
    if !os.exists(prev) { toast("No earlier effects map to go back to"); return }
    tmp:=join_path({project_root(),"model","sfx-soundmap.swap.json"})
    if os.exists(cur) && os.rename(cur,tmp)!=nil { toast("Could not swap the effects maps"); return }
    if os.rename(prev,cur)!=nil { _=os.rename(tmp,cur); toast("Could not swap the effects maps"); return }
    if os.exists(tmp) { _=os.rename(tmp,prev) }
    reset_sfx_sound_map()
    invalidate_nodes()
    toast("Effects map swapped with the previous one (press Undo again to swap back)")
}

build_sfx_sound_layout :: proc() -> bool {
    load_sfx_sound_map()
    clear(&sfx_extra.dot_of_track)
    if len(sfx_sound_map.points)==0 { return false }
    nodes.source=.Semantic
    scale:=max(f32(WORLD_R),math.sqrt(f32(len(lib.tracks)))*24)

    resolve_sfx_rows()

    for &t,i in lib.tracks {
        if !t.is_sfx || !kind_allows(&t) { continue }
        key:=path_key(t.path)
        p,ok:=sfx_sound_map.points[key]
        if !ok { continue }
        col:=sound_colour(&t)
        if row,has:=sfx_extra.row_of[key]; has {
            if name:=sfx_extra.group_name[row]; name!="" { col=tag_color_of(name) }
        }
        append(&nodes.dots,Node_Dot{track=i,pos={p.x*scale,p.y*scale},col=col,kind=.SFX})
    }
    if len(nodes.dots)==0 { return false }
    declump()
    // The job's own signposts when it has them, the tag-derived ones only as a
    // fallback for a map built before this existed.
    if !place_sfx_regions(scale) { label_tag_regions() }
    place_untagged()
    for d,i in nodes.dots { sfx_extra.dot_of_track[d.track]=i }
    return true
}

// Puts the job's named regions on the map. Returns whether there were any.
place_sfx_regions :: proc(scale: f32) -> bool {
    if len(sfx_regions)==0 { return false }
    clear(&nodes.anchors)
    for r in sfx_regions {
        append(&nodes.anchors, Node_Anchor{
            tag    = r.label,
            pos    = {r.pos[0]*scale, r.pos[1]*scale},
            count  = r.count,
            kind   = .SFX,
            spread = r.spread*scale,
        })
    }
    return true
}

// Which library track each of the job's rows is. Over the whole library, not
// only what is drawn: an effect the kind filter hides is still a neighbour.
resolve_sfx_rows :: proc() {
    clear(&sfx_extra.track_of_row)
    resize(&sfx_extra.track_of_row,len(sfx_extra.row_key))
    for &v in sfx_extra.track_of_row { v=-1 }
    for &t,i in lib.tracks {
        if !t.is_sfx { continue }
        if row,has:=sfx_extra.row_of[path_key(t.path)]; has { sfx_extra.track_of_row[row]=i }
    }
}

// The nearest sounds to a track, closest first, as track indices. Empty when
// the map has no neighbours for it.
sfx_neighbours :: proc(track: int, allocator := context.temp_allocator) -> []int {
    load_sfx_sound_map()
    out:=make([dynamic]int,0,sfx_extra.k,allocator)
    if track<0 || track>=len(lib.tracks) || sfx_extra.k==0 { return out[:] }
    row,ok:=sfx_extra.row_of[path_key(lib.tracks[track].path)]
    if !ok { return out[:] }
    // Resolved again when the library has moved under the rows (a rescan).
    stale :: proc(n: int) -> bool {
        if n>=len(sfx_extra.track_of_row) { return true }
        t:=sfx_extra.track_of_row[n]
        return t>=len(lib.tracks) || (t>=0 && path_key(lib.tracks[t].path)!=sfx_extra.row_key[n])
    }
    if len(sfx_extra.track_of_row)!=len(sfx_extra.row_key) || stale(row) { resolve_sfx_rows() }
    for j in 0..<sfx_extra.k {
        n:=int(sfx_extra.nn[row*sfx_extra.k+j])
        if n<0 || n>=len(sfx_extra.row_key) { continue }
        if stale(n) { resolve_sfx_rows() }
        if t:=sfx_extra.track_of_row[n]; t>=0 { append(&out,t) }
    }
    return out[:]
}

// The name of the group a track is in, or "".
sfx_group_of :: proc(track: int) -> string {
    if track<0 || track>=len(lib.tracks) { return "" }
    row,ok:=sfx_extra.row_of[path_key(lib.tracks[track].path)]
    if !ok { return "" }
    return sfx_extra.group_name[row]
}

// Whether the arrow keys hop between sounds right now.
sfx_hopping :: proc() -> bool {
    return app.view==.Map && nodes.mode==.Sound && nodes.source==.Semantic && sfx_extra.k>0
}

// Remembers where a hop came from, so Left can go back to it. Called before
// the selection changes, from a click on the map or from the keys.
sfx_hop_from :: proc(from, to: int) {
    if from<0 || from==to { return }
    if len(sfx_hop.trail)>0 && sfx_hop.trail[len(sfx_hop.trail)-1]==from { return }
    append(&sfx_hop.trail,from)
    if len(sfx_hop.trail)>200 { ordered_remove(&sfx_hop.trail,0) }
}

// Right: the closest sound to the current one that has not been heard on this
// run. Left: back one.
sfx_hop_step :: proc(delta: int) {
    if delta<0 {
        if len(sfx_hop.trail)==0 { return }
        back:=pop(&sfx_hop.trail)
        app.selected=back
    } else {
        if app.selected<0 { return }
        seen:=make(map[int]bool,context.temp_allocator)
        for t in sfx_hop.trail { seen[t]=true }
        next:=-1
        for n in sfx_neighbours(app.selected) {
            if !seen[n] { next=n; break }
        }
        if next<0 { toast("Every near sound has been played; press Left to go back"); return }
        sfx_hop_from(app.selected,next)
        app.selected=next
    }
    clear(&app.selection)
    play_track(app.selected)
    sfx_hop.follow=true
}

// Lines from the selected sound to its nearest ones, brightest for the
// closest, and the first five numbered in the order Right will visit them.
draw_sfx_neighbours :: proc(r: Rect, centre: rl.Vector2) {
    if nodes.source!=.Semantic || app.selected<0 { return }
    di,ok:=sfx_extra.dot_of_track[app.selected]
    if !ok || di>=len(nodes.dots) || nodes.dots[di].track!=app.selected { return }
    screen :: proc(p, centre: rl.Vector2) -> rl.Vector2 {
        return {centre.x+(p.x+nodes.pan.x)*nodes.zoom, centre.y+(p.y+nodes.pan.y)*nodes.zoom}
    }
    from:=screen(nodes.dots[di].pos,centre)

    // Keep a hopped-to sound in view.
    if sfx_hop.follow {
        sfx_hop.follow=false
        margin:=px(60)
        if from.x<r.x+margin || from.x>r.x+r.width-margin || from.y<r.y+margin || from.y>r.y+r.height-margin {
            nodes.pan={-nodes.dots[di].pos.x,-nodes.dots[di].pos.y}
            from=screen(nodes.dots[di].pos,centre)
        }
    }

    seen:=make(map[int]bool,context.temp_allocator)
    for t in sfx_hop.trail { seen[t]=true }
    shown,order:=0,0
    for n in sfx_neighbours(app.selected) {
        if shown>=SFX_HOP_SHOW { break }
        ni,has:=sfx_extra.dot_of_track[n]
        if !has { continue }
        shown+=1
        to:=screen(nodes.dots[ni].pos,centre)
        fade:=1-f32(shown-1)/f32(SFX_HOP_SHOW)
        col:=ACCENT
        col.a=u8(60+150*fade)
        if seen[n] { col.a=50 }
        rl.DrawLineEx(from,to,px(1.2),col)
        rl.DrawCircleLinesV(to,px(6),col)
        if !seen[n] && order<5 {
            order+=1
            label:=fmt.ctprintf("%d",order)
            draw_text(.Bold,label,to.x+px(7),to.y-px(16),FS_SMALL,ACCENT)
        }
    }
}

// The effects' half of the Sound tab's controls, under the caption. The same
// pattern as music: a button only when there is something to place, and Undo
// once a map has replaced another.
draw_sfx_map_controls :: proc(x, y: f32) {
    if map_job.running {
        draw_text(.Regular,strings.clone_to_cstring(map_job.detail,context.temp_allocator),x,y+px(3),FS_SMALL,ACCENT)
        if button(rect(x,y+px(24),px(100),px(24)),"Stop",.Ghost) {
            stream_kill(&map_job.stream); stream_close(&map_job.stream); map_job.running=false
            toast("Stopped; sounds analysed so far are kept and will not be redone")
        }
        return
    }
    unmapped,effects:=sfx_unmapped()
    bx:=x
    // A map from before groups and neighbours existed is redone in full.
    old:=sfx_sound_map.found && sfx_extra.k==0
    if effects>=4 && (unmapped>0 || old || !sfx_sound_map.found) {
        label:=fmt.ctprintf("Sort %d effects by sound",effects)
        if sfx_sound_map.found && !old { label=fmt.ctprintf("Map %d new effects",unmapped) }
        bw:=text_w(.Regular,label,FS_SMALL)+px(20)
        if button(rect(bx,y,bw,px(22)),label,.Ghost) { start_sfx_map() }
        bx+=bw+px(6)
    }
    if sfx_can_undo() {
        if button(rect(bx,y,px(60),px(22)),"Undo",.Ghost) { undo_sfx_map() }
    }
}
