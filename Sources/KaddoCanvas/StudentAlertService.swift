import AppKit
import UserNotifications

/// Text alerts always work. System banners are an explicit /notifications opt-in.
@MainActor
public final class StudentAlertService: NSObject, UNUserNotificationCenterDelegate {
    private let planner: StudentPlanner
    private let center: UNUserNotificationCenter
    private var bannersEnabled = false

    public init(planner: StudentPlanner) {
        self.planner = planner
        center = UNUserNotificationCenter.current()
        super.init()
        center.delegate = self
        planner.onAlert = { [weak self] message in self?.deliver(message) }
        planner.notificationRequest = { [weak self] enabled in
            guard let self else { return .init(.failure, "Notification service is unavailable.") }
            return await self.setEnabled(enabled)
        }
        planner.notificationAction = { [weak self] enabled in
            Task { [weak self] in
                guard let self else { return }
                let result = await self.setEnabled(enabled)
                self.planner.say(result.message)
            }
        }
    }

    private func setEnabled(_ enabled: Bool) async -> KaddoToolResult {
        guard enabled else {
            bannersEnabled = false
            return .init(.success, "macOS banners off. Text alerts and your /sound setting still apply.")
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            bannersEnabled = granted
            return granted
                ? .init(.success, "macOS alert banners enabled while Kaddo is running.")
                : .init(.failure, "macOS notifications are disabled. You can enable Kaddo in System Settings → Notifications. Text and sound alerts still work.")
        } catch {
            return .init(.failure, "Couldn’t enable macOS notifications: \(error.localizedDescription). Text and sound alerts still work.")
        }
    }

    private func deliver(_ message: String) {
        if planner.soundsEnabled { NSSound(named: "Glass")?.play() }
        guard bannersEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Kaddo"
        content.body = message
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request) { _ in }
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
