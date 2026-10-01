package musictagger

// Taking a track out of the in-memory library. Portable; the file itself goes
// to the bin through `recycle_file`, which is per platform.

// Drops a track from the library in memory.
//
// The list is indexed by position from a dozen places — the view, the
// selection, the undo stack — so removing one has to be told to all of them.
// The caller does that; this only takes the entry out and lets go of what it
// owned.
forget_track :: proc(index: int) {
	if index < 0 || index >= len(lib.tracks) { return }

	// The undo stack holds indices into this list, and every one after this
	// point is about to mean a different file. There is no honest way to
	// renumber a stack of past states, so it is thrown away instead.
	undo_clear()
	clear_thumbnails()
	restart_search_server()

	if player.track == index { stop_playback() }
	else if player.track > index { player.track -= 1 }

	// The playing video is held by position too. Left alone, deleting a file
	// above it pointed it past the end of the list, and the next frame
	// stopped the program on a bounds check.
	if video.active || video.decoder != nil {
		if video.index == index { video_close() }
		else if video.index > index { video.index -= 1 }
	}

	ordered_remove(&lib.tracks, index)

	// Every remembered position after the removed one moves down by one.
	for &i in app.selection {
		if i > index { i -= 1 }
	}
	if app.selected > index { app.selected -= 1 }
	else if app.selected == index { app.selected = -1 }
	if app.anchor > index { app.anchor -= 1 }
	if search.anchor > index { search.anchor -= 1 }
	else if search.anchor == index { search.anchor = -1 }
}

// Silences and unloads whatever is playing.
stop_playback :: proc() {
	player.playing = false
	unload_music()
	player.track     = -1
	player.has_peaks = false
	player.duration  = 0
	player.sel_start = 0
	player.sel_end   = 0
	invalidate_clip()
}
