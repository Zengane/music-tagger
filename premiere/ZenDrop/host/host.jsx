/*
 * Zen Drop - ExtendScript half.
 *
 * One job: take a file path from outside Premiere, put it in a bin, and lay it
 * on the first timeline track that has room at the playhead, without pushing or
 * covering anything that is already there.
 *
 * Why overwriteClip and not insertClip: insertClip ripples the track, which
 * moves work the user already placed. overwriteClip only destroys something if
 * the span is occupied - so the whole trick is refusing to call it until we
 * have found a span that is empty. That check is zdTrackFree().
 */

var ZD_TICKS_PER_SECOND = 254016000000;

/* ---------- tiny JSON writer (ExtendScript has no JSON object) ---------- */

function zdEsc(s) {
    s = String(s);
    s = s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
    s = s.replace(/\r/g, "\\r").replace(/\n/g, "\\n").replace(/\t/g, "\\t");
    return s;
}

function zdJson(obj) {
    var parts = [];
    for (var k in obj) {
        if (!obj.hasOwnProperty(k)) { continue; }
        var v = obj[k];
        var piece;
        if (v === null || v === undefined) { piece = "null"; }
        else if (typeof v === "number") { piece = isFinite(v) ? String(v) : "null"; }
        else if (typeof v === "boolean") { piece = v ? "true" : "false"; }
        else { piece = '"' + zdEsc(v) + '"'; }
        parts.push('"' + zdEsc(k) + '":' + piece);
    }
    return "{" + parts.join(",") + "}";
}

function zdFail(msg) { return zdJson({ ok: false, error: String(msg) }); }

/* ---------- helpers ---------- */

function zdBool(v) { return v === true || v === "true" || v === 1 || v === "1"; }

