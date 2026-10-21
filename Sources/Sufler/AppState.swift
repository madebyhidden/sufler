import AVFoundation
import AppKit
import PDFKit
import Foundation
import SwiftUI

struct ChatLine: Identifiable {
    let id = UUID()
    var role: String
    var text: String
    var sources: [String] = []
    /// Изменения фактов: уже применённые (по прямой просьбе) или предложенные аудитом и ждущие подтверждения
    var ops: [FactOp] = []
    var opsPending = false
}

struct FactOp: Identifiable, Hashable {
    let id = UUID()
    var op: String        // add | update | delete
    var factID: Int64
    var text: String
    var old: String = ""
    var reason: String = ""
}

@MainActor
final class AppState: ObservableObject {
    // Движки
    @Published var asrStatus = "Загружаю Whisper…"
    @Published var llmStatus = "Загружаю языковую модель…"
    @Published var asrReady = false
    @Published var llmReady = false
    @Published var embedReady = false
    @Published var asrFailed = false
    @Published var llmFailed = false

    // Данные
    @Published var meetings: [Meeting] = []
    @Published var selectedID: Int64?
    @Published var turns: [Turn] = []
    @Published var questions: [Question] = []
    @Published var partial: [Speaker: String] = [:]
    @Published var levels: [Speaker: Float] = [:]

    // Состояние
    @Published var isRecording = false
    @Published var recordingID: Int64?
    @Published var detecting = false
    @Published var answering = false
    @Published var summarizing = false
    @Published var errorText: String?
    @Published var chat: [ChatLine] = []
    @Published var chatBusy = false
    @Published var voiceNames: [Int: String] = [:]
    @Published var pendingQuestion = ""
    @Published var renamingVoice: Int?
    @Published var renameText = ""
    @Published var documents: [Doc] = []
    @Published var facts: [Fact] = []
    @Published var kbTab = 0

    // Первый запуск: знакомство, загрузка моделей, разрешения
    @Published var showSetup = false
    @Published var setupStep = 0
    @Published var modelItems: [ModelItem] = ModelItem.catalog
    @Published var downloading = false
    @Published var micAccess = "unknown"
    @Published var notifAccess = "unknown"
    @Published var systemAudioChecked: Bool?
    @AppStorage("onboarded") var onboarded = false
    var resumeData: [String: Data] = [:]

    // Обновления
    @Published var updateInfo: UpdateInfo?
    @Published var updatePhase: UpdatePhase = .idle
    @Published var showUpdate = false
    @Published var updateCheckNote = ""

    // Расшифровка: пока пользователь листает, вниз не тянем
    @Published var followPausedUntil: Date?
    @Published var scrollTick = 0
    /// Микрофон выключен на время этой записи: пишем только звук звонка
    @Published var micMuted = false
    @Published var copiedNote = ""
    /// Векторы кусков открытой встречи — чтобы чат искал по всей расшифровке и не считал их заново
    var meetingVecCache: [String: [Float]] = [:]
    private var followTask: Task<Void, Never>?
    @Published var showKB = false
    @Published var kbStatus = ""
    @Published var chatInput = ""
    @Published var showSettings = false
    @Published var tab = 0

    // Звук встречи, диктовка, проверка названий, звонки
    /// Компактный режим: маленькое окно поверх всех с последними репликами и вопросом
    @Published var compact = false
    /// Экран «Статистика» вместо встречи
    @Published var showStats = false
    @Published var showFeedback = false
    /// Спросить, можно ли отправлять анонимную статистику (один раз)
    @Published var showConsent = false
    /// «unknown» — ещё не спрашивали, «yes» — разрешили, «no» — отказались
    @AppStorage("telemetryConsent") var telemetryConsent = "unknown"
    @Published var settingsPane = "general"
    @Published var feedbackKind = "idea"
    @Published var feedbackText = ""
    @Published var feedbackContact = ""
    @Published var feedbackAttach = true
    @Published var feedbackSent = false
    var frameBeforeCompact: NSRect?
    @Published var playingTurnID: Int64?
    @Published var selectedHasAudio = false
    /// Сколько последних реплик показывать в расшифровке
    @Published var shownTurns = 150
    @Published var nameChecks: [NameCheck] = []
    @Published var checkingNames = false
    /// Что пользователь вписал в поля «как правильно»
    @Published var checkInputs: [UUID: String] = [:]
    @Published var dictating = false
    /// Приложение, в котором, похоже, начался звонок: показываем предложение начать запись
    @Published var callOffer: String?
    @AppStorage("keepAudio") var keepAudio = true
    /// Через сколько минут тишины запись останавливается сама; 0 — никогда
    @AppStorage("autoStopMinutes") var autoStopMinutes = 10
    var lastSoundAt = Date()
    /// Словарь исправлений: строки «как услышано = как правильно»
    @AppStorage("corrections") var corrections = ""
    @AppStorage("watchCalls") var watchCalls = true
    @AppStorage("watchApps") var watchApps = CallWatcher.defaultApps
    var audioWriter: MeetingAudio?
    var player: AVAudioPlayer?
    var playStop: Task<Void, Never>?
    let micRouter = MicRouter()
    var dictationOwnsMic = false
    var dictationBase = ""
    var dictationToken = 0
    let callWatcher = CallWatcher()
    var lastCallOffer: [String: Date] = [:]
    var micDevice: MicCapture { mic }
    var speechEngine: WhisperEngine? { whisper }
    var meetingStore: Store { store }
    var speechPipeline: TranscriptionPipeline? { pipeline }

    // Собеседования
    /// "classic" — обычный суфлёр встреч, "interview" — суфлёр для собеседований
    @AppStorage("appMode") var appMode = "classic"
    var interviewMode: Bool { appMode == "interview" }
    /// Подготовка, карта вопросов, доуточнения и оценка открытого собеседования
    @Published var interview: Interview?
    /// База собеседований: вакансии и резюме под ними
    @Published var vacancies: [Vacancy] = []
    @Published var resumes: [Resume] = []
    @Published var libVacancyID: Int64?
    @Published var libResumeID: Int64?
    /// Какие собеседования проведены по каждому резюме
    @Published var resumeInterviews: [Int64: [Int64]] = [:]
    /// Итог последнего собеседования по каждому резюме
    @Published var resumeResults: [Int64: CandidateResult] = [:]
    var librarySaveTask: Task<Void, Never>?
    @Published var interviewTab = 0
    @Published var preparing = false
    @Published var prepNote = ""
    @Published var evaluating = false
    @Published var evalNote = ""
    @Published var probing = false
    @Published var deepStatus = ""
    var deepServer: LlamaProcess?
    var deepClient: LLMClient?
    var deepStarting: Task<LLMClient?, Never>?
    var probeTask: Task<Void, Never>?
    /// До какой реплики кандидата ответы уже разобраны
    var probedUntil: Int64 = 0
    var probedLen = 0
    /// Когда кандидат начал говорить реплику и сколько секунд речи в ней — для маркеров «долго думал», «медленно говорит»
    var turnStarts: [Int64: Date] = [:]
    var turnSpeech: [Int64: Double] = [:]
    var interviewSaveTask: Task<Void, Never>?

    // Настройки
    @AppStorage("language") var language = "ru"
    @AppStorage("glossary") var glossary = ""
    @AppStorage("myName") var myName = ""
    /// Путь к своему GGUF вместо Gemma; пусто — модель по умолчанию
    @AppStorage("chatModelPath") var chatModelPath = ""
    @AppStorage("captureSystem") var captureSystem = true
    @AppStorage("captureMic") var captureMic = true

    private let store = Store()
    private var whisper: WhisperEngine?
    private var pipeline: TranscriptionPipeline?
    private var llm: LLMClient?
    var chatClient: LLMClient? { llm }
    private var chatServer: LlamaProcess?
    private var embedServer: LlamaProcess?
    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var examinedTurnID: Int64 = 0
    private var examinedLen = 0
    private var candidateSince: Date?
    private var detectTask: Task<Void, Never>?
    private var starting = false
    private var voice: VoiceID?
    private var notesSaveTask: Task<Void, Never>?

    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var lastQuestion: Question? { questions.last }

