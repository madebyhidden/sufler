import AppKit
import UserNotifications

/// Системные уведомления: «вопрос адресован вам».
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    private var ready = false
    /// Нажали «Начать запись» в уведомлении о звонке
    var onStartRecording: (() -> Void)?

    /// Вне .app (запуск голого бинарника) центра уведомлений нет — там просто ничего не делаем.
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available, !ready else { return }
        ready = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let start = UNNotificationAction(identifier: "START", title: "Начать запись", options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "CALL", actions: [start], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String) {
        guard available else { return }
        setup()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        // Если уведомления запрещены, хотя бы значок в Dock подпрыгнет
        DispatchQueue.main.async { NSApp.requestUserAttention(.criticalRequest) }
    }

    /// «Похоже, начался звонок — начать запись?» Нажатие на уведомление или на кнопку в нём запускает запись.
    func offerRecording(app: String) {
        guard available else { return }
        setup()
        let content = UNMutableNotificationContent()
        content.title = "Похоже, начался звонок"
        content.body = "\(app) включил микрофон. Начать запись в Суфлёре?"
        content.sound = .default
        content.categoryIdentifier = "CALL"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call-offer", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.notification.request.content.categoryIdentifier == "CALL", response.actionIdentifier != UNNotificationDismissActionIdentifier {
            onStartRecording?()
        }
        completionHandler()
    }

    // Показываем баннер, даже когда окно приложения на переднем плане
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
