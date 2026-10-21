import AppKit
import Foundation

// MARK: Данные собеседования

/// Вопрос из карты: обязательный по требованиям, «про человека» (цель скрыта) или с подковыркой.
struct PlanQuestion: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    /// must | person | tricky
    var kind: String
    var text: String
    /// Что на самом деле проверяем; для вопросов «про человека» это скрытая цель
    var purpose: String
    /// Что хотим услышать в хорошем ответе
    var listen: String
    var requirement: String
    var asked = false
    var skipped = false
}

struct InterviewPlan: Codable, Hashable {
    /// Ключевые требования вакансии, коротко
    var requirements: [String] = []
    /// Кто перед нами по резюме: 3–5 строк
    var brief = ""
    /// Что стоит проверить: заявленные достижения, неясности, пробелы
    var focus: [String] = []
    var questions: [PlanQuestion] = []
    /// Карту собрала глубокая модель или запасная
    var deep = false
}

/// Разбор одного ответа кандидата прямо во время собеседования.
struct Probe: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var ts = Date()
    /// Реплика интервьюера, с которой начался обмен: по ней один и тот же ответ не разбираем дважды
    var questionTurnID: Int64
    var question: String
    var gist: String
    /// strong | ok | vague | evasive | contradiction | red_flag
    var verdict: String
    var followup: String
    var reason: String
    var used = false
    var dismissed = false
    /// Насколько кандидат владеет темой по этому ответу: 0 — не знает, 5 — свободно. У старых разборов нет
    var mastery: Int?
    /// Похоже ли, что кандидат зачитывает ответ нейросети: 0 — живая речь, 3 — явно читает текст
    var ai: Int?
    var aiWhy: String?
    /// Как отвечал: пауза перед ответом, темп, «ээ»
    var stats: AnswerStats?
    /// Уточнение готово, а кандидат ещё не договорил — показываем бледно, чтобы интервьюер видел заранее
    var draft: Bool?
}

/// Как кандидат отвечал — считается по самой речи, без модели, поэтому видно сразу.
struct AnswerStats: Codable, Hashable {
    /// Сколько секунд молчал после вопроса, прежде чем начать
    var latency: Double?
    var words: Int
    /// «ээ», «ну», «как бы» на 100 слов
    var fillers: Double
    /// Слов в секунду речи
    var pace: Double?

    /// Маркеры для интервьюера: текст и цвет
    var markers: [(String, String)] {
        var out: [(String, String)] = []
        if let l = latency, l >= 6 { out.append(("Долго думал: \(Int(l)) с", "orange")) }
        if fillers >= 6 { out.append(("Много «ээ» и «ну»", "orange")) }
        if let p = pace, p < 1.3, words >= 15 { out.append(("Говорит медленно, с паузами", "orange")) }
        if words < 12 { out.append(("Очень короткий ответ", "orange")) }
        if fillers < 1, words >= 50, (latency ?? 0) >= 4 { out.append(("Гладко, как по написанному", "purple")) }
        return out
    }

    var line: String {
        var s: [String] = []
        if let l = latency { s.append("пауза перед ответом \(Int(l.rounded())) с") }
        if let p = pace { s.append(String(format: "темп %.1f слова в секунду", p)) }
        s.append(String(format: "«ээ», «ну», «как бы» — %.0f на 100 слов", fillers))
        s.append("\(words) слов")
        return s.joined(separator: "; ")
    }

    static func == (a: AnswerStats, b: AnswerStats) -> Bool { a.latency == b.latency && a.words == b.words && a.fillers == b.fillers && a.pace == b.pace }
    func hash(into h: inout Hasher) { h.combine(words); h.combine(fillers) }
}

struct Competency: Codable, Identifiable, Hashable {
    var id: String { name }
    var name: String
    var requirement: String
    /// 0 — не проявлено, 5 — сильно выше ожиданий
    var score: Int
    var evidence: String
    /// high | medium | low — насколько уверенно можно судить по разговору
    var confidence: String
}

struct InterviewReport: Codable, Hashable {
    /// Соответствие требованиям вакансии, 0–100
    var fit: Int
    /// strong_yes | yes | maybe | no
    var verdict: String
    var summary: String
    var portrait: String
    var competencies: [Competency]
    var strengths: [String]
    var risks: [String]
    var mismatches: [String]
    var nextSteps: [String]
    var deep = false
    var createdAt = Date()
    /// Бизнес-логика: как человек рассуждает внутри задачи. У оценок до 0.5.4 этого блока нет
    var business: BusinessThinking?
    /// Самостоятельность ответов: признаки, что кандидат подсматривал в нейросеть или поиск
    var integrity: Integrity?
}

struct Integrity: Codable, Hashable {
    /// none | low | medium | high
    var level: String
    var signs: [String]

    var title: String {
        switch level {
        case "high": return "Похоже, отвечал с подсказками ИИ"
        case "medium": return "Есть признаки подсказок ИИ"
        case "low": return "Отдельные ответы звучат как зачитанные"
        default: return "Отвечал сам"
        }
    }
}

/// Как кандидат думает в рамках бизнес-задачи: «спроектируйте агента-шоппера — как будете делать?»
struct BusinessThinking: Codable, Hashable {
    /// 0 — не проявлено, 5 — выдающееся
    var score: Int
    var summary: String
    /// Как рассуждал, по шагам: с чего начал, как разложил задачу
    var approach: [String]
    /// Что упустил: пользователь, метрики, риски, стоимость, крайние случаи
    var gaps: [String]
    var confidence: String
}

struct Interview: Codable, Hashable {
    var meetingID: Int64
    var candidate = ""
    var vacancy = ""
    var resume = ""
    /// Акценты интервьюера: на что смотреть особенно
    var notes = ""
    var plan: InterviewPlan?
    var probes: [Probe] = []
    var report: InterviewReport?
    /// Откуда взяты вакансия и резюме в базе собеседований; nil — вставлены вручную
    var vacancyID: Int64?
    var resumeID: Int64?
}

enum Verdict {
    static func title(_ v: String) -> String {
        switch v {
        case "strong": return "Сильный ответ"
        case "ok": return "Ответ по делу"
        case "vague": return "Размыто"
        case "evasive": return "Уходит от ответа"
        case "contradiction": return "Противоречие"
        case "red_flag": return "Тревожный сигнал"
        default: return v
        }
    }

    static func hire(_ v: String) -> String {
        switch v {
        case "strong_yes": return "Однозначно брать"
        case "yes": return "Скорее подходит"
        case "maybe": return "Под вопросом"
        case "no": return "Не подходит"
        default: return v
        }
    }

