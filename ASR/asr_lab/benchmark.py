"""Run one backend per process so memory/timing are not shared across models."""
import argparse
import hashlib
import importlib.metadata
import json
import platform
import time
from datetime import datetime, timezone
from pathlib import Path

import mlx.core as mx

from .backends import Backend, MODEL_NAMES, ROOT, read_audio


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", choices=MODEL_NAMES, required=True)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--mode",choices=["both","baseline","hotwords"],default="both")
    parser.add_argument("--hotword-score",type=float,default=4.0)
    args = parser.parse_args()
    manifest = json.loads((ROOT / "data/audio-manifest.json").read_text())
    if args.limit:
        manifest = manifest[:args.limit]
    words = [entry["text"] for entry in json.loads((ROOT / "data/lexicon.json").read_text())]
    output = args.output or ROOT / "results" / f"{args.model}.jsonl"
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite evidence: {output}. Choose --output.")
    started = time.perf_counter()
    backend = Backend(args.model,hotword_score=args.hotword_score)
    mx.synchronize()
    load_s = time.perf_counter() - started
    warm_audio = read_audio(ROOT / manifest[0]["path"])
    warm_start = time.perf_counter()
    backend.transcribe(warm_audio)
    backend.transcribe(warm_audio, words if backend.supports_hotwords else None)
    mx.synchronize()
    warmup_s = time.perf_counter() - warm_start
    metadata = {
        "date":datetime.now(timezone.utc).isoformat(), "model":args.model,
        "snapshot":json.loads((ROOT / "data/model-manifest.json").read_text())[args.model],
        "load_s":load_s, "warmup_s":warmup_s, "warmup_calls":2,
        "platform":platform.platform(), "python":platform.python_version(),
        "packages":{p:importlib.metadata.version(p) for p in ["mlx", "mlx-audio", "qwen3-asr-mlx", "pypinyin"]},
        "lexicon_sha256":hashlib.sha256((ROOT / "data/lexicon.json").read_bytes()).hexdigest(),
        "audio_manifest_sha256":hashlib.sha256((ROOT / "data/audio-manifest.json").read_bytes()).hexdigest(),
        "hotwords":words if backend.supports_hotwords else [],
        "native_hotwords_supported":backend.supports_hotwords,
        "hotword_method":"contextual_beam_search" if args.model=="firered" else "prompt",
        "hotword_score":backend.hotword_score if args.model=="firered" else None,
        "timing":"warm model; includes feature extraction and decoding; excludes audio file read, recording and endpoint detection",
        "decode":backend.decode_options,
        "code_sha256":{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
                       for name in ["asr_lab/backends.py","asr_lab/benchmark.py","asr_lab/firered.py",
                                    "asr_lab/hotwords.py","asr_lab/firered_bias.py"]},
    }
    output.with_suffix(".meta.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
    print(f"Loaded {args.model}: {load_s:.2f}s; warmup {warmup_s:.2f}s", flush=True)
    with output.open("w") as stream:
        for index, clip in enumerate(manifest):
            audio = read_audio(ROOT / clip["path"])
            # Alternate order to reduce systematic first/second-call bias.
            modes = ["baseline", "hotwords"] if index % 2 == 0 else ["hotwords", "baseline"]
            if not backend.supports_hotwords:
                modes = ["baseline"]
            if args.mode != "both":
                modes = [mode for mode in modes if mode == args.mode]
            for mode in modes:
                mx.synchronize()
                start = time.perf_counter()
                recognized = backend.recognize(audio, words if mode == "hotwords" else None)
                text = recognized.text
                mx.synchronize()
                elapsed = time.perf_counter() - start
                row = {**clip,"model":args.model,"mode":mode,"text":text,"elapsed_s":elapsed,
                       "rtf":elapsed / clip["duration_s"], "mlx_peak_bytes":mx.get_peak_memory()}
                if recognized.confidence is not None:
                    row["asr_confidence"] = recognized.confidence
                    row["asr_confidence_scope"] = "utterance"
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
                stream.flush()
                print(f"{index+1}/{len(manifest)} {mode} {clip['id']} {elapsed:.3f}s: {text}", flush=True)


if __name__ == "__main__":
    main()
