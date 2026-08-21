#!/usr/bin/env python3
"""Generate the Services provider-acquisition parity fixture from Python.

The supplied Python checkout identifies the source-of-truth Git repository.
Generation executes an isolated archive of the pinned commit, so local tracked
or untracked changes cannot affect the fixture. Requests are scripted; no live
network access or provider credentials are used.

Usage:
    scripts/generate-provider-fixture.py --python-root /path/to/python-repo \
        --manifest Packages/Services/Tests/ServicesTests/Fixtures/fixtures_manifest.json \
        --output Packages/Services/Tests/ServicesTests/Fixtures/provider_acquisition_reference.json \
        --year-output Packages/Services/Tests/ServicesTests/Fixtures/year_decision_reference.json
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
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime, tzinfo
from pathlib import Path
from typing import Any, NotRequired, Protocol, TypedDict, cast
from urllib.parse import urlparse

ARTIST_QUERY = "björk"
ARTIST_DISPLAY = "Björk"
ALBUM_QUERY = "homogenic"
ALBUM_DISPLAY = "Homogenic"
TRACK_MODELS_MODULE = "core.models.track_models"

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

DECISION_YEAR = 2026


class DecisionCandidate(TypedDict):
    year: int | None
    score: int
    source: str


class DecisionScoring(TypedDict):
    baseScore: int
    musicBrainzBonus: int
    itunesBonus: int


class DecisionDivergence(TypedDict):
    kind: str
    reason: str


class DecisionCase(TypedDict):
    id: str
    description: str
    album: str
    candidates: list[DecisionCandidate]
    scoring: DecisionScoring
    existingYear: NotRequired[int]
    releaseYear: NotRequired[int]
    artistStartYear: NotRequired[int]
    startingAttempts: NotRequired[int]
    fallbackEnabled: NotRequired[bool]
    divergences: NotRequired[list[DecisionDivergence]]


YEAR_DECISION_CASES: list[DecisionCase] = [
    {
        "id": "candidate_year_boundary",
        "description": "Invalid, future, and missing years do not enter resolution",
        "album": "Album",
        "candidates": [
            {"year": 2028, "score": 100, "source": "musicbrainz"},
            {"year": 2020, "score": 70, "source": "discogs"},
            {"year": 1800, "score": 99, "source": "itunes"},
            {"year": None, "score": 88, "source": "discogs"},
        ],
        "scoring": {"baseScore": 70, "musicBrainzBonus": 30, "itunesBonus": 29},
    },
    {
        "id": "supported_existing_year",
        "description": "A suspicious change preserves an API-supported existing year",
        "album": "Album",
        "existingYear": 2005,
        "artistStartYear": 1993,
        "candidates": [
            {"year": 1997, "score": 69, "source": "musicbrainz"},
            {"year": 2005, "score": 60, "source": "discogs"},
        ],
        "scoring": {"baseScore": 60, "musicBrainzBonus": 9, "itunesBonus": 0},
    },
    {
        "id": "unsupported_existing_year",
        "description": "An unsupported existing year yields to API evidence",
        "album": "Album",
        "existingYear": 2005,
        "artistStartYear": 1993,
        "candidates": [{"year": 1997, "score": 69, "source": "discogs"}],
        "scoring": {"baseScore": 69, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "very_low_confidence",
        "description": "A new year below the confidence floor remains pending",
        "album": "Album",
        "candidates": [{"year": 2019, "score": 20, "source": "discogs"}],
        "scoring": {"baseScore": 20, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "confidence_floor",
        "description": "The exact new-year confidence floor is accepted",
        "album": "Album",
        "candidates": [{"year": 2019, "score": 30, "source": "discogs"}],
        "scoring": {"baseScore": 30, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "verification_escalation",
        "description": "The orchestration mark reaches the attempt ceiling before fallback",
        "album": "Album",
        "startingAttempts": 2,
        "candidates": [{"year": 2019, "score": 20, "source": "discogs"}],
        "scoring": {"baseScore": 20, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "compilation_preserves_existing",
        "description": "Compilation policy preserves the existing year",
        "album": "Greatest Hits",
        "existingYear": 2018,
        "candidates": [{"year": 1990, "score": 60, "source": "discogs"}],
        "scoring": {"baseScore": 60, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "remaster_applies_api",
        "description": "A remaster keeps the API year and records reissue evidence",
        "album": "Album (Remastered)",
        "existingYear": 2015,
        "candidates": [{"year": 2020, "score": 60, "source": "discogs"}],
        "scoring": {"baseScore": 60, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "implausible_existing_year",
        "description": "An existing year before artist activity yields to the API year",
        "album": "Album",
        "existingYear": 2000,
        "artistStartYear": 2015,
        "candidates": [
            {"year": 2025, "score": 60, "source": "musicbrainz"},
            {"year": 2000, "score": 50, "source": "discogs"},
        ],
        "scoring": {"baseScore": 50, "musicBrainzBonus": 10, "itunesBonus": 0},
    },
    {
        "id": "implausible_proposed_year",
        "description": "A proposed year before artist activity is rejected",
        "album": "Album",
        "existingYear": 2005,
        "artistStartYear": 1993,
        "candidates": [
            {"year": 1965, "score": 60, "source": "musicbrainz"},
            {"year": 2005, "score": 50, "source": "discogs"},
        ],
        "scoring": {"baseScore": 50, "musicBrainzBonus": 10, "itunesBonus": 0},
    },
    {
        "id": "release_year_conflict",
        "description": "A release-year conflict preserves editable metadata",
        "album": "Album",
        "existingYear": 2018,
        "releaseYear": 2000,
        "candidates": [{"year": 2010, "score": 60, "source": "discogs"}],
        "scoring": {"baseScore": 60, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "fresh_release_year",
        "description": "A current release year replaces stale API evidence",
        "album": "Album",
        "releaseYear": 2026,
        "candidates": [{"year": 2025, "score": 49, "source": "discogs"}],
        "scoring": {"baseScore": 49, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "definitive_bypasses_fallback",
        "description": "Definitive evidence bypasses special-album and plausibility guards",
        "album": "Greatest Hits",
        "existingYear": 2005,
        "releaseYear": 2025,
        "artistStartYear": 2015,
        "candidates": [{"year": 1997, "score": 90, "source": "discogs"}],
        "scoring": {"baseScore": 90, "musicBrainzBonus": 0, "itunesBonus": 0},
    },
    {
        "id": "fallback_disabled_single_mark",
        "description": "Disabled fallback applies API evidence without duplicating Swift verification attempts",
        "album": "Scallywag",
        "existingYear": 2018,
        "fallbackEnabled": False,
        "candidates": [
            {"year": 1998, "score": 40, "source": "discogs"},
            {"year": 2018, "score": 35, "source": "musicbrainz"},
        ],
        "scoring": {"baseScore": 40, "musicBrainzBonus": -5, "itunesBonus": 0},
        "divergences": [
            {
                "kind": "single_verification_mark",
                "reason": "Swift assigns verification-attempt ownership to the workflow and records one attempt per lookup; Python marks once in orchestration and again in disabled fallback",
            }
        ],
    },
]


class VerificationReasonValue(Protocol):
    value: str


class VerificationReasonParser(Protocol):
    def from_string(self, reason: str) -> VerificationReasonValue: ...


class ScoreResolver(Protocol):
    def aggregate_year_scores(
        self,
        releases: list[dict[str, object]],
    ) -> dict[str, list[int]]: ...


class DecisionTrack(Protocol):
    id: str
    year: str | None


TrackFactory = Callable[..., DecisionTrack]


class ScoreResolverFactory(Protocol):
    def __call__(
        self,
        *,
        console_logger: logging.Logger,
        min_valid_year: int,
        current_year: int,
        definitive_score_threshold: int,
        definitive_score_diff: int,
        remaster_keywords: list[str],
    ) -> ScoreResolver: ...


class FallbackFactory(Protocol):
    def __call__(self, **arguments: object) -> object: ...


class ConsistencyCheckerFactory(Protocol):
    def __call__(self, *, console_logger: logging.Logger) -> object: ...


class ProviderProcessingConfig(Protocol):
    cache_ttl_days: int


class ProviderLogicConfig(Protocol):
    min_valid_year: int
    definitive_score_threshold: int
    major_market_codes: list[str]


class ProviderYearConfig(Protocol):
    processing: ProviderProcessingConfig
    logic: ProviderLogicConfig
    scoring: object


class ProviderCleaningConfig(Protocol):
    remaster_keywords: list[str]


class ProviderConfig(Protocol):
    year_retrieval: ProviderYearConfig
    cleaning: ProviderCleaningConfig


class ProviderCoordinator(Protocol):
    async def fetch_all_api_results(
        self,
        artist: object,
        album: object,
        artist_region: object,
        display_artist: str,
        display_album: str,
    ) -> list[object]: ...


ProviderFactory = Callable[..., object]
ProviderConfigParser = Callable[[object], ProviderConfig]
ProviderCoordinatorFactory = Callable[..., ProviderCoordinator]
ReleaseFixtureBuilder = Callable[[object], dict[str, object]]


@dataclass(frozen=True)
class YearDecisionImports:
    external_api_orchestrator: type[object]
    score_resolver: ScoreResolverFactory
    verification_reason: VerificationReasonParser
    track: TrackFactory
    fallback: FallbackFactory
    determinator: type[object]
    consistency_checker: ConsistencyCheckerFactory
    updater: type[object]


DecisionResult = tuple[str | None, bool, int, dict[str, int]]
ProcessResults = Callable[..., asyncio.Future[DecisionResult]]
FetchYear = Callable[..., asyncio.Future[str | None]]
CollectTracks = Callable[
    [list[DecisionTrack], str],
    tuple[list[DecisionTrack], list[DecisionTrack]],
]


def completed[ResultValue](value: ResultValue) -> asyncio.Future[ResultValue]:
    future = asyncio.get_running_loop().create_future()
    future.set_result(value)
    return future


def dynamic_attribute(source: object, name: str) -> object:
    return getattr(source, name)


def imported_attribute(module_name: str, name: str) -> object:
    return dynamic_attribute(importlib.import_module(module_name), name)


def assign_dynamic_attributes(source: object, attributes: dict[str, object]) -> None:
    for name, value in attributes.items():
        setattr(source, name, value)


class PendingProbe:
    def __init__(
        self, reason_parser: VerificationReasonParser, starting_attempts: int
    ) -> None:
        self._reason_parser = reason_parser
        self.attempt_count = starting_attempts
        self.entry: dict[str, object] | None = None
        self.operations: list[dict[str, object]] = []

    def mark_for_verification(
        self,
        artist: str,
        album: str,
        reason: str = "no_year_found",
        metadata: dict[str, object] | None = None,
        recheck_days: int | None = None,
    ) -> asyncio.Future[None]:
        del artist, album, recheck_days
        normalized_reason = self._reason_parser.from_string(reason).value
        normalized_metadata = {
            key: str(value) for key, value in (metadata or {}).items()
        }
        self.attempt_count += 1
        self.entry = {
            "reason": normalized_reason,
            "metadata": normalized_metadata,
            "attemptCount": self.attempt_count,
        }
        self.operations.append(
            {
                "kind": "mark",
                "reason": normalized_reason,
                "metadata": normalized_metadata,
            }
        )
        return completed(None)

    def remove_from_pending(self, *, artist: str, album: str) -> asyncio.Future[None]:
        del artist, album
        self.entry = None
        self.operations.append({"kind": "remove"})
        return completed(None)

    def get_attempt_count(self, artist: str, album: str) -> asyncio.Future[int]:
        del artist, album
        return completed(self.attempt_count)


class AlbumYearCacheProbe:
    def __init__(self) -> None:
        self.store: dict[str, object] | None = None

    def store_album_year_in_cache(
        self,
        artist: str,
        album: str,
        year: str,
        *,
        confidence: int,
    ) -> asyncio.Future[None]:
        del artist, album
        self.store = {"year": int(year), "confidence": confidence}
        return completed(None)


class ArtistStartProbe:
    def __init__(self, year: int | None) -> None:
        self.year = year

    def get_artist_start_year(self, artist: str) -> asyncio.Future[int | None]:
        del artist
        return completed(self.year)


class AlbumYearResultProbe:
    def __init__(self, result: DecisionResult) -> None:
        self.result = result

    def get_album_year(
        self,
        *args: object,
        **kwargs: object,
    ) -> asyncio.Future[DecisionResult]:
        del args, kwargs
        return completed(self.result)


class ScriptedRequests:
    """Provider-local FIFO transport that records production requests."""

    def __init__(self, responses: dict[str, list[dict[str, Any]]]) -> None:
        self._responses = {
            provider: deque(values) for provider, values in responses.items()
        }
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

    async def set_async(
        self, key: str, value: object, ttl: float | None = None
    ) -> None:
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


def canonical_python_candidate(candidate: dict[str, object]) -> dict[str, object]:
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
        raise RuntimeError(
            f"git {' '.join(arguments)} failed: {stderr.decode().strip()}"
        )
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


def scored_release(candidate: DecisionCandidate, album: str) -> dict[str, object]:
    year = candidate["year"]
    return {
        "title": album,
        "year": str(year) if year is not None else None,
        "score": candidate["score"],
        "artist": "Artist",
        "album_type": "album",
        "country": None,
        "status": "official",
        "format": None,
        "label": None,
        "catalog_number": None,
        "barcode": None,
        "disambiguation": None,
        "source": candidate["source"],
        "is_reissue": False,
    }


def decision_tracks(
    track_factory: TrackFactory, case: DecisionCase
) -> list[DecisionTrack]:
    existing_year = case.get("existingYear")
    release_year = case.get("releaseYear")
    return [
        track_factory(
            id=f"track-{index}",
            name=f"Track {index}",
            artist="Artist",
            album=str(case["album"]),
            year=str(existing_year) if existing_year is not None else None,
            release_year=str(release_year) if release_year is not None else None,
            track_status="purchased",
        )
        for index in (1, 2)
    ]


async def execute_year_decision(
    case: DecisionCase,
    imported: YearDecisionImports,
    logger: logging.Logger,
) -> dict[str, object]:
    pending = PendingProbe(
        imported.verification_reason,
        case.get("startingAttempts", 0),
    )
    resolver = imported.score_resolver(
        console_logger=logger,
        min_valid_year=1900,
        current_year=DECISION_YEAR,
        definitive_score_threshold=50,
        definitive_score_diff=15,
        remaster_keywords=[
            "remaster",
            "remastered",
            "anniversary",
            "deluxe",
            "edition",
        ],
    )
    orchestrator = object.__new__(imported.external_api_orchestrator)
    assign_dynamic_attributes(
        orchestrator,
        {
            "console_logger": logger,
            "error_logger": logger,
            "pending_verification_service": pending,
            "_pending_tasks": set(),
            "current_year": DECISION_YEAR,
            "min_valid_year": 1900,
            "year_score_resolver": resolver,
        },
    )

    releases = [
        scored_release(candidate, case["album"]) for candidate in case["candidates"]
    ]
    process_results = cast(
        ProcessResults,
        dynamic_attribute(orchestrator, "_process_api_results"),
    )
    api_result = await process_results(
        releases,
        artist="Artist",
        album=case["album"],
        log_artist="Artist",
        log_album=case["album"],
        current_library_year=(
            str(case["existingYear"]) if case.get("existingYear") is not None else None
        ),
        earliest_track_added_year=2024,
    )

    fallback = imported.fallback(
        console_logger=logger,
        pending_verification=pending,
        fallback_enabled=case.get("fallbackEnabled", True),
        absurd_year_threshold=1970,
        year_difference_threshold=5,
        trust_api_score_threshold=70,
        min_confidence_for_new_year=30,
        api_orchestrator=ArtistStartProbe(case.get("artistStartYear")),
    )
    cache = AlbumYearCacheProbe()
    determinator = object.__new__(imported.determinator)
    assign_dynamic_attributes(
        determinator,
        {
            "external_api": AlbumYearResultProbe(api_result),
            "fallback_handler": fallback,
            "cache_service": cache,
            "consistency_checker": imported.consistency_checker(console_logger=logger),
            "console_logger": logger,
            "error_logger": logger,
        },
    )
    tracks = decision_tracks(imported.track, case)
    fetch_year = cast(
        FetchYear,
        dynamic_attribute(determinator, "_fetch_from_api"),
    )
    final_year = await fetch_year(
        "Artist",
        case["album"],
        tracks,
        str(case["existingYear"]) if case.get("existingYear") is not None else None,
    )

    updater = object.__new__(imported.updater)
    assign_dynamic_attributes(updater, {"console_logger": logger})
    proposals: list[dict[str, object]] = []
    if final_year is not None:
        collect_tracks = cast(
            CollectTracks,
            dynamic_attribute(updater, "_collect_tracks_for_update"),
        )
        _, proposal_tracks = collect_tracks(tracks, final_year)
        proposals = [
            {
                "trackID": track.id,
                "oldYear": int(track.year) if track.year is not None else None,
                "newYear": int(final_year),
            }
            for track in proposal_tracks
        ]

    aggregated = resolver.aggregate_year_scores(releases)
    accepted_score_lists = dict(
        sorted(aggregated.items(), key=lambda item: int(item[0]))
    )
    rejected_years: list[int] = []
    for candidate in case["candidates"]:
        year = candidate["year"]
        if year is not None and str(year) not in aggregated:
            rejected_years.append(year)
    rejected_missing_year_count = sum(
        candidate["year"] is None for candidate in case["candidates"]
    )
    selected_year, is_definitive, confidence, year_scores = api_result
    return {
        "acceptedScoreLists": accepted_score_lists,
        "rejectedYears": rejected_years,
        "rejectedMissingYearCount": rejected_missing_year_count,
        "selectedYear": int(selected_year) if selected_year else None,
        "isDefinitive": is_definitive,
        "confidence": confidence,
        "yearScores": year_scores,
        "finalYear": int(final_year) if final_year is not None else None,
        "pendingOperations": pending.operations,
        "pendingFinal": pending.entry,
        "cacheStore": cache.store,
        "proposals": proposals,
    }


def load_year_imports() -> YearDecisionImports:
    return YearDecisionImports(
        external_api_orchestrator=cast(
            type[object],
            imported_attribute(
                "services.api.orchestrator",
                "ExternalApiOrchestrator",
            ),
        ),
        score_resolver=cast(
            ScoreResolverFactory,
            imported_attribute(
                "services.api.year_score_resolver",
                "YearScoreResolver",
            ),
        ),
        verification_reason=cast(
            VerificationReasonParser,
            imported_attribute(
                "core.models.cache_types",
                "VerificationReason",
            ),
        ),
        track=cast(
            TrackFactory,
            imported_attribute(
                TRACK_MODELS_MODULE,
                "TrackDict",
            ),
        ),
        fallback=cast(
            FallbackFactory,
            imported_attribute(
                "core.tracks.year_fallback",
                "YearFallbackHandler",
            ),
        ),
        determinator=cast(
            type[object],
            imported_attribute(
                "core.tracks.year_determination",
                "YearDeterminator",
            ),
        ),
        consistency_checker=cast(
            ConsistencyCheckerFactory,
            imported_attribute(
                "core.tracks.year_consistency",
                "YearConsistencyChecker",
            ),
        ),
        updater=cast(
            type[object],
            imported_attribute(
                "core.tracks.track_updater",
                "TrackUpdater",
            ),
        ),
    )


def decision_case_input(case: DecisionCase) -> dict[str, object]:
    result: dict[str, object] = {
        "album": case["album"],
        "candidates": case["candidates"],
        "scoring": case["scoring"],
    }
    if "existingYear" in case:
        result["existingYear"] = case["existingYear"]
    if "releaseYear" in case:
        result["releaseYear"] = case["releaseYear"]
    if "artistStartYear" in case:
        result["artistStartYear"] = case["artistStartYear"]
    if "startingAttempts" in case:
        result["startingAttempts"] = case["startingAttempts"]
    if "fallbackEnabled" in case:
        result["fallbackEnabled"] = case["fallbackEnabled"]
    return result


async def build_year_fixture(
    python_root: Path,
    baseline: str,
) -> dict[str, object]:
    imported = load_year_imports()
    year_fallback_module = importlib.import_module("core.tracks.year_fallback")
    album_type_module = importlib.import_module("core.models.album_type")
    yaml_loader = cast(
        Callable[[str], object],
        imported_attribute("yaml", "safe_load"),
    )
    configuration_parser = cast(
        Callable[[object], object],
        dynamic_attribute(
            imported_attribute(TRACK_MODELS_MODULE, "AppConfig"),
            "model_validate",
        ),
    )
    configure_album_patterns = cast(
        Callable[[object], None],
        dynamic_attribute(album_type_module, "configure_patterns"),
    )
    configuration = configuration_parser(
        yaml_loader((python_root / "config.yaml").read_text(encoding="utf-8"))
    )
    configure_album_patterns(configuration)
    original_datetime = year_fallback_module.datetime

    class FixedDateTime:
        @classmethod
        def now(cls, timezone: tzinfo | None = UTC) -> datetime:
            del cls
            return datetime(DECISION_YEAR, 1, 15, tzinfo=timezone)

    year_fallback_module.datetime = FixedDateTime
    logger = logging.getLogger("year_decision_fixture")
    logger.handlers = [logging.NullHandler()]
    try:
        cases = [
            {
                "id": case["id"],
                "description": case["description"],
                "input": decision_case_input(case),
                "expected": await execute_year_decision(case, imported, logger),
                **(
                    {"divergences": case["divergences"]}
                    if "divergences" in case
                    else {}
                ),
            }
            for case in YEAR_DECISION_CASES
        ]
    finally:
        year_fallback_module.datetime = original_datetime

    return {
        "schemaVersion": 1,
        "pythonBaseline": baseline,
        "contract": "post_acquisition_scored_release_decision",
        "decisionYear": DECISION_YEAR,
        "cases": cases,
    }


async def generate(
    python_root: Path,
    expected_baseline: str,
) -> tuple[dict[str, object], dict[str, object]]:
    baseline = await verify_python_checkout(python_root, expected_baseline)
    archive = await git_bytes(python_root, "archive", "--format=tar", expected_baseline)
    with tempfile.TemporaryDirectory(prefix="genre-updater-python-") as directory:
        source_root = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source_archive:
            source_archive.extractall(source_root, filter="data")
        provider_fixture = await build_fixture(source_root, baseline)
        year_decision_fixture = await build_year_fixture(source_root, baseline)

    if await verify_python_checkout(python_root, expected_baseline) != baseline:
        raise RuntimeError("Python HEAD changed during fixture generation")
    return provider_fixture, year_decision_fixture


async def build_fixture(python_root: Path, baseline: str) -> dict[str, object]:
    sys.path.insert(0, str(python_root))
    sys.path.insert(0, str(python_root / "src"))

    yaml_loader = cast(Callable[[str], object], imported_attribute("yaml", "safe_load"))
    configuration_parser = cast(
        ProviderConfigParser,
        dynamic_attribute(
            imported_attribute(TRACK_MODELS_MODULE, "AppConfig"),
            "model_validate",
        ),
    )
    apple_music_factory = cast(
        ProviderFactory,
        imported_attribute("services.api.applemusic", "AppleMusicClient"),
    )
    discogs_factory = cast(
        ProviderFactory,
        imported_attribute("services.api.discogs", "DiscogsClient"),
    )
    musicbrainz_factory = cast(
        ProviderFactory,
        imported_attribute("services.api.musicbrainz", "MusicBrainzClient"),
    )
    release_scorer_factory = cast(
        ProviderFactory,
        imported_attribute("services.api.year_scoring", "ReleaseScorer"),
    )
    coordinator_factory = cast(
        ProviderCoordinatorFactory,
        imported_attribute(
            "services.api.year_search_coordinator",
            "YearSearchCoordinator",
        ),
    )
    build_release_fixture = cast(
        ReleaseFixtureBuilder,
        imported_attribute(
            "tools.generate_swift_fixtures",
            "_build_release_fixture",
        ),
    )

    configuration = configuration_parser(
        yaml_loader((python_root / "config.yaml").read_text(encoding="utf-8"))
    )
    logger = logging.getLogger("provider_fixture")
    logger.handlers = [logging.NullHandler()]
    analytics = PassthroughAnalytics()
    requests = ScriptedRequests(SCRIPTED_RESPONSES)
    score = accept_candidate

    musicbrainz = musicbrainz_factory(logger, logger, requests, score, analytics)
    discogs = discogs_factory(
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
    itunes = apple_music_factory(logger, logger, requests, score)
    scorer = release_scorer_factory(
        scoring_config=configuration.year_retrieval.scoring,
        min_valid_year=configuration.year_retrieval.logic.min_valid_year,
        definitive_score_threshold=configuration.year_retrieval.logic.definitive_score_threshold,
        console_logger=logger,
        remaster_keywords=configuration.cleaning.remaster_keywords,
        major_market_codes=configuration.year_retrieval.logic.major_market_codes,
    )
    coordinator = coordinator_factory(
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


def write_fixture(path: Path, fixture: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(fixture, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--year-output", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    arguments = parser.parse_args()

    python_root = arguments.python_root.resolve(strict=True)
    output = arguments.output.resolve()
    year_output = arguments.year_output.resolve()
    manifest = json.loads(
        arguments.manifest.resolve(strict=True).read_text(encoding="utf-8")
    )
    expected_baseline = str(manifest["pythonBaseline"])
    provider_fixture, year_decision_fixture = asyncio.run(
        generate(python_root, expected_baseline)
    )
    write_fixture(output, provider_fixture)
    write_fixture(year_output, year_decision_fixture)


if __name__ == "__main__":
    main()
