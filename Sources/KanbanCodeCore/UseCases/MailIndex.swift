import Foundation

/// One indexed mail message, parsed from a macOS Mail `.emlx` file on local disk.
/// Read-once + incremental: the app scans `~/Library/Mail`, parses each message, and
/// caches the result so later runs only touch new files (like the git commit index).
public struct MailItem: Identifiable, Codable, Sendable, Equatable {
    public let id: String          // RFC822 Message-Id (fallback: the .emlx path)
    public let from: String        // display name if present, else the address
    public let subject: String
    public let date: Date
    public let unread: Bool
    public let snippet: String
    public let mailbox: String     // e.g. "INBOX", "Sent Messages"
    public let account: String     // the owning account address (from Delivered-To/To), lowercased

    public init(id: String, from: String, subject: String, date: Date,
                unread: Bool, snippet: String, mailbox: String, account: String = "") {
        self.id = id; self.from = from; self.subject = subject; self.date = date
        self.unread = unread; self.snippet = snippet; self.mailbox = mailbox; self.account = account
    }

    /// Deep link that opens this message in Mail.app (`message://<Message-Id>`).
    public var mailAppURL: String? {
        let mid = id.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        guard mid.contains("@") else { return nil }        // not a real Message-Id
        return "message://%3C\(mid)%3E"
    }
}

/// On-disk cache: parsed items + the set of already-seen `.emlx` paths (with mtime), so
/// a rescan only parses files it hasn't seen. Stored at ~/.kanban-code/mail-index.json.
public struct MailIndex: Codable, Sendable {
    public var items: [MailItem] = []
    public var seen: [String: Date] = [:]     // emlx path → mtime
    public init() {}
}

