import Foundation

@main
struct SeerrChecks {
    static func main() async throws {
        let client = try SeerrClient(address: " https://media.example.org/seerr/api/v1/ ", key: " test-key ")
        precondition(client.base.absoluteString == "https://media.example.org/seerr")
        precondition(client.key == "test-key")
        precondition((try? SeerrClient(address: "http://media.example.org", key: "test-key")) == nil)
        let json = """
        {"id":17,"seasons":[{"seasonNumber":0},{"seasonNumber":1},{"seasonNumber":2},{"seasonNumber":3}],
         "mediaInfo":{"status":4,"seasons":[{"seasonNumber":1,"status":5}],
         "requests":[{"status":1,"is4k":false,"seasons":[{"seasonNumber":2}]},
                     {"status":3,"is4k":false,"seasons":[{"seasonNumber":3}]}]}}
        """
        let series = try JSONDecoder().decode(SeerrClient.Media.self, from: Data(json.utf8))
        precondition(series.blockedSeasons == [1, 2])
        let encoder = JSONEncoder()
        let movie = try encoder.encode(SeerrClient.Submission(mediaType: "movie", mediaId: 17, seasons: nil))
        let movieJSON = try JSONSerialization.jsonObject(with: movie) as? [String: Any]
        precondition(movieJSON?["mediaType"] as? String == "movie" && movieJSON?["seasons"] == nil)
        let tv = try encoder.encode(SeerrClient.Submission(mediaType: "tv", mediaId: 17, seasons: [3]))
        let tvJSON = try JSONSerialization.jsonObject(with: tv) as? [String: Any]
        precondition(tvJSON?["seasons"] as? [Int] == [3])
        precondition(ReleaseDate.french("2024-02-29") == "29 février 2024")
        precondition(ReleaseDate.french("2025-02-29") == nil)
        precondition(ReleaseDate.french("") == nil)
        try await checkRequestFlow()
        print("Seerr HTTP flow, season availability, request encoding and release dates passed.")
    }

    private static func checkRequestFlow() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let client = try SeerrClient(address: "https://media.example.org/seerr", key: "test-key",
                                     session: URLSession(configuration: configuration))
        try await client.check()
        let media = try await client.details(kind: "tv", id: 17)
        precondition(media.seasons?.first?.seasonNumber == 3)
        let receipt = try await client.submit(.init(mediaType: "tv", mediaId: 17, seasons: [3]))
        precondition(receipt.id == 42 && receipt.status == 2)
        let refreshed = try await client.receipt(id: receipt.id)
        precondition(refreshed.status == 4 && refreshed.label.contains("échec"))
        do {
            _ = try await client.submit(.init(mediaType: "tv", mediaId: 17, seasons: [3]))
            preconditionFailure("HTTP 202 is not a successful Seerr request")
        } catch {
            precondition(error.localizedDescription.contains("aucune demande (202)"))
        }
        do {
            _ = try await client.details(kind: "movie", id: 16)
            preconditionFailure("Invalid credentials should fail")
        } catch {
            precondition(error.localizedDescription.contains("403"))
        }
    }
}

private final class FixtureProtocol: URLProtocol {
    private static var posted = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        precondition(request.value(forHTTPHeaderField: "X-Api-Key") == "test-key")
        guard let url = request.url, let client else { preconditionFailure("Malformed fixture request") }
        let reply: (Int, String)
        switch (request.httpMethod, url.path) {
        case ("GET", "/seerr/api/v1/auth/me"):
            reply = (200, #"{"id":1}"#)
        case ("GET", "/seerr/api/v1/tv/17"):
            reply = (200, #"{"id":17,"seasons":[{"seasonNumber":3}]}"#)
        case ("GET", "/seerr/api/v1/movie/16"):
            reply = (403, #"{"error":"You do not have permission to access this endpoint"}"#)
        case ("POST", "/seerr/api/v1/request"):
            precondition(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            reply = Self.posted ? (202, #"{"message":"No seasons available to request"}"#)
                                : (201, #"{"id":42,"status":2}"#)
            Self.posted = true
        case ("GET", "/seerr/api/v1/request/42"):
            reply = (200, #"{"id":42,"status":4}"#)
        default:
            preconditionFailure("Unexpected fixture path: \(url.path)")
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client.urlProtocolDidFinishLoading(self)
    }
}