    static func kind(_ k: String) -> String {
        switch k {
        case "must": return "Обязательные"
        case "person": return "Про человека"
        case "tricky": return "С подковыркой"
        case "case": return "Кейсы на бизнес-логику"
        default: return k
        }
    }
}

// MARK: Логика

extension AppState {
    /// Встречи или собеседования — смотря какой режим включён
    var modeMeetings: [Meeting] { meetings.filter { $0.isInterview == interviewMode } }

    func loadInterview(_ id: Int64) {
        guard meetings.first(where: { $0.id == id })?.isInterview == true else { interview = nil; return }
        interview = meetingStore.interview(meetingID: id) ?? Interview(meetingID: id)
        probedUntil = turns.last?.id ?? 0
        probedLen = turns.last?.text.count ?? 0
        interviewTab = turns.isEmpty ? 0 : (interview?.report != nil ? 2 : 0)
    }

    /// Новое собеседование: сначала подготовка, запись — потом, кнопкой.
    func newInterview() {
        guard !isRecording else { return }
        let df = DateFormatter()
        df.locale = Locale(identifier: "ru_RU")
        df.dateFormat = "d MMMM, HH:mm"
        let m = meetingStore.createMeeting(title: "Собеседование " + df.string(from: Date()), kind: "interview")
        meetings.insert(m, at: 0)
        showKB = false
        select(m.id)
        warmDeep()
    }

