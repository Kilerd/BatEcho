#!/usr/bin/env python3
"""Reject machine-specific data and credential files in tracked content."""
from pathlib import Path
import argparse
import re
import subprocess
import sys


PATTERNS = {
    "absolute home directory": rb"/(?:Users|home)/[A-Za-z0-9._-]+/",
    "Windows home directory": rb"[A-Za-z]:\\Users\\[^\\\s]+\\",
    "machine temporary directory": rb"/(?:private/)?var/folders/[A-Za-z0-9_/]+",
    "signing team value": rb"(?:--team-id\s+|TeamIdentifier=)[A-Z0-9]{10}\b",
    "personal signing identity": rb"Developer ID Application:\s+[^\r\n\"']+\([A-Z0-9]{10}\)",
}
CREDENTIAL_FILE = re.compile(
    r"(^|/)(\.env(?:\..+)?|[^/]+\.(?:p12|pfx|pem|key|keychain|keychain-db))$"
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, help="Check packaged files for embedded build-machine paths")
    args = parser.parse_args()
    if args.bundle:
        if not args.bundle.is_dir():
            parser.error("The app bundle must exist")
        failures = []
        for path in args.bundle.rglob("*"):
            if not path.is_file() or path.is_symlink():
                continue
            data = path.read_bytes()
            for label, pattern in PATTERNS.items():
                if "directory" in label and re.search(pattern, data):
                    failures.append(f"{path.relative_to(args.bundle)}: {label} (value omitted)")
        for failure in failures:
            print(failure, file=sys.stderr)
        if failures:
            return 1
        print("App bundle contains no embedded build-machine paths.")
        return 0
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    names = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    failures = []
    for name in filter(None, names):
        path = root / name
        if not path.is_file() or path.is_symlink():
            continue
        if CREDENTIAL_FILE.search(name):
            failures.append(f"{name}: credential file must remain outside version control")
        data = path.read_bytes()
        for label, pattern in PATTERNS.items():
            match = re.search(pattern, data)
            if match:
                line = data[:match.start()].count(b"\n") + 1
                failures.append(f"{name}:{line}: {label} (value omitted)")
    for failure in failures:
        print(failure, file=sys.stderr)
    if failures:
        return 1
    print("Tracked files contain no machine-specific paths or signing identities.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
