import Foundation
import CryptoKit

enum Crypto {
    private static let key: SymmetricKey = {
        let h = SHA256.hash(data: Data(Config.token.utf8))
        return SymmetricKey(data: Data(h))
    }()

    static func seal(_ s: String) -> String? {
        guard let d = s.data(using: .utf8),
              let box = try? AES.GCM.seal(d, using: key),
              let c = box.combined else { return nil }
        return c.base64EncodedString()
    }

    static func open(_ b: String) -> String? {
        guard let d = Data(base64Encoded: b),
              let box = try? AES.GCM.SealedBox(combined: d),
              let p = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: p, encoding: .utf8)
    }
}
