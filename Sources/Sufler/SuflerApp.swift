import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    var onOpen: (([URL]) -> Void)?
    private var termSource: DispatchSourceSignal?

    /// Файлы, брошенные на значок приложения, уходят в базу знаний
    func application(_ application: NSApplication, open urls: [URL]) { onOpen?(urls) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Выход по сигналу (выключение Mac, завершение сеанса, kill) идёт мимо applicationWillTerminate —
        // обрабатываем его так же: гасим серверы моделей и выходим без деструкторов
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { [weak self] in
            self?.onQuit?()
            _exit(0)
        }
        src.resume()
        termSource = src
    }

    func applicationWillTerminate(_ notification: Notification) {
        onQuit?()
        // Выходим без статических деструкторов: иначе Metal-часть whisper.cpp падает, если в этот момент
        // фоновые потоки ещё заняты моделью (отсюда «приложение неожиданно завершилось» при закрытии)
        _exit(0)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SuflerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()

    init() { SelfTest.runIfRequested() }

    var body: some Scene {
        WindowGroup("Суфлёр") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: app.compact ? 320 : 1060, minHeight: app.compact ? 230 : 660)
                .onAppear {
                    delegate.onQuit = { [weak app] in app?.shutdown() }
                    delegate.onOpen = { [weak app] urls in app?.showKB = true; app?.addDocuments(urls) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}
