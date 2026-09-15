"""Fetch the qingjian research model and a pinned Silero VAD model."""
import hashlib
import json
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def download(url: str, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            path.write_bytes(response.read())
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    base = "https://github.com/qingjian-team/qingjian/releases/download/data/"
    qjm = ROOT / ".cache/models/qingjian/model.qjm"
    qj_manifest = ROOT / "data/qingjian-model.json"
    digest = download(base+"model.qjm", qjm)
    if qj_manifest.exists():
        expected = json.loads(qj_manifest.read_text())["sha256"]
    else:
        lines = urllib.request.urlopen(base+"SHA256SUMS", timeout=30).read().decode().splitlines()
        checks = {Path(line.split()[-1]).name:line.split()[0] for line in lines}
        expected = checks["model.qjm"]
    if digest != expected:
        raise ValueError("qingjian model checksum mismatch; release data is mutable, keep the pinned artifact")
    qj_manifest.write_text(json.dumps({"url":base+"model.qjm","sha256":digest,
        "size_bytes":qjm.stat().st_size,"license":"GPL-3.0-or-later",
        "source_revision":"30bf66ce49080df571273bf944d75f87a4195271"},indent=2)+"\n")
    manifest_path = ROOT / "data/vad-model.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text())
    else:
        info = json.load(urllib.request.urlopen("https://api.github.com/repos/snakers4/silero-vad/commits/master",timeout=30))
        revision = info["sha"]
        manifest = {"repo":"snakers4/silero-vad","revision":revision,"license":"MIT",
                    "url":f"https://raw.githubusercontent.com/snakers4/silero-vad/{revision}/src/silero_vad/data/silero_vad.onnx"}
    sha = download(manifest["url"],ROOT / ".cache/models/silero_vad.onnx")
    if manifest.get("sha256",sha) != sha:
        raise ValueError("Silero model checksum mismatch")
    manifest["sha256"] = sha
    manifest_path.write_text(json.dumps(manifest,indent=2)+"\n")
    print("Verified qingjian and Silero model checksums", flush=True)


if __name__ == "__main__":
    main()
