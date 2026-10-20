import Foundation

final class Hist {
    static let shared = Hist()

    private let q = DispatchQueue(label: "hist")
    private let maxBytes = 2_000_000

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var file: URL { dir.appendingPathComponent("events.jsonl") }
    private var shots: URL { dir.appendingPathComponent("shots") }

    func append(_ o: [String: Any]) {
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
            if let h = try? FileHandle(forWritingTo: self.file) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                if #available(iOS 18.0, *) { try? h.close() } else { h.closeFile() }
            } else {
                try? line.write(to: self.file, atomically: true, encoding: .utf8)
            }
            self.trim()
            self.trimShots()
            self.trimShots()
        }
    }

    func tail(_ n: Int) -> [[String: Any]] {
        guard let txt = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return txt.split(separator: "\n").suffix(n).compactMap { l in
            guard let d = l.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            return o
        }
    }

    func shot(_ name: String) -> Data? {
        guard name.range(of: "^[0-9]+\\.jpg$", options: .regularExpression) != nil else { return nil }
        return try? Data(contentsOf: shots.appendingPathComponent(name))
    }

    func wipe() {
        q.async {
            try? FileManager.default.removeItem(at: self.file)
            try? FileManager.default.removeItem(at: self.shots)
        }
    }

    private func trimShots() {
        guard let f = try? FileManager.default.contentsOfDirectory(atPath: shots.path) else { return }
        let sorted = f.filter { $0.hasSuffix(".jpg") }.sorted()
        for old in sorted.dropLast(40) { try? FileManager.default.removeItem(at: shots.appendingPathComponent(old)) }
    }

    private func trimShots() {
        guard let f = try? FileManager.default.contentsOfDirectory(atPath: shots.path) else { return }
        let sorted = f.filter { $0.hasSuffix(".jpg") }.sorted()
        for old in sorted.dropLast(40) { try? FileManager.default.removeItem(at: shots.appendingPathComponent(old)) }
    }

    private func trim() {
        guard let a = try? FileManager.default.attributesOfItem(atPath: file.path),
              let sz = a[.size] as? Int, sz > maxBytes,
              let txt = try? String(contentsOf: file, encoding: .utf8) else { return }
        let lines = txt.split(separator: "\n")
        try? (lines.suffix(lines.count / 2).joined(separator: "\n") + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
    }
}
