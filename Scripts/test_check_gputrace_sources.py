from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
CHECK_SCRIPT = REPO_ROOT / "Scripts" / "check_gputrace_sources.py"
SNAPSHOT_SCRIPT = REPO_ROOT / "Scripts" / "snapshot_capture_run.py"



def make_gputrace(trace_dir: Path, files: dict[str, str | bytes], *, index_hashes: list[str]) -> None:
    trace_dir.mkdir(parents=True, exist_ok=True)
    for name, content in files.items():
        path = trace_dir / name
        if isinstance(content, bytes):
            path.write_bytes(content)
        else:
            path.write_text(content, encoding="utf-8")
    (trace_dir / "index").write_bytes(" ".join(index_hashes).encode("utf-8"))



def make_bundle_dir(bundle_dir: Path) -> None:
    module_dir = bundle_dir / "modules" / "module-key-1"
    replacement_dir = bundle_dir / "replacements" / "20260405_selector_cache"
    module_dir.mkdir(parents=True, exist_ok=True)
    replacement_dir.mkdir(parents=True, exist_ok=True)

    module_text = "#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1.0); }\n"
    aggregate_text = (
        "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n"
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "fragment float4 aggregate0() { return float4(1.0); }\n"
    )

    (module_dir / "module.generated.metal").write_text(module_text, encoding="utf-8")
    (replacement_dir / "aggregate.generated.metal").write_text(aggregate_text, encoding="utf-8")
    (replacement_dir / "replacement.meta.json").write_text(
        json.dumps({"moduleKeys": ["module-key-1"]}, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )



def make_snapshot_container(container_root: Path) -> None:
    bundle_id = "com.example.demo"
    corpus_dir = container_root / "ShaderCorpus" / bundle_id
    module_dir = corpus_dir / "modules" / "module-key-1"
    module_dir.mkdir(parents=True, exist_ok=True)

    (corpus_dir / "manifest.jsonl").write_text('{"event":"capture"}\n', encoding="utf-8")
    (module_dir / "module.bc").write_bytes(b"bc")
    (module_dir / "module.ll").write_text("; module\n", encoding="utf-8")
    (module_dir / "module.generated.metal").write_text(
        "#include <metal_stdlib>\nfragment float4 main0() { return float4(1.0); }\n",
        encoding="utf-8",
    )
    (module_dir / "module.meta.json").write_text("{}\n", encoding="utf-8")



class CheckGputraceSourcesTests(unittest.TestCase):
    def test_coverage_uses_valid_msl_files_instead_of_all_hex_files(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            trace_dir = root / "trace.gputrace"
            make_gputrace(
                trace_dir,
                {
                    "0123456789ABCDEF": "#include <metal_stdlib>\nusing namespace metal;\n",
                    "FEDCBA9876543210": b"bplist00\x00\x01\x02",
                },
                index_hashes=[
                    "0123456789ABCDEF",
                    "FEDCBA9876543210",
                    "AAAAAAAAAAAAAAAA",
                    "BBBBBBBBBBBBBBBB",
                ],
            )

            completed = subprocess.run(
                ["python3", str(CHECK_SCRIPT), str(trace_dir), "--json"],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            result = json.loads(completed.stdout)
            self.assertEqual(result["source_files"], 2)
            self.assertEqual(result["valid_msl_files"], 1)
            self.assertEqual(result["non_msl_files"], 1)
            self.assertEqual(result["index_hash_references"], 4)
            self.assertEqual(result["coverage_pct"], 25.0)
            self.assertEqual(result["referenced_valid_msl_hashes"], ["0123456789ABCDEF"])
            self.assertEqual(result["referenced_non_msl_hashes"], ["FEDCBA9876543210"])
            self.assertEqual(result["missing_referenced_hashes"], ["AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"])
            self.assertEqual(result["unreferenced_valid_msl_hashes"], [])
            self.assertEqual(result["unreferenced_non_msl_hashes"], [])
            self.assertEqual(result["source_hash_length_counts"], {"16": 2})
            self.assertEqual(result["index_hash_length_counts"], {"16": 4})
            self.assertEqual(result["non_msl_type_counts"], {"bplist": 1})
            self.assertEqual(result["files"]["FEDCBA9876543210"]["is_msl"], False)
            self.assertEqual(result["files"]["FEDCBA9876543210"]["content_type"], "bplist")
            self.assertEqual(result["files"]["FEDCBA9876543210"]["hash_length"], 16)

    def test_bundle_dir_enables_visible_msl_attribution(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bundle_dir = root / "com.example.demo"
            trace_dir = root / "trace.gputrace"
            make_bundle_dir(bundle_dir)

            aggregate_text = (
                "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n"
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "fragment float4 aggregate0() { return float4(1.0); }\n"
            )
            unmatched_text = "#include <metal_stdlib>\nusing namespace metal;\nfloat marker = 2.0;\n"
            make_gputrace(
                trace_dir,
                {
                    "0123456789ABCDEF": aggregate_text,
                    "FEDCBA9876543210": unmatched_text,
                },
                index_hashes=["0123456789ABCDEF", "FEDCBA9876543210"],
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(CHECK_SCRIPT),
                    str(trace_dir),
                    "--bundle-dir",
                    str(bundle_dir),
                    "--json",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            result = json.loads(completed.stdout)
            attribution = result["attribution"]
            self.assertEqual(attribution["visibleMSLFileCount"], 2)
            self.assertEqual(attribution["attributedVisibleMSLFileCount"], 1)
            self.assertEqual(attribution["unattributedVisibleMSLFileCount"], 1)
            self.assertEqual(attribution["referencedVisibleMSLFileCount"], 2)
            self.assertEqual(attribution["attributedReferencedMSLFileCount"], 1)
            self.assertEqual(attribution["unattributedReferencedMSLFileCount"], 1)
            self.assertEqual(attribution["attributedVisibleMSLHashes"], ["0123456789ABCDEF"])
            self.assertEqual(attribution["unattributedVisibleMSLHashes"], ["FEDCBA9876543210"])
            self.assertEqual(attribution["attributedReferencedMSLHashes"], ["0123456789ABCDEF"])
            self.assertEqual(attribution["unattributedReferencedMSLHashes"], ["FEDCBA9876543210"])
            self.assertEqual(attribution["attributedModuleKeys"], ["module-key-1"])
            self.assertEqual(
                attribution["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )

    def test_bundle_dir_attribution_ignores_trailing_nul_in_gputrace_source(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            bundle_dir = root / "com.example.demo"
            trace_dir = root / "trace.gputrace"
            make_bundle_dir(bundle_dir)

            aggregate_text = (
                "// Auto-generated aggregated MSL source by PlayTools LibrarySourceInjection\n"
                "#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "fragment float4 aggregate0() { return float4(1.0); }\n"
            )
            make_gputrace(
                trace_dir,
                {
                    "0123456789ABCDEF": aggregate_text.encode("utf-8") + b"\x00",
                },
                index_hashes=["0123456789ABCDEF"],
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(CHECK_SCRIPT),
                    str(trace_dir),
                    "--bundle-dir",
                    str(bundle_dir),
                    "--json",
                ],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            result = json.loads(completed.stdout)
            attribution = result["attribution"]
            self.assertEqual(attribution["attributedVisibleMSLHashes"], ["0123456789ABCDEF"])
            self.assertEqual(attribution["attributedReferencedMSLHashes"], ["0123456789ABCDEF"])
            self.assertEqual(attribution["unattributedVisibleMSLHashes"], [])
            self.assertEqual(attribution["unattributedReferencedMSLHashes"], [])
            self.assertEqual(attribution["attributedModuleKeys"], ["module-key-1"])
            self.assertEqual(
                attribution["attributedReplacementDirectories"],
                ["replacements/20260405_selector_cache"],
            )

    def test_short_hex_hashes_are_counted_and_classified(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            trace_dir = root / "trace.gputrace"
            make_gputrace(
                trace_dir,
                {
                    "A123456789ABCD": b"bplist00\x00\x01\x02",
                    "B123456789ABCDE": b"bplist00\x00\x01\x02",
                    "0123456789ABCDEF": "#include <metal_stdlib>\nusing namespace metal;\n",
                },
                index_hashes=[
                    "A123456789ABCD",
                    "B123456789ABCDE",
                    "0123456789ABCDEF",
                    "AAAAAAAAAAAAAAAA",
                ],
            )

            completed = subprocess.run(
                ["python3", str(CHECK_SCRIPT), str(trace_dir), "--json"],
                cwd=REPO_ROOT,
                check=True,
                capture_output=True,
                text=True,
            )

            result = json.loads(completed.stdout)
            self.assertEqual(result["source_files"], 3)
            self.assertEqual(result["index_hash_references"], 2)
            self.assertEqual(result["referenced_non_msl_hashes"], [])
            self.assertEqual(result["missing_referenced_hashes"], ["AAAAAAAAAAAAAAAA"])
            self.assertEqual(result["source_hash_length_counts"], {"14": 1, "15": 1, "16": 1})
            self.assertEqual(result["index_hash_length_counts"], {"16": 2})
            self.assertEqual(result["raw_index_hash_length_counts"], {"14": 1, "15": 1, "16": 2})
            self.assertEqual(result["noncanonical_visible_hashes"], ["A123456789ABCD", "B123456789ABCDE"])
            self.assertEqual(
                result["noncanonical_visible_hashes_mentioned_in_index"],
                ["A123456789ABCD", "B123456789ABCDE"],
            )
            self.assertEqual(result["raw_index_noncanonical_hashes"], ["A123456789ABCD", "B123456789ABCDE"])
            self.assertEqual(result["non_msl_type_counts"], {"bplist": 2})
            self.assertEqual(result["files"]["A123456789ABCD"]["content_type"], "bplist")
            self.assertEqual(result["files"]["A123456789ABCD"]["hash_length"], 14)
            self.assertEqual(result["files"]["B123456789ABCDE"]["hash_length"], 15)

    def test_snapshot_capture_uses_same_valid_msl_coverage_rule(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            container_root = root / "container"
            output_root = root / "snapshots"
            trace_dir = root / "trace.gputrace"
            make_snapshot_container(container_root)
            make_gputrace(
                trace_dir,
                {
                    "0123456789ABCDEF": "#include <metal_stdlib>\nusing namespace metal;\n",
                    "FEDCBA9876543210": b"bplist00\x00\x01\x02",
                },
                index_hashes=[
                    "0123456789ABCDEF",
                    "FEDCBA9876543210",
                    "AAAAAAAAAAAAAAAA",
                    "BBBBBBBBBBBBBBBB",
                ],
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

            meta_path = output_root / "run-a" / "com.example.demo" / "snapshot.meta.json"
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            summary = meta["gputraceSummary"]
            self.assertEqual(summary["sourceFiles"], 2)
            self.assertEqual(summary["validMSLFiles"], 1)
            self.assertEqual(summary["nonMSLFiles"], 1)
            self.assertEqual(summary["indexHashReferences"], 4)
            self.assertEqual(summary["referencedValidMSLHashes"], ["0123456789ABCDEF"])
            self.assertEqual(summary["referencedNonMSLHashes"], ["FEDCBA9876543210"])
            self.assertEqual(summary["missingReferencedHashes"], ["AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"])
            self.assertEqual(summary["sourceHashLengthCounts"], {"16": 2})
            self.assertEqual(summary["indexHashLengthCounts"], {"16": 4})
            self.assertEqual(summary["rawIndexHashLengthCounts"], {"16": 4})
            self.assertEqual(summary["rawIndexNonCanonicalHashes"], [])
            self.assertEqual(summary["nonMSLTypeCounts"], {"bplist": 1})
            self.assertEqual(summary["coveragePct"], 25.0)


if __name__ == "__main__":
    unittest.main()
