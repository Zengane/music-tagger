"""The model half of media analysis, with no downloads.

Tiny SigLIP, Florence-2 and BERT models with random weights are built in a
temporary folder and loaded through exactly the same code as the real ones
(`from_pretrained` on a path instead of a hub name). Their answers are
nonsense, and that is fine: what is being tested is the plumbing — that the
processors are called the way this transformers version wants, that the
outputs are the shape the pipeline expects, and that the caches round-trip.

This is the test to run after upgrading transformers or torch.

    python tests_media_models.py
"""

import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import numpy as np

try:
    import torch  # noqa: F401
    import transformers  # noqa: F401
    HAVE_TORCH = True
except Exception:
    HAVE_TORCH = False

CORPUS = ["a photo of a cat", "a muzzle flash from a gun", "an explosion", "query: passage: hello",
          "What is the text in the image?", "Describe in detail what is shown in the image.",
          "the quick brown fox jumps over the lazy dog"] * 20


def _bpe(extra=()):
    from tokenizers import Tokenizer, decoders, models, pre_tokenizers, trainers

    tok = Tokenizer(models.BPE(unk_token="<unk>"))
    tok.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
    tok.decoder = decoders.ByteLevel()
    tok.train_from_iterator(CORPUS, trainers.BpeTrainer(
        vocab_size=500, special_tokens=["<s>", "<pad>", "</s>", "<unk>", "<mask>", *extra],
        initial_alphabet=pre_tokenizers.ByteLevel.alphabet()))
    return tok


def build_tiny_models(out: Path) -> None:
    from transformers import (BartTokenizerFast, BertConfig, BertModel, Florence2Config,
                              Florence2ForConditionalGeneration, Florence2Processor,
                              PreTrainedTokenizerFast, SiglipConfig, SiglipImageProcessor,
                              SiglipModel, SiglipProcessor)
    from transformers.models.clip.image_processing_pil_clip import CLIPImageProcessorPil

    cfg = SiglipConfig(
        text_config=dict(vocab_size=500, hidden_size=32, intermediate_size=64, num_hidden_layers=2,
                         num_attention_heads=2, max_position_embeddings=64),
        vision_config=dict(hidden_size=32, intermediate_size=64, num_hidden_layers=2,
                           num_attention_heads=2, image_size=64, patch_size=16))
    SiglipModel(cfg).save_pretrained(out / "siglip")
    tok = PreTrainedTokenizerFast(tokenizer_object=_bpe(), pad_token="<pad>", unk_token="<unk>", eos_token="</s>")
    SiglipProcessor(image_processor=SiglipImageProcessor(size={"height": 64, "width": 64}),
                    tokenizer=tok).save_pretrained(out / "siglip")

    BertModel(BertConfig(vocab_size=500, hidden_size=32, num_hidden_layers=2, num_attention_heads=2,
                         intermediate_size=64), add_pooling_layer=False).save_pretrained(out / "e5")
    PreTrainedTokenizerFast(tokenizer_object=_bpe(), pad_token="<pad>",
                            unk_token="<unk>").save_pretrained(out / "e5")

    bt = BartTokenizerFast(tokenizer_object=_bpe(["<image>"]), bos_token="<s>", eos_token="</s>",
                           pad_token="<pad>", unk_token="<unk>", mask_token="<mask>",
                           extra_special_tokens={"image_token": "<image>"})
    ip = CLIPImageProcessorPil(size={"height": 64, "width": 64}, crop_size={"height": 64, "width": 64},
                               do_center_crop=False)
    ip.image_seq_length = 5  # (64 / 32)^2 patches + 1 pooled token
    fcfg = Florence2Config(
        text_config=dict(model_type="bart", vocab_size=len(bt), d_model=32, encoder_layers=1, decoder_layers=1,
                         encoder_attention_heads=2, decoder_attention_heads=2, encoder_ffn_dim=64,
                         decoder_ffn_dim=64, max_position_embeddings=1024, pad_token_id=bt.pad_token_id,
                         bos_token_id=bt.bos_token_id, eos_token_id=bt.eos_token_id,
                         decoder_start_token_id=bt.eos_token_id, forced_eos_token_id=bt.eos_token_id),
        vision_config=dict(depths=(1, 1, 1, 1), embed_dim=(8, 16, 32, 32), num_heads=(1, 2, 2, 2),
                           num_groups=(1, 2, 2, 2), window_size=2, projection_dim=32, max_position_embeddings=16),
        image_token_id=bt.convert_tokens_to_ids("<image>"))
    Florence2ForConditionalGeneration(fcfg).save_pretrained(out / "florence")
    Florence2Processor(image_processor=ip, tokenizer=bt).save_pretrained(out / "florence")


