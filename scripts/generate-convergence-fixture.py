#!/usr/bin/env python3
"""Generate the library-convergence reference from pinned Python code."""

from __future__ import annotations

import argparse
import asyncio
import importlib
import io
import json
import logging
import sys
import tarfile
import tempfile
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol, TypedDict, Unpack, cast


@dataclass(frozen=True)
class TrackInput:
    identifier: str
    artist: str
    album: str
    album_artist: str | None = None
    genre: str | None = "Metal"
    year: str | None = "2004"


@dataclass(frozen=True)
class ScenarioInput:
    identifier: str
    description: str
    previous: tuple[TrackInput, ...]
    current: tuple[TrackInput, ...]
    previous_test_artists: tuple[str, ...] = ()
    test_artists: tuple[str, ...] = ()
    force_metadata_refresh: bool = False
    metadata_response_ids: tuple[str, ...] | None = None
    does_source_change_during_scan: bool = False


IN_FLAMES_TRACK = TrackInput("1", "In Flames", "Soundtrack to Your Escape")
DARK_TRANQUILLITY_TRACK = TrackInput("2", "Dark Tranquillity", "Character")
GUEST_VOCAL_TRACK = TrackInput(
    "3",
    "Guest Vocalist",
    "Fiction",
    album_artist="Dark Tranquillity",
)

SCENARIOS = (
    ScenarioInput(
        "unchanged-library",
        "An unchanged library performs no metadata or cache work",
        (IN_FLAMES_TRACK,),
        (IN_FLAMES_TRACK,),
    ),
    ScenarioInput(
        "new-track",
        "A new track enters the physical inventory and processing mirror",
        (IN_FLAMES_TRACK,),
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK),
    ),
    ScenarioInput(
        "removed-track",
        "A removed track leaves membership and invalidates its album caches",
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK),
        (IN_FLAMES_TRACK,),
    ),
    ScenarioInput(
        "metadata-change",
        "A force refresh observes changed managed metadata",
        (IN_FLAMES_TRACK,),
        (
            TrackInput(
                "1",
                IN_FLAMES_TRACK.artist,
                IN_FLAMES_TRACK.album,
                genre="Melodic Death Metal",
                year="2006",
            ),
        ),
        force_metadata_refresh=True,
    ),
    ScenarioInput(
        "identity-change",
        "A force refresh observes an artist and album identity change",
        (IN_FLAMES_TRACK,),
        (TrackInput("1", "The Halo Effect", "Days of the Lost"),),
        force_metadata_refresh=True,
    ),
    ScenarioInput(
        "test-artists-change",
        "Changing Test Artists reclassifies the processing scope without narrowing physical membership",
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK),
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK, GUEST_VOCAL_TRACK),
        previous_test_artists=(IN_FLAMES_TRACK.artist,),
        test_artists=(DARK_TRANQUILLITY_TRACK.artist,),
    ),
    ScenarioInput(
        "configured-force-refresh",
        "A configured force refresh re-reads common metadata without inventing a delta",
        (IN_FLAMES_TRACK,),
        (IN_FLAMES_TRACK,),
        force_metadata_refresh=True,
    ),
    ScenarioInput(
        "partial-response",
        "A partial force response must not certify metadata that was not observed",
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK),
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK),
        force_metadata_refresh=True,
        metadata_response_ids=(IN_FLAMES_TRACK.identifier,),
    ),
    ScenarioInput(
        "source-change-during-scan",
        "A source generation change must not publish a mixed observation",
        (IN_FLAMES_TRACK,),
        (IN_FLAMES_TRACK, DARK_TRANQUILLITY_TRACK),
        does_source_change_during_scan=True,
    ),
)


class PythonTrack(Protocol):
    id: str
    name: str
    artist: str
    album: str
    album_artist: str | None
    genre: str | None
    year: str | int | None
    track_status: str | None


class TrackArguments(TypedDict):
    id: str
    name: str
    artist: str
    album: str
    album_artist: str | None
    genre: str | None
    year: str | None


class TrackFactory(Protocol):
    def __call__(self, **kwargs: Unpack[TrackArguments]) -> PythonTrack: ...


class TrackDelta(Protocol):
    new_ids: list[str]
    updated_ids: list[str]
    removed_ids: list[str]

    def is_empty(self) -> bool: ...


class ComputeTrackDelta(Protocol):
    def __call__(
        self,
        current_tracks: list[PythonTrack],
        existing_map: dict[str, PythonTrack],
    ) -> TrackDelta: ...


class TrackComparison(Protocol):
    def __call__(self, current: PythonTrack, stored: PythonTrack) -> bool: ...


class CacheEventSink(Protocol):
    def emit_track_removed(self, track_id: str, artist: str, album: str) -> None: ...

    def emit_track_modified(self, track_id: str, artist: str, album: str) -> None: ...


