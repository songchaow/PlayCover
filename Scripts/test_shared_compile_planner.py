from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "Scripts"
SHARED_COMPILE_PLANNER_SWIFT = (
    REPO_ROOT
    / "Carthage"
    / "Checkouts"
    / "PlayTools"
    / "PlayTools"
    / "SharedCompilePlanner.swift"
)

if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

import corpus_replay_runner as replay_runner


HARNESS_SWIFT = textwrap.dedent(
    """
    import Foundation

    @main
    struct SharedCompilePlannerHarnessMain {
        static func main() throws {
            guard CommandLine.arguments.count == 2 else {
                fputs("usage: SharedCompilePlannerHarnessMain <input.json>\\n", stderr)
                exit(2)
            }

            let inputPath = CommandLine.arguments[1]
            let inputData = try Data(contentsOf: URL(fileURLWithPath: inputPath))
            let input = try JSONDecoder().decode(SharedCompilePlannerInput.self, from: inputData)
            let plan = SharedCompilePlanner.makePlan(input: input)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let outputData = try encoder.encode(plan)
            FileHandle.standardOutput.write(outputData)
        }
    }
    """
)


@unittest.skipUnless(shutil.which("swiftc"), "requires swiftc")
class SharedCompilePlannerTests(unittest.TestCase):
    def run_shared_compile_planner(
        self,
        *,
        original_ir_texts: list[str],
        user_metal_args: list[str] | None = None,
        requested_backend: str = "xcrun",
    ) -> dict:
        payload = {
            "originalIRTexts": list(original_ir_texts),
            "userMetalArgs": list(user_metal_args or []),
            "requestedBackend": requested_backend,
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            input_path = root / "planner-input.json"
            harness_path = root / "SharedCompilePlannerHarnessMain.swift"
            binary_path = root / "shared_compile_planner_harness"
            input_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
            harness_path.write_text(HARNESS_SWIFT, encoding="utf-8")

            subprocess.run(
                ["swiftc", str(SHARED_COMPILE_PLANNER_SWIFT), str(harness_path), "-o", str(binary_path)],
                check=True,
                capture_output=True,
                text=True,
            )
            completed = subprocess.run(
                [str(binary_path), str(input_path)],
                check=True,
                capture_output=True,
                text=True,
            )
        return json.loads(completed.stdout)

    def test_python_manifest_loader_points_to_shared_compile_planner(self) -> None:
        self.assertEqual(
            replay_runner.shared_compile_decision_manifest_path().resolve(),
            SHARED_COMPILE_PLANNER_SWIFT.resolve(),
        )
        manifest = replay_runner.load_shared_compile_decision_manifest()
        self.assertEqual(manifest["fastMath"]["enableOption"], "air.compile.fast_math_enable")
        self.assertEqual(manifest["fastMath"]["disableOption"], "air.compile.fast_math_disable")

    def test_swift_shared_compile_planner_covers_current_fast_math_reason_codes(self) -> None:
        enable_ir = '!1 = !{!"air.compile.fast_math_enable"}\n'
        disable_ir = '!1 = !{!"air.compile.fast_math_disable"}\n'
        unknown_ir = '; no compile options\n'
        cases = [
            {
                "name": "aligned_enable",
                "requested_backend": "mtl-device",
                "original_ir_texts": [enable_ir],
                "user_metal_args": [],
                "expected_reason": "fast_math_aligned",
                "expected_mode": "enable",
                "expected_inferred": ["-ffast-math"],
                "expected_effective": ["-ffast-math"],
                "expected_explicit": True,
                "expected_fast_math_enabled": True,
                "expected_override_source": None,
            },
            {
                "name": "aligned_disable",
                "requested_backend": "mtl-device",
                "original_ir_texts": [disable_ir],
                "user_metal_args": [],
                "expected_reason": "fast_math_aligned",
                "expected_mode": "disable",
                "expected_inferred": ["-fno-fast-math"],
                "expected_effective": ["-fno-fast-math"],
                "expected_explicit": True,
                "expected_fast_math_enabled": False,
                "expected_override_source": None,
            },
            {
                "name": "conflict",
                "requested_backend": "xcrun",
                "original_ir_texts": [enable_ir, disable_ir],
                "user_metal_args": [],
                "expected_reason": "fast_math_conflict",
                "expected_mode": None,
                "expected_inferred": [],
                "expected_effective": [],
                "expected_explicit": False,
                "expected_fast_math_enabled": None,
                "expected_override_source": None,
            },
            {
                "name": "partial",
                "requested_backend": "xcrun",
                "original_ir_texts": [enable_ir, unknown_ir],
                "user_metal_args": [],
                "expected_reason": "fast_math_partial",
                "expected_mode": None,
                "expected_inferred": [],
                "expected_effective": [],
                "expected_explicit": False,
                "expected_fast_math_enabled": None,
                "expected_override_source": None,
            },
            {
                "name": "unavailable",
                "requested_backend": "xcrun",
                "original_ir_texts": [unknown_ir],
                "user_metal_args": ["-std=metal3.1"],
                "expected_reason": "fast_math_unavailable",
                "expected_mode": None,
                "expected_inferred": [],
                "expected_effective": ["-std=metal3.1"],
                "expected_explicit": False,
                "expected_fast_math_enabled": None,
                "expected_override_source": None,
            },
            {
                "name": "user_override",
                "requested_backend": "mtl-device",
                "original_ir_texts": [enable_ir],
                "user_metal_args": ["-fno-fast-math", "-std=metal3.1"],
                "expected_reason": "user_override",
                "expected_mode": "disable",
                "expected_inferred": [],
                "expected_effective": ["-fno-fast-math", "-std=metal3.1"],
                "expected_explicit": True,
                "expected_fast_math_enabled": False,
                "expected_override_source": "user_metal_args",
            },
        ]

        for case in cases:
            with self.subTest(case=case["name"]):
                plan = self.run_shared_compile_planner(
                    original_ir_texts=case["original_ir_texts"],
                    user_metal_args=case["user_metal_args"],
                    requested_backend=case["requested_backend"],
                )

                self.assertEqual(plan["requestedBackend"], case["requested_backend"])
                self.assertEqual(plan["inferredMetalArgs"], case["expected_inferred"])
                self.assertEqual(plan["effectiveMetalArgs"], case["expected_effective"])

                decision = plan["decision"]
                self.assertEqual(decision["reason"], case["expected_reason"])
                self.assertEqual(decision["fastMathDecision"], case["expected_reason"])
                self.assertEqual(decision.get("fastMathMode"), case["expected_mode"])
                self.assertEqual(decision["usesExplicitCompileOptions"], case["expected_explicit"])
                self.assertEqual(decision.get("compileOptionsFastMathEnabled"), case["expected_fast_math_enabled"])
                self.assertEqual(decision.get("explicitOverrideSource"), case["expected_override_source"])

                payload = plan.get("mtlCompileOptionsPayload")
                if case["expected_fast_math_enabled"] is None:
                    self.assertIsNone(payload)
                else:
                    self.assertEqual(payload, {"fastMathEnabled": case["expected_fast_math_enabled"]})


if __name__ == "__main__":
    unittest.main()
