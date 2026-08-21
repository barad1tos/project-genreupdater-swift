#!/usr/bin/env python3
"""Generate the Services provider-acquisition parity fixture from Python.

The supplied Python checkout identifies the source-of-truth Git repository.
Generation executes an isolated archive of the pinned commit, so local tracked
or untracked changes cannot affect the fixture. Requests are scripted; no live
network access or provider credentials are used.

Usage:
    scripts/generate-provider-fixture.py --python-root /path/to/python-repo \
        --manifest Packages/Services/Tests/ServicesTests/Fixtures/fixtures_manifest.json \
        --output Packages/Services/Tests/ServicesTests/Fixtures/provider_acquisition_reference.json
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import importlib
import io
import json
import logging
import sys
import tarfile
import tempfile
from collections import defaultdict, deque
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


ARTIST_QUERY = "björk"
ARTIST_DISPLAY = "Björk"
ALBUM_QUERY = "homogenic"
ALBUM_DISPLAY = "Homogenic"

CASE_INPUT = {
    "artist": ARTIST_QUERY,
    "album": ALBUM_QUERY,
    "artistRegion": "IS",
}

SCRIPTED_RESPONSES: dict[str, list[dict[str, Any]]] = {
    "musicbrainz": [
        {"statusCode": 200, "body": {"count": 0, "release-groups": []}},
        {
            "statusCode": 200,
            "body": {
                "count": 2,
                "release-groups": [
                    {
                        "id": "mb-unrelated",
                        "title": ALBUM_DISPLAY,
                        "first-release-date": "1997-01-01",
                        "primary-type": "Album",
                        "artist-credit": [
                            {
                                "name": "Another Artist",
                                "artist": {"name": "Another Artist"},
                            }
                        ],
                    },
                    {
                        "id": "mb-homogenic",
                        "title": ALBUM_DISPLAY,
                        "first-release-date": "1997-09-22",
                        "primary-type": "Album",
                        "artist-credit": [
                            {
                                "name": ARTIST_DISPLAY,
                                "artist": {"name": ARTIST_DISPLAY},
                            }
                        ],
                    },
                ],
            },
        },
        {
            "statusCode": 200,
            "body": {
                "releases": [
                    {
                        "id": "mb-release-homogenic",
                        "title": ALBUM_DISPLAY,
                        "date": "1997-09-22",
                        "status": "Official",
                        "artist-credit": [
                            {
                                "name": ARTIST_DISPLAY,
                                "artist": {"name": ARTIST_DISPLAY},
                            }
                        ],
                        "media": [{"format": "CD"}],
                    }
                ]
            },
        },
    ],
    "discogs": [
        {"statusCode": 200, "body": {"pagination": {"items": 0}, "results": []}},
        {"statusCode": 200, "body": {"pagination": {"items": 0}, "results": []}},
        {
            "statusCode": 200,
            "body": {
                "results": [
                    {
                        "id": 200,
                        "type": "release",
                        "title": f"{ARTIST_DISPLAY} - {ALBUM_DISPLAY}",
                        "year": 2001,
                        "country": "IS",
                        "genre": ["Electronic"],
                        "formats": [{"name": "CD", "descriptions": ["Album"]}],
                        "format": ["Album"],
                        "master_id": 100,
                    }
                ]
            },
        },
        {
            "statusCode": 200,
            "body": {
                "id": 100,
                "title": ALBUM_DISPLAY,
                "year": 1997,
                "genres": ["Electronic"],
            },
        },
    ],
    "itunes": [
        {"statusCode": 200, "body": {"resultCount": 0, "results": []}},
        {
            "statusCode": 200,
            "body": {
                "resultCount": 1,
                "results": [
                    {
                        "wrapperType": "artist",
                        "artistName": ARTIST_QUERY,
                        "artistId": 42,
                    }
                ],
            },
        },
        {
            "statusCode": 200,
            "body": {
                "resultCount": 2,
                "results": [
                    {
                        "wrapperType": "artist",
                        "artistName": ARTIST_DISPLAY,
                        "artistId": 42,
                    },
                    {
                        "wrapperType": "collection",
                        "artistName": ARTIST_DISPLAY,
                        "collectionName": ALBUM_DISPLAY,
                        "releaseDate": "1997-09-22T00:00:00Z",
                        "collectionType": "Album",
                        "country": "US",
                        "primaryGenreName": "Electronic",
                    },
                ],
            },
        },
    ],
}

SCENARIO: dict[str, object] = {
    "id": "all_provider_fallbacks",
    "description": "All providers recover through their broad acquisition paths",
    "input": CASE_INPUT,
    "scriptedResponses": SCRIPTED_RESPONSES,
}


class ScriptedRequests:
    """Provider-local FIFO transport that records production requests."""

    def __init__(self, responses: dict[str, list[dict[str, Any]]]) -> None:
        self._responses = {provider: deque(values) for provider, values in responses.items()}
        self.requests: dict[str, list[dict[str, Any]]] = defaultdict(list)

    async def __call__(
        self,
        api_name: str,
        url: str,
        params: dict[str, object] | None = None,
        **policy: object,
    ) -> dict[str, Any] | None:
        parsed = urlparse(url)
        query = [
            {"name": str(name), "value": str(value)}
            for name, value in sorted((params or {}).items())
        ]
        self.requests[api_name].append(
            {
                "scheme": parsed.scheme,
                "host": parsed.hostname,
                "port": parsed.port,
                "path": parsed.path.rstrip("/") or "/",
                "query": query,
            }
        )

        queue = self._responses.get(api_name)
        if queue is None or not queue:
            raise RuntimeError(
                f"unexpected {api_name} request #{len(self.requests[api_name])}: {url}"
            )
        response = queue.popleft()
        if int(response["statusCode"]) < 200 or int(response["statusCode"]) >= 300:
            return None
        return copy.deepcopy(response["body"])

    def assert_consumed(self) -> None:
        if unused := {
            provider: len(values)
            for provider, values in self._responses.items()
            if values
        }:
            raise RuntimeError(f"unused scripted responses: {unused}")


class FixtureCache:
    def __init__(self) -> None:
        self._values: dict[str, object] = {}
        self._lock = asyncio.Lock()

    async def get_async(self, key: str) -> object | None:
        async with self._lock:
            return self._values.get(key)

    async def set_async(self, key: str, value: object, ttl: float | None = None) -> None:
        del ttl
        async with self._lock:
            self._values[key] = value


class PassthroughAnalytics:
    @staticmethod
    async def execute_async_wrapped_call(
        function: Any,
        event_type: str,
        *args: object,
        **kwargs: object,
    ) -> object:
        del event_type
        return await function(*args, **kwargs)


def accept_candidate(*args: object, **kwargs: object) -> float:
    """Keep acquisition independent from Domain 8 scoring."""
    del args, kwargs
    return 100.0


def canonical_python_candidate(candidate: dict[str, Any]) -> dict[str, Any]:
    """Represent Python's empty country as Swift's absent optional value."""
    canonical = dict(candidate)
    if canonical.get("country") == "":
        canonical["country"] = None
    return canonical


def reviewed_divergences() -> dict[str, list[dict[str, object]]]:
    return {
        "requests": [
            {
                "source": "itunes",
                "requestIndex": 0,
                "queryName": "limit",
                "pythonValue": "50",
                "swiftValue": "200",
                "reason": "Swift favors direct-search recall over Python's smaller response payload",
            }
        ],
        "candidates": [
            {
                "candidateIndex": 0,
                "field": "mbReleaseGroupID",
                "pythonValue": None,
                "swiftValue": "mb-homogenic",
                "reason": "Swift retains MusicBrainz release-group identity for downstream evidence",
            },
            {
                "candidateIndex": 0,
                "field": "mbReleaseGroupFirstYear",
                "pythonValue": None,
                "swiftValue": 1997,
                "reason": "Swift retains the MusicBrainz release-group first year",
            },
            {
                "candidateIndex": 1,
                "field": "artist",
                "pythonValue": ARTIST_DISPLAY,
                "swiftValue": ARTIST_QUERY,
                "reason": "Swift preserves the normalized query artist for Discogs candidates",
            },
            {
                "candidateIndex": 1,
                "field": "releaseType",
                "pythonValue": "other",
                "swiftValue": "album",
                "reason": "Swift derives the Discogs release type from format evidence",
            },
            {
                "candidateIndex": 1,
                "field": "country",
                "pythonValue": "IS",
                "swiftValue": "is",
                "reason": "Swift canonicalizes Discogs country codes to lowercase",
            },
            {
                "candidateIndex": 1,
                "field": "genre",
                "pythonValue": None,
                "swiftValue": "Electronic",
                "reason": "Swift retains Discogs genre evidence",
            },
            {
                "candidateIndex": 2,
                "field": "country",
                "pythonValue": "US",
                "swiftValue": "us",
                "reason": "Swift canonicalizes iTunes country codes to lowercase",
            },
        ],
    }


async def git_bytes(python_root: Path, *arguments: str) -> bytes:
    process = await asyncio.create_subprocess_exec(
        "git",
        "-C",
        str(python_root),
        *arguments,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(f"git {' '.join(arguments)} failed: {stderr.decode().strip()}")
    return stdout


async def git_output(python_root: Path, *arguments: str) -> str:
    return (await git_bytes(python_root, *arguments)).decode().strip()


async def verify_python_checkout(python_root: Path, expected_baseline: str) -> str:
    baseline = await git_output(python_root, "rev-parse", "HEAD")
    if baseline != expected_baseline:
        raise RuntimeError(
            f"Python baseline mismatch: expected {expected_baseline}, found {baseline}"
        )

    return baseline


async def generate(python_root: Path, expected_baseline: str) -> dict[str, object]:
    baseline = await verify_python_checkout(python_root, expected_baseline)
    archive = await git_bytes(python_root, "archive", "--format=tar", expected_baseline)
    with tempfile.TemporaryDirectory(prefix="genreupdater-python-") as directory:
        source_root = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source_archive:
            source_archive.extractall(source_root, filter="data")
        fixture = await build_fixture(source_root, baseline)

    if await verify_python_checkout(python_root, expected_baseline) != baseline:
        raise RuntimeError("Python HEAD changed during fixture generation")
    return fixture


async def build_fixture(python_root: Path, baseline: str) -> dict[str, object]:
    sys.path.insert(0, str(python_root))
    sys.path.insert(0, str(python_root / "src"))

    yaml_module = importlib.import_module("yaml")
    app_config_type = getattr(
        importlib.import_module("core.models.track_models"),
        "AppConfig",
    )
    apple_music_type = getattr(
        importlib.import_module("services.api.applemusic"),
        "AppleMusicClient",
    )
    discogs_type = getattr(
        importlib.import_module("services.api.discogs"),
        "DiscogsClient",
    )
    musicbrainz_type = getattr(
        importlib.import_module("services.api.musicbrainz"),
        "MusicBrainzClient",
    )
    release_scorer_type = getattr(
        importlib.import_module("services.api.year_scoring"),
        "ReleaseScorer",
    )
    coordinator_type = getattr(
        importlib.import_module("services.api.year_search_coordinator"),
        "YearSearchCoordinator",
    )
    build_release_fixture = getattr(
        importlib.import_module("tools.generate_swift_fixtures"),
        "_build_release_fixture",
    )

    configuration = app_config_type.model_validate(
        getattr(yaml_module, "safe_load")(
            (python_root / "config.yaml").read_text(encoding="utf-8")
        )
    )
    logger = logging.getLogger("provider_fixture")
    logger.handlers = [logging.NullHandler()]
    analytics = PassthroughAnalytics()
    requests = ScriptedRequests(SCRIPTED_RESPONSES)
    score = accept_candidate

    musicbrainz = musicbrainz_type(logger, logger, requests, score, analytics)
    discogs = discogs_type(
        "fixture-token",
        logger,
        logger,
        analytics,
        requests,
        score_release_func=score,
        cache_service=FixtureCache(),
        scoring_config=configuration.year_retrieval,
        config=configuration,
        cache_ttl_days=configuration.year_retrieval.processing.cache_ttl_days,
    )
    itunes = apple_music_type(logger, logger, requests, score)
    scorer = release_scorer_type(
        scoring_config=configuration.year_retrieval.scoring,
        min_valid_year=configuration.year_retrieval.logic.min_valid_year,
        definitive_score_threshold=configuration.year_retrieval.logic.definitive_score_threshold,
        console_logger=logger,
        remaster_keywords=configuration.cleaning.remaster_keywords,
        major_market_codes=configuration.year_retrieval.logic.major_market_codes,
    )
    coordinator = coordinator_type(
        console_logger=logger,
        error_logger=logger,
        config=configuration,
        preferred_api="musicbrainz",
        musicbrainz_client=musicbrainz,
        discogs_client=discogs,
        applemusic_client=itunes,
        release_scorer=scorer,
        max_concurrent_api_calls=2,
    )

    releases = await coordinator.fetch_all_api_results(
        CASE_INPUT["artist"],
        CASE_INPUT["album"],
        CASE_INPUT["artistRegion"],
        ARTIST_DISPLAY,
        ALBUM_DISPLAY,
    )
    requests.assert_consumed()
    python_candidates = [
        canonical_python_candidate(build_release_fixture(release))
        for release in releases
    ]
    python_requests = dict(requests.requests)
    return {
        "schemaVersion": 2,
        "pythonBaseline": baseline,
        "cases": [
            {
                **SCENARIO,
                "expected": {
                    "pythonRequests": python_requests,
                    "candidateSourceOrder": [
                        candidate["source"] for candidate in python_candidates
                    ],
                    "pythonCandidates": python_candidates,
                },
                "divergences": reviewed_divergences(),
            }
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    arguments = parser.parse_args()

    python_root = arguments.python_root.resolve(strict=True)
    output = arguments.output.resolve()
    manifest = json.loads(arguments.manifest.resolve(strict=True).read_text(encoding="utf-8"))
    expected_baseline = str(manifest["pythonBaseline"])
    fixture = asyncio.run(generate(python_root, expected_baseline))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(fixture, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