    /// Правка полей подготовки: сохраняем с задержкой, чтобы не писать в базу на каждую букву.
    func editInterview(_ change: (inout Interview) -> Void) {
        guard var iv = interview else { return }
        change(&iv)
        interview = iv
        interviewSaveTask?.cancel()
        interviewSaveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { self.meetingStore.saveInterview(iv) }
        }
    }

    private func saveInterviewNow() {
        interviewSaveTask?.cancel()
        if let iv = interview { meetingStore.saveInterview(iv) }
    }

    func setCandidate(_ name: String) {
        editInterview { $0.candidate = name }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let i = meetings.firstIndex(where: { $0.id == interview?.meetingID }), meetings[i].title.hasPrefix("Собеседование") {
            meetings[i].title = n.isEmpty ? meetings[i].title : "Собеседование: " + n
            meetingStore.update(meetings[i])
        }
    }

    /// Текст вакансии или резюме из файла: PDF, Word, текст.
    func loadInterviewFile(resume: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = resume ? "Выберите резюме кандидата" : "Выберите описание вакансии"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = Self.extractText(url)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            errorText = "Не удалось прочитать текст из «\(url.lastPathComponent)»."
            return
        }
        editInterview { if resume { $0.resume = text } else { $0.vacancy = text } }
    }

    func togglePlanQuestion(_ qid: String) {
        editInterview { iv in
            guard let i = iv.plan?.questions.firstIndex(where: { $0.id == qid }) else { return }
            iv.plan!.questions[i].asked.toggle()
            if iv.plan!.questions[i].asked { iv.plan!.questions[i].skipped = false }
        }
    }

    func skipPlanQuestion(_ qid: String) {
        editInterview { iv in
            guard let i = iv.plan?.questions.firstIndex(where: { $0.id == qid }) else { return }
            iv.plan!.questions[i].skipped = true
        }
    }

    /// Порядок видов вопросов в карте и в подсказке «следующий вопрос».
    nonisolated static let planKinds = ["must", "case", "person", "tricky"]

    /// Следующий вопрос, который стоит задать: сначала обязательные, затем кейсы, про человека, с подковыркой.
    var nextPlanQuestion: PlanQuestion? {
        let qs = interview?.plan?.questions.filter { !$0.asked && !$0.skipped } ?? []
        for k in Self.planKinds { if let q = qs.first(where: { $0.kind == k }) { return q } }
        return nil
    }

    func markProbe(_ pid: String, used: Bool) {
        editInterview { iv in
            guard let i = iv.probes.firstIndex(where: { $0.id == pid }) else { return }
            if used { iv.probes[i].used = true } else { iv.probes[i].dismissed = true }
        }
    }

    /// Кандидат — любой голос, кроме владельца: звук звонка или другой человек у того же микрофона (очное собеседование).
    nonisolated static func isCandidate(_ t: Turn) -> Bool { t.speaker == .them || voiceKey(t) != 0 }

    /// Доля речи кандидата: если интервьюер говорит больше кандидата — что-то идёт не так.
    var talkShare: Double? {
        var me = 0, them = 0
        for t in turns { if Self.isCandidate(t) { them += t.text.count } else { me += t.text.count } }
        return me + them > 200 ? Double(them) / Double(me + them) : nil
    }

    /// Владение темой по последним ответам: свежие весят больше. nil — разборов с оценкой ещё нет.
    var mastery: Double? {
        let xs = (interview?.probes ?? []).compactMap(\.mastery).suffix(5)
        guard !xs.isEmpty else { return nil }
        var sum = 0.0, w = 0.0
        for (i, x) in xs.enumerated() { let k = Double(i + 1); sum += Double(x) * k; w += k }
        return sum / w
    }

    // MARK: Глубокая модель

    /// Глубокой модели нужно ~15 ГБ памяти поверх основной; на маленьких Mac работаем на основной.
    var deepFits: Bool { ProcessInfo.processInfo.physicalMemory >= 30_000_000_000 }

    /// Поднимаем глубокую модель заранее, пока человек вставляет вакансию: загрузка занимает десятки секунд.
    func warmDeep() {
        guard deepFits, deepModelReady, deepClient == nil, deepStarting == nil else { return }
        Task { _ = await deepLLM() }
    }

    /// Клиент глубокой модели; если её нет или она не влезает — основная модель. Второе значение — глубокая ли.
    func deepLLM() async -> (LLMClient, Bool)? {
        if let deepClient { return (deepClient, true) }
        if deepFits, deepModelReady, let model = Paths.model(Paths.deepModel) {
            if deepStarting == nil {
                deepStarting = Task { @MainActor in
                    deepStatus = "Загружаю Gemma 4 26B…"
                    var extra = ["-c", "32768", "-np", "1", "--reasoning-budget", "0", "--jinja"]
                    if let draft = Paths.model(Paths.deepDraftModel) { extra += ["--spec-draft-model", draft.path, "--spec-type", "draft-mtp"] }
                    let p = LlamaProcess(name: "deep", model: model, port: freePort(), extra: extra)
                    deepServer = p
                    do {
                        try await p.start()
                        let c = LLMClient(chatURL: p.baseURL, embedURL: p.baseURL)
                        deepClient = c
                        deepStatus = "Gemma 4 26B"
                        return c
                    } catch {
                        log("deep: \(error.localizedDescription)")
                        p.stop()
                        deepServer = nil
                        deepStatus = "Глубокая модель не запустилась — работаю на основной"
                        return nil
                    }
                }
            }
            let c = await deepStarting?.value
            if c == nil { deepStarting = nil }
            if let c { return (c, true) }
        }
        guard let c = chatClient, llmReady else { return nil }
        return (c, false)
    }

    /// Вышли из режима собеседований — глубокую модель выгружаем, память нужнее другим.
    func stopDeep() {
        deepServer?.stop()
        deepServer = nil
        deepClient = nil
        deepStarting = nil
        deepStatus = ""
    }

    func modeChanged() {
        // Палитра зависит от режима — перерисовываем всё окно
        objectWillChange.send()
        if interviewMode { warmDeep() } else { stopDeep() }
        if let s = selected, s.isInterview != interviewMode { select(modeMeetings.first?.id) }
    }

    private func jsonObject(_ raw: String) -> [String: Any]? {
        guard let d = raw.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    private func decode<T: Decodable>(_ raw: String, _ type: T.Type) -> T? {
        guard let d = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: d)
    }

    // MARK: Подготовка: карта вопросов

    static let prepPrompt = """
    Ты — опытный интервьюер и HR-партнёр. Готовишь карту вопросов к собеседованию по описанию вакансии и резюме кандидата.
    Важно: резюме и требования вакансии часто не совпадают — это нормально. Не делай на расхождениях акцент, не строй вопросов в духе «почему у вас нет X». Задача — на практике проверить, справится ли человек с тем, что требует вакансия, опираясь на его реальный опыт.
    Собери:
    - requirements — 5–10 ключевых требований вакансии, каждое в 2–6 словах;
    - brief — кто перед нами по резюме: 3–4 коротких предложения (опыт, уровень, сильные стороны), без оценок;
    - focus — 3–6 пунктов, что стоит проверить особенно: громкие заявленные достижения, неясности, места, где нужен личный вклад и цифры;
    - questions — вопросы четырёх видов:
      • must — 8–12 обязательных: по каждому ключевому требованию хотя бы один, через реальный опыт («расскажите, как вы…», «какой был последний случай, когда…»);
      • person — 5–7 вопросов, чтобы понять, что за человек: мотивация, ценности, отношение к ошибкам, конфликтам, ответственности, обратной связи. Они должны звучать как обычные рабочие вопросы — истинную цель кандидат не должен угадать; её пиши в purpose;
      • case — 1–2 кейса на бизнес-логику: живая задача из области вакансии, которую кандидат решает вслух («Спроектируйте агента-шоппера для маркетплейса: как будете его делать?», «Продажи в регионе упали на 20% — с чего начнёте?»). Кейс открытый, без единственного правильного ответа: проверяем, как человек думает, — уточняет ли цель и пользователя, раскладывает ли задачу на части, думает ли о метриках успеха, рисках, крайних случаях, стоимости и компромиссах, предлагает ли простой первый шаг. В listen перечисли, что отличает сильное решение;
      • tricky — 4–6 с подковыркой: проверка глубины и честности — «а что бы вы сделали иначе», просьба посчитать или разобрать кейс-ловушку, личный вклад в заявленное достижение, вопрос, где правильный ответ — «не знаю» или «зависит от». Без унижения и подвохов ради подвохов.
    Для каждого вопроса: text — сам вопрос, как его произнести, по-русски, естественно; purpose — что на самом деле проверяем; listen — что хотим услышать в сильном ответе и какие тревожные сигналы; requirement — к какому требованию относится (или пустая строка).
    """

    static let prepSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "requirements": ["type": "array", "items": ["type": "string"]],
            "brief": ["type": "string"],
            "focus": ["type": "array", "items": ["type": "string"]],
            "questions": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "kind": ["type": "string", "enum": ["must", "case", "person", "tricky"]],
                    "text": ["type": "string"], "purpose": ["type": "string"], "listen": ["type": "string"], "requirement": ["type": "string"],
                ],
                "required": ["kind", "text", "purpose", "listen", "requirement"], "additionalProperties": false,
            ]],
        ],
        "required": ["requirements", "brief", "focus", "questions"], "additionalProperties": false,
    ]

    func buildPlan() {
        guard let iv = interview, !preparing else { return }
        let vacancy = iv.vacancy.trimmingCharacters(in: .whitespacesAndNewlines)
        let resume = iv.resume.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !vacancy.isEmpty || !resume.isEmpty else { errorText = "Добавьте описание вакансии или резюме — по ним собирается карта вопросов."; return }
        saveInterviewToLibrary()
        preparing = true
        prepNote = "Готовлю модель…"
        let mid = iv.meetingID
        Task {
            defer { preparing = false; prepNote = "" }
            guard let (llm, deep) = await deepLLM() else { errorText = "Языковая модель ещё загружается."; return }
            var user = "Вакансия:\n" + (vacancy.isEmpty ? "(не указана — опирайся на резюме)" : String(vacancy.prefix(14000)))
            user += "\n\nРезюме кандидата:\n" + (resume.isEmpty ? "(нет — составь вопросы по вакансии)" : String(resume.prefix(14000)))
            if !iv.notes.trimmingCharacters(in: .whitespaces).isEmpty { user += "\n\nАкценты интервьюера:\n" + iv.notes }
            prepNote = deep ? "Gemma 26B собирает карту вопросов…" : "Собираю карту вопросов…"
            var acc = ""
            do {
                for try await piece in llm.chatStream([.init(role: "system", content: Self.prepPrompt), .init(role: "user", content: user)], schema: Self.prepSchema, maxTokens: 6000, temperature: 0.4) {
                    acc += piece
                    let n = acc.components(separatedBy: "\"kind\"").count - 1
                    if n > 0 { prepNote = "Вопросов готово: \(n)…" }
                }
            } catch {
                errorText = "Не удалось собрать карту: " + error.localizedDescription
                return
            }
            guard var plan = decode(acc, InterviewPlanRaw.self)?.plan else { errorText = "Модель вернула неполную карту — попробуйте ещё раз."; return }
            plan.deep = deep
            guard interview?.meetingID == mid else {
                // Пока собирали, человек ушёл на другую встречу — сохраняем прямо в базу
                if var other = meetingStore.interview(meetingID: mid) { other.plan = plan; meetingStore.saveInterview(other) }
                return
            }
            editInterview { $0.plan = plan }
            saveInterviewNow()
        }
    }

    // MARK: Во время собеседования: доуточнения

    nonisolated static let fillerWords: Set<String> = ["э", "ээ", "эээ", "эм", "эмм", "ммм", "мм", "ну", "типа", "короче", "вот", "значит", "блин"]

    /// Как кандидат отвечал: пауза после вопроса, темп и слова-паразиты. Только для живой записи — паузы мы видим, пока пишем.
    func answerStats(question: [Turn], answer: [Turn]) -> AnswerStats {
        let text = answer.map(\.text).joined(separator: " ").lowercased()
        let words = text.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var fill = Double(words.filter { Self.fillerWords.contains($0) }.count)
        // «как бы» — два слова, считаем отдельно
        fill += Double(text.components(separatedBy: "как бы").count - 1)
        let speech = answer.compactMap { turnSpeech[$0.id] }.reduce(0, +)
        var latency: Double?
        if let qEnd = question.last?.ts, let first = answer.first, let start = turnStarts[first.id] {
            latency = max(0, start.timeIntervalSince(qEnd))
        }
        return AnswerStats(latency: latency, words: words.count, fillers: words.isEmpty ? 0 : fill * 100 / Double(words.count),
                           pace: speech > 2 ? Double(words.count) / speech : nil)
    }

    /// Похоже, что кандидат подсматривает в нейросеть: по оценкам модели и по поведению (долгая пауза → гладкий ответ без «ээ»).
    var aiSuspicion: (score: Double, reasons: [String])? {
        let ps = (interview?.probes ?? []).filter { $0.ai != nil }.suffix(4)
        guard ps.count >= 2 else { return nil }
        var score = Double(ps.compactMap(\.ai).reduce(0, +)) / Double(ps.count)
        let smooth = ps.filter { p in p.stats.map { $0.fillers < 1 && $0.words >= 50 && ($0.latency ?? 0) >= 6 } ?? false }.count
        score += Double(smooth) / Double(ps.count)
        var reasons = ps.filter { ($0.ai ?? 0) >= 2 }.compactMap { $0.aiWhy }.filter { !$0.isEmpty }
        if smooth > 0 { reasons.insert("долгая пауза перед гладким ответом без «ээ» — \(smooth) из \(ps.count)", at: 0) }
        return (min(3, score), Array(NSOrderedSet(array: reasons).array as? [String] ?? reasons).prefix(4).map { $0 })
    }

    /// Сколько тишины ждать после фразы кандидата, прежде чем показать разбор. Живой человек делает паузы
    /// посреди мысли: если фраза оборвалась на «и…», «потому что…», «ну», запятой — ждём дольше; закончил мысль — показываем быстро.
    nonisolated static func pauseNeeded(_ text: String) -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if t.hasSuffix(",") || t.hasSuffix("…") || t.hasSuffix("...") || t.hasSuffix("-") || t.hasSuffix("—") { return 2.4 }
        let last = t.split { !$0.isLetter }.last.map(String.init) ?? ""
        let hanging: Set<String> = ["и", "а", "но", "или", "что", "чтобы", "потому", "поэтому", "который", "которая", "которые", "которое", "если", "когда", "как", "это", "то", "ну", "вот", "типа", "значит", "в", "на", "с", "по", "для", "из", "к", "у", "о", "от", "при", "мы", "я", "он", "там", "тоже", "также"]
        let fillers: Set<String> = ["э", "ээ", "эээ", "эм", "эмм", "ммм", "мм", "м", "ам", "хм"]
        if hanging.contains(last) || fillers.contains(last) { return 2.4 }
        if t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") { return 0.6 }
        return 1.0
    }

    /// Разбор начинаем сразу, как только фраза кандидата распознана, — модель думает, пока мы ждём паузу.
    /// Заговорил снова — разбор отменяется и начинается заново по всему ответу.
    func considerProbe() {
        guard llmReady, let llm = chatClient, let iv = interview, let last = turns.last, Self.isCandidate(last) else { return }
        let (question, answer) = Self.lastExchange(turns)
        guard let qTurn = question.first, !answer.isEmpty else { return }
        let answerText = answer.map(\.text).joined(separator: " ")
        guard answerText.count >= 60 else { return }
        let questionText = question.map(\.text).joined(separator: " ")
        let stats = answerStats(question: question, answer: answer)
        let user = Self.probeRequest(iv, questionText: questionText, answerText: answerText, questionTurnID: qTurn.id) + "\nКак отвечал: " + stats.line
        let pause = Self.pauseNeeded(last.text)
        let mid = iv.meetingID

        probeTask?.cancel()
        probeTask = Task {
            probing = true
            let box = ProbeStream()
            let gen = Task { @MainActor in
                do {
                    for try await piece in llm.chatStream([.init(role: "system", content: Self.probePrompt), .init(role: "user", content: user)], maxTokens: 260, temperature: 0.2) {
                        box.acc += piece
                    }
                } catch {}
                box.done = true
            }
            defer { gen.cancel() }
            // Фраза уже закрыта паузой Whisper — её тоже засчитываем
            var quiet = 0.4
            var shown = false
            var drafted = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                quiet = speechPipeline?.anyoneSpeaking == true ? 0 : quiet + 0.1
                guard interview?.meetingID == mid else { break }
                // Знакомство, прощание, «слышно?» — это не ответ, разбирать и оценивать нечего
                if Self.isSmallTalk(box.acc) { dropProbe(questionTurnID: qTurn.id); break }
                let ready = box.done || Self.probeReady(box.acc)
                guard ready else { continue }
                // Модель считает, что кандидат оборвался на полуслове, — даём ему договорить
                let unfinished = Self.probeField(box.acc, "ЗАКОНЧИЛ")?.lowercased().hasPrefix("нет") == true
                let need = unfinished ? max(pause, 3.0) : pause
                if quiet < need && !shown {
                    // Уточнение уже готово — показываем черновиком, чтобы интервьюер видел его заранее
                    if !drafted { commitProbe(box.acc, questionTurnID: qTurn.id, question: questionText, stats: stats, draft: true, notify: false); drafted = true }
                    continue
                }
                commitProbe(box.acc, questionTurnID: qTurn.id, question: questionText, stats: stats, draft: false, notify: !shown)
                shown = true
                if box.done { break }
            }
            if !Task.isCancelled { probing = false }
        }
    }

    static let probePrompt = """
    Ты подсказываешь интервьюеру на собеседовании. Расшифровка автоматическая, в ней бывают ошибки распознавания — не цепляйся к словам.
    Тебе дают требования вакансии, кратко о кандидате, карту вопросов с id, уже разобранные ответы, а также последний вопрос интервьюера и ответ кандидата.
    Ответь строками, без разметки и пояснений, в таком порядке:
    ТИП: ответ — кандидат отвечает по существу; светское — знакомство, приветствие, прощание, благодарность, «слышно ли меня», организационные моменты, рассказ интервьюера о компании или вопросы кандидата об условиях. Если светское — больше ничего не пиши.
    ОЦЕНКА: strong — конкретно, с примерами, цифрами и личным вкладом; ok — по делу, хватает; vague — общие слова, «мы делали», нет примера или своей роли; evasive — уходит от вопроса; contradiction — расходится с резюме или с тем, что он говорил раньше; red_flag — тревожный сигнал (перекладывает вину, неэтично, токсично о прошлой команде). Напиши одно слово.
    ЗАКОНЧИЛ: да — мысль завершена; нет — ответ оборвался на полуслове и кандидат явно собирается продолжить.
    ИИ: похоже ли, что кандидат зачитывает ответ нейросети или поиска, число 0–3 и через тире почему, 2–6 слов. 0 — живая речь: паузы, самоисправления, личные детали; 1 — гладко, но есть живое; 2 — книжные обороты, структура «во-первых… во-вторых», общие формулировки без своего опыта; 3 — явно читает текст: определения как из учебника, перечисления, ни одной личной детали. Учитывай строку «Как отвечал»: долгая пауза перед гладким ответом без «ээ» — тревожный знак. Живая речь не бывает идеальной.
    УТОЧНЕНИЕ: сам вопрос — ровно те слова, которые интервьюер произнесёт вслух кандидату, без пояснений для интервьюера. Если оценка vague, evasive, contradiction или red_flag — один уточняющий вопрос, который стоит задать прямо сейчас: короткий, естественный, без обвинений («А что именно делали лично вы?», «Сколько это было в цифрах?», «Вы говорили, что…, а сейчас…, как это сочетается?»). Если ИИ 2–3 — уточнение обязательно, даже при strong или ok: спроси про личный случай с деталями, которые нельзя подсмотреть («Когда это было у вас? Что пошло не так?»). Иначе, если strong или ok, — поставь -. Не дозадавай ради дозадавания.
    В ТЕМЕ: насколько кандидат владеет темой, число 0–5. 5 — свободно: объясняет, почему так, называет компромиссы и детали; 4 — уверенно; 3 — знает основы, но поверхностно; 2 — плавает: путается, перечисляет термины без объяснения, отвечает не на тот вопрос, много «ну… эм…», заученные фразы; 1 — почти не понимает; 0 — не знает. Оценивай понимание, а не красноречие.
    СУТЬ: суть ответа одним коротким предложением.
    ПОЧЕМУ: почему такая оценка, 3–8 слов, для интервьюера.
    ЗАКРЫТО: id вопросов из карты, на которые этот обмен по сути ответил, через запятую; если нет — -
    Будь строгим, как опытный нанимающий менеджер:
    - перечисление названий, терминов и этапов без объяснения, как это работает и почему так, — это vague, В ТЕМЕ не выше 2;
    - «мы сделали», «внедрили», «использовали» без своей роли, примера или цифры — vague;
    - strong и В ТЕМЕ 4–5 — только когда кандидат объясняет механику, компромиссы, ошибки или результат в цифрах;
    - ответ оборвался посередине — оценивай то, что уже сказано, а в ЗАКОНЧИЛ ставь нет.
    Каждая строка начинается со своего ключа, например «ОЦЕНКА: vague».
    """

    nonisolated static let probeKeys = ["ТИП", "ОЦЕНКА", "ЗАКОНЧИЛ", "ИИ", "УТОЧНЕНИЕ", "В ТЕМЕ", "СУТЬ", "ПОЧЕМУ", "ЗАКРЫТО"]

    /// Модель сочла обмен светской беседой: знакомство, прощание, организационное.
    nonisolated static func isSmallTalk(_ acc: String) -> Bool {
        probeField(acc, "ТИП")?.lowercased().hasPrefix("светск") == true
    }

    /// Значение строки ответа; строка должна быть уже дописана. Маленькая модель иногда пропускает «КЛЮЧ:»
    /// и пишет одни значения — тогда берём строку по порядку.
    nonisolated static func probeField(_ acc: String, _ key: String) -> String? {
        guard let n = probeKeys.firstIndex(of: key) else { return nil }
        var lines = acc.components(separatedBy: "\n")
        lines.removeLast() // последняя строка ещё дописывается
        lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("```") }
        if let keyed = lines.first(where: { $0.uppercased().hasPrefix(key + ":") }) {
            return String(keyed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        // Без ключей — по порядку; строки с чужим ключом в счёт не идут
        guard n < lines.count else { return nil }
        let line = lines[n]
        if let other = probeKeys.first(where: { line.uppercased().hasPrefix($0 + ":") }), other != key { return nil }
        return line
    }

    /// Уточнение уже можно показывать: дописаны ТИП, ОЦЕНКА, ЗАКОНЧИЛ, ИИ и УТОЧНЕНИЕ.
    nonisolated static func probeReady(_ acc: String) -> Bool {
        acc.components(separatedBy: "\n").dropLast().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 5
    }

    /// Последний обмен: подряд идущие реплики интервьюера и всё, что кандидат сказал после.
    nonisolated static func lastExchange(_ turns: [Turn]) -> (question: [Turn], answer: [Turn]) {
        var answer: [Turn] = []
        var question: [Turn] = []
        for t in turns.reversed() {
            if isCandidate(t) { if question.isEmpty { answer.insert(t, at: 0) } else { break } } else { question.insert(t, at: 0) }
            if question.count >= 3 { break }
        }
        return (question, answer)
    }

    /// Кладёт разбор в собеседование. Вызывается, как только готово уточнение, и ещё раз — когда модель допишет остальное.
    /// Обмен оказался светской беседой — прежний разбор того же обмена (по первым фразам) убираем.
    private func dropProbe(questionTurnID: Int64) {
        guard interview?.probes.contains(where: { $0.questionTurnID == questionTurnID }) == true else { return }
        editInterview { $0.probes.removeAll { $0.questionTurnID == questionTurnID } }
    }

    private func commitProbe(_ raw: String, questionTurnID: Int64, question: String, stats: AnswerStats?, draft: Bool, notify: Bool) {
        let acc = raw.hasSuffix("\n") ? raw : raw + "\n"
        let verdictWord = (Self.probeField(acc, "ОЦЕНКА") ?? "ok").lowercased().split { !$0.isLetter && $0 != "_" }.first.map(String.init) ?? "ok"
        let verdict = ["strong", "ok", "vague", "evasive", "contradiction", "red_flag"].contains(verdictWord) ? verdictWord : "ok"
        var follow = (Self.probeField(acc, "УТОЧНЕНИЕ") ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " -—«»\""))
        // Маленькая модель иногда начинает с пометки «ИИ 2 —» — отрезаем её
        if let r = follow.range(of: #"^(ИИ|AI)\s*\d\s*[-—:]\s*"#, options: .regularExpression) { follow.removeSubrange(r) }
        let aiScore = Self.probeField(acc, "ИИ")?.first(where: \.isNumber)?.wholeNumberValue ?? 0
        // Хороший ответ не дозадаём — кроме случая, когда он похож на зачитанный из нейросети
        if (["strong", "ok"].contains(verdict) && aiScore < 2) || follow.count < 8 { follow = "" }
        var p = Probe(questionTurnID: questionTurnID, question: question, gist: Self.probeField(acc, "СУТЬ") ?? "", verdict: verdict, followup: follow, reason: Self.probeField(acc, "ПОЧЕМУ") ?? "")
        p.mastery = (Self.probeField(acc, "В ТЕМЕ")?.first(where: \.isNumber)?.wholeNumberValue).map { max(0, min(5, $0)) }
        if let ai = Self.probeField(acc, "ИИ") {
            p.ai = ai.first(where: \.isNumber)?.wholeNumberValue.map { max(0, min(3, $0)) }
            let why = ai.drop { $0.isNumber || $0 == " " || $0 == "—" || $0 == "-" || $0 == ":" }
            p.aiWhy = why.trimmingCharacters(in: .whitespaces)
        }
        p.stats = stats
        p.draft = draft
        let covered = Set((Self.probeField(acc, "ЗАКРЫТО") ?? "").components(separatedBy: CharacterSet(charactersIn: ", []")).map { String($0.prefix(8)).lowercased() }.filter { $0.count >= 4 })
        var isNewFollowup = false
        editInterview { iv in
            // Кандидат продолжил тот же ответ — заменяем прежний разбор, а не плодим карточки
            if let i = iv.probes.lastIndex(where: { $0.questionTurnID == questionTurnID }) {
                var np = p
                np.id = iv.probes[i].id
                np.ts = iv.probes[i].ts
                np.used = iv.probes[i].used && np.followup == iv.probes[i].followup
                np.dismissed = iv.probes[i].dismissed && np.followup == iv.probes[i].followup
                // Черновик стал окончательным — это тоже «новое» уточнение для уведомления
                isNewFollowup = !np.followup.isEmpty && (np.followup != iv.probes[i].followup || iv.probes[i].draft == true)
                // Новые подробности не должны терять то, что модель уже сказала в прошлый раз
                if np.gist.isEmpty { np.gist = iv.probes[i].gist }
                if np.reason.isEmpty { np.reason = iv.probes[i].reason }
                if np.mastery == nil { np.mastery = iv.probes[i].mastery }
                if np.ai == nil { np.ai = iv.probes[i].ai; np.aiWhy = iv.probes[i].aiWhy }
                iv.probes[i] = np
            } else {
                iv.probes.append(p)
                isNewFollowup = !p.followup.isEmpty
            }
            for i in (iv.plan?.questions.indices ?? 0..<0) where covered.contains(String(iv.plan!.questions[i].id.prefix(8)).lowercased()) {
                iv.plan!.questions[i].asked = true
            }
        }
        if notify, !draft, isNewFollowup, compact || NSApp.isActive == false {
            Notifier.shared.notify(title: "Дозадайте вопрос", body: follow)
        }
    }

    /// Запрос к модели. Неизменная часть (требования, кандидат, вся карта) идёт первой — её llama-server держит в кэше,
    /// и каждый разбор пересчитывает только хвост с ответом.
    nonisolated static func probeRequest(_ iv: Interview, questionText: String, answerText: String, questionTurnID: Int64) -> String {
        var user = ""
        if let plan = iv.plan {
            if !plan.requirements.isEmpty { user += "Требования вакансии: " + plan.requirements.joined(separator: "; ") + "\n" }
            if !plan.brief.isEmpty { user += "Кандидат по резюме: " + plan.brief + "\n" }
            if !plan.questions.isEmpty { user += "\nКарта вопросов:\n" + plan.questions.prefix(30).map { "[\($0.id.prefix(8))] \($0.text)" }.joined(separator: "\n") + "\n" }
        } else if !iv.vacancy.isEmpty {
            user += "Вакансия: " + String(iv.vacancy.prefix(1500)) + "\n"
        }
        let earlier = iv.probes.filter { $0.questionTurnID != questionTurnID }.suffix(6)
        if !earlier.isEmpty { user += "\nРанее кандидат говорил:\n" + earlier.map { "— \($0.gist)" }.joined(separator: "\n") + "\n" }
        user += "\nВопрос интервьюера: " + String(questionText.suffix(700)) + "\nОтвет кандидата: " + String(answerText.suffix(2500))
        return user
    }

    // MARK: После собеседования: оценка и матрица компетенций

    static let evalPrompt = """
    Ты — опытный нанимающий менеджер. По расшифровке собеседования оцени кандидата относительно требований вакансии. «Я» и голоса на стороне интервьюера — те, кто проводит собеседование; «Собеседник» — кандидат. Расшифровка автоматическая, с ошибками распознавания.
    Правила честной оценки:
    - Оценивай только по тому, что прозвучало. Нет доказательств — ставь низкую уверенность, а не низкий балл «на всякий случай».
    - Расхождения резюме и вакансии — не минус сами по себе; важно, что человек показал на собеседовании.
    - Не оценивай пол, возраст, внешность, акцент и прочее, не относящееся к работе.
    - Знакомство, приветствие, прощание, благодарности, «слышно ли меня», рассказ интервьюера о компании и вопросы кандидата об условиях — не ответы. Не ставь по ним баллы и не делай выводов: обычное прощание — это не минус.
    Верни:
    - competencies — 6–10 компетенций: по ключевым требованиям вакансии плюс 1–3 личностные (ответственность, коммуникация, обучаемость — что реально проявилось). name — 2–4 слова; requirement — к какому требованию относится; score 0–5 (0 — не проявлено, 1 — слабо, 2 — ниже ожиданий, 3 — соответствует, 4 — сильно, 5 — выдающееся); evidence — короткая опора из разговора, лучше близко к цитате; confidence — high, medium или low;
    - fit — соответствие требованиям вакансии в процентах, 0–100;
    - verdict — strong_yes, yes, maybe или no;
    - summary — 2–3 предложения итога для нанимающего менеджера;
    - portrait — психологический и рабочий портрет: как человек думает, как говорит о прошлых командах и ошибках, что его мотивирует, в какой среде раскроется и где будет трудно. 4–6 предложений, бережно и по делу;
    - strengths — 2–5 сильных сторон; risks — 2–5 рисков и тревожных сигналов;
    - mismatches — где сказанное расходится с резюме или само с собой (если нет — пусто), без драматизации;
    - nextSteps — 2–4 пункта: что проверить на следующем этапе или у рекомендателей;
    - integrity — самостоятельность ответов: признаки, что кандидат пользовался подсказками нейросети или поиска во время собеседования — долгие паузы перед гладкими книжными ответами без «ээ», ответы как из учебника без личного опыта, резкий контраст между отточенными ответами и тем, как он справляется с уточнениями. level — none, low, medium или high; signs — 0–4 коротких наблюдения. Не обвиняй — только наблюдения; живая неидеальная речь — это нормально;
    - business — бизнес-логика: как кандидат думает в рамках задачи — по кейсам («спроектируйте…», «как бы вы сделали…») и любым ответам, где он рассуждал о решении. Смотри: понял ли цель бизнеса и пользователя, задал ли уточняющие вопросы, разложил ли задачу на части, подумал ли о метриках успеха, рисках, крайних случаях, стоимости и компромиссах, предложил ли простой первый шаг. score 0–5; summary — 2–3 предложения; approach — 2–5 шагов, как он рассуждал; gaps — 1–4 пункта, что упустил; confidence — high, medium или low (low, если кейсов почти не было).
    Пиши на русском — все поля, включая названия компетенций и требований (не «Go & Highload», а «Go и высокие нагрузки»).
    """

    static let evalSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "competencies": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "name": ["type": "string"], "requirement": ["type": "string"], "score": ["type": "integer"],
                    "evidence": ["type": "string"], "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                ],
                "required": ["name", "requirement", "score", "evidence", "confidence"], "additionalProperties": false,
            ]],
            "fit": ["type": "integer"],
            "verdict": ["type": "string", "enum": ["strong_yes", "yes", "maybe", "no"]],
            "summary": ["type": "string"], "portrait": ["type": "string"],
            "strengths": ["type": "array", "items": ["type": "string"]],
            "risks": ["type": "array", "items": ["type": "string"]],
            "mismatches": ["type": "array", "items": ["type": "string"]],
            "nextSteps": ["type": "array", "items": ["type": "string"]],
            "integrity": [
                "type": "object",
                "properties": ["level": ["type": "string", "enum": ["none", "low", "medium", "high"]], "signs": ["type": "array", "items": ["type": "string"]]],
                "required": ["level", "signs"], "additionalProperties": false,
            ],
            "business": [
                "type": "object",
                "properties": [
                    "score": ["type": "integer"], "summary": ["type": "string"],
                    "approach": ["type": "array", "items": ["type": "string"]],
                    "gaps": ["type": "array", "items": ["type": "string"]],
                    "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                ],
                "required": ["score", "summary", "approach", "gaps", "confidence"], "additionalProperties": false,
            ],
        ],
        "required": ["competencies", "fit", "verdict", "summary", "portrait", "strengths", "risks", "mismatches", "nextSteps", "integrity", "business"], "additionalProperties": false,
    ]

    func evaluateInterview(_ id: Int64) async {
        guard !evaluating else { return }
        let all = meetingStore.turns(meetingID: id)
        guard all.count >= 4 else { return }
        let iv = (interview?.meetingID == id ? interview : nil) ?? meetingStore.interview(meetingID: id) ?? Interview(meetingID: id)
        evaluating = true
        evalNote = "Готовлю модель…"
        defer { evaluating = false; evalNote = "" }
        guard let (llm, deep) = await deepLLM() else { return }
        let names = meetingStore.voiceNames(meetingID: id)
        var text = all.map { "\(Self.label($0, names)): \($0.text)" }.joined(separator: "\n")
        // Глубокая модель держит ~32 тыс. токенов; совсем длинное собеседование сжимаем по частям основной моделью
        let budget = deep ? 50000 : 18000
        if text.count > budget, let small = chatClient {
            evalNote = "Собеседование длинное — сжимаю расшифровку…"
            var digests: [String] = []
            for part in Self.chunk(text, size: 9000) {
                let d = (try? await small.chat([
                    .init(role: "system", content: "Сожми фрагмент расшифровки собеседования: вопросы интервьюера и суть ответов кандидата, с конкретикой, цифрами и показательными цитатами. На русском."),
                    .init(role: "user", content: part),
                ], maxTokens: 700)) ?? ""
                digests.append(d)
            }
            text = digests.joined(separator: "\n\n")
        }
        var user = ""
        if let plan = iv.plan {
            if !plan.requirements.isEmpty { user += "Требования вакансии:\n" + plan.requirements.map { "- " + $0 }.joined(separator: "\n") + "\n\n" }
            if !plan.brief.isEmpty { user += "Кандидат по резюме: " + plan.brief + "\n\n" }
        } else if !iv.vacancy.isEmpty {
            user += "Вакансия:\n" + String(iv.vacancy.prefix(6000)) + "\n\n"
        }
        if !iv.resume.isEmpty, iv.plan == nil { user += "Резюме:\n" + String(iv.resume.prefix(6000)) + "\n\n" }
        let flagged = iv.probes.filter { !["ok", "strong"].contains($0.verdict) }
        // Как отвечал по ходу: паузы и похожесть на зачитанный текст — для блока самостоятельности
        let behaviour = iv.probes.compactMap { p -> String? in
            guard p.ai != nil || p.stats != nil else { return nil }
            var s = "- " + String(p.gist.prefix(90))
            if let st = p.stats { s += " (" + st.line + ")" }
            if let a = p.ai { s += "; похоже на зачитанное: \(a)/3" + ((p.aiWhy ?? "").isEmpty ? "" : " — " + p.aiWhy!) }
            return s
        }
        if !behaviour.isEmpty { user += "Как кандидат отвечал по ходу:\n" + behaviour.joined(separator: "\n") + "\n\n" }
        let ms = iv.probes.compactMap(\.mastery)
        if !ms.isEmpty { user += "Владение темой по ответам (0–5): " + ms.map(String.init).joined(separator: ", ") + "\n\n" }
        if !flagged.isEmpty { user += "Отметки по ходу собеседования:\n" + flagged.map { "- \(Verdict.title($0.verdict)): \($0.gist)" }.joined(separator: "\n") + "\n\n" }
        if let m = meetings.first(where: { $0.id == id }), !m.notes.isEmpty { user += "Заметки интервьюера:\n" + m.notes + "\n\n" }
        user += "Расшифровка собеседования:\n" + text
        evalNote = deep ? "Gemma 26B оценивает кандидата…" : "Оцениваю кандидата…"
        var acc = ""
        do {
            for try await piece in llm.chatStream([.init(role: "system", content: Self.evalPrompt), .init(role: "user", content: user)], schema: Self.evalSchema, maxTokens: 4000, temperature: 0.2) {
                acc += piece
                let n = acc.components(separatedBy: "\"evidence\"").count - 1
                if n > 0 { evalNote = "Компетенций оценено: \(n)…" }
            }
        } catch {
            errorText = "Не удалось оценить кандидата: " + error.localizedDescription
            return
        }
        guard var report = decode(acc, InterviewReportRaw.self)?.report else { errorText = "Модель вернула неполную оценку — нажмите «Пересобрать»."; return }
        report.deep = deep
        if interview?.meetingID == id {
            editInterview { $0.report = report }
            // Резюме вставляли вручную и карту не собирали — кандидат всё равно попадает в базу
            if interview?.resumeID == nil { saveInterviewToLibrary() }
            saveInterviewNow()
        } else {
            var other = iv
            other.report = report
            meetingStore.saveInterview(other)
        }
        refreshResumeInterviews()
    }

    /// Чат по собеседованию знает вакансию, карту и оценку.
    func interviewContext() -> String {
        guard let iv = interview, iv.meetingID == selectedID else { return "" }
        var s = "\n\nЭто собеседование. «Я» — интервьюер, «Собеседник» — кандидат" + (iv.candidate.isEmpty ? "" : " (\(iv.candidate))") + ".\n"
        if let p = iv.plan {
            if !p.requirements.isEmpty { s += "Требования вакансии: " + p.requirements.joined(separator: "; ") + "\n" }
            if !p.brief.isEmpty { s += "Кандидат по резюме: " + p.brief + "\n" }
        } else if !iv.vacancy.isEmpty { s += "Вакансия: " + String(iv.vacancy.prefix(2000)) + "\n" }
        if let r = iv.report {
            s += "Оценка: соответствие \(r.fit)%, \(Verdict.hire(r.verdict)). \(r.summary)\nКомпетенции: " + r.competencies.map { "\($0.name) \($0.score)/5" }.joined(separator: ", ") + "\n"
        }
        return s
    }

    // MARK: Отчёт: копирование и Word

    func reportPlainText() -> String {
        guard let iv = interview, let r = iv.report else { return "" }
        var s = (selected?.title ?? "Собеседование") + "\n\n"
        s += "Соответствие вакансии: \(r.fit)% — \(Verdict.hire(r.verdict))\n\n\(r.summary)\n\nМатрица компетенций:\n"
        for c in r.competencies { s += "• \(c.name): \(c.score)/5 — \(c.evidence)\n" }
        s += "\nПортрет:\n\(r.portrait)\n"
        func list(_ t: String, _ xs: [String]) { if !xs.isEmpty { s += "\n\(t):\n" + xs.map { "• " + $0 }.joined(separator: "\n") + "\n" } }
        list("Сильные стороны", r.strengths)
        list("Риски", r.risks)
        list("Расхождения", r.mismatches)
        list("Что проверить дальше", r.nextSteps)
        if let ig = r.integrity, ig.level != "none" {
            s += "\nСамостоятельность ответов: \(ig.title)\n"
            list("Наблюдения", ig.signs)
        }
        if let b = r.business {
            s += "\nБизнес-логика: \(b.score)/5\n\(b.summary)\n"
            list("Как рассуждал", b.approach)
            list("Что упустил", b.gaps)
        }
        return s
    }

    func copyReport() {
        let t = reportPlainText()
        guard !t.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
        copiedNote = "Скопировано"
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copiedNote = "" }
    }

    func exportReportToWord() {
        guard let m = selected, interview?.report != nil else { return }
        // Тот же оформитель, что у итога встречи: заголовки «**…**» и пункты «- …»
        var md = m
        var body = reportPlainText().components(separatedBy: "\n").dropFirst(2).map { line -> String in
            if line.hasPrefix("• ") { return "- " + line.dropFirst(2) }
            if line.hasSuffix(":"), !line.contains("—") { return "**" + line.dropLast() + "**" }
            return line
        }.joined(separator: "\n")
        if !m.summary.isEmpty { body += "\n\n**Итог разговора**\n" + m.summary }
        md.summary = body
        let panel = NSSavePanel()
        panel.nameFieldStringValue = m.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: " ") + ".docx"
        panel.message = "Куда сохранить оценку кандидата"
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "docx" { url.appendPathExtension("docx") }
        let out = Self.summaryDocument(md)
        do {
            let data = try out.data(from: NSRange(location: 0, length: out.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorText = "Не удалось сохранить файл Word: " + error.localizedDescription
        }
    }
}

