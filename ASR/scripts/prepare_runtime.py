"""Prepare the app's Python environment and pinned models outside the app bundle."""
import argparse
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1]


def download_models(runtime: Path):
    from huggingface_hub import snapshot_download

    manifest = json.loads((SOURCE / "data/model-manifest.json").read_text())["firered"]
    print("Preparing FireRedASR2-AED (about 4.6 GB)…", flush=True)
    snapshot_download(repo_id=manifest["repo"], revision=manifest["revision"],
                      local_dir=runtime / "models/firered",
                      allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model"])
    vad = json.loads((SOURCE / "data/vad-model.json").read_text())
    destination = runtime / "models/silero_vad.onnx"
    if not destination.exists():
        temporary = destination.with_suffix(".download")
        with urllib.request.urlopen(vad["url"], timeout=60) as response:
            temporary.write_bytes(response.read())
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != vad["sha256"]:
            temporary.unlink()
            raise ValueError("Downloaded speech detector checksum does not match")
        temporary.replace(destination)
    if hashlib.sha256(destination.read_bytes()).hexdigest() != vad["sha256"]:
        raise ValueError("Speech detector checksum does not match")
    print("Local speech models are ready.", flush=True)


def prepare(runtime: Path, reuse_models: Path | None):
    runtime.mkdir(parents=True, exist_ok=True)
    with (runtime / ".setup.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError("Local speech setup is already running") from None
        uv = shutil.which("uv")
        if not uv:
            raise RuntimeError("Install uv before preparing the local speech model")
        environment = runtime / "environment"
        environment.mkdir(exist_ok=True)
        for name in ("pyproject.toml", "uv.lock"):
            shutil.copy2(SOURCE / name, environment / name)
        env = {**os.environ, "UV_PROJECT_ENVIRONMENT": str(runtime / ".venv")}
        print("Preparing the local speech environment…", flush=True)
        subprocess.run([uv, "sync", "--locked", "--python", "3.12", "--project", str(environment)],
                       env=env, check=True, stdin=subprocess.DEVNULL)
        model_dir = runtime / "models"
        model_dir.mkdir(exist_ok=True)
        if reuse_models:
            if not (model_dir / "firered").exists():
                shutil.copytree(reuse_models / "firered", model_dir / "firered")
            if not (model_dir / "silero_vad.onnx").exists():
                shutil.copy2(reuse_models / "silero_vad.onnx", model_dir / "silero_vad.onnx")
        subprocess.run([str(runtime / ".venv/bin/python"), str(Path(__file__).resolve()),
                        "--runtime", str(runtime), "--download-only"], check=True,
                       stdin=subprocess.DEVNULL)
        lexicon = runtime / "lexicon.json"
        if not lexicon.exists():
            shutil.copy2(SOURCE / "data/lexicon.json", lexicon)
        metadata = {"schema": 1,
                    "environment_sha256": hashlib.sha256((SOURCE / "uv.lock").read_bytes()).hexdigest(),
                    "firered": json.loads((SOURCE / "data/model-manifest.json").read_text())["firered"]}
        (runtime / "runtime.json").write_text(json.dumps(metadata, indent=2) + "\n")
        print("Setup complete. FireRed is ready in voicer.", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=Path,
                        default=Path.home() / "Library/Application Support/voicer/asr")
    parser.add_argument("--reuse-models", type=Path)
    parser.add_argument("--download-only", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    runtime = args.runtime.expanduser().resolve()
    if args.download_only:
        download_models(runtime)
    else:
        prepare(runtime, args.reuse_models)


if __name__ == "__main__":
    main()
