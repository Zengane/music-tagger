"""The words the image models are asked about, and how sure they must be.

Each group names the kinds it applies to, how scores from several frames are
combined, and a threshold. A tag scoring above its threshold applies itself;
below it, it is offered as a ranked suggestion — the same rule the music
tagger uses, so the front end treats both alike.

**The thresholds are starting points, not measurements.** SigLIP's sigmoid
scores are not calibrated across concepts, and nothing here has been measured
on a real library yet. The music side earned its thresholds by measuring
precision per tag; the same has to be done here, on the owner's files, before
these numbers deserve trust. `media_vocab.json` beside the app overrides any
of them without touching code (see `load`).

Tag names follow the library's existing style: Title-Case, words joined by
hyphens.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

from .. import kinds as K

IMG, VID, M3D = K.IMAGE, K.VIDEO, K.MODEL


@dataclass
class Group:
    name: str
    kinds: tuple[str, ...]
    tags: dict[str, list[str]]
    threshold: float = 0.10
    # "max": present in any frame is enough (a flash, a meme caption).
    # "mean": must hold across the clip (a location, a subject).
    pool: str = "mean"
    # Never applied automatically, only suggested — for tags a wrong guess
    # would be embarrassing or where the model is known to be shaky.
    suggest_only: bool = False
    overrides: dict[str, float] = field(default_factory=dict)  # per-tag thresholds


def _p(*phrases: str) -> list[str]:
    return list(phrases)


GROUPS: list[Group] = [
    Group("VFX", (VID, IMG), pool="max", threshold=0.10, tags={
        "Muzzle-Flash": _p("a muzzle flash from a gun", "a gunshot muzzle flash on a black background"),
        "Explosion": _p("an explosion fireball", "a large explosion with fire and smoke"),
        "Fire": _p("flames", "a fire burning"),
        "Smoke": _p("smoke", "a cloud of smoke on a black background"),
        "Sparks": _p("sparks flying", "welding sparks"),
        "Lens-Flare": _p("a lens flare", "an anamorphic lens flare streak of light"),
        "Light-Leak": _p("a light leak film overlay", "an orange light leak"),
        "Film-Burn": _p("a film burn transition", "burning film overlay"),
        "Film-Grain": _p("film grain and dust scratches overlay", "old film dust and scratches"),
        "Lightning": _p("a lightning bolt", "electric lightning"),
        "Electricity": _p("electric arcs", "electricity sparks and arcs"),
        "Magic-Energy": _p("a magic energy effect", "glowing magical particles"),
        "Shockwave": _p("a shockwave ring", "a shockwave blast"),
        "Dust": _p("a dust cloud", "dust particles floating"),
        "Debris": _p("flying debris", "rubble and debris flying"),
        "Blood": _p("blood splatter", "a blood spray"),
        "Water-Splash": _p("a water splash", "splashing water"),
        "Rain": _p("rain falling", "raindrops overlay"),
        "Snow": _p("snow falling", "snowflakes overlay"),
        "Fog": _p("fog", "mist and fog"),
        "Glitch": _p("a digital glitch effect", "glitch distortion"),
        "Particles": _p("glowing particles", "floating particles on a black background"),
        "Bokeh": _p("bokeh lights", "blurry out of focus lights"),
        "Fireworks": _p("fireworks", "fireworks exploding in the night sky"),
        "Confetti": _p("confetti", "falling confetti"),
        "Bullet-Impact": _p("a bullet impact", "bullet hit sparks on a wall"),
        "Laser": _p("a laser beam", "a sci-fi laser"),
        "Portal": _p("a magic portal", "a swirling portal"),
        "Hologram": _p("a hologram", "a holographic interface"),
        "HUD": _p("a futuristic HUD interface", "heads-up display graphics"),
        "Transition": _p("a video transition effect", "a wipe transition"),
    }),
    Group("B-Roll", (VID, IMG), threshold=0.10, tags={
        "Aerial": _p("an aerial drone shot", "a drone view from above"),
        "Timelapse": _p("a timelapse", "a time-lapse of clouds moving"),
        "Cityscape": _p("a city skyline", "a cityscape"),
        "Street": _p("a busy street", "people walking on a city street"),
        "Traffic": _p("traffic on a road", "cars driving on a highway"),
        "Nature": _p("nature", "a natural landscape"),
        "Landscape": _p("a wide landscape", "scenic countryside"),
        "Mountains": _p("mountains", "a mountain range"),
        "Forest": _p("a forest", "trees in a forest"),
        "Beach": _p("a beach", "a sandy beach with waves"),
        "Ocean": _p("the ocean", "sea waves"),
        "Desert": _p("a desert", "sand dunes"),
        "Sky": _p("the sky", "clouds in the sky"),
        "Sunset": _p("a sunset", "a sunrise"),
        "Night": _p("at night", "a night scene"),
        "Office": _p("an office", "people working in an office"),
        "Home-Interior": _p("a home interior", "a living room"),
        "Kitchen": _p("a kitchen", "cooking in a kitchen"),
        "Crowd": _p("a crowd of people", "a large crowd"),
        "People": _p("people", "a group of people"),
        "Portrait": _p("a portrait of a person", "a close-up of a face"),
        "Hands": _p("close-up of hands", "hands doing something"),
        "Technology": _p("technology", "a computer screen and devices"),
        "Industry": _p("a factory", "industrial machinery"),
        "Sports": _p("sports", "an athlete playing sport"),
        "Concert": _p("a concert", "a crowd at a music concert"),
        "Food": _p("food", "a plate of food"),
        "Animals": _p("animals", "a wild animal"),
        "Water": _p("water", "a river or a lake"),
        "Architecture": _p("architecture", "a building facade"),
    }),
    Group("Shot", (VID, IMG), threshold=0.10, tags={
        "Close-Up": _p("an extreme close-up shot", "a close-up"),
        "Wide-Shot": _p("a wide establishing shot", "a wide shot"),
        "Macro": _p("a macro photo", "extreme macro close-up"),
        "Top-Down": _p("a top-down flat lay", "a view from directly above"),
        "Slow-Motion": _p("a slow motion shot"),
        "Silhouette": _p("a silhouette against the light"),
        "Talking-Head": _p("a person talking to the camera", "an interview shot"),
        "Screen-Recording": _p("a screen recording of a computer", "a screenshot of software"),
        "Gameplay": _p("video game gameplay footage", "a screenshot of a video game"),
    }),
    Group("Style", (IMG, VID, M3D), threshold=0.10, tags={
        "Photo": _p("a photograph", "a stock photo"),
        "Illustration": _p("an illustration", "a digital illustration"),
        "3D-Render": _p("a 3D render", "computer generated 3D graphics"),
        "Cartoon": _p("a cartoon", "a cartoon drawing"),
        "Anime": _p("anime", "an anime illustration"),
        "Pixel-Art": _p("pixel art", "retro pixel art sprite"),
        "Painting": _p("a painting", "an oil painting"),
        "Sketch": _p("a pencil sketch", "a line drawing"),
        "Flat-Design": _p("flat vector design", "a vector illustration"),
        "Logo": _p("a logo", "a brand logo"),
        "Icon": _p("an icon", "a simple app icon"),
        "Texture": _p("a seamless texture", "a surface texture"),
        "Pattern": _p("a repeating pattern"),
        "Infographic": _p("an infographic", "a chart or graph"),
        "Poster": _p("a poster", "a movie poster"),
        "Vintage": _p("a vintage photo", "a retro film look"),
    }),
    Group("Meme", (IMG, VID), pool="max", threshold=0.12, tags={
        "Meme": _p("an internet meme", "a meme with a caption", "an image macro meme"),
        "Reaction": _p("a reaction image", "a reaction face meme"),
        "Screenshot": _p("a screenshot of a social media post", "a screenshot of a tweet"),
    }),
    # Famous templates. Suggested, never applied: the model knows some of them
    # and confidently misnames others.
    Group("Meme-Template", (IMG, VID), pool="max", threshold=0.30, suggest_only=True, tags={
        "Drake-Hotline-Bling": _p("the Drake Hotline Bling meme"),
        "Distracted-Boyfriend": _p("the distracted boyfriend meme"),
        "Woman-Yelling-At-Cat": _p("the woman yelling at a cat meme"),
        "This-Is-Fine": _p("the this is fine dog in a burning room meme"),
        "Surprised-Pikachu": _p("the surprised Pikachu meme"),
        "Expanding-Brain": _p("the expanding brain meme"),
        "Two-Buttons": _p("the two buttons meme sweating man"),
        "Change-My-Mind": _p("the change my mind meme"),
        "Stonks": _p("the stonks meme"),
        "Gigachad": _p("the gigachad meme"),
        "Wojak": _p("a wojak meme drawing"),
        "Pepe": _p("Pepe the frog"),
        "Doge": _p("the doge shiba inu meme"),
        "Trollface": _p("a trollface meme"),
    }),
    Group("3D", (M3D,), threshold=0.10, tags={
        "Character": _p("a 3D character model", "a humanoid character"),
        "Creature": _p("a creature", "a monster"),
        "Weapon": _p("a weapon", "a sword or a gun"),
        "Vehicle": _p("a vehicle", "a car"),
        "Furniture": _p("furniture", "a chair or a table"),
        "Building": _p("a building", "a house"),
        "Prop": _p("a small prop object"),
        "Environment": _p("a 3D environment scene", "a terrain"),
        "Plant": _p("a plant", "a tree"),
        "Rock": _p("a rock", "a stone"),
        "Food": _p("food"),
        "Jewellery": _p("jewellery", "a ring"),
    }),
]


# Document categories, scored by the text model rather than the image model.
DOCUMENT_TAGS: dict[str, str] = {
    "Script": "a screenplay or video script with scenes and dialogue",
    "Lyrics": "song lyrics with verses and a chorus",
    "Notes": "personal notes or a to-do list",
    "Shot-List": "a shot list or storyboard notes for a video shoot",
    "Invoice": "an invoice or a receipt with amounts to pay",
    "Contract": "a legal contract or agreement",
    "Report": "a report with findings",
    "Article": "a news or blog article",
    "Recipe": "a cooking recipe with ingredients",
    "Resume": "a CV or resume",
    "Letter": "a letter or an email",
    "Manual": "a user manual or instructions",
    "Subtitles": "subtitles or a transcript of speech",
    "Brief": "a creative brief or client requirements",
}
DOCUMENT_THRESHOLD = 0.30


def load(root: Path | None = None) -> list[Group]:
    """The groups, with any overrides from `media_vocab.json` applied.

    The file may set a group's threshold, a single tag's threshold, add tags
    with their own phrases, or remove tags:

        {"VFX": {"threshold": 0.12,
                 "tags": {"Muzzle-Flash": {"threshold": 0.2},
                          "Blood-Squib": {"phrases": ["a blood squib"]}},
                 "remove": ["Confetti"]}}
    """
    groups = [Group(g.name, g.kinds, dict(g.tags), g.threshold, g.pool, g.suggest_only, dict(g.overrides))
              for g in GROUPS]
    root = root or Path(__file__).resolve().parents[2]
    path = root / "media_vocab.json"
    if not path.exists():
        return groups
    try:
        doc = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return groups
    by_name = {g.name: g for g in groups}
    for name, spec in doc.items():
        g = by_name.get(name)
        if g is None or not isinstance(spec, dict):
            continue
        if "threshold" in spec:
            g.threshold = float(spec["threshold"])
        for tag in spec.get("remove", []):
            g.tags.pop(tag, None)
        for tag, t in (spec.get("tags") or {}).items():
            if "phrases" in t:
                g.tags[tag] = list(t["phrases"])
            if "threshold" in t:
                g.overrides[tag] = float(t["threshold"])
    return groups


def all_tags() -> dict[str, list[str]]:
    """Group name -> tag names, including measured and document tags. For the
    front end's vocabulary."""
    from .measure import MEASURED_GROUPS

    out = {g.name: list(g.tags) for g in GROUPS}
    out.update(MEASURED_GROUPS)
    out["Document"] = list(DOCUMENT_TAGS)
    return out
