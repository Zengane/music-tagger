package musictagger

// The beat grid, and putting the drop on it.
//
// The drop detector finds roughly where a track arrives. Roughly is the
// problem: it lands a second or two out, and a second is two beats, so the
// marker sits between beats where no edit would ever be cut. Music has a grid
// and the answer is always on it.
//
// So: work out the tempo, work out where the beats fall, work out which of
// those beats are downbeats, and move the drop to the nearest one. That fixes
// the fine positioning without touching the coarse decision, which is the part
// the envelope is actually good at.
//
// Everything runs on the envelope that has already been measured — no second
// pass over the audio, no transform. Tempo is periodicity in the onsets, and
// periodicity is what autocorrelation is for.

import "core:math"

Beat_Grid :: struct {
	// Seconds between beats. Zero when nothing convincing was found, which is
	// the honest answer for free-time music and for ambient beds.
	period:  f32,
	// Seconds from the start of the file to the first beat.
	offset:  f32,
	// How many beats to a bar. Four unless three fits better.
	bar:     int,
	// Which beat of the bar the first beat is, so downbeats can be found.
	downbeat: int,
	// How much stronger the beats are than the gaps, as a ratio. Below about
	// 1.3 the grid is not worth trusting.
	strength: f32,
	found:   bool,
}

// How much of a change in texture counts next to a change in level.
//
// A drum kit coming in changes the brightness far more than the level, and a
// bass note the other way round. Adding both, with the brightness scaled up to
// the same range, means a beat is found whichever way it announces itself.
@(private) ONSET_BRIGHTNESS_WEIGHT :: 3.0

// The range of tempos looked for, in beats per minute.
//
// Below 60 the autocorrelation starts finding bars rather than beats, and above
// 200 it finds eighth notes. Anything outside is halved or doubled into range,
// which is what a listener does too.
@(private) TEMPO_MIN :: 60.0
@(private) TEMPO_MAX :: 200.0

// Onset strength, frame by frame: how much *more* is happening than a moment
// ago. Only increases count — a note ending is not an onset.
@(private)
onset_curve :: proc(env, bright: []f32, allocator := context.temp_allocator) -> []f32 {
	out := make([]f32, len(env), allocator)
	for i in 1 ..< len(env) {
		level := max(env[i] - env[i - 1], 0)
		tone  := max(bright[i] - bright[i - 1], 0) * ONSET_BRIGHTNESS_WEIGHT
		out[i] = level + tone
	}

	// Flattened against its own local average, so a loud passage does not
	// simply out-vote a quiet one and take every beat with it.
	window := max(len(out) / 40, 8)
	smoothed := make([]f32, len(out), allocator)
	running: f32
	for i in 0 ..< len(out) {
		running += out[i]
		if i >= window { running -= out[i - window] }
		smoothed[i] = running / f32(min(i + 1, window))
	}
	for i in 0 ..< len(out) {
		out[i] = max(out[i] - smoothed[i], 0)
	}
	return out
}

// The strongest periodicity in the onsets, as a number of frames.
@(private)
best_period :: proc(onset: []f32, per_second: f32) -> (period: int, score: f32) {
	lo := max(int(60 / TEMPO_MAX * per_second), 2)
	hi := min(int(60 / TEMPO_MIN * per_second), len(onset) / 4)
	if hi <= lo { return 0, 0 }

	total: f32
	for v in onset { total += v * v }
	if total <= 1e-9 { return 0, 0 }

	for lag in lo ..= hi {
		sum: f32
		for i in 0 ..< len(onset) - lag {
			sum += onset[i] * onset[i + lag]
		}
		// Longer lags have fewer terms to add up, so the sum is normalised by
		// how many there were — otherwise fast tempos always win.
		value := sum / f32(len(onset) - lag)
		if value > score {
			score = value
			period = lag
		}
	}
	return
}

// How much of the onset energy lands on a grid of this period at this offset.
@(private)
grid_energy :: proc(onset: []f32, period, offset: int) -> f32 {
	if period <= 0 { return 0 }
	sum: f32
	count := 0
	for i := offset; i < len(onset); i += period {
		// The frame either side too: a beat is not one frame wide, and a grid
		// that has to hit exactly would be defeated by rounding.
		sum += onset[i]
		if i > 0            { sum += onset[i - 1] * 0.5 }
		if i + 1 < len(onset) { sum += onset[i + 1] * 0.5 }
		count += 1
	}
	return count > 0 ? sum / f32(count) : 0
}

