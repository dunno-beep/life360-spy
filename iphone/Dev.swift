import Foundation

enum Dev {
    static let id: String = {
        let k = "l360.devid"
        if let v = UserDefaults.standard.string(forKey: k) { return v }
        let v = "dev" + String(UUID().uuidString.prefix(5)).lowercased()
        UserDefaults.standard.set(v, forKey: k)
        return v
    }()

    static var label: String {
        UserDefaults.standard.string(forKey: "l360.devlabel") ?? id
    }

    static func rename(_ s: String) {
        UserDefaults.standard.set(s, forKey: "l360.devlabel")
    }
}
