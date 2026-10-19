import Foundation
import AVFoundation
import UIKit

final class Relay {
    static let shared = Relay()
    private var task: URLSessionWebSocketTask?
    private let audioQ = DispatchQueue(label: "relay.audio")
    private let down = Downsampler()

    func connect() {
        Mqtt.shared.onMessage = { [weak self] m in self?.handle(m: m) }
        Mqtt.shared.onUp = { Outbox.shared.flush() }
        Mqtt.shared.start()
    }