def build_tiny_pe_audio(out: Path) -> None:
    """A PE Audio model the size of a postage stamp, saved like a checkpoint."""
    from transformers import PeAudioConfig, PeAudioModel, PeAudioProcessor, PreTrainedTokenizerFast
    from transformers.models.pe_audio.feature_extraction_pe_audio import PeAudioFeatureExtractor

    cfg = PeAudioConfig(
        text_config=dict(model_type="modernbert", vocab_size=500, hidden_size=32, intermediate_size=64,
                         num_hidden_layers=2, num_attention_heads=2, pad_token_id=1, bos_token_id=0,
                         eos_token_id=2, cls_token_id=0, sep_token_id=2),
        audio_config=dict(hidden_size=32, intermediate_size=64, num_hidden_layers=1, num_attention_heads=2,
                          head_dim=16, dac_config=dict(encoder_hidden_size=8, codebook_dim=16)))
    PeAudioModel(cfg).save_pretrained(out)
    tok = PreTrainedTokenizerFast(tokenizer_object=_bpe(), pad_token="<pad>", unk_token="<unk>", cls_token="<s>")
    PeAudioProcessor(feature_extractor=PeAudioFeatureExtractor(), tokenizer=tok).save_pretrained(out)


@unittest.skipUnless(HAVE_TORCH and shutil.which("ffmpeg"), "needs torch, transformers and ffmpeg")
class SoundModelPlumbing(unittest.TestCase):
    """PE-AV: the sound search model of the balanced and best profiles."""

    @classmethod
    def setUpClass(cls):
        import mtag.encoders as E

        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        build_tiny_pe_audio(root / "pe")
        cls.Tiny = type("TinyPe", (E.PeAvEncoder,), {"name": "tiny-pe", "MODEL_ID": str(root / "pe")})
        cls.enc = cls.Tiny()
        cls.enc.load()
        cls.wav = root / "tone.wav"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=300:duration=23",
                        str(cls.wav)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_windows_pool_and_text(self):
        w = self.enc.embed_windows_file(self.wav)
        self.assertEqual(w.shape[0], 2)  # 23 s in 10 s windows
        v = self.enc.embed_file(self.wav)
        self.assertEqual(v.shape[0], w.shape[1] * 2)  # mean + std
        self.assertAlmostEqual(float(np.linalg.norm(v)), 1.0, places=4)
        t = self.enc.embed_text(["an explosion", "a door"])
        np.testing.assert_allclose(np.linalg.norm(t, axis=1), 1, atol=1e-4)
        p = self.enc.probabilities(w.mean(0, keepdims=True), self.enc.embed_text(["x"], raw=True))
        self.assertTrue(0 < float(p[0, 0]) < 1)

    def test_every_effect_category_has_prompts(self):
        from mtag import sfxtax

        for group, tags in sfxtax.SFX_GROUPS:
            if group in ("SFX Intent", "SFX Length"):
                continue
            for tag in tags:
                self.assertIn(tag, sfxtax.SFX_PROMPTS, f"{group}: {tag}")

    def test_audio_video_checkpoint(self):
        # The published PE-AV checkpoints are audio-video models. Only the
        # audio and text parts are kept, and they must be the trained ones.
        try:
            import timm  # noqa: F401
        except ImportError:
            self.skipTest("timm is not installed")
        import torch
        from transformers import AutoModel, PeAudioVideoConfig, PeAudioVideoModel, PreTrainedTokenizerFast
        from transformers.models.pe_audio.feature_extraction_pe_audio import PeAudioFeatureExtractor
        import mtag.encoders as E

        out = Path(self.tmp.name) / "pe-av"
        small = dict(hidden_size=32, intermediate_size=64, num_hidden_layers=1, num_attention_heads=2, head_dim=16)
        cfg = PeAudioVideoConfig(
            text_config=dict(model_type="modernbert", vocab_size=500, hidden_size=32, intermediate_size=64,
                             num_hidden_layers=2, num_attention_heads=2, pad_token_id=1, bos_token_id=0,
                             eos_token_id=2, cls_token_id=0, sep_token_id=2),
            audio_video_config=dict(**small,
                audio_config=dict(**small, dac_config=dict(encoder_hidden_size=8, codebook_dim=16)),
                video_config=dict(**small, vision_config=dict(
                    architecture="vit_tiny_patch16_224", num_classes=8,
                    model_args={"embed_dim": 32, "depth": 1, "num_heads": 2, "img_size": 32}))))
        PeAudioVideoModel(cfg).save_pretrained(out)
        PreTrainedTokenizerFast(tokenizer_object=_bpe(), pad_token="<pad>", unk_token="<unk>",
                                cls_token="<s>").save_pretrained(out)
        PeAudioFeatureExtractor().save_pretrained(out)

        enc = type("TinyPeAv", (E.PeAvEncoder,), {"MODEL_ID": str(out)})()
        enc.load()
        self.assertFalse(hasattr(enc.model, "video_model"))
        ref = AutoModel.from_pretrained(out).audio_model.text_audio_head.proj.weight
        self.assertTrue(torch.allclose(ref, enc.model.text_audio_head.proj.weight.float()))
        self.assertEqual(enc.embed_windows_file(self.wav).shape[0], 2)

    def test_in_a_fusion(self):
        import mtag.encoders as E

        E.ENCODERS["tiny-pe"] = self.Tiny
        try:
            f = E.get_encoder("fusion:tiny-pe")
            v = f.embed_file(self.wav)
            self.assertEqual(f.text_slice(v.shape[0]), (0, v.shape[0] // 2))
            self.assertEqual(f.embed_text(["a riser"]).shape[0], 1)
        finally:
            del E.ENCODERS["tiny-pe"]
            import mtag.dataset as DS

            shutil.rmtree(DS.CACHE_ROOT / "tiny-pe", ignore_errors=True)
            shutil.rmtree(DS.CACHE_ROOT / "fusion_tiny-pe", ignore_errors=True)


@unittest.skipUnless(HAVE_TORCH and shutil.which("ffmpeg"), "needs torch, transformers and ffmpeg")
class ModelPlumbing(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import mtag.dataset as DS
        from mtag.media import analyze as AN
        from mtag.media import models as MD

        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        # Keep this test's caches out of the real ones.
        cls._cache = DS.CACHE_ROOT
        DS.CACHE_ROOT = AN.CACHE_ROOT = root / "cache"
        build_tiny_models(root / "models")
        cls.models = AN.Models(
            siglip=MD.Siglip(str(root / "models" / "siglip")).load(),
            florence=MD.Florence(str(root / "models" / "florence")).load(),
            text=MD.TextEmbedder(str(root / "models" / "e5")).load(),
            build="plumbing")
        cls.bank = AN.build_prompts(cls.models)

        media = root / "media"
        media.mkdir()
        from PIL import Image

        Image.new("RGB", (320, 200), (20, 190, 60)).save(media / "green.png")
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=25:d=2",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", str(media / "clip.mp4")], check=True)
        (media / "notes.txt").write_text("Shot list: drone over the harbour at dawn.", encoding="utf-8")
        cls.paths = sorted(media.iterdir())

    @classmethod
    def tearDownClass(cls):
        import mtag.dataset as DS
        from mtag.media import analyze as AN

        DS.CACHE_ROOT = AN.CACHE_ROOT = cls._cache
        cls.tmp.cleanup()

    def test_prompts_embedded(self):
        n_prompts = sum(len(p) for g in self.bank.groups for p in g.tags.values())
        self.assertEqual(self.bank.prompt_vecs.shape[0], n_prompts)
        self.assertEqual(self.bank.doc_vecs.shape[0], len(self.bank.doc_labels))
        np.testing.assert_allclose(np.linalg.norm(self.bank.prompt_vecs, axis=1), 1, atol=1e-4)

    def test_pipeline_and_cache(self):
        from mtag.media import analyze as AN

        errors = []
        results = AN.analyse_batch(self.paths, self.models, self.bank,
                                   on_error=lambda p, e: errors.append((p, e)), use_cache=False)
        self.assertEqual(errors, [])
        by_name = {Path(r.path).name: r for r in results}
        self.assertEqual(set(by_name), {"green.png", "clip.mp4", "notes.txt"})

        for name in ("green.png", "clip.mp4"):
            r = by_name[name]
            self.assertIsNotNone(r.visual_vec)
            self.assertIsNotNone(r.text_vec)
            self.assertTrue(r.thumb and Path(r.thumb).exists())
            self.assertIsInstance(r.caption, str)
            self.assertGreater(len(r.scores), 50)  # measured + zero-shot
        self.assertIn("Green-Screen", by_name["green.png"].selected())
        self.assertIsNone(by_name["notes.txt"].visual_vec)
        self.assertIsNotNone(by_name["notes.txt"].text_vec)
        self.assertIn("Script", by_name["notes.txt"].scores)  # document labels were scored

        event = by_name["clip.mp4"].to_event()
        import json

        json.dumps(event)  # must be serialisable as it stands

        again = AN.analyse_batch(self.paths, self.models, self.bank)
        self.assertEqual({Path(r.path).name: sorted(r.scores) for r in again},
                         {n: sorted(r.scores) for n, r in by_name.items()})


if __name__ == "__main__":
    unittest.main(verbosity=2)
