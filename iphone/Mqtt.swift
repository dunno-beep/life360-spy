import Foundation

final class Mqtt {
    static let shared = Mqtt()

    var onMessage: (([String: Any]) -> Void)?
    var onUp: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private var timer: DispatchSourceTimer?
    private var ready = false
    private var connecting = false
    private let cid = "l360ios" + UUID().uuidString.prefix(8)

    func start() {
        if task == nil { connect() }
    }

    private func connect() {
        guard !connecting else { return }
        connecting = true
        var c = URLComponents()
        c.scheme = "wss"
        c.host = Config.brokerHost
        c.port = Config.brokerPort
        c.path = Config.brokerPath
        guard let u = c.url else { return }
        var r = URLRequest(url: u)
        r.setValue("mqtt", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let t = URLSession.shared.webSocketTask(with: r)
        task = t
        ready = false
        t.resume()
        t.send(.data(connectPacket())) { _ in }
        listen(t)
        arm()
    }

    private func arm() {
        timer?.cancel()
        let d = DispatchSource.makeTimerSource(queue: .main)
        d.schedule(deadline: .now() + 25, repeating: 25)
        d.setEventHandler { [weak self] in
            guard let self = self else { return }
            if self.ready, let t = self.task {
                t.send(.data(Data([0xC0, 0x00]))) { _ in }
            } else {
                self.task = nil
                self.connecting = false
                self.connect()
            }
        }
        d.resume()
        timer = d
    }

    private func listen(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] res in
            guard let self = self else { return }
            switch res {
            case .failure:
                self.task = nil
                self.connecting = false
                HealthMon.fail(.pushAlerts, "Broker unreachable")
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.connect() }
            case .success(let msg):
                if case .data(let d) = msg { self.parse(d) }
                else if case .string(let s) = msg, let d = s.data(using: .isoLatin1) { self.parse(d) }
                self.listen(t)
            }
        }
    }

    private func parse(_ d: Data) {
        guard d.count >= 2 else { return }
        let type = d[0] >> 4
        var i = 1, mult = 1, len = 0
        while i < d.count {
            let b = Int(d[i]); i += 1
            len += (b & 127) * mult
            if b & 128 == 0 { break }
            mult *= 128
        }
        let end = min(d.count, i + len)
        guard i <= end else { return }
        let body = d.subdata(in: i..<end)
        if type == 2 {
            if !ready {
                ready = true
                connecting = false
                task?.send(.data(subPacket(Config.downTopic))) { _ in }
                onUp?()
            }
            return
        }
        if type == 3 {
            guard body.count > 2 else { return }
            let tl = Int(body[0]) << 8 | Int(body[1])
            guard body.count > 2 + tl else { return }
            let payload = body.subdata(in: (2 + tl)..<body.count)
            guard let s = String(data: payload, encoding: .utf8),
                  let plain = Crypto.open(s),
                  let obj = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) as? [String: Any]
            else { return }
            onMessage?(obj)
        }
    }

    func publish(_ text: String) {
        guard ready, let t = task else { return }
        t.send(.data(pubPacket(topic: Config.upTopic, payload: Data(text.utf8)))) { _ in }
    }

    private func str(_ s: String) -> Data {
        let b = Data(s.utf8)
        var d = Data([UInt8(b.count >> 8), UInt8(b.count & 0xFF)])
        d.append(b)
        return d
    }

    private func rl(_ n: Int) -> Data {
        var x = n
        var out = Data()
        repeat {
            var b = UInt8(x % 128)
            x /= 128
            if x > 0 { b |= 0x80 }
            out.append(b)
        } while x > 0
        return out
    }

    private func frame(_ t: UInt8, _ f: UInt8, _ body: Data) -> Data {
        var d = Data([(t << 4) | f])
        d.append(rl(body.count))
        d.append(body)
        return d
    }

    private func connectPacket() -> Data {
        var b = str("MQTT")
        b.append(4)
        b.append(0x02)
        b.append(contentsOf: [0, 60])
        b.append(str(cid))
        return frame(1, 0, b)
    }

    private func subPacket(_ topic: String) -> Data {
        var b = Data([0x00, 0x01])
        b.append(str(topic))
        b.append(0x00)
        return frame(8, 2, b)
    }

    private func pubPacket(topic: String, payload: Data) -> Data {
        var b = str(topic)
        b.append(payload)
        return frame(3, 0, b)
    }
}
