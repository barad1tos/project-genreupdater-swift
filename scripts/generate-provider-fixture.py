#!/usr/bin/env python3
"""Generate the Services provider-acquisition parity fixture from Python.

The supplied Python checkout is the executable source of truth. Requests are
scripted, so generation runs the real provider clients and coordinator without
network access or provider credentials.

Usage:
    scripts/generate-provider-fixture.py --python-root /path/to/python-repo \
        --output Packages/Services/Tests/ServicesTests/Fixtures/provider_acquisition_reference.json
"""

from __future__ import annotations

import argparse
import asyncio
import copy
import importlib
import json
import logging
import sys
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


def swift_candidates() -> list[dict[str, Any]]:
    """Record reviewed Swift enrichments without rewriting Python evidence."""
    return [
        {
            "artist": ARTIST_QUERY,
            "album": ALBUM_DISPLAY,
            "year": 1997,
            "source": "musicbrainz",
            "releaseType": "album",
            "status": "official",
            "country": None,
            "isReissue": False,
            "mbReleaseGroupID": "mb-homogenic",
            "mbReleaseGroupFirstYear": 1997,
            "genre": None,
        },
        {
            "artist": ARTIST_QUERY,
            "album": ALBUM_DISPLAY,
            "year": 1997,
            "source": "discogs",
            "releaseType": "album",
            "status": "official",
            "country": "is",
            "isReissue": False,
            "mbReleaseGroupID": None,
            "mbReleaseGroupFirstYear": None,
            "genre": "Electronic",
        },
        {
            "artist": ARTIST_DISPLAY,
            "album": ALBUM_DISPLAY,
            "year": 1997,
            "source": "itunes",
            "releaseType": "album",
            "status": "official",
            "country": "us",
            "isReissue": False,
            "mbReleaseGroupID": None,
            "mbReleaseGroupFirstYear": None,
            "genre": None,
        },
    ]


def canonical_python_candidate(candidate: dict[str, Any]) -> dict[str, Any]:
    """Represent Python's empty country as Swift's absent optional value."""
    canonical = dict(candidate)
    if canonical.get("country") == "":
        canonical["country"] = None
    return canonical


def swift_requests(
    python_requests: dict[str, list[dict[str, Any]]],
) -> dict[str, list[dict[str, Any]]]:
    """Record the reviewed Swift request-policy divergence."""
    requests = copy.deepcopy(python_requests)
    direct_search = requests["itunes"][0]["query"]
    next(item for item in direct_search if item["name"] == "limit")["value"] = "200"
    return requests


async def generate(python_root: Path) -> dict[str, object]:
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

    process = await asyncio.create_subprocess_exec(
        "git",
        "-C",
        str(python_root),
        "rev-parse",
        "HEAD",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        raise RuntimeError(f"failed to read Python baseline: {stderr.decode().strip()}")
    baseline = stdout.decode().strip()
    python_candidates = [
        canonical_python_candidate(build_release_fixture(release))
        for release in releases
    ]
    python_requests = dict(requests.requests)
    return {
        "schemaVersion": 1,
        "pythonBaseline": baseline,
        "cases": [
            {
                **SCENARIO,
                "expected": {
                    "pythonRequests": python_requests,
                    "swiftRequests": swift_requests(python_requests),
                    "candidateSourceOrder": [
                        candidate["source"] for candidate in python_candidates
                    ],
                    "pythonCandidates": python_candidates,
                    "swiftCandidates": swift_candidates(),
                },
                "divergences": [
                    {
                        "scope": "candidate enrichment",
                        "reason": (
                            "Swift retains MusicBrainz release-group evidence and Discogs "
                            "format/genre evidence that Python consumes or drops before return"
                        ),
                    },
                    {
                        "scope": "iTunes direct-search breadth",
                        "reason": (
                            "Swift requests 200 direct-search results for higher recall; Python "
                            "requests 50 for a smaller response payload. Both use 200 for lookup."
                        ),
                    }
                ],
            }
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    python_root = arguments.python_root.resolve(strict=True)
    output = arguments.output.resolve()
    fixture = asyncio.run(generate(python_root))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(fixture, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