class AppleScriptAcquisitionClient(Protocol):
    async def fetch_all_track_ids(self) -> list[str]: ...

    async def run_script(
        self,
        script: str,
        arguments: list[str] | None = None,
        **options: object,
    ) -> str: ...


class SnapshotServiceSurface(Protocol):
    logger: logging.Logger

    def is_enabled(self) -> bool: ...

    async def is_snapshot_valid(self) -> bool: ...

    async def compute_smart_delta(
        self,
        client: AppleScriptAcquisitionClient,
        *,
        force: bool,
    ) -> TrackDelta | None: ...

    async def should_force_scan(self, force: bool) -> tuple[bool, str]: ...

    async def load_snapshot(self) -> list[PythonTrack]: ...

    async def _detect_updated_tracks(
        self,
        client: AppleScriptAcquisitionClient,
        current_ids: set[str],
        snapshot_ids: set[str],
        snapshot_map: dict[str, PythonTrack],
    ) -> list[str]: ...

    def _parse_fetch_tracks_output(self, raw_output: str) -> list[dict[str, str]]: ...

    def _parse_raw_track(self, raw_track: dict[str, str]) -> PythonTrack: ...

    async def _update_force_scan_time(self) -> None: ...


class TrackByIDFetcher(Protocol):
    async def fetch_tracks_by_ids(self, identifiers: list[str]) -> list[PythonTrack]: ...


class SnapshotManagerSurface(Protocol):
    _track_processor: TrackByIDFetcher
    _console_logger: logging.Logger

    async def merge_smart_delta(
        self,
        snapshot_tracks: list[PythonTrack],
        delta: TrackDelta,
    ) -> list[PythonTrack] | None: ...


class CacheServicesSurface(Protocol):
    api_service: CacheEventSink


class SmartDeltaDependenciesSurface(Protocol):
    library_snapshot_service: SnapshotServiceSurface
    ap_client: AppleScriptAcquisitionClient
    cache_service: CacheServicesSurface


class SmartDeltaUpdaterSurface(Protocol):
    deps: SmartDeltaDependenciesSurface
    snapshot_manager: SnapshotManagerSurface
    console_logger: logging.Logger
    error_logger: logging.Logger

    def _emit_removed_track_events(
        self,
        removed_ids: list[str],
        snapshot_map: dict[str, PythonTrack],
        recorder: CacheEventSink,
    ) -> None: ...

    def _emit_identity_change_events(
        self,
        updated_ids: list[str],
        snapshot_map: dict[str, PythonTrack],
        current_tracks: list[PythonTrack],
        recorder: CacheEventSink,
    ) -> None: ...


class TestArtistScopeSurface(Protocol):
    tracks: list[PythonTrack]
    dry_run_test_artists: set[str]
    dry_run_mode: str
    config: ScopeConfiguration
    console_logger: logging.Logger

    async def fetch_tracks_async(
        self,
        artist: str,
        force_refresh: bool,
        *,
        ignore_test_filter: bool,
    ) -> list[PythonTrack]: ...


class SnapshotCompute(Protocol):
    async def __call__(
        self,
        receiver: SnapshotServiceSurface,
        applescript_client: AppleScriptAcquisitionClient,
        force: bool = False,
    ) -> TrackDelta | None: ...


class UpdatedTrackDetector(Protocol):
    async def __call__(
        self,
        receiver: SnapshotServiceSurface,
        applescript_client: AppleScriptAcquisitionClient,
        current_ids: set[str],
        snapshot_ids: set[str],
        snapshot_map: dict[str, PythonTrack],
    ) -> list[str]: ...


class RawTrackParser(Protocol):
    def __call__(self, raw_track: dict[str, str]) -> PythonTrack: ...


class FetchOutputParser(Protocol):
    def __call__(
        self,
        receiver: SnapshotServiceSurface,
        raw_output: str,
    ) -> list[dict[str, str]]: ...


class SmartDeltaMerger(Protocol):
    async def __call__(
        self,
        receiver: SnapshotManagerSurface,
        snapshot_tracks: list[PythonTrack],
        delta: TrackDelta,
    ) -> list[PythonTrack] | None: ...


class TrackPayload(TypedDict):
    identifier: str
    artist: str
    album: str
    album_artist: str | None
    genre: str | None
    year: str | None


class MembershipDeltaPayload(TypedDict):
    newIDs: list[str]
    removedIDs: list[str]


class InvalidationTargetPayload(TypedDict):
    artist: str
    album: str


class ScenarioInputPayload(TypedDict):
    previousTracks: list[TrackPayload]
    currentTracks: list[TrackPayload]
    previousTestArtists: list[str]
    testArtists: list[str]
    forceMetadataRefresh: bool
    metadataResponseIDs: list[str]
    sourceChangesDuringScan: bool


