"""Development-only comparison of the native binary against frozen Python outputs.

No Python code is used inside BatEcho. Inputs are the existing synthetic/public
research clips; this is migration parity evidence, not a human accuracy benchmark.
"""
import argparse
import hashlib
import json
import os
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, default=ROOT / 'build/BatEcho.app')
    parser.add_argument('--output', type=Path, default=ROOT / 'ASR/results/swift-parity.json')
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError('Choose a new output path to preserve evidence')
    binary = args.app.resolve() / 'Contents/MacOS/BatEcho'
    binary_hash = hashlib.sha256(binary.read_bytes()).hexdigest()
    source_hash = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in sorted((ROOT / 'Sources/BatEcho').rglob('*')) if p.is_file()}
    environment = {**os.environ, 'PATH': '/usr/bin:/bin'}
    groups = []
    for name, source, flags in [
        ('baseline', 'firered.jsonl', []),
        ('hotwords-4', 'firered-hotwords-once-4.jsonl', ['--hotwords']),
    ]:
        reference = [json.loads(line) for line in (ROOT / 'ASR/results' / source).read_text().splitlines()]
        command = [str(binary), '--no-correction', *flags]
        for row in reference:
            path = ROOT / 'ASR' / row['path']
            assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256']
            command += ['--transcribe-file', str(path)]
        completed = subprocess.run(command, cwd='/tmp', env=environment, capture_output=True,
                                   text=True, timeout=600, check=True)
        native = [json.loads(line) for line in completed.stdout.splitlines()]
        assert len(native) == len(reference)
        rows = []
        for expected, actual in zip(reference, native):
            assert actual['engine'] == 'swift-mlx' and actual['model_load_count'] == 1
            rows.append({'id': expected['id'], 'reference': expected['text'], 'native': actual,
                         'equal': expected['text'] == actual['raw_text']})
        warm = [r['elapsed_s'] for r in native[1:] if r['vad']['has_speech']]
        ordered = sorted(warm)
        group = {'name': name, 'total': len(rows), 'equal': sum(r['equal'] for r in rows),
                 'warm_pipeline_p50_s': statistics.median(warm),
                 'warm_pipeline_p95_s': ordered[round(.95 * (len(ordered) - 1))], 'cases': rows}
        groups.append(group)
        print(name, group['equal'], '/', group['total'], 'p50', group['warm_pipeline_p50_s'], flush=True)
        for row in rows:
            if not row['equal']: print('DIFFERENCE:', row['id'], row['reference'], '->', row['native']['text'], flush=True)
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == binary_hash, 'Binary changed during validation'
    result = {'date': datetime.now(timezone.utc).isoformat(),
              'scope': 'Native Swift raw transcription vs frozen Python FP32 reference; TTS/public clips only',
              'timing_scope': 'Native whole pipeline including VAD/audio read; not directly comparable to historical ASR-only timing',
              'binary_sha256': binary_hash,
              'source_sha256': source_hash,
              'groups': groups}
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    if any(g['equal'] != g['total'] for g in groups):
        raise SystemExit('Text differences require review; see recorded results')


if __name__ == '__main__':
    main()
