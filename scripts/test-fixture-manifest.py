#!/usr/bin/env python3
"""Regression tests for the fixture provenance manifest CLI."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = Path(
    os.environ.get(
        "FIXTURE_MANIFEST_SCRIPT",
        REPOSITORY_ROOT / "scripts/refresh-fixture-manifest.py",
    )
)
SERVICES_FIXTURES = (
    REPOSITORY_ROOT / "Packages/Services/Tests/ServicesTests/Fixtures"
)
CORE_FIXTURES = REPOSITORY_ROOT / "Packages/Core/Tests/CoreTests/Fixtures"


class ManifestCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def make_fixture_set(self, name: str, manifest: object) -> Path:
        fixtures = self.root / name
        fixtures.mkdir()
        (fixtures / "fixtures_manifest.json").write_text(json.dumps(manifest))
        (fixtures / "sample.json").write_text(
            json.dumps({"cases": [{"value": 1}]})
        )
        return fixtures

    @staticmethod
    def run_cli(
        fixtures: Path,
        generated: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        command = [sys.executable, str(SCRIPT), "--fixtures-dir", str(fixtures)]
        if generated is not None:
            command.extend(["--generated-dir", str(generated)])
        return subprocess.run(
            command,
            capture_output=True,
            check=False,
            text=True,
        )

    def assert_rejected_unchanged(
        self,
        fixtures: Path,
        generated: Path | None = None,
    ) -> None:
        manifest = fixtures / "fixtures_manifest.json"
        original = manifest.read_bytes()

        result = self.run_cli(fixtures, generated)

        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(manifest.read_bytes(), original)

    def test_malformed_manifest_fails_closed(self) -> None:
        malformed: dict[str, object] = {
            "top-level-null": None,
            "top-level-list": [],
            "files-null": {"files": None},
            "files-list": {"files": []},
            "entry-null": {"files": {"sample.json": None}},
            "entry-list": {"files": {"sample.json": []}},
            "generated-null": {"files": {"sample.json": {"generated": None}}},
            "generated-bool": {"files": {"sample.json": {"generated": True}}},
            "generated-string": {"files": {"sample.json": {"generated": "1"}}},
            "generated-negative": {"files": {"sample.json": {"generated": -1}}},
            "generated-too-large": {"files": {"sample.json": {"generated": 2}}},
            "required-null": {"requiresGeneratedInput": None},
            "required-string": {"requiresGeneratedInput": "true"},
        }

        for name, manifest in malformed.items():
            with self.subTest(name=name):
                fixtures = self.make_fixture_set(name, manifest)
                self.assert_rejected_unchanged(fixtures)

    def test_required_input_fails_closed(self) -> None:
        manifest = {
            "requiresGeneratedInput": True,
            "files": {"sample.json": {"generated": 1}},
        }
        cases = ("missing-argument", "same-directory", "missing-file", "mismatch")

        for name in cases:
            with self.subTest(name=name):
                fixtures = self.make_fixture_set(name, manifest)
                if name == "missing-argument":
                    generated = None
                elif name == "same-directory":
                    generated = fixtures
                elif name == "missing-file":
                    generated = self.root / f"{name}-generated"
                    generated.mkdir()
                else:
                    generated = self.root / f"{name}-generated"
                    generated.mkdir()
                    (generated / "sample.json").write_text(
                        json.dumps({"cases": [{"value": 2}]})
                    )
                self.assert_rejected_unchanged(fixtures, generated)

    def test_oversized_history_fails_closed(self) -> None:
        fixtures = self.make_fixture_set(
            "oversized-history",
            {
                "requiresGeneratedInput": True,
                "files": {"sample.json": {"generated": 2}},
            },
        )
        generated = self.root / "oversized-history-generated"
        generated.mkdir()
        shutil.copy(fixtures / "sample.json", generated / "sample.json")

        self.assert_rejected_unchanged(fixtures, generated)

    def test_services_exact_refresh(self) -> None:
        fixtures = self.root / "services"
        generated = self.root / "services-generated"
        shutil.copytree(SERVICES_FIXTURES, fixtures)
        generated.mkdir()
        shutil.copy(
            fixtures / "provider_acquisition_reference.json",
            generated / "provider_acquisition_reference.json",
        )
        manifest = fixtures / "fixtures_manifest.json"
        expected = manifest.read_bytes()

        result = self.run_cli(fixtures, generated)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(manifest.read_bytes(), expected)

    def test_core_refresh_preserves_legacy_provenance(self) -> None:
        fixtures = self.root / "core"
        shutil.copytree(CORE_FIXTURES, fixtures)
        manifest = fixtures / "fixtures_manifest.json"
        expected_files = json.loads(manifest.read_text())["files"]

        result = self.run_cli(fixtures)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(manifest.read_text())["files"], expected_files)


if __name__ == "__main__":
    unittest.main()
