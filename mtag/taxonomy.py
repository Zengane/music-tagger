"""The tag vocabulary, mirrored from the TagSpaces tag library.

`PROMPTS` are only used for zero-shot fallback on tags that have too few
labelled examples to train a probe. Everything else is learned from the
user's own sidecars.
"""

MOOD_TAGS = [
    "Adventure",
    "Awkward",
    "Bombastic-Heavy",
    "Build-Up",
    "Chill",
    "Epic",
    "Goofy",
    "Hopeful",
    "Hype",
    "Loss",
    "Melancholic",
    "Mysterious",
    "Ominous",
    "Serene",
    "Tension",
    "Victory",
]

SOUND_TAGS = [
    "Ambient",
    "Beachy",
    "Childish",
    "Chiptuney",
    "Choir",
    "Dreamy",
    "Electronic",
    "Fantasy",
    "Folk",
    "Funky",
    "Jazzy",
    "Medieval",
    "Orchestral",
    "Oriental",
    "Rock-Metal",
    "Romantic",
    "Trappy",
    "Tribal",
    "Vocals",
    "Wintery",
    "Weird",
]

ALL_TAGS = MOOD_TAGS + SOUND_TAGS

# Sound effects use a different vocabulary from music. These are deliberately
# broad production categories: they describe how an editor will reach for an
# effect, not what the recording is "about". They are manual labels for now;
# the music model must never be trained on them or asked to predict them.
SFX_TAGS = [
    "Ambience", "Creature", "Foley", "Footstep", "Impact", "Interface",
    "Magic", "Mechanical", "Nature", "One-Shot", "Loop", "Transition",
    "Vehicle", "Voice", "Weapon", "Whoosh",
]

LIBRARY_TAGS = ALL_TAGS + SFX_TAGS

# Folder names in the library that don't match a tag title verbatim.
FOLDER_ALIASES = {
    "Build up": "Build-Up",
    "Hype - Ominous": "Hype",
}

# Tags typed into sidecars that don't exist in the TagSpaces tag library.
# Without these, 15 already-tagged tracks read as untagged and never trained.
# `fix_tags.py` rewrites them in place; reading applies them on the fly either way.
TAG_ALIASES = {
    "Jazz": "Jazzy",
    "Bombastic": "Bombastic-Heavy",
}

# Files whose name contains any of these are not library tracks. Rendering audio
# out for Audition drops the result next to the original, and those renders
# should never be tagged or counted as new music.
SKIP_NAME_PATTERNS = ("audio extracted",)

# Top-level folders left alone entirely. SFX is a different problem — one-shot
# hits and drones don't fit a Mood/Sound taxonomy built for music.
SKIP_DIRS = ("SFX",)

# Folders that group tracks without naming a game — staging areas, not sources.
CONTAINER_DIRS = {"untagged", "new", "inbox", "music", "ost", "soundtrack", "misc"}

PROMPTS = {
    "Adventure": "adventurous upbeat exploration heroic journey music",
    "Awkward": "awkward quirky uncomfortable comedic clumsy bumbling music",
    "Bombastic-Heavy": "bombastic heavy powerful loud intense dramatic music",
    "Build-Up": "building tension rising crescendo anticipation music",
    "Chill": "relaxed chill calm laid-back lofi background music",
    "Epic": "epic cinematic grand sweeping powerful orchestral music",
    "Goofy": "goofy silly playful cartoon comedic funny music",
    "Hopeful": "hopeful uplifting optimistic inspiring emotional music",
    "Hype": "hype energetic pump-up exciting high-energy intense music",
    "Loss": "sad loss grief somber mourning emotional music",
    "Melancholic": "melancholic bittersweet nostalgic sad reflective music",
    "Mysterious": "mysterious suspenseful dark atmospheric enigmatic music",
    "Ominous": "ominous threatening dark foreboding danger warning music",
    "Serene": "serene peaceful tranquil gentle soft quiet music",
    "Tension": "tense suspenseful thriller horror dread music",
    "Victory": "victory triumphant celebration winning heroic fanfare music",
    "Ambient": "ambient atmospheric background texture drone music",
    "Beachy": "beachy tropical summery ocean island relaxed music",
    "Childish": "childish playful innocent toy-like simple cute music",
    "Chiptuney": "chiptune 8-bit retro video game electronic bleeps music",
    "Choir": "choir choral vocals singing ensemble voices music",
    "Dreamy": "dreamy ethereal floating hazy soft reverb music",
    "Electronic": "electronic synthesizer EDM digital dance music",
    "Fantasy": "fantasy magical mystical fairy tale music",
    "Folk": "folk acoustic guitar traditional roots storytelling music",
    "Funky": "funky groovy bass slap soul rhythm music",
    "Jazzy": "jazz swing blues saxophone improvisation music",
    "Medieval": "medieval renaissance lute harpsichord period historical music",
    "Orchestral": "orchestral classical symphony strings full orchestra music",
    "Oriental": "east asian koto shamisen traditional japanese music",
    "Rock-Metal": "rock metal electric guitar distortion heavy drums music",
    "Romantic": "romantic love tender intimate soft emotional music",
    "Trappy": "trap hip-hop 808 bass hi-hat beat rap music",
    "Tribal": "tribal drums percussion world music ritual beat",
    "Vocals": "prominent vocals lead singing voice song music",
    "Wintery": "winter christmas cold snow festive holiday music",
    "Weird": "weird experimental unusual strange avant-garde abstract music",
}

