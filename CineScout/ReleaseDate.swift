import Foundation

enum ReleaseDate {
    private static let parser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func french(_ value: String?) -> String? {
        guard let value, let date = parser.date(from: value), parser.string(from: date) == value else { return nil }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted,
                                               locale: Locale(identifier: "fr_FR"),
                                               calendar: Calendar(identifier: .gregorian),
                                               timeZone: parser.timeZone))
    }
}
