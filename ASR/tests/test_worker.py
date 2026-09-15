import io
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import soundfile as sf

from asr_lab.backends import Recognition
from asr_lab.worker import Pipeline, serve


class FakeBackend:
    def __init__(self, *args, **kwargs):
        self.calls = []
        self.truncated = False

    def recognize(self, audio, hotwords):
        self.calls.append(hotwords)
        return Recognition("这个项目由同事景恒负责", 0.8, self.truncated)


class FakeGate:
    has_speech = True

    def __init__(self, **kwargs):
        pass

    def check(self, audio):
        return {"has_speech": self.has_speech}


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.audio = self.root / "recording.caf"
        sf.write(self.audio, np.zeros((4800, 2)), 48000, format="CAF", subtype="FLOAT")
        self.lexicon = self.root / "lexicon.json"
        self.lexicon.write_text(json.dumps([
            {"text": "璟珩", "pinyin": ["jing", "heng"], "contexts": ["同事"]}
        ]))
        self.pipeline = Pipeline(self.root, self.lexicon, backend_factory=FakeBackend, gate_factory=FakeGate)
        self.request = {"type": "transcribe", "audio": str(self.audio)}

    def test_defaults_apply_conservative_correction_without_decoder_hotwords(self):
        result = self.pipeline.handle(self.request)
        self.assertEqual(result["text"], "这个项目由同事璟珩负责")
        self.assertEqual(result["raw_text"], "这个项目由同事景恒负责")
        self.assertIsNone(self.pipeline.backend.calls[0])
        self.assertAlmostEqual(result["duration_s"], 0.1)

    def test_hotwords_and_updated_vocabulary_reach_same_warm_model(self):
        self.pipeline.handle({"type": "warmup"})
        self.pipeline.handle({**self.request, "hotwords": True, "correction": "none"})
        self.lexicon.write_text(json.dumps([{"text": "Kubernetes", "pinyin": []}]))
        result = self.pipeline.handle({**self.request, "hotwords": True, "hotword_score": 2})
        self.assertEqual(self.pipeline.backend.calls, [["璟珩"], ["Kubernetes"]])
        self.assertEqual(result["model_load_count"], 1)
        self.assertEqual(self.pipeline.backend.hotword_score, 2)

    def test_correction_can_be_disabled(self):
        result = self.pipeline.handle({**self.request, "correction": "none"})
        self.assertEqual(result["text"], result["raw_text"])

    def test_silence_does_not_load_asr(self):
        self.pipeline.load_gate().has_speech = False
        result = self.pipeline.handle(self.request)
        self.assertEqual(result["text"], "")
        self.assertEqual(result["model_load_count"], 0)

    def test_invalid_options_are_rejected_before_model_loading(self):
        for options in [{"hotwords": "yes"}, {"hotword_score": -1}, {"hotword_score": 9},
                        {"hotword_score": float("nan")}, {"correction": "invent"}]:
            with self.subTest(options=options), self.assertRaises(ValueError):
                self.pipeline.handle({**self.request, **options})
        self.assertEqual(self.pipeline.model_load_count, 0)

    def test_long_audio_is_rejected_before_loading_or_decoding(self):
        sf.write(self.audio, np.zeros(16000 * 31), 16000, format="CAF")
        with self.assertRaisesRegex(ValueError, "30 seconds"):
            self.pipeline.handle(self.request)
        self.assertIsNone(self.pipeline.gate)
        self.assertEqual(self.pipeline.model_load_count, 0)

    def test_invalid_vocabulary_can_be_fixed_without_restarting_worker(self):
        self.pipeline.handle({"type": "warmup"})
        self.lexicon.write_text('[{"text":"璟珩"}]')
        with self.assertRaisesRegex(ValueError, "pinyin array"):
            self.pipeline.handle(self.request)
        self.lexicon.write_text('[]')
        result = self.pipeline.handle(self.request)
        self.assertEqual(result["text"], result["raw_text"])
        self.assertEqual(result["model_load_count"], 1)

    def test_output_limit_does_not_return_an_incomplete_transcript(self):
        self.pipeline.load_model().truncated = True
        with self.assertRaisesRegex(ValueError, "output limit"):
            self.pipeline.handle(self.request)

    def test_error_response_is_scoped_and_later_requests_still_work(self):
        lines = ["invalid", json.dumps({"id": "bad", "type": "unknown"}),
                 json.dumps({"id": "good", **self.request})]
        output = io.StringIO()
        serve(self.pipeline, io.StringIO("\n".join(lines)), output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertIn("error", responses[0])
        self.assertEqual(responses[1]["id"], "bad")
        self.assertEqual(responses[2]["id"], "good")
        self.assertEqual(responses[2]["text"], "这个项目由同事璟珩负责")


if __name__ == "__main__":
    unittest.main()
