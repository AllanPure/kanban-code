import Foundation

/// A subscribed calendar (an iCal .ics URL the user configures — e.g. Google Calendar's
/// "secret address in iCal format"). Persisted in ~/.kanban-code/calendars.json.
public struct CalendarSource: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public var name: String
    public var url: String
    public var enabled: Bool
    public var colorHex: String

    public init(id: String = KSUID.generate(prefix: "cal"),
                name: String, url: String, enabled: Bool = true, colorHex: String) {
        self.id = id; self.name = name; self.url = url; self.enabled = enabled; self.colorHex = colorHex
    }
}

/// A parsed calendar event (from an iCal feed), for the week calendar overlay.
public struct CalendarEvent: Identifiable, Sendable, Equatable {
    public let id: String
    public let start: Date
    public let end: Date?
    public let summary: String
    public let allDay: Bool
    public let calendarName: String
    public let colorHex: String

    public init(id: String, start: Date, end: Date?, summary: String, allDay: Bool, calendarName: String, colorHex: String) {
        self.id = id; self.start = start; self.end = end; self.summary = summary
        self.allDay = allDay; self.calendarName = calendarName; self.colorHex = colorHex
    }
}

/// Read/write the configured calendar subscriptions (calendars.json).
public enum CalendarStore {
    public static func filePath(basePath: String? = nil) -> String {
        let base = basePath ?? (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        return (base as NSString).appendingPathComponent("calendars.json")
    }
    public static func read(basePath: String? = nil) -> [CalendarSource] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath(basePath: basePath))),
              let sources = try? JSONDecoder().decode([CalendarSource].self, from: data) else { return [] }
        return sources
    }
    public static func write(_ sources: [CalendarSource], basePath: String? = nil) {
        let path = filePath(basePath: basePath)
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sources) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// A default palette to assign new calendars.
    public static let palette = ["#E5484D", "#3E63DD", "#30A46C", "#F76B15", "#8E4EC6", "#0091FF"]
}

public enum CalendarFeed {
    /// Fetch and parse the events of every enabled calendar subscription.
    public static func loadEvents(sources: [CalendarSource]) async -> [CalendarEvent] {
        var all: [CalendarEvent] = []
        for source in sources where source.enabled {
            var ics: String?
            if source.url.hasPrefix("/") || source.url.hasPrefix("file://") {
                // Imported local .ics file — read from disk (picks up re-exports in place).
                let path = source.url.hasPrefix("file://") ? (URL(string: source.url)?.path ?? source.url) : source.url
                ics = try? String(contentsOfFile: path, encoding: .utf8)
            } else {
                // Google's iCal "secret address" is often given as webcal://; normalise to https.
                let normalized = source.url.replacingOccurrences(of: "webcal://", with: "https://")
                if let url = URL(string: normalized), let (data, _) = try? await URLSession.shared.data(from: url) {
                    ics = String(data: data, encoding: .utf8)
                }
            }
            guard let ics else { continue }
            all.append(contentsOf: ICSParser.parse(ics, calendarName: source.name, colorHex: source.colorHex))
        }
        return all
    }
}

public enum ICSParser {
    /// Parse an iCal document into events for one calendar. Handles DTSTART/DTEND with
    /// UTC (`Z`), `TZID=`, and all-day (`VALUE=DATE`). Recurring events (RRULE) are not
    /// expanded — only their base occurrence is emitted.
    public static func parse(_ ics: String, calendarName: String, colorHex: String) -> [CalendarEvent] {
        var events: [CalendarEvent] = []
        var inEvent = false
        var uid: String?, summary: String?
        var start: (date: Date, allDay: Bool)?
        var end: (date: Date, allDay: Bool)?

        for line in unfold(ics) {
            if line == "BEGIN:VEVENT" {
                inEvent = true; uid = nil; summary = nil; start = nil; end = nil; continue
            }
            if line == "END:VEVENT" {
                if let s = start {
                    events.append(CalendarEvent(
                        id: uid ?? UUID().uuidString,
                        start: s.date, end: end?.date, summary: summary ?? "(no title)",
                        allDay: s.allDay, calendarName: calendarName, colorHex: colorHex))
                }
                inEvent = false; continue
            }
            guard inEvent else { continue }
            let (name, params, value) = splitProperty(line)
            switch name {
            case "UID": uid = value
            case "SUMMARY": summary = unescapeText(value)
            case "DTSTART": start = parseDate(value: value, params: params)
            case "DTEND": end = parseDate(value: value, params: params)
            default: break
            }
        }
        return events
    }

    /// Unfold RFC 5545 line folding: a line starting with a space or tab continues the
    /// previous one. Also normalises CRLF.
    static func unfold(_ ics: String) -> [String] {
        let raw = ics.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for line in raw {
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += line.dropFirst()
            } else {
                out.append(String(line))
            }
        }
        return out
    }

    /// Split `NAME;PARAM=VAL;PARAM2=VAL2:VALUE` into (name, params, value).
    static func splitProperty(_ line: String) -> (name: String, params: [String: String], value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, [:], "") }
        let lhs = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let parts = lhs.split(separator: ";").map(String.init)
        let name = parts.first ?? lhs
        var params: [String: String] = [:]
        for p in parts.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1] }
        }
        return (name.uppercased(), params, value)
    }

    static func parseDate(value: String, params: [String: String]) -> (date: Date, allDay: Bool)? {
        // All-day: VALUE=DATE, "yyyyMMdd"
        if params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T")) {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: params["TZID"] ?? "") ?? .current
            if let d = f.date(from: value) { return (d, true) }
            return nil
        }
        // Datetime: "yyyyMMdd'T'HHmmss" (+ optional Z)
        let isUTC = value.hasSuffix("Z")
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd'T'HHmmss"
        if isUTC {
            f.timeZone = TimeZone(identifier: "UTC")
        } else {
            f.timeZone = TimeZone(identifier: params["TZID"] ?? "") ?? .current
        }
        if let d = f.date(from: value.hasSuffix("Z") ? String(value.dropLast()) : value) {
            return (d, false)
        }
        return nil
    }

    static func unescapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\,", with: ",")
         .replacingOccurrences(of: "\\;", with: ";")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