class PythonExpectationPayload(TypedDict):
    membershipDelta: MembershipDeltaPayload
    managedMetadataChangedIDs: list[str]
    identityChangedIDs: list[str]
    admittedIDs: list[str]
    metadataRequestIDs: list[str]
    metadataObservedIDs: list[str]
    invalidationTargets: list[InvalidationTargetPayload]
    readiness: None
    downstreamDecision: str


class SwiftExpectationPayload(TypedDict):
    identityRequestIDs: list[str]
    persistedClassificationUpsertedIDs: list[str]
    persistedClassificationRemovedIDs: list[str]
    invalidationTargets: list[InvalidationTargetPayload]
    isReady: bool
    downstreamDecision: str
    strongerContractReasons: list[str]


class ScenarioPayload(TypedDict):
    id: str
    description: str
    input: ScenarioInputPayload
    pythonExpected: PythonExpectationPayload
    swiftExpected: SwiftExpectationPayload


class FixturePayload(TypedDict):
    schemaVersion: int
    pythonBaseline: str
    pythonEntryPoints: list[str]
    cases: list[ScenarioPayload]


class CacheEventRecorder:
    def __init__(self) -> None:
        self.targets: list[InvalidationTargetPayload] = []
        self.event_kinds: list[str] = []

    def emit_track_removed(self, track_id: str, artist: str, album: str) -> None:
        self._record_invalidation("removed", track_id, artist, album)

    def emit_track_modified(self, track_id: str, artist: str, album: str) -> None:
        self._record_invalidation("modified", track_id, artist, album)

    def _record_invalidation(self, kind: str, track_id: str, artist: str, album: str) -> None:
        del track_id
        self.event_kinds.append(kind)
        self.targets.append({"artist": artist, "album": album})


class AcquisitionRecorder:
    def __init__(self) -> None:
        self.requested_ids: list[str] = []
        self.observed_ids: list[str] = []

    def record_request(self, identifiers: list[str]) -> None:
        self.requested_ids.extend(identifiers)

    def record_observation(self, tracks: list[PythonTrack]) -> None:
        self.observed_ids.extend(str(track.id) for track in tracks)

    @staticmethod
    def unique(identifiers: list[str]) -> list[str]:
        return sorted(set(identifiers))


@dataclass(frozen=True)
class ScenarioTracks:
    previous: list[PythonTrack]
    current: list[PythonTrack]
    previous_by_id: dict[str, PythonTrack]
    current_by_id: dict[str, PythonTrack]
    response_ids: set[str]


@dataclass(frozen=True)
class PythonHarnessState:
    cache_events: CacheEventRecorder
    acquisition: AcquisitionRecorder


class ScriptedAppleScriptClient:
    def __init__(
        self,
        current_tracks: list[PythonTrack],
        response_ids: set[str],
        recorder: AcquisitionRecorder,
        field_separator: str,
        line_separator: str,
    ) -> None:
        self.current_tracks = {str(track.id): track for track in current_tracks}
        self.response_ids = response_ids
        self.recorder = recorder
        self.field_separator = field_separator
        self.line_separator = line_separator

    async def fetch_all_track_ids(self) -> list[str]:
        await asyncio.sleep(0)
        return sorted(self.current_tracks)

    async def run_script(
        self,
        script: str,
        arguments: list[str] | None = None,
        **options: object,
    ) -> str:
        await asyncio.sleep(0)
        del script, options
        requested_ids = arguments[0].split(",") if arguments else []
        self.recorder.record_request(requested_ids)
        tracks = [
            self.current_tracks[identifier]
            for identifier in requested_ids
            if identifier in self.response_ids and identifier in self.current_tracks
        ]
        self.recorder.record_observation(tracks)
        return self.line_separator.join(self._encoded(track) for track in tracks)

    def _encoded(self, track: PythonTrack) -> str:
        values = (
            str(track.id),
            track.name,
            track.artist,
            track.album_artist or "",
            track.album,
            track.genre or "",
            "",
            "",
            track.track_status or "",
            str(track.year or ""),
            "",
        )
        return self.field_separator.join(values)


