#!/usr/bin/env python3
"""Refresh the parity-fixture provenance manifest.

The manifest is what stops a fixture expectation from being edited to match
Swift — the failure mode that hid a 50-point artist-scoring divergence until
slice 17. Run this ONLY after re-deriving expectations from Python, never to
make FixtureProvenanceTests go green.

    scripts/refresh-fixture-manifest.py
    scripts/refresh-fixture-manifest.py --generated-dir /tmp/regen

`--generated-dir` should hold the output of the Python repo's
tools/generate_swift_fixtures.py. Without it the generated/verified split is
carried over from the existing manifest, and only digests and counts refresh.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

FIXTURES = (
    Path(__file__).resolve().parent.parent / "Packages/Core/Tests/CoreTests/Fixtures"
)
MANIFEST = FIXTURES / "fixtures_manifest.json"

COMMENT = (
    "Provenance of the Python parity fixtures. 'generated' cases are emitted by "
    "tools/generate_swift_fixtures.py in the Python repo, which executes the real "
    "implementation. 'verifiedByExecution' cases were hand-authored and later "
    "confirmed by feeding their inputs through the same Python entry points. "
    "digest covers the canonical (sorted-key, separator-normalized) file contents. "
    "Regenerate with scripts/refresh-fixture-manifest.py after any intentional change."
)


def canonical(obj: object) -> str:
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generated-dir", type=Path, default=None)
    generated_dir = parser.parse_args().generated_dir

    previous = json.loads(MANIFEST.read_text())["files"] if MANIFEST.exists() else {}
    files: dict[str, dict] = {}

    for path in sorted(FIXTURES.glob("*.json")):
        if path.name == MANIFEST.name:
            continue
        data = json.loads(path.read_text())
        entry: dict[str, object] = {
            "digest": f"sha256:{hashlib.sha256(canonical(data).encode()).hexdigest()}"
        }

        if isinstance(data, list):
            entry["caseCount"] = len(data)
            source = generated_dir / path.name if generated_dir else None
            if source and source.exists():
                emitted = {canonical(case) for case in json.loads(source.read_text())}
                entry["generated"] = sum(canonical(case) in emitted for case in data)
            else:
                entry["generated"] = previous.get(path.name, {}).get("generated", 0)
            entry["verifiedByExecution"] = len(data) - int(entry["generated"])

        files[path.name] = entry
        print(f"  {path.name}: {entry.get('caseCount', '-')} cases")

    MANIFEST.write_text(
        json.dumps({"_comment": COMMENT, "files": files}, indent=2, ensure_ascii=False)
        + "\n"
    )
    # relative_to raises when the cwd is not an ancestor — this script is meant
    # to be runnable from anywhere, including a CI wrapper or an editor.
    print(f"Wrote {os.path.relpath(MANIFEST, Path.cwd())}")


if __name__ == "__main__":
    main()