// Ответы модели в том виде, как их требует схема; дальше переводим в свои структуры
struct InterviewPlanRaw: Decodable {
    struct Q: Decodable { var kind, text, purpose, listen, requirement: String }
    var requirements: [String]
    var brief: String
    var focus: [String]
    var questions: [Q]

    var plan: InterviewPlan? {
        let qs = questions.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !qs.isEmpty else { return nil }
        return InterviewPlan(requirements: requirements, brief: brief, focus: focus,
                             questions: qs.map { PlanQuestion(kind: $0.kind, text: $0.text, purpose: $0.purpose, listen: $0.listen, requirement: $0.requirement) })
    }
}

struct InterviewReportRaw: Decodable {
    struct C: Decodable { var name, requirement: String; var score: Int; var evidence, confidence: String }
    var competencies: [C]
    var fit: Int
    var verdict, summary, portrait: String
    var strengths, risks, mismatches, nextSteps: [String]
    var business: BusinessThinking?
    var integrity: Integrity?

    var report: InterviewReport? {
        guard !competencies.isEmpty else { return nil }
        var b = business
        if let score = b?.score { b?.score = max(0, min(5, score)) }
        return InterviewReport(fit: max(0, min(100, fit)), verdict: verdict, summary: summary, portrait: portrait,
                               competencies: competencies.map { Competency(name: $0.name, requirement: $0.requirement, score: max(0, min(5, $0.score)), evidence: $0.evidence, confidence: $0.confidence) },
                               strengths: strengths, risks: risks, mismatches: mismatches, nextSteps: nextSteps, business: b, integrity: integrity)
    }
}

/// Копит потоковый ответ модели, пока разбор ждёт паузу.
@MainActor final class ProbeStream {
    var acc = ""
    var done = false
}
