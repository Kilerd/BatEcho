"""Local file-to-text entry point. All inference stays on this Mac."""
import argparse
import json
import time
from pathlib import Path

from .backends import Backend, DEFAULT_MODEL, MODEL_NAMES, read_audio, resolve_hotwords
from .correction import QingjianScorer, candidates, choose_conservative, choose_lm, load_lexicon
from .vad import SpeechGate


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio",type=Path)
    parser.add_argument("--model",choices=MODEL_NAMES,default=DEFAULT_MODEL)
    parser.add_argument("--lexicon",type=Path)
    parser.add_argument("--hotwords",action=argparse.BooleanOptionalAction,default=None,
                        help="Default: Qwen/Fun enabled; experimental FireRed contextual decoding disabled")
    parser.add_argument("--hotword-score",type=float,default=4.0,
                        help="FireRed contextual score per completed phrase (requires --hotwords)")
    parser.add_argument("--correction",choices=["none","context","qingjian"],default="context")
    parser.add_argument("--output",type=Path)
    args = parser.parse_args()
    try:
        use_hotwords = resolve_hotwords(args.model,args.hotwords)
    except ValueError as error:
        parser.error(str(error))
    if args.output and args.output.exists():
        raise FileExistsError(args.output)
    start = time.perf_counter()
    audio = read_audio(args.audio)
    gate = SpeechGate().check(audio)
    result = {"audio":str(args.audio),"model":args.model,"duration_s":len(audio)/16000,"vad":gate,
              "raw_text":"","text":"","correction":args.correction,"hotwords_enabled":use_hotwords}
    if gate["has_speech"]:
        lexicon = load_lexicon(args.lexicon)
        model_start = time.perf_counter()
        backend = Backend(args.model,hotword_score=args.hotword_score)
        result["model_load_s"] = time.perf_counter()-model_start
        inference_start = time.perf_counter()
        recognized = backend.recognize(audio,[e["text"] for e in lexicon] if use_hotwords else None)
        raw = recognized.text
        result["asr_s"] = time.perf_counter()-inference_start
        if recognized.confidence is not None:
            result.update({"asr_confidence":recognized.confidence,"asr_confidence_scope":"utterance"})
        if args.model == "firered" and use_hotwords:
            result["hotword_score"] = args.hotword_score
            result["hotword_method"] = "contextual_beam_search"
        options = candidates(raw,lexicon)
        chosen = options[0]
        if args.correction == "context":
            chosen = choose_conservative(options)
        elif args.correction == "qingjian" and len(options)>1:
            scorer = QingjianScorer()
            try:
                scored = scorer.score([c.text for c in options])
                result["lm"] = scored
                chosen = choose_lm(options,scored["scores"],True)
            finally:
                scorer.close()
        result.update({"raw_text":raw,"text":chosen.text,"candidates":[c.audit() for c in options]})
    result["elapsed_s"] = time.perf_counter()-start
    rendered = json.dumps(result,ensure_ascii=False,indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(rendered+"\n")
    print(rendered)


if __name__ == "__main__":
    main()