AUDIO_EXTS = {".mp3", ".flac", ".wav", ".ogg", ".m4a", ".aac", ".opus"}

# Words that appear in sound-effect filenames, per SFX tag. Effects are named
# after what they are far more reliably than music is — "door_creak_03.wav"
# says everything — so the filename is the first guess and the editor only
# corrects it. Longer phrases are tried first.
#
# This is not a model. It is a lookup, and it is meant to be edited: add the
# words your own library actually uses.
SFX_PHRASES = {
    "Ambience": ["ambience", "ambient", "roomtone", "room tone", "atmo",
                 "atmosphere", "background", "drone", "bed"],
    "Creature": ["creature", "monster", "growl", "roar", "snarl", "beast",
                 "dragon", "zombie", "animal", "dog", "cat", "bird"],
    "Foley": ["foley", "cloth", "rustle", "handling", "grab", "pickup",
              "paper", "coin", "keys", "fabric"],
    "Footstep": ["footstep", "footsteps", "walk", "run ", "boot", "step_",
                 "steps", "gravel", "concrete"],
    "Impact": ["impact", "hit", "punch", "smash", "crash", "thud", "slam",
               "break", "shatter", "explosion", "boom", "bang"],
    "Interface": ["ui_", "ui ", "interface", "button", "click", "menu",
                  "notification", "beep", "select", "confirm", "cancel",
                  "error", "popup", "hover"],
    "Magic": ["magic", "spell", "cast", "arcane", "enchant", "sparkle",
              "shimmer", "power up", "powerup", "buff"],
    "Mechanical": ["mechanic", "machine", "motor", "engine", "gear", "servo",
                   "robot", "hydraulic", "clank", "metal"],
    "Nature": ["nature", "wind", "rain", "thunder", "water", "river", "ocean",
               "wave", "fire", "forest", "leaves", "storm"],
    "One-Shot": ["oneshot", "one shot", "one-shot", "single", "hit_"],
    "Loop": ["loop", "looping", "_lp", "cycle", "sustained"],
    "Transition": ["transition", "riser", "downlifter", "uplifter", "sweep",
                   "stinger", "swell", "build"],
    "Vehicle": ["vehicle", "car", "truck", "engine rev", "tire", "skid",
                "plane", "helicopter", "train", "boat"],
    "Voice": ["voice", "vocal", "shout", "scream", "grunt", "laugh", "speech",
              "dialogue", "vo_", "breath"],
    "Weapon": ["weapon", "gun", "gunshot", "rifle", "pistol", "shot", "reload",
               "sword", "blade", "slash", "bow", "arrow", "laser"],
    "Whoosh": ["whoosh", "swoosh", "swish", "woosh", "pass by", "passby",
               "flyby", "air"],
}

# What a menu sound is *for*, from its filename.
#
# This is the part no acoustic model can do: Confirm and Cancel are the same
# sound and differ only in what the designer meant. Game audio nearly always
# says so in the filename, so that is where it is read from.
SFX_INTENT_PHRASES = {
    "Confirm": ["confirm", "accept", "ok_", "_ok", "yes", "success", "approve",
                "validate", "correct"],
    "Cancel": ["cancel", "back", "decline", "dismiss", "escape", "_no_", "abort",
               "reject"],
    "Error": ["error", "deny", "denied", "fail", "invalid", "wrong", "buzz",
              "negative", "forbidden", "blocked"],
    "Notification": ["notification", "notify", "alert", "message", "ping",
                     "popup", "toast", "chime"],
    "Select": ["select", "choose", "cursor", "move", "navigate", "highlight",
               "tick", "switch"],
    "Hover": ["hover", "focus", "rollover", "over_"],
    "Open": ["open", "expand", "appear", "show", "enter_", "unfold"],
    "Close-UI": ["close", "collapse", "disappear", "hide", "exit_", "fold"],
    "Purchase": ["purchase", "buy", "shop", "coin", "cash", "money", "sell",
                 "transaction"],
    "Unlock": ["unlock", "achievement", "reward", "complete", "unlocked"],
    "Level-Up": ["levelup", "level up", "level_up", "upgrade", "rank up",
                 "promote", "powerup", "power up"],
    "Pickup": ["pickup", "pick up", "collect", "grab", "loot", "gather", "item"],
    "Equip": ["equip", "unequip", "holster", "draw_", "sheath"],
    "Save": ["save", "checkpoint", "autosave"],
    "Page-Turn": ["page", "turn", "flip", "book", "scroll"],
    "Typing": ["typing", "keyboard", "keypress", "type_", "letter"],
}