public enum MailIndexStore {
    static func path() -> String {
        let base = (NSHomeDirectory() as NSString).appendingPathComponent(".kanban-code")
        return (base as NSString).appendingPathComponent("mail-index.json")
    }
    public static func read() -> MailIndex {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path())),
              let idx = try? decoder.decode(MailIndex.self, from: data) else { return MailIndex() }
        return idx
    }
    public static func write(_ index: MailIndex) {
        let p = path()
        try? FileManager.default.createDirectory(
            atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let data = try? encoder.encode(index) else { return }
        try? data.write(to: URL(fileURLWithPath: p))
    }
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

public enum MailScanError: Error, Sendable, Equatable {
    case needsFullDiskAccess    // ~/Library/Mail exists but macOS TCC blocks reading it
    case noMailData             // no Mail store / no messages found
}

/// A progress event from the incremental scan.
public enum MailScanEvent: Sendable {
    case items([MailItem])      // the growing, deduped, newest-first list
    case failure(MailScanError)
}

public enum MailIndexer {
    public static func mailRoot() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Mail")
    }

    // MARK: - Progressive scan

    /// Scan `~/Library/Mail` for `.emlx` files, parsing only ones not already cached, and
    /// yield the growing list (newest first). Emits the cache immediately, then batches as
    /// it parses. A blocked Mail directory yields `.failure(.needsFullDiskAccess)`.
    public static func loadProgressive() -> AsyncStream<MailScanEvent> {
        AsyncStream { continuation in
            Task.detached(priority: .utility) {
                let fm = FileManager.default
                let root = mailRoot()

                // Version dirs (V10, V9, …). A permission error here = Full Disk Access needed.
                let versionDirs: [String]
                do {
                    let entries = try fm.contentsOfDirectory(atPath: root)
                    versionDirs = entries.filter { $0.hasPrefix("V") }
                        .map { (root as NSString).appendingPathComponent($0) }
                } catch let error as NSError {
                    // Cocoa 257 = no permission, 256 = generic can't-read; both mean TCC here
                    let denied = error.domain == NSCocoaErrorDomain && (error.code == 257 || error.code == 256)
                    continuation.yield(.failure(denied ? .needsFullDiskAccess : .noMailData))
                    continuation.finish(); return
                }
                guard !versionDirs.isEmpty else {
                    continuation.yield(.failure(.noMailData)); continuation.finish(); return
                }

                var index = MailIndexStore.read()
                if !index.items.isEmpty { continuation.yield(.items(deduped(index.items))) }

                // Enumerate every .emlx with its mtime.
                let files = enumerateEmlx(in: versionDirs)

                // Only files we haven't parsed yet, newest first (so recent mail shows first).
                let fresh = files.filter { index.seen[$0.path] == nil }.sorted { $0.mtime > $1.mtime }
                if fresh.isEmpty {
                    if index.items.isEmpty { continuation.yield(.failure(.noMailData)) }
                    continuation.finish(); return
                }

                var sinceWrite = 0
                for f in fresh {
                    index.seen[f.path] = f.mtime               // mark seen even if skipped, so we don't rescan
                    let mailbox = mailboxName(fromPath: f.path)
                    if isExcludedMailbox(mailbox) { continue }  // never index spam / trash
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: f.path)),
                          let parsed = parseEmlx(data: data, fallbackDate: f.mtime) else { continue }
                    index.items.append(MailItem(
                        id: parsed.id.isEmpty ? f.path : parsed.id,
                        from: parsed.from, subject: parsed.subject, date: parsed.date,
                        unread: parsed.unread, snippet: parsed.snippet,
                        mailbox: mailbox, account: parsed.account))
                    sinceWrite += 1
                    if sinceWrite >= 300 {
                        sinceWrite = 0
                        MailIndexStore.write(index)
                        continuation.yield(.items(deduped(index.items)))
                    }
                }
                MailIndexStore.write(index)
                continuation.yield(.items(deduped(index.items)))
                continuation.finish()
            }
        }
    }

    /// Walk the Mail version dirs and collect every `.emlx` path with its mtime. Kept
    /// synchronous — NSEnumerator can't be iterated from an async context.
    static func enumerateEmlx(in versionDirs: [String]) -> [(path: String, mtime: Date)] {
        let fm = FileManager.default
        var files: [(path: String, mtime: Date)] = []
        for dir in versionDirs {
            guard let en = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                guard url.pathExtension == "emlx" else { continue }
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                files.append((url.path, mtime))
                if files.count >= 100_000 { break }
            }
        }
        return files
    }

    /// Same message can live in several mailboxes (Gmail INBOX + All Mail). Keep one per
    /// Message-Id, newest first.
    public static func deduped(_ items: [MailItem]) -> [MailItem] {
        var seen = Set<String>()
        var out: [MailItem] = []
        for item in items.sorted(by: { $0.date > $1.date }) where seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }

    static func mailboxName(fromPath path: String) -> String {
        // …/<Name>.mbox/…/Messages/xxx.emlx → the innermost ".mbox" component's name.
        let comps = (path as NSString).pathComponents
        if let mbox = comps.last(where: { $0.hasSuffix(".mbox") }) {
            return String(mbox.dropLast(".mbox".count))
        }
        return ""
    }

    // MARK: - .emlx parsing (pure / testable)

    /// Parse a `.emlx` blob: a length line, the raw RFC822 message, then a plist trailer
    /// (whose `flags` integer's bit 0 marks read). Returns nil if it isn't a message.
    public static func parseEmlx(data: Data, fallbackDate: Date)
        -> (id: String, from: String, subject: String, date: Date, unread: Bool, snippet: String, account: String)? {
        let bytes = [UInt8](data)
        guard let nl = bytes.firstIndex(of: 0x0A) else { return nil }
        let lengthStr = String(decoding: bytes[0..<nl], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let start = nl + 1
        let messageSlice: ArraySlice<UInt8>
        let plistSlice: ArraySlice<UInt8>
        if let len = Int(lengthStr), len >= 0, start + len <= bytes.count {
            messageSlice = bytes[start..<(start + len)]
            plistSlice = bytes[(start + len)...]
        } else {
            messageSlice = bytes[start...]
            plistSlice = []
        }
        let message = decodeBytes(messageSlice)
        guard !message.isEmpty else { return nil }

        let (headerBlock, body) = splitHeadersBody(message)
        let subject = decodeEncodedWords(headerValue("Subject", in: headerBlock) ?? "")
        let from = displayFrom(headerValue("From", in: headerBlock) ?? "")
        let id = (headerValue("Message-ID", in: headerBlock) ?? headerValue("Message-Id", in: headerBlock) ?? "")
            .trimmingCharacters(in: .whitespaces)
        let date = (headerValue("Date", in: headerBlock).flatMap(parseRFC822Date)) ?? fallbackDate
        let unread = readFlag(plistSlice)
        let snippet = makeSnippet(body)
        // The mail's owning account: Gmail/Workspace stamp Delivered-To with the recipient
        // mailbox address (the topmost one is the final delivery). Fall back to To.
        let account = extractAddress(headerValue("Delivered-To", in: headerBlock)
            ?? headerValue("To", in: headerBlock) ?? "")
        return (id, from, subject.isEmpty ? "(sans objet)" : subject, date, unread, snippet, account)
    }

    /// Pull the bare email address out of a header value ("Name <a@b>" / "a@b").
    static func extractAddress(_ raw: String) -> String {
        let s = decodeEncodedWords(raw)
        if let lt = s.firstIndex(of: "<"), let gt = s[lt...].firstIndex(of: ">") {
            return String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        let token = s.split(whereSeparator: { " ,;\t".contains($0) }).first(where: { $0.contains("@") })
        return (token.map(String.init) ?? s).trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Junk/Trash mailboxes we never want to show (Gmail nests Spam/Bin under "[Gmail]").
    static let excludedMailboxes: Set<String> = [
        "junk", "spam", "junk e-mail", "bulk mail",
        "trash", "bin", "deleted messages", "deleted items", "corbeille", "pourriels",
    ]

    static func isExcludedMailbox(_ name: String) -> Bool {
        excludedMailboxes.contains(name.lowercased())
    }

    /// `.emlx` plist trailer: `flags` integer, bit 0 = read. Unknown ⇒ treat as read.
    static func readFlag(_ plistSlice: ArraySlice<UInt8>) -> Bool {
        guard !plistSlice.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: Data(plistSlice), options: [], format: nil),
              let dict = plist as? [String: Any],
              let flags = dict["flags"] as? Int else { return false }
        return (flags & 1) == 0
    }

    static func decodeBytes(_ slice: ArraySlice<UInt8>) -> String {
        let data = Data(slice)
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Split on the first blank line. Header lines are unfolded (continuations joined).
    static func splitHeadersBody(_ message: String) -> (headers: String, body: String) {
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        if let range = normalized.range(of: "\n\n") {
            return (String(normalized[..<range.lowerBound]), String(normalized[range.upperBound...]))
        }
        return (normalized, "")
    }

    /// First matching header value, unfolding RFC822 continuation lines (leading WS).
    static func headerValue(_ name: String, in headers: String) -> String? {
        let lines = headers.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let prefix = name.lowercased() + ":"
        var i = 0
        while i < lines.count {
            if lines[i].lowercased().hasPrefix(prefix) {
                var value = String(lines[i].dropFirst(prefix.count))
                var j = i + 1
                while j < lines.count, let c = lines[j].first, c == " " || c == "\t" {
                    value += " " + lines[j].trimmingCharacters(in: .whitespaces)
                    j += 1
                }
                return value.trimmingCharacters(in: .whitespaces)
            }
            i += 1
        }
        return nil
    }

    static func displayFrom(_ raw: String) -> String {
        let decoded = decodeEncodedWords(raw)
        if let lt = decoded.firstIndex(of: "<") {
            let name = decoded[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            if !name.isEmpty { return name }
            if let gt = decoded[lt...].firstIndex(of: ">") {
                return String(decoded[decoded.index(after: lt)..<gt])
            }
        }
        return decoded.trimmingCharacters(in: .whitespaces)
    }

    static func parseRFC822Date(_ raw: String) -> Date? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let paren = s.range(of: " (") { s = String(s[..<paren.lowerBound]) }  // strip "(UTC)" comment
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm Z",
        ]
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX")
        for f in formats { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        return nil
    }

    static func makeSnippet(_ body: String, limit: Int = 200) -> String {
        var text = body
        // Drop MIME boundary / header noise crudely, strip HTML tags, collapse whitespace.
        if let r = text.range(of: "<html", options: .caseInsensitive) { text = String(text[r.lowerBound...]) }
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "&nbsp;", with: " ")
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        return String(text.prefix(limit))
    }

    // MARK: - RFC 2047 encoded-words (=?charset?B/Q?text?=)

    public static func decodeEncodedWords(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        var result = ""
        var rest = Substring(input)
        while let open = rest.range(of: "=?") {
            result += rest[..<open.lowerBound]
            let afterOpen = rest[open.upperBound...]
            guard let q1 = afterOpen.range(of: "?") else { result += "=?"; rest = afterOpen; break }
            let charset = String(afterOpen[..<q1.lowerBound])
            let afterCharset = afterOpen[q1.upperBound...]
            guard let q2 = afterCharset.range(of: "?") else { result += "=?" + charset + "?"; rest = afterCharset; break }
            let enc = String(afterCharset[..<q2.lowerBound])
            let afterEnc = afterCharset[q2.upperBound...]
            guard let close = afterEnc.range(of: "?=") else { result += "=?" + charset + "?" + enc + "?"; rest = afterEnc; break }
            let encoded = String(afterEnc[..<close.lowerBound])
            result += decodeWord(encoded, encoding: enc, charset: charset)
                ?? "=?\(charset)?\(enc)?\(encoded)?="
            rest = afterEnc[close.upperBound...]
        }
        result += rest
        return result
    }

    static func decodeWord(_ text: String, encoding: String, charset: String) -> String? {
        let cs = charsetEncoding(charset)
        switch encoding.uppercased() {
        case "B":
            guard let data = Data(base64Encoded: text) else { return nil }
            return String(data: data, encoding: cs)
        case "Q":
            var bytes = [UInt8]()
            let chars = Array(text)
            var i = 0
            while i < chars.count {
                let c = chars[i]
                if c == "_" { bytes.append(0x20); i += 1 }
                else if c == "=", i + 2 < chars.count, let b = UInt8(String(chars[i+1...i+2]), radix: 16) {
                    bytes.append(b); i += 3
                } else { bytes.append(contentsOf: Array(String(c).utf8)); i += 1 }
            }
            return String(data: Data(bytes), encoding: cs)
        default:
            return nil
        }
    }

    static func charsetEncoding(_ name: String) -> String.Encoding {
        switch name.uppercased() {
        case "UTF-8", "UTF8": return .utf8
        case "ISO-8859-1", "LATIN1", "ISO-8859-15": return .isoLatin1
        case "US-ASCII", "ASCII": return .ascii
        case "WINDOWS-1252", "CP1252": return .windowsCP1252
        default: return .utf8
        }
    }
}
