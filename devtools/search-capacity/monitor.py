#!/usr/bin/env python3
"""Observational cgroup sampling for one owned local test container; bounded run."""
import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--container", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--seconds", type=int, default=7200)
args = parser.parse_args()
args.output.parent.mkdir(parents=True, exist_ok=True)
deadline = time.monotonic() + args.seconds
with args.output.open("a") as output:
    while time.monotonic() < deadline:
        started = time.monotonic()
        result = subprocess.run(["docker", "exec", args.container, "cat",
            "/sys/fs/cgroup/memory.current", "/sys/fs/cgroup/memory.peak",
            "/sys/fs/cgroup/memory.stat", "/sys/fs/cgroup/memory.events",
            "/sys/fs/cgroup/cpu.stat"], capture_output=True, text=True, timeout=15)
        record = {"time": time.time(), "container": args.container}
        if result.returncode == 0:
            lines = result.stdout.splitlines()
            record["memory_current"] = int(lines[0])
            record["memory_peak"] = int(lines[1])
            record.update({key: int(value) for key, value in (line.split() for line in lines[2:])})
        else:
            record["error"] = result.stderr[:300]
        output.write(json.dumps(record) + "\n")
        output.flush()
        time.sleep(max(0, 5 - (time.monotonic() - started)))
