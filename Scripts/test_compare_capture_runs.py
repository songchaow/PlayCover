from __future__ import annotations

import json
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
COMPARE_SCRIPT = REPO_ROOT / "Scripts" / "compare_capture_runs.py"
SNAPSHOT_SCRIPT = REPO_ROOT / "Scripts" / "snapshot_capture_run.py"


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(row, sort_keys=True) + "\n" for row in rows), encoding="utf-8")


def make_container_run(
    container_root: Path,
    aggregate_text: str,
    module_text: str,
    *,
    attempt_outcome: str | None = "succeeded",
    attempt_reason_code: str | None = None,
) -> None:
    bundle_id = "com.example.demo"
    corpus_dir = container_root / "ShaderCorpus" / bundle_id
    module_dir = corpus_dir / "modules" / "module-key-1"
    replacement_dir = corpus_dir / "replacements" / "20260405_selector_cache"
    settings_path = container_root / "App Settings" / f"{bundle_id}.plist"

    module_dir.mkdir(parents=True, exist_ok=True)
    replacement_dir.mkdir(parents=True, exist_ok=True)
    settings_path.parent.mkdir(parents=True, exist_ok=True)

    (module_dir / "module.bc").write_bytes(b"bc")
    (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
    (module_dir / "module.generated.metal").write_text(module_text, encoding="utf-8")
    write_json(
        module_dir / "module.meta.json",
        {
            "compileStatus": "compiled",
            "converterStatus": "success",
            "llvmDisStatus": "success",
            "captureCount": 1,
            "observedSelectors": ["newLibraryWithData:error:"],
            "sourceCacheKeys": ["cache-key"],
            "generatedMSLBytes": len(module_text.encode("utf-8")),
            "llvmIRBytes": 8,
            "bitcodeBytes": 2,
        },
    )

    (replacement_dir / "aggregate.generated.metal").write_text(aggregate_text, encoding="utf-8")
    write_json(replacement_dir / "replacement.meta.json", {"moduleKeys": ["module-key-1"]})
    events = [
        {
            "event": "capture",
            "bundleId": bundle_id,
            "selector": "newLibraryWithData:error:",
            "moduleKey": "module-key-1",
            "captureAction": "saved",
            "functionNames": ["main0"],
            "functionTypes": ["fragment"],
            "generatedFunctionNames": ["main0"],
            "generatedFunctionTypes": ["fragment"],
            "timestamp": "2026-04-05T00:00:01Z",
        }
    ]
    if attempt_outcome is not None:
        events.append(
            {
                "event": "replacement_attempt",
                "timestamp": "2026-04-05T00:00:015Z",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "cache-key",
                "outcome": attempt_outcome,
                "reasonCode": attempt_reason_code,
                "moduleKeys": ["module-key-1"],
                "moduleCount": 1,
                "invalidModuleCount": None,
            }
        )
    if attempt_outcome == "succeeded":
        events.append(
            {
                "event": "replacement",
                "timestamp": "2026-04-05T00:00:02Z",
                "selector": "newLibraryWithData:error:",
                "cacheKey": "cache-key",
                "corpusRelativeDirectory": "replacements/20260405_selector_cache",
                "moduleKeys": ["module-key-1"],
                "moduleCount": 1,
                "functionCount": 1,
                "totalIRSize": 8,
                "aggregateMSLBytes": len(aggregate_text.encode("utf-8")),
                "sourceFunctionNames": ["main0"],
                "sourceFunctionTypes": ["fragment"],
                "aggregateSourcePath": "replacements/20260405_selector_cache/aggregate.generated.metal",
            }
        )
    write_jsonl(corpus_dir / "manifest.jsonl", events)
    with settings_path.open("wb") as handle:
        plistlib.dump({"shaderSourceReplacementEnabled": True}, handle)


def make_gputrace(
    trace_dir: Path,
    visible_files: dict[str, str | bytes],
    *,
    index_entries: list[str] | None = None,
) -> None:
    trace_dir.mkdir(parents=True, exist_ok=True)
    for name, content in visible_files.items():
        path = trace_dir / name
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
    entries = index_entries or ["0123456789ABCDEF", "FEDCBA9876543210"]
    (trace_dir / "index").write_bytes(" ".join(entries).encode("ascii"))


class CompareCaptureRunsTests(unittest.TestCase):
    def test_snapshot_capture_writes_gputrace_attribution_index(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            output_root = root / "snapshots"
            trace_dir = root / "trace-a.gputrace"
            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"
            make_container_run(container_root, aggregate_text, module_text)
            make_gputrace(
                trace_dir,
                {
                    "0123456789ABCDEF": aggregate_text,
                    "FEDCBA9876543210": module_text,
                },
            )

            subprocess.run(
                [
                    "python3",
                    str(SNAPSHOT_SCRIPT),
                    "--bundle-id",
                    "com.example.demo",
                    "--label",
                    "run-a",
                    "--container",
                    str(container_root),
                    "--output-root",
                    str(output_root),
                    "--gputrace",
                    str(trace_dir),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            bundle_dir = output_root / "run-a" / "com.example.demo"
            meta = json.loads((bundle_dir / "snapshot.meta.json").read_text(encoding="utf-8"))
            self.assertEqual(meta["copiedArtifacts"]["gputraceAttributionIndexPath"], "gputrace-attribution-index.json")

            attribution = json.loads((bundle_dir / "gputrace-attribution-index.json").read_text(encoding="utf-8"))
            self.assertEqual(sorted(attribution["attributedVisibleMSLHashes"]), ["0123456789ABCDEF", "FEDCBA9876543210"])
            self.assertEqual(sorted(attribution["attributedReferencedMSLHashes"]), ["0123456789ABCDEF", "FEDCBA9876543210"])
            self.assertEqual(attribution["unattributedReferencedMSLHashes"], [])
            self.assertEqual(attribution["attributedModuleKeys"], ["module-key-1"])
            self.assertEqual(
                attribution["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )

    def test_compare_capture_runs_reports_gputrace_attribution_differences(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            run_a = runs_root / "run-a" / "com.example.demo"
            run_b = runs_root / "run-b" / "com.example.demo"

            aggregate_text_a = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            aggregate_text_b = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\nfloat marker = 2.0;\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            for bundle_dir, aggregate_text, visible_hash in (
                (run_a, aggregate_text_a, "0123456789ABCDEF"),
                (run_b, aggregate_text_b, "FEDCBA9876543210"),
            ):
                container_root = root / f"container-{bundle_dir.parent.name}"
                make_container_run(container_root, aggregate_text, module_text)
                trace_dir = root / f"trace-{bundle_dir.parent.name}.gputrace"
                make_gputrace(trace_dir, {visible_hash: aggregate_text})
                subprocess.run(
                    [
                        "python3",
                        str(SNAPSHOT_SCRIPT),
                        "--bundle-id",
                        "com.example.demo",
                        "--label",
                        bundle_dir.parent.name,
                        "--container",
                        str(container_root),
                        "--output-root",
                        str(runs_root),
                        "--gputrace",
                        str(trace_dir),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            output_path = root / "compare.json"
            completed = subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a),
                    "--run-b",
                    str(run_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn(
                "gputrace attribution: runA=1 visible-attributed / 1 referenced-valid / 1 missing, "
                "runB=1 visible-attributed / 1 referenced-valid / 1 missing",
                completed.stdout,
            )
            report = json.loads(output_path.read_text(encoding="utf-8"))
            differences = report["comparison"]["snapshotComparison"]["differences"]
            difference_fields = {item["field"] for item in differences}
            self.assertIn("gputraceSummary.visibleMSLHashes", difference_fields)
            self.assertIn("gputraceSummary.referencedValidMSLHashes", difference_fields)
            self.assertIn("gputraceAttribution.attributedVisibleMSLHashes", difference_fields)
            self.assertIn("gputraceAttribution.attributedReferencedMSLHashes", difference_fields)
            self.assertIn("gputraceAttribution.visibleMSLContentSHA256", difference_fields)
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )

    def test_compare_capture_runs_reports_missing_breakdown_and_raw_short_hashes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            run_a = runs_root / "run-a" / "com.example.demo"
            run_b = runs_root / "run-b" / "com.example.demo"

            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            container_a = root / "container-run-a"
            make_container_run(container_a, aggregate_text, module_text)
            trace_a = root / "trace-run-a.gputrace"
            make_gputrace(
                trace_a,
                {"0123456789ABCDEF": aggregate_text},
                index_entries=["0123456789ABCDEF", "AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"],
            )
            subprocess.run(
                [
                    "python3",
                    str(SNAPSHOT_SCRIPT),
                    "--bundle-id",
                    "com.example.demo",
                    "--label",
                    "run-a",
                    "--container",
                    str(container_a),
                    "--output-root",
                    str(runs_root),
                    "--gputrace",
                    str(trace_a),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            container_b = root / "container-run-b"
            make_container_run(container_b, aggregate_text, module_text)
            trace_b = root / "trace-run-b.gputrace"
            make_gputrace(
                trace_b,
                {
                    "FEDCBA9876543210": aggregate_text,
                    "A123456789ABCD": b"bplist00\x00\x01\x02",
                },
                index_entries=["FEDCBA9876543210", "BBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCC", "A123456789ABCD"],
            )
            subprocess.run(
                [
                    "python3",
                    str(SNAPSHOT_SCRIPT),
                    "--bundle-id",
                    "com.example.demo",
                    "--label",
                    "run-b",
                    "--container",
                    str(container_b),
                    "--output-root",
                    str(runs_root),
                    "--gputrace",
                    str(trace_b),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            output_path = root / "compare-missing-breakdown.json"
            completed = subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a),
                    "--run-b",
                    str(run_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("gputrace missing delta: shared=1 onlyA=1 onlyB=1 net=+0", completed.stdout)
            self.assertIn("gputrace raw short-hash tokens: runA=0 runB=1 shared=0 onlyA=0 onlyB=1", completed.stdout)
            self.assertIn(
                "gputrace raw short-hash file writes: runA=0/0 visible (msl=0 nonMSL=0), runB=1/1 visible (msl=0 nonMSL=1), sharedVisible=0 onlyAVisible=0 onlyBVisible=1",
                completed.stdout,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            snapshot_comparison = report["comparison"]["snapshotComparison"]
            self.assertEqual(
                snapshot_comparison["missingReferencedHashBreakdown"],
                {
                    "runACount": 2,
                    "runBCount": 2,
                    "sharedCount": 1,
                    "onlyRunACount": 1,
                    "onlyRunBCount": 1,
                    "netCountDelta": 0,
                    "sharedHashes": ["BBBBBBBBBBBBBBBB"],
                    "onlyRunAHashes": ["AAAAAAAAAAAAAAAA"],
                    "onlyRunBHashes": ["CCCCCCCCCCCCCCCC"],
                },
            )
            self.assertEqual(
                snapshot_comparison["rawIndexNonCanonicalHashBreakdown"],
                {
                    "runACount": 0,
                    "runBCount": 1,
                    "sharedCount": 0,
                    "onlyRunACount": 0,
                    "onlyRunBCount": 1,
                    "netCountDelta": 1,
                    "sharedHashes": [],
                    "onlyRunAHashes": [],
                    "onlyRunBHashes": ["A123456789ABCD"],
                },
            )
            self.assertEqual(
                snapshot_comparison["rawIndexNonCanonicalVisibleHashBreakdown"],
                {
                    "runACount": 0,
                    "runBCount": 1,
                    "sharedCount": 0,
                    "onlyRunACount": 0,
                    "onlyRunBCount": 1,
                    "netCountDelta": 1,
                    "sharedHashes": [],
                    "onlyRunAHashes": [],
                    "onlyRunBHashes": ["A123456789ABCD"],
                },
            )
            self.assertEqual(report["runA"]["snapshotContext"]["rawIndexNonCanonicalHashes"], [])
            self.assertEqual(report["runB"]["snapshotContext"]["rawIndexNonCanonicalHashes"], ["A123456789ABCD"])
            self.assertEqual(report["runA"]["snapshotContext"]["rawIndexNonCanonicalVisibleHashes"], [])
            self.assertEqual(report["runB"]["snapshotContext"]["rawIndexNonCanonicalVisibleHashes"], ["A123456789ABCD"])
            self.assertEqual(report["runB"]["snapshotContext"]["rawIndexNonCanonicalOnlyHashes"], [])
            self.assertEqual(report["runB"]["snapshotContext"]["rawIndexNonCanonicalVisibleTypeCounts"], {"bplist": 1})
            self.assertEqual(
                report["runB"]["snapshotContext"]["rawIndexNonCanonicalVisibility"],
                {
                    "rawTokenCount": 1,
                    "visibleFileCount": 1,
                    "onlyInIndexCount": 0,
                    "visibleMSLCount": 0,
                    "visibleNonMSLCount": 1,
                },
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["nonCanonicalVisibleHashesMentionedInIndex"],
                ["A123456789ABCD"],
            )

    def test_compare_capture_runs_recomputes_attribution_for_older_snapshot_without_index(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            run_a = runs_root / "run-a" / "com.example.demo"
            run_b = runs_root / "run-b" / "com.example.demo"

            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            for bundle_dir, visible_hash in (
                (run_a, "0123456789ABCDEF"),
                (run_b, "FEDCBA9876543210"),
            ):
                container_root = root / f"container-{bundle_dir.parent.name}"
                make_container_run(container_root, aggregate_text, module_text)
                trace_dir = root / f"trace-{bundle_dir.parent.name}.gputrace"
                make_gputrace(trace_dir, {visible_hash: aggregate_text})
                subprocess.run(
                    [
                        "python3",
                        str(SNAPSHOT_SCRIPT),
                        "--bundle-id",
                        "com.example.demo",
                        "--label",
                        bundle_dir.parent.name,
                        "--container",
                        str(container_root),
                        "--output-root",
                        str(runs_root),
                        "--gputrace",
                        str(trace_dir),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            for bundle_dir in (run_a, run_b):
                attribution_path = bundle_dir / "gputrace-attribution-index.json"
                attribution_path.unlink()
                meta_path = bundle_dir / "snapshot.meta.json"
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                meta["copiedArtifacts"]["gputraceAttributionIndexPath"] = None
                meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")

            output_path = root / "compare-fallback.json"
            subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a),
                    "--run-b",
                    str(run_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedVisibleMSLHashes"],
                ["0123456789ABCDEF"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedVisibleMSLHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedReferencedMSLHashes"],
                ["0123456789ABCDEF"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedReferencedMSLHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["missingReferencedHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["missingReferencedHashes"],
                ["0123456789ABCDEF"],
            )

    def test_compare_capture_runs_recomputes_attribution_for_outdated_snapshot_index(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            run_a = runs_root / "run-a" / "com.example.demo"
            run_b = runs_root / "run-b" / "com.example.demo"

            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            for bundle_dir, visible_hash in (
                (run_a, "0123456789ABCDEF"),
                (run_b, "FEDCBA9876543210"),
            ):
                container_root = root / f"container-{bundle_dir.parent.name}"
                make_container_run(container_root, aggregate_text, module_text)
                trace_dir = root / f"trace-{bundle_dir.parent.name}.gputrace"
                make_gputrace(trace_dir, {visible_hash: aggregate_text})
                subprocess.run(
                    [
                        "python3",
                        str(SNAPSHOT_SCRIPT),
                        "--bundle-id",
                        "com.example.demo",
                        "--label",
                        bundle_dir.parent.name,
                        "--container",
                        str(container_root),
                        "--output-root",
                        str(runs_root),
                        "--gputrace",
                        str(trace_dir),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            for bundle_dir in (run_a, run_b):
                write_json(
                    bundle_dir / "gputrace-attribution-index.json",
                    {
                        "schemaVersion": 1,
                        "visibleMSLFileCount": 0,
                        "attributedVisibleMSLHashes": [],
                        "unattributedVisibleMSLHashes": [],
                        "attributedModuleKeys": [],
                        "attributedReplacementDirectories": [],
                    },
                )

            output_path = root / "compare-outdated-index.json"
            subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a),
                    "--run-b",
                    str(run_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedVisibleMSLHashes"],
                ["0123456789ABCDEF"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedVisibleMSLHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedReferencedMSLHashes"],
                ["0123456789ABCDEF"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedReferencedMSLHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["missingReferencedHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["missingReferencedHashes"],
                ["0123456789ABCDEF"],
            )

    def test_compare_capture_runs_recomputes_gputrace_summary_for_older_snapshot_meta(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            run_a = runs_root / "run-a" / "com.example.demo"
            run_b = runs_root / "run-b" / "com.example.demo"

            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            for bundle_dir, visible_hash, missing_hash in (
                (run_a, "0123456789ABCDEF", "FEDCBA9876543210"),
                (run_b, "FEDCBA9876543210", "0123456789ABCDEF"),
            ):
                container_root = root / f"container-{bundle_dir.parent.name}"
                make_container_run(container_root, aggregate_text, module_text)
                trace_dir = root / f"trace-{bundle_dir.parent.name}.gputrace"
                make_gputrace(trace_dir, {visible_hash: aggregate_text})
                (trace_dir / "index").write_bytes(f"{visible_hash} {missing_hash}".encode("ascii"))
                subprocess.run(
                    [
                        "python3",
                        str(SNAPSHOT_SCRIPT),
                        "--bundle-id",
                        "com.example.demo",
                        "--label",
                        bundle_dir.parent.name,
                        "--container",
                        str(container_root),
                        "--output-root",
                        str(runs_root),
                        "--gputrace",
                        str(trace_dir),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                meta_path = bundle_dir / "snapshot.meta.json"
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
                meta["gputraceSummary"] = {
                    "indexHashReferences": 2,
                    "sourceFiles": 1,
                    "validMSLFiles": 1,
                }
                meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")

            output_path = root / "compare-stale-summary.json"
            subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a),
                    "--run-b",
                    str(run_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(
                report["runA"]["snapshotContext"]["referencedValidMSLHashes"],
                ["0123456789ABCDEF"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["referencedValidMSLHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["missingReferencedHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["missingReferencedHashes"],
                ["0123456789ABCDEF"],
            )

    def test_compare_capture_runs_recomputes_attribution_even_when_saved_index_has_current_schema(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            run_a = runs_root / "run-a" / "com.example.demo"
            run_b = runs_root / "run-b" / "com.example.demo"

            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            for bundle_dir, visible_hash in (
                (run_a, "0123456789ABCDEF"),
                (run_b, "FEDCBA9876543210"),
            ):
                container_root = root / f"container-{bundle_dir.parent.name}"
                make_container_run(container_root, aggregate_text, module_text)
                trace_dir = root / f"trace-{bundle_dir.parent.name}.gputrace"
                make_gputrace(trace_dir, {visible_hash: aggregate_text})
                subprocess.run(
                    [
                        "python3",
                        str(SNAPSHOT_SCRIPT),
                        "--bundle-id",
                        "com.example.demo",
                        "--label",
                        bundle_dir.parent.name,
                        "--container",
                        str(container_root),
                        "--output-root",
                        str(runs_root),
                        "--gputrace",
                        str(trace_dir),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                write_json(
                    bundle_dir / "gputrace-attribution-index.json",
                    {
                        "schemaVersion": 999,
                        "visibleMSLFileCount": 1,
                        "attributedVisibleMSLHashes": [],
                        "unattributedVisibleMSLHashes": [visible_hash],
                        "attributedReferencedMSLHashes": [],
                        "unattributedReferencedMSLHashes": [visible_hash],
                        "attributedModuleKeys": [],
                        "attributedReplacementDirectories": [],
                        "visibleMSLContentSHA256": [],
                    },
                )

            output_path = root / "compare-current-schema-stale-index.json"
            subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a),
                    "--run-b",
                    str(run_b),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            report = json.loads(output_path.read_text(encoding="utf-8"))
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedVisibleMSLHashes"],
                ["0123456789ABCDEF"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedVisibleMSLHashes"],
                ["FEDCBA9876543210"],
            )
            self.assertEqual(
                report["runA"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )
            self.assertEqual(
                report["runB"]["snapshotContext"]["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )

    def test_compare_capture_runs_reports_latest_replacement_attempt_difference(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            run_a = root / "run-a"
            run_b = root / "run-b"
            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            make_container_run(run_a, aggregate_text, module_text, attempt_outcome="failed", attempt_reason_code="compile_failed")
            make_container_run(run_b, aggregate_text, module_text, attempt_outcome="failed", attempt_reason_code="preflight_rejected")

            output_path = root / "compare-attempts.json"
            completed = subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(run_a / "ShaderCorpus" / "com.example.demo"),
                    "--run-b",
                    str(run_b / "ShaderCorpus" / "com.example.demo"),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn("latest replacement attempt differs", completed.stdout)
            self.assertIn("replacement attempts: runA=failed/compile_failed runB=failed/preflight_rejected", completed.stdout)

            report = json.loads(output_path.read_text(encoding="utf-8"))
            difference_fields = {
                item["field"] for item in report["comparison"]["latestReplacementAttemptComparison"]["differences"]
            }
            self.assertEqual(report["runA"]["replacementAttemptSummary"]["latestReasonCode"], "compile_failed")
            self.assertEqual(report["runB"]["replacementAttemptSummary"]["latestReasonCode"], "preflight_rejected")
            self.assertIn("reasonCode", difference_fields)

    def test_compare_capture_runs_warns_when_attempts_missing_while_enabled(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            runs_root = root / "runs"
            aggregate_text = "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n#include <metal_stdlib>\n"
            module_text = "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n"

            for label in ("run-a", "run-b"):
                container_root = root / f"container-{label}"
                make_container_run(container_root, aggregate_text, module_text, attempt_outcome=None)
                subprocess.run(
                    [
                        "python3",
                        str(SNAPSHOT_SCRIPT),
                        "--bundle-id",
                        "com.example.demo",
                        "--label",
                        label,
                        "--container",
                        str(container_root),
                        "--output-root",
                        str(runs_root),
                    ],
                    cwd=REPO_ROOT,
                    check=True,
                    capture_output=True,
                    text=True,
                )

            output_path = root / "compare-missing-attempts.json"
            completed = subprocess.run(
                [
                    "python3",
                    str(COMPARE_SCRIPT),
                    "--run-a",
                    str(runs_root / "run-a" / "com.example.demo"),
                    "--run-b",
                    str(runs_root / "run-b" / "com.example.demo"),
                    "--output",
                    str(output_path),
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            self.assertIn(
                "replacement attempts missing while replacementEnabled=true for: runA, runB",
                completed.stdout,
            )
            report = json.loads(output_path.read_text(encoding="utf-8"))
            coverage = report["comparison"]["replacementAttemptCoverage"]
            self.assertEqual(coverage["missingWhenEnabled"], ["runA", "runB"])
            self.assertEqual(coverage["runAEnabledWithoutAttempt"], True)
            self.assertEqual(coverage["runBEnabledWithoutAttempt"], True)
            self.assertEqual(coverage["bothRunsMissingWhenEnabled"], True)


if __name__ == "__main__":
    unittest.main()
