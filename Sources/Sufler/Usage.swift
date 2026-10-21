import AppKit
import Foundation
import SQLite3

// MARK: Статистика использования, согласие на отправку, отзывы

/// Куда отправлять общую статистику и отзывы. Пока адрес пустой, приложение ничего никуда не отправляет:
/// статистика копится только на этом Mac, отзывы ждут в очереди.
enum Telemetry {
    static let endpoint = "https://minijir.space/sufler"
    static var enabled: Bool { !endpoint.isEmpty }
}

/// Сводка для экрана «Статистика».
struct UsageSummary {
    var meetings = 0
    var recordedHours = 0.0
    var words = 0
    var questions = 0
    var questionsForMe = 0
    var facts = 0
    var documents = 0
    var chunks = 0
    var databaseMB = 0.0
    var audioMB = 0.0
    var llmRequests = 0
    var llmIn = 0
    var llmOut = 0
    var chatQuestions = 0
    /// Последние 30 дней: минуты записи и слова по дням
    var days: [(day: Date, minutes: Double, words: Int)] = []
}

extension Store {
    /// Счётчики по дням: сколько слов, токенов, вопросов и т. п. Хранятся только здесь, в базе на этом Mac.
    func bump(_ key: String, by value: Double, day: String) {
        exec("CREATE TABLE IF NOT EXISTS usage(day TEXT, key TEXT, value REAL, PRIMARY KEY(day, key));")
        rawRun("INSERT INTO usage(day, key, value) VALUES(?,?,?) ON CONFLICT(day, key) DO UPDATE SET value = value + excluded.value", [day, key, value])
    }

    func usage(since day: String) -> [String: [String: Double]] {
        exec("CREATE TABLE IF NOT EXISTS usage(day TEXT, key TEXT, value REAL, PRIMARY KEY(day, key));")
        var out: [String: [String: Double]] = [:]
        rawRun("SELECT day, key, value FROM usage WHERE day >= ?", [day]) { st in
            let d = String(cString: sqlite3_column_text(st, 0)), k = String(cString: sqlite3_column_text(st, 1))
            out[d, default: [:]][k] = sqlite3_column_double(st, 2)
        }
        return out
    }

    func scalar(_ sql: String) -> Double {
        var v = 0.0
        rawRun(sql, []) { st in v = sqlite3_column_double(st, 0) }
        return v
    }
}

extension AppState {
    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Плюс к счётчику за сегодня.
    func count(_ key: String, _ value: Double = 1) {
        meetingStore.bump(key, by: value, day: Self.dayFormat.string(from: Date()))
    }

