"""Token-level contextual bias with refundable prefix scores.

Inspired by the Aho-Corasick contextual-biasing method documented by sherpa.
Each completed phrase earns a fixed score, independent of Chinese/BPE length.
English phrase rewards wait for a word boundary, avoiding API -> APIS matches.
"""
import math
import re
from collections import OrderedDict, deque
from dataclasses import dataclass, field

import numpy as np

HANZI = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")


def tokenize_hotwords(model, words: list[str]) -> list[dict]:
    if len(words) > 64:
        raise ValueError("Select at most 64 FireRed hotwords for one utterance")
    vocabulary = {piece:index for index,piece in enumerate(model._tokenizer)}
    compiled, seen = [], set()
    for word in words:
        # Follow FireRed's ChineseCharEnglishSpmTokenizer: uppercase English,
        # individual Chinese characters, SentencePiece for non-Chinese spans.
        text = re.sub(r"[，。？！,.?!]", " ", word.upper()).strip()
        pieces = []
        for part in re.split(r"([\u3400-\u4dbf\u4e00-\u9fff])", text):
            if not part.strip():
                continue
            pieces.extend([part] if HANZI.fullmatch(part) else model._sp.encode(part.strip(),out_type=str))
        ids = [vocabulary.get(piece,1) for piece in pieces]
        if not ids or any(token < 5 for token in ids):
            raise ValueError(f"FireRed cannot encode hotword without unknown/special tokens: {word!r}")
        key = tuple(ids)
        if key not in seen:
            seen.add(key)
            compiled.append({"text":word,"tokens":pieces,"ids":ids,
                             "english_boundary":bool(re.search(r"[A-Z0-9]$",text))})
    if sum(len(word["ids"]) for word in compiled) > 512:
        raise ValueError("Select fewer FireRed hotwords (maximum 512 tokens total)")
    return compiled


@dataclass
class Node:
    children: dict[int,int] = field(default_factory=dict)
    fail: int = 0
    prefixes: dict[int,float] = field(default_factory=dict)
    immediate: int = 0
    deferred: int = 0


class ContextGraph:
    def __init__(self, phrases: list[dict], vocabulary: list[str], eos_id: int, score: float):
        if not math.isfinite(score) or score < 0:
            raise ValueError("Hotword score must be finite and nonnegative")
        self.nodes = [Node()]
        self.score = score
        self.alphabet = set()
        self._reward_cache = OrderedDict()
        self.boundaries = np.array([
            i == eos_id or (i >= 5 and (piece.startswith("▁") or not re.fullmatch(r"[A-Z0-9_']+",piece)))
            for i,piece in enumerate(vocabulary)
        ],dtype=bool)
        seen = set()
        for phrase in phrases:
            ids = tuple(phrase["ids"])
            if not ids or ids in seen:
                continue
            phrase_id = len(seen)
            seen.add(ids)
            node = 0
            for depth, token in enumerate(ids,1):
                self.alphabet.add(token)
                if token not in self.nodes[node].children:
                    self.nodes[node].children[token] = len(self.nodes)
                    self.nodes.append(Node())
                node = self.nodes[node].children[token]
                self.nodes[node].prefixes[phrase_id] = score*depth/len(ids)
            if phrase.get("english_boundary",False):
                self.nodes[node].deferred |= 1 << phrase_id
            else:
                self.nodes[node].immediate |= 1 << phrase_id
        queue = deque(self.nodes[0].children.values())
        while queue:
            node = queue.popleft()
            for token, child in self.nodes[node].children.items():
                fallback = self.nodes[node].fail
                while fallback and token not in self.nodes[fallback].children:
                    fallback = self.nodes[fallback].fail
                self.nodes[child].fail = self.nodes[fallback].children.get(token,0)
                suffix = self.nodes[self.nodes[child].fail]
                self.nodes[child].immediate |= suffix.immediate
                self.nodes[child].deferred |= suffix.deferred
                for phrase_id,potential in suffix.prefixes.items():
                    self.nodes[child].prefixes[phrase_id] = max(
                        self.nodes[child].prefixes.get(phrase_id,0),potential)
                queue.append(child)

    def potential(self, state: int, seen: int) -> float:
        return max((value for phrase_id,value in self.nodes[state].prefixes.items()
                    if not seen & (1 << phrase_id)),default=0.0)

    def step(self, state: int, token: int, seen: int = 0) -> tuple[int,float,int]:
        previous = self.nodes[state]
        potential = self.potential(state,seen)
        while state and token not in self.nodes[state].children:
            state = self.nodes[state].fail
        following = self.nodes[state].children.get(token,0)
        node = self.nodes[following]
        completed = node.immediate
        if self.boundaries[token]:
            completed |= previous.deferred
        newly_completed = completed & ~seen
        seen |= newly_completed
        reward = self.potential(following,seen)-potential+newly_completed.bit_count()*self.score
        return following,reward,seen

    def finalize(self, state: int, seen: int = 0) -> float:
        # At a decode-length cutoff, do not reward an unconfirmed English end.
        return -self.potential(state,seen)

    def reward_vector(self, state: int, seen: int) -> np.ndarray:
        key = (state,seen)
        if key in self._reward_cache:
            self._reward_cache.move_to_end(key)
            return self._reward_cache[key]
        pending = (self.nodes[state].deferred & ~seen).bit_count()*self.score
        rewards = (-self.potential(state,seen)+self.boundaries*pending).astype(np.float32)
        for token in self.alphabet:
            _,rewards[token],_ = self.step(state,token,seen)
        # At most ~9 MB for this vocabulary, even across many utterances.
        if len(self._reward_cache) >= 256:
            self._reward_cache.popitem(last=False)
        self._reward_cache[key] = rewards
        return rewards