class SmartDeltaSnapshotService:
    def __init__(
        self,
        snapshot_tracks: list[PythonTrack],
        compute: SnapshotCompute,
        detect_updated: UpdatedTrackDetector,
        parse_fetch_output: FetchOutputParser,
        parse_raw_track: RawTrackParser,
    ) -> None:
        self.snapshot_tracks = snapshot_tracks
        self.compute = compute
        self.detect_updated = detect_updated
        self.parse_fetch_output = parse_fetch_output
        self.parse_raw_track = parse_raw_track
        self.last_delta: TrackDelta | None = None
        self.logger = logging.getLogger("convergence-fixture")

    @staticmethod
    def is_enabled() -> bool:
        return True

    @staticmethod
    async def is_snapshot_valid() -> bool:
        await asyncio.sleep(0)
        return True

    async def compute_smart_delta(
        self,
        client: AppleScriptAcquisitionClient,
        *,
        force: bool,
    ) -> TrackDelta | None:
        self.last_delta = await self.compute(self, client, force)
        return self.last_delta

    async def load_snapshot(self) -> list[PythonTrack]:
        await asyncio.sleep(0)
        return self.snapshot_tracks

    @staticmethod
    async def should_force_scan(force: bool) -> tuple[bool, str]:
        await asyncio.sleep(0)
        reason = "fixture requested force scan" if force else "fixture fast scan"
        return force, reason

    async def _detect_updated_tracks(
        self,
        client: AppleScriptAcquisitionClient,
        current_ids: set[str],
        snapshot_ids: set[str],
        snapshot_map: dict[str, PythonTrack],
    ) -> list[str]:
        return await self.detect_updated(
            self,
            client,
            current_ids,
            snapshot_ids,
            snapshot_map,
        )

    def _parse_fetch_tracks_output(self, raw_output: str) -> list[dict[str, str]]:
        return self.parse_fetch_output(self, raw_output)

    def _parse_raw_track(self, raw_track: dict[str, str]) -> PythonTrack:
        return self.parse_raw_track(raw_track)

    @staticmethod
    async def _update_force_scan_time() -> None:
        await asyncio.sleep(0)


class ScriptedTrackProcessor:
    def __init__(
        self,
        current_tracks: list[PythonTrack],
        response_ids: set[str],
        recorder: AcquisitionRecorder,
    ) -> None:
        self.current_tracks = {str(track.id): track for track in current_tracks}
        self.response_ids = response_ids
        self.recorder = recorder

    async def fetch_tracks_by_ids(self, identifiers: list[str]) -> list[PythonTrack]:
        await asyncio.sleep(0)
        self.recorder.record_request(identifiers)
        tracks = [
            self.current_tracks[identifier]
            for identifier in identifiers
            if identifier in self.response_ids and identifier in self.current_tracks
        ]
        self.recorder.record_observation(tracks)
        return tracks


class SmartDeltaSnapshotManager:
    def __init__(self, track_processor: ScriptedTrackProcessor, merge: SmartDeltaMerger) -> None:
        self._track_processor: TrackByIDFetcher = track_processor
        self._console_logger = logging.getLogger("convergence-fixture")
        self.merge = merge

    async def merge_smart_delta(
        self,
        snapshot_tracks: list[PythonTrack],
        delta: TrackDelta,
    ) -> list[PythonTrack] | None:
        return await self.merge(self, snapshot_tracks, delta)


class CacheServices:
    def __init__(self, api_service: CacheEventSink) -> None:
        self.api_service: CacheEventSink = api_service


class SmartDeltaDependencies:
    def __init__(
        self,
        snapshot_service: SmartDeltaSnapshotService,
        client: ScriptedAppleScriptClient,
        recorder: CacheEventRecorder,
    ) -> None:
        self.library_snapshot_service: SnapshotServiceSurface = snapshot_service
        self.ap_client: AppleScriptAcquisitionClient = client
        self.cache_service: CacheServicesSurface = CacheServices(recorder)


class SmartDeltaHarness:
    def __init__(
        self,
        tracks: ScenarioTracks,
        state: PythonHarnessState,
        production_paths: PythonProductionPaths,
    ) -> None:
        client = ScriptedAppleScriptClient(
            tracks.current,
            tracks.response_ids,
            state.acquisition,
            production_paths.field_separator,
            production_paths.line_separator,
        )
        snapshot_service = SmartDeltaSnapshotService(
            tracks.previous,
            production_paths.snapshot_compute,
            production_paths.updated_track_detector,
            production_paths.fetch_output_parser,
            production_paths.raw_track_parser,
        )
        self.deps: SmartDeltaDependenciesSurface = SmartDeltaDependencies(
            snapshot_service,
            client,
            state.cache_events,
        )
        self.snapshot_manager: SnapshotManagerSurface = SmartDeltaSnapshotManager(
            ScriptedTrackProcessor(
                tracks.current,
                tracks.response_ids,
                state.acquisition,
            ),
            production_paths.smart_delta_merger,
        )
        self.snapshot_service = snapshot_service
        self.console_logger = logging.getLogger("convergence-fixture")
        self.error_logger = self.console_logger
        self.removed_emitter = production_paths.removed_invalidation
        self.identity_emitter = production_paths.identity_invalidation

    def _emit_removed_track_events(
        self,
        removed_ids: list[str],
        snapshot_map: dict[str, PythonTrack],
        recorder: CacheEventSink,
    ) -> None:
        self.removed_emitter(self, removed_ids, snapshot_map, recorder)

    def _emit_identity_change_events(
        self,
        updated_ids: list[str],
        snapshot_map: dict[str, PythonTrack],
        current_tracks: list[PythonTrack],
        recorder: CacheEventSink,
    ) -> None:
        self.identity_emitter(
            self,
            updated_ids,
            snapshot_map,
            current_tracks,
            recorder,
        )


