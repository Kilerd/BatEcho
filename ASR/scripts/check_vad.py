"""Check the speech gate against the fixed corpus and synthetic non-speech."""
import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
from asr_lab.backends import read_audio
from asr_lab.vad import SpeechGate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output",type=Path,default=ROOT/"results/vad-checks.json")
    args = parser.parse_args()
    out = args.output
    if out.exists():
        raise FileExistsError(out)
    gate = SpeechGate()
    manifest = json.loads((ROOT / "data/audio-manifest.json").read_text())
    checks = [(r["id"],read_audio(ROOT/r["path"]),r["category"]!="silence") for r in manifest]
    checks.append(("seeded-white-noise",np.random.default_rng(42).normal(0,0.02,48000).astype(np.float32),False))
    results=[]
    for name,audio,expected in checks:
        started=time.perf_counter()
        result=gate.check(audio)
        row={"id":name,**result,"expected_speech":expected,"elapsed_s":time.perf_counter()-started}
        results.append(row)
        print(f"{name}: speech={result['has_speech']}, expected={expected}, peak={result['max_probability']:.3f}")
    out.parent.mkdir(parents=True,exist_ok=True)
    out.write_text(json.dumps(results,ensure_ascii=False,indent=2)+"\n")
    assert not any(r["has_speech"] for r in results if not r["expected_speech"]),"Non-speech triggered ASR"
    assert all(r["has_speech"] for r in results if r["expected_speech"]),"Speech was rejected"


if __name__ == "__main__":
    main()
