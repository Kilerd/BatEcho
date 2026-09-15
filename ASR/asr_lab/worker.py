"""Persistent, private JSON-lines worker used by the native voicer app.

stdin/stdout are the entire transport; there is no listening network socket.
Audio belongs to the caller, which deletes its temporary file after completion.
"""
import argparse
import contextlib
import json
import math
import sys
import time
from pathlib import Path

import soundfile as sf

from .backends import Backend, read_audio
from .correction import candidates, choose_conservative
from .vad import SpeechGate

MAX_AUDIO_SECONDS = 30


class Pipeline:
    def __init__(self, model_dir: Path, lexicon: Path, *, backend_factory=Backend,
                 gate_factory=SpeechGate):
        self.model_dir = model_dir
        self.lexicon = lexicon
        self.backend_factory = backend_factory
        self.gate_factory = gate_factory
        self.backend = None
        self.gate = None
        self.model_load_count = 0

    def load_model(self):
        if self.backend is None:
            # More room than the original 2–5 second research clips. Audio is
            # still bounded to 30 seconds; there is no silent input truncation.
            self.backend = self.backend_factory("firered", model_dir=self.model_dir, max_tokens=512)
            self.model_load_count += 1
        return self.backend

    def load_gate(self):
        if self.gate is None:
            self.gate = self.gate_factory(model_dir=self.model_dir)
        return self.gate

    def vocabulary(self):
        if self.lexicon.stat().st_size > 1024 * 1024:
            raise ValueError("Vocabulary must be smaller than 1 MB")
        entries = json.loads(self.lexicon.read_text())
        if not isinstance(entries, list) or len(entries) > 4096:
            raise ValueError("Vocabulary must contain at most 4096 entries")
        for entry in entries:
            if (not isinstance(entry, dict)
                    or not isinstance(entry.get("text"), str) or not entry["text"].strip()
                    or not isinstance(entry.get("pinyin"), list)
                    or not all(isinstance(s, str) for s in entry["pinyin"])
                    or not isinstance(entry.get("contexts", []), list)
                    or not all(isinstance(s, str) and s for s in entry.get("contexts", []))):
                raise ValueError("Each vocabulary entry needs text, a pinyin array and optional context strings")
            if entry["pinyin"] and len(entry["pinyin"]) != len(entry["text"]):
                raise ValueError(f"Pinyin must match character count: {entry['text']}")
        return entries

    def handle(self, request: dict) -> dict:
        operation = request.get("type")
        if operation == "warmup":
            self.load_gate()
            self.load_model()
            return {"ready": True, "model": "firered", "model_load_count": self.model_load_count}
        if operation != "transcribe":
            raise ValueError("Unknown worker operation")
        hotwords = request.get("hotwords", False)
        score = request.get("hotword_score", 4.0)
        correction = request.get("correction", "context")
        if type(hotwords) is not bool:
            raise ValueError("hotwords must be a boolean")
        if type(score) not in (int, float) or not math.isfinite(score) or not 0 <= score <= 8:
            raise ValueError("Hotword strength must be between 0 and 8")
        if correction not in ("none", "context"):
            raise ValueError("Unknown correction mode")
        path = request.get("audio")
        if not isinstance(path, str) or not path:
            raise ValueError("An audio file is required")
        audio_path = Path(path)
        info = sf.info(audio_path)
        if info.duration > MAX_AUDIO_SECONDS + 0.001:
            raise ValueError("Please dictate no more than 30 seconds at a time")
        if not 1 <= info.channels <= 8 or not 8000 <= info.samplerate <= 192000:
            raise ValueError("Unsupported audio format")
        started = time.perf_counter()
        audio = read_audio(audio_path)
        gate = self.load_gate().check(audio)
        result = {"model": "firered", "raw_text": "", "text": "", "vad": gate,
                  "duration_s": len(audio) / 16000, "hotwords_enabled": hotwords,
                  "hotword_score": score, "correction": correction}
        if gate["has_speech"]:
            # Read on every request so editing the user's vocabulary needs no restart.
            lexicon = self.vocabulary()
            backend = self.load_model()
            backend.hotword_score = score
            recognized = backend.recognize(audio, [e["text"] for e in lexicon] if hotwords else None)
            if recognized.truncated:
                raise ValueError("Recognition reached its output limit. Please dictate a shorter phrase")
            raw = recognized.text
            choice = choose_conservative(candidates(raw, lexicon)) if correction == "context" else None
            result.update({"raw_text": raw, "text": choice.text if choice else raw,
                           "asr_confidence": recognized.confidence,
                           "asr_confidence_scope": "utterance"})
        result["model_load_count"] = self.model_load_count
        result["elapsed_s"] = time.perf_counter() - started
        return result


def serve(pipeline, incoming, outgoing):
    for line in incoming:
        request_id = None
        try:
            if len(line) > 16384:
                raise ValueError("Worker request is too large")
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("Worker request must be an object")
            request_id = request.get("id")
            if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128:
                raise ValueError("Worker request needs an id")
            # Third-party Python diagnostics must never enter the wire protocol.
            with contextlib.redirect_stdout(sys.stderr):
                result = pipeline.handle(request)
            response = {"id": request_id, **result}
        except Exception as error:
            response = {"id": request_id,
                        "error": {"code": type(error).__name__, "message": str(error)}}
        outgoing.write(json.dumps(response, ensure_ascii=False, allow_nan=False) + "\n")
        outgoing.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--lexicon", type=Path, required=True)
    args = parser.parse_args()
    serve(Pipeline(args.model_dir, args.lexicon), sys.stdin, sys.stdout)


if __name__ == "__main__":
    main()
