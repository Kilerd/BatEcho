"""Rebuild static Swift pinyin data and Python parity fixtures (development only).

Run from the repository with ASR's locked Python 3.12 environment. The application
never invokes this script. Licenses live in Sources/voicer/ASRResources.
"""
import argparse
import json
import sys
from pathlib import Path

import mlx.core as mx
import numpy as np
import sentencepiece as spm
from mlx_audio.dsp import compute_fbank_kaldi
from pypinyin import Style
from pypinyin.constants import PHRASES_DICT, PINYIN_DICT
from pypinyin.style import convert

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'ASR'))
from asr_lab.correction import candidates, choose_conservative, load_lexicon


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model-dir', type=Path,
                        default=Path.home() / 'Library/Application Support/voicer/asr/models/firered')
    args = parser.parse_args()
    resources = ROOT / 'Sources/voicer/ASRResources'
    fixtures = ROOT / 'Tests/voicerTests/Fixtures'
    normal = lambda value: convert(value, Style.NORMAL, strict=True)
    characters = {chr(k): normal(v.split(',')[0]) for k, v in PINYIN_DICT.items()}
    phrases = {k: [normal(p[0]) for p in v] for k, v in PHRASES_DICT.items()}
    for name, value in [('pinyin-characters', characters), ('pinyin-phrases', phrases)]:
        (resources / (name + '.json')).write_text(json.dumps(value, ensure_ascii=False, separators=(',', ':'), sort_keys=True) + '\n')
    for name in ['dict.txt', 'train_bpe1000.model']:
        (fixtures / name).write_bytes((args.model_dir / name).read_bytes())
    tokenizer = spm.SentencePieceProcessor(model_file=str(args.model_dir / 'train_bpe1000.model'))
    vocab = {line.split()[0]: i for i, line in enumerate((args.model_dir / 'dict.txt').read_text().splitlines())}
    rows = []
    for word in ['Cloudflare', 'Kubernetes', 'PostgreSQL', 'API', 'APIS', "VOICER'S API", 'GPU 123', 'ＦｉｒｅＲｅｄ', 'API   SERVER']:
        pieces = tokenizer.encode(word.upper(), out_type=str)
        rows.append({'word': word, 'pieces': pieces, 'encodable': all(vocab.get(t, 1) >= 5 for t in pieces)})
    (fixtures / 'sentencepiece-parity.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
    audio = np.array([np.sin(i * .071) * .1 + np.cos(i * .019) * .02 for i in range(1600)], dtype=np.float32)
    features = compute_fbank_kaldi(mx.array(audio) * 32768, sample_rate=16000, win_len=400, win_inc=160, num_mels=80, dither=0)
    mx.eval(features)
    (fixtures / 'fbank-python.json').write_text(json.dumps({'audio': audio.tolist(), 'shape': list(features.shape),
        'features': np.array(features).ravel().tolist()}, separators=(',', ':')) + '\n')
    texts = []
    for name in ['firered.jsonl', 'firered-hotwords-once-4.jsonl']:
        for line in (ROOT / 'ASR/results' / name).read_text().splitlines():
            text = json.loads(line)['text']
            if text not in texts: texts.append(text)
    lexicon = load_lexicon(ROOT / 'ASR/data/lexicon.json')
    rows = [{'input': text, 'expected': choose_conservative(candidates(text, lexicon)).text} for text in texts]
    (fixtures / 'correction-python.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
    print('Exported Swift pinyin tables, SentencePiece, fbank and correction fixtures')


if __name__ == '__main__':
    main()
