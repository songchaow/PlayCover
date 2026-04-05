from __future__ import annotations

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
            self.assertIn("finalize-run --bundle-id com.example.demo --mode off --run-index 2", completed.stdout)

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


if __name__ == "__main__":
    unittest.main()
