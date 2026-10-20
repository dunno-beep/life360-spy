import Foundation

enum Hist {
    private static let q = DispatchQueue(label: "hist")
    private static let maxBytes = 2_000_000
    private static let keepShots = 40

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private static var file: URL { dir.appendingPathComponent("events.jsonl") }
    private static var shots: URL { dir.appendingPathComponent("shots") }

    static func append(_ o: [String: Any]) {
        var rec = o
        if let b64 = rec["b64"] as? String, b64.count > 4096, let d = Data(base64Encoded: b64) {
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            let name = "\(Int(Date().timeIntervalSince1970 * 1000)).jpg"
            try? d.write(to: shots.appendingPathComponent(name))
            rec.removeValue(forKey: "b64")
            rec["shot"] = name
        }
        q.async {
            guard let d = try? JSONSerialization.data(withJSONObject: rec),
                  var line = String(data: d, encoding: .utf8) else { return }
            line += "\n"
            if let h = try? FileHandle(forWritingTo: Self.file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                if #available(iOS 18.0, *) { try? h.close() } else { h.closeFile() }
            } else {
                try? line.write(to: Self.file, atomically: true, encoding: .utf8)
            }
            Self.trim()
            Self.trimShots()
        }
    }

    static func tail(_ n: Int) -> [[String: Any]] {
        guard let txt = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return txt.split(separator: "\n").suffix(n).compactMap { l in
            guard let d = l.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }
    }

    static func shot(_ name: String) -> Data? {
        guard name.range(of: "^[0-9]+\\.jpg$", options: .regularExpression) != nil else { return nil }
        return try? Data(contentsOf: shots.appendingPathComponent(name))
    }

    static func wipe() {
        q.async {
            try? FileManager.default.removeItem(at: Self.file)
            try? FileManager.default.removeItem(at: Self.shots)
        }
    }

    private static func trimShots() {
        guard let f = try? FileManager.default.contentsOfDirectory(atPath: shots.path) else { return }
        let sorted = f.filter { $0.hasSuffix(".jpg") }.sorted()
        for old in sorted.dropLast(keepShots) {
            try? FileManager.default.removeItem(at: shots.appendingPathComponent(old))
        }
    }

    private static func trim() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path),
              let sz = a[.size] as? Int, sz > maxBytes,
              let txt = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = txt.split(separator: "\n")
        try? (lines.suffix(lines.count / 2).joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }
}
