import Core
import Foundation
import Testing
@testable import Services

@Suite("Provider acquisition reference replay", .serialized)
struct ProviderReplayTests {
    @Test("Python acquisition cases preserve Swift requests and candidates")
    func replaysAcquisitionReference() async throws {
        let reference: ReplayReference = try loadFixture("provider_acquisition_reference")
        let manifest: ReplayManifest = try loadFixture("fixtures_manifest")
        let replayDate = try #require(
            ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")
        )

        #expect(reference.schemaVersion == 2)
        #expect(reference.pythonBaseline == manifest.pythonBaseline)
        #expect(!reference.cases.isEmpty)

        for testCase in reference.cases {
            try await replay(testCase, at: replayDate)
        }
    }

    @Test("candidate projection covers every stored field")
    func coversCandidateFields() {
        let candidate = ReleaseCandidate(
            artist: "Artist",
            album: "Album",
            year: 2000,
            source: .musicBrainz,
            releaseType: .album,
            status: .official
        )
        let storedFields = Set(Mirror(reflecting: candidate).children.compactMap(\.label))

        #expect(storedFields == Set(CandidateField.allCases.map(\.rawValue)))
    }

    @Test("scripted JSON preserves integer identities beyond Double precision")
    func preservesIntegerIdentity() throws {
        let data = Data(#"{"id":9007199254740993,"offset":-9007199254740993}"#.utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let encoded = try JSONEncoder().encode(decoded)

        let encodedJSON = try #require(String(data: encoded, encoding: .utf8))
        #expect(encodedJSON.contains(#""id":9007199254740993"#))
        #expect(encodedJSON.contains(#""offset":-9007199254740993"#))
    }

    private func replay(_ testCase: ReplayCase, at date: Date) async throws {
        let router = ReplayRouter(responses: testCase.scriptedResponses.values)
        ReplayURLProtocol.router = router
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplayURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            ReplayURLProtocol.router = nil
        }

        let orchestrator = makeOrchestrator(for: testCase, date: date, session: session)
        let candidates = await orchestrator.getReleaseCandidates(
            artist: testCase.input.artist,
            album: testCase.input.album,
            currentLibraryYear: nil,
            earliestTrackAddedYear: nil
        )
        let context = "[\(testCase.id)] \(testCase.description)"
        try assertCandidateParity(candidates, for: testCase, context: context)

        for source in replaySources {
            let swiftRequests = router.requests(for: source)
            let requestDifferences = try requestDifferences(
                source: source,
                python: testCase.expected.pythonRequests[source] ?? [],
                swift: swiftRequests
            )
            let expectedRequestDifferences = testCase.divergences.requests
                .filter { $0.source == source }
                .map(\.identity)
                .sorted { $0.isOrdered(before: $1) }
            #expect(
                requestDifferences.elementsEqual(expectedRequestDifferences) {
                    $0.matches($1)
                },
                Comment(rawValue: "\(context): \(source.rawValue) request divergences differ")
            )
            #expect(
                router.remainingResponses(for: source) == 0,
                Comment(rawValue: "\(context): \(source.rawValue) has unused responses")
            )
        }
    }

    private func assertCandidateParity(
        _ candidates: [ReleaseCandidate],
        for testCase: ReplayCase,
        context: String
    ) throws {
        let candidateDifferences = try candidateDifferences(
            python: testCase.expected.pythonCandidates,
            swift: candidates
        )
        let expectedCandidateDifferences = testCase.divergences.candidates
            .map(\.identity)
            .sorted { $0.isOrdered(before: $1) }

        #expect(
            candidateDifferences.elementsEqual(expectedCandidateDifferences) {
                $0.matches($1)
            },
            Comment(rawValue: "\(context): candidate divergences differ")
        )
        #expect(
            candidates.map(\.source) == testCase.expected.candidateSourceOrder,
            Comment(rawValue: "\(context): candidate source order differs")
        )
        #expect(
            testCase.expected.pythonCandidates.map(\.source) == testCase.expected.candidateSourceOrder,
            Comment(rawValue: "\(context): fixture candidate source order is inconsistent")
        )
        #expect(testCase.divergences.candidates.allSatisfy { !$0.reason.isEmpty })
        #expect(testCase.divergences.requests.allSatisfy { !$0.reason.isEmpty })
    }

    private func candidateDifferences(
        python: [CandidateDTO],
        swift: [ReleaseCandidate]
    ) throws -> [CandidateDifference.Identity] {
        guard python.count == swift.count else {
            throw ReplayError.candidateCount(python: python.count, swift: swift.count)
        }
        return zip(python, swift).enumerated().flatMap { index, pair in
            let swiftCandidate = CandidateDTO(pair.1)
            precondition(pair.0.fields.map(\.field) == CandidateField.allCases)
            precondition(swiftCandidate.fields.map(\.field) == CandidateField.allCases)
            return zip(pair.0.fields, swiftCandidate.fields).compactMap { pythonField, swiftField
                -> CandidateDifference.Identity? in
                guard pythonField.value != swiftField.value else { return nil }
                return CandidateDifference.Identity(
                    candidateIndex: index,
                    field: pythonField.field,
                    pythonValue: pythonField.value,
                    swiftValue: swiftField.value
                )
            }
        }.sorted { $0.isOrdered(before: $1) }
    }

    private func requestDifferences(
        source: APISource,
        python: [ReplayRequest],
        swift: [ReplayRequest]
    ) throws -> [RequestDifference.Identity] {
        guard python.count == swift.count else {
            throw ReplayError.requestCount(source: source, python: python.count, swift: swift.count)
        }
        return try zip(python, swift).enumerated().flatMap { index, pair in
            guard pair.0.scheme == pair.1.scheme,
                  pair.0.host == pair.1.host,
                  pair.0.port == pair.1.port,
                  pair.0.path == pair.1.path
            else {
                throw ReplayError.requestTarget(source: source, ordinal: index)
            }
            guard pair.0.query.map(\.name) == pair.1.query.map(\.name) else {
                throw ReplayError.requestShape(source: source, ordinal: index)
            }
            return zip(pair.0.query, pair.1.query).compactMap { pythonItem, swiftItem -> RequestDifference.Identity? in
                guard pythonItem.value != swiftItem.value else { return nil }
                return RequestDifference.Identity(
                    source: source,
                    requestIndex: index,
                    queryName: pythonItem.name,
                    pythonValue: pythonItem.value,
                    swiftValue: swiftItem.value
                )
            }
        }.sorted { $0.isOrdered(before: $1) }
    }

    private func makeOrchestrator(
        for testCase: ReplayCase,
        date: Date,
        session: URLSession
    ) -> APIOrchestrator {
        let services = APIOrchestratorServices(
            musicBrainz: MusicBrainzClient(
                appName: "GenreUpdaterTests",
                contactEmail: "tests@example.invalid",
                session: session,
                rateLimiter: limiter(for: .musicBrainz, in: testCase)
            ),
            discogs: DiscogsClient(
                token: "fixture-token",
                session: session,
                rateLimiter: limiter(for: .discogs, in: testCase)
            ),
            appleMusic: CatalogSearchClient(
                session: session,
                rateLimiter: limiter(for: .itunes, in: testCase),
                dateProvider: { date }
            )
        )
        var orchestratorConfiguration = APIOrchestratorConfiguration()
        orchestratorConfiguration.dateProvider = { date }
        return APIOrchestrator(
            services: services,
            configuration: orchestratorConfiguration
        )
    }

    private func limiter(for source: APISource, in testCase: ReplayCase) -> TokenBucketRateLimiter {
        TokenBucketRateLimiter(
            maxTokens: max(1, testCase.scriptedResponses[source]?.count ?? 0),
            refillInterval: .seconds(1)
        )
    }

    private func loadFixture<T: Decodable>(_ name: String) throws -> T {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private let replaySources: [APISource] = [.musicBrainz, .discogs, .itunes]

private struct ReplayReference: Decodable {
    let schemaVersion: Int
    let pythonBaseline: String
    let cases: [ReplayCase]
}

private struct ReplayManifest: Decodable {
    let pythonBaseline: String
}

private struct ReplayCase: Decodable {
    struct Input: Decodable {
        let artist: String
        let album: String
        let artistRegion: String?
    }

    struct Expected: Decodable {
        let pythonRequests: SourceMap<[ReplayRequest]>
        let candidateSourceOrder: [APISource]
        let pythonCandidates: [CandidateDTO]
    }

    let id: String
    let description: String
    let input: Input
    let scriptedResponses: SourceMap<[ScriptedResponse]>
    let expected: Expected
    let divergences: Divergences
}

private struct Divergences: Decodable {
    let requests: [RequestDifference]
    let candidates: [CandidateDifference]
}

private struct ScriptedResponse: Decodable {
    let statusCode: Int
    let body: [String: JSONValue]
}

private struct ReplayRequest: Decodable, Equatable {
    let scheme: String
    let host: String
    let port: Int?
    let path: String
    let query: [QueryItem]
}

private struct QueryItem: Decodable, Equatable {
    let name: String
    let value: String
}

private struct CandidateDTO: Decodable {
    let artist: String
    let album: String
    let year: Int
    let source: APISource
    let releaseType: ReleaseType
    let status: ReleaseStatus
    let country: String?
    let isReissue: Bool
    let mbReleaseGroupID: String?
    let mbReleaseGroupFirstYear: Int?
    let genre: String?

    init(_ candidate: ReleaseCandidate) {
        artist = candidate.artist
        album = candidate.album
        year = candidate.year
        source = candidate.source
        releaseType = candidate.releaseType
        status = candidate.status
        country = candidate.country
        isReissue = candidate.isReissue
        mbReleaseGroupID = candidate.mbReleaseGroupID
        mbReleaseGroupFirstYear = candidate.mbReleaseGroupFirstYear
        genre = candidate.genre
    }

    var fields: [(field: CandidateField, value: JSONValue)] {
        [
            (.artist, .string(artist)),
            (.album, .string(album)),
            (.year, .integer(Int64(year))),
            (.source, .string(source.rawValue)),
            (.releaseType, .string(releaseType.rawValue)),
            (.status, .string(status.rawValue)),
            (.country, country.map(JSONValue.string) ?? .null),
            (.isReissue, .bool(isReissue)),
            (.mbReleaseGroupID, mbReleaseGroupID.map(JSONValue.string) ?? .null),
            (
                .mbReleaseGroupFirstYear,
                mbReleaseGroupFirstYear.map { .integer(Int64($0)) } ?? .null
            ),
            (.genre, genre.map(JSONValue.string) ?? .null),
        ]
    }
}

private enum CandidateField: String, CaseIterable, Decodable {
    case artist
    case album
    case year
    case source
    case releaseType
    case status
    case country
    case isReissue
    case mbReleaseGroupID
    case mbReleaseGroupFirstYear
    case genre
}

private struct CandidateDifference: Decodable {
    struct Identity {
        let candidateIndex: Int
        let field: CandidateField
        let pythonValue: JSONValue
        let swiftValue: JSONValue

        func isOrdered(before other: Self) -> Bool {
            (candidateIndex, field.rawValue) < (other.candidateIndex, other.field.rawValue)
        }

        func matches(_ other: Self) -> Bool {
            candidateIndex == other.candidateIndex
                && field == other.field
                && pythonValue == other.pythonValue
                && swiftValue == other.swiftValue
        }
    }

    let candidateIndex: Int
    let field: CandidateField
    let pythonValue: JSONValue
    let swiftValue: JSONValue
    let reason: String

    var identity: Identity {
        Identity(
            candidateIndex: candidateIndex,
            field: field,
            pythonValue: pythonValue,
            swiftValue: swiftValue
        )
    }
}

private struct RequestDifference: Decodable {
    struct Identity {
        let source: APISource
        let requestIndex: Int
        let queryName: String
        let pythonValue: String
        let swiftValue: String

        func isOrdered(before other: Self) -> Bool {
            (source.rawValue, requestIndex, queryName)
                < (other.source.rawValue, other.requestIndex, other.queryName)
        }

        func matches(_ other: Self) -> Bool {
            source == other.source
                && requestIndex == other.requestIndex
                && queryName == other.queryName
                && pythonValue == other.pythonValue
                && swiftValue == other.swiftValue
        }
    }

    let source: APISource
    let requestIndex: Int
    let queryName: String
    let pythonValue: String
    let swiftValue: String
    let reason: String

    var identity: Identity {
        Identity(
            source: source,
            requestIndex: requestIndex,
            queryName: queryName,
            pythonValue: pythonValue,
            swiftValue: swiftValue
        )
    }
}

private struct SourceMap<Value: Decodable>: Decodable {
    let values: [APISource: Value]

    subscript(source: APISource) -> Value? {
        values[source]
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: SourceKey.self)
        var decoded: [APISource: Value] = [:]
        for key in container.allKeys {
            guard let source = APISource(rawValue: key.stringValue), source != .unknown else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "unsupported provider \(key.stringValue)"
                )
            }
            decoded[source] = try container.decode(Value.self, forKey: key)
        }
        values = decoded
    }
}

