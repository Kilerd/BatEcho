"""Create a fixed synthetic smoke set; this is not a real-speaker benchmark."""
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]


def main():
    out = ROOT / "data/audio"
    out.mkdir(parents=True, exist_ok=True)
    sentences = json.loads((ROOT / "data/sentences.json").read_text())
    manifest = []
    for voice in ["Tingting", "Eddy (Chinese (China mainland))"]:
        voice_id = "tingting" if voice == "Tingting" else "eddy"
        for sentence in sentences:
            name = f"{voice_id}-{sentence['id']}"
            path = out / f"{name}.wav"
            if not path.exists():
                aiff = out / f"{name}.aiff"
                subprocess.run(["say", "-v", voice, "-r", "175", "-o", str(aiff), sentence["text"]], check=True)
                subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(aiff), "-ar", "16000", "-ac", "1", str(path)], check=True)
                aiff.unlink()
            info = sf.info(path)
            manifest.append({**sentence, "id": name, "source": "macOS say synthetic", "voice": voice,
                             "path": str(path.relative_to(ROOT)), "reference": sentence["text"],
                             "duration_s": info.duration, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
            print(f"Prepared {name}: {info.duration:.2f}s", flush=True)
    silence = out / "silence.wav"
    sf.write(silence, np.zeros(48000, dtype=np.float32), 16000, subtype="PCM_16")
    manifest.append({"id":"silence", "source":"generated silence", "category":"silence", "terms":[],
                     "path":str(silence.relative_to(ROOT)), "reference":"", "duration_s":3.0,
                     "sha256":hashlib.sha256(silence.read_bytes()).hexdigest()})
    # Public audio paired with this text in the official Qwen3 forced-aligner example.
    url = "https://qianwen-res.oss-cn-beijing.aliyuncs.com/Qwen3-ASR-Repo/asr_zh.wav"
    sample = out / "qwen-official-zh.wav"
    if not sample.exists():
        with urllib.request.urlopen(url, timeout=30) as response:
            sample.write_bytes(response.read())
    manifest.append({"id":"qwen-official-zh", "source":url, "category":"public", "terms":[],
                     "reference":"甚至出现交易几乎停滞的情况。", "path":str(sample.relative_to(ROOT)),
                     "reference_source":"https://github.com/QwenLM/Qwen3-ASR#forcedaligner-usage",
                     "duration_s":sf.info(sample).duration, "sha256":hashlib.sha256(sample.read_bytes()).hexdigest()})
    (ROOT / "data/audio-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(f"Ready: {len(manifest)} clips", flush=True)


if __name__ == "__main__":
    main()
