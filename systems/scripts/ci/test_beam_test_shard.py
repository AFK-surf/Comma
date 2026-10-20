"""Exercise CI file ownership and empty-shard handling through the planner CLI."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BeamTestShardTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.systems = self.root / "systems"
        scripts = self.systems / "scripts/ci"
        scripts.mkdir(parents=True)
        shutil.copyfile(Path(__file__).with_name("beam_test_shard.exs"), scripts / "beam_test_shard.exs")
        (scripts / "beam_test_timings.json").write_text("{}")
        self.tests = self.systems / "apps/billing_core/test"
        self.tests.mkdir(parents=True)

    def run_planner(self, *args):
        return subprocess.run(
            ["elixir", "scripts/ci/beam_test_shard.exs", *args],
            cwd=self.systems, env=os.environ | {"ELIXIR_ERL_OPTIONS": "+S 1:1"},
            capture_output=True, text=True,
        )

    def write_test(self, name, body):
        path = self.tests / f"{name}_test.exs"
        path.write_text(body)
        return path.relative_to(self.systems).as_posix()

    def test_every_test_file_belongs_to_a_shard(self):
        clock = self.write_test("clock", "defmodule ClockTest do\n use SystemsClock.Case\nend")
        native = self.write_test("native", "defmodule NativeTest do\n use ExUnit.Case\nend")
        custom = self.write_test("custom", "defmodule CustomTest do\n use MyTestSupport\nend")
        result = self.run_planner("1", "1", "apps/billing_core/test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(result.stdout.splitlines()), {clock, native, custom})
        absolute = self.run_planner("1", "1", str(self.tests))
        self.assertEqual(absolute.returncode, 0, absolute.stderr)
        self.assertEqual(
            {Path(p).relative_to(self.systems).as_posix() for p in absolute.stdout.splitlines()},
            set(result.stdout.splitlines()),
        )

    def test_empty_directory_has_no_shard(self):
        result = self.run_planner("--plan", "--full")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"include": []})
        empty = self.run_planner("1", "1", "apps/billing_core/test")
        self.assertNotEqual(empty.returncode, 0)
        self.assertEqual(empty.stdout, "")

    def test_shards_fill_whole_jobs(self):
        other = self.systems / "apps/bridge_for_teams_core/test"
        other.mkdir(parents=True)
        timings = {}
        for index in range(9):
            name = self.write_test(f"slow{index}", "defmodule SlowTest do\n use ExUnit.Case\nend")
            timings[name] = 50.0
        for index in range(5):
            (other / f"slow{index}_test.exs").write_text("defmodule OtherTest do\n use ExUnit.Case\nend")
            timings[f"apps/bridge_for_teams_core/test/slow{index}_test.exs"] = 50.0
        (self.systems / "scripts/ci/beam_test_timings.json").write_text(json.dumps(timings))
        result = self.run_planner("--plan", "--full")
        self.assertEqual(result.returncode, 0, result.stderr)
        # 700 recorded seconds fit one job: each group gets a shard per 90
        # seconds, five for the longer group and three for the other, on the
        # 8-CPU runner.
        [job] = json.loads(result.stdout)["include"]
        self.assertEqual(job["partitions"], 8)
        self.assertEqual(job["runner"], "pvg-linux-arm64-8c")
        self.assertEqual(
            [shard.split(" ")[:2] for shard in job["shards"].split(";")],
            [["1", "5"], ["2", "5"], ["3", "5"], ["4", "5"], ["5", "5"], ["1", "3"], ["2", "3"], ["3", "3"]],
        )
        self.assertIn("apps/billing_core/test", job["shards"].split(";")[0])

    def test_unrelated_change_runs_no_job(self):
        self.write_test("native", "defmodule NativeTest do\n use ExUnit.Case\nend")
        changed = self.root / "changed-files"
        changed.write_text("clients/apps/web/src/main.ts\n")
        result = self.run_planner("--plan", str(changed))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"include": []})


if __name__ == "__main__":
    unittest.main()
