#!/usr/bin/env python3
"""Materialize one pinned TeamBench task without exposing grader data to agents."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys


def copy_tree_contents(source: pathlib.Path, destination: pathlib.Path) -> None:
    if not source.is_dir():
        return
    destination.mkdir(parents=True, exist_ok=True)
    for child in source.iterdir():
        target = destination / child.name
        if child.is_dir():
            shutil.copytree(child, target, dirs_exist_ok=True)
        else:
            shutil.copy2(child, target)


def materialize(source_root: pathlib.Path, task_id: str, seed: int, output: pathlib.Path) -> dict:
    task_source = source_root / "tasks" / task_id
    if not task_source.is_dir() or not (task_source / "grade.sh").is_file():
        raise ValueError(f"unknown TeamBench task: {task_id}")

    agent_root = output / "agent"
    workspace = agent_root / "workspace"
    reports = output / "grader" / "reports"
    task_copy = output / "grader" / "source" / "tasks" / task_id
    harness_copy = output / "grader" / "source" / "harness"
    for directory in (workspace, reports, task_copy, harness_copy):
        directory.mkdir(parents=True, exist_ok=True)

    copy_tree_contents(task_source, task_copy)
    helper = source_root / "harness" / "grader_helpers.sh"
    if helper.is_file():
        shutil.copy2(helper, harness_copy / helper.name)

    sys.path.insert(0, str(source_root))
    generated = False
    spec_text: str
    brief_text: str
    generator_source = source_root / "generators" / f"gen_{task_id.lower()}.py"
    if generator_source.is_file():
        from generators.registry import get_generator

        generator = get_generator(task_id)
        result = generator.generate(seed=seed)
        generator.write_to_disk(
            result,
            workspace_dir=str(workspace),
            reports_dir=str(reports),
            task_dir=str(task_copy),
        )
        spec_text = result.spec_md
        brief_text = result.brief_md
        guidance = result.metadata.get("analysis_guidance_md")
        if isinstance(guidance, str) and guidance:
            (task_copy / "analysis_guidance.md").write_text(guidance, encoding="utf-8")
        generated = True
    else:
        copy_tree_contents(task_source / "workspace", workspace)
        setup = task_copy / "setup.sh"
        if setup.is_file():
            run_id = f"evalens-{task_id}-seed-{seed}"
            completed = subprocess.run(
                ["bash", str(setup), str(workspace), str(reports), run_id, str(seed)],
                cwd=source_root,
                check=False,
                capture_output=True,
                text=True,
            )
            if completed.returncode != 0:
                raise RuntimeError(
                    f"{task_id} setup.sh failed ({completed.returncode}): "
                    f"{completed.stderr[-4000:]}"
                )
        spec_text = (task_copy / "spec.md").read_text(encoding="utf-8")
        brief_text = (task_copy / "brief.md").read_text(encoding="utf-8")

    # Corpus files are public task inputs referenced by the specification, not
    # grader internals. Keep an explicit agent-visible copy so experiments never
    # need to expose or reach into grader/source at run time.
    copy_tree_contents(task_copy / "corpus", agent_root / "task" / "corpus")
    (agent_root / "spec.md").write_text(spec_text, encoding="utf-8")
    (agent_root / "brief.md").write_text(brief_text, encoding="utf-8")
    metadata = {
        "format": "evalens-teambench-materialization-v1",
        "task_id": task_id,
        "seed": seed,
        "generated": generated,
    }
    (output / "materialization.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True)
    parser.add_argument("--task-id", required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    source_root = pathlib.Path(args.source_root).resolve()
    output = pathlib.Path(args.output).resolve()
    if output.exists() and any(output.iterdir()):
        raise ValueError(f"materialization output must be empty: {output}")
    output.mkdir(parents=True, exist_ok=True)
    print(json.dumps(materialize(source_root, args.task_id, args.seed, output)))


if __name__ == "__main__":
    main()