    func usageSummary() -> UsageSummary {
        let s = meetingStore
        var u = UsageSummary()
        u.meetings = Int(s.scalar("SELECT COUNT(*) FROM meetings"))
        u.recordedHours = s.scalar("SELECT COALESCE(SUM(ended_at - started_at), 0) FROM meetings WHERE ended_at IS NOT NULL") / 3600
        // Слова считаем по пробелам: для статистики этого достаточно
        u.words = Int(s.scalar("SELECT COALESCE(SUM(LENGTH(text) - LENGTH(REPLACE(text, ' ', '')) + 1), 0) FROM turns WHERE LENGTH(text) > 0"))
        u.questions = Int(s.scalar("SELECT COUNT(*) FROM questions"))
        u.questionsForMe = Int(s.scalar("SELECT COUNT(*) FROM questions WHERE for_me = 1"))
        u.facts = Int(s.scalar("SELECT COUNT(*) FROM facts"))
        u.documents = Int(s.scalar("SELECT COUNT(*) FROM documents"))
        u.chunks = Int(s.scalar("SELECT COUNT(*) FROM chunks"))
        let db = Paths.supportDir.appendingPathComponent("sufler.sqlite")
        u.databaseMB = Double(Paths.fileSize(db) + Paths.fileSize(db.appendingPathExtension("wal"))) / 1e6
        let audio = (try? FileManager.default.contentsOfDirectory(at: MeetingAudio.dir, includingPropertiesForKeys: nil)) ?? []
        u.audioMB = Double(audio.map { Paths.fileSize($0) }.reduce(0, +)) / 1e6

        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -29, to: cal.startOfDay(for: Date()))!
        let counters = s.usage(since: "0000")
        for (_, kv) in counters {
            u.llmRequests += Int(kv["llm_requests"] ?? 0)
            u.llmIn += Int(kv["llm_in"] ?? 0)
            u.llmOut += Int(kv["llm_out"] ?? 0)
            u.chatQuestions += Int(kv["chat_questions"] ?? 0)
        }
        // Активность по дням берём из самих встреч — так видна и история до появления счётчиков
        var minutes: [String: Double] = [:], words: [String: Int] = [:]
        for m in meetings where m.startedAt >= start {
            let d = Self.dayFormat.string(from: m.startedAt)
            minutes[d, default: 0] += max(0, (m.endedAt ?? m.startedAt).timeIntervalSince(m.startedAt)) / 60
        }
        s.rawRun("SELECT ts, LENGTH(text) - LENGTH(REPLACE(text, ' ', '')) + 1 FROM turns WHERE ts >= ?", [start.timeIntervalSince1970]) { st in
            let d = Self.dayFormat.string(from: Date(timeIntervalSince1970: sqlite3_column_double(st, 0)))
            words[d, default: 0] += Int(sqlite3_column_int64(st, 1))
        }
        for i in 0..<30 {
            let day = cal.date(byAdding: .day, value: i, to: start)!
            let key = Self.dayFormat.string(from: day)
            u.days.append((day, minutes[key] ?? 0, words[key] ?? 0))
        }
        return u
    }

    // MARK: Общая статистика (только с согласия)

    /// Постоянный случайный номер установки: по нему считаются люди, но он ни с чем не связан.
    var installID: String {
        if let id = UserDefaults.standard.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "installID")
        return id
    }

    /// Счётчики по дням, посчитанные прямо по встречам в базе: так уходит и история до появления счётчиков,
    /// и ничего не считается дважды.
    private func derivedDays(after last: String) -> [String: [String: Double]] {
        var out: [String: [String: Double]] = [:]
        let s = meetingStore
        func add(_ sql: String, _ key: String) {
            s.rawRun(sql, [last]) { st in
                let d = String(cString: sqlite3_column_text(st, 0))
                out[d, default: [:]][key] = sqlite3_column_double(st, 1)
            }
        }
        add("SELECT date(started_at, 'unixepoch', 'localtime') d, COUNT(*) FROM meetings GROUP BY d HAVING d > ?", "meetings")
        add("SELECT date(started_at, 'unixepoch', 'localtime') d, SUM(COALESCE(ended_at, started_at) - started_at) / 60.0 FROM meetings GROUP BY d HAVING d > ?", "recorded_minutes")
        add("SELECT date(ts, 'unixepoch', 'localtime') d, SUM(LENGTH(text) - LENGTH(REPLACE(text, ' ', '')) + 1) FROM turns GROUP BY d HAVING d > ?", "words")
        add("SELECT date(ts, 'unixepoch', 'localtime') d, COUNT(*) FROM questions GROUP BY d HAVING d > ?", "questions")
        add("SELECT date(ts, 'unixepoch', 'localtime') d, SUM(for_me) FROM questions GROUP BY d HAVING d > ?", "questions_me")
        return out
    }

    /// Ровно то, что уйдёт на сервер. Показывается пользователю по кнопке «Что отправляется».
    func telemetryPayload() -> [String: Any] {
        let last = UserDefaults.standard.string(forKey: "telemetrySentDay") ?? "0000"
        let today = Self.dayFormat.string(from: Date())
        var days = meetingStore.usage(since: last).filter { $0.key > last }
        // Встречи, слова и вопросы берём из самих встреч, остальное (токены, вопросы в чат) — из счётчиков
        for (day, kv) in derivedDays(after: last) {
            for (k, v) in kv { days[day, default: [:]][k] = v }
        }
        // Отметка «сегодня приложение открывали» — по ней видно, сколько людей пользуется
        days[today, default: [:]]["active"] = 1
        let mem = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        return [
            "install": installID,
            "app": "mac",
            "version": currentVersion,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "memory_gb": Int(mem.rounded()),
            "mode": appMode,
            "days": days.keys.sorted().map { day in ["day": day, "counters": days[day] ?? [:]] as [String: Any] },
        ]
    }

    /// Раз в день, если человек согласился: счётчики за прошедшие дни и за сегодня. Без согласия эта функция ничего не делает.
    func sendTelemetryIfAllowed() async {
        guard telemetryConsent == "yes", Telemetry.enabled, let url = URL(string: Telemetry.endpoint + "/v1/usage") else { return }
        let payload = telemetryPayload()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
            // Сегодняшний день ещё не закончился — в следующий раз отправим его снова, сервер просто обновит цифры
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
            UserDefaults.standard.set(Self.dayFormat.string(from: yesterday), forKey: "telemetrySentDay")
        }
    }

    /// Пока приложение открыто — отправляем раз в несколько часов, чтобы день не терялся, если Mac не перезапускают.
    func startTelemetryLoop() {
        Task {
            while true {
                await sendTelemetryIfAllowed()
                await flushOutbox()
                try? await Task.sleep(nanoseconds: 4 * 3600 * 1_000_000_000)
            }
        }
    }

    func setTelemetry(_ allowed: Bool) {
        telemetryConsent = allowed ? "yes" : "no"
        showConsent = false
        // Отказ — и ничего не уходит: ни сейчас, ни потом. Накопленное остаётся только на этом Mac
        if allowed { Task { await sendTelemetryIfAllowed() } }
    }

    // MARK: Отзывы

    static var outbox: URL {
        let d = Paths.supportDir.appendingPathComponent("Outbox")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Отзыв кладём в очередь и отправляем, как только есть куда. Тексты встреч сюда не попадают.
    func submitFeedback(kind: String, text: String, contact: String, attachInfo: Bool) {
        var item: [String: Any] = ["kind": kind, "text": text, "contact": contact, "created": ISO8601DateFormatter().string(from: Date()), "app": "mac", "version": currentVersion]
        if attachInfo {
            item["os"] = ProcessInfo.processInfo.operatingSystemVersionString
            item["memory_gb"] = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1e9).rounded())
            item["models"] = "\(asrStatus); \(llmStatus)"
            item["mode"] = appMode
        }
        let url = Self.outbox.appendingPathComponent(UUID().uuidString + ".json")
        if let d = try? JSONSerialization.data(withJSONObject: item, options: [.prettyPrinted]) { try? d.write(to: url) }
        Task { await flushOutbox() }
    }

    func flushOutbox() async {
        guard Telemetry.enabled, let endpoint = URL(string: Telemetry.endpoint + "/v1/feedback") else { return }
        for f in (try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "json" {
            guard let body = try? Data(contentsOf: f) else { continue }
            var req = URLRequest(url: endpoint)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    var pendingFeedback: Int {
        ((try? FileManager.default.contentsOfDirectory(at: Self.outbox, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }.count
    }
}
