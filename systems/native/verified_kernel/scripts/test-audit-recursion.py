"""Exercise the audit through Lean compilation and its command-line result."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest


PACKAGE = Path(__file__).resolve().parent.parent


class RecursionAuditTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="lean-recursion-audit-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.root = Path(cls.directory.name)
        source = cls.root / "Fixtures.lean"
        shutil.copyfile(PACKAGE / "test/recursion_audit/Fixtures.lean", source)
        result = subprocess.run(
            ["lake", "env", "lean", "-j1", f"--root={cls.root}",
             "-o", str(cls.root / "Fixtures.olean"), str(source)],
            cwd=PACKAGE, capture_output=True, text=True, timeout=60,
        )
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        unsafe_source = cls.root / "Unsafe.lean"
        shutil.copyfile(PACKAGE / "test/recursion_audit/Unsafe.lean", unsafe_source)
        subprocess.run(
            ["lake", "env", "lean", "-j1", f"--root={cls.root}",
             "-o", str(cls.root / "Unsafe.olean"), str(unsafe_source)],
            cwd=PACKAGE, capture_output=True, text=True, timeout=60, check=True,
        )
        cls.environment = os.environ.copy()
        lake_path = subprocess.check_output(
            ["lake", "env", "printenv", "LEAN_PATH"], cwd=PACKAGE, text=True
        ).strip()
        cls.environment["LEAN_PATH"] = str(cls.root) + os.pathsep + lake_path

    def audit(self, entry=None):
        args = [sys.executable, "scripts/audit-recursion.py",
                "--module", "Fixtures", "--prefix", "Fixtures"]
        if entry:
            args += ["--entry", "RecursionFixtures." + entry]
        result = subprocess.run(
            args, cwd=PACKAGE, env=self.environment,
            capture_output=True, text=True, timeout=60,
        )
        self.assertIn(result.returncode, (0, 1), result.stdout + result.stderr)
        return result.returncode, json.loads(result.stdout)["exports"]

    def test_accumulator_recursion_compiles_as_a_loop(self):
        status, reports = self.audit("loop")
        self.assertEqual(status, 0)
        self.assertEqual(reports[0]["status"], "bounded")
        self.assertEqual(reports[0]["max_lean_frames"], 1)

    def test_work_after_a_recursive_call_is_rejected(self):
        status, reports = self.audit("recursive")
        self.assertEqual(status, 1)
        self.assertIn(["RecursionFixtures.recursive"], reports[0]["unbounded_components"])

    def test_recursion_in_a_reachable_helper_is_rejected(self):
        status, reports = self.audit("transitive")
        self.assertEqual(status, 1)
        self.assertIn(["RecursionFixtures.helper"], reports[0]["unbounded_components"])

    def test_unresolved_function_values_do_not_pass(self):
        status, reports = self.audit("indirect")
        self.assertEqual(status, 1)
        self.assertTrue(any("unresolved callback" in x for x in reports[0]["unresolved"]))

    def test_mutual_recursion_is_rejected(self):
        status, reports = self.audit("mutualCalls")
        self.assertEqual(status, 1)
        self.assertTrue(any(len(cycle) > 1 for cycle in reports[0]["unbounded_components"]))

    def test_exported_callable_values_are_not_silently_ignored(self):
        status, reports = self.audit("closure")
        self.assertEqual(status, 1)
        self.assertTrue(reports[0]["unresolved"])

    def test_a_fixed_decreasing_fuel_is_bounded(self):
        status, reports = self.audit("closedBound")
        self.assertEqual(status, 0)
        self.assertGreater(reports[0]["max_lean_frames"], 64)
        self.assertTrue(reports[0]["bounded_components"])

    def test_input_fuel_is_not_a_uniform_bound(self):
        self.assertEqual(self.audit("bounded")[0], 1)

    def test_known_callbacks_including_arrays_are_resolved(self):
        for entry in ("knownCallback", "arrayCallback"):
            with self.subTest(entry=entry):
                status, reports = self.audit(entry)
                self.assertEqual(status, 0, reports)

    def test_fuel_must_decrease_on_every_recursive_cycle(self):
        for entry in ("resetFuel", "truncatedFuel"):
            with self.subTest(entry=entry):
                status, reports = self.audit(entry)
                self.assertEqual(status, 1, reports)
                self.assertTrue(reports[0]["unbounded_components"])

    def test_unknown_callbacks_fail_closed_at_boundaries(self):
        for entry in ("foreignResult", "foreignCallback", "inputContainer"):
            with self.subTest(entry=entry):
                status, reports = self.audit(entry)
                self.assertEqual(status, 1, reports)
                self.assertTrue(reports[0]["unresolved"])

    def test_recursion_inside_a_reused_function_container_is_found(self):
        status, reports = self.audit("containerRecursion")
        self.assertEqual(status, 1)
        self.assertIn(["RecursionFixtures.helper"], reports[0]["unbounded_components"])

    def test_a_bound_can_cross_mutually_recursive_functions(self):
        status, reports = self.audit("boundedMutual")
        self.assertEqual(status, 0, reports)
        self.assertTrue(reports[0]["bounded_components"])

    def test_unsafe_code_cannot_bypass_erased_type_filtering(self):
        result = subprocess.run(
            [sys.executable, "scripts/audit-recursion.py", "--module", "Unsafe", "--prefix", "Unsafe"],
            cwd=PACKAGE, env=self.environment, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Unsafe definition", result.stderr)

    def test_a_tail_loop_cannot_reset_a_recursive_frame_budget(self):
        status, reports = self.audit("tailRefuel")
        self.assertEqual(status, 1, reports)
        self.assertTrue(reports[0]["unbounded_components"])

    def test_every_export_is_discovered(self):
        status, reports = self.audit()
        self.assertEqual(status, 1)
        self.assertEqual(
            {report["entrypoint"] for report in reports},
            {"RecursionFixtures." + name for name in
             ["loop", "recursive", "transitive", "mutualCalls", "closure",
              "indirect", "bounded", "closedBound", "knownCallback", "arrayCallback",
              "resetFuel", "truncatedFuel", "foreignResult", "foreignCallback", "inputContainer",
              "containerRecursion", "boundedMutual", "tailRefuel"]},
        )


if __name__ == "__main__":
    unittest.main()
