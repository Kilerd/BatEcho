"""Bounded text-derived pinyin candidates; these are not acoustic posteriors."""
import json
import re
import subprocess
from dataclasses import asdict, dataclass
from pathlib import Path

from pypinyin import Style, lazy_pinyin

from .backends import ROOT

HANZI = re.compile(r"[\u3400-\u9fff]+")
INITIAL_PAIRS = [("zh", "z"), ("ch", "c"), ("sh", "s"), ("n", "l")]
FINAL_PAIRS = [("ang", "an"), ("eng", "en"), ("ing", "in")]


def syllable_cost(left: str, right: str) -> float:
    if left == right:
        return 0.0
    for a, b in INITIAL_PAIRS:
        for x, y in [(a, b), (b, a)]:
            if left.startswith(x) and right == y + left[len(x):]:
                return 0.5
    for a, b in FINAL_PAIRS:
        for x, y in [(a, b), (b, a)]:
            if left.endswith(x) and right == left[:-len(x)] + y:
                return 0.5
    return float("inf")


@dataclass(frozen=True)
class Edit:
    start: int
    end: int
    before: str
    after: str
    cost: float
    context_supported: bool


@dataclass
class Candidate:
    text: str
    edits: list[Edit]

    def audit(self):
        return {"text":self.text, "edits":[asdict(e) for e in self.edits]}


def load_lexicon(path: Path | None = None) -> list[dict]:
    entries = json.loads((path or ROOT / "data/lexicon.json").read_text())
    for entry in entries:
        if entry["pinyin"] and len(entry["text"]) != len(entry["pinyin"]):
            raise ValueError(f"Pinyin must match character count: {entry['text']}")
    return entries


def candidates(text: str, lexicon: list[dict], limit: int = 16) -> list[Candidate]:
    edits = []
    for match in HANZI.finditer(text):
        segment = match.group()
        syllables = lazy_pinyin(segment, style=Style.NORMAL, errors=lambda s:list(s))
        for entry in lexicon:
            target = entry["pinyin"]
            width = len(target)
            if width < 2:
                continue
            for i in range(len(syllables) - width + 1):
                before = segment[i:i+width]
                if before == entry["text"]:
                    continue
                cost = sum(syllable_cost(a,b) for a,b in zip(syllables[i:i+width], target))
                if cost > 0.5:
                    continue
                edits.append(Edit(match.start()+i, match.start()+i+width, before, entry["text"], cost,
                                  any(anchor in text for anchor in entry.get("contexts", []))))
    # Generate a bounded set, always retaining the original. No reference labels enter here.
    selections: list[list[Edit]] = [[]]
    for edit in sorted(edits, key=lambda e:(e.start, e.cost, -(e.end-e.start), e.after)):
        additions = [chosen+[edit] for chosen in selections
                     if all(edit.end <= e.start or edit.start >= e.end for e in chosen)]
        selections += additions
        selections = [[]] + sorted(selections[1:], key=lambda es:(sum(e.cost for e in es), -len(es)))[:limit-1]
    out = []
    seen = set()
    for selected in selections:
        changed = text
        for edit in sorted(selected, key=lambda e:e.start, reverse=True):
            changed = changed[:edit.start] + edit.after + changed[edit.end:]
        if changed not in seen:
            out.append(Candidate(changed, selected))
            seen.add(changed)
    return out


def choose_naive(options: list[Candidate]) -> Candidate:
    """Deliberately aggressive ablation: prioritize dictionary matches, even without context."""
    return max(options, key=lambda c:(len(c.edits), -sum(e.cost for e in c.edits)))


def choose_conservative(options: list[Candidate]) -> Candidate:
    eligible = [c for c in options if c.edits and all(e.cost == 0 and e.context_supported for e in c.edits)]
    if not eligible:
        return options[0]
    most_edits = max(len(c.edits) for c in eligible)
    winners = [c for c in eligible if len(c.edits) == most_edits]
    return winners[0] if len(winners) == 1 else options[0]


class QingjianScorer:
    def __init__(self):
        binary = ROOT / "experiments/qingjian-scorer/target/release/qingjian-scorer-probe"
        model = ROOT / ".cache/models/qingjian/model.qjm"
        self.process = subprocess.Popen([str(binary),str(model)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, text=True, bufsize=1)
        self.score(["你好。", "您好。"])

    def score(self, texts: list[str], context: str = "") -> dict:
        self.process.stdin.write(json.dumps({"context":context,"texts":texts},ensure_ascii=False)+"\n")
        self.process.stdin.flush()
        line = self.process.stdout.readline()
        if not line:
            raise RuntimeError(f"qingjian scorer exited: {self.process.poll()}")
        result = json.loads(line)
        if len(result["scores"]) != len(texts):
            raise RuntimeError("qingjian returned an unexpected score count")
        return result

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()


def choose_lm(options: list[Candidate], scores: list[float], with_lexicon_prior: bool) -> Candidate:
    combined = []
    for option, score in zip(options, scores):
        value = score - sum(0.5 + 4*e.cost for e in option.edits)
        if with_lexicon_prior:
            value += sum(3.0 for e in option.edits if e.context_supported)
        combined.append(value)
    return options[max(range(len(options)), key=lambda i:combined[i])]
