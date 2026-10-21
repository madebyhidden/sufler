import AVFoundation
import SwiftUI
import UserNotifications

/// Модель, которую приложение скачивает при первом запуске.
struct ModelItem: Identifiable, Equatable {
    enum State: Equatable {
        case missing
        case downloading
        case ready
        case failed(String)
    }

    let id: String          // имя файла
    let title: String
    let note: String
    let url: String
    let size: Int64
    let required: Bool
    /// Качается не при первом запуске, а по кнопке — когда понадобится (глубокая модель для собеседований)
    var onDemand = false
    var progress: Double = 0
    var state: State = .missing

    static let catalog: [ModelItem] = [
        ModelItem(id: Paths.whisperModel, title: "Whisper large-v3-turbo", note: "Распознавание речи на русском и английском",
                  url: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin", size: 574_041_195, required: true),
        ModelItem(id: Paths.chatModel, title: "Gemma 4 E4B", note: "Вопросы, итоги встреч, факты и чат",
                  url: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_0.gguf", size: 4_590_807_392, required: true),
        ModelItem(id: Paths.draftModel, title: "Ускоритель Gemma", note: "Делает ответы примерно на треть быстрее",
                  url: "https://huggingface.co/ggml-org/gemma-4-E4B-it-GGUF/resolve/main/mtp-gemma-4-E4B-it-Q4_0.gguf", size: 59_678_240, required: false),
        ModelItem(id: Paths.embedModel, title: "EmbeddingGemma", note: "Поиск по базе знаний и прошлым встречам",
                  url: "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf", size: 333_590_944, required: true),
        ModelItem(id: Paths.deepModel, title: "Gemma 4 26B", note: "Карта вопросов и оценка кандидата на собеседованиях",
                  url: "https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-Q4_0.gguf", size: 14_618_145_824, required: false, onDemand: true),
        ModelItem(id: Paths.deepDraftModel, title: "Ускоритель Gemma 26B", note: "Ускоряет глубокую модель",
                  url: "https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF/resolve/main/mtp-gemma-4-26B-A4B-it-Q4_0.gguf", size: 251_939_520, required: false, onDemand: true),
    ]
}

func gigabytes(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000 ? String(format: "%.1f ГБ", Double(bytes) / 1e9) : String(format: "%.0f МБ", Double(bytes) / 1e6)
}

extension AppState {
    var missingBytes: Int64 { modelItems.filter { $0.state != .ready && !$0.onDemand }.reduce(0) { $0 + $1.size } }
    var modelsReady: Bool { !modelItems.contains { $0.required && $0.state != .ready } }
    var totalProgress: Double {
        let base = modelItems.filter { !$0.onDemand }
        let all = base.reduce(Int64(0)) { $0 + $1.size }
        let done = base.reduce(0.0) { $0 + Double($1.size) * ($1.state == .ready ? 1 : $1.progress) }
        return all > 0 ? done / Double(all) : 0
    }

    var freeDiskBytes: Int64 {
        let v = try? Paths.supportDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func refreshModels() {
        for i in modelItems.indices where modelItems[i].state != .downloading {
            if let u = Paths.model(modelItems[i].id), Paths.fileSize(u) >= Int(modelItems[i].size) {
                modelItems[i].state = .ready
                modelItems[i].progress = 1
            } else if case .failed = modelItems[i].state {
                // ошибку оставляем на экране до повторной попытки
            } else {
                modelItems[i].state = .missing
            }
        }
    }

    func downloadModels() {
        guard !downloading else { return }
        downloading = true
        Task {
            for i in modelItems.indices where modelItems[i].state != .ready && !modelItems[i].onDemand {
                await download(i)
            }
            downloading = false
            // Модели на месте — поднимаем движки. Языковую модель и поиск перезапускаем всегда:
            // до загрузки они могли стартовать без части файлов
            if modelsReady {
                await boot()
                await restartLLM()
            }
        }
    }

    /// Глубокая модель для собеседований: качается отдельно, по кнопке в настройках.
    var deepItems: [ModelItem] { modelItems.filter(\.onDemand) }
    var deepModelReady: Bool { !deepItems.contains { $0.id == Paths.deepModel && $0.state != .ready } }
    var deepDownloading: Bool { deepItems.contains { $0.state == .downloading } }
    var deepProgress: Double {
        let all = deepItems.reduce(Int64(0)) { $0 + $1.size }
        let done = deepItems.reduce(0.0) { $0 + Double($1.size) * ($1.state == .ready ? 1 : $1.progress) }
        return all > 0 ? done / Double(all) : 0
    }

    func downloadDeepModel() {
        guard !downloading else { return }
        downloading = true
        Task {
            for i in modelItems.indices where modelItems[i].onDemand && modelItems[i].state != .ready {
                await download(i)
            }
            downloading = false
            if interviewMode { warmDeep() }
        }
    }

    private func download(_ i: Int) async {
        let item = modelItems[i]
        guard let url = URL(string: item.url) else { return }
        modelItems[i].state = .downloading
        let dest = Paths.downloadedModelsDir.appendingPathComponent(item.id)
        do {
            let tmp: URL = try await withCheckedThrowingContinuation { cont in
                let done: (URL?, URLResponse?, Error?) -> Void = { tmp, resp, error in
                    if let error {
                        // Запоминаем, где оборвалось, чтобы докачать с того же места
                        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                        Task { @MainActor in self.resumeData[item.id] = data }
                        cont.resume(throwing: error)
                        return
                    }
                    guard let tmp, (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
                        cont.resume(throwing: err("Сервер не отдал файл"))
                        return
                    }
                    // Временный файл исчезнет сразу после выхода из обработчика — переносим здесь же
                    let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    do { try FileManager.default.moveItem(at: tmp, to: keep); cont.resume(returning: keep) } catch { cont.resume(throwing: error) }
                }
                let task = resumeData[item.id].map { URLSession.shared.downloadTask(withResumeData: $0, completionHandler: done) }
                    ?? URLSession.shared.downloadTask(with: url, completionHandler: done)
                let obs = task.progress.observe(\.fractionCompleted) { p, _ in
                    Task { @MainActor in if self.modelItems[i].state == .downloading { self.modelItems[i].progress = p.fractionCompleted } }
                }
                objc_setAssociatedObject(task, "obs", obs, .OBJC_ASSOCIATION_RETAIN)
                task.resume()
            }
            resumeData[item.id] = nil
            guard Paths.fileSize(tmp) >= Int(item.size) else { throw err("Файл скачался не полностью") }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
            modelItems[i].progress = 1
            modelItems[i].state = .ready
        } catch {
            modelItems[i].state = .failed(error.localizedDescription)
        }
    }

    // MARK: Разрешения

    func refreshPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: micAccess = "granted"
        case .denied, .restricted: micAccess = "denied"
        default: micAccess = "unknown"
        }
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let v = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional ? "granted" : (s.authorizationStatus == .denied ? "denied" : "unknown")
            Task { @MainActor in self.notifAccess = v }
        }
    }

