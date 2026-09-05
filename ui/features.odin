package musictagger

// What a sound is shaped like, measured rather than guessed.
//
// The AudioSet tagger describes a *thing*: a door, a dog, breaking glass. That
// is the right answer for film foley and the wrong one for editing, where the
// question is almost never "what object is this" and almost always "what does
// it do to my timeline". A riser rises. A hit is loud and immediately over. A
// drone sits still. Those are properties of the waveform, so they are measured
// off it — no model, no download, and no opinion about what the object was.
//
// The numbers come out of the same decode that builds the waveform, so the
// whole library is described by the import that was already happening. They
// are stored beside the peaks and are what the browse-by-feel sorting reads.

import "core:math"
import "core:slice"

Features :: struct {
	duration:   f32, // seconds
	loudness:   f32, // mean level, 0..1
	peak:       f32, // highest level, 0..1
	brightness: f32, // how much of the energy is high frequency, 0..1
	attack:     f32, // seconds until it first properly speaks: the onset
	slope:      f32, // -1 falls away, 0 steady, +1 builds
	sustain:    f32, // how much of it is above a fifth of the peak, 0..1
	// Where the sound actually lands, in seconds.
	//
	// For a transition effect this is the sync point: the frame you line up
	// with the cut. It is the loudest moment for a hit, and the start of the
	// loudest stretch for something with a sustained peak, so a riser marks
	// where it arrives rather than somewhere in the middle of its tail.
	hit:        f32,
	// How much of the energy is below about 180 Hz, 0..1.
	//
	// Brightness alone could not tell a sub boom from a wooden thud: both are
	// dull, so both read the same. This is measured with a one-pole low-pass,
	// which at the 8 kHz the peaks are decoded at is enough to separate the
	// bottom octave from everything above it.
	low:        f32,
	// The sharpest single-frame rise in the envelope, as a fraction of the
	// peak, 0..1. A crack reaches full level inside five milliseconds; a boom
	// takes fifty or more. This is what "impacty" actually means, and the
	// attack time cannot say it — both land under the same threshold.
	punch:      f32,
	// Where a song picks up: the drop, in seconds.
	//
	// A different question from `hit`, and asked of different material. An
	// effect has one loud instant and `hit` finds it. A song has an arrangement
	// — it starts thin, builds, and at some point the whole thing arrives, and
	// that arrival is what an edit is cut to. It is not the loudest moment;
	// the loudest moment is usually somewhere in the middle of the last chorus.
	// It is the moment the level *changes* and stays changed.
	//
	// Zero when there is no such moment, which is the honest answer for an
	// ambient bed that never picks up.
	drop:       f32,
	// Beats per minute, or zero when the track has no steady pulse.
	//
	// Measured for the drop's sake — a marker between beats is a marker no cut
	// will ever land on — and worth having on its own: two tracks at the same
	// tempo can be cut against each other.
	tempo:      f32,
	valid:      bool,
}

