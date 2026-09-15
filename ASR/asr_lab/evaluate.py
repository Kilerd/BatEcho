import argparse
import hashlib
import json
import time
import unicodedata
from collections import defaultdict
from pathlib import Path

import numpy as np
from rapidfuzz.distance import Levenshtein

from .backends import ROOT
from .correction import QingjianScorer, candidates, choose_conservative, choose_lm, choose_naive, load_lexicon


def normalize(text: str) -> str:
    return "".join(c for c in unicodedata.normalize("NFKC",text).casefold() if c.isalnum())


def errors(reference: str, hypothesis: str) -> int:
    return Levenshtein.distance(normalize(reference), normalize(hypothesis))


def summarize(rows: list[dict]) -> dict:
    groups = defaultdict(list)
    for row in rows:
        groups[(row["model"],row["mode"],row["correction"])].append(row)
    output = {}
    for key, items in groups.items():
        # Keep number formatting, English character segmentation and public examples separate.
        primary = [r for r in items if r["source"] == "macOS say synthetic" and r["category"] not in {"number","mixed"}]
        negative = [r for r in items if r["category"] == "negative"]
        term_rows = [r for r in items if r["category"] == "term"]
        term_total = sum(len(r["terms"]) for r in term_rows)
        reference_chars = sum(len(normalize(r["reference"])) for r in primary)
        output["/".join(key)] = {
            "clips":len(items), "primary_clips":len(primary), "reference_chars":reference_chars,
            "errors":sum(r["errors"] for r in primary),
            "cer":sum(r["errors"] for r in primary)/reference_chars if reference_chars else None,
            "term_hits":sum(normalize(t) in normalize(r["corrected"]) for r in term_rows for t in r["terms"]),
            "term_total":term_total,
            "negative_errors":sum(r["errors"] for r in negative),
            "negative_changed":sum(r["corrected"] != r["text"] for r in negative),
            "improved_clips":sum(r["errors"] < r["original_errors"] for r in items),
            "harmed_clips":sum(r["errors"] > r["original_errors"] for r in items),
            "asr_p50_s":float(np.percentile([r["elapsed_s"] for r in items],50)),
            "asr_p95_s":float(np.percentile([r["elapsed_s"] for r in items],95)),
            "post_p50_s":float(np.percentile([r["post_s"] for r in items],50)),
            "post_p95_s":float(np.percentile([r["post_s"] for r in items],95)),
            "total_p95_s":float(np.percentile([r["elapsed_s"]+r["post_s"] for r in items],95)),
            "mlx_peak_gib":max(r["mlx_peak_bytes"] for r in items)/(1024**3),
        }
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path)
    parser.add_argument("--with-qingjian", action="store_true")
    parser.add_argument("--output", type=Path, default=ROOT/"results/evaluation.json")
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(f"Choose a new --output to preserve evidence: {args.output}")
    lexicon = load_lexicon()
    scorer = QingjianScorer() if args.with_qingjian else None
    rows = []
    audits = []
    try:
        for path in args.inputs:
            for line in path.read_text().splitlines():
                record = json.loads(line)
                start = time.perf_counter()
                options = candidates(record["text"],lexicon)
                proposal_s = time.perf_counter()-start
                choices = {"none":(options[0],0.0),
                           "pinyin_naive":(choose_naive(options),proposal_s),
                           "pinyin_context":(choose_conservative(options),proposal_s)}
                audit = {"model":record["model"],"mode":record["mode"],"id":record["id"],
                         "candidates":[c.audit() for c in options],"reference_in_candidates":
                         any(normalize(c.text)==normalize(record["reference"]) for c in options)}
                if scorer:
                    lm_start = time.perf_counter()
                    scored = scorer.score([c.text for c in options]) if len(options)>1 else {"scores":[0.0],"elapsed_s":0.0}
                    lm_s = time.perf_counter()-lm_start if len(options)>1 else 0.0
                    for use_prior, name in [(False,"pinyin_qingjian"),(True,"pinyin_qingjian_prior")]:
                        choices[name] = (choose_lm(options,scored["scores"],use_prior),proposal_s+lm_s)
                    audit["lm"] = scored
                audits.append(audit)
                for name, (choice,post_s) in choices.items():
                    rows.append({**record,"correction":name,"corrected":choice.text,
                                 "edits":[e.__dict__ for e in choice.edits],"post_s":post_s,
                                 "errors":errors(record["reference"],choice.text),
                                 "original_errors":errors(record["reference"],record["text"])})
    finally:
        if scorer:
            scorer.close()
    result={"method":"fixed lexicon; no reference text used for correction; qingjian CPU Accelerate, LM weight 1, edit penalty 0.5+4*phonetic_cost, context-supported lexicon bonus 3; weights not tuned",
            "inputs":{str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in args.inputs},
            "code_sha256":{name:hashlib.sha256((ROOT/name).read_bytes()).hexdigest()
                           for name in ["asr_lab/correction.py", "asr_lab/evaluate.py",
                                        "experiments/qingjian-scorer/src/main.rs"]},
            "lexicon_sha256":hashlib.sha256((ROOT/"data/lexicon.json").read_bytes()).hexdigest(),
            "summary":summarize(rows),
            "summary_by_voice":{voice:summarize([r for r in rows if r.get("voice",r["category"])==voice])
                                for voice in sorted({r.get("voice",r["category"]) for r in rows})},
            "rows":rows,"candidate_audit":audits}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,ensure_ascii=False,indent=2)+"\n")
    for key, value in result["summary"].items():
        print(f"{key}: CER {value['cer']:.2%}; terms {value['term_hits']}/{value['term_total']}; changed +{value['improved_clips']} / -{value['harmed_clips']}; ASR P50 {value['asr_p50_s']:.3f}s")


if __name__ == "__main__":
    main()