private struct SourceKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue _: Int) {
        nil
    }
}

private indirect enum JSONValue: Codable, Equatable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case integer(Int64)
    case unsignedInteger(UInt64)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .unsignedInteger(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private final class ReplayRouter: @unchecked Sendable {
    private let lock = NSLock()
    private let responses: [APISource: [ScriptedResponse]]
    private var offsets: [APISource: Int] = [:]
    private var captured: [APISource: [ReplayRequest]] = [:]

    init(responses: [APISource: [ScriptedResponse]]) {
        self.responses = responses
    }

    func response(for request: URLRequest) throws -> ScriptedResponse {
        let source = try provider(for: request)
        let capturedRequest = try replayRequest(from: request)
        return try lock.withLock {
            let offset = offsets[source, default: 0]
            captured[source, default: []].append(capturedRequest)
            guard let scripted = responses[source], scripted.indices.contains(offset) else {
                throw ReplayError.unexpectedRequest(source: source, ordinal: offset)
            }
            offsets[source] = offset + 1
            return scripted[offset]
        }
    }

    func requests(for source: APISource) -> [ReplayRequest] {
        lock.withLock { captured[source, default: []] }
    }

    func remainingResponses(for source: APISource) -> Int {
        lock.withLock {
            max(0, (responses[source]?.count ?? 0) - offsets[source, default: 0])
        }
    }

    private func provider(for request: URLRequest) throws -> APISource {
        guard let host = request.url?.host?.lowercased() else {
            throw ReplayError.invalidURL
        }
        if host == MusicBrainzClient.defaultBaseURL.host?.lowercased() {
            return .musicBrainz
        }
        if host == DiscogsClient.defaultBaseURL.host?.lowercased() {
            return .discogs
        }
        if host == CatalogSearchClient.defaultITunesHost {
            return .itunes
        }
        throw ReplayError.unsupportedHost(host)
    }

    private func replayRequest(from request: URLRequest) throws -> ReplayRequest {
        guard let url = request.url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw ReplayError.invalidURL
        }
        let path = components.path.hasSuffix("/") && components.path.count > 1
            ? String(components.path.dropLast())
            : components.path
        return ReplayRequest(
            scheme: components.scheme ?? "",
            host: components.host ?? "",
            port: components.port,
            path: path,
            query: (components.queryItems ?? [])
                .map { QueryItem(name: $0.name, value: $0.value ?? "") }
                .sorted { ($0.name, $0.value) < ($1.name, $1.value) }
        )
    }
}

private enum ReplayError: Error {
    case invalidURL
    case unsupportedHost(String)
    case unexpectedRequest(source: APISource, ordinal: Int)
    case missingRouter
    case invalidResponse
    case candidateCount(python: Int, swift: Int)
    case requestCount(source: APISource, python: Int, swift: Int)
    case requestTarget(source: APISource, ordinal: Int)
    case requestShape(source: APISource, ordinal: Int)
}

private final class ReplayURLProtocol: URLProtocol {
    nonisolated(unsafe) static var router: ReplayRouter?

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https" || request.url?.scheme == "http"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let router = Self.router else {
                throw ReplayError.missingRouter
            }
            let scripted = try router.response(for: request)
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: scripted.statusCode,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "application/json"]
                  )
            else {
                throw ReplayError.invalidResponse
            }
            let data = try JSONEncoder().encode(scripted.body)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
