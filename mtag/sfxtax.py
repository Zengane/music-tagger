"""The sound-effect vocabulary, and how an AudioSet tagger maps onto it.

Why a mapping rather than the model's own labels
------------------------------------------------
An AudioSet tagger emits 527 classes. Those are not tags: they are a research
ontology with entries like "Rub", "Inside, small room" and "Sound effect", and
putting all of them in the tag rail would make it unusable while still not
answering the question an editor asks, which is "what do I reach for".

So the classes are folded into a small vocabulary, in groups:

    Type      what the thing is          Impact, Whoosh, Footstep, Interface…
    Material  what it is made of         Metal, Wood, Glass, Water…
    Space     what it sounds like it is in   Room, Hall, Outdoor…
    Length    how it behaves in time     One-Shot, Loop, Tail

A file usually earns one or two from Type, sometimes a Material, and a Length.
That is a description an editor can search, and it is far fewer decisions than
527.

What the model cannot do
------------------------
AudioSet describes *sound*, not *intent*. It can tell you a file is a short
bright electronic beep. It cannot tell you whether that beep means Confirm or
Cancel, because those are identical acoustically and differ only in what the
designer meant. The same goes for Error, Select, Purchase and the rest of the
menu vocabulary.

Intent therefore comes from two other places, both of which are more reliable
for it than any classifier would be:

  * the filename, which for game audio nearly always says so outright
    ("ui_confirm_01.wav") — see SFX_PHRASES in taxonomy.py
  * the editor, once enough files are labelled by hand, using the same
    per-tag probe approach the music side already uses

The honest split is: the model does the acoustics, the filename does the
intent, and a probe learns whatever is left.
"""

# ── the vocabulary, in groups ────────────────────────────────────────────────
# Each group becomes a tag category in the interface, scoped to effects so it
# never clutters the music tabs.

SFX_TYPE = [
    "Impact", "Whoosh", "Footstep", "Foley", "Interface", "Magic", "Weapon",
    "Vehicle", "Mechanical", "Creature", "Voice", "Nature", "Ambience",
    "Musical", "Explosion", "Break", "Liquid", "Fire", "Electricity",
]

SFX_MATERIAL = [
    "Metal", "Wood", "Glass", "Stone", "Water", "Cloth", "Paper", "Plastic",
    "Electronic", "Organic",
]

SFX_SPACE = ["Close", "Room", "Hall", "Outdoor", "Underwater"]

SFX_LENGTH = ["One-Shot", "Loop", "Tail"]

# What a menu sound is *for*. Never predicted from audio — see the note above.
# These come from the filename, or from the editor's own hand.
SFX_INTENT = [
    "Confirm", "Cancel", "Error", "Notification", "Select", "Hover",
    "Open", "Close-UI", "Purchase", "Unlock", "Level-Up", "Pickup",
    "Equip", "Save", "Page-Turn", "Typing",
]

# How a sound behaves over time, which is what an editor actually picks by.
# These are measured from the waveform rather than predicted — a riser rises —
# so they need no model at all. See ui/features.odin.
SFX_SHAPE = [
    "Riser", "Downlifter", "Impact", "Whoosh", "Drone", "Stab", "Swell",
    "Bright", "Dark", "Boomy", "Sub", "Punchy", "Sustained",
]

SFX_GROUPS = [
    ("SFX Shape", SFX_SHAPE),
    ("SFX Type", SFX_TYPE),
    ("SFX Material", SFX_MATERIAL),
    ("SFX Space", SFX_SPACE),
    ("SFX Length", SFX_LENGTH),
    ("SFX Intent", SFX_INTENT),
]

ALL_SFX_TAGS = [t for _, tags in SFX_GROUPS for t in tags]