    init() {
        meetings = store.meetings()
        documents = store.documents()
        vacancies = store.vacancies()
        resumes = store.resumes()
        refreshResumeInterviews()
        facts = store.facts()
        selectedID = meetings.first?.id
        if let id = selectedID { load(id) }
        if !myName.trimmingCharacters(in: .whitespaces).isEmpty { Notifier.shared.setup() }
        startUpdateChecks()
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            // Про статистику спрашиваем один раз, после знакомства с приложением
            if onboarded, !showSetup, telemetryConsent == "unknown" { showConsent = true }
            startTelemetryLoop()
        }
        mic.onSamples = { [micRouter] s in micRouter.route(s) }
        MeetingAudio.cleanup(olderThanDays: 30)
        startCallWatcher()
        refreshModels()
        showSetup = !onboarded || modelItems.contains { $0.required && $0.state != .ready }
        Task {
            await boot()
            // Только для замеров при сборке: начать запись сразу после запуска
            if ProcessInfo.processInfo.environment["SUFLER_AUTO_RECORD"] != nil, asrReady { toggleRecording() }
        }
    }

    // MARK: Запуск движков

    func boot() async {
        async let a: Void = bootWhisper()
        async let b: Void = bootLLM()
        _ = await (a, b)
    }

    private func bootWhisper() async {
        guard !asrReady else { return }
        asrFailed = false
        asrStatus = "Загружаю Whisper…"
        guard let model = Paths.model(Paths.whisperModel) else {
            asrStatus = "Нет модели Whisper"
            asrFailed = true
            return
        }
        do {
            let engine = try await Task.detached(priority: .userInitiated) { try WhisperEngine(modelPath: model.path) }.value
            // Прогрев: первый проход компилирует шейдеры Metal
            _ = await engine.transcribe([Float](repeating: 0, count: 16000), language: "ru", fast: true)
            whisper = engine
            let p = TranscriptionPipeline(whisper: engine)
            p.onPartial = { [weak self] sp, text in Task { @MainActor in self?.partial[sp] = text.isEmpty ? nil : text; if !text.isEmpty { self?.lastSoundAt = Date() } } }
            p.onFinal = { [weak self] sp, text, who, samples in Task { @MainActor in self?.addTurn(sp, text, who, samples) } }
            p.onLevel = { [weak self] sp, lv in Task { @MainActor in self?.levels[sp] = lv; self?.lastSoundAt = Date() } }
            if let dir = VoiceID.modelsDir, let v = try? VoiceID(dir: dir) {
                // Прогрев, чтобы первая фраза не ждала компиляции модели
                _ = await Task.detached { v.identify([Float](repeating: 0, count: 32000)) }.value
                v.reset()
                voice = v
                p.voice = v
            }
            pipeline = p
            asrReady = true
            asrStatus = "Whisper large-v3-turbo"
        } catch {
            asrStatus = "Whisper не загрузился"
            asrFailed = true
        }
    }

    /// Перезапуск языковой модели и поиска: после загрузки моделей или смены модели в настройках.
    func restartLLM() async {
        chatServer?.stop()
        embedServer?.stop()
        chatServer = nil
        embedServer = nil
        llmReady = false
        embedReady = false
        llmStatus = "Загружаю языковую модель…"
        await bootLLM()
    }

    func chooseChatModel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Выберите языковую модель в формате GGUF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension.lowercased() == "gguf" else { errorText = "Нужен файл модели в формате GGUF."; return }
        chatModelPath = url.path
        Task { await restartLLM() }
    }

    func resetChatModel() {
        chatModelPath = ""
        Task { await restartLLM() }
    }

    private func bootLLM() async {
        guard !llmReady else { return }
        llmFailed = false
        chatServer?.stop()
        embedServer?.stop()
        embedServer = nil
        guard let chatModel = Paths.chatModelURL else {
            llmStatus = "Нет языковой модели"
            llmFailed = true
            return
        }
        let modelName = chatModel.deletingPathExtension().lastPathComponent
        llmStatus = "Загружаю \(modelName)…"
        LlamaProcess.killStale(name: "chat")
        LlamaProcess.killStale(name: "embed")
        LlamaProcess.killStale(name: "deep")
        var extra = ["-c", "16384", "-np", "2", "--reasoning-budget", "0", "--jinja"]
        if chatModel.lastPathComponent == Paths.chatModel, let draft = Paths.model(Paths.draftModel) {
            extra += ["--spec-draft-model", draft.path, "--spec-type", "draft-mtp"]
        }
        let chat = LlamaProcess(name: "chat", model: chatModel, port: freePort(), extra: extra)
        chatServer = chat
        var embedURL = chat.baseURL
        if let em = Paths.model(Paths.embedModel) {
            let e = LlamaProcess(name: "embed", model: em, port: freePort(), extra: ["--embedding", "--pooling", "mean", "-c", "2048", "-np", "1", "-b", "2048", "-ub", "2048"])
            embedServer = e
            embedURL = e.baseURL
        }
        llm = LLMClient(chatURL: chat.baseURL, embedURL: embedURL)
        llm?.onUsage = { [weak self] p, c in
            Task { @MainActor in
                self?.count("llm_requests")
                self?.count("llm_in", Double(p))
                self?.count("llm_out", Double(c))
            }
        }
        do {
            try await chat.start()
            llmReady = true
            llmStatus = modelName
        } catch {
            log("llm: \(error.localizedDescription)")
            llmStatus = "Языковая модель не запустилась"
            llmFailed = true
        }
        if let e = embedServer {
            do { try await e.start(); embedReady = true } catch { log("embed: \(error.localizedDescription)") }
        }
    }

    func shutdown() {
        mic.stop()
        system.stop()
        audioWriter?.close()
        chatServer?.stop()
        embedServer?.stop()
        deepServer?.stop()
    }

    // MARK: Встречи

    func load(_ id: Int64) {
        turns = store.turns(meetingID: id)
        questions = store.questions(meetingID: id)
        voiceNames = store.voiceNames(meetingID: id)
        meetingVecCache = [:]
        stopPlayback()
        shownTurns = 150
        refreshHasAudio()
        nameChecks = decodeChecks(meetings.first { $0.id == id }?.checks ?? "")
        examinedTurnID = turns.last?.id ?? 0
        examinedLen = turns.last?.text.count ?? 0
        partial = [:]
        loadInterview(id)
    }

    func select(_ id: Int64?) {
        if id != nil { showKB = false; showStats = false }
        guard id != selectedID else { return }
        selectedID = id
        if let id { load(id) } else { turns = []; questions = []; interview = nil }
    }

    func delete(_ id: Int64) {
        guard id != recordingID else { return }
        store.deleteMeeting(id)
        MeetingAudio.delete(id)
        meetings.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil; select(meetings.first?.id) }
    }

    func setNotes(_ text: String) {
        guard let i = meetings.firstIndex(where: { $0.id == selectedID }) else { return }
        meetings[i].notes = text
        let m = meetings[i]
        notesSaveTask?.cancel()
        notesSaveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !Task.isCancelled { self.store.update(m) }
        }
    }

    func setTitle(_ text: String) {
        guard let i = meetings.firstIndex(where: { $0.id == selectedID }) else { return }
        meetings[i].title = text
        store.update(meetings[i])
    }

    // MARK: Запись

    func toggleRecording() {
        if isRecording { stop(); return }
        // Подготовленное собеседование, которое ещё не начиналось, пишем в него же
        if let m = selected, m.isInterview, turns.isEmpty { Task { await start(reuse: m.id) }; return }
        Task { await start() }
    }

    private func start(reuse: Int64? = nil) async {
        guard asrReady, let pipeline else { errorText = "Whisper ещё загружается"; return }
        // Пока висит системный запрос доступа, повторное нажатие не должно запускать вторую запись
        guard !starting else { return }
        starting = true
        defer { starting = false }
        errorText = nil
        if captureMic, await !AVCaptureDevice.requestAccess(for: .audio) {
            errorText = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность → Микрофон."
            return
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM, HH:mm"
        let m: Meeting
        if let reuse, let i = meetings.firstIndex(where: { $0.id == reuse }) {
            meetings[i].startedAt = Date()
            store.setStarted(reuse, meetings[i].startedAt)
            m = meetings.remove(at: i)
        } else if interviewMode {
            m = store.createMeeting(title: "Собеседование " + df.string(from: Date()), kind: "interview")
        } else {
            m = store.createMeeting(title: "Встреча " + df.string(from: Date()))
        }
        meetings.insert(m, at: 0)
        showKB = false
        selectedID = m.id
        recordingID = m.id
        turns = []
        questions = []
        partial = [:]
        voiceNames = [:]
        examinedTurnID = 0
        examinedLen = 0
        candidateSince = nil
        voice?.reset()
        stopPlayback()
        callOffer = nil
        nameChecks = []
        audioWriter = keepAudio ? MeetingAudio(meetingID: m.id) : nil
        selectedHasAudio = false
        shownTurns = 150
        if m.isInterview {
            if interview?.meetingID != m.id { loadInterview(m.id) }
            probedUntil = 0
            interviewTab = 0
            // На время собеседования глубокую модель выгружаем: память нужна быстрой модели и распознаванию.
            // Для итоговой оценки она загрузится снова сама
            stopDeep()
        }

        pipeline.language = language
        pipeline.resetContext()
        // Имена подсказываем и Whisper: так он реже коверкает их при распознавании
        pipeline.prompt = [myName, glossary].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
        micRouter.setMeeting { [weak pipeline] s in pipeline?.feed(.me, s) }
        system.onSamples = { [weak pipeline] s in pipeline?.feed(.them, s) }
        micMuted = !captureMic
        do {
            if captureMic { try mic.start() }
        } catch {
            errorText = "Микрофон: " + error.localizedDescription
            micMuted = true
        }
        if captureSystem {
            do { try system.start() } catch { errorText = error.localizedDescription }
        }
        isRecording = true
        watchSilence()
    }

    /// Выключить или включить микрофон прямо во время записи. Звук звонка продолжает писаться.
    func toggleMic() {
        guard isRecording else { return }
        if !micMuted {
            mic.stop()
            micMuted = true
            partial[.me] = nil
            levels[.me] = 0
            return
        }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                errorText = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность → Микрофон."
                return
            }
            do { try mic.start(); micMuted = false } catch { errorText = "Микрофон: " + error.localizedDescription }
        }
    }

    private func stop() {
        micMuted = false
        if dictating { cancelDictation() }
        micRouter.setMeeting(nil)
        mic.stop()
        system.stop()
        pipeline?.flush()
        isRecording = false
        levels = [:]
        guard let id = recordingID, let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].endedAt = Date()
        count("meetings")
        count("recorded_minutes", meetings[i].endedAt!.timeIntervalSince(meetings[i].startedAt) / 60)
        store.update(meetings[i])
        Task {
            // Даём Whisper дожевать хвост
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            self.recordingID = nil
            self.audioWriter?.close()
            self.audioWriter = nil
            self.refreshHasAudio()
            if self.meetings.first(where: { $0.id == id })?.isInterview == true {
                // Ответы кандидата в общую базу фактов не тащим: там рабочие договорённости, а не люди
                if self.selectedID == id { self.interviewTab = 2 }
                await self.evaluateInterview(id)
                await self.summarize(id)
                await self.checkNames(id)
                await self.index(id)
                return
            }
            await self.summarize(id)
            await self.checkNames(id)
            await self.extractFacts(id)
            await self.index(id)
        }
    }

    /// Забыли остановить запись после звонка: если долго тихо — останавливаем сами.
    private func watchSilence() {
        lastSoundAt = Date()
        Task {
            while isRecording {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard isRecording else { return }
                // Пока индикатор звука горит, тишины нет — даже если слов не распознано
                if levels.values.contains(where: { $0 > 0 }) || pipeline?.anyoneSpeaking == true { lastSoundAt = Date() }
                let limit = Double(autoStopMinutes) * 60
                if limit > 0, Date().timeIntervalSince(lastSoundAt) >= limit {
                    let minutes = autoStopMinutes
                    toggleRecording()
                    Notifier.shared.notify(title: "Запись остановлена", body: "\(minutes) мин было тихо — похоже, встреча закончилась. Итог уже составляется.")
                    return
                }
            }
        }
    }

    private func addTurn(_ speaker: Speaker, _ heard: String, _ who: Int, _ samples: [Float]) {
        guard let id = recordingID else { return }
        lastSoundAt = Date()
        // Словарь исправлений: названия, которые распознавание стабильно коверкает, сразу пишем правильно
        let text = Corrections.apply(heard, Corrections.parse(corrections))
        count("words", Double(text.split(separator: " ").count))
        count("phrases")
        // Микрофон слышит колонки: если реплика совпала с только что сказанной собеседником — это эхо
        let recent = turns.suffix(6).filter { Date().timeIntervalSince($0.ts) < 10 && $0.speaker != speaker }
        if let dup = recent.first(where: { similarity($0.text, text) > 0.6 }) {
            if speaker == .me { return }
            store.deleteTurn(dup.id)
            turns.removeAll { $0.id == dup.id }
        }
        // Whisper режет речь по коротким паузам; подряд идущие куски одного голоса склеиваем в одну реплику
        if var last = turns.last, last.speaker == speaker, last.voice == who || who == 0 || last.voice == 0,
           Date().timeIntervalSince(last.ts) < 3.5, last.text.count < 400 {
            last.text += " " + text
            last.ts = Date()
            if last.voice == 0 { last.voice = who }
            if let r = audioWriter?.append(samples) {
                if last.audioEnd == 0 { last.audioStart = r.0 }
                last.audioEnd = r.1
            }
            store.updateTurn(last)
            turns[turns.count - 1] = last
            turnSpeech[last.id, default: 0] += Double(samples.count) / 16000
        } else {
            let t = store.addTurn(meetingID: id, speaker: speaker, text: text, voice: who, audio: audioWriter?.append(samples) ?? (0, 0))
            let seconds = Double(samples.count) / 16000
            turnStarts[t.id] = Date().addingTimeInterval(-seconds)
            turnSpeech[t.id] = seconds
            turns.append(t)
        }
        if selectedID != id { return }
        if interview?.meetingID == id { considerProbe(); return }
        considerDetect(text)
    }

    // MARK: Последний вопрос

    private static let askWords = ["скажи", "расскажи", "подскажи", "объясни", "напомни", "уточни", "покажи", "пришли", "скинь", "ответь", "можешь", "можете", "сможешь", "сможете"]

    /// Дёшево отсекаем реплики, в которых вопроса заведомо нет, чтобы не гонять модель на каждую фразу.
    private func looksLikeQuestion(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("?") || Self.askWords.contains { t.contains($0) }
    }

    /// Модель зовём не сразу, а когда говорящий договорил: так она видит мысль целиком
    /// (в том числе «спросил и сам ответил») и карточка не перерисовывается по несколько раз.
    private func considerDetect(_ text: String) {
        guard llmReady else { return }
        if looksLikeQuestion(text), candidateSince == nil { candidateSince = Date() }
        guard let since = candidateSince, !detecting else { return }
        detectTask?.cancel()
        detectTask = Task {
            // Фраза уже закрыта паузой, так что обычно идём к модели сразу. Ждём, только если
            // человек уже продолжил говорить: возможно, он сам отвечает на свой вопрос
            while pipeline?.anyoneSpeaking == true, Date().timeIntervalSince(since) < 4 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            candidateSince = nil
            detecting = true
            await detect()
            detecting = false
            if candidateSince != nil { considerDetect("") }
        }
    }

    /// Как реплика подписана в расшифровке и в запросах к модели.
    func label(_ t: Turn) -> String { Self.label(t, voiceNames) }

    /// Ключ голоса внутри встречи: 0 — владелец (или не определён), плюс — собеседники из звонка,
    /// минус — другие люди, которых слышит микрофон.
    nonisolated static func voiceKey(_ t: Turn) -> Int {
        t.speaker == .me ? (t.voice >= 2 ? -t.voice : 0) : t.voice
    }

    static func label(_ t: Turn, _ names: [Int: String]) -> String {
        let key = voiceKey(t)
        if key == 0 { return t.speaker.rawValue }
        if let n = names[key] { return n }
        return key < 0 ? "Голос \(-key)" : "Собеседник \(key)"
    }

    private func lines(_ ts: ArraySlice<Turn>) -> String {
        ts.map { "\(label($0)): \($0.text)" }.joined(separator: "\n")
    }

    private func transcriptTail(_ n: Int, maxChars: Int = 2400) -> String {
        var ls = turns.suffix(n).map { "\(label($0)): \($0.text)" }
        while ls.joined(separator: "\n").count > maxChars, ls.count > 3 { ls.removeFirst() }
        return ls.joined(separator: "\n")
    }

    private static let questionPrompt = """
    Ты ассистент на встрече. Тебе дают расшифровку разговора — она автоматическая, в ней бывают ошибки. «Я» — владелец приложения, остальные подписи — другие участники.
    В блоке «Новые реплики» определи, есть ли ПРЯМОЙ вопрос или просьба, на которые говорящий на самом деле ждёт ответа от другого человека.
    Сначала определи тип:
    - прямой — вопрос или просьба обращены к собеседнику, и ответа пока нет;
    - риторический — вопрос ради эффекта, ответа не ждут («ну кто так делает?»);
    - сам ответил — говорящий тут же сам на него отвечает («и что я сделал? а сделал я вот что…»);
    - в воздух — размышление вслух, ни к кому не обращено, или говорящий сам от него отмахнулся;
    - пустой — «алло», «слышно?», «да?», «понятно?», обрывок без смысла;
    - нет — вопросов и просьб в новых репликах нет.
    Если в новых репликах несколько вопросов, бери последний прямой. Вопросы из блока «Контекст» не бери — они уже обработаны.
    Первая строка ответа всегда: ТИП: <тип>
    Если тип не «прямой», больше ничего не пиши. Если «прямой», добавь ровно пять строк, без пояснений и разметки:
    ВОПРОС: сам вопрос одной чёткой фразой; восстанови из контекста, о чём спрашивают (без «это», «там», «он»)
    КОМУ: имя человека, к которому обратились по имени в реплике с вопросом; если имени не называли — поставь -
    КТО: кто задал вопрос — так, как он подписан в диалоге
    ТЕМА: о чём сейчас разговор, 3–6 слов
    ПОДРОБНО: 1–2 предложения: что обсуждали прямо перед вопросом и что нужно помнить, чтобы ответить
    Не выдумывай имён и фактов.
    """

    private func detect() async {
        guard let llm, let id = recordingID ?? selectedID, let lastTurn = turns.last else { return }
        // Делим хвост разговора на уже проверенное («Контекст») и новое: вопрос ищем только в новом
        var ctx: [String] = []
        var fresh: [String] = []
        for t in turns.suffix(14) {
            if t.id < examinedTurnID {
                ctx.append("\(label(t)): \(t.text)")
            } else if t.id == examinedTurnID {
                let old = String(t.text.prefix(examinedLen)).trimmingCharacters(in: .whitespaces)
                let new = String(t.text.dropFirst(examinedLen)).trimmingCharacters(in: .whitespaces)
                if !old.isEmpty { ctx.append("\(label(t)): \(old)") }
                if !new.isEmpty { fresh.append("\(label(t)): \(new)") }
            } else {
                fresh.append("\(label(t)): \(t.text)")
            }
        }
        guard !fresh.isEmpty else { return }
        defer { examinedTurnID = lastTurn.id; examinedLen = lastTurn.text.count }

        let names = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        var system = Self.questionPrompt
        if !names.isEmpty { system += "\nИмена и термины, которые могут встречаться: \(names)" }
        let me = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { system += "\nВладельца приложения зовут: \(me). Если в реплике с вопросом обращаются к нему по имени или фамилии — в строке КОМУ напиши это имя." }
        let freshText = fresh.joined(separator: " ")
        let user = "Контекст:\n" + (ctx.isEmpty ? "(пусто)" : ctx.joined(separator: "\n")) + "\n\nНовые реплики:\n" + fresh.joined(separator: "\n")

        var acc = ""
        var qid: Int64?
        var decided = false
        func field(_ key: String) -> String? {
            guard let r = acc.range(of: key + ": ") else { return nil }
            let rest = acc[r.upperBound...]
            return String(rest[..<(rest.firstIndex(of: "\n") ?? rest.endIndex)]).trimmingCharacters(in: .whitespaces)
        }
        do {
            for try await piece in llm.chatStream([.init(role: "system", content: system), .init(role: "user", content: user)], maxTokens: 240, temperature: 0.1) {
                acc += piece
                // Первая строка — тип. Показываем только прямые вопросы, на которые ждут ответа
                guard acc.contains("\n") else { continue }
                guard let type = field("ТИП"), type.lowercased().hasPrefix("прям") else { break }
                if !decided {
                    pendingQuestion = field("ВОПРОС") ?? ""
                    guard acc.contains("\nКОМУ:"), var q = field("ВОПРОС"), q.count > 3 else { continue }
                    decided = true
                    pendingQuestion = ""
                    q = q.prefix(1).uppercased() + q.dropFirst()
                    if let last = q.last, !".?!…".contains(last) { q += "?" }
                    // Уже показанный вопрос не трогаем: карточка не должна прыгать и переписываться
                    if questions.suffix(6).contains(where: { similarity($0.question, q) > 0.55 }) { break }
                    let saved = store.addQuestion(Question(id: 0, meetingID: id, ts: Date(), question: q, addressee: "", asker: "", context: "", answer: ""))
                    questions.append(saved)
                    count("questions")
                    qid = saved.id
                }
                guard let qid, let i = questions.firstIndex(where: { $0.id == qid }) else { continue }
                if let v = field("КОМУ"), acc.contains("\nКТО:") {
                    // «Собеседник 2» или «Я» — это не имя: модель подставила подпись вместо прочерка
                    let noName = v == "-" || v == "—" || v == Speaker.me.rawValue || v.hasPrefix(Speaker.them.rawValue) || v.hasPrefix("Голос")
                    // Имя должно реально прозвучать в последних репликах, иначе модель его домыслила
                    let recent = turns.suffix(3).map { $0.text }.joined(separator: " ").lowercased()
                    let stem = String(v.lowercased().prefix(max(3, v.count - 2)))
                    questions[i].addressee = (noName || !recent.contains(stem)) ? "" : v
                    // Вопрос к владельцу: имя назвала модель или оно прямо прозвучало в новых репликах
                    if !questions[i].forMe, isMyName(questions[i].addressee) || (questions[i].addressee.isEmpty && isMyName(freshText)) {
                        questions[i].forMe = true
                        count("questions_me")
                        if questions[i].addressee.isEmpty { questions[i].addressee = me.components(separatedBy: CharacterSet(charactersIn: ", ")).first ?? me }
                        Notifier.shared.notify(title: "Вопрос к вам", body: questions[i].question)
                    }
                }
                if let v = field("КТО"), acc.contains("\nТЕМА:") { questions[i].asker = v }
                if let v = field("ТЕМА") { questions[i].topic = v }
                if let v = field("ПОДРОБНО") { questions[i].context = v }
            }
            pendingQuestion = ""
            if let qid, let i = questions.firstIndex(where: { $0.id == qid }) { store.update(questions[i]) }
        } catch {
            pendingQuestion = ""
            log("detect: \(error.localizedDescription)")
        }
    }

    // MARK: Факты

    private func embedFact(_ text: String) async -> [Float] {
        (try? await llm?.embed(["title: none | text: " + text]).first) ?? []
    }

    private func json(_ raw: String) -> [String: Any]? {
        guard let d = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// После встречи: вытаскиваем долговечные факты и сверяем с базой — новое добавляем, изменившееся заменяем.
    func extractFacts(_ id: Int64) async {
        guard let llm, llmReady, embedReady else { return }
        let all = store.turns(meetingID: id)
        guard all.count >= 2, let m = meetings.first(where: { $0.id == id }) else { return }
        let names = store.voiceNames(meetingID: id)
        var text = all.map { "\(Self.label($0, names)): \($0.text)" }.joined(separator: "\n")
        if text.count > 9000 { text = m.summary + "\n\nКонец расшифровки:\n" + String(text.suffix(6000)) }
        kbStatus = "Ищу факты во встрече…"
        defer { kbStatus = "" }
        let system = """
        Ты ведёшь базу знаний владельца приложения. Из расшифровки встречи выдели долговечные факты — то, что будет полезно помнить через недели и месяцы:
        цифры и метрики («сервис раскатили на 15 тысяч пользователей»), принятые решения, сроки и даты, кто за что отвечает, договорённости, параметры проектов и продуктов.
        Каждый факт — одно самостоятельное предложение, понятное без самой встречи: с названиями, именами и числами, без «он», «это», «там».
        Не включай: мнения и эмоции, ход обсуждения, вопросы без ответа, сиюминутное («сейчас посмотрю»), догадки и то, в чём говорящие не уверены.
        Если таких фактов нет — верни пустой список. Не больше 8 фактов. Ничего не выдумывай.
        """
        let schema: [String: Any] = ["type": "object", "properties": ["facts": ["type": "array", "items": ["type": "string"]]], "required": ["facts"], "additionalProperties": false]
        guard let raw = try? await llm.chat([.init(role: "system", content: system), .init(role: "user", content: text)], schema: schema, maxTokens: 700, temperature: 0.1),
              let found = json(raw)?["facts"] as? [String] else { return }
        for f in found.prefix(8) {
            let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 10 { await mergeFact(t, meetingID: id) }
        }
    }

    /// Кладёт факт в базу: если там уже есть про то же самое — заменяет или пропускает.
    private func mergeFact(_ text: String, meetingID: Int64) async {
        guard let llm else { return }
        let v = await embedFact(text)
        guard !v.isEmpty else { return }
        let near = facts.map { ($0, cosine($0.vector, v)) }.filter { $0.1 > 0.5 }.sorted { $0.1 > $1.1 }.prefix(4).map { $0.0 }
        if near.isEmpty {
            facts.insert(store.addFact(text: text, meetingID: meetingID, vector: v), at: 0)
            return
        }
        let system = """
        Ты ведёшь базу фактов. Пришёл новый факт, в базе есть похожие. Реши, что делать:
        - add — в базе нет факта о том же самом, это новая информация;
        - update — новый факт о том же, что и один из существующих, но значение изменилось или стало точнее (было «раскатили на 15 тысяч», стало «раскатили на 100 тысяч»): верни id заменяемого факта и итоговый текст с актуальным значением;
        - skip — в базе уже есть то же самое.
        """
        let user = "Новый факт: \(text)\n\nПохожие факты в базе:\n" + near.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["op": ["type": "string", "enum": ["add", "update", "skip"]], "id": ["type": "integer"], "text": ["type": "string"]],
            "required": ["op", "id", "text"], "additionalProperties": false,
        ]
        let o = (try? await llm.chat([.init(role: "system", content: system), .init(role: "user", content: user)], schema: schema, maxTokens: 200, temperature: 0.1)).flatMap(json)
        switch o?["op"] as? String {
        case "skip": return
        case "update":
            let fid = (o?["id"] as? NSNumber)?.int64Value ?? 0
            let newText = ((o?["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if near.contains(where: { $0.id == fid }) {
                await applyOps([FactOp(op: "update", factID: fid, text: newText.count >= 10 ? newText : text)], meetingID: meetingID)
                return
            }
            fallthrough
        default:
            facts.insert(store.addFact(text: text, meetingID: meetingID, vector: v), at: 0)
        }
    }

    /// Применяет изменения к базе фактов. Возвращает то, что реально сделано (с прежним текстом).
    @discardableResult
    func applyOps(_ ops: [FactOp], meetingID: Int64 = 0) async -> [FactOp] {
        var done: [FactOp] = []
        for var op in ops {
            let text = op.text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch op.op {
            case "add":
                guard text.count >= 5 else { continue }
                let v = await embedFact(text)
                facts.insert(store.addFact(text: text, meetingID: meetingID, vector: v), at: 0)
            case "update":
                guard text.count >= 5, let i = facts.firstIndex(where: { $0.id == op.factID }) else { continue }
                var f = facts[i]
                op.old = f.text
                f.previous = f.text
                f.text = text
                f.updatedAt = Date()
                if meetingID != 0 { f.meetingID = meetingID }
                f.vector = await embedFact(text)
                store.updateFact(f)
                facts.remove(at: i)
                facts.insert(f, at: 0)
            case "delete":
                guard let i = facts.firstIndex(where: { $0.id == op.factID }) else { continue }
                op.old = facts[i].text
                store.deleteFact(op.factID)
                facts.remove(at: i)
            default: continue
            }
            done.append(op)
        }
        return done
    }

    func deleteFact(_ id: Int64) {
        store.deleteFact(id)
        facts.removeAll { $0.id == id }
    }

    /// Подтверждение изменений, предложенных аудитом.
    func applyProposal(_ lineID: UUID) {
        guard let i = chat.firstIndex(where: { $0.id == lineID }), chat[i].opsPending else { return }
        let ops = chat[i].ops
        chat[i].opsPending = false
        Task {
            let done = await applyOps(ops)
            if let j = chat.firstIndex(where: { $0.id == lineID }) {
                chat[j].ops = done
                chat[j].text += "\n\nПрименено изменений: \(done.count)."
            }
        }
    }

    func rejectProposal(_ lineID: UUID) {
        guard let i = chat.firstIndex(where: { $0.id == lineID }) else { return }
        chat[i].opsPending = false
        chat[i].ops = []
        chat[i].text += "\n\nИзменения отклонены, база не тронута."
    }

    private func kbIntent(_ q: String) async -> String {
        guard let llm else { return "answer" }
        let system = """
        Определи, чего хочет пользователь от базы знаний:
        - answer — задаёт вопрос или просит что-то найти, рассказать, сравнить;
        - edit — просит добавить, запомнить, изменить, исправить или удалить факт («запомни, что…», «исправь: теперь 100 тысяч», «удали факт про…»);
        - audit — просит проверить, почистить, провести ревизию или аудит фактов на актуальность и нужность.
        """
        let schema: [String: Any] = ["type": "object", "properties": ["intent": ["type": "string", "enum": ["answer", "edit", "audit"]]], "required": ["intent"], "additionalProperties": false]
        let o = (try? await llm.chat([.init(role: "system", content: system), .init(role: "user", content: q)], schema: schema, maxTokens: 20, temperature: 0)).flatMap(json)
        return (o?["intent"] as? String) ?? "answer"
    }

    private func parseOps(_ raw: [[String: Any]], allowed: [Fact]) -> [FactOp] {
        raw.compactMap { o in
            guard let op = o["op"] as? String else { return nil }
            let fid = (o["id"] as? NSNumber)?.int64Value ?? 0
            if op != "add", !allowed.contains(where: { $0.id == fid }) { return nil }
            let old = allowed.first { $0.id == fid }?.text ?? ""
            return FactOp(op: op, factID: fid, text: (o["text"] as? String) ?? "", old: old, reason: (o["reason"] as? String) ?? "")
        }
    }

    /// Прямая просьба изменить факты — выполняем сразу.
    private func editFacts(_ q: String) async {
        guard let llm else { return }
        var pool = facts
        if pool.count > 30 {
            let qv = await embedFact(q)
            pool = facts.map { ($0, cosine($0.vector, qv)) }.sorted { $0.1 > $1.1 }.prefix(20).map { $0.0 }
        }
        let system = """
        Пользователь просит изменить базу фактов. Выполни просьбу операциями:
        - add — добавить новый факт (text; id = 0);
        - update — заменить текст существующего факта (id и новый text целиком);
        - delete — удалить факт (id; text пустой).
        Каждый факт — одно самостоятельное предложение с названиями и числами. Меняй только то, о чём просят. Если непонятно, какой факт имеется в виду, ничего не меняй и спроси в reply.
        reply — одна-две фразы: что сделано.
        """
        let user = "Факты в базе:\n" + (pool.isEmpty ? "(пусто)" : pool.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n")) + "\n\nПросьба: \(q)"
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "reply": ["type": "string"],
                "ops": ["type": "array", "items": [
                    "type": "object",
                    "properties": ["op": ["type": "string", "enum": ["add", "update", "delete"]], "id": ["type": "integer"], "text": ["type": "string"]],
                    "required": ["op", "id", "text"], "additionalProperties": false,
                ]],
            ],
            "required": ["reply", "ops"], "additionalProperties": false,
        ]
        guard let o = (try? await llm.chat([.init(role: "system", content: system), .init(role: "user", content: user)], schema: schema, maxTokens: 700, temperature: 0.1)).flatMap(json) else {
            chat[chat.count - 1].text = "Не получилось разобрать просьбу — попробуйте сформулировать иначе."
            return
        }
        let done = await applyOps(parseOps((o["ops"] as? [[String: Any]]) ?? [], allowed: pool))
        chat[chat.count - 1].text = (o["reply"] as? String) ?? (done.isEmpty ? "Ничего не изменил." : "Готово.")
        chat[chat.count - 1].ops = done
        kbTab = 0
    }

    /// Ревизия фактов: модель только предлагает, применяет пользователь кнопкой.
    /// Идём в два прохода: по каждому факту — нужен ли он вообще, затем по похожим парам — дубль или устаревшее.
    private func auditFacts() async {
        guard let llm else { return }
        guard !facts.isEmpty else { chat[chat.count - 1].text = "В базе пока нет фактов — проверять нечего."; return }
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        var ops: [FactOp] = []
        var dropped = Set<Int64>()

        // 1. Нужность. Вердикт требуем по каждому факту — иначе маленькая модель отвечает «всё хорошо», не вчитываясь
        let system = """
        Ты проверяешь базу знаний рабочих встреч. Сегодня \(df.string(from: Date())). Для КАЖДОГО факта из списка вынеси вердикт:
        - keep — полезно помнить через недели и месяцы: цифры и метрики, решения, сроки, ответственные, договорённости, параметры проектов;
        - drop — не нужно хранить: погода, настроение, бытовое и сиюминутное, мнение вместо факта, обрывок без смысла, непонятное без контекста, срок, который давно прошёл.
        reason — причина в нескольких словах.
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["items": ["type": "array", "items": [
                "type": "object",
                "properties": ["id": ["type": "integer"], "verdict": ["type": "string", "enum": ["keep", "drop"]], "reason": ["type": "string"]],
                "required": ["id", "verdict", "reason"], "additionalProperties": false,
            ]]],
            "required": ["items"], "additionalProperties": false,
        ]
        let sorted = facts.sorted { $0.updatedAt < $1.updatedAt }
        for start in stride(from: 0, to: sorted.count, by: 20) {
            let batch = Array(sorted[start..<min(start + 20, sorted.count)])
            chat[chat.count - 1].text = "Проверяю нужность: \(start + batch.count) из \(sorted.count)…"
            let user = batch.map { "[\($0.id)] (\(df.string(from: $0.updatedAt))) \($0.text)" }.joined(separator: "\n")
            guard let o = (try? await llm.chat([.init(role: "system", content: system), .init(role: "user", content: user)], schema: schema, maxTokens: 1500, temperature: 0.1)).flatMap(json),
                  let items = o["items"] as? [[String: Any]] else { continue }
            for it in items where (it["verdict"] as? String) == "drop" {
                let fid = (it["id"] as? NSNumber)?.int64Value ?? 0
                guard let f = batch.first(where: { $0.id == fid }), dropped.insert(fid).inserted else { continue }
                ops.append(FactOp(op: "delete", factID: fid, text: "", old: f.text, reason: "Не нужен: " + ((it["reason"] as? String) ?? "")))
            }
        }

        // 2. Дубли и устаревшее: сравниваем только похожие по смыслу пары
        let pairSystem = """
        Сравни два факта из базы знаний:
        - same — говорят одно и то же разными словами;
        - conflict — об одном и том же, но значения расходятся (разные числа, даты, ответственные);
        - different — о разном, оба нужны.
        """
        let pairSchema: [String: Any] = ["type": "object", "properties": ["relation": ["type": "string", "enum": ["same", "conflict", "different"]]], "required": ["relation"], "additionalProperties": false]
        let alive = sorted.filter { !dropped.contains($0.id) }
        var pairs: [(Fact, Fact)] = []
        for i in 0..<alive.count {
            for j in (i + 1)..<alive.count where cosine(alive[i].vector, alive[j].vector) > 0.72 { pairs.append((alive[i], alive[j])) }
        }
        for (n, (older, newer)) in pairs.prefix(40).enumerated() {
            if dropped.contains(older.id) || dropped.contains(newer.id) { continue }
            chat[chat.count - 1].text = "Ищу дубли: \(n + 1) из \(min(pairs.count, 40))…"
            let user = "Факт А (\(df.string(from: older.updatedAt))): \(older.text)\nФакт Б (\(df.string(from: newer.updatedAt))): \(newer.text)"
            let rel = (try? await llm.chat([.init(role: "system", content: pairSystem), .init(role: "user", content: user)], schema: pairSchema, maxTokens: 20, temperature: 0)).flatMap(json)?["relation"] as? String
            guard rel == "same" || rel == "conflict" else { continue }
            dropped.insert(older.id)
            let why = rel == "same" ? "Дубль факта: «\(newer.text)»" : "Устарел: есть более свежий факт «\(newer.text)»"
            ops.append(FactOp(op: "delete", factID: older.id, text: "", old: older.text, reason: why))
        }

        var text = "Проверил фактов: \(facts.count)."
        if ops.isEmpty { text += " Лишнего, дублей и устаревшего не нашёл." } else { text += " Предлагаю удалить: \(ops.count). Посмотрите список и подтвердите — без этого база не изменится." }
        chat[chat.count - 1].text = text
        chat[chat.count - 1].ops = ops
        chat[chat.count - 1].opsPending = !ops.isEmpty
        kbTab = 0
    }

    // MARK: Прокрутка расшифровки

    /// Пользователь листает расшифровку во время записи: на 10 секунд перестаём тянуть её вниз.
    func userScrolled() {
        guard isRecording, selectedID == recordingID else { return }
        followPausedUntil = Date().addingTimeInterval(10)
        followTask?.cancel()
        followTask = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled { resumeFollow() }
        }
    }

    func resumeFollow() {
        followTask?.cancel()
        followPausedUntil = nil
        scrollTick += 1
    }

    // MARK: Моё имя

    /// Есть ли в тексте имя или фамилия владельца. Сравниваем по основе слова, чтобы ловить падежи:
    /// «Денис», «Дениса», «Денису».
    func isMyName(_ text: String) -> Bool {
        let mine = myName.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 3 }
        guard !mine.isEmpty, !text.isEmpty else { return false }
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return mine.contains { name in words.contains { Self.isForm($0, of: name) } }
    }

    /// Слово — это имя в одном из падежей: «Денис», «Дениса», «Денису»; «Аня», «Ани», «Аню».
    /// Сравниваем не по началу слова, а по окончаниям: иначе короткое имя «Ден» находилось в «денег» и «день».
    static func isForm(_ word: String, of name: String) -> Bool {
        if word == name { return true }
        let root: Substring
        let endings: [String]
        switch name.last {
        case "а", "я": root = name.dropLast(); endings = ["а", "я", "ы", "и", "е", "у", "ю", "ой", "ей", "ою", "ею"]
        case "й": root = name.dropLast(); endings = ["й", "я", "ю", "ем", "е"]
        case "ь": root = name.dropLast(); endings = ["ь", "я", "ю", "ем", "е", "и"]
        default: root = Substring(name); endings = ["а", "у", "е", "ом", "ы"]
        }
        guard word.hasPrefix(root) else { return false }
        return endings.contains(String(word.dropFirst(root.count)))
    }

    func nameChanged() {
        if !myName.trimmingCharacters(in: .whitespaces).isEmpty { Notifier.shared.setup() }
    }

    // MARK: Голоса

    func renameVoice(_ voice: Int, to name: String) {
        guard let id = selectedID else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        voiceNames[voice] = n
        store.setVoiceName(meetingID: id, voice: voice, name: n)
    }

    /// Подсказка к ответу: ищем по базе прошлых встреч и по текущему разговору.
    func suggestAnswer(for qid: Int64) {
        guard let llm, let i = questions.firstIndex(where: { $0.id == qid }), !answering else { return }
        answering = true
        let q = questions[i]
        Task {
            defer { answering = false }
            let found = await retrieve(q.question, limit: 5).map { $0.0 }
            var user = "Вопрос: \(q.question)\n"
            if !q.topic.isEmpty { user += "Тема: \(q.topic)\n" }
            if !q.context.isEmpty { user += "Контекст: \(q.context)\n" }
            user += "\nТекущий разговор:\n" + transcriptTail(20)
            if !found.isEmpty { user += "\n\nИз базы знаний и прошлых встреч:\n" + found.joined(separator: "\n---\n") }
            let system = "Ты подсказываешь владельцу приложения, что ответить на вопрос во время встречи. Дай короткую подсказку на русском: 2–4 предложения или пара пунктов. Опирайся только на данные ниже; если данных не хватает, честно скажи, чего не хватает."
            do {
                var acc = ""
                for try await piece in llm.chatStream([.init(role: "system", content: system), .init(role: "user", content: user)], maxTokens: 350) {
                    acc += piece
                    if let j = questions.firstIndex(where: { $0.id == qid }) { questions[j].answer = acc }
                }
                if let j = questions.firstIndex(where: { $0.id == qid }) { store.update(questions[j]) }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    // MARK: Сводка и поиск

    func summarize(_ id: Int64) async {
        guard let llm, llmReady, !summarizing else { return }
        let all = store.turns(meetingID: id)
        guard all.count >= 2, let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        summarizing = true
        defer { summarizing = false }
        let names = store.voiceNames(meetingID: id)
        let text = all.map { "\(Self.label($0, names)): \($0.text)" }.joined(separator: "\n")
        let notes = meetings[i].notes
        do {
            // Длинную встречу сжимаем по частям, затем собираем итог
            var parts = split(text, size: 9000)
            if parts.count > 1 {
                var digests: [String] = []
                for p in parts {
                    digests.append(try await llm.chat([
                        .init(role: "system", content: "Сожми фрагмент расшифровки встречи в 5–8 пунктов: факты, решения, задачи, вопросы. Только по тексту, на русском."),
                        .init(role: "user", content: p),
                    ], maxTokens: 500))
                }
                parts = [digests.joined(separator: "\n")]
            }
            let system = """
            Ты составляешь итог встречи по расшифровке (в ней возможны ошибки распознавания). «Я» — владелец приложения. Пиши на русском, только по тексту, ничего не выдумывай. Формат Markdown:
            **Коротко** — 2–3 предложения.
            **Решения** — список.
            **Задачи** — список «кто — что».
            **Открытые вопросы** — список.
            Пустые разделы пропускай.
            """
            var user = "Расшифровка:\n" + parts[0]
            if !notes.isEmpty { user += "\n\nЗаметки владельца:\n" + notes }
            let summary = try await llm.chat([.init(role: "system", content: system), .init(role: "user", content: user)], maxTokens: 900)
            let title = try await llm.chat([
                .init(role: "system", content: "Придумай название встречи: 3–6 слов на русском, без кавычек и точки в конце. Верни только название."),
                .init(role: "user", content: summary),
            ], maxTokens: 30)
            guard let j = meetings.firstIndex(where: { $0.id == id }) else { return }
            meetings[j].summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let t = title.trimmingCharacters(in: CharacterSet(charactersIn: " \n\"«».*#"))
            if !t.isEmpty, t.count < 80, meetings[j].title.hasPrefix("Встреча ") { meetings[j].title = t }
            store.update(meetings[j])
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func split(_ s: String, size: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for line in s.split(separator: "\n") {
            if cur.count + line.count > size, !cur.isEmpty { out.append(cur); cur = "" }
            cur += line + "\n"
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    private func index(_ id: Int64) async {
        guard let llm, embedReady, let m = meetings.first(where: { $0.id == id }) else { return }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateStyle = .medium
        let head = "Встреча «\(m.title)», \(df.string(from: m.startedAt))\n"
        let names = store.voiceNames(meetingID: id)
        let text = store.turns(meetingID: id).map { "\(Self.label($0, names)): \($0.text)" }.joined(separator: "\n")
        var pieces = split(text, size: 700).map { head + $0 }
        if !m.summary.isEmpty { pieces.append(head + "Итог:\n" + m.summary) }
        if !m.notes.isEmpty { pieces.append(head + "Заметки:\n" + m.notes) }
        guard !pieces.isEmpty else { return }
        do {
            var rows: [(String, [Float])] = []
            for start in stride(from: 0, to: pieces.count, by: 8) {
                let batch = Array(pieces[start..<min(start + 8, pieces.count)])
                let vecs = try await llm.embed(batch.map { "title: none | text: " + $0 })
                for (t, v) in zip(batch, vecs) { rows.append((t, v)) }
            }
            store.replaceChunks(meetingID: id, chunks: rows)
        } catch {
            log("index: \(error.localizedDescription)")
        }
    }

    /// Поиск по базе: документы и прошлые встречи. Возвращает фрагмент и название источника.
    private func retrieve(_ query: String, limit: Int) async -> [(String, String)] {
        guard let llm, embedReady, let qv = try? await llm.embed(["task: search result | query: " + query]).first else { return [] }
        let all = store.allChunks().map { ($0.text, $0.source, cosine($0.vector, qv)) }
            + facts.map { ("Факт: " + $0.text, "Факты", cosine($0.vector, qv) + 0.05) }
        return all
            .filter { $0.2 > 0.3 }
            .sorted { $0.2 > $1.2 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }

    // MARK: База знаний

    func pickDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Выберите файлы для базы знаний: PDF, Word, текст, Markdown"
        if panel.runModal() == .OK { addDocuments(panel.urls) }
    }

    func addDocuments(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard embedReady, let llm else { errorText = "Модель поиска ещё загружается — попробуйте через несколько секунд."; return }
        Task {
            for url in urls {
                let title = url.lastPathComponent
                kbStatus = "Читаю «\(title)»…"
                let text = await Task.detached { Self.extractText(url) }.value
                guard let text, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20 else {
                    errorText = "Не удалось прочитать текст из «\(title)»."
                    continue
                }
                let pieces = Self.chunk(text, size: 900).map { "Документ «\(title)»\n" + $0 }
                var rows: [(String, [Float])] = []
                do {
                    for start in stride(from: 0, to: pieces.count, by: 8) {
                        kbStatus = "Индексирую «\(title)»: \(Int(Double(start) / Double(pieces.count) * 100))%"
                        let batch = Array(pieces[start..<min(start + 8, pieces.count)])
                        let vecs = try await llm.embed(batch.map { "title: none | text: " + $0 })
                        for (t, v) in zip(batch, vecs) { rows.append((t, v)) }
                    }
                } catch {
                    errorText = "Не удалось проиндексировать «\(title)»: " + error.localizedDescription
                    continue
                }
                let doc = store.addDocument(title: title, path: url.path, chars: text.count)
                store.addDocChunks(docID: doc.id, chunks: rows)
                documents.insert(doc, at: 0)
            }
            kbStatus = ""
        }
    }

    func deleteDocument(_ id: Int64) {
        store.deleteDocument(id)
        documents.removeAll { $0.id == id }
    }

    nonisolated static func extractText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return PDFDocument(url: url)?.string }
        if ["rtf", "rtfd", "doc", "docx", "odt", "html", "htm", "webarchive"].contains(ext) {
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return try? String(contentsOf: url, encoding: .windowsCP1251)
    }

    /// Режет текст на куски по абзацам; слишком длинные абзацы делит принудительно.
    nonisolated static func chunk(_ text: String, size: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() {
            let t = cur.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            cur = ""
        }
        for para in text.components(separatedBy: "\n") {
            var p = Substring(para.trimmingCharacters(in: .whitespaces))
            if p.isEmpty { continue }
            while p.count > size {
                flush()
                out.append(String(p.prefix(size)))
                p = p.dropFirst(size)
            }
            if cur.count + p.count > size { flush() }
            cur += p + "\n"
        }
        flush()
        return out
    }

    func ask(_ text: String) {
        count("chat_questions")
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let llm, llmReady, !q.isEmpty, !chatBusy else { return }
        chat.append(ChatLine(role: "user", text: q))
        chat.append(ChatLine(role: "assistant", text: ""))
        chatBusy = true
        Task {
            defer { chatBusy = false }
            // В базе знаний чат умеет не только отвечать, но и править факты и проводить их ревизию
            if showKB {
                switch await kbIntent(q) {
                case "edit": await editFacts(q); return
                case "audit": await auditFacts(); return
                default: break
                }
            }
            let system: String
            if !showKB, let m = selected {
                // Чат внутри встречи отвечает только по ней самой — по всей расшифровке, итогу и заметкам
                // Уточняющий вопрос («и что решили?») сам по себе ни о чём: ищем по нему вместе с предыдущим обменом
                let before = chat.dropLast(2).suffix(2).map { String($0.text.prefix(300)) }.joined(separator: " ")
                let ctx = await meetingContext(before.isEmpty ? q : before + " " + q, m)
                system = "Ты помощник по одной встрече владельца приложения. «Я» в расшифровке — владелец. Отвечай на русском, кратко и по делу, опираясь только на расшифровку, итог и заметки этой встречи ниже. Расшифровка автоматическая, в ней бывают ошибки распознавания. Если ответа во встрече нет — так и скажи. Это продолжающийся разговор: короткий уточняющий вопрос («и что обсудили?», «а кто?») относится к теме твоего предыдущего ответа, а не ко всей встрече.\n\n" + ctx + interviewContext()
            } else {
                let found = await retrieve(q, limit: 8)
                var seen = Set<String>()
                chat[chat.count - 1].sources = found.map { $0.1 }.filter { !$0.isEmpty && seen.insert($0).inserted }
                var ctx = ""
                if !found.isEmpty { ctx += "Найдено в базе знаний и прошлых встречах:\n" + found.map { $0.0 }.joined(separator: "\n---\n") }
                system = "Ты помощник владельца приложения по его документам и встречам. Отвечай на русском, кратко и по делу, опираясь только на данные ниже; где уместно, называй документ или встречу, откуда взят факт. Если в данных ответа нет — так и скажи.\n\n" + ctx
            }
            var msgs = [ChatMessage(role: "system", content: system)]
            for line in chat.dropLast().suffix(8) { msgs.append(.init(role: line.role, content: line.text)) }
            do {
                for try await piece in llm.chatStream(msgs) {
                    chat[chat.count - 1].text += piece
                }
            } catch {
                chat[chat.count - 1].text = "Ошибка: " + error.localizedDescription
            }
        }
    }
}

extension AppState {
    /// Что показать модели для вопроса по встрече. Короткая встреча уходит целиком;
    /// из длинной берём куски, подходящие к вопросу, и самый конец разговора.
    func meetingContext(_ q: String, _ m: Meeting) async -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy, HH:mm"
        var ctx = "Встреча «\(m.title)», \(df.string(from: m.startedAt)).\n"
        if !m.summary.isEmpty { ctx += "\nИтог:\n\(m.summary)\n" }
        if !m.notes.isEmpty { ctx += "\nЗаметки владельца:\n\(m.notes)\n" }
        let full = turns.map { "\(label($0)): \($0.text)" }.joined(separator: "\n")
        guard !full.isEmpty else { return ctx + "\nРасшифровки пока нет." }
        if full.count <= 9000 { return ctx + "\nПолная расшифровка:\n" + full }

        let tail = String(full.suffix(2200))
        let pieces = Self.chunk(full, size: 800)
        var picked: [String] = []
        if embedReady, let llm = chatClient {
            // Последний кусок ещё растёт во время записи — его не кэшируем
            let missing = pieces.dropLast().filter { meetingVecCache[$0] == nil }
            for start in stride(from: 0, to: missing.count, by: 8) {
                let batch = Array(missing[start..<min(start + 8, missing.count)])
                if let vecs = try? await llm.embed(batch.map { "title: none | text: " + $0 }) {
                    for (t, v) in zip(batch, vecs) { meetingVecCache[t] = v }
                }
            }
            if let qv = try? await llm.embed(["task: search result | query: " + q]).first {
                let ranked = pieces.enumerated()
                    .compactMap { (i, t) in meetingVecCache[t].map { (i, cosine($0, qv)) } }
                    .sorted { $0.1 > $1.1 }
                    .prefix(7)
                    .map { $0.0 }
                    .sorted()
                picked = ranked.map { pieces[$0] }
            }
        }
        if picked.isEmpty { return ctx + "\nКонец расшифровки (встреча длинная, начало не поместилось):\n" + String(full.suffix(8500)) }
        return ctx + "\nФрагменты расшифровки, подходящие к вопросу (по порядку):\n" + picked.joined(separator: "\n…\n") + "\n\nКонец расшифровки:\n" + tail
    }

    // MARK: Итог: копирование и экспорт

    /// Итог простым текстом, без разметки.
    func summaryPlainText(_ m: Meeting) -> String {
        m.summary.components(separatedBy: "\n").map { raw -> String in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") || line.hasPrefix("* ") { line = "• " + line.dropFirst(2).trimmingCharacters(in: .whitespaces) }
            line = line.replacingOccurrences(of: "**", with: "")
            while line.hasPrefix("#") { line.removeFirst() }
            return line.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    func copySummary() {
        guard let m = selected, !m.summary.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(m.title + "\n\n" + summaryPlainText(m), forType: .string)
        copiedNote = "Скопировано"
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copiedNote = "" }
    }

    /// Итог встречи как оформленный документ: название, дата, разделы и пункты.
    nonisolated static func summaryDocument(_ m: Meeting) -> NSAttributedString {
        let out = NSMutableAttributedString()
        func add(_ text: String, size: CGFloat, bold: Bool = false, color: NSColor = .black, before: CGFloat = 0, indent: CGFloat = 0) {
            let para = NSMutableParagraphStyle()
            para.paragraphSpacingBefore = before
            para.paragraphSpacing = 4
            para.headIndent = indent
            para.firstLineHeadIndent = 0
            if indent > 0 { para.tabStops = [NSTextTab(textAlignment: .left, location: indent)] }
            // Внутри строки «**так**» помечен полужирный
            let parts = text.components(separatedBy: "**")
            for (i, part) in parts.enumerated() where !part.isEmpty {
                let isBold = bold || i % 2 == 1
                out.append(NSAttributedString(string: part, attributes: [
                    .font: isBold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size),
                    .foregroundColor: color, .paragraphStyle: para,
                ]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: size), .paragraphStyle: para]))
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM yyyy, HH:mm"
        add(m.title, size: 18, bold: true)
        add(df.string(from: m.startedAt), size: 10, color: .darkGray)
        for raw in m.summary.components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                add("•\t" + line.dropFirst(2).trimmingCharacters(in: .whitespaces), size: 12, indent: 18)
            } else if line.hasPrefix("#") || (line.hasPrefix("**") && line.hasSuffix("**")) {
                while line.hasPrefix("#") { line.removeFirst() }
                add(line.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces), size: 13, bold: true, before: 10)
            } else {
                add(line, size: 12, before: line.hasPrefix("**") ? 10 : 0)
            }
        }
        return out
    }

    /// Сохраняет итог встречи в файл Word (.docx).
    func exportSummaryToWord() {
        guard let m = selected, !m.summary.isEmpty else { return }
        let panel = NSSavePanel()
        let safe = m.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ")
        panel.nameFieldStringValue = safe + ".docx"
        panel.message = "Куда сохранить итог встречи"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "docx" { url.appendPathExtension("docx") }

        let out = Self.summaryDocument(m)
        do {
            let data = try out.data(from: NSRange(location: 0, length: out.length),
                                    documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorText = "Не удалось сохранить файл Word: " + error.localizedDescription
        }
    }
}

/// Доля общих слов — грубая, но быстрая мера похожести двух фраз.
func similarity(_ a: String, _ b: String) -> Double {
    func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 })
    }
    let x = words(a), y = words(b)
    guard !x.isEmpty, !y.isEmpty else { return 0 }
    return Double(x.intersection(y).count) / Double(min(x.count, y.count))
}

func freePort() -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    return Int(UInt16(bigEndian: addr.sin_port))
}