// Measured from mono samples at PEAK_RATE.
//
// Brightness is the energy of the first difference against the energy of the
// signal. Differencing is a high-pass, so the ratio says how much of the sound
// lives up top — a cheap spectral centroid that needs no transform, which
// matters when this runs over ten thousand files.
measure_features :: proc(samples: []f32, duration: f32) -> Features {
	if len(samples) < 64 || duration <= 0 { return {} }

	f := Features{duration = duration, valid = true}

	sum_sq: f64
	diff_sq: f64
	peak: f32
	for s, i in samples {
		a := abs(s)
		if a > peak { peak = a }
		sum_sq += f64(s) * f64(s)
		if i > 0 {
			d := s - samples[i - 1]
			diff_sq += f64(d) * f64(d)
		}
	}
	n := f64(len(samples))
	f.peak     = peak
	f.loudness = f32(math.sqrt(sum_sq / n))

	// The differenced signal has roughly four times the energy of the original
	// for white noise, so the ratio is scaled to land in 0..1 for real audio.
	if sum_sq > 1e-12 {
		f.brightness = clamp(f32(math.sqrt(diff_sq / sum_sq)) * 0.5, 0, 1)
	}

	// Bass weight: a one-pole low-pass at about 180 Hz, then the energy of what
	// came through against the energy that went in.
	{
		// a = 1 - exp(-2 pi fc / fs), with fs the peaks rate.
		a :: f32(0.132)
		y: f32
		lo_sq: f64
		for s in samples {
			y += a * (s - y)
			lo_sq += f64(y) * f64(y)
		}
		if sum_sq > 1e-12 {
			// The filter loses level as well as content, so the ratio is lifted
			// to land near 1 for a sound that is nothing but bass.
			f.low = clamp(f32(math.sqrt(lo_sq / sum_sq)) * 1.0, 0, 1)
		}
	}

	// An envelope at about fifty frames a second, which is fine enough to see
	// an attack and coarse enough not to follow the waveform itself.
	frame := max(len(samples) / max(int(duration * 50), 1), 1)
	frames := len(samples) / frame
	if frames < 3 { return f }

	env := make([]f32, frames, context.temp_allocator)
	// Brightness, frame by frame.
	//
	// The same measurement as the track-wide `brightness`, taken over one
	// frame at a time: the energy of the differenced signal against the energy
	// of the signal. It is what percussion coming in looks like — a drum kit
	// adds far more high frequency than it adds level, and a melodic intro
	// played loudly adds none.
	//
	// This is the channel that finds a "switch-up": a track can arrive without
	// getting louder, and the level alone has nothing to see.
	bright := make([]f32, frames, context.temp_allocator)

	for i in 0 ..< frames {
		lo := i * frame
		hi := min(lo + frame, len(samples))
		m: f32
		energy, edges: f64
		for k in lo ..< hi {
			a := abs(samples[k])
			if a > m { m = a }
			energy += f64(samples[k]) * f64(samples[k])
			if k > lo {
				diff := samples[k] - samples[k - 1]
				edges += f64(diff) * f64(diff)
			}
		}
		env[i] = m
		if energy > 1e-12 {
			bright[i] = clamp(f32(math.sqrt(edges / energy)) * 0.5, 0, 1)
		}
	}

	env_peak: f32
	for v in env { if v > env_peak { env_peak = v } }
	if env_peak <= 0.0001 { return f }

	// Attack: how long until the sound first properly speaks.
	//
	// Measured at a quarter of the peak, not at ninety per cent. Ninety
	// per cent is the time to the *loudest moment*, which for a drone that
	// swells late reads as a nineteen-second attack and says nothing about
	// how it starts. A quarter is the onset, which is what separates a hit
	// from a swell.
	f.attack = duration
	for v, i in env {
		if v >= env_peak * 0.25 {
			f.attack = f32(i) / f32(frames) * duration
			break
		}
	}

	// The hit: where the loudest run begins.
	//
	// Not simply the single loudest frame, which for anything with a flat top
	// lands arbitrarily inside it. The first frame within a whisker of the
	// peak is where the sound arrives, which is what a marker wants to be on.
	for v, i in env {
		if v >= env_peak * 0.92 {
			f.hit = f32(i) / f32(frames) * duration
			break
		}
	}

	// Punch: the sharpest rise in a fine envelope, five milliseconds a frame.
	// The fifty-a-second envelope above is too coarse for this — a whole
	// transient fits inside one of its frames.
	{
		fine   := max(len(samples) / max(int(duration * 200), 1), 1)
		fcount := len(samples) / fine
		if fcount >= 3 {
			prev, best, top: f32
			for i in 0 ..< fcount {
				lo := i * fine
				hi := min(lo + fine, len(samples))
				m: f32
				for s in samples[lo:hi] {
					av := abs(s)
					if av > m { m = av }
				}
				if m > top { top = m }
				if m - prev > best { best = m - prev }
				prev = m
			}
			if top > 0.0001 { f.punch = clamp(best / top, 0, 1) }
		}
	}

	// Sustain: how much of the file is actually doing something.
	above := 0
	for v in env { if v >= env_peak * 0.2 { above += 1 } }
	f.sustain = f32(above) / f32(frames)

	// The drop: the first major beat.
	//
	// Not the loudest moment, not the biggest rise, and — the mistake this is
	// the third attempt at — not "the first time it reaches a level measured
	// against the whole track". That last one is late by construction: a piece
	// that builds to a finale has a high average, so the first moment to reach
	// eighty per cent of it is somewhere in the second half. It kept marking
	// a minute in.
	//
	// The question is a *local* one. A major beat is a moment that is much
	// louder than the seconds immediately before it, and stays that way. So
	// each moment is compared with its own recent past rather than with a
	// number taken from the whole file:
	//
	//   the next two seconds, against the previous three
	//
	// A jump of sixty per cent between those two counts as an arrival, as long
	// as what arrives is actually substantial — a quiet passage doubling to a
	// slightly less quiet one is not a downbeat, so it also has to reach half
	// of what the loud parts of the track sit at.
	//
	// A track that is already at full strength when it starts has no such jump
	// to find, and the answer for it is zero: the beginning is the beat.
	if duration >= 10 && frames >= 60 {
		sorted := make([]f32, frames, context.temp_allocator)
		copy(sorted, env)
		slice.sort(sorted)
		loud := sorted[int(f32(frames) * 0.85)]

		if loud > env_peak * 0.05 {
			per_second := f32(frames) / duration

			mean_over :: proc(values: []f32, from, to: int) -> f32 {
				lo := max(from, 0)
				hi := min(to, len(values))
				if hi <= lo { return 0 }
				sum: f32
				for i in lo ..< hi { sum += values[i] }
				return sum / f32(hi - lo)
			}

			before_w := max(int(3 * per_second), 2)
			after_w  := max(int(2 * per_second), 2)

			// Already going at the start: nothing to wait for.
			//
			// Loud *and* busy. A melodic intro can be as loud as the rest of
			// the track and still be an intro — "Duel of Legend" opens with
			// one — so the level alone said the piece began at full strength
			// and the drop thirty-five seconds later was never looked for.
			// Asking about the texture as well is what separates the two.
			opening_level  := mean_over(env, 0, after_w)
			opening_bright := mean_over(bright, 0, after_w)
			overall_bright := mean_over(bright, 0, frames)

			if opening_level >= loud * 0.55 && opening_bright >= overall_bright * 0.85 {
				f.drop = 0
			} else {
				// Only the opening counts.
				//
				// A jump four and a half minutes into a six minute piece is
				// not a first beat, however big it is — one track was marked
				// at 4:30 because its quiet middle made the last chorus look
				// like an arrival. Past a minute the answer is that the track
				// simply starts where it starts.
				latest := min(int(60 * per_second), frames - after_w)

				for i in before_w ..< max(latest, before_w + 1) {
					before := mean_over(env, i - before_w, i)
					after  := mean_over(env, i, i + after_w)

					// Whatever arrives has to be substantial in its own right.
					if after < loud * 0.50 { continue }

					// Either channel may carry the arrival. Louder, or busier:
					// a chorus that comes in over the same level as the verse
					// is a real arrival and the level cannot see it.
					louder := after >= before * 1.60

					before_bright := mean_over(bright, i - before_w, i)
					after_bright  := mean_over(bright, i, i + after_w)
					busier := before_bright > 0.001 &&
					          after_bright >= before_bright * 1.35 &&
					          after >= before * 1.05

					if !louder && !busier { continue }

					// The jump is somewhere in the second or so around here.
					// Land on the sharpest single step in that window, which
					// is the transient itself rather than the ramp into it.
					best_step := f32(0)
					beat := i
					from := max(i - int(0.6 * per_second), 1)
					to   := min(i + int(0.6 * per_second) + 1, frames)
					for k in from ..< to {
						step := env[k] - env[k - 1]
						if step > best_step {
							best_step = step
							beat = k
						}
					}

					f.drop = f32(beat) / f32(frames) * duration
					break
				}
			}
		}
	}

	// The beat grid, and the drop moved onto it.
	//
	// Everything above finds the drop to within a second or so, which is two
	// beats — near enough to be obviously right and far enough to be useless,
	// because a marker between beats is a marker nothing can be cut to. The
	// grid fixes the placement without touching the decision.
	{
		per_second := f32(frames) / max(duration, 0.001)
		grid := find_beat_grid(env, bright, per_second)
		f.tempo = grid_bpm(grid)
		if f.drop > 0 {
			f.drop = clamp(snap_to_grid(grid, f.drop), 0, duration)
		}
	}

	// Slope: the trend of the envelope, as a least-squares fit, normalised so
	// a sound that goes from nothing to full reads as +1.
	mean_x := f32(frames - 1) * 0.5
	mean_y: f32
	for v in env { mean_y += v }
	mean_y /= f32(frames)

	num, den: f32
	for v, i in env {
		dx := f32(i) - mean_x
		num += dx * (v - mean_y)
		den += dx * dx
	}
	if den > 0 {
		// Rise across the whole file, as a fraction of the peak.
		rise := num / den * f32(frames - 1)
		f.slope = clamp(rise / env_peak, -1, 1)
	}
	return f
}