class DevelopmentConfiguration:
    def __init__(self, test_artists: tuple[str, ...]) -> None:
        self.test_artists = list(test_artists)


class ScopeConfiguration:
    def __init__(self, test_artists: tuple[str, ...]) -> None:
        self.development = DevelopmentConfiguration(test_artists)


class TestArtistScopeHarness:
    def __init__(
        self,
        tracks: list[PythonTrack],
        test_artists: tuple[str, ...],
        response_ids: set[str],
        recorder: AcquisitionRecorder,
    ) -> None:
        self.tracks = tracks
        self.response_ids = response_ids
        self.recorder = recorder
        self.dry_run_test_artists = set(test_artists)
        self.dry_run_mode = "test"
        self.config = ScopeConfiguration(test_artists)
        self.console_logger = logging.getLogger("convergence-fixture")

    async def fetch_tracks_async(
        self,
        artist: str,
        force_refresh: bool,
        *,
        ignore_test_filter: bool,
    ) -> list[PythonTrack]:
        await asyncio.sleep(0)
        del force_refresh
        if not ignore_test_filter:
            message = "production Test Artists fetch must bypass recursive filtering"
            raise RuntimeError(message)
        matching_tracks = [
            track
            for track in self.tracks
            if track.artist == artist or track.album_artist == artist
        ]
        self.recorder.record_request([str(track.id) for track in matching_tracks])
        tracks = [track for track in matching_tracks if str(track.id) in self.response_ids]
        self.recorder.record_observation(tracks)
        return tracks


SmartDeltaExecutor = Callable[
    [SmartDeltaUpdaterSurface, bool],
    Awaitable[list[PythonTrack] | None],
]
TestArtistScopeExecutor = Callable[
    [TestArtistScopeSurface, bool],
    Awaitable[list[PythonTrack]],
]


@dataclass(frozen=True)
class PythonProductionPaths:
    smart_delta: SmartDeltaExecutor
    test_artist_scope: TestArtistScopeExecutor
    snapshot_compute: SnapshotCompute
    updated_track_detector: UpdatedTrackDetector
    fetch_output_parser: FetchOutputParser
    raw_track_parser: RawTrackParser
    smart_delta_merger: SmartDeltaMerger
    field_separator: str
    line_separator: str
    removed_invalidation: Callable[
        [
            SmartDeltaUpdaterSurface,
            list[str],
            dict[str, PythonTrack],
            CacheEventSink,
        ],
        None,
    ]
    identity_invalidation: Callable[
        [
            SmartDeltaUpdaterSurface,
            list[str],
            dict[str, PythonTrack],
            list[PythonTrack],
            CacheEventSink,
        ],
        None,
    ]


@dataclass(frozen=True)
class PythonBehavior:
    factory: TrackFactory
    compute_delta: ComputeTrackDelta
    has_track_changed: TrackComparison
    has_identity_changed: TrackComparison
    production_paths: PythonProductionPaths


@dataclass(frozen=True)
class PythonExecutionOutcome:
    delta: TrackDelta
    admitted_ids: list[str]
    previously_admitted_ids: list[str]
    acquisition: AcquisitionRecorder
    invalidation_targets: list[InvalidationTargetPayload]


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
        message = f"git {' '.join(arguments)} failed: {stderr.decode().strip()}"
        raise RuntimeError(message)
    return stdout


async def git_output(python_root: Path, *arguments: str) -> str:
    return (await git_bytes(python_root, *arguments)).decode().strip()


async def verify_python_checkout(python_root: Path, expected_baseline: str) -> str:
    baseline = await git_output(python_root, "rev-parse", "HEAD")
    if baseline != expected_baseline:
        message = (
            f"Python baseline mismatch: expected {expected_baseline}, found {baseline}"
        )
        raise RuntimeError(message)
    return baseline


def make_track(factory: TrackFactory, value: TrackInput) -> PythonTrack:
    return factory(
        id=value.identifier,
        name=f"Track {value.identifier}",
        artist=value.artist,
        album=value.album,
        album_artist=value.album_artist,
        genre=value.genre,
        year=value.year,
    )


def track_payload(track: TrackInput) -> TrackPayload:
    return {
        "identifier": track.identifier,
        "artist": track.artist,
        "album": track.album,
        "album_artist": track.album_artist,
        "genre": track.genre,
        "year": track.year,
    }


def album_target(track: PythonTrack) -> InvalidationTargetPayload:
    return {"artist": track.album_artist or track.artist, "album": track.album}