function zdNormPath(p) {
    return String(p).replace(/\//g, "\\").toLowerCase();
}

function zdExt(p) {
    var m = String(p).match(/\.([A-Za-z0-9]+)\s*$/);
    return m ? m[1].toLowerCase() : "";
}

var ZD_AUDIO_EXT = ["wav", "mp3", "aac", "m4a", "flac", "aif", "aiff", "ogg", "wma", "opus"];
var ZD_STILL_EXT = ["png", "jpg", "jpeg", "psd", "tif", "tiff", "gif", "bmp", "tga", "exr", "webp", "ai", "eps", "dpx", "svg"];

function zdInList(list, v) {
    for (var i = 0; i < list.length; i++) { if (list[i] === v) { return true; } }
    return false;
}

/*
 * What kind of tracks this file needs.
 *   "audio" - audio track only
 *   "video" - video track only (stills)
 *   "both"  - video track, and Premiere lays the audio on the audio track of
 *             the same index, so that one must be free too
 */
function zdMediaKind(path, checkAudio) {
    var e = zdExt(path);
    if (zdInList(ZD_AUDIO_EXT, e)) { return "audio"; }
    if (zdInList(ZD_STILL_EXT, e)) { return "video"; }
    return checkAudio ? "both" : "video";
}

function zdTimeFromTicks(ticks) {
    var t = new Time();
    t.ticks = String(Math.round(ticks));
    return t;
}

/* ---------- bin ---------- */

function zdIsBin(item) {
    try { return item.type === ProjectItemType.BIN; } catch (e) { return item.type === 2; }
}

function zdFindBin(name) {
    var kids = app.project.rootItem.children;
    for (var i = 0; i < kids.numItems; i++) {
        var c = kids[i];
        if (zdIsBin(c) && String(c.name) === String(name)) { return c; }
    }
    return null;
}

function zdFindOrCreateBin(name) {
    var b = zdFindBin(name);
    if (b) { return b; }
    app.project.rootItem.createBin(String(name));
    return zdFindBin(name);
}

/* ---------- project item lookup ---------- */

function zdCollectIds(item, out) {
    var kids;
    try { kids = item.children; } catch (e) { return out; }
    if (!kids) { return out; }
    for (var i = 0; i < kids.numItems; i++) {
        var c = kids[i];
        try { out[String(c.nodeId)] = true; } catch (e2) {}
        zdCollectIds(c, out);
    }
    return out;
}

function zdFindNew(item, known, found) {
    var kids;
    try { kids = item.children; } catch (e) { return found; }
    if (!kids) { return found; }
    for (var i = 0; i < kids.numItems && !found.item; i++) {
        var c = kids[i];
        var id = null;
        try { id = String(c.nodeId); } catch (e2) {}
        if (id && !known[id] && !zdIsBin(c)) { found.item = c; return found; }
        zdFindNew(c, known, found);
    }
    return found;
}

function zdFindByPath(item, wanted, found) {
    var kids;
    try { kids = item.children; } catch (e) { return found; }
    if (!kids) { return found; }
    for (var i = 0; i < kids.numItems && !found.item; i++) {
        var c = kids[i];
        try {
            var mp = c.getMediaPath();
            if (mp && zdNormPath(mp) === wanted) { found.item = c; return found; }
        } catch (e2) {}
        zdFindByPath(c, wanted, found);
    }
    return found;
}

/*
 * Import one file and hand back its ProjectItem.
 * Premiere does not always honour the target bin argument, so the item is moved
 * into the bin afterwards when it lands somewhere else.
 */
function zdImport(path, binName) {
    var bin = zdFindOrCreateBin(binName);
    if (!bin) { throw new Error("Could not create bin: " + binName); }

    var known = zdCollectIds(app.project.rootItem, {});
    app.project.importFiles([String(path)], true, bin, false);

    var item = zdFindNew(app.project.rootItem, known, { item: null }).item;
    if (!item) {
        /* Nothing new: Premiere reused an item already in the project. */
        item = zdFindByPath(app.project.rootItem, zdNormPath(path), { item: null }).item;
    }
    if (!item) { throw new Error("Import produced no project item for: " + path); }

    try {
        if (!item.parent || String(item.parent.nodeId) !== String(bin.nodeId)) { item.moveBin(bin); }
    } catch (e) {}

    return item;
}

/* ---------- free space ---------- */

function zdSpanBusy(collection, s, e) {
    if (!collection) { return false; }
    for (var i = 0; i < collection.numItems; i++) {
        var c = collection[i];
        var cs, ce;
        try { cs = Number(c.start.ticks); ce = Number(c.end.ticks); } catch (err) { continue; }
        if (cs < e && ce > s) { return true; }
    }
    return false;
}

function zdTrackFree(track, s, e, skipLocked) {
    if (!track) { return false; }
    if (skipLocked) {
        try { if (track.isLocked()) { return false; } } catch (err) {}
    }
    if (zdSpanBusy(track.clips, s, e)) { return false; }
    if (zdSpanBusy(track.transitions, s, e)) { return false; }
    return true;
}

/*
 * Lowest track index with room. For "both", the video track and the audio track
 * of the same index must both be free.
 */
function zdFindFreeIndex(seq, kind, s, e, skipLocked) {
    var v = seq.videoTracks, a = seq.audioTracks, i;
    if (kind === "audio") {
        for (i = 0; i < a.numTracks; i++) {
            if (zdTrackFree(a[i], s, e, skipLocked)) { return i; }
        }
        return -1;
    }
    for (i = 0; i < v.numTracks; i++) {
        if (!zdTrackFree(v[i], s, e, skipLocked)) { continue; }
        if (kind === "both") {
            if (i >= a.numTracks) { continue; }
            if (!zdTrackFree(a[i], s, e, skipLocked)) { continue; }
        }
        return i;
    }
    return -1;
}

/* Append tracks. Counts of 0 are allowed, so one side can grow alone. */
function zdAddTracks(seq, addV, addA) {
    try { app.enableQE(); } catch (e) { return false; }
    var qs = null;
    try { qs = qe.project.getActiveSequence(); } catch (e2) { return false; }
    if (!qs) { return false; }

    var numV = seq.videoTracks.numTracks, numA = seq.audioTracks.numTracks;
    try {
        qs.addTracks(addV, numV, addA, numA, 1, 0, 0);
    } catch (e3) {
        return false;
    }
    var after = app.project.activeSequence;
    return (after.videoTracks.numTracks >= numV + addV) && (after.audioTracks.numTracks >= numA + addA);
}

var ZD_MAX_NEW_TRACKS = 16;

/*
 * Grow the sequence until the clip has somewhere to land, then hand back the
 * fresh sequence and the index to use.
 *
 * A clip with audio needs one index that exists AND is free on the video side
 * and the audio side, because Premiere lays the audio on the audio track of the
 * same number. A sequence with 10 video tracks and 4 audio tracks can therefore
 * only ever use indexes 1-4, and a long clip is likely to collide across all
 * four - that is the "added tracks but still no room" failure.
 *
 * Tracks are added one at a time, re-reading the sequence after each step,
 * because a single large addTracks call is the part that proved unreliable.
 */
function zdEnsureRoom(kind, s, e, skipLocked) {
    var seq = app.project.activeSequence;
    var idx = zdFindFreeIndex(seq, kind, s, e, skipLocked);
    if (idx >= 0) { return { seq: seq, idx: idx, added: false }; }

    for (var n = 0; n < ZD_MAX_NEW_TRACKS; n++) {
        var numV = seq.videoTracks.numTracks, numA = seq.audioTracks.numTracks;
        var addV = 0, addA = 0;

        if (kind === "audio") {
            addA = 1;
        } else if (kind === "video") {
            addV = 1;
        } else if (numV < numA) {
            addV = 1;              /* level up the short side first */
        } else if (numA < numV) {
            addA = 1;
        } else {
            addV = 1; addA = 1;    /* level: a new pair is needed */
        }

        if (!zdAddTracks(seq, addV, addA)) {
            throw new Error("No free track, and adding one failed at " + numV + "V/" + numA + "A.");
        }

        /* Re-fetch: the Sequence object hands back stale track collections
           after the QE DOM changes the layout underneath it. */
        seq = app.project.activeSequence;

        idx = zdFindFreeIndex(seq, kind, s, e, skipLocked);
        if (idx >= 0) { return { seq: seq, idx: idx, added: true }; }
    }

    throw new Error("Added " + ZD_MAX_NEW_TRACKS + " tracks and still no room (" + kind + ", " +
        seq.videoTracks.numTracks + "V/" + seq.audioTracks.numTracks + "A).");
}

function zdSelectAt(track, s) {
    try {
        var clips = track.clips;
        for (var i = 0; i < clips.numItems; i++) {
            if (Number(clips[i].start.ticks) === s) { clips[i].setSelected(true, true); return; }
        }
    } catch (e) {}
}


/* ---------- a range of the source, and a marker on it ---------- */

/*
 * Trim the project item to a span of the source, in seconds.
 *
 * zdPlace already lays down whatever the item's in and out points describe, so
 * setting them here is all it takes for a drop to place a selection rather than
 * a whole file - and the media on the timeline is still the original, with the
 * handles intact to trim back out to.
 *
 * setInPoint's second argument is the media type. 4 is "video and audio"; some
 * builds refuse the argument entirely, so the one-argument form is the fallback
 * rather than an error.
 */
/*
 * Back to the whole file. Premiere reuses the project item when the same file
 * is sent again, and the item keeps the in/out of the last ranged send: a
 * whole-track send after a ranged one placed the old range.
 */
function zdClearRange(item) {
    try { item.clearInPoint(); } catch (e) {}
    try { item.clearOutPoint(); } catch (e2) {}
}

function zdSetRange(item, inSec, outSec) {
    if (!(outSec > inSec)) { return false; }
    var ok = false;
    try { item.setInPoint(inSec, 4); item.setOutPoint(outSec, 4); ok = true; }
    catch (e) {
        try { item.setInPoint(inSec); item.setOutPoint(outSec); ok = true; } catch (e2) {}
    }
    return ok;
}

/*
 * A marker on the clip itself, not on the sequence.
 *
 * A sequence marker sits on the timeline: it stays where it is when the clip
 * moves, and it belongs to the sequence rather than to the sound. A clip marker
 * travels with the media, which is what makes it useful for lining other clips
 * up against - drag the sound somewhere else and the sync point goes with it,
 * and it snaps when you drag other things against it.
 *
 * Clip markers live on the project item and are measured in *source* time, so
 * no offset arithmetic is needed: the marker goes at the second of the file
 * where the hit is, wherever that file later ends up on a timeline.
 */
function zdMarkClip(item, sourceSeconds, name) {
    if (!item) { return false; }
    try {
        var markers = item.getMarkers();
        if (!markers) { return false; }

        /* Not twice in the same place: dropping the same effect five times
           should not leave five markers stacked on one frame of the source. */
        try {
            for (var i = 0; i < markers.numMarkers; i++) {
                var existing = i === 0 ? markers.getFirstMarker() : markers.getNextMarker(existing);
                if (!existing) { break; }
                if (Math.abs(Number(existing.start.seconds) - sourceSeconds) < 0.01) { return true; }
            }
        } catch (eScan) {}

        var m = markers.createMarker(sourceSeconds);
        if (m && name) { m.name = String(name); }
        return true;
    } catch (e) { return false; }
}

/*
 * A sequence marker, kept for the cases where the sound is not the thing being
 * marked - nothing calls it today, and it is here because the two are easy to
 * confuse and the difference is worth writing down.
 */
function zdMarkAt(seq, seconds, name) {
    try {
        var m = seq.markers.createMarker(seconds);
        if (m && name) { m.name = String(name); }
        return true;
    } catch (e) { return false; }
}

function zdNum(v, fallback) {
    var n = Number(v);
    return isFinite(n) ? n : fallback;
}

/* ---------- placement ---------- */

function zdPlace(item, opts) {
    var seq = app.project.activeSequence;
    if (!seq) { throw new Error("No active sequence."); }

    var start = Number(seq.getPlayerPosition().ticks);

    /* Frame-align, so a scrubbed playhead cannot leave a sub-frame sliver. */
    var tb = Number(seq.timebase);
    if (tb > 0) { start = Math.round(start / tb) * tb; }

    var inT = 0, outT = 0;
    try { inT = Number(item.getInPoint().ticks); } catch (e) {}
    try { outT = Number(item.getOutPoint().ticks); } catch (e2) {}
    var dur = outT - inT;
    /* The sender knows the length; five seconds is only the last resort, and
       a short guess lets the free-space check pass for a long file whose
       overwrite then covers later clips. */
    if (!(dur > 0) && opts.durSeconds > 0) { dur = opts.durSeconds * ZD_TICKS_PER_SECOND; }
    if (!(dur > 0)) { dur = 5 * ZD_TICKS_PER_SECOND; }
    var end = start + dur;

    var mediaPath = "";
    try { mediaPath = item.getMediaPath(); } catch (e3) { mediaPath = String(item.name); }
    var kind = zdMediaKind(mediaPath, opts.checkAudio);

    var idx = zdFindFreeIndex(seq, kind, start, end, opts.skipLocked);
    var added = false;
    if (idx < 0) {
        if (opts.fallback !== "newtrack") {
            throw new Error("No track has free space at the playhead (" + kind + ", " +
                seq.videoTracks.numTracks + "V/" + seq.audioTracks.numTracks + "A" +
                ", start " + (start / ZD_TICKS_PER_SECOND).toFixed(2) + "s" +
                ", length " + (dur / ZD_TICKS_PER_SECOND).toFixed(2) + "s).");
        }
        var room = zdEnsureRoom(kind, start, end, opts.skipLocked);
        seq = room.seq;
        idx = room.idx;
        added = room.added;
    }

    var track = (kind === "audio") ? seq.audioTracks[idx] : seq.videoTracks[idx];
    track.overwriteClip(item, zdTimeFromTicks(start));
    zdSelectAt(track, start);

    /* The sync point, if one was asked for. On the clip, in source time, so it
       travels with the sound instead of staying where the timeline was. */
    var marked = false;
    if (opts.markSeconds >= 0) {
        marked = zdMarkClip(item, opts.markSeconds, opts.markName || "hit");
    }

    return zdJson({
        ok: true,
        name: String(item.name),
        kind: kind,
        track: (kind === "audio" ? "A" : "V") + (idx + 1),
        addedTrack: added,
        marked: marked,
        startSeconds: start / ZD_TICKS_PER_SECOND,
        durationSeconds: dur / ZD_TICKS_PER_SECOND
    });
}


/* ---------- trimming a clip that Windows dropped ---------- */

/*
 * Premiere never tells an extension where a drag was dropped, so a drop cannot
 * be intercepted and placed. What can be done is to let Premiere handle the
 * drop normally - the whole file lands wherever the pointer let go - and then
 * come back and trim that clip down to the part that was actually wanted.
 *
 * Finding the clip: the one just dropped is the selected one, which is what
 * Premiere does with a fresh drop. If nothing is selected (the user clicked
 * elsewhere first) the last clip on the timeline whose media matches the path
 * is the next best guess, and being wrong there means trimming a clip of the
 * same file somewhere else - which is why selection is tried first.
 */
function zdMatchingClips(seq, wantedPath) {
    var out = [], i, k, tracks, clips, c, mp;
    var groups = [{ tracks: seq.videoTracks, kind: "video" },
                  { tracks: seq.audioTracks, kind: "audio" }];
    for (var g = 0; g < groups.length; g++) {
        tracks = groups[g].tracks;
        for (i = 0; i < tracks.numTracks; i++) {
            clips = tracks[i].clips;
            for (k = 0; k < clips.numItems; k++) {
                c = clips[k];
                mp = "";
                try { mp = c.projectItem.getMediaPath(); } catch (e) { continue; }
                if (mp && zdNormPath(mp) === wantedPath) {
                    /* The track and index travel with the clip: a replacement
                       has to go back exactly where the original was. */
                    out.push({ clip: c, track: tracks[i], kind: groups[g].kind, index: i });
                }
            }
        }
    }
    return out;
}

function zdPickDropped(found) {
    var i;
    for (i = 0; i < found.length; i++) {
        try { if (found[i].clip.isSelected()) { return found[i]; } } catch (e) {}
    }
    /* Nothing selected: the one that starts latest. */
    var best = null, bestStart = -1, st;
    for (i = 0; i < found.length; i++) {
        try { st = Number(found[i].clip.start.ticks); } catch (e) { continue; }
        if (st > bestStart) { bestStart = st; best = found[i]; }
    }
    return best;
}

/*
 * Trim `clip` to the span of source between inSec and outSec, keeping its
 * position on the timeline.
 *
 * inPoint is source time and end is sequence time, so both have to move: the
 * clip must start at the same frame it was dropped on and run for exactly the
 * length of the selection.
 */
function zdTrimClip(clip, inSec, outSec) {
    var startTicks = Number(clip.start.ticks);
    var lengthTicks = Math.round((outSec - inSec) * ZD_TICKS_PER_SECOND);
    if (!(lengthTicks > 0)) { throw new Error("The selection has no length."); }

    /* End first. Shortening before moving the source in point means the clip
       never has to grow past whatever sits to its right. */
    try { clip.end = zdTimeFromTicks(startTicks + lengthTicks); } catch (e) {}

    var inTime = zdTimeFromTicks(Math.round(inSec * ZD_TICKS_PER_SECOND));
    try { clip.inPoint = inTime; }
    catch (e2) { throw new Error("Premiere refused to move the clip's in point: " + e2.toString()); }

    /* Setting the in point can drag the end along with it, so it is put back. */
    try { clip.end = zdTimeFromTicks(startTicks + lengthTicks); } catch (e3) {}
    try { clip.start = zdTimeFromTicks(startTicks); } catch (e4) {}

    return { startTicks: startTicks, lengthTicks: lengthTicks };
}

/*
 * Called after a drag from another app has landed on the timeline: trim the
 * clip that just arrived down to the selection, and mark the sync point.
 */
function zdTrimDropped(path, inSec, outSec, markSec) {
    try {
        var seq = app.project ? app.project.activeSequence : null;
        if (!seq) { return zdFail("No active sequence."); }

        var i0 = zdNum(inSec, -1), i1 = zdNum(outSec, -1), mk = zdNum(markSec, -1);
        if (!(i0 >= 0 && i1 > i0)) { return zdFail("No range was given."); }

        var found = zdMatchingClips(seq, zdNormPath(path));
        if (found.length === 0) {
            return zdFail("That file is not on the timeline - was it dropped somewhere else?");
        }
        var hit = zdPickDropped(found);
        if (!hit) { return zdFail("Could not tell which clip was just dropped."); }

        var clip = hit.clip;
        var placed = zdTrimClip(clip, i0, i1);

        var marked = false;
        if (mk >= i0 && mk <= i1) {
            var item = null;
            try { item = clip.projectItem; } catch (eItem) {}
            marked = zdMarkClip(item, mk, "hit");
        }

        return zdJson({
            ok: true,
            name: String(clip.name),
            marked: marked,
            startSeconds: placed.startTicks / ZD_TICKS_PER_SECOND,
            durationSeconds: placed.lengthTicks / ZD_TICKS_PER_SECOND
        });
    } catch (err) {
        return zdFail(err.toString());
    }
}


/* ---------- replacing the clip under the drop (Alt held) ---------- */

/*
 * Premiere's own Alt-drag replace only works for drags that start inside
 * Premiere. A drop from Windows is a plain overwrite: the placeholder cuts a
 * hole in the song it lands on, and the rest of that song stays.
 *
 * So the app reads Alt itself and does the replace here. Once the drop has
 * landed there is no way to tell which clip used to be under it - the drop has
 * already cut it up - so the app asks for this picture of the sequence when
 * the drag starts, and the swap reads it afterwards.
 *
 * Plain data plus the project item: TrackItem objects go stale as soon as the
 * timeline changes under them.
 */
var zdSnap = null;

function zdClipPath(c) {
    try { return zdNormPath(c.projectItem.getMediaPath()); } catch (e) { return ""; }
}

function zdSnapshot() {
    zdSnap = null;
    try {
        var seq = app.project ? app.project.activeSequence : null;
        if (!seq) { return zdFail("No active sequence."); }
        /* Audio tracks only: the placeholder is always a WAV, and this
           runs on Premiere's main thread while the user is dragging. */
        var out = [];
        var groups = [{ tracks: seq.audioTracks, kind: "audio" }];
        for (var g = 0; g < groups.length; g++) {
            var tracks = groups[g].tracks;
            for (var i = 0; i < tracks.numTracks; i++) {
                var clips = tracks[i].clips;
                for (var k = 0; k < clips.numItems; k++) {
                    var c = clips[k];
                    var rec = { kind: groups[g].kind, index: i, item: null, path: zdClipPath(c) };
                    try {
                        rec.start = Number(c.start.ticks);
                        rec.end = Number(c.end.ticks);
                        rec.inT = Number(c.inPoint.ticks);
                        rec.outT = Number(c.outPoint.ticks);
                    } catch (eT) { continue; }
                    try { rec.item = c.projectItem; } catch (eI) {}
                    out.push(rec);
                }
            }
        }
        zdSnap = { seq: String(seq.sequenceID), clips: out };
        return zdJson({ ok: true, clips: out.length });
    } catch (err) {
        return zdFail(err.toString());
    }
}

function zdOverlap(rec, s, e) {
    return Math.min(rec.end, e) - Math.max(rec.start, s);
}

/* The clip that was under most of the placeholder before it landed. */
function zdOldUnder(seq, hit, s, e, placeholderNorm) {
    if (!zdSnap || zdSnap.seq !== String(seq.sequenceID)) { return null; }
    var best = null, bestOverlap = 0;
    for (var i = 0; i < zdSnap.clips.length; i++) {
        var rec = zdSnap.clips[i];
        if (rec.kind !== hit.kind || rec.index !== hit.index) { continue; }
        if (rec.path === placeholderNorm) { continue; }
        var o = zdOverlap(rec, s, e);
        if (o > bestOverlap) { bestOverlap = o; best = rec; }
    }
    return best;
}

/* Remove every clip on the track that `test` picks. Collected first: the
   collection re-indexes as clips go. Returns how many refused. */
function zdRemoveClips(track, test) {
    var doomed = [], clips = track.clips, k;
    for (k = 0; k < clips.numItems; k++) {
        try { if (test(clips[k])) { doomed.push(clips[k]); } } catch (e) {}
    }
    var refused = 0;
    for (k = 0; k < doomed.length; k++) {
        try { doomed[k].remove(false, false); } catch (e2) { refused += 1; }
    }
    return refused;
}

/*
 * Put back a clip the placeholder covered. Only plain audio: a clip from a
 * video file would bring its picture along onto a video track.
 *
 * What comes back is the same media over the same span. Effects and
 * keyframes on the original are gone - the drop destroyed them, not this.
 */
function zdRestoreClip(track, rec) {
    if (!rec.item || rec.kind !== "audio" || zdMediaKind(rec.path, true) !== "audio") { return false; }
    var item = rec.item, oldIn = -1, oldOut = -1, ok = false;
    try { oldIn = Number(item.getInPoint().seconds); oldOut = Number(item.getOutPoint().seconds); } catch (e) {}
    if (!zdSetRange(item, rec.inT / ZD_TICKS_PER_SECOND, rec.outT / ZD_TICKS_PER_SECOND)) { return false; }
    try { track.overwriteClip(item, zdTimeFromTicks(rec.start)); ok = true; } catch (e2) {}
    if (oldOut > oldIn && oldIn >= 0) { zdSetRange(item, oldIn, oldOut); } else { zdClearRange(item); }
    return ok;
}

/*
 * The replace itself: the new sound takes the old clip's exact slot - same
 * start, same length - played from the start of the selection. That is what
 * Premiere's own Alt-replace does, and the edit's timing does not move. A file
 * that ends before the slot does leaves the rest of the slot empty.
 */
function zdReplaceSlot(seq, hit, old, placeholderNorm, realPath, inSec, fileSec, markSec, binName) {
    var track = hit.track;
    var ps = Number(hit.clip.start.ticks), pe = Number(hit.clip.end.ticks);
    var placeholderItem = null;
    try { placeholderItem = hit.clip.projectItem; } catch (e) {}

    var lenSec = (old.end - old.start) / ZD_TICKS_PER_SECOND;
    if (fileSec > inSec && inSec + lenSec > fileSec) { lenSec = fileSec - inSec; }
    var outSec = inSec + lenSec;

    var item = zdImport(realPath, binName);
    zdSetRange(item, inSec, outSec);

    /* Clear the slot: what is left of the old song, and the placeholder
       wherever it reaches - it can hang past either end of the slot. */
    var tb = Number(seq.timebase);
    var eps = tb > 0 ? tb / 2 : 0;
    var refused = zdRemoveClips(track, function (c) {
        var p = zdClipPath(c);
        if (p === placeholderNorm) { return true; }
        if (p !== old.path) { return false; }
        return Number(c.start.ticks) >= old.start - eps && Number(c.end.ticks) <= old.end + eps;
    });

    track.overwriteClip(item, zdTimeFromTicks(old.start));
    zdSelectAt(track, old.start);

    /* The drop was an overwrite, so a placeholder longer than the room it
       landed in cut into the clips next door. Put them back. */
    var lost = 0;
    for (var i = 0; i < zdSnap.clips.length; i++) {
        var rec = zdSnap.clips[i];
        if (rec === old || rec.kind !== hit.kind || rec.index !== hit.index) { continue; }
        if (rec.path === placeholderNorm || zdOverlap(rec, ps, pe) <= 0) { continue; }
        if (!zdRestoreClip(track, rec)) { lost += 1; }
    }

    try { if (placeholderItem) { placeholderItem.deleteBin(); } } catch (e2) {}

    var marked = false;
    if (markSec >= inSec && markSec <= outSec) { marked = zdMarkClip(item, markSec, "hit"); }

    return zdJson({
        ok: true,
        replaced: true,
        name: String(item.name),
        track: (hit.kind === "audio" ? "A" : "V") + (hit.index + 1),
        marked: marked,
        refused: refused,
        lost: lost,
        startSeconds: old.start / ZD_TICKS_PER_SECOND,
        durationSeconds: lenSec
    });
}


/* ---------- swapping a placeholder for the real thing ---------- */

/*
 * The drag problem, and why this is the better half of the answer.
 *
 * Premiere never tells an extension where a drag was dropped, so a drop cannot
 * be caught and placed. Dropping the original file and trimming it afterwards
 * works, but for the moment between the two the timeline holds a clip the full
 * length of the song - which is the wrong length to be looking at while you
 * decide where it goes, and it can cover work to its right.
 *
 * So the app drags a short rendered file that is exactly as long as the
 * selection. Premiere places that, the length is right from the first frame,
 * and then this swaps it for the original with in and out points set. The media
 * on the timeline ends up being the real file, with handles, and nothing was
 * ever the wrong size.
 *
 * If this fails the placeholder simply stays: it is the correct audio, so the
 * worst case is the old behaviour of a rendered clip rather than a broken edit.
 */
/*
 * `replace` (Alt was held at the drop): the new sound takes the slot of the
 * clip it was dropped on - see zdReplaceSlot. `fileSec` is the real file's
 * length, so a slot longer than what is left of the file is not overrun.
 * With nothing under the drop, it is an ordinary swap.
 */
function zdSwapPlaceholder(placeholderPath, realPath, inSec, outSec, markSec, binName, replace, fileSec) {
    try {
        var seq = app.project ? app.project.activeSequence : null;
        if (!seq) { return zdFail("No active sequence."); }

        var i0 = zdNum(inSec, -1), i1 = zdNum(outSec, -1), mk = zdNum(markSec, -1);
        if (!(i0 >= 0 && i1 > i0)) { return zdFail("No range was given."); }

        var placeholderNorm = zdNormPath(placeholderPath);
        var found = zdMatchingClips(seq, placeholderNorm);
        if (found.length === 0) {
            return zdFail("The dropped clip is not on the timeline - was it dropped somewhere else?");
        }
        var hit = zdPickDropped(found);
        if (!hit) { return zdFail("Could not tell which clip was just dropped."); }

        var startTicks = Number(hit.clip.start.ticks);

        var note = "";
        if (zdBool(replace)) {
            var old = zdOldUnder(seq, hit, startTicks, Number(hit.clip.end.ticks), placeholderNorm);
            if (old) {
                return zdReplaceSlot(seq, hit, old, placeholderNorm, realPath, i0,
                                     zdNum(fileSec, -1), mk, binName);
            }
            note = zdSnap ? "nothing was under the drop to replace" : "no picture of the timeline from the drag start";
        }
        var placeholderItem = null;
        try { placeholderItem = hit.clip.projectItem; } catch (e) {}

        /* The real file, trimmed to the selection before it is laid down, so
           overwriteClip covers exactly the span the placeholder occupied. */
        var item = zdImport(realPath, binName);
        zdSetRange(item, i0, i1);

        hit.track.overwriteClip(item, zdTimeFromTicks(startTicks));
        zdSelectAt(hit.track, startTicks);

        /* The placeholder is a temporary file the app wrote; leaving its
           project item behind would fill the bin with them. The clip itself is
           already gone - overwriteClip covered it. */
        try { if (placeholderItem) { placeholderItem.deleteBin(); } } catch (e2) {}

        var marked = false;
        if (mk >= i0 && mk <= i1) {
            marked = zdMarkClip(item, mk, "hit");
        }

        return zdJson({
            ok: true,
            name: String(item.name),
            track: (hit.kind === "audio" ? "A" : "V") + (hit.index + 1),
            marked: marked,
            note: note,
            startSeconds: startTicks / ZD_TICKS_PER_SECOND,
            durationSeconds: i1 - i0
        });
    } catch (err) {
        return zdFail(err.toString());
    } finally {
        /* One picture per drag: a later drag must not read this one. */
        zdSnap = null;
    }
}

/* ---------- entry points called from the panel ---------- */

/*
 * mode "timeline" - import and place now.
 * mode "source"   - import and load the Source Monitor, place later.
 */
function zdDrop(path, mode, binName, fallback, checkAudio, skipLocked, inSec, outSec, markSec, durSec) {
    try {
        if (!app.project) { return zdFail("No project is open."); }
        var item = zdImport(path, binName);

        /* Absent, or -1, means the whole file - which is what a plain drop
           from Listary sends. */
        var i0 = zdNum(inSec, -1), i1 = zdNum(outSec, -1), mk = zdNum(markSec, -1);
        if (i0 >= 0 && i1 > i0) { zdSetRange(item, i0, i1); }
        else { zdClearRange(item); }

        if (String(mode) === "source") {
            try {
                app.sourceMonitor.openProjectItem(item);
            } catch (e) {
                return zdFail("Imported, but the Source Monitor refused it: " + e.toString());
            }
            return zdJson({ ok: true, name: String(item.name), staged: true });
        }

        return zdPlace(item, {
            fallback: String(fallback),
            checkAudio: zdBool(checkAudio),
            skipLocked: zdBool(skipLocked),
            markSeconds: mk,
            markName: "hit",
            durSeconds: (i0 >= 0 && i1 > i0) ? (i1 - i0) : zdNum(durSec, -1)
        });
    } catch (err) {
        return zdFail(err.toString());
    }
}

/* Place whatever is loaded in the Source Monitor, honouring its in/out points. */
function zdPlaceFromSource(fallback, checkAudio, skipLocked) {
    try {
        var item = null;
        try { item = app.sourceMonitor.getProjectItem(); } catch (e) {}
        if (!item) { return zdFail("Nothing is loaded in the Source Monitor."); }
        return zdPlace(item, {
            fallback: String(fallback),
            checkAudio: zdBool(checkAudio),
            skipLocked: zdBool(skipLocked),
            markSeconds: -1
        });
    } catch (err) {
        return zdFail(err.toString());
    }
}

/* Panel status line. */
function zdStatus() {
    try {
        var p = app.project;
        var seq = p ? p.activeSequence : null;
        return zdJson({
            ok: true,
            project: p ? String(p.name) : "",
            sequence: seq ? String(seq.name) : "",
            videoTracks: seq ? seq.videoTracks.numTracks : 0,
            audioTracks: seq ? seq.audioTracks.numTracks : 0
        });
    } catch (err) {
        return zdFail(err.toString());
    }
}
