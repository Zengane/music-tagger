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

# ── Game tags ────────────────────────────────────────────────────────────────
# Mirrors the Game group in the tag library. These are never predicted from
# audio — they're read out of the filename or the folder it sits in.
GAME_TAGS = [
    "A-Hat-In-Time", "Alice-Madness", "Animal-Crossing", "Another-Crab's-Treasure",
    "Balatro", "BattleBlock", "Blue-Archive", "Candy-Crush", "Celeste",
    "Command-and-Conquer", "Deus-Ex", "Donkey-Kong-Country-Returns", "Fantavision",
    "Fire-Emblem", "Genshin", "Gravity-Rush", "Homestuck-Hiveswap",
    "Jet-Set-Radio-or-Bomb-Rush-Cyberfunk", "Mario-Galaxy", "Mario-Odyssey", "Misc",
    "Mount-&-Blade", "N64-Zelda", "Need-For-Speed", "Octodad", "Penny's-Big-Breakaway",
    "Pikuniku", "Pokemon-Channel", "Rabbids-Go-Home", "Ridge-Racer", "SMT4", "Sims",
    "Sonic-Mania", "Splatoon", "TMNT", "Tekken", "Undertale-Deltarune", "Warhammer",
    "Wii-Music", "Wizard-of-Legend", "Xenoblade",
]

# Game tags in sidecars that predate a rename in the tag library.
GAME_ALIASES = {
    "Penny-Big-Breakaway": "Penny's-Big-Breakaway",
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
    "Mario-Galaxy": ["super mario galaxy", "mario galaxy"],
    "Mario-Odyssey": ["super mario odyssey", "mario odyssey"],
    "Mount-&-Blade": ["mount & blade", "mount and blade", "bannerlord"],
    # Deliberately not "legend of zelda": that also matches Breath of the Wild,
    # Twilight Princess and every other entry in the series.
    "N64-Zelda": ["ocarina of time", "majora's mask", "majoras mask"],
    "Need-For-Speed": ["need for speed", "hot pursuit"],
    "Octodad": ["octodad"],
    "Penny's-Big-Breakaway": ["penny's big breakaway", "pennys big breakaway",
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
