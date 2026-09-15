"""Compare language hints on the existing four mixed-language synthetic clips.

This leaves the main pipeline and the previous experiment's evidence unchanged.
"""
import argparse
import hashlib
import importlib.metadata
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import mlx.core as mx

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from asr_lab.backends import Backend, read_audio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=["qwen", "fun"], required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or ROOT / f"results/mixed-language-{args.model}.jsonl"
    if output.exists():
        raise FileExistsError(output)
    clips = [r for r in json.loads((ROOT / "data/audio-manifest.json").read_text())
             if r["category"] == "mixed"]
    hotwords = [r["text"] for r in json.loads((ROOT / "data/lexicon.json").read_text())]
    model = Backend(args.model).model

    def transcribe(audio, language_mode, use_hotwords):
        if args.model == "qwen":
            return model.transcribe(
                audio, language=None if language_mode == "auto" else "Chinese",
                temperature=0.0, max_tokens=128, repetition_penalty=1.2,
                context="Vocabulary: " + ", ".join(hotwords) + "." if use_hotwords else None,
            )
        return model.generate(
            audio, language=None if language_mode == "auto" else "zh",
            temperature=0.0, max_tokens=128, itn=False,
            hotwords=hotwords if use_hotwords else None,
        )

    configurations = [(language, use_hotwords) for language in ["chinese", "auto"]
                      for use_hotwords in [False, True]]
    first_audio = read_audio(ROOT / clips[0]["path"])
    for language, use_hotwords in configurations:
        transcribe(first_audio, language, use_hotwords)
    mx.synchronize()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w") as stream:
        for index, clip in enumerate(clips):
            audio = read_audio(ROOT / clip["path"])
            for language, use_hotwords in configurations[::1 if index % 2 == 0 else -1]:
                mx.synchronize()
                started = time.perf_counter()
                result = transcribe(audio, language, use_hotwords)
                mx.synchronize()
                row = {**clip, "model":args.model, "language_mode":language,
                       "hotwords_enabled":use_hotwords, "text":result.text,
                       "returned_language":getattr(result, "language", None),
                       "elapsed_s":time.perf_counter()-started}
                stream.write(json.dumps(row, ensure_ascii=False)+"\n")
                stream.flush()
                print(f"{args.model} {clip['id']} {language} hotwords={use_hotwords}: {result.text}", flush=True)
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    metadata = {
        "date":datetime.now(timezone.utc).isoformat(),
        "snapshot":json.loads((ROOT/"data/model-manifest.json").read_text())[args.model],
        "packages":{p:importlib.metadata.version(p) for p in ["mlx", "qwen3-asr-mlx", "mlx-audio"]},
        "script_sha256":sha(Path(__file__)),
        "audio_manifest_sha256":sha(ROOT/"data/audio-manifest.json"),
        "lexicon_sha256":sha(ROOT/"data/lexicon.json"),
        "hotwords":hotwords, "warmup_calls":4,
        "decode":{"temperature":0.0, "max_tokens":128, "qwen_repetition_penalty":1.2, "fun_itn":False},
        "scope":"four synthetic clips from two sentence templates; no post-correction; no real-speaker conclusions",
        "timing":"warm feature extraction and decoding only; excludes recording, file read, VAD, model load and text insertion",
    }
    output.with_suffix(".meta.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n")


if __name__ == "__main__":
    main()