def swift_album_targets(track: PythonTrack) -> list[InvalidationTargetPayload]:
    artists = {track.artist}
    if track.album_artist:
        artists.add(track.album_artist)
    return [{"artist": artist, "album": track.album} for artist in sorted(artists)]


def unique_targets(
    targets: list[InvalidationTargetPayload],
) -> list[InvalidationTargetPayload]:
    unique = {(target["artist"], target["album"]): target for target in targets}
    return [unique[key] for key in sorted(unique)]


async def python_scope_ids(
    tracks: list[PythonTrack],
    test_artists: tuple[str, ...],
    scope_executor: TestArtistScopeExecutor,
    response_ids: set[str],
    recorder: AcquisitionRecorder | None = None,
) -> list[str]:
    if not test_artists:
        return sorted(track.id for track in tracks)
    active_recorder = recorder or AcquisitionRecorder()
    scoped_tracks = await scope_executor(
        TestArtistScopeHarness(
            tracks,
            test_artists,
            response_ids,
            active_recorder,
        ),
        False,
    )
    return AcquisitionRecorder.unique([track.id for track in scoped_tracks])


async def execute_python_workflow(
    scenario: ScenarioInput,
    tracks: ScenarioTracks,
    compute_delta: ComputeTrackDelta,
    production_paths: PythonProductionPaths,
) -> PythonExecutionOutcome:
    acquisition = AcquisitionRecorder()
    admitted_ids = await python_scope_ids(
        tracks.current,
        scenario.test_artists,
        production_paths.test_artist_scope,
        tracks.response_ids,
        acquisition if scenario.test_artists else None,
    )
    previously_admitted_ids = await python_scope_ids(
        tracks.previous,
        scenario.previous_test_artists,
        production_paths.test_artist_scope,
        set(tracks.previous_by_id),
    )
    cache_events = CacheEventRecorder()
    if scenario.test_artists:
        delta = compute_delta(tracks.current, tracks.previous_by_id)
        result: list[PythonTrack] | None = [
            tracks.current_by_id[identifier] for identifier in admitted_ids
        ]
    else:
        harness = SmartDeltaHarness(
            tracks,
            PythonHarnessState(cache_events, acquisition),
            production_paths,
        )
        result = await production_paths.smart_delta(
            harness,
            scenario.force_metadata_refresh,
        )
        delta = harness.snapshot_service.last_delta
        if delta is None:
            message = f"Python Smart Delta produced no delta for {scenario.identifier}"
            raise RuntimeError(message)
    if result is None:
        message = f"Python Smart Delta unexpectedly fell back for {scenario.identifier}"
        raise RuntimeError(message)
    return PythonExecutionOutcome(
        delta=delta,
        admitted_ids=admitted_ids,
        previously_admitted_ids=previously_admitted_ids,
        acquisition=acquisition,
        invalidation_targets=unique_targets(cache_events.targets),
    )


