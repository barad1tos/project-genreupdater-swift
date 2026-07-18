import Foundation
import Testing
@testable import Core
@testable import Services

// MARK: - MusicBrainzClientTests

@Suite("MusicBrainzClient — MusicBrainz API JSON parsing and URL building")
struct MusicBrainzClientTests {
    // MARK: - JSON Parsing

    @Test("Parse release group search response")
    func parseReleaseGroupResponse() throws {
        let json = """
        {
            "release-groups": [
                {
                    "id": "abc-123",
                    "title": "Ride the Lightning",
                    "primary-type": "Album",
                    "first-release-date": "1984-07-27",
                    "tags": [{"name": "thrash metal", "count": 15}],
                    "genres": [{"name": "metal", "count": 8}]
                }
            ]
        }
        """

        let response = try JSONDecoder().decode(
            MBReleaseGroupSearchResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.releaseGroups.count == 1)

        let group = response.releaseGroups[0]
        #expect(group.releaseYear == 1984)
        #expect(group.title == "Ride the Lightning")
        #expect(group.primaryType == "Album")
        #expect(group.tags?.first?.name == "thrash metal")
        #expect(group.genres?.first?.name == "metal")
    }

    @Test("Parse artist search response with life-span")
    func parseArtistSearchResponse() throws {
        let json = """
        {
            "artists": [
                {
                    "id": "def-456",
                    "name": "Metallica",
                    "type": "Group",
                    "life-span": {
                        "begin": "1981-10",
                        "end": null,
                        "ended": false
                    }
                }
            ]
        }
        """

        let response = try JSONDecoder().decode(
            MBArtistSearchResponse.self,
            from: Data(json.utf8)
        )

        #expect(response.artists.count == 1)

        let artist = response.artists[0]
        #expect(artist.name == "Metallica")
        #expect(artist.type == "Group")
        #expect(artist.lifeSpan?.beginYear == 1981)
        #expect(artist.lifeSpan?.endYear == nil)
        #expect(artist.lifeSpan?.ended == false)
    }

    // MARK: - Year Extraction

    @Test("Release year extraction handles partial dates like '1984'")
    func releaseYearPartialDate() {
        let group = MBReleaseGroup(
            id: "test-id",
            title: "Test Album",
            primaryType: "Album",
            firstReleaseDate: "1984",
            tags: nil,
            genres: nil
        )

        #expect(group.releaseYear == 1984)
    }

    @Test("Release year extraction returns nil for nil date")
    func releaseYearNilDate() {
        let group = MBReleaseGroup(
            id: "test-id",
            title: "Test Album",
            primaryType: nil,
            firstReleaseDate: nil,
            tags: nil,
            genres: nil
        )

        #expect(group.releaseYear == nil)
    }

    // MARK: - URL Building

    @Test("buildReleaseGroupSearchURL encodes query correctly")
    func buildReleaseGroupSearchURL() throws {
        let url = MusicBrainzClient.buildReleaseGroupSearchURL(
            artist: "Iron Maiden",
            album: "Powerslave"
        )

        #expect(url != nil)

        let urlString = try #require(url?.absoluteString)
        #expect(urlString.contains("release-group"))
        #expect(urlString.contains("fmt=json"))
        #expect(urlString.contains("limit=5"))
        // URLComponents percent-encodes spaces
        #expect(urlString.contains("Iron%20Maiden") || urlString.contains("Iron+Maiden"))
    }

    @Test("buildArtistSearchURL encodes query correctly")
    func buildArtistSearchURL() throws {
        let url = MusicBrainzClient.buildArtistSearchURL(
            artist: "Motorhead"
        )

        #expect(url != nil)

        let urlString = try #require(url?.absoluteString)
        #expect(urlString.contains("artist"))
        #expect(urlString.contains("fmt=json"))
        #expect(urlString.contains("limit=1"))
    }

    // MARK: - Request Headers

    @Test("makeRequest sets correct User-Agent header")
    func userAgentHeader() throws {
        let client = MusicBrainzClient()
        let testURL = try #require(URL(string: "https://musicbrainz.org/ws/2/release-group"))
        let request = client.makeRequest(for: testURL)

        let userAgent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
        #expect(userAgent.contains("GenreUpdater"))

        let accept = request.value(forHTTPHeaderField: "Accept")
        #expect(accept == "application/json")
    }
}
