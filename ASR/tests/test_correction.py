import unittest

from asr_lab.correction import candidates, choose_conservative, choose_naive, load_lexicon
from asr_lab.evaluate import errors


class CorrectionTests(unittest.TestCase):
    def setUp(self):
        self.lexicon = load_lexicon()

    def test_personal_name_with_context(self):
        source = "请发给同事齐彦。"
        options = candidates(source,self.lexicon)
        self.assertEqual(options[0].text,source)
        self.assertEqual(choose_conservative(options).text,"请发给同事祁砚。")

    def test_legitimate_homophone_is_protected_without_context(self):
        source = "请把婚礼请柬放在桌子上。"
        options = candidates(source,self.lexicon)
        self.assertIn("青简",choose_naive(options).text)
        self.assertEqual(choose_conservative(options).text,source)

    def test_ambiguous_personal_names_abstain(self):
        lexicon = self.lexicon + [{"text":"齐燕","pinyin":["qi","yan"],"contexts":["同事"]}]
        source = "同事齐彦到了。"
        self.assertEqual(choose_conservative(candidates(source,lexicon)).text,source)

    def test_english_and_digits_unchanged(self):
        source = "Cloudflare API v2: 2026-09-15, id=123."
        self.assertEqual(choose_conservative(candidates(source,self.lexicon)).text,source)

    def test_overlapping_dictionary_entries_do_not_duplicate_text(self):
        lexicon = [{"text":"青简","pinyin":["qing","jian"],"contexts":["项目"]},
                   {"text":"青简输入法","pinyin":["qing","jian","shu","ru","fa"],"contexts":["项目"]}]
        options = candidates("项目清简输入法",lexicon)
        self.assertEqual({c.text for c in options},{"项目清简输入法","项目青简输入法"})

    def test_error_count_includes_insertions_and_deletions(self):
        self.assertEqual(errors("你好，世界！","你好世界"),0)
        self.assertEqual(errors("你好世界","你好"),2)
        self.assertEqual(errors("你好","你好世界"),2)


if __name__ == "__main__":
    unittest.main()