// ── what the shape is called ────────────────────────────────────────────────

// The editing vocabulary, from the measurements.
//
// These are the words an editor reaches for — riser, hit, whoosh, drone — and
// each is a shape rather than an object, which is exactly what the numbers
// above describe. Thresholds are deliberately loose: a suggestion that is
// nearly right is useful, and everything here is reviewed before it is saved.
shape_tags :: proc(f: Features, out: ^[dynamic]string) {
	clear(out)
	if !f.valid { return }

	add :: proc(out: ^[dynamic]string, tag: string) {
		if !slice.contains(out[:], tag) { append(out, tag) }
	}

	// Thresholds calibrated against a real effects folder rather than picked
	// by eye. Two of them were badly wrong on the first pass: Whoosh wanted
	// *high* sustain when every real whoosh has low sustain, and Dark fired on
	// two thirds of everything because the brightness scale is compressed
	// toward the bottom.
	immediate := f.attack <= 0.12
	brief     := f.duration <= 8
	long      := f.duration >= 5

	// A front edge you can feel, and a sound that lives at the bottom.
	//
	// The "Hit & Impact" folder is what these are for: half of it is sub bass
	// that swells rather than lands, and the attack time could not tell the
	// two apart, because a sub reaching a quarter of its level in forty
	// milliseconds passes the same test a crack does. The rise inside a single
	// five-millisecond frame does tell them apart, measured over the folder:
	// the real impacts sit at 0.6 and above, the bass swells at 0.2 to 0.55.
	sharp := f.punch >= 0.6
	bassy := f.low   >= 0.80

	switch {
	case f.slope >= 0.25 && f.duration >= 0.3 && f.duration <= 25:
		// Builds as it goes: the thing that sits under a cut.
		add(out, "Riser")

	case sharp && f.peak >= 0.5 && f.slope <= -0.2 && f.sustain <= 0.9:
		// Lands, then gets out of the way. Length is not part of this: a sub
		// hit with a long tail is still a hit. The front edge is, though —
		// without one it is a swell, however loud it gets.
		add(out, "Impact")

	case f.slope <= -0.3 && long && f.sustain >= 0.4:
		// Comes down over a long stretch and stays present while it does.
		add(out, "Downlifter")

	case long && f.sustain >= 0.7 && abs(f.slope) < 0.25:
		// Sits still: a bed or a drone.
		add(out, "Drone")

	case f.duration <= 10 && f.sustain <= 0.45 && f.slope <= 0.2 && !immediate:
		// Arrives, passes, gone, without a hard front edge. Air rather than an
		// object.
		add(out, "Whoosh")

	case brief && immediate:
		// Short and immediate but not loud enough to be a hit.
		add(out, "Stab")
	}

	// Character, on the scale the measurement actually produces: most material
	// sits between 0.02 and 0.35, and only cymbals and metal go above that.
	if f.brightness >= 0.35 { add(out, "Bright") }
	else if f.brightness <= 0.05 { add(out, "Dark") }

	// Where it sits and how hard it arrives, which are separate questions.
	// Boomy is "there is weight down there"; Sub is "there is nothing else",
	// and it only applies when nothing sharp happens at the front — otherwise
	// the sound is an impact that happens to be low.
	if bassy { add(out, "Boomy") }
	if f.low >= 0.92 && !sharp { add(out, "Sub") }
	if sharp && f.peak >= 0.5 { add(out, "Punchy") }
	if f.sustain >= 0.8 && long { add(out, "Sustained") }

	// Length, which the shape rules do not always reach.
	if f.duration <= 1.2 { add(out, "One-Shot") }
	else if long && f.sustain >= 0.85 && abs(f.slope) < 0.25 { add(out, "Loop") }
}