async def execute_scenario(
    scenario: ScenarioInput,
    behavior: PythonBehavior,
) -> ScenarioPayload:
    previous = [make_track(behavior.factory, track) for track in scenario.previous]
    current = [make_track(behavior.factory, track) for track in scenario.current]
    previous_by_id = {track.id: track for track in previous}
    current_by_id = {track.id: track for track in current}
    response_ids = set(
        scenario.metadata_response_ids
        if scenario.metadata_response_ids is not None
        else current_by_id
    )
    python_outcome = await execute_python_workflow(
        scenario,
        ScenarioTracks(
            previous=previous,
            current=current,
            previous_by_id=previous_by_id,
            current_by_id=current_by_id,
            response_ids=response_ids,
        ),
        behavior.compute_delta,
        behavior.production_paths,
    )
    delta = python_outcome.delta
    admitted_ids = python_outcome.admitted_ids
    processing_new_ids = [
        identifier
        for identifier in admitted_ids
        if identifier not in python_outcome.previously_admitted_ids
    ]
    metadata_request_ids = AcquisitionRecorder.unique(
        python_outcome.acquisition.requested_ids
    )
    observed_metadata_ids = AcquisitionRecorder.unique(
        python_outcome.acquisition.observed_ids
    )
    common_ids = sorted(previous_by_id.keys() & current_by_id.keys())
    observed_common_ids = [
        identifier for identifier in common_ids if identifier in observed_metadata_ids
    ]
    observed_updated_ids = [
        identifier
        for identifier in delta.updated_ids
        if identifier in observed_common_ids
        and behavior.has_track_changed(
            current_by_id[identifier], previous_by_id[identifier]
        )
    ]
    identity_changed_ids = [
        identifier
        for identifier in observed_common_ids
        if behavior.has_identity_changed(
            current_by_id[identifier], previous_by_id[identifier]
        )
    ]
    python_invalidation_targets = python_outcome.invalidation_targets

    unknown_identity_ids = current_by_id.keys() - previous_by_id.keys()
    requires_identity_snapshot = bool(scenario.test_artists) and (
        scenario.force_metadata_refresh or bool(unknown_identity_ids)
    )
    expected_identity_request_ids = (
        sorted(current_by_id.keys()) if requires_identity_snapshot else []
    )
    classification_upserted_ids = AcquisitionRecorder.unique(
        delta.new_ids + identity_changed_ids
    )
    classification_removed_ids = delta.removed_ids
    swift_invalidation_tracks = [
        current_by_id[identifier]
        for identifier in set(processing_new_ids).union(observed_updated_ids)
        if identifier in current_by_id
    ]
    for identifier in identity_changed_ids:
        swift_invalidation_tracks.extend(
            track
            for track in (
                previous_by_id.get(identifier),
                current_by_id.get(identifier),
            )
            if track is not None
        )
    swift_invalidation_tracks.extend(
        previous_by_id[identifier]
        for identifier in delta.removed_ids
        if identifier in previous_by_id
    )
    swift_invalidation_targets = unique_targets(
        [
            target
            for track in swift_invalidation_tracks
            for target in swift_album_targets(track)
        ]
    )
    stronger_reasons: list[str] = []
    if requires_identity_snapshot:
        stronger_reasons.append(
            "Swift classifies Test Artists membership from one generation-fenced full identity snapshot."
        )
    if swift_invalidation_targets != python_invalidation_targets:
        stronger_reasons.append(
            "Swift invalidates the closed old-and-new album identity set; Python emits only production Smart Delta events."
        )
    has_complete_metadata_response = response_ids == set(metadata_request_ids)
    if scenario.metadata_response_ids is not None and not has_complete_metadata_response:
        stronger_reasons.append(
            "Swift refuses incomplete metadata coverage; Python has no persisted readiness certificate."
        )
    if scenario.does_source_change_during_scan:
        stronger_reasons.append(
            "Swift retries a source-generation change before commit; Python has no source-generation observation fence."
        )

    previous_tracks = [track_payload(track) for track in scenario.previous]
    current_tracks = [track_payload(track) for track in scenario.current]

    return {
        "id": scenario.identifier,
        "description": scenario.description,
        "input": {
            "previousTracks": previous_tracks,
            "currentTracks": current_tracks,
            "previousTestArtists": list(scenario.previous_test_artists),
            "testArtists": list(scenario.test_artists),
            "forceMetadataRefresh": scenario.force_metadata_refresh,
            "metadataResponseIDs": sorted(response_ids),
            "sourceChangesDuringScan": scenario.does_source_change_during_scan,
        },
        "pythonExpected": {
            "membershipDelta": {
                "newIDs": delta.new_ids,
                "removedIDs": delta.removed_ids,
            },
            "managedMetadataChangedIDs": observed_updated_ids,
            "identityChangedIDs": identity_changed_ids,
            "admittedIDs": admitted_ids,
            "metadataRequestIDs": metadata_request_ids,
            "metadataObservedIDs": observed_metadata_ids,
            "invalidationTargets": python_invalidation_targets,
            "readiness": None,
            "downstreamDecision": "continue-with-snapshot",
        },
        "swiftExpected": {
            "identityRequestIDs": expected_identity_request_ids,
            "persistedClassificationUpsertedIDs": classification_upserted_ids,
            "persistedClassificationRemovedIDs": classification_removed_ids,
            "invalidationTargets": swift_invalidation_targets,
            "isReady": scenario.metadata_response_ids is None
            or has_complete_metadata_response,
            "downstreamDecision": (
                "continue-with-committed-mirror"
                if scenario.metadata_response_ids is None
                or has_complete_metadata_response
                else "refuse-incomplete-observation"
            ),
            "strongerContractReasons": stronger_reasons,
        },
    }


def verify_scope_contract(root: Path) -> None:
    source = (root / "applescripts/fetch_tracks.applescript").read_text(
        encoding="utf-8"
    )
    expected = "(artist is selectedArtist) or (album artist is selectedArtist)"
    if expected not in source:
        message = "Python Test Artists source contract changed"
        raise RuntimeError(message)


def required_production_callable(owner: object, name: str) -> object:
    member = getattr(owner, name, None)
    owner_name = getattr(owner, "__name__", type(owner).__name__)
    if not callable(member):
        message = f"Pinned Python production callable is missing: {owner_name}.{name}"
        raise TypeError(message)
    return member


