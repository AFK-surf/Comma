#!/usr/bin/env python3
"""Count repository-owned model/config physical lines, not executable SLOC."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
paths = subprocess.check_output(
    ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard",
     "--", "*.tla", "*.cfg"], cwd=root,
).decode().split("\0")
counts = {".tla": 0, ".cfg": 0}
for name in sorted(set(paths) - {""}):
    path = root / name
    if path.is_file():  # Deleted tracked files are absent in a worktree diff.
        counts[path.suffix] += len(path.read_bytes().splitlines())
total = sum(counts.values())
print(f"TLA+ budget: {total}/5000 lines "
      f"({counts['.tla']} model + {counts['.cfg']} configuration)")
if total > 5000:
    print("Reduce/replace coverage; do not minify or relocate models.", file=sys.stderr)
    sys.exit(1)
