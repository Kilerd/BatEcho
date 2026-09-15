"""Exercise the packaged Swift downloader with existing FireRed and fresh VAD.

This development script needs only the Python standard library. voicer itself
runs with a restricted PATH and performs all preparation through URLSession.
"""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, default=ROOT / 'ASR/results/swift-setup.json')
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Choose a new evidence output')
    original = Path.home() / 'Library/Application Support/voicer/asr'
    binary = ROOT / 'build/voicer.app/Contents/MacOS/voicer'
    with tempfile.TemporaryDirectory(prefix='voicer-native-setup-') as name:
        directory = Path(name)
        (directory / 'models').mkdir()
        # Reuse read-only model assets, but force the Swift downloader to fetch VAD.
        (directory / 'models/firered').symlink_to(original / 'models/firered', target_is_directory=True)
        vocabulary = b'[ {"text":"CUSTOM", "pinyin":[], "contexts":[]} ]\n'
        (directory / 'lexicon.json').write_bytes(vocabulary)
        environment = {**os.environ, 'VOICER_ASR_RUNTIME': str(directory), 'PATH': '/usr/bin:/bin'}
        checks = []
        for iteration in range(2):
            result = subprocess.run([str(binary), '--prepare-model'], env=environment, cwd=directory,
                                    text=True, capture_output=True, check=True, timeout=300)
            assert (directory / 'lexicon.json').read_bytes() == vocabulary
            manifest = json.loads((directory / 'native-runtime.json').read_text())
            assert manifest['engine'] == 'swift-mlx'
            checks.append({'iteration': iteration + 1, 'log': result.stderr,
                           'vocabulary_preserved': True,
                           'vad_downloaded': 'Downloading silero-v6/model.safetensors' in result.stderr})
        assert checks[0]['vad_downloaded'] and not checks[1]['vad_downloaded']
        output = {'date': datetime.now(timezone.utc).isoformat(), 'checks': checks,
                  'manifest': manifest, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}
    args.output.write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    print('Swift model download, SHA256 checks, repeat setup and personal vocabulary preservation passed')


if __name__ == '__main__':
    main()
