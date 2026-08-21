#!/usr/bin/env python3
"""Refresh the parity-fixture provenance manifest.

The manifest is what stops a fixture expectation from being edited to match
Swift — the failure mode that hid a 50-point artist-scoring divergence until
slice 17. Run this ONLY after re-deriving expectations from Python, never to
make FixtureProvenanceTests go green.

    scripts/refresh-fixture-manifest.py
    scripts/refresh-fixture-manifest.py --generated-dir /tmp/regen

`--generated-dir` should hold independently regenerated fixture files. Fixture
sets marked `requiresGeneratedInput` reject an omitted or same-directory input
and require complete generated-file equality. Other sets preserve the existing
generated/verified split when the argument is omitted. `--fixtures-dir` selects
the fixture set; it defaults to the Core parity fixtures for compatibility.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

DEFAULT_FIXTURES = (
    Path(__file__).resolve().parent.parent / "Packages/Core/Tests/CoreTests/Fixtures"
)

COMMENT = (
    "Provenance of the Python parity fixtures. 'generated' cases are emitted by "
    "a checked-in generator that executes the real Python implementation. "
    "'verifiedByExecution' cases were hand-authored and later "
    "confirmed by feeding their inputs through the same Python entry points. "
    "digest covers the canonical (sorted-key, separator-normalized) file contents. "
    "Regenerate with scripts/refresh-fixture-manifest.py after any intentional change."
)


class ManifestError(ValueError):
    pass


def canonical(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def fixture_cases(data: object) -> list[object] | None:
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("cases"), list):
        return data["cases"]
    return None


def parse_arguments() -> tuple[argparse.ArgumentParser, Path | None, Path]:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated-dir", type=Path, default=None)
    parser.add_argument("--fixtures-dir", type=Path, default=DEFAULT_FIXTURES)
    arguments = parser.parse_args()
    return parser, arguments.generated_dir, arguments.fixtures_dir


def validate_generated_directory(
    fixtures: Path,
    generated: Path | None,
    is_required: bool,
) -> Path | None:
    if not is_required:
        return generated
    if generated is None:
        raise ManifestError("--generated-dir is required for this fixture set")
    if generated.resolve() == fixtures.resolve():
        raise ManifestError("--generated-dir must be independent from --fixtures-dir")
    return generated


def require_generated_match(
    fixture: Path,
    source: Path | None,
    fixture_data: object,
) -> None:
    if source is None:
        raise ManifestError(f"missing independently generated fixture: {fixture.name}")
    if not source.exists():
        raise ManifestError(f"missing independently generated fixture: {fixture.name}")
    if canonical(json.loads(source.read_text())) != canonical(fixture_data):
        raise ManifestError(f"generated fixture differs: {fixture.name}")


def matching_generated_count(source: Path, cases: list[object]) -> int:
    emitted_cases = fixture_cases(json.loads(source.read_text())) or []
    emitted = {canonical(case) for case in emitted_cases}
    return sum(canonical(case) in emitted for case in cases)


def load_manifest(path: Path) -> dict[str, object]:
    if not path.exists():
        return {}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ManifestError("fixture manifest must be an object")
    return value


def previous_generated_count(entry: object) -> int:
    if entry is None:
        return 0
    if not isinstance(entry, dict):
        raise ManifestError("fixture manifest entry must be an object")
    if "generated" not in entry:
        return 0
    value = entry["generated"]
    if not isinstance(value, int) or isinstance(value, bool):
        raise ManifestError("fixture manifest generated count must be an integer")
    if value < 0:
        raise ManifestError("fixture manifest generated count must not be negative")
    return value


def manifest_files(data: dict[str, object]) -> dict[str, object]:
    if "files" not in data:
        return {}
    value = data["files"]
    if not isinstance(value, dict):
        raise ManifestError("fixture manifest files must be an object")
    for entry in value.values():
        if entry is None:
            raise ManifestError("fixture manifest entry must be an object")
        previous_generated_count(entry)
    return value


def requires_generated_input(data: dict[str, object]) -> bool:
    if "requiresGeneratedInput" not in data:
        return False
    value = data["requiresGeneratedInput"]
    if not isinstance(value, bool):
        raise ManifestError("requiresGeneratedInput must be a boolean")
    return value


def generated_case_count(
    fixture: Path,
    fixture_data: object,
    cases: list[object],
    generated: Path | None,
    is_required: bool,
    previous_count: int,
) -> int:
    source = generated / fixture.name if generated is not None else None
    if is_required:
        require_generated_match(fixture, source, fixture_data)
        return len(cases)
    if source is not None and source.exists():
        return matching_generated_count(source, cases)
    return previous_count


def fixture_entry(
    fixture: Path,
    generated: Path | None,
    is_generated_required: bool,
    previous_entry: object,
) -> dict[str, object]:
    data = json.loads(fixture.read_text())
    entry: dict[str, object] = {
        "digest": f"sha256:{hashlib.sha256(canonical(data).encode()).hexdigest()}"
    }
    cases = fixture_cases(data)
    if cases is None:
        return entry

    previous_count = previous_generated_count(previous_entry)
    if previous_count > len(cases):
        raise ManifestError(
            f"fixture manifest generated count exceeds case count: {fixture.name}"
        )
    count = generated_case_count(
        fixture,
        data,
        cases,
        generated,
        is_generated_required,
        previous_count,
    )
    entry["caseCount"] = len(cases)
    entry["generated"] = count
    entry["verifiedByExecution"] = len(cases) - count
    return entry


def refreshed_manifest(
    previous: dict[str, object],
    files: dict[str, dict[str, object]],
) -> dict[str, object]:
    refreshed: dict[str, object] = {"_comment": COMMENT}
    for key in ("pythonBaseline", "requiresGeneratedInput"):
        if key in previous:
            refreshed[key] = previous[key]
    refreshed["files"] = files
    return refreshed


def main() -> None:
    parser, generated, fixtures = parse_arguments()
    manifest = fixtures / "fixtures_manifest.json"
    files: dict[str, dict[str, object]] = {}
    try:
        manifest_data = load_manifest(manifest)
        previous_files = manifest_files(manifest_data)
        is_generated_required = requires_generated_input(manifest_data)
        generated = validate_generated_directory(
            fixtures,
            generated,
            is_generated_required,
        )
        for fixture in sorted(fixtures.glob("*.json")):
            if fixture == manifest:
                continue
            previous_entry = previous_files.get(fixture.name)
            entry = fixture_entry(
                fixture,
                generated,
                is_generated_required,
                previous_entry,
            )
            files[fixture.name] = entry
            print(f"  {fixture.name}: {entry.get('caseCount', '-')} cases")
    except ManifestError as error:
        parser.error(str(error))

    refreshed = refreshed_manifest(manifest_data, files)
    manifest.write_text(json.dumps(refreshed, indent=2, ensure_ascii=False) + "\n")
    # relative_to raises when the cwd is not an ancestor — this script is meant
    # to be runnable from anywhere, including a CI wrapper or an editor.
    print(f"Wrote {os.path.relpath(manifest, Path.cwd())}")


if __name__ == "__main__":
    main()
