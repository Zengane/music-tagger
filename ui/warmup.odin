package musictagger

// Building every waveform in the library, in the background.
//
// Generating peaks means decoding the whole file, which is dominated by
// reading it off the disk and by ffmpeg's startup — neither of which one
// thread can saturate. Measured on this library, a single worker managed
// about 0.4 files a second, which is over an hour for 1823 tracks. Several
// workers overlap the waiting and finish it in a fraction of that.
//
// The pool never touches `lib`. It is handed copies of the paths it needs, so
// a rescan freeing the library's arena mid-decode is not something that has to
// be locked against — it simply cannot happen. The pool's only output is cache
// files on disk, keyed by path, size and modification time, which is what the
// player reads when a track is opened.

import "core:strings"
import "core:sync"
import "core:thread"

// Two workers, which gets about ten files a second on this library.
//
// Worth knowing, because it was nearly the wrong lesson: an earlier comparison
// had four workers running three times slower than one, and the obvious
// explanation — four decoders thrashing a mechanical drive — was wrong. Both
// configurations were dominated by a polling bug in `run_capture` that spent
// roughly 15 s per file asleep (see `stream_read_wait`). With that fixed the
// same work runs 150 times faster, and the thread count barely matters:
// ffmpeg decodes one of these files in about 0.12 s.
//
// Two is kept because it is measured and it is enough — the whole library
// finishes in under two minutes — and because this runs in the background
// while the machine is being used for something else.
WARM_WORKERS :: 2

Warmup :: struct {
	items:    []Peak_Key,
	storage:  []string, // the copied paths, owned here and freed together
	cursor:   int,      // atomic: the next item to claim
	done:     int,      // atomic: how many have been dealt with
	built:    int,      // atomic: how many were actually decoded
	total:    int,
	threads:  [WARM_WORKERS]^thread.Thread,
	running:  bool,
	stop:     bool,
}

warmup: Warmup

// Starts building peaks for every track that has none.
//
// Safe to call again: an in-flight pass is stopped first, so importing a
// second folder does not leave workers grinding through the first.
start_warmup :: proc(tracks: []Track) {
	stop_warmup()
	if len(tracks) == 0 { return }

	warmup.storage = make([]string, len(tracks))
	warmup.items   = make([]Peak_Key, len(tracks))
	for &t, i in tracks {
		warmup.storage[i] = strings.clone(t.path)
		warmup.items[i] = Peak_Key{
			path  = warmup.storage[i],
			size  = t.size,
			mtime = t.mtime,
		}
	}

	warmup.total  = len(tracks)
	warmup.cursor = 0
	warmup.done   = 0
	warmup.built  = 0
	warmup.stop   = false
	warmup.running = true

	for i in 0 ..< WARM_WORKERS {
		warmup.threads[i] = thread.create_and_start(warm_worker)
	}
}

stop_warmup :: proc() {
	if !warmup.running { return }
	sync.atomic_store(&warmup.stop, true)

	for i in 0 ..< WARM_WORKERS {
		if warmup.threads[i] == nil { continue }
		thread.join(warmup.threads[i])
		thread.destroy(warmup.threads[i])
		warmup.threads[i] = nil
	}
	warmup.running = false

	for s in warmup.storage { delete(s) }
	delete(warmup.storage)
	delete(warmup.items)
	warmup.storage = nil
	warmup.items   = nil
}

// Reads the measured features for every track whose peaks are already cached.
//
// Cheap — a few kilobytes a file and no decoding — so it runs after a scan and
// again when the warm-up finishes, which is when the rest will have appeared.
load_all_features :: proc() -> int {
	loaded := 0
	for &t in lib.tracks {
		if t.features.valid { continue }
		if !peaks_cache_valid(peak_key_of(&t)) { continue }
		p, ok := peaks_load(&t)
		if !ok { continue }
		t.features = p.features
		if t.duration <= 0 { t.duration = p.duration }
		delete(p.values)
		loaded += 1
	}
	return loaded
}

// Progress, for the status line.
warmup_progress :: proc() -> (done: int, total: int, running: bool) {
	if !warmup.running { return 0, 0, false }
	d := sync.atomic_load(&warmup.done)
	if d >= warmup.total { return warmup.total, warmup.total, false }
	return d, warmup.total, true
}

@(private)
warm_worker :: proc() {
	for {
		if sync.atomic_load(&warmup.stop) { return }

		index := sync.atomic_add(&warmup.cursor, 1)
		if index >= len(warmup.items) { return }
		key := warmup.items[index]

		// Already on disk and readable by this build. Checking the format as
		// well as the file means a cache written by an older version is
		// rebuilt rather than skipped forever.
		if !peaks_cache_valid(key) {
			if p, ok := peaks_generate_for(key.path); ok {
				peaks_store_for(key, p)
				delete(p.values)
				sync.atomic_add(&warmup.built, 1)
			}
		}
		sync.atomic_add(&warmup.done, 1)

		// Each pass allocates through the temp allocator; without this the
		// thread's arena grows for the length of the whole library.
		free_all(context.temp_allocator)
	}
}
