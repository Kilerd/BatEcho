import unittest

import mlx.core as mx
import numpy as np
from mlx_audio.stt.models.fireredasr2 import Model, ModelConfig

from asr_lab.firered_bias import biased_beam_search
from asr_lab.hotwords import ContextGraph


class ContextGraphTests(unittest.TestCase):
    vocab = ["<blank>","<unk>","<pad>","<sos>","<eos>","青","简","输","入","▁AP","I","S","中"]

    def graph(self, phrases, score=4):
        return ContextGraph(phrases,self.vocab,4,score)

    def total(self, graph, tokens):
        state,score,seen = 0,0.0,0
        for token in tokens:
            state,reward,seen = graph.step(state,token,seen)
            score += reward
        return score+graph.finalize(state,seen)

    def test_partial_prefix_is_fully_refunded(self):
        graph = self.graph([{"ids":[5,6]}])
        self.assertEqual(self.total(graph,[5]),0)
        self.assertEqual(self.total(graph,[5,12]),0)

    def test_completed_phrase_gets_one_length_independent_reward(self):
        graph = self.graph([{"ids":[5,6]},{"ids":[7,8,5,6]}])
        self.assertEqual(self.total(graph,[5,6,12]),4)
        # The longer phrase and its complete suffix are both present.
        self.assertEqual(self.total(graph,[7,8,5,6,12]),8)

    def test_shared_prefix_failure_preserves_suffix_match(self):
        graph = self.graph([{"ids":[5,6,7]},{"ids":[6,8]}])
        self.assertEqual(self.total(graph,[5,6,8,12]),4)

    def test_english_reward_waits_for_boundary(self):
        graph = self.graph([{"ids":[9,10],"english_boundary":True}])
        self.assertEqual(self.total(graph,[9,10,4]),4)
        self.assertEqual(self.total(graph,[9,10,12]),4)
        self.assertEqual(self.total(graph,[9,10,11,4]),0)  # APIS != API
        self.assertEqual(self.total(graph,[9,10]),0)  # token-limit cutoff

    def test_duplicate_phrases_do_not_multiply_reward(self):
        graph = self.graph([{"ids":[5,6]},{"ids":[5,6]}])
        self.assertEqual(self.total(graph,[5,6,4]),4)

    def test_repeating_a_word_cannot_accumulate_more_reward(self):
        graph = self.graph([{"ids":[5,6]}],score=8)
        self.assertEqual(self.total(graph,[5,6]*20+[4]),8)
        state,_,seen = graph.step(0,5,0)
        state,_,seen = graph.step(state,6,seen)
        state,reward,seen = graph.step(state,5,seen)
        self.assertEqual(reward,0)

    def test_reward_vectors_match_state_machine_with_used_words(self):
        graph = self.graph([{"ids":[5,6]},{"ids":[9,10],"english_boundary":True}])
        for state in range(len(graph.nodes)):
            for seen in range(4):
                rewards = graph.reward_vector(state,seen)
                for token in range(len(self.vocab)):
                    _,reward,_ = graph.step(state,token,seen)
                    self.assertAlmostEqual(rewards[token],reward,places=5)

    def test_zero_bias_preserves_original_beam_search(self):
        mx.random.seed(19)
        model = Model(ModelConfig.from_dict({
            "d_model":16,"odim":len(self.vocab),
            "encoder":{"n_layers":1,"n_head":4,"d_model":16},
            "decoder":{"n_layers":1,"n_head":4,"d_model":16},
        }))
        encoded = mx.random.normal((1,5,16))
        options = {"beam_size":3,"max_len":6,"eos_penalty":0.8}
        expected,_ = model.decoder.beam_search(encoded,**options)
        graph = self.graph([{"ids":[5,6]}],score=0)
        actual,confidence = biased_beam_search(model.decoder,encoded,graph,**options)
        self.assertEqual(actual.tolist(),expected.tolist())
        self.assertTrue(np.isfinite(np.array(confidence)).all())
        self.assertLessEqual(float(mx.max(confidence).item()),1.0)


if __name__ == "__main__":
    unittest.main()