// ── sorting by feel ─────────────────────────────────────────────────────────

Sort_Mode :: enum {
	Name,
	Duration,
	Brightness,
	Punch,
	Loudness,
	Build, // rising first, falling last
	Similar,
}

sort_mode_name :: proc(mode: Sort_Mode) -> cstring {
	switch mode {
	case .Name:       return "Name"
	case .Duration:   return "Length"
	case .Brightness: return "Bright"
	case .Punch:      return "Punchy"
	case .Loudness:   return "Loud"
	case .Build:      return "Building"
	case .Similar:    return "Similar"
	}
	return "Name"
}

// How far apart two sounds are, for "more like this one".
//
// The axes are already 0..1 and are weighted by how much they change what a
// sound is *for*: brightness and shape matter more than raw level, which
// varies with how a library was mastered rather than with the sound.
feature_distance :: proc(a, b: Features) -> f32 {
	if !a.valid || !b.valid { return 1e9 }

	// Duration on a log scale: half a second against one is a real difference,
	// twenty seconds against twenty-one is not.
	la := math.log2(max(a.duration, 0.05))
	lb := math.log2(max(b.duration, 0.05))

	d := f32(0)
	d += 2.0 * (a.brightness - b.brightness) * (a.brightness - b.brightness)
	d += 1.5 * (a.low - b.low) * (a.low - b.low)
	d += 1.5 * (a.punch - b.punch) * (a.punch - b.punch)
	d += 2.0 * (a.slope - b.slope) * (a.slope - b.slope)
	d += 1.5 * (a.sustain - b.sustain) * (a.sustain - b.sustain)
	d += 1.0 * ((la - lb) / 6) * ((la - lb) / 6)
	d += 0.7 * (a.loudness - b.loudness) * (a.loudness - b.loudness)
	return math.sqrt(d)
}
