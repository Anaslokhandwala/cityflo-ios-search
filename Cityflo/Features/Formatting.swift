import Foundation

/// All times are shown in IST, whatever the device time zone. A commuter
/// travelling with a phone set to another zone still needs bus times in Mumbai time.
enum IST {
    static let timeZone = TimeZone(identifier: "Asia/Kolkata")!

    static func time(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    static func dateTime(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.timeZone = timeZone
        return date.formatted(style) + " IST"
    }

    static func hour(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: date)
    }

    static func duration(_ duration: Duration) -> String {
        let minutes = Int(duration.components.seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }
}
