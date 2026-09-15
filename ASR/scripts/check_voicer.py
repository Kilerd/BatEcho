"""Check the packaged native Swift -> MLX path using the fixed research audio."""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, default=ROOT / "build/voicer.app")
    parser.add_argument("--audio-dir", type=Path, default=ROOT / "ASR/data/audio")
    parser.add_argument("--output", type=Path, default=ROOT / "ASR/results/voicer-swift-integration.json")
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Choose another --output to preserve the existing evidence")
    subprocess.run(["codesign", "--verify", "--strict", str(args.app)], check=True)
    with tempfile.TemporaryDirectory(prefix="voicer-check-") as temporary:
        temporary = Path(temporary)
        # A copied app, with cwd outside the checkout, exercises resource packaging.
        app = temporary / "voicer.app"
        shutil.copytree(args.app, app)
        executable = app / "Contents/MacOS/voicer"
        binary_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
        audio_dir = args.audio_dir.resolve()
        native = temporary / "native-stereo-48k.caf"
        waveform, rate = sf.read(audio_dir / "tingting-term03.wav", dtype="float32")
        assert rate == 16000
        waveform = resample_poly(waveform, 3, 1)
        sf.write(native, np.stack([waveform, waveform], axis=1), 48000, format="CAF", subtype="FLOAT")
        cases = [
            ("default", [], [
                (audio_dir / "tingting-term03.wav", "这个项目由同事璟珩负责"),
                (audio_dir / "qwen-official-zh.wav", "甚至出现交易几乎停滞的情况"),
                (audio_dir / "silence.wav", ""),
            ]),
            ("hotwords-without-correction", ["--hotwords", "--no-correction"], [
                (audio_dir / "tingting-term01.wav", "我想把青简接入这个语音输入法"),
                (audio_dir / "tingting-mixed02.wav", "这个服务使用 kubernetes和 postgresql"),
                (audio_dir / "silence.wav", ""),
            ]),
            ("native-caf", [], [(native, "这个项目由同事璟珩负责")]),
        ]
        results = []
        environment = {key: value for key, value in os.environ.items() if key != "VOICER_ASR_SOURCE"}
        environment["PATH"] = "/usr/bin:/bin"
        assert not any(path.suffix in {".py", ".pyc", ".onnx"} for path in app.rglob("*"))
        for name, options, files in cases:
            command = [str(executable), *options]
            for path, _ in files:
                command += ["--transcribe-file", str(path)]
            completed = subprocess.run(command, cwd=temporary, env=environment,
                                       capture_output=True, text=True, check=True, timeout=180)
            rows = [json.loads(line) for line in completed.stdout.splitlines()]
            assert len(rows) == len(files)
            for row, (path, expected) in zip(rows, files):
                assert row["text"] == expected, (name, path.name, row)
                assert row["model"] == "firered" and row["model_load_count"] == 1
                assert row["engine"] == "swift-mlx", "Must exercise the native engine"
                if "--no-correction" in options:
                    assert row["text"] == row["raw_text"]
                results.append({"case": name, "audio": path.name, "expected": expected,
                                "audio_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                                "result": row, "passed": True})
            print(f"{name}: {len(rows)} passed; model loaded once", flush=True)
        output = {
            "date": datetime.now(timezone.utc).isoformat(),
            "scope": "Packaged native client, copied outside checkout, real FireRed model; no physical microphone or focused-app injection",
            "cases": results,
            "swift_version": subprocess.check_output(["swift", "--version"], text=True).strip(),
            "binary_sha256": binary_hash,
            "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in sorted((ROOT / "Sources/voicer").rglob("*")) if path.is_file()},
        }
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