    func requestMic() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
        }
    }

    func requestNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in Notifier.shared.setup(); self.refreshPermissions() }
        }
    }

    /// У записи звука системы нет способа спросить «разрешено ли» — только попробовать.
    /// Короткий пробный захват заодно вызывает системный запрос доступа.
    func probeSystemAudio() {
        Task {
            let probe = SystemAudioCapture()
            do {
                try probe.start()
                try? await Task.sleep(nanoseconds: 900_000_000)
                probe.stop()
                systemAudioChecked = true
            } catch {
                systemAudioChecked = false
            }
        }
    }

    func openPrivacySettings(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }

    func finishSetup() {
        onboarded = true
        showSetup = false
        if telemetryConsent == "unknown" { showConsent = true }
    }

    func reopenSetup() {
        refreshModels()
        refreshPermissions()
        setupStep = 0
        showSettings = false
        showSetup = true
    }
}

// MARK: Экраны

struct SetupView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch app.setupStep {
                case 0: WelcomeStep()
                case 1: ModelsStep()
                default: ReadyStep()
                }
            }
            .frame(maxWidth: 780, maxHeight: .infinity)
            .padding(.horizontal, 40).padding(.top, 34)

            HStack {
                if app.setupStep > 0 {
                    Button("Назад") { app.setupStep -= 1 }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 7) {
                    ForEach(0..<3, id: \.self) { i in
                        Capsule().fill(i == app.setupStep ? Theme.accent : Color.primary.opacity(0.15)).frame(width: i == app.setupStep ? 22 : 7, height: 7)
                    }
                }
                Spacer()
                PrimaryButton(title: app.setupStep == 2 ? "Начать работу" : "Дальше", enabled: app.setupStep != 2 || app.asrReady) {
                    if app.setupStep == 2 { app.finishSetup() } else { app.setupStep += 1; app.refreshPermissions() }
                }
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 40).padding(.vertical, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.page, Theme.page], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
        )
        .onAppear { app.refreshModels(); app.refreshPermissions() }
    }
}

