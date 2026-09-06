package musictagger
import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:math"
import rl "vendor:raylib"
sfx_sound_map: Music_Map

// The signposts the map job worked out, in map coordinates.
//
// The labels used to come from `label_tag_regions`, which reads the tags a file
// carries — and almost no effect carries one, so a map of several thousand
// sounds had a handful of words on it and several of them described whatever
// tag happened to be nearby. These come from the audio itself: the job scores
// every effect against a vocabulary of plain descriptions and puts a word where
// the files it best describes actually sit.
Sfx_Region :: struct {
    label:  string,
    pos:    [2]f32,
    count:  int,
    spread: f32,
}
sfx_regions: [dynamic]Sfx_Region
sfx_sound_path :: proc() -> string { return join_path({project_root(),"model","sfx-soundmap.json"}) }
load_sfx_sound_map :: proc() {
    if sfx_sound_map.loaded { return }
    sfx_sound_map.loaded=true
    raw,err:=os.read_entire_file(sfx_sound_path(),context.temp_allocator)
    if err!=nil { return }
    doc: struct {
        points: map[string][2]f32,
        regions: []struct { label: string, pos: [2]f32, count: int, spread: f32 },
    }
    if json.unmarshal(raw,&doc,allocator=context.temp_allocator)!=nil { return }
    for path,xy in doc.points { sfx_sound_map.points[strings.to_lower(path,context.allocator)]={xy[0],xy[1]} }

    clear(&sfx_regions)
    for r in doc.regions {
        append(&sfx_regions, Sfx_Region{
            label  = strings.clone(r.label, context.allocator),
            pos    = r.pos,
            count  = r.count,
            spread = r.spread,
        })
    }
}
start_sfx_map :: proc() {
    if map_job.running || folder_copy.running || scan.running || filing_busy() || job.phase==.Running || job.phase==.Loading { toast("Finish the current job before building the sound map"); return }
    paths:=make([dynamic]string,0,len(lib.tracks),context.temp_allocator)
    for t in lib.tracks { if t.is_sfx { append(&paths,t.path) } }
    if len(paths)<4 { toast("At least four sound effects are needed"); return }
    path:=join_path({cache_dir("jobs"),"sfx-map-paths.txt"})
    if os.write_entire_file(path,transmute([]byte)strings.join(paths[:],"\n",context.temp_allocator))!=nil { toast("Could not write SFX map input"); return }
    stream,ok:=stream_start({python_exe(),join_path({project_root(),"sfx_map_job.py"}),"--paths-from",path,"--out",sfx_sound_path()},project_root())
    if !ok { toast("Could not start SFX mapping"); return }
    map_job.stream=stream; map_job.running=true; map_job.failed=false; map_job.placed=0
    clear(&map_job.partial)
    set_owned(&map_job.detail,"Reading cached SFX audio analysis")
}
build_sfx_sound_layout :: proc() -> bool {
    load_sfx_sound_map()
    if len(sfx_sound_map.points)==0 { return false }
    nodes.source=.Semantic
    scale:=max(f32(WORLD_R),math.sqrt(f32(len(lib.tracks)))*24)
    for &t,i in lib.tracks {
        if !t.is_sfx || !kind_allows(&t) { continue }
        p,ok:=sfx_sound_map.points[strings.to_lower(t.path,context.temp_allocator)]
        if !ok { continue }
        append(&nodes.dots,Node_Dot{track=i,pos={p.x*scale,p.y*scale},col=sound_colour(&t),kind=.SFX})
    }
    if len(nodes.dots)==0 { return false }
    declump()
    // The job's own signposts when it has them, the tag-derived ones only as a
    // fallback for a map built before this existed.
    if !place_sfx_regions(scale) { label_tag_regions() }
    place_untagged()
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
