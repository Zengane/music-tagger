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
