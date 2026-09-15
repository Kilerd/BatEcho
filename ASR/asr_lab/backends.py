from dataclasses import dataclass
import math
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[1]
MODEL_NAMES = ("firered", "qwen", "fun")
DEFAULT_MODEL = "firered"


def supports_hotwords(name: str) -> bool:
    if name not in MODEL_NAMES:
        raise ValueError(f"Unknown backend: {name}")
    return True


def resolve_hotwords(name: str, requested: bool | None) -> bool:
    supports_hotwords(name)
    # FireRed contextual decoding is experimental and remains opt-in.
    return name in {"qwen", "fun"} if requested is None else requested


@dataclass(frozen=True)
class Recognition:
    text: str
    # FireRed MLX returns a mean token score for the whole utterance.
    # This is not a calibrated probability that the transcript is correct.
    confidence: float | None = None
    truncated: bool = False


class Backend:
    def __init__(self, name: str = DEFAULT_MODEL, *, hotword_score: float = 4.0,
                 model_dir: Path | None = None, max_tokens: int = 128):
        supports_hotwords(name)  # Validate the name before reading model files.
        if not math.isfinite(hotword_score) or hotword_score < 0:
            raise ValueError("Hotword score must be finite and nonnegative")
        self.name = name
        self.hotword_score = hotword_score
        if type(max_tokens) is not int or not 1 <= max_tokens <= 2048:
            raise ValueError("Maximum output tokens must be between 1 and 2048")
        self.max_tokens = max_tokens
        self._hotword_graphs = {}
        path = (model_dir or ROOT / ".cache/models") / name
        if not path.exists():
            raise FileNotFoundError("Run scripts/download_models.py first")
        if name == "qwen":
            from qwen3_asr_mlx import Qwen3ASR
            self.model = Qwen3ASR.from_pretrained(str(path))
        elif name in {"firered", "fun"}:
            if name == "firered":
                for asset in ["config.json", "model.safetensors", "cmvn.json", "dict.txt", "train_bpe1000.model"]:
                    if not (path / asset).is_file():
                        raise FileNotFoundError(f"Missing FireRed asset {asset}; run scripts/download_models.py --model firered")
                from .firered import load_firered
                self.model = load_firered(path)
            else:
                from mlx_audio.stt.utils import load
                self.model = load(str(path), strict=True)

    @property
    def supports_hotwords(self) -> bool:
        return supports_hotwords(self.name)

    @property
    def decode_options(self) -> dict:
        if self.name == "firered":
            return {"beam_size":3, "max_len":self.max_tokens, "softmax_smoothing":1.25,
                    "length_penalty":0.6, "eos_penalty":1.0}
        if self.name == "qwen":
            return {"language":"Chinese", "temperature":0.0, "max_tokens":128, "repetition_penalty":1.2}
        return {"language":"zh", "temperature":0.0, "max_tokens":128, "itn":False}

    def transcribe(self, audio: np.ndarray, hotwords: list[str] | None = None) -> str:
        return self.recognize(audio,hotwords).text

    def recognize(self, audio: np.ndarray, hotwords: list[str] | None = None) -> Recognition:
        if self.name == "firered":
            import mlx.core as mx
            audio = mx.array(audio,dtype=mx.float32)
            if hotwords:
                from .firered_bias import generate_with_hotwords
                from .hotwords import ContextGraph, tokenize_hotwords
                key = (tuple(hotwords),self.hotword_score)
                if key not in self._hotword_graphs:
                    phrases = tokenize_hotwords(self.model,hotwords)
                    graph = ContextGraph(phrases,self.model._tokenizer,self.model.config.eos_id,self.hotword_score)
                    # Keep only the current vocabulary's graph to bound retained memory.
                    self._hotword_graphs = {key:graph}
                result = generate_with_hotwords(self.model,audio,self._hotword_graphs[key],self.decode_options)
            else:
                result = self.model.generate(audio,**self.decode_options)
            confidence = result.segments[0].get("confidence") if result.segments else None
            return Recognition(result.text,confidence,result.generation_tokens >= self.max_tokens)
        elif self.name == "qwen":
            result = self.model.transcribe(
                audio, **self.decode_options,
                context=("Vocabulary: " + ", ".join(hotwords) + ".") if hotwords else None,
            )
        else:
            result = self.model.generate(
                audio, **self.decode_options, hotwords=hotwords,
            )
        return Recognition(result.text)


def read_audio(path: Path) -> np.ndarray:
    data, rate = sf.read(path, dtype="float32", always_2d=True)
    mono = data.mean(axis=1)
    if rate != 16000:
        from scipy.signal import resample_poly
        from math import gcd
        divisor = gcd(rate, 16000)
        mono = resample_poly(mono, 16000 // divisor, rate // divisor)
    return np.asarray(mono, dtype=np.float32)
