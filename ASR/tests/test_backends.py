import unittest
from asr_lab.backends import Backend, DEFAULT_MODEL, resolve_hotwords


class BackendContractTests(unittest.TestCase):
    def test_default_model_uses_post_correction_without_native_hotwords(self):
        self.assertEqual(DEFAULT_MODEL, "firered")
        self.assertFalse(resolve_hotwords(DEFAULT_MODEL, None))
        self.assertFalse(resolve_hotwords(DEFAULT_MODEL, False))

    def test_existing_models_keep_automatic_hotword_support(self):
        for name in ["qwen", "fun"]:
            self.assertTrue(resolve_hotwords(name, None))
            self.assertFalse(resolve_hotwords(name, False))

    def test_firered_contextual_decoding_is_explicitly_enabled(self):
        self.assertTrue(resolve_hotwords("firered",True))

    def test_invalid_bias_is_rejected_before_model_loading(self):
        for score in [-1,float("nan"),float("inf")]:
            with self.assertRaisesRegex(ValueError, "finite and nonnegative"):
                Backend(hotword_score=score)

    def test_unknown_backend_cannot_silently_fall_through(self):
        with self.assertRaisesRegex(ValueError, "Unknown backend"):
            resolve_hotwords("unavailable", None)


if __name__ == "__main__":
    unittest.main()
