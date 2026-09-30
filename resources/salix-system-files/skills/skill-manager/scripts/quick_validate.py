#!/usr/bin/env python3
"""
Quick validation script for Bridge skills (minimal).

This validates a target skill directory by checking:
- SKILL.md exists
- YAML frontmatter exists and is parseable
- Required keys: name, description
- Common naming/length rules (hyphen-case name, reasonable description)
- Directory name matches frontmatter name (recommended for Bridge)

This script is intentionally lightweight and may not cover all YAML features.
If PyYAML is available, it will be used for parsing; otherwise a simple parser is used.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None


ALLOWED_PROPERTIES = {
    "name",
    "description",
    "license",
    "compatibility",
    "allowed-tools",
    "metadata",
}

WARN_IMPORT_PATTERNS: list[tuple[str, str]] = [
    ("requests", "Avoid re-implementing web fetching in scripts when web tools exist; prefer built-in web search / browser tools."),
    ("httpx", "Avoid re-implementing web fetching in scripts when web tools exist; prefer built-in web search / browser tools."),
    ("aiohttp", "Avoid re-implementing web fetching in scripts when web tools exist; prefer built-in web search / browser tools."),
    ("urllib.request", "Avoid re-implementing web fetching in scripts when web tools exist; prefer built-in web search / browser tools."),
    ("bs4", "Avoid re-implementing parsing pipelines unless necessary; prefer existing tools/skills and keep scripts small."),
    ("BeautifulSoup", "Avoid re-implementing parsing pipelines unless necessary; prefer existing tools/skills and keep scripts small."),
    ("selenium", "Prefer platform browser tools over embedding selenium in scripts unless explicitly justified."),
    ("playwright", "Prefer platform browser tools over embedding playwright in scripts unless explicitly justified."),
]


def extract_frontmatter(content: str) -> tuple[str | None, str | None]:
    if not content.startswith("---\n"):
        return None, "No YAML frontmatter found (expected file to start with ---)"

    match = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
    if not match:
        return None, "Invalid frontmatter format (missing closing --- delimiter)"

    return match.group(1), None


def parse_frontmatter(frontmatter_text: str) -> tuple[dict | None, str | None]:
    if yaml is not None:
        try:
            fm = yaml.safe_load(frontmatter_text)
        except Exception as e:  # pragma: no cover
            return None, f"Invalid YAML in frontmatter: {e}"
        if not isinstance(fm, dict):
            return None, "Frontmatter must be a YAML dictionary"
        return fm, None

    # Fallback parser (supports simple key/value lines + a 'metadata:' mapping)
    fm: dict = {}
    lines = frontmatter_text.splitlines()
    i = 0
    while i < len(lines):
        line = lines[i].rstrip("\n")
        if not line.strip():
            i += 1
            continue

        # nested metadata block
        if re.match(r"^metadata:\s*$", line):
            meta: dict[str, str] = {}
            i += 1
            while i < len(lines):
                sub = lines[i].rstrip("\n")
                if not sub.strip():
                    i += 1
                    continue
                if not sub.startswith("  "):
                    break
                m = re.match(r"^\s{2}([A-Za-z0-9_.-]+):\s*(.*)$", sub)
                if m:
                    k = m.group(1)
                    v = m.group(2).strip().strip('"').strip("'")
                    meta[k] = v
                i += 1
            fm["metadata"] = meta
            continue

        m = re.match(r"^([A-Za-z0-9_.-]+):\s*(.*)$", line)
        if m:
            k = m.group(1)
            v = m.group(2).strip().strip('"').strip("'")
            fm[k] = v
        i += 1

    return fm, None


def collect_warnings(skill_dir: Path) -> list[str]:
    warnings: list[str] = []

    scripts_dir = skill_dir / "scripts"
    if not scripts_dir.exists() or not scripts_dir.is_dir():
        return warnings

    for script_path in scripts_dir.rglob("*.py"):
        try:
            text = script_path.read_text(encoding="utf-8")
        except Exception:
            continue

        for needle, hint in WARN_IMPORT_PATTERNS:
            if needle in text:
                warnings.append(f"{script_path.name}: found '{needle}'. {hint}")

        # Lightweight smell: instruction-style installs embedded in scripts
        if "pip install" in text or "python -m venv" in text or "virtualenv" in text:
            warnings.append(
                f"{script_path.name}: detected install/venv instructions. Prefer using the environment's package policy and keep skills portable."
            )

    return warnings


def validate_skill(skill_path: str) -> tuple[bool, str]:
    skill_dir = Path(skill_path).expanduser().resolve()

    if not skill_dir.exists():
        return False, f"Skill folder not found: {skill_dir}"
    if not skill_dir.is_dir():
        return False, f"Path is not a directory: {skill_dir}"

    skill_md = skill_dir / "SKILL.md"
    if not skill_md.exists():
        return False, "SKILL.md not found"

    content = skill_md.read_text(encoding="utf-8")
    fm_text, err = extract_frontmatter(content)
    if err:
        return False, err

    fm, err = parse_frontmatter(fm_text or "")
    if err:
        return False, err
    if not isinstance(fm, dict):
        return False, "Frontmatter must be a YAML dictionary"

    unexpected_keys = set(fm.keys()) - ALLOWED_PROPERTIES
    if unexpected_keys:
        return False, (
            f"Unexpected key(s) in SKILL.md frontmatter: {', '.join(sorted(unexpected_keys))}. "
            f"Allowed properties are: {', '.join(sorted(ALLOWED_PROPERTIES))}"
        )

    if "name" not in fm:
        return False, "Missing 'name' in frontmatter"
    if "description" not in fm:
        return False, "Missing 'description' in frontmatter"

    name = fm.get("name", "")
    if not isinstance(name, str):
        return False, f"Name must be a string, got {type(name).__name__}"
    name = name.strip()
    if not name:
        return False, "Name cannot be empty"

    # Recommended Bridge convention (also matches many skill ecosystems)
    if not re.match(r"^[a-z0-9-]+$", name):
        return False, f"Name '{name}' should be hyphen-case (lowercase letters, digits, and hyphens only)"
    if name.startswith("-") or name.endswith("-") or "--" in name:
        return False, f"Name '{name}' cannot start/end with hyphen or contain consecutive hyphens"
    if len(name) > 64:
        return False, f"Name is too long ({len(name)} characters). Maximum is 64 characters."

    # Bridge expects folder name alignment (warn-as-error for consistency)
    if skill_dir.name != name:
        return False, f"Directory name '{skill_dir.name}' must match frontmatter name '{name}'"

    description = fm.get("description", "")
    if not isinstance(description, str):
        return False, f"Description must be a string, got {type(description).__name__}"
    description = description.strip()
    if not description:
        return False, "Description cannot be empty"
    if "<" in description or ">" in description:
        return False, "Description cannot contain angle brackets (< or >)"
    if len(description) > 1024:
        return False, f"Description is too long ({len(description)} characters). Maximum is 1024 characters."

    warnings = collect_warnings(skill_dir)
    if warnings:
        joined = "\n".join(f"⚠️  {w}" for w in warnings)
        return True, f"Skill is valid (with warnings):\n{joined}"

    return True, "Skill is valid!"


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: python3 quick_validate.py <skill_directory>")
        return 1

    valid, message = validate_skill(sys.argv[1])
    print(message)
    return 0 if valid else 1


if __name__ == "__main__":
    raise SystemExit(main())