// Finds the grid. `env` and `bright` are the per-frame measurements, and
// `per_second` how many of them there are in a second.
find_beat_grid :: proc(env, bright: []f32, per_second: f32) -> Beat_Grid {
	grid: Beat_Grid
	if len(env) < 64 || per_second <= 0 { return grid }

	onset := onset_curve(env, bright)
	period, _ := best_period(onset, per_second)
	if period <= 0 { return grid }

	// Octave errors are the classic failure: half or double the real tempo
	// correlates nearly as well, because every other beat of a 130 track is
	// also a perfectly good grid at 65.
	//
	// Energy alone cannot choose between them — the half-time grid lands on
	// real beats too, just fewer of them. What settles it is that people do not
	// write music at 65: tempos cluster around 120, and a reading twice or half
	// that is far more likely to be a counting mistake than a genuinely slow
	// piece. So each candidate is weighted by how ordinary its tempo is.
	//
	// This matters more than it sounds. A half-time reading makes a bar twice
	// as long, and snapping the drop to a bar that is twice as long can move it
	// by seconds — which is how adding a beat grid managed to make the drop
	// *worse* on the first attempt.
	best_score := f32(0)
	best_period_frames := period
	for candidate in ([5]int{period / 4, period / 2, period, period * 2, period * 4}) {
		if candidate < 2 || candidate > len(onset) / 4 { continue }

		strongest := f32(0)
		for offset in 0 ..< candidate {
			if e := grid_energy(onset, candidate, offset); e > strongest { strongest = e }
		}

		bpm := 60 / (f32(candidate) / per_second)
		if bpm < TEMPO_MIN || bpm > TEMPO_MAX { continue }

		// A bell curve in octaves around 120, which is the shape tempo
		// actually has: 60 and 240 are equally unusual, and both half as
		// likely as 120.
		octaves := math.log2(bpm / 120)
		prior := math.exp(-(octaves * octaves) / (2 * 0.9 * 0.9))

		if value := strongest * prior; value > best_score {
			best_score = value
			best_period_frames = candidate
		}
	}
	period = best_period_frames

	// Where the beats sit.
	best_offset := 0
	best_energy := f32(0)
	for offset in 0 ..< period {
		if e := grid_energy(onset, period, offset); e > best_energy {
			best_energy = e
			best_offset = offset
		}
	}

	// Is the grid worth believing? Compare a beat against the average frame.
	mean: f32
	for v in onset { mean += v }
	mean /= f32(len(onset))
	if mean <= 1e-9 { return grid }
	grid.strength = best_energy / mean
	if grid.strength < 1.3 { return grid }

	// Bars. Four beats unless three explains the accents better.
	//
	// The test is the same one used for the beats, a level up: whichever bar
	// length puts the most energy on its downbeats is the one the music is in.
	best_bar, best_downbeat := 4, 0
	best_contrast := f32(0)
	for bar in ([2]int{4, 3}) {
		for start in 0 ..< bar {
			sum: f32
			count := 0
			for k := start; ; k += bar {
				i := best_offset + k * period
				if i >= len(onset) { break }
				sum += onset[i]
				count += 1
			}
			if count < 4 { continue }
			contrast := (sum / f32(count)) / max(best_energy, 1e-9)
			if contrast > best_contrast {
				best_contrast = contrast
				best_bar = bar
				best_downbeat = start
			}
		}
	}

	grid.period   = f32(period) / per_second
	grid.offset   = f32(best_offset) / per_second
	grid.bar      = best_bar
	grid.downbeat = best_downbeat
	grid.found    = true
	return grid
}

// Moves a time onto the grid.
//
// A downbeat if one is close enough, otherwise the nearest beat. "Close enough"
// is half a bar for the downbeat and half a beat for the beat, which is simply
// "the nearest one" in both cases — the point is that a drop found within a bar
// of a downbeat almost certainly *is* that downbeat, arrived at by a detector
// that cannot count.
snap_to_grid :: proc(grid: Beat_Grid, seconds: f32) -> f32 {
	if !grid.found || grid.period <= 0 || seconds <= 0 { return seconds }

	beats := (seconds - grid.offset) / grid.period
	bar := f32(max(grid.bar, 1))

	// A snap may tidy a placement. It may not move it.
	//
	// Reaching for the nearest downbeat can shift the answer by most of a bar,
	// and a bar is seconds — so a detector that was a beat out came back two
	// beats out on the other side. The correction is allowed half a beat, and
	// that is all: the coarse decision belongs to whatever found the drop, and
	// this only puts it on the nearest line.
	beat_time := grid.offset + math.round(beats) * grid.period
	if beat_time < 0 { return seconds }

	// A downbeat within that same half beat is better still — it is the same
	// instant, named more usefully.
	from_downbeat := (beats - f32(grid.downbeat)) / bar
	downbeat_time := grid.offset +
	                 (math.round(from_downbeat) * bar + f32(grid.downbeat)) * grid.period
	if downbeat_time >= 0 && abs(downbeat_time - seconds) <= grid.period * 0.5 {
		return downbeat_time
	}
	return beat_time
}

// The tempo, for showing.
grid_bpm :: proc(grid: Beat_Grid) -> f32 {
	if !grid.found || grid.period <= 0 { return 0 }
	return 60 / grid.period
}
