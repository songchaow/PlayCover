from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
RUNNER_SCRIPT = REPO_ROOT / "Scripts" / "e006d_matrix_runner.py"


class E006DMatrixRunnerTests(unittest.TestCase):
    def test_prepare_run_toggles_mode_and_prints_followup(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            settings_path = container_root / "App Settings" / "com.example.demo.plist"
            settings_path.parent.mkdir(parents=True, exist_ok=True)
            with settings_path.open("wb") as handle:
                plistlib.dump({"shaderSourceReplacementEnabled": True}, handle)

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "prepare-run",
                    "--bundle-id",
                    "com.example.demo",
                    "--mode",
                    "off",
                    "--run-index",
                    "2",
                    "--container",
                    str(container_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            with settings_path.open("rb") as handle:
                payload = plistlib.load(handle)
            self.assertEqual(payload["shaderSourceReplacementEnabled"], False)
            self.assertIn("prepared replacement-off-run2", completed.stdout)
            self.assertIn("Library/Containers/com.example.demo/Data/Documents/Captures", completed.stdout)
            self.assertIn("finalize-run --bundle-id com.example.demo --mode off --run-index 2", completed.stdout)
            self.assertIn("--latest-gputrace", completed.stdout)

    def test_finalize_run_uses_standard_label_and_snapshot_script(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            output_root = root / "snapshots"
            bundle_id = "com.example.demo"

            corpus_dir = container_root / "ShaderCorpus" / bundle_id
            module_dir = corpus_dir / "modules" / "module-1"
            settings_dir = container_root / "App Settings"
            module_dir.mkdir(parents=True, exist_ok=True)
            settings_dir.mkdir(parents=True, exist_ok=True)

            (corpus_dir / "manifest.jsonl").write_text("{\"event\":\"capture\"}\n", encoding="utf-8")
            (module_dir / "module.bc").write_bytes(b"bc")
            (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
            (module_dir / "module.generated.metal").write_text("#include <metal_stdlib>\n", encoding="utf-8")
            (module_dir / "module.meta.json").write_text("{}\n", encoding="utf-8")
            with (settings_dir / f"{bundle_id}.plist").open("wb") as handle:
                plistlib.dump({"shaderSourceReplacementEnabled": True}, handle)

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-run",
                    "--bundle-id",
                    bundle_id,
                    "--mode",
                    "on",
                    "--run-index",
                    "3",
                    "--container",
                    str(container_root),
                    "--output-root",
                    str(output_root),
                    "--print-compare-path",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            snapshot_dir = output_root / "replacement-on-run3" / bundle_id
            self.assertTrue(snapshot_dir.is_dir())
            self.assertTrue((snapshot_dir / "snapshot.meta.json").is_file())
            self.assertIn(str(snapshot_dir), completed.stdout)

    def test_finalize_run_can_use_latest_gputrace_from_capture_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            capture_root = root / "captures"
            output_root = root / "snapshots"
            bundle_id = "com.example.demo"

            corpus_dir = container_root / "ShaderCorpus" / bundle_id
            module_dir = corpus_dir / "modules" / "module-1"
            settings_dir = container_root / "App Settings"
            module_dir.mkdir(parents=True, exist_ok=True)
            settings_dir.mkdir(parents=True, exist_ok=True)
            capture_root.mkdir(parents=True, exist_ok=True)

            (corpus_dir / "manifest.jsonl").write_text("{\"event\":\"capture\"}\n", encoding="utf-8")
            (module_dir / "module.bc").write_bytes(b"bc")
            (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
            (module_dir / "module.generated.metal").write_text("#include <metal_stdlib>\n", encoding="utf-8")
            (module_dir / "module.meta.json").write_text("{}\n", encoding="utf-8")
            with (settings_dir / f"{bundle_id}.plist").open("wb") as handle:
                plistlib.dump({"shaderSourceReplacementEnabled": True}, handle)

            older_trace = capture_root / "capture_older.gputrace"
            newer_trace = capture_root / "capture_newer.gputrace"
            older_trace.mkdir()
            newer_trace.mkdir()
            (older_trace / "index").write_text("OLDER\n", encoding="utf-8")
            (newer_trace / "index").write_text("NEWER\n", encoding="utf-8")
            older_mtime = older_trace.stat().st_mtime
            newer_mtime = older_mtime + 10
            older_trace.touch()
            newer_trace.touch()
            os.utime(older_trace, (older_mtime, older_mtime))
            os.utime(newer_trace, (newer_mtime, newer_mtime))

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-run",
                    "--bundle-id",
                    bundle_id,
                    "--mode",
                    "on",
                    "--run-index",
                    "4",
                    "--container",
                    str(container_root),
                    "--output-root",
                    str(output_root),
                    "--latest-gputrace",
                    "--capture-root",
                    str(capture_root),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            snapshot_trace = output_root / "replacement-on-run4" / bundle_id / "gputrace" / newer_trace.name
            self.assertTrue(snapshot_trace.is_dir())
            self.assertFalse((output_root / "replacement-on-run4" / bundle_id / "gputrace" / older_trace.name).exists())
            self.assertIn(str(newer_trace.resolve()), completed.stdout)

    def test_finalize_run_can_use_latest_gputrace_from_default_capture_root(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            output_root = root / "snapshots"
            bundle_id = "com.example.demo"

            corpus_dir = container_root / "ShaderCorpus" / bundle_id
            module_dir = corpus_dir / "modules" / "module-1"
            settings_dir = container_root / "App Settings"
            module_dir.mkdir(parents=True, exist_ok=True)
            settings_dir.mkdir(parents=True, exist_ok=True)

            (corpus_dir / "manifest.jsonl").write_text("{\"event\":\"capture\"}\n", encoding="utf-8")
            (module_dir / "module.bc").write_bytes(b"bc")
            (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
            (module_dir / "module.generated.metal").write_text("#include <metal_stdlib>\n", encoding="utf-8")
            (module_dir / "module.meta.json").write_text("{}\n", encoding="utf-8")
            with (settings_dir / f"{bundle_id}.plist").open("wb") as handle:
                plistlib.dump({"shaderSourceReplacementEnabled": True}, handle)

            capture_root = root / "Library" / "Containers" / bundle_id / "Data" / "Documents" / "Captures"
            capture_root.mkdir(parents=True, exist_ok=True)
            newer_trace = capture_root / "capture_default_newest.gputrace"
            newer_trace.mkdir()
            (newer_trace / "index").write_text("DEFAULT\n", encoding="utf-8")

            env = os.environ.copy()
            env["HOME"] = str(root)

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-run",
                    "--bundle-id",
                    bundle_id,
                    "--mode",
                    "on",
                    "--run-index",
                    "6",
                    "--container",
                    str(container_root),
                    "--output-root",
                    str(output_root),
                    "--latest-gputrace",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
                env=env,
            )

            snapshot_trace = output_root / "replacement-on-run6" / bundle_id / "gputrace" / newer_trace.name
            self.assertTrue(snapshot_trace.is_dir())
            self.assertIn(str(newer_trace.resolve()), completed.stdout)

    def test_finalize_run_rejects_conflicting_gputrace_options(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            output_root = root / "snapshots"
            bundle_id = "com.example.demo"

            corpus_dir = container_root / "ShaderCorpus" / bundle_id
            module_dir = corpus_dir / "modules" / "module-1"
            settings_dir = container_root / "App Settings"
            module_dir.mkdir(parents=True, exist_ok=True)
            settings_dir.mkdir(parents=True, exist_ok=True)

            (corpus_dir / "manifest.jsonl").write_text("{\"event\":\"capture\"}\n", encoding="utf-8")
            (module_dir / "module.bc").write_bytes(b"bc")
            (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
            (module_dir / "module.generated.metal").write_text("#include <metal_stdlib>\n", encoding="utf-8")
            (module_dir / "module.meta.json").write_text("{}\n", encoding="utf-8")
            with (settings_dir / f"{bundle_id}.plist").open("wb") as handle:
                plistlib.dump({"shaderSourceReplacementEnabled": True}, handle)

            trace_dir = root / "manual.gputrace"
            trace_dir.mkdir()
            (trace_dir / "index").write_text("TRACE\n", encoding="utf-8")

            completed = subprocess.run(
                [
                    "python3",
                    str(RUNNER_SCRIPT),
                    "finalize-run",
                    "--bundle-id",
                    bundle_id,
                    "--mode",
                    "on",
                    "--run-index",
                    "5",
                    "--container",
                    str(container_root),
                    "--output-root",
                    str(output_root),
                    "--gputrace",
                    str(trace_dir),
                    "--latest-gputrace",
                ],
                cwd=REPO_ROOT,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("mutually exclusive", completed.stderr)


if __name__ == "__main__":
    unittest.main()
