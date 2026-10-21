// jarvis-messages: recent one-on-one iMessage/SMS conversations for Jarvis's briefing.
// Bundled at JarvisOrb.app/Contents/Resources/bin.
//
//   jarvis-messages [--hours 36] [--json]
//
// Reads ~/Library/Messages/chat.db read-only: direct chats only (no group chats), conversations
// where someone wrote to the owner in the window, with the last messages of both sides so Claude
// can tell what was asked and whether it was answered. Names come from Contacts.
//
// Needs Full Disk Access for Jarvis Orb (Apple protects the Messages database) and asks once for
// Contacts. Message text is printed for Jarvis only; nothing is logged.

import Contacts
import Foundation
import SQLite3

let args = Array(CommandLine.arguments.dropFirst())

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let hours = max(1, min(Int(option("--hours") ?? "36") ?? 36, 24 * 14))
let wantsJSON = args.contains("--json")
let perChat = 20
let maxChats = 15

// MARK: Contacts

/// Phone numbers (last 10 digits) and emails → contact names.
func contactNames() -> [String: String] {
    let store = CNContactStore()
    let done = DispatchSemaphore(value: 0)
    var granted = false
    store.requestAccess(for: .contacts) { ok, _ in
        granted = ok
        done.signal()
    }
    done.wait()
    guard granted else { return [:] }
    var names: [String: String] = [:]
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
    try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
        let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        let display = name.isEmpty ? contact.nickname : name
        guard !display.isEmpty else { return }
        for phone in contact.phoneNumbers { names[normalize(phone.value.stringValue)] = display }
        for email in contact.emailAddresses { names[(email.value as String).lowercased()] = display }
    }
    return names
}

func normalize(_ handle: String) -> String {
    if handle.contains("@") { return handle.lowercased() }
    let digits = handle.filter(\.isNumber)
    return String(digits.suffix(10))
}

// MARK: Message text

/// Newer macOS stores the text only in `attributedBody`, an NSAttributedString in Apple's old
/// typedstream format. The string follows the "NSString" class name: skip 5 bytes, then a length
/// (one byte, or 0x81 + two bytes little-endian), then UTF-8.
func text(fromAttributedBody data: Data) -> String? {
    guard let marker = data.range(of: Data("NSString".utf8)) else { return nil }
    var i = marker.upperBound + 5
    guard i < data.count else { return nil }
    var length = Int(data[i])
    i += 1
    if length == 0x81, i + 1 < data.count {
        length = Int(data[i]) | Int(data[i + 1]) << 8
        i += 2
    } else if length == 0x82, i + 3 < data.count {
        length = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
        i += 4
    }
    guard length > 0, i + length <= data.count else { return nil }
    return String(data: data[i..<(i + length)], encoding: .utf8)
}

// MARK: Database

let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
var db: OpaquePointer?
guard sqlite3_open_v2("file:\(path)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
      sqlite3_exec(db, "SELECT 1 FROM message LIMIT 1", nil, nil, nil) == SQLITE_OK else {
    fail("Can't read Messages. Give Jarvis Orb Full Disk Access in System Settings › Privacy & Security › Full Disk Access.")
}

// Messages dates are nanoseconds since 2001-01-01.
let appleEpoch = 978_307_200.0
let since = Int64((Date().timeIntervalSince1970 - Double(hours) * 3600 - appleEpoch) * 1_000_000_000)

let sql = """
    SELECT c.ROWID, h.id, m.is_from_me, m.is_read, m.date, m.text, m.attributedBody
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cmj.chat_id
    LEFT JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
    LEFT JOIN handle h ON h.ROWID = chj.handle_id
    WHERE c.style = 45 AND m.date > ?
      AND (m.associated_message_type IS NULL OR m.associated_message_type = 0)
      AND m.item_type = 0
    ORDER BY m.date ASC
    """
var statement: OpaquePointer?
guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
    fail("Messages database format not recognised: \(String(cString: sqlite3_errmsg(db)))")
}
sqlite3_bind_int64(statement, 1, since)

struct Message {
    let fromMe: Bool
    let unread: Bool
    let date: Date
    let text: String
}

var chats: [Int64: (handle: String, messages: [Message])] = [:]
while sqlite3_step(statement) == SQLITE_ROW {
    let chatID = sqlite3_column_int64(statement, 0)
    let handle = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "unknown"
    let fromMe = sqlite3_column_int(statement, 2) == 1
    let unread = !fromMe && sqlite3_column_int(statement, 3) == 0
    let date = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4)) / 1_000_000_000 + appleEpoch)
    var body = sqlite3_column_text(statement, 5).map { String(cString: $0) } ?? ""
    if body.isEmpty, let blob = sqlite3_column_blob(statement, 6) {
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 6)))
        body = text(fromAttributedBody: data) ?? ""
    }
    body = body.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]").trimmingCharacters(in: .whitespacesAndNewlines)
    if body.isEmpty { body = "[attachment]" }
    chats[chatID, default: (handle, [])].messages.append(Message(fromMe: fromMe, unread: unread, date: date, text: body))
}
sqlite3_finalize(statement)
sqlite3_close(db)

// Only conversations where someone wrote to the owner, most recent first.
let names = contactNames()
let active = chats.values
    .filter { $0.messages.contains { !$0.fromMe } }
    .sorted { ($0.messages.last { !$0.fromMe }?.date ?? .distantPast) > ($1.messages.last { !$0.fromMe }?.date ?? .distantPast) }
    .prefix(maxChats)

let time = DateFormatter()
time.dateFormat = "EEE h:mm a"

if wantsJSON {
    let out: [[String: Any]] = active.map { chat in
        [
            "contact": names[normalize(chat.handle)] ?? chat.handle,
            "unread": chat.messages.filter(\.unread).count,
            "lastReplyIsMine": chat.messages.last?.fromMe ?? false,
            "messages": chat.messages.suffix(perChat).map { ["from": $0.fromMe ? "me" : "them", "time": time.string(from: $0.date), "text": String($0.text.prefix(500))] },
        ]
    }
    let data = try! JSONSerialization.data(withJSONObject: ["hours": hours, "chats": out], options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
} else {
    if active.isEmpty { print("No direct messages in the last \(hours) hours.") }
    for chat in active {
        let unread = chat.messages.filter(\.unread).count
        print("== \(names[normalize(chat.handle)] ?? chat.handle)\(unread > 0 ? " (\(unread) unread)" : "")")
        for m in chat.messages.suffix(perChat) {
            print("  \(time.string(from: m.date))  \(m.fromMe ? "me" : "them"): \(m.text.prefix(500))")
        }
    }
}