async def build_fixture(root: Path, baseline: str) -> FixturePayload:
    sys.path.insert(0, str(root))
    sys.path.insert(0, str(root / "src"))
    verify_scope_contract(root)
    track_models = importlib.import_module("core.models.track_models")
    track_delta = importlib.import_module("core.tracks.track_delta")
    music_updater = importlib.import_module("app.music_updater")
    pipeline_snapshot = importlib.import_module("app.pipeline_snapshot")
    snapshot_service = importlib.import_module("services.cache.snapshot")
    track_processor = importlib.import_module("core.tracks.track_processor")
    factory = cast(TrackFactory, track_models.TrackDict)
    compute_delta = cast(ComputeTrackDelta, track_delta.compute_track_delta)
    has_track_changed = cast(TrackComparison, track_delta.has_track_changed)
    has_identity_changed = cast(
        TrackComparison, track_delta.has_identity_changed
    )
    updater_type = music_updater.MusicUpdater
    snapshot_type = snapshot_service.LibrarySnapshotService
    snapshot_manager_type = pipeline_snapshot.PipelineSnapshotManager
    production_paths = PythonProductionPaths(
        smart_delta=cast(
            SmartDeltaExecutor,
            required_production_callable(updater_type, "_try_smart_delta_fetch"),
        ),
        test_artist_scope=cast(
            TestArtistScopeExecutor,
            required_production_callable(
                track_processor.TrackProcessor,
                "_process_test_artists",
            ),
        ),
        snapshot_compute=cast(
            SnapshotCompute,
            snapshot_type.compute_smart_delta,
        ),
        updated_track_detector=cast(
            UpdatedTrackDetector,
            required_production_callable(snapshot_type, "_detect_updated_tracks"),
        ),
        fetch_output_parser=cast(
            FetchOutputParser,
            required_production_callable(snapshot_type, "_parse_fetch_tracks_output"),
        ),
        raw_track_parser=cast(
            RawTrackParser,
            required_production_callable(snapshot_type, "_parse_raw_track"),
        ),
        smart_delta_merger=cast(
            SmartDeltaMerger,
            snapshot_manager_type.merge_smart_delta,
        ),
        field_separator=cast(str, track_delta.FIELD_SEPARATOR),
        line_separator=cast(str, track_delta.LINE_SEPARATOR),
        removed_invalidation=cast(
            Callable[
                [
                    SmartDeltaUpdaterSurface,
                    list[str],
                    dict[str, PythonTrack],
                    CacheEventSink,
                ],
                None,
            ],
            required_production_callable(updater_type, "_emit_removed_track_events"),
        ),
        identity_invalidation=cast(
            Callable[
                [
                    SmartDeltaUpdaterSurface,
                    list[str],
                    dict[str, PythonTrack],
                    list[PythonTrack],
                    CacheEventSink,
                ],
                None,
            ],
            required_production_callable(updater_type, "_emit_identity_change_events"),
        ),
    )
    behavior = PythonBehavior(
        factory=factory,
        compute_delta=compute_delta,
        has_track_changed=has_track_changed,
        has_identity_changed=has_identity_changed,
        production_paths=production_paths,
    )
    cases: list[ScenarioPayload] = []
    for scenario in SCENARIOS:
        cases.append(await execute_scenario(scenario, behavior))
    return {
        "schemaVersion": 1,
        "pythonBaseline": baseline,
        "pythonEntryPoints": [
            "core.tracks.track_delta.compute_track_delta",
            "core.tracks.track_delta.has_track_changed",
            "core.tracks.track_delta.has_identity_changed",
            "app.music_updater.MusicUpdater._try_smart_delta_fetch",
            "services.cache.snapshot.LibrarySnapshotService.compute_smart_delta",
            "services.cache.snapshot.LibrarySnapshotService._detect_updated_tracks",
            "services.cache.snapshot.LibrarySnapshotService._parse_fetch_tracks_output",
            "services.cache.snapshot.LibrarySnapshotService._parse_raw_track",
            "app.pipeline_snapshot.PipelineSnapshotManager.merge_smart_delta",
            "core.tracks.track_processor.TrackProcessor._process_test_artists",
            "applescripts/fetch_tracks.applescript",
        ],
        "cases": cases,
    }


async def generate(python_root: Path, expected_baseline: str) -> FixturePayload:
    baseline = await verify_python_checkout(python_root, expected_baseline)
    archive = await git_bytes(python_root, "archive", "--format=tar", baseline)
    with tempfile.TemporaryDirectory(prefix="genre-updater-convergence-") as directory:
        source_root = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as source_archive:
            source_archive.extractall(source_root, filter="data")
        fixture = await build_fixture(source_root, baseline)
    if await verify_python_checkout(python_root, expected_baseline) != baseline:
        message = "Python HEAD changed during fixture generation"
        raise RuntimeError(message)
    return fixture


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--python-root", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    manifest = json.loads(
        arguments.manifest.resolve(strict=True).read_text(encoding="utf-8")
    )
    fixture = asyncio.run(
        generate(
            arguments.python_root.resolve(strict=True),
            str(manifest["pythonBaseline"]),
        )
    )
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(fixture, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
