import Foundation

@main
struct SeerrChecks {
    static func main() throws {
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
        print("Seerr URL, status and request payload checks passed.")
    }
}