# ── Game tags ────────────────────────────────────────────────────────────────
# Mirrors the Game group in the tag library. These are never predicted from
# audio — they're read out of the filename or the folder it sits in.
GAME_TAGS = [
    "A-Hat-In-Time", "Alice-Madness", "Animal-Crossing", "Another-Crab's-Treasure",
    "Balatro", "BattleBlock", "Blue-Archive", "Candy-Crush", "Celeste",
    "Command-and-Conquer", "Deus-Ex", "Donkey-Kong-Country-Returns", "Fantavision",
    "Fire-Emblem", "Genshin", "Gravity-Rush", "Homestuck-Hiveswap",
    "Jet-Set-Radio-or-Bomb-Rush-Cyberfunk", "Mario", "Mario-Galaxy", "Mario-Odyssey", "Misc",
    # "Penny-Big-Breakaway", not the tag library's "Penny's-Big-Breakaway":
    # TagSpaces wouldn't match the tag with the apostrophe, so it was renamed.
    # All 44 files use this spelling and none use the library's.
    "Mount-&-Blade", "N64-Zelda", "Need-For-Speed", "Octodad", "Penny-Big-Breakaway",
    "Pikuniku", "Pokemon-Channel", "Rabbids-Go-Home", "Ridge-Racer", "SMT4", "Sims",
    "Sonic-Mania", "Splatoon", "TMNT", "Tekken", "Undertale-Deltarune", "Warhammer",
    "Wii-Music", "Wizard-of-Legend", "Xenoblade",
]

# Game tags that have been superseded. Penny goes the other way from the tag
# library on purpose — see the note in GAME_TAGS.
GAME_ALIASES = {
    "Penny's-Big-Breakaway": "Penny-Big-Breakaway",
    "Jet-Set-Radio": "Jet-Set-Radio-or-Bomb-Rush-Cyberfunk",
}

# Phrases to look for in a filename or its folder, per game. Taken from how the
# files are actually named — a tag like "SMT4" never appears literally, while
# "Shin Megami Tensei" does. Longer phrases are tried first, so "Super Mario
# Galaxy" wins over a bare "Mario".
GAME_PHRASES = {
    "A-Hat-In-Time": ["a hat in time"],
    "Alice-Madness": ["alice madness"],
    "Animal-Crossing": ["animal crossing"],
    "Another-Crab's-Treasure": ["another crab"],
    "Balatro": ["balatro"],
    "BattleBlock": ["battleblock", "battle block"],
    "Blue-Archive": ["blue archive", "ブルーアーカイブ"],
    "Candy-Crush": ["candy crush"],
    "Celeste": ["celeste"],
    "Command-and-Conquer": ["command and conquer", "command & conquer",
                            "c c generals", "zero hour", "red alert"],
    "Deus-Ex": ["deus ex"],
    "Donkey-Kong-Country-Returns": ["donkey kong country returns", "donkey kong country"],
    "Fantavision": ["fantavision"],
    "Fire-Emblem": ["fire emblem"],
    "Genshin": ["genshin"],
    "Gravity-Rush": ["gravity rush"],
    "Homestuck-Hiveswap": ["hiveswap", "homestuck"],
    "Jet-Set-Radio-or-Bomb-Rush-Cyberfunk": ["jet set radio", "bomb rush cyberfunk",
                                             "jet set radio future"],
    # One tag for the series, not one per instalment. A search for Mario music
    # is a search for all of it, and splitting Galaxy from Odyssey from 64 put
    # three files in three places for no gain. The two older tags still exist
    # on files that carry them; renaming one onto "Mario" in the app merges
    # them.
    "Mario": [
        "super mario galaxy", "mario galaxy",
        "super mario odyssey", "mario odyssey",
        "super mario sunshine", "mario sunshine",
        "super mario world", "super mario bros", "super mario",
        "mario kart", "paper mario", "mario",
    ],
    "Mount-&-Blade": ["mount & blade", "mount and blade", "bannerlord"],
    # Deliberately not "legend of zelda": that also matches Breath of the Wild,
    # Twilight Princess and every other entry in the series.
    "N64-Zelda": ["ocarina of time", "majora's mask", "majoras mask"],
    "Need-For-Speed": ["need for speed", "hot pursuit"],
    "Octodad": ["octodad"],
    "Penny-Big-Breakaway": ["penny's big breakaway", "pennys big breakaway",
                            "penny big breakaway"],
    "Pikuniku": ["pikuniku"],
    "Pokemon-Channel": ["pokemon channel", "pokémon channel"],
    "Rabbids-Go-Home": ["rabbids go home", "rabbids"],
    "Ridge-Racer": ["ridge racer type 4", "ridge racer"],
    "SMT4": ["shin megami tensei iv", "shin megami tensei"],
    "Sims": ["the sims", "sims hot date", "sims"],
    "Sonic-Mania": ["sonic mania"],
    "Splatoon": ["splatoon"],
    "TMNT": ["tmnt", "teenage mutant ninja turtles", "shredder's revenge"],
    "Tekken": ["tekken"],
    "Undertale-Deltarune": ["undertale", "deltarune"],
    "Warhammer": ["warhammer"],
    "Wii-Music": ["wii music", "mii channel", "nintendo wii"],
    "Wizard-of-Legend": ["wizard of legend"],
    "Xenoblade": ["xenoblade"],
}
