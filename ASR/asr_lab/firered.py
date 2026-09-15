"""Load the pinned FireRed conversion with strict learned-weight validation.

mlx-audio 0.5.4 registers two deterministic sinusoidal position tables as
parameters, but the converted checkpoint omits them. Restore just those
constructor-generated tables, retaining strict checks for every learned weight.
"""
import json
from pathlib import Path

import mlx.core as mx
from mlx_audio.stt.models.fireredasr2 import Model, ModelConfig


def restore_position_tables(model, weights: dict) -> dict:
    restored = dict(weights)
    for name, table in [
        ("encoder.positional_encoding.pe", model.encoder.positional_encoding.pe),
        ("decoder.positional_encoding.pe", model.decoder.positional_encoding.pe),
    ]:
        restored.setdefault(name, table)
    return restored


def load_firered(path: Path):
    config = json.loads((path / "config.json").read_text())
    config["model_path"] = str(path)
    model = Model(ModelConfig.from_dict(config))
    weights = model.sanitize(mx.load(str(path / "model.safetensors")))
    weights = restore_position_tables(model, weights)
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    return Model.post_load_hook(model, path)
