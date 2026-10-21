import AppKit
import CryptoKit
import SwiftUI

/// Обновления «по воздуху»: приложение читает маленький файл с номером последней версии,
/// скачивает архив самого приложения (модели не трогаются), проверяет подпись и заменяет себя.
enum UpdateConfig {
    static let manifestURL = "https://github.com/madebyhidden/sufler/releases/latest/download/update.json"
    /// Открытый ключ Ed25519. Архив, не подписанный парным закрытым ключом, приложение не установит.
    static let publicKey = "YP++IUeTcwDBDq0FFK4qvrcuun/13KLkg/xOxSJ/CtE="
}

struct UpdateInfo: Equatable {
    var version: String
    var notes: String
    var url: String
    var signature: String
    var size: Int64
}

enum UpdatePhase: Equatable {
    case idle
    case downloading(Double)
    case installing
    case failed(String)
}

func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
        if l != r { return l > r }
    }
    return false
}

extension AppState {
    var currentVersion: String {
        ProcessInfo.processInfo.environment["SUFLER_FAKE_VERSION"]
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    func startUpdateChecks() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            while true {
                await checkForUpdate(manual: false)
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }

    func checkForUpdate(manual: Bool) async {
        if manual { updateCheckNote = "Проверяю…" }
        guard let url = URL(string: UpdateConfig.manifestURL) else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = o["version"] as? String, let link = o["url"] as? String, let sig = o["signature"] as? String else {
            if manual { updateCheckNote = "Не удалось проверить — нет связи с сервером обновлений." }
            return
        }
        if isNewer(version, than: currentVersion) {
            updateInfo = UpdateInfo(version: version, notes: (o["notes"] as? String) ?? "", url: link, signature: sig, size: (o["size"] as? NSNumber)?.int64Value ?? 0)
            if manual { updateCheckNote = ""; showSettings = false; showUpdate = true }
            // Только для проверки механизма при сборке: поставить обновление без нажатия кнопки
            if ProcessInfo.processInfo.environment["SUFLER_AUTO_UPDATE"] != nil { installUpdate() }
        } else {
            updateInfo = nil
            if manual { updateCheckNote = "У вас последняя версия (\(currentVersion))." }
        }
    }

    func installUpdate() {
        guard let info = updateInfo, updatePhase == .idle || { if case .failed = updatePhase { return true }; return false }() else { return }
        if isRecording { updatePhase = .failed("Сначала остановите запись."); return }
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        // Из образа диска или из «карантинной» папки заменить себя нельзя
        if appURL.path.hasPrefix("/Volumes/") || appURL.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: parent.path) {
            updatePhase = .failed("Перенесите Суфлёр в папку «Программы», откройте оттуда и повторите.")
            return
        }
        updatePhase = .downloading(0)
        Task {
            do {
                guard let url = URL(string: info.url) else { throw err("Неверный адрес обновления") }
                let zip: URL = try await withCheckedThrowingContinuation { cont in
                    let task = URLSession.shared.downloadTask(with: url) { tmp, resp, error in
                        if let error { cont.resume(throwing: error); return }
                        guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else { cont.resume(throwing: err("Сервер не отдал обновление")); return }
                        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
                        do { try FileManager.default.moveItem(at: tmp, to: keep); cont.resume(returning: keep) } catch { cont.resume(throwing: error) }
                    }
                    let obs = task.progress.observe(\.fractionCompleted) { p, _ in
                        Task { @MainActor in if case .downloading = self.updatePhase { self.updatePhase = .downloading(p.fractionCompleted) } }
                    }
                    objc_setAssociatedObject(task, "obs", obs, .OBJC_ASSOCIATION_RETAIN)
                    task.resume()
                }
                updatePhase = .installing

                // Подпись: архив должен быть выпущен владельцем ключа
                let data = try Data(contentsOf: zip)
                guard let keyData = Data(base64Encoded: UpdateConfig.publicKey), let sig = Data(base64Encoded: info.signature),
                      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData), key.isValidSignature(sig, for: data) else {
                    throw err("Подпись обновления не сошлась — установка отменена.")
                }

                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sufler-update-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                unzip.arguments = ["-x", "-k", zip.path, dir.path]
                try unzip.run()
                unzip.waitUntilExit()
                guard unzip.terminationStatus == 0,
                      let newApp = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                      Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw err("Архив обновления повреждён.")
                }

                // Заменить себя на ходу нельзя: это делает маленький сценарий после нашего выхода
                let backup = dir.appendingPathComponent("previous.app")
                let script = dir.appendingPathComponent("install.sh")
                let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                try """
                #!/bin/sh
                while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
                if mv \(q(appURL.path)) \(q(backup.path)); then
                  if ! mv \(q(newApp.path)) \(q(appURL.path)); then mv \(q(backup.path)) \(q(appURL.path)); fi
                fi
                xattr -cr \(q(appURL.path)) 2>/dev/null
                # Если здешняя macOS не принимает подпись новой сборки, переподписываем на месте — иначе приложение не откроется
                codesign --verify --deep \(q(appURL.path)) 2>/dev/null || codesign --force --deep -s - \(q(appURL.path)) 2>/dev/null
                open \(q(appURL.path))
                """.write(to: script, atomically: true, encoding: .utf8)
                let run = Process()
                run.executableURL = URL(fileURLWithPath: "/bin/sh")
                run.arguments = ["-c", "nohup /bin/sh \(q(script.path)) >/dev/null 2>&1 &"]
                try run.run()
                run.waitUntilExit()
                // Выходим сразу: сценарий ждёт именно завершения процесса, а вежливый terminate может не сработать
                shutdown()
                _exit(0)
            } catch {
                updatePhase = .failed(error.localizedDescription)
            }
        }
    }
}

struct UpdateSheet: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Суфлёр \(app.updateInfo?.version ?? "")").font(.title3.weight(.semibold))
                    Text("У вас версия \(app.currentVersion)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let notes = app.updateInfo?.notes, !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(notes.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            if !line.trimmingCharacters(in: .whitespaces).isEmpty { Text(.init(line)).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(12)
                .background(Theme.soft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            Text("Скачается только само приложение\(app.updateInfo.map { $0.size > 0 ? " (\(gigabytes($0.size)))" : "" } ?? "") — модели и ваши встречи останутся на месте. После обновления macOS может ещё раз спросить доступ к микрофону и звуку.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch app.updatePhase {
            case .downloading(let p):
                ProgressView(value: p).tint(Theme.accent)
            case .installing:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Устанавливаю, приложение перезапустится…").font(.callout) }
            case .failed(let why):
                Label(why, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }
            HStack {
                Spacer()
                Button("Позже") { app.showUpdate = false }.keyboardShortcut(.cancelAction)
                    .disabled(app.updatePhase == .installing)
                PrimaryButton(title: "Обновить и перезапустить", enabled: { if case .downloading = app.updatePhase { return false }; return app.updatePhase != .installing }()) {
                    app.installUpdate()
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
