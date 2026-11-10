import Foundation

struct SavedSnapshot: Codable {
    let date: Date
    let text: String
}
struct ContactProfile: Codable {
    let id: UUID
    var name: String
    let sourceKey: String
    var snapshots: [SavedSnapshot]
}
final class ProfileStore {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("微信回复建议/Contacts", isDirectory: true)
    }
    func profiles() -> [ContactProfile] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url.appendingPathComponent("profile.json")),
                  let p = try? JSONDecoder().decode(ContactProfile.self, from: data), p.id.uuidString == url.lastPathComponent else { return nil }
            return p
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func load(_ id: UUID) throws -> ContactProfile {
        try JSONDecoder().decode(ContactProfile.self, from: Data(contentsOf: directory(id).appendingPathComponent("profile.json")))
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ p: ContactProfile) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = directory(p.id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("profile.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(p).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func record(_ id: UUID, text: String) throws {
        var p = try load(id)
        guard p.snapshots.last?.text != text else { return }
        p.snapshots.append(SavedSnapshot(date: Date(), text: text))
        p.snapshots = Array(p.snapshots.suffix(10))
        try save(p)
    }
    func history(_ id: UUID, excluding current: String) throws -> String {
        let p = try load(id)
        let earlier = p.snapshots.filter { $0.text != current }.suffix(2)
        return String(earlier.map { "【同一已确认档案的先前可见片段，可能有重复，不是新消息】\n" + $0.text }.joined(separator: "\n").suffix(5000))
    }
}

// Only explicit Accessibility speaker labels are accepted. Never guess from bubble order.
func explicitMessage(_ text: String) -> String? {
    let patterns = [#"^(.+?)Said:\s*(.+)$"#, #"^(.+?)[说說][：:]\s*(.+)$"#, #"^(.+?)[：:]\s*Sent a\s*(.+)$"#]
    for pattern in patterns {
        let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
            var who = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let content = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !who.isEmpty, who.count < 100, !content.isEmpty else { return nil }
            if ["me", "我"].contains(who.lowercased()) { who = "我" }
            return "[\(who)] \(content)"
        }
    }
    return nil
}
