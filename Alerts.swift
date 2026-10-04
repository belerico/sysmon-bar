// Notifications when memory pressure rises to the level chosen in the settings.

import Foundation
import OSLog
import UserNotifications

@MainActor
final class PressureAlerts: NSObject, UNUserNotificationCenterDelegate {
    /// A level is not announced again within this time, in case pressure flaps around it.
    static let cooldown: TimeInterval = 10 * 60

    private let log = Logger(subsystem: "com.belerico.sysmon", category: "alerts")
    /// The highest level announced since pressure was last back to normal.
    private var announced = Pressure.normal
    private var announcedAt: [Pressure: Date] = [:]

    // UNUserNotificationCenter traps without a bundle, e.g. when the bare binary runs --dump.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    func requestPermission() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            log.notice("Notification permission granted: \(granted), error: \(error?.localizedDescription ?? "none", privacy: .public)")
        }
    }

    /// Announces the pressure once it reaches `threshold`, again only if it climbs higher, and
    /// re-arms when it is back to normal. Returns the level announced, if any.
    @discardableResult
    func check(_ memory: Memory, threshold: PressureAlert, now: Date = .now) -> Pressure? {
        let level = memory.pressure
        guard level != .normal else {
            announced = .normal
            return nil
        }
        guard let minimum = threshold.level, level.rank >= minimum.rank, level.rank > announced.rank else { return nil }
        announced = level
        if let last = announcedAt[level], now.timeIntervalSince(last) < Self.cooldown { return nil }
        announcedAt[level] = now

        let gib = 1_073_741_824.0
        let content = UNMutableNotificationContent()
        content.title = "Memory pressure: \(level.rawValue)"
        content.body = String(format: "%.1f of %.0f GB used, %.1f GB in swap. Quitting apps you don't need frees memory.",
                              memory.used / gib, memory.total / gib, memory.swapUsed / gib)
        content.sound = .default
        center?.add(UNNotificationRequest(identifier: "pressure-\(level.rawValue)", content: content, trigger: nil))
        log.notice("Memory pressure \(level.rawValue, privacy: .public)")
        return level
    }

    // Show banners even while the panel is open and this app is active.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

private extension Pressure {
    var rank: Int {
        switch self {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }
}
