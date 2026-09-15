"""Whole-clip speech gate using Silero's documented stateful ONNX interface.

The gate preserves the full waveform, so it does not cut speech boundaries.
This is not an implementation of live endpoint detection.
"""
import math
from pathlib import Path

import numpy as np
import onnxruntime as ort

from .backends import ROOT


class SpeechGate:
    def __init__(self, threshold: float = 0.5, min_speech_ms: int = 160,
                 model_dir: Path | None = None):
        options = ort.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        self.session = ort.InferenceSession(str((model_dir or ROOT / ".cache/models") / "silero_vad.onnx"),
                                           sess_options=options, providers=["CPUExecutionProvider"])
        self.threshold = threshold
        self.min_frames = math.ceil(min_speech_ms / 32)

    def check(self, audio: np.ndarray) -> dict:
        if audio.ndim != 1 or not np.isfinite(audio).all():
            raise ValueError("Expected finite mono samples at 16000 Hz")
        state = np.zeros((2,1,128),dtype=np.float32)
        context = np.zeros((1,64),dtype=np.float32)
        peak = 0.0
        run = 0
        longest_run = 0
        for offset in range(0,len(audio),512):
            chunk = audio[offset:offset+512]
            if len(chunk)<512:
                chunk = np.pad(chunk,(0,512-len(chunk)))
            x = np.concatenate([context,np.asarray(chunk,dtype=np.float32)[None]],axis=1)
            output,state = self.session.run(None,{"input":x,"state":state,"sr":np.asarray(16000,dtype=np.int64)})
            probability = float(output.reshape(-1)[0])
            peak = max(peak,probability)
            run = run+1 if probability>=self.threshold else 0
            longest_run = max(longest_run,run)
            context = x[:,-64:]
        return {"has_speech":longest_run>=self.min_frames,"max_probability":peak,
                "longest_speech_ms":longest_run*32,"threshold":self.threshold,"minimum_speech_ms":self.min_frames*32}
