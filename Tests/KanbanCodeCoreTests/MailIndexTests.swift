import Testing
import Foundation
@testable import KanbanCodeCore

@Suite struct MailIndexTests {
    /// Build a minimal .emlx blob: "<length>\n<message><plist>".
    private func emlx(message: String, flags: Int?) -> Data {
        let msgBytes = Array(message.utf8)
        var out = "\(msgBytes.count)\n".data(using: .utf8)!
        out.append(Data(msgBytes))
        if let flags {
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict><key>flags</key><integer>\(flags)</integer></dict></plist>
            """
            out.append(plist.data(using: .utf8)!)
        }
        return out
    }

    @Test func parsesHeadersAndUnreadFlag() {
        let message = """
        From: Patrick Profit <patrick@pure-illusion.com>
        To: allan@pure-illusion.com
        Subject: Suite à notre démo
        Date: Tue, 7 Jul 2026 08:21:57 +0200
        Message-ID: <abc123@pure-illusion.com>

        Bonjour Allan, peux-tu regarder ceci ?
        """
        // flags = 0 → bit0 unset → unread
        let parsed = MailIndexer.parseEmlx(data: emlx(message: message, flags: 0), fallbackDate: .distantPast)
        #expect(parsed != nil)
        #expect(parsed?.from == "Patrick Profit")
        #expect(parsed?.subject == "Suite à notre démo")
        #expect(parsed?.id == "<abc123@pure-illusion.com>")
        #expect(parsed?.unread == true)
        #expect(parsed?.snippet.contains("Bonjour Allan") == true)
    }

    @Test func readFlagMarksAsRead() {
        let message = "From: a@b.com\nSubject: x\nDate: Tue, 7 Jul 2026 08:21:57 +0200\n\nbody"
        // flags = 1 → bit0 set → read
        let parsed = MailIndexer.parseEmlx(data: emlx(message: message, flags: 1), fallbackDate: .distantPast)
        #expect(parsed?.unread == false)
    }

    @Test func decodesRFC2047EncodedSubject() {
        // "Réunion café" via UTF-8 base64, and a quoted-printable variant
        let b = MailIndexer.decodeEncodedWords("=?UTF-8?B?UsOpdW5pb24gY2Fmw6k=?=")
        #expect(b == "Réunion café")
        let q = MailIndexer.decodeEncodedWords("=?UTF-8?Q?R=C3=A9union_caf=C3=A9?=")
        #expect(q == "Réunion café")
    }

    @Test func plainTextPassesThroughDecoder() {
        #expect(MailIndexer.decodeEncodedWords("Plain subject") == "Plain subject")
    }

    @Test func extractsAddressWhenNoDisplayName() {
        let message = "From: <solo@example.com>\nSubject: s\nDate: bad\n\nb"
        let parsed = MailIndexer.parseEmlx(data: emlx(message: message, flags: 1), fallbackDate: .distantPast)
        #expect(parsed?.from == "solo@example.com")
    }

    @Test func parsesRFC822Date() {
        let d = MailIndexer.parseRFC822Date("Tue, 7 Jul 2026 08:21:57 +0200")
        #expect(d != nil)
        // 08:21:57 +0200 == 06:21:57 UTC
        let c = Calendar(identifier: .gregorian)
        var utc = c; utc.timeZone = TimeZone(identifier: "UTC")!
        let comps = utc.dateComponents([.hour, .minute], from: d!)
        #expect(comps.hour == 6)
        #expect(comps.minute == 21)
    }

    @Test func dedupKeepsOnePerMessageIdNewestFirst() {
        let older = MailItem(id: "<same@x>", from: "a", subject: "s", date: Date(timeIntervalSince1970: 100),
                             unread: false, snippet: "", mailbox: "All Mail")
        let newer = MailItem(id: "<same@x>", from: "a", subject: "s", date: Date(timeIntervalSince1970: 200),
                             unread: true, snippet: "", mailbox: "INBOX")
        let other = MailItem(id: "<other@x>", from: "b", subject: "t", date: Date(timeIntervalSince1970: 150),
                             unread: false, snippet: "", mailbox: "INBOX")
        let result = MailIndexer.deduped([older, newer, other])
        #expect(result.count == 2)
        #expect(result.first?.id == "<same@x>")      // newest overall first
        #expect(result.first?.date == Date(timeIntervalSince1970: 200))
    }

    @Test func extractsAccountFromDeliveredTo() {
        let message = """
        Delivered-To: allan@pure-illusion.com
        From: Someone <x@y.com>
        To: allan@pure-illusion.com
        Subject: hi
        Date: Tue, 7 Jul 2026 08:21:57 +0200

        body
        """
        let parsed = MailIndexer.parseEmlx(data: emlx(message: message, flags: 1), fallbackDate: .distantPast)
        #expect(parsed?.account == "allan@pure-illusion.com")
    }

    @Test func accountFallsBackToToHeader() {
        let message = "From: x@y.com\nTo: Perso <me@gmail.com>\nSubject: s\nDate: bad\n\nb"
        let parsed = MailIndexer.parseEmlx(data: emlx(message: message, flags: 1), fallbackDate: .distantPast)
        #expect(parsed?.account == "me@gmail.com")
    }

    @Test func spamAndTrashMailboxesAreExcluded() {
        #expect(MailIndexer.isExcludedMailbox("Spam"))
        #expect(MailIndexer.isExcludedMailbox("Junk"))
        #expect(MailIndexer.isExcludedMailbox("Trash"))
        #expect(MailIndexer.isExcludedMailbox("Corbeille"))
        #expect(!MailIndexer.isExcludedMailbox("INBOX"))
        #expect(!MailIndexer.isExcludedMailbox("Sent Messages"))
    }

    @Test func mailboxNameFromPath() {
        let path = "/Users/x/Library/Mail/V10/UUID/INBOX.mbox/ABC/Data/1/Messages/42.emlx"
        #expect(MailIndexer.mailboxName(fromPath: path) == "INBOX")
    }

    @Test func mailAppURLBuiltFromMessageId() {
        let item = MailItem(id: "<abc123@pure-illusion.com>", from: "a", subject: "s",
                            date: .now, unread: false, snippet: "", mailbox: "INBOX")
        #expect(item.mailAppURL == "message://%3Cabc123@pure-illusion.com%3E")
    }
}
