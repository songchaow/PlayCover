from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "Scripts" / "analyze_capture_run_matrix.py"


def write_json(path: Path, payload: dict) -> None:
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


def make_run(
    root: Path,
    label: str,
    enabled: bool,
    module_key: str,
    aggregate_hash: str,
    visible_hashes: list[str],
    *,
    compile_status: str = "compiled",
    capture_count: int = 1,
) -> Path:
    bundle_dir = root / label / "com.miHoYo.Yuanshen"
    modules_dir = bundle_dir / "modules" / module_key
    replacements_dir = bundle_dir / "replacements" / f"20260405_newLibraryWithData:error:_cache-{label}"
    modules_dir.mkdir(parents=True, exist_ok=True)
    replacements_dir.mkdir(parents=True, exist_ok=True)

    (modules_dir / "module.bc").write_bytes(f"bc-{module_key}".encode("utf-8"))
    (modules_dir / "module.ll").write_text(f"; module {module_key}\n", encoding="utf-8")
    (modules_dir / "module.generated.metal").write_text(
        f"#include <metal_stdlib>\nusing namespace metal;\n// {aggregate_hash}\n",
        encoding="utf-8",
    )
    write_json(
        modules_dir / "module.meta.json",
        {
            "compileStatus": compile_status,
            "converterStatus": "success",
            "llvmDisStatus": "success",
            "captureCount": capture_count,
            "observedSelectors": ["newLibraryWithData:error:"],
            "sourceCacheKeys": [f"cache-{aggregate_hash}"],
            "generatedMSLBytes": 64,
            "llvmIRBytes": 32,
            "bitcodeBytes": 16,
        },
    )

    aggregate_relative = f"replacements/{replacements_dir.name}/aggregate.generated.metal"
    (bundle_dir / aggregate_relative).write_text(
        f"#include <metal_stdlib>\nusing namespace metal;\n// aggregate {aggregate_hash}\n",
        encoding="utf-8",
    )
    write_json(
        replacements_dir / "replacement.meta.json",
        {
            "moduleKeys": [module_key],
        },
    )
    write_jsonl(
        bundle_dir / "manifest.jsonl",
        [
            {
                "event": "capture",
                "bundleId": "com.miHoYo.Yuanshen",
                "selector": "newLibraryWithData:error:",
                "moduleKey": module_key,
                "captureAction": "saved",
                "functionNames": ["main0"],
                "functionTypes": ["fragment"],
                "generatedFunctionNames": ["main0"],
                "generatedFunctionTypes": ["fragment"],
                "timestamp": f"2026-04-05T00:00:0{1 if enabled else 2}Z",
            },
            {
                "event": "replacement",
                "timestamp": f"2026-04-05T00:00:1{1 if enabled else 2}Z",
                "selector": "newLibraryWithData:error:",
                "cacheKey": f"cache-{label}",
                "corpusRelativeDirectory": f"replacements/{replacements_dir.name}",
                "moduleKeys": [module_key],
                "moduleCount": 1,
                "functionCount": 1,
                "totalIRSize": 32,
                "aggregateMSLBytes": 64,
                "sourceFunctionNames": ["main0"],
                "sourceFunctionTypes": ["fragment"],
                "aggregateSourcePath": aggregate_relative,
            },
        ],
    )
    write_json(
        bundle_dir / "snapshot.meta.json",
        {
            "label": label,
            "replacementMode": {
                "enabled": enabled,
            },
            "gputraceSummary": {
                "validMSLFiles": len(visible_hashes),
                "indexHashReferences": 10,
                "files": {
                    hash_name: {
                        "isMSL": True,
                    }
                    for hash_name in visible_hashes
                },
            },
        },
    )
    return bundle_dir


