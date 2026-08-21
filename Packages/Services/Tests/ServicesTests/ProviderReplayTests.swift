import Core
import Foundation
import Testing
@testable import Services

@Suite("Provider acquisition reference replay", .serialized)
struct ProviderReplayTests {
    @Test("Python acquisition cases preserve Swift requests and candidates")
    func replaysAcquisitionReference() async throws {
        let reference: ReplayReference = try loadFixture("provider_acquisition_reference")
        let replayDate = try #require(
            ISO8601DateFormatter().date(from: "2026-01-15T00:00:00Z")
        )

        #expect(reference.schemaVersion == 1)
        #expect(!reference.pythonBaseline.isEmpty)
        #expect(!reference.cases.isEmpty)

        for testCase in reference.cases {
            try await replay(testCase, at: replayDate)
        }
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
        let expected = testCase.expected.swiftCandidates ?? testCase.expected.pythonCandidates
        let expectedCandidates = expected.map(\.candidate)
        let context = "[\(testCase.id)] \(testCase.description)"

        #expect(candidates == expectedCandidates, Comment(rawValue: "\(context): candidates differ"))
        #expect(
            candidates.map(\.source) == testCase.expected.candidateSourceOrder,
            Comment(rawValue: "\(context): candidate source order differs")
        )
        #expect(
            expectedCandidates.map(\.source) == testCase.expected.candidateSourceOrder,
            Comment(rawValue: "\(context): fixture candidate source order is inconsistent")
        )

        for source in replaySources {
            let expectedRequests = testCase.expected.swiftRequests?[source]
                ?? testCase.expected.pythonRequests[source]
                ?? []
            #expect(
                router.requests(for: source) == expectedRequests,
                Comment(rawValue: "\(context): \(source.rawValue) requests differ")
            )
            #expect(
                router.remainingResponses(for: source) == 0,
                Comment(rawValue: "\(context): \(source.rawValue) has unused responses")
            )
        }
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

private struct ReplayCase: Decodable {
    struct Input: Decodable {
        let artist: String
        let album: String
        let artistRegion: String?
    }

    struct Expected: Decodable {
        let pythonRequests: SourceMap<[ReplayRequest]>
        let swiftRequests: SourceMap<[ReplayRequest]>?
        let candidateSourceOrder: [APISource]
        let pythonCandidates: [CandidateDTO]
        let swiftCandidates: [CandidateDTO]?
    }

    let id: String
    let description: String
    let input: Input
    let scriptedResponses: SourceMap<[ScriptedResponse]>
    let expected: Expected
}

private struct ScriptedResponse: Decodable {
    let statusCode: Int
    let body: [String: JSONValue]
}

private struct ReplayRequest: Decodable, Equatable {
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

    var candidate: ReleaseCandidate {
        ReleaseCandidate(
            artist: artist,
            album: album,
            year: year,
            source: source,
            releaseType: releaseType,
            status: status,
            country: country,
            isReissue: isReissue,
            mbReleaseGroupID: mbReleaseGroupID,
            mbReleaseGroupFirstYear: mbReleaseGroupFirstYear,
            genre: genre
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

private indirect enum JSONValue: Codable {
    case object([String: Self])
    case array([Self])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
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
