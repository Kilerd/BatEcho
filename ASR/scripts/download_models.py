"""Download pinned snapshots without installing global packages."""
import argparse
import json
from pathlib import Path

from huggingface_hub import HfApi, snapshot_download

ROOT = Path(__file__).resolve().parents[1]
MODELS = {
    "firered": "mlx-community/FireRedASR2-AED-mlx",
    "qwen": "mlx-community/Qwen3-ASR-0.6B-bf16",
    "fun": "mlx-community/Fun-ASR-Nano-2512",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model",choices=[*MODELS,"all"],default="firered")
    args = parser.parse_args()
    selected = MODELS if args.model == "all" else {args.model:MODELS[args.model]}
    manifest_path = ROOT / "data/model-manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    for name, repo in selected.items():
        if name in manifest and manifest[name]["repo"] != repo:
            raise ValueError(f"Model manifest disagrees with {repo}; preserve old snapshot before changing it")
        revision = manifest.get(name, {}).get("revision") or HfApi().model_info(repo).sha
        manifest[name] = {"repo": repo, "revision": revision}
        manifest_path.parent.mkdir(parents=True,exist_ok=True)
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        print(f"Downloading {name}: {repo}@{revision}", flush=True)
        snapshot_download(
            repo_id=repo,
            revision=revision,
            local_dir=ROOT / ".cache/models" / name,
            allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model", "README.md"],
        )
        print(f"Ready: {name}", flush=True)


if __name__ == "__main__":
    main()
