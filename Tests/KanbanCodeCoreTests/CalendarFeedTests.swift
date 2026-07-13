import Testing
import Foundation
@testable import KanbanCodeCore

@Suite("iCal parser")
struct CalendarFeedTests {
    @Test("parses timed (TZID), all-day, and UTC events")
    func parseEvents() {
        let ics = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:1
        DTSTART;TZID=Europe/Paris:20260713T084500
        DTEND;TZID=Europe/Paris:20260713T093000
        SUMMARY:Réunion Team
        END:VEVENT
        BEGIN:VEVENT
        UID:2
        DTSTART;VALUE=DATE:20260714
        DTEND;VALUE=DATE:20260715
        SUMMARY:La fête nationale
        END:VEVENT
        BEGIN:VEVENT
        UID:3
        DTSTART:20260713T064500Z
        SUMMARY:UTC event
        END:VEVENT
        END:VCALENDAR
        """
        let events = ICSParser.parse(ics, calendarName: "Bureau", colorHex: "#E5484D")
        #expect(events.count == 3)
        #expect(events[0].summary == "Réunion Team")
        #expect(events[0].allDay == false)
        #expect(events[1].allDay == true)
        // Paris 08:45 (CEST = UTC+2 in July) equals the UTC 06:45 event.
        #expect(abs(events[0].start.timeIntervalSince1970 - events[2].start.timeIntervalSince1970) < 1)
        #expect(events[0].calendarName == "Bureau")
    }

    @Test("unfolds folded lines and unescapes text")
    func unfoldAndEscape() {
        let ics = "BEGIN:VEVENT\nDTSTART:20260713T090000Z\nSUMMARY:Long title that is\n  folded across lines\\, with comma\nEND:VEVENT"
        let events = ICSParser.parse(ics, calendarName: "c", colorHex: "#000")
        #expect(events.count == 1)
        #expect(events[0].summary == "Long title that is folded across lines, with comma")
    }
}
