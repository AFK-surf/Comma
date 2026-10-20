#!/usr/bin/env python3
"""Permit one archive retry only for native profile lookup failure before build tasks."""
from pathlib import Path
import plistlib
import re
import sys


def retry_allowed(release):
    options = plistlib.loads((release / "ExportOptions.plist").read_bytes())
    lines = (release / "archive-attempt-1.log").read_text().splitlines()
    errors = [line for line in lines if re.search(r"(?:^|:\s*)error:", line)]
    allowed = set(options["provisioningProfiles"].values())
    for line in errors:
        match = re.search(r": error: No profile for team '([^']+)' matching '([^']+)' found:", line)
        if not match or match[1] != options["teamID"] or match[2] not in allowed:
            return False
    product_task = any(re.search(r"^[A-Za-z][A-Za-z0-9_]*\s+.*\(in target '", line) for line in lines)
    completed = (release / "Comma.xcarchive" / "Info.plist").exists() or any(
        "** ARCHIVE SUCCEEDED **" in line for line in lines)
    return bool(errors) and not product_task and not completed


if __name__ == "__main__":
    try:
        permitted = retry_allowed(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, IndexError, TypeError):
        permitted = False
    raise SystemExit(0 if permitted else 1)
