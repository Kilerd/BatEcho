import unittest

from mlx.utils import tree_flatten
from mlx_audio.stt.models.fireredasr2 import Model, ModelConfig

from asr_lab.firered import restore_position_tables


class FireRedWeightValidationTests(unittest.TestCase):
    def setUp(self):
        self.model = Model(ModelConfig.from_dict({
            "d_model":16, "odim":32,
            "encoder":{"n_layers":1,"n_head":4,"d_model":16},
            "decoder":{"n_layers":1,"n_head":4,"d_model":16},
        }))
        self.weights = dict(tree_flatten(self.model.parameters()))
        for key in ["encoder.positional_encoding.pe", "decoder.positional_encoding.pe"]:
            del self.weights[key]

    def test_checkpoint_without_fixed_position_tables_loads_strictly(self):
        restored = restore_position_tables(self.model, self.weights)
        self.model.load_weights(list(restored.items()), strict=True)
        self.assertNotIn("encoder.positional_encoding.pe", self.weights)

    def test_missing_learned_weight_still_fails(self):
        del self.weights["decoder.tgt_word_emb.weight"]
        restored = restore_position_tables(self.model, self.weights)
        with self.assertRaisesRegex(ValueError, "decoder.tgt_word_emb.weight"):
            self.model.load_weights(list(restored.items()), strict=True)

    def test_unexpected_checkpoint_weight_still_fails(self):
        self.weights["unexpected.weight"] = self.weights["decoder.tgt_word_emb.weight"]
        restored = restore_position_tables(self.model, self.weights)
        with self.assertRaisesRegex(ValueError, "unexpected.weight"):
            self.model.load_weights(list(restored.items()), strict=True)


if __name__ == "__main__":
    unittest.main()
