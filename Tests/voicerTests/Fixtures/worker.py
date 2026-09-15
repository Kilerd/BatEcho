import json
import os
from pathlib import Path
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    name = Path(request.get("audio") or "warmup").name
    if name == "crash":
        os._exit(2)
    if name == "hang":
        Path("started").write_text(str(os.getpid()))
        time.sleep(10)
    result = {"id": request["id"], "model": str(os.getpid()), "model_load_count": 1,
              "ready": True, "text": "你好 Kubernetes", "raw_text": "你好 Kubernetes"}
    if name == "error":
        result = {"id": request["id"], "error": {"code": "ValueError", "message": "Invalid vocabulary"}}
    encoded = (json.dumps(result, ensure_ascii=False) + "\n").encode()
    if name == "chunked":
        for start in range(0, len(encoded), 3):
            os.write(sys.stdout.fileno(), encoded[start:start+3])
            time.sleep(0.001)
    elif name == "invalid":
        print("not JSON", flush=True)
    else:
        os.write(sys.stdout.fileno(), encoded)