# ── AudioSet class -> our tags ───────────────────────────────────────────────
# Keys are AudioSet display names, matched case-insensitively and by substring
# so near-misses in the label text still land. A class may contribute several
# tags: breaking glass is both an Impact and Glass.
#
# Only classes worth a tag are listed. Everything unlisted is ignored, which is
# most of the 527 — "Speech synthesizer", "Rail transport", "Music" and the
# rest of the ontology's upper levels say nothing useful about an effect.

AUDIOSET_MAP = {
    # Impacts and destruction
    "bang": ["Impact"],
    "slam": ["Impact"],
    "knock": ["Impact"],
    "thump, thud": ["Impact"],
    "smash, crash": ["Impact", "Break"],
    "breaking": ["Break"],
    "shatter": ["Break", "Glass"],
    "glass": ["Glass"],
    "chink, clink": ["Glass", "Impact"],
    "explosion": ["Explosion"],
    "boom": ["Explosion"],
    "eruption": ["Explosion"],
    "gunshot, gunfire": ["Weapon"],
    "machine gun": ["Weapon"],
    "artillery fire": ["Weapon", "Explosion"],
    "cap gun": ["Weapon"],
    "fusillade": ["Weapon"],
    "arrow": ["Weapon"],
    "sword": ["Weapon", "Metal"],

    # Movement through air
    "whoosh, swoosh, swish": ["Whoosh"],
    "wind noise (microphone)": ["Whoosh"],
    "swing": ["Whoosh"],

    # Feet and handling
    "walk, footsteps": ["Footstep"],
    "run": ["Footstep"],
    "shuffle": ["Footstep", "Foley"],
    "rustle": ["Foley", "Cloth"],
    "rustling leaves": ["Nature", "Organic"],
    "crumpling, crinkling": ["Foley", "Paper"],
    "tearing": ["Foley", "Paper"],
    "zipper (clothing)": ["Foley", "Cloth"],
    "velcro, hook and loop fastener": ["Foley", "Cloth"],
    "coin (dropping)": ["Foley", "Metal", "Pickup"],
    "keys jangling": ["Foley", "Metal"],
    "writing": ["Foley", "Paper"],
    "scissors": ["Foley", "Metal"],

    # Interface and electronics
    "beep, bleep": ["Interface", "Electronic"],
    "ding": ["Interface"],
    "dial tone": ["Interface", "Electronic"],
    "busy signal": ["Interface", "Electronic"],
    "alarm clock": ["Interface", "Notification"],
    "telephone bell ringing": ["Interface", "Notification"],
    "ringtone": ["Interface", "Notification"],
    "buzzer": ["Interface", "Error"],
    "smoke detector, smoke alarm": ["Interface", "Notification"],
    "computer keyboard": ["Interface", "Typing"],
    "typing": ["Typing", "Interface"],
    "mouse click": ["Interface", "Select"],
    "click": ["Interface", "Select"],
    "electronic tuner": ["Electronic"],
    "chime": ["Interface", "Notification"],
    "bell": ["Interface"],
    "chirp tone": ["Interface", "Electronic"],
    "sine wave": ["Electronic"],
    "static": ["Electronic"],
    "hum": ["Electronic"],
    "electronic": ["Electronic"],
    "white noise": ["Electronic"],

    # Machines and vehicles
    "engine": ["Mechanical", "Vehicle"],
    "motor vehicle (road)": ["Vehicle"],
    "car": ["Vehicle"],
    "truck": ["Vehicle"],
    "motorcycle": ["Vehicle"],
    "aircraft": ["Vehicle"],
    "helicopter": ["Vehicle"],
    "train": ["Vehicle"],
    "boat, water vehicle": ["Vehicle", "Water"],
    "skidding": ["Vehicle"],
    "machine": ["Mechanical"],
    "sewing machine": ["Mechanical"],
    "drill": ["Mechanical"],
    "power tool": ["Mechanical"],
    "sanding": ["Mechanical"],
    "printer": ["Mechanical"],
    "camera": ["Mechanical"],
    "gears": ["Mechanical", "Metal"],
    "ratchet, pawl": ["Mechanical", "Metal"],
    "clock": ["Mechanical"],
    "tick": ["Mechanical"],
    "tick-tock": ["Mechanical", "Loop"],
    "door": ["Foley", "Wood"],
    "creak": ["Foley", "Wood"],
    "sliding door": ["Mechanical"],
    "cupboard open or close": ["Foley", "Wood"],
    "drawer open or close": ["Foley", "Wood"],

    # Living things
    "animal": ["Creature", "Organic"],
    "dog": ["Creature"],
    "cat": ["Creature"],
    "bird": ["Creature", "Nature"],
    "bird vocalization, bird call, bird song": ["Nature", "Creature"],
    "insect": ["Creature", "Nature"],
    "roar": ["Creature"],
    "growling": ["Creature"],
    "howl": ["Creature"],
    "hiss": ["Creature"],
    "livestock, farm animals, working animals": ["Creature"],
    "speech": ["Voice"],
    "shout": ["Voice"],
    "screaming": ["Voice"],
    "laughter": ["Voice"],
    "crying, sobbing": ["Voice"],
    "breathing": ["Voice", "Organic"],
    "cough": ["Voice"],
    "whistling": ["Voice"],
    "singing": ["Voice", "Musical"],
    "chatter": ["Voice"],
    "crowd": ["Voice", "Ambience"],

    # The world
    "wind": ["Nature", "Ambience"],
    "rain": ["Nature", "Water", "Ambience"],
    "thunderstorm": ["Nature"],
    "thunder": ["Nature"],
    "water": ["Water", "Liquid"],
    "stream": ["Water", "Nature", "Loop"],
    "ocean": ["Water", "Nature", "Ambience"],
    "waves, surf": ["Water", "Nature"],
    "splash, splatter": ["Water", "Liquid"],
    "drip": ["Water", "Liquid"],
    "pour": ["Liquid"],
    "gurgling": ["Liquid"],
    "boiling": ["Liquid", "Fire"],
    "fire": ["Fire"],
    "crackle": ["Fire"],
    "wildfire": ["Fire", "Nature"],
    "underwater": ["Underwater"],

    # Rooms and spaces
    "inside, small room": ["Room", "Close"],
    "inside, large room or hall": ["Hall"],
    "inside, public space": ["Hall", "Ambience"],
    "outside, urban or manmade": ["Outdoor", "Ambience"],
    "outside, rural or natural": ["Outdoor", "Nature", "Ambience"],
    "echo": ["Hall"],
    "reverberation": ["Hall"],
    "environmental noise": ["Ambience"],
    "ambient": ["Ambience"],
    "silence": ["Ambience"],

    # Music-ish effects
    "musical instrument": ["Musical"],
    "plucked string instrument": ["Musical"],
    "drum": ["Musical", "Impact"],
    "cymbal": ["Musical", "Metal"],
    "gong": ["Musical", "Metal"],
    "harp": ["Musical"],
    "glockenspiel": ["Musical", "Metal"],
    "synthesizer": ["Musical", "Electronic"],
    "sound effect": [],  # too general to mean anything
}


def tags_for_labels(labels):
    """Fold scored AudioSet labels into our vocabulary.

    `labels` is an iterable of (display_name, score). Returns
    {tag: best_score}, so a tag reached by several classes keeps the
    strongest evidence for it rather than the last one seen.
    """
    out = {}
    for name, score in labels:
        lowered = str(name).strip().lower()
        for key, tags in AUDIOSET_MAP.items():
            # Exact first, then substring, so "Glass" does not swallow
            # "Glass breaking" before the more specific entry is tried.
            if lowered != key and key not in lowered:
                continue
            for tag in tags:
                if score > out.get(tag, 0.0):
                    out[tag] = float(score)
    return out


def group_of(tag):
    """Which category a tag belongs to, or None."""
    for name, tags in SFX_GROUPS:
        if tag in tags:
            return name
    return None
