#!/usr/bin/env python3
"""Refresh the parity-fixture provenance manifest.

The manifest is what stops a fixture expectation from being edited to match
Swift — the failure mode that hid a 50-point artist-scoring divergence until
slice 17. Run this ONLY after re-deriving expectations from Python, never to
make FixtureProvenanceTests go green.

    scripts/refresh-fixture-manifest.py
    scripts/refresh-fixture-manifest.py --generated-dir /tmp/regen

`--generated-dir` should hold independently regenerated fixture files. Without
it the generated/verified split is carried over from the existing manifest,
and only digests and counts refresh. `--fixtures-dir` selects the fixture set;
it defaults to the Core parity fixtures for backward compatibility.
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


def canonical(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def fixture_cases(data: object) -> list[object] | None:
    if isinstance(data, list):
        return data
    if isinstance(data, dict) and isinstance(data.get("cases"), list):
        return data["cases"]
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated-dir", type=Path, default=None)
    parser.add_argument("--fixtures-dir", type=Path, default=DEFAULT_FIXTURES)
    arguments = parser.parse_args()
    generated_dir: Path | None = arguments.generated_dir
    fixtures: Path = arguments.fixtures_dir
    manifest = fixtures / "fixtures_manifest.json"

    previous = json.loads(manifest.read_text())["files"] if manifest.exists() else {}
    files: dict[str, dict[str, object]] = {}

    for path in sorted(fixtures.glob("*.json")):
        if path.name == manifest.name:
            continue
        data = json.loads(path.read_text())
        entry: dict[str, object] = {
            "digest": f"sha256:{hashlib.sha256(canonical(data).encode()).hexdigest()}"
        }

        cases = fixture_cases(data)
        if cases is not None:
            entry["caseCount"] = len(cases)
            source = generated_dir / path.name if generated_dir is not None else None
            if source is not None and source.exists():
                emitted_cases = fixture_cases(json.loads(source.read_text())) or []
                emitted = {canonical(case) for case in emitted_cases}
                generated_count = sum(canonical(case) in emitted for case in cases)
            else:
                generated_count = int(previous.get(path.name, {}).get("generated", 0))
            entry["generated"] = generated_count
            entry["verifiedByExecution"] = len(cases) - generated_count

        files[path.name] = entry
        print(f"  {path.name}: {entry.get('caseCount', '-')} cases")

    manifest.write_text(
        json.dumps({"_comment": COMMENT, "files": files}, indent=2, ensure_ascii=False)
        + "\n"
    )
    # relative_to raises when the cwd is not an ancestor — this script is meant
    # to be runnable from anywhere, including a CI wrapper or an editor.
    print(f"Wrote {os.path.relpath(manifest, Path.cwd())}")


if __name__ == "__main__":
    main()