struct PrimaryButton: View {
    let title: String
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Theme.accent.opacity(enabled ? 1 : 0.4), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!enabled)
    }
}

struct WelcomeStep: View {
    private let features: [(String, String, String)] = [
        ("waveform", "Живая расшифровка", "Русская и английская речь превращается в текст прямо во время звонка — и ваш голос, и собеседников."),
        ("questionmark.bubble.fill", "Последний вопрос", "Суфлёр ловит вопрос, показывает, кому он адресован, тему и короткий контекст. Риторические пропускает."),
        ("bell.badge.fill", "«Вопрос к вам»", "Назовёте своё имя — карточка с обращением к вам выделится цветом и придёт уведомление."),
        ("person.2.wave.2.fill", "Кто говорит", "Собеседники различаются по голосу; каждому можно дать имя."),
        ("books.vertical.fill", "База знаний", "Факты из встреч копятся сами и обновляются, когда цифры меняются. Туда же — ваши документы и чат по ним."),
        ("lock.shield.fill", "Всё на этом Mac", "Модели работают локально. Звук и тексты никуда не отправляются, интернет нужен только чтобы один раз скачать модели."),
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            VStack(spacing: 6) {
                Text("Суфлёр").font(.system(size: 34, weight: .bold))
                Text("Подсказывает на встречах: что спросили, кого и о чём шла речь").font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(features, id: \.1) { f in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: f.0).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(f.1).fontWeight(.semibold)
                            Text(f.2).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ModelsStep: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Модели").font(.system(size: 28, weight: .bold))
                Text("Суфлёр работает на моделях, которые лежат на вашем Mac. Их нужно скачать один раз — дальше интернет не понадобится.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                ForEach(app.modelItems.filter { !$0.onDemand }) { m in ModelRow(item: m) }
            }
            if app.modelsReady && app.missingBytes == 0 {
                Label("Все модели на месте", systemImage: "checkmark.seal.fill").foregroundStyle(.green).fontWeight(.medium)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if app.downloading {
                        ProgressView(value: app.totalProgress).tint(Theme.accent)
                        Text("Скачано \(Int(app.totalProgress * 100))%. Не закрывайте приложение. Если связь оборвётся — нажмите «Скачать» ещё раз, загрузка продолжится с того же места.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 14) {
                            PrimaryButton(title: "Скачать — \(gigabytes(app.missingBytes))") { app.downloadModels() }
                            Text("Свободно на диске: \(gigabytes(app.freeDiskBytes))")
                                .font(.callout).foregroundStyle(app.freeDiskBytes < app.missingBytes + 2_000_000_000 ? Color.red : Color.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ModelRow: View {
    let item: ModelItem

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch item.state {
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .downloading: ProgressView().controlSize(.small)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .missing: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.title).fontWeight(.semibold)
                    if !item.required { Text("необязательно").font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.soft, in: Capsule()) }
                }
                Text(item.note).font(.callout).foregroundStyle(.secondary)
                if case .downloading = item.state { ProgressView(value: item.progress).tint(Theme.accent) }
                if case .failed(let why) = item.state { Text("Не скачалось: \(why). Нажмите «Скачать» ещё раз.").font(.caption).foregroundStyle(.orange) }
            }
            Spacer(minLength: 8)
            Text(item.state == .downloading ? "\(Int(item.progress * 100))%" : gigabytes(item.size)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}

struct ReadyStep: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Разрешения и готовность").font(.system(size: 28, weight: .bold))
                Text("macOS спросит доступ к микрофону и звуку. Без них Суфлёр ничего не услышит.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 8) {
                CheckRow(icon: "mic.fill", title: "Микрофон", note: "Ваш голос",
                         status: app.micAccess == "granted" ? .ok : (app.micAccess == "denied" ? .bad : .todo),
                         button: app.micAccess == "granted" ? nil : (app.micAccess == "denied" ? "Открыть настройки" : "Разрешить")) {
                    if app.micAccess == "denied" { app.openPrivacySettings("Privacy_Microphone") } else { app.requestMic() }
                }
                CheckRow(icon: "speaker.wave.2.fill", title: "Звук системы", note: "Голоса собеседников из Zoom, Meet, Телемоста и любых других приложений",
                         status: app.systemAudioChecked == true ? .ok : (app.systemAudioChecked == false ? .bad : .todo),
                         button: app.systemAudioChecked == true ? nil : (app.systemAudioChecked == false ? "Открыть настройки" : "Разрешить")) {
                    if app.systemAudioChecked == false { app.openPrivacySettings("Privacy_AudioCapture") } else { app.probeSystemAudio() }
                }
                CheckRow(icon: "bell.fill", title: "Уведомления", note: "Чтобы не пропустить вопрос, обращённый к вам. Необязательно",
                         status: app.notifAccess == "granted" ? .ok : (app.notifAccess == "denied" ? .bad : .todo),
                         button: app.notifAccess == "granted" ? nil : (app.notifAccess == "denied" ? "Открыть настройки" : "Разрешить")) {
                    if app.notifAccess == "denied" { app.openPrivacySettings("Privacy_Notifications") } else { app.requestNotifications() }
                }
            }
            Text("Движки").font(.headline).padding(.top, 4)
            VStack(spacing: 8) {
                CheckRow(icon: "waveform", title: "Распознавание речи", note: app.asrStatus, status: app.asrReady ? .ok : (app.asrFailed ? .bad : .wait))
                CheckRow(icon: "sparkles", title: "Языковая модель", note: app.llmStatus, status: app.llmReady ? .ok : (app.llmFailed ? .bad : .wait))
                CheckRow(icon: "magnifyingglass", title: "Поиск по базе знаний", note: app.embedReady ? "Готов" : (Paths.model(Paths.embedModel) == nil ? "Нет модели — скачайте её на предыдущем шаге" : "Запускается вместе с языковой моделью"),
                         status: app.embedReady ? .ok : (app.llmFailed || Paths.model(Paths.embedModel) == nil ? .bad : .wait))
            }
            if app.systemAudioChecked == true {
                Text("Если в расшифровке нет собеседников, проверьте: Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного аудио → Суфлёр.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct CheckRow: View {
    enum Status { case ok, bad, todo, wait }
    let icon: String
    let title: String
    let note: String
    let status: Status
    var button: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let button {
                Button(action: action) {
                    Text(button).font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Theme.accent.opacity(0.12), in: Capsule()).contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            switch status {
            case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
            case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.title3)
            case .todo: Image(systemName: "circle").foregroundStyle(.tertiary).font(.title3)
            case .wait: ProgressView().controlSize(.small)
            }
        }
        .padding(13)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.line))
    }
}