class AnalyzeCaptureRunMatrixTests(unittest.TestCase):
    def test_run_matrix_groups_stability_and_cross_mode_differences(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            make_run(root, "replacement-off-run1", False, "shared-module", "off", ["AAAAAAAAAAAAAAAA"])
            make_run(root, "replacement-off-run2", False, "shared-module", "off", ["AAAAAAAAAAAAAAAA"])
            make_run(root, "replacement-on-run1", True, "shared-module", "on", ["BBBBBBBBBBBBBBBB"])
            make_run(root, "replacement-on-run2", True, "shared-module", "on", ["BBBBBBBBBBBBBBBB"])

            output_path = root / "matrix.json"
            completed = subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--runs-root",
                    str(root),
                    "--bundle-id",
                    "com.miHoYo.Yuanshen",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("mode=off: runs=2 pairs=1 allInputStable=True", completed.stdout)
            self.assertIn("mode=on: runs=2 pairs=1 allInputStable=True", completed.stdout)
            self.assertIn("off-vs-on: pairs=4 allPairsDifferent=True", completed.stdout)

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["groups"]["off"]["pairSummary"]["allPairsInputStable"], True)
            self.assertEqual(report["groups"]["on"]["pairSummary"]["allPairsInputStable"], True)
            self.assertEqual(report["crossMode"]["offVsOnPairSummary"]["allPairsDifferent"], True)

    def test_cross_mode_requires_more_than_replacement_flag_difference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            make_run(root, "replacement-off-run1", False, "shared-module", "same", ["AAAAAAAAAAAAAAAA"])
            make_run(root, "replacement-on-run1", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"])

            output_path = root / "matrix.json"
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--runs-root",
                    str(root),
                    "--bundle-id",
                    "com.miHoYo.Yuanshen",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["crossMode"]["offVsOnPairSummary"]["allPairsDifferent"], False)

    def test_same_mode_compile_status_drift_breaks_stability(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            make_run(root, "replacement-on-run1", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"], compile_status="compiled", capture_count=1)
            make_run(root, "replacement-on-run2", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"], compile_status="failed", capture_count=2)

            output_path = root / "matrix.json"
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--runs-root",
                    str(root),
                    "--bundle-id",
                    "com.miHoYo.Yuanshen",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["groups"]["on"]["pairSummary"]["allPairsInputStable"], False)
            pair = report["groups"]["on"]["pairs"][0]
            self.assertEqual(pair["classification"]["semanticSharedModuleDifferenceCount"], 1)

    def test_same_mode_capture_count_drift_is_benign(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            make_run(root, "replacement-on-run1", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"], capture_count=1)
            make_run(root, "replacement-on-run2", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"], capture_count=2)

            output_path = root / "matrix.json"
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--runs-root",
                    str(root),
                    "--bundle-id",
                    "com.miHoYo.Yuanshen",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["groups"]["on"]["pairSummary"]["allPairsInputStable"], True)
            pair = report["groups"]["on"]["pairs"][0]
            self.assertEqual(pair["classification"]["semanticSharedModuleDifferenceCount"], 0)

    def test_same_mode_summary_byte_drift_is_benign_when_artifacts_match(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run_a = make_run(root, "replacement-on-run1", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"])
            run_b = make_run(root, "replacement-on-run2", True, "shared-module", "same", ["AAAAAAAAAAAAAAAA"])

            meta_path = run_b / "modules" / "shared-module" / "module.meta.json"
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            meta["generatedMSLBytes"] += 6
            write_json(meta_path, meta)

            output_path = root / "matrix.json"
            subprocess.run(
                [
                    "python3",
                    str(SCRIPT_PATH),
                    "--runs-root",
                    str(root),
                    "--bundle-id",
                    "com.miHoYo.Yuanshen",
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(report["groups"]["on"]["pairSummary"]["allPairsInputStable"], True)
            pair = report["groups"]["on"]["pairs"][0]
            self.assertEqual(pair["classification"]["semanticSharedModuleDifferenceCount"], 0)


if __name__ == "__main__":
    unittest.main()
