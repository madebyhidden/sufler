import AVFoundation
import AppKit
import CryptoKit
import Foundation

/// Проверка без интерфейса: `Sufler --selftest file.wav` прогоняет файл через нарезку и Whisper.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        // Проверка экспорта: `Sufler --docx-test <файл.docx>` сохраняет итог последней встречи с итогом
        if let i = args.firstIndex(of: "--docx-test"), i + 1 < args.count {
            guard let m = Store().meetings().first(where: { !$0.summary.isEmpty }) else { print("нет встреч с итогом"); exit(1) }
            let doc = AppState.summaryDocument(m)
            guard let data = try? doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]),
                  (try? data.write(to: URL(fileURLWithPath: args[i + 1]))) != nil else { print("ошибка экспорта"); exit(1) }
            print("ok: \(m.title), \(data.count) байт")
            exit(0)
        }
        // Подпись архива обновления: `Sufler --sign <файл> <файл с закрытым ключом>` печатает подпись в base64
        if let i = args.firstIndex(of: "--sign"), i + 2 < args.count {
            guard let data = FileManager.default.contents(atPath: args[i + 1]),
                  let keyText = try? String(contentsOfFile: args[i + 2], encoding: .utf8),
                  let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData),
                  let sig = try? key.signature(for: data) else { print("ошибка подписи"); exit(1) }
            print(sig.base64EncodedString())
            exit(0)
        }
        // Проверка сохранения звука: `Sufler --audio-test a.wav b.wav` пишет фразы в архив и читает его обратно
        if let i = args.firstIndex(of: "--audio-test"), i + 1 < args.count {
            let id: Int64 = -777
            MeetingAudio.delete(id)
            guard let w = MeetingAudio(meetingID: id) else { print("архив не создался"); exit(1) }
            var total = 0.0
            for path in args[(i + 1)...] {
                guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
                      let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buf)) != nil else { print("не читается \(path)"); continue }
                let samples = Resampler().convert(buf)
                let r = w.append(samples)
                total += Double(samples.count) / 16000
                print("фраза \(Double(samples.count) / 16000) с → в архиве \(r?.0 ?? -1)…\(r?.1 ?? -1)")
            }
            w.close()
            let url = MeetingAudio.url(id)
            let p = try? AVAudioPlayer(contentsOf: url)
            print("архив: \(Paths.fileSize(url)) байт, длительность \(p?.duration ?? -1) с при записанных \(total) с")
            if let p { p.currentTime = max(0, total - 2); print("перемотка к концу: \(p.currentTime) с, играет: \(p.play())"); p.stop() }
            MeetingAudio.delete(id)
            exit(0)
        }
        // Промпты собеседования на живой модели: `Sufler --interview-test <model.gguf> <папка>`
        // В папке: vacancy.txt, resume.txt, transcript.txt; строки «Я: …» / «Собеседник: …»; пустая строка разделяет обмены для разбора
        if let i = args.firstIndex(of: "--interview-test"), i + 2 < args.count {
            let model = URL(fileURLWithPath: args[i + 1]), dir = URL(fileURLWithPath: args[i + 2])
            Task.detached { await interviewTest(model: model, dir: dir); exit(0) }
            RunLoop.main.run()
        }
        // Задержка разбора на сохранённом собеседовании: `Sufler --probe-latency <id встречи> <model.gguf>`
        if let i = args.firstIndex(of: "--probe-latency"), i + 2 < args.count, let id = Int64(args[i + 1]) {
            let model = URL(fileURLWithPath: args[i + 2])
            Task.detached { await probeLatency(id, model: model); exit(0) }
            RunLoop.main.run()
        }
        // Кто сейчас пользуется микрофоном: `Sufler --watch-mic 10` следит заданное число секунд
        if let i = args.firstIndex(of: "--watch-mic"), i + 1 < args.count {
            let w = CallWatcher()
            w.onMicStarted = { name, hay in print("микрофон включил: \(name) [\(hay)]") }
            w.start()
            print("слежу \(args[i + 1]) с…")
            RunLoop.main.run(until: Date().addingTimeInterval(Double(args[i + 1]) ?? 10))
            print("конец")
            exit(0)
        }
        if let i = args.firstIndex(of: "--fetch-voice"), i + 1 < args.count {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                do { try await VoiceID.fetch(to: URL(fileURLWithPath: args[i + 1])); print("ok") } catch { print("ошибка: \(error)") }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await run(path: args[i + 1])
            sem.signal()
        }
        sem.wait()
        exit(0)
    }

    private static func run(path: String) async {
        guard let model = Paths.model(Paths.whisperModel), let engine = try? WhisperEngine(modelPath: model.path) else {
            print("нет модели Whisper"); return
        }
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buf)) != nil else { print("не читается файл"); return }
        let samples = Resampler().convert(buf)
        print("аудио: \(Double(samples.count) / 16000) с")
        _ = await engine.transcribe([Float](repeating: 0, count: 16000), language: "ru", fast: true)

        let voice = VoiceID.modelsDir.flatMap { try? VoiceID(dir: $0) }
        print(voice == nil ? "голоса: модели не найдены" : "голоса: готово")
        var ctxText = ""
        let seg = Segmenter()
        var events: [Segmenter.Event] = []
        for start in stride(from: 0, to: samples.count, by: 1600) {
            events += seg.feed(Array(samples[start..<min(start + 1600, samples.count)]))
        }
        if let tail = seg.flush() { events.append(.final(tail)) }
        for e in events {
            let t0 = Date()
            switch e {
            case .partial(let s):
                let text = await engine.transcribe(s, language: "ru", fast: true)
                print(String(format: "  черновик %.1f с за %.2f с: %@", Double(s.count) / 16000, Date().timeIntervalSince(t0), text))
            case .final(let s):
                let parts = voice?.split(s) ?? [0..<s.count]
                if parts.count > 1 { print("  фраза \(String(format: "%.1f", Double(s.count) / 16000)) с разделена на \(parts.count) части по смене голоса") }
                for r in parts {
                    let piece = Array(s[r])
                    let t0 = Date()
                    let text = await engine.transcribe(piece, language: "ru", names: ProcessInfo.processInfo.environment["NAMES"] ?? "", context: ctxText, fast: false)
                    if !text.isEmpty { ctxText = String((ctxText + " " + text).suffix(220)) }
                    let v = voice?.identify(piece) ?? 0
                    print(String(format: "ФРАЗА %.1f с за %.2f с (голос %d): %@", Double(piece.count) / 16000, Date().timeIntervalSince(t0), v, text))
                }
            }
        }
    }
}


private func interviewTest(model: URL, dir: URL) async {
    func read(_ n: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8)) ?? "" }
    let deep = model.lastPathComponent.contains("26B")
    var extra = ["-c", deep ? "32768" : "16384", "-np", "1", "--reasoning-budget", "0", "--jinja"]
    let draft = model.deletingLastPathComponent().appendingPathComponent("mtp-" + model.lastPathComponent)
    if FileManager.default.fileExists(atPath: draft.path) { extra += ["--spec-draft-model", draft.path, "--spec-type", "draft-mtp"] }
    let p = LlamaProcess(name: "itest", model: model, port: freePort(), extra: extra)
    var t0 = Date()
    do { try await p.start() } catch { print("сервер не поднялся: \(error)"); return }
    defer { p.stop() }
    print("загрузка: \(String(format: "%.1f", Date().timeIntervalSince(t0))) с")
    let llm = LLMClient(chatURL: p.baseURL, embedURL: p.baseURL)

    t0 = Date()
    let user = "Вакансия:\n" + read("vacancy.txt") + "\n\nРезюме кандидата:\n" + read("resume.txt")
    var acc = ""
    do {
        for try await piece in llm.chatStream([.init(role: "system", content: AppState.prepPrompt), .init(role: "user", content: user)], schema: AppState.prepSchema, maxTokens: 6000, temperature: 0.4) { acc += piece }
    } catch { print("карта: \(error)") }
    let plan = (acc.data(using: .utf8)).flatMap { try? JSONDecoder().decode(InterviewPlanRaw.self, from: $0) }?.plan
    print("\n=== КАРТА (\(String(format: "%.1f", Date().timeIntervalSince(t0))) с, \(acc.count) знаков) ===")
    if let plan {
        print("Требования: " + plan.requirements.joined(separator: "; "))
        print("Кандидат: " + plan.brief)
        print("Проверить: " + plan.focus.joined(separator: " | "))
        for q in plan.questions { print("[\(q.kind)] \(q.text)\n    цель: \(q.purpose)\n    слушаем: \(q.listen)") }
    } else { print("не разобралась:\n" + acc.prefix(1500)) }

    let transcript = read("transcript.txt")
    for (n, ex) in transcript.components(separatedBy: "\n\n").enumerated() {
        let lines = ex.split(separator: "\n").map(String.init)
        let q = lines.filter { $0.hasPrefix("Я:") }.map { String($0.dropFirst(2)) }.joined(separator: " ")
        let a = lines.filter { $0.hasPrefix("Собеседник:") }.map { String($0.dropFirst(11)) }.joined(separator: " ")
        guard !q.isEmpty, !a.isEmpty else { continue }
        var iv = Interview(meetingID: 0)
        iv.plan = plan
        var u = AppState.probeRequest(iv, questionText: q, answerText: a, questionTurnID: Int64(n))
        // Строка «#…» в обмене — как отвечал кандидат (паузы, темп), её в живом режиме считает приложение
        if let how = lines.first(where: { $0.hasPrefix("#") }) { u += "\nКак отвечал: " + how.dropFirst() }
        print("\n=== РАЗБОР \(n + 1) ===\nВ: \(q.prefix(120))")
        await timedProbe(llm, u)
    }

    t0 = Date()
    var eu = ""
    if let plan { eu += "Требования вакансии:\n" + plan.requirements.map { "- " + $0 }.joined(separator: "\n") + "\n\nКандидат по резюме: " + plan.brief + "\n\n" }
    eu += "Как кандидат отвечал по ходу:\n- идемпотентность в Kafka (пауза перед ответом 9 с; «ээ» — 0 на 100 слов; 52 слова); похоже на зачитанное: 2/3 — книжная структура\n- как делали в ЛогистикПро (пауза 1 с; «ээ» — 9 на 100 слов); похоже на зачитанное: 1/3\n\n"
    eu += "Расшифровка собеседования:\n" + transcript.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
    acc = ""
    do {
        for try await piece in llm.chatStream([.init(role: "system", content: AppState.evalPrompt), .init(role: "user", content: eu)], schema: AppState.evalSchema, maxTokens: 4000, temperature: 0.2) { acc += piece }
    } catch { print("оценка: \(error)") }
    print("\n=== ОЦЕНКА (\(String(format: "%.1f", Date().timeIntervalSince(t0))) с) ===")
    if let r = (acc.data(using: .utf8)).flatMap({ try? JSONDecoder().decode(InterviewReportRaw.self, from: $0) })?.report {
        print("Соответствие \(r.fit)% — \(r.verdict)\n\(r.summary)")
        for c in r.competencies { print("  \(c.name) [\(c.requirement)]: \(c.score)/5 (\(c.confidence)) — \(c.evidence)") }
        if let ig = r.integrity { print("САМОСТОЯТЕЛЬНОСТЬ: \(ig.level) — \(ig.signs)") }
        if let b = r.business { print("БИЗНЕС-ЛОГИКА \(b.score)/5 (\(b.confidence)): \(b.summary)\n  шаги: \(b.approach)\n  упустил: \(b.gaps)") }
        print("Портрет: \(r.portrait)\n+ \(r.strengths)\n! \(r.risks)\n≠ \(r.mismatches)\n→ \(r.nextSteps)")
    } else { print("не разобралась:\n" + acc.prefix(1500)) }
}



/// Разбор потоком, как в приложении: сколько прошло до готового уточнения и до конца ответа.
private func timedProbe(_ llm: LLMClient, _ user: String) async {
    let t0 = Date()
    var acc = ""
    var firstAt: Double?
    do {
        for try await piece in llm.chatStream([.init(role: "system", content: AppState.probePrompt), .init(role: "user", content: user)], maxTokens: 260, temperature: 0.2) {
            acc += piece
            if firstAt == nil, AppState.probeReady(acc) { firstAt = Date().timeIntervalSince(t0) }
        }
    } catch { print("ошибка: \(error)") }
    print(String(format: "уточнение готово через %.2f с, весь ответ — %.2f с", firstAt ?? -1, Date().timeIntervalSince(t0)))
    let a = acc + "\n"
    print(AppState.probeKeys.map { "\($0): \(AppState.probeField(a, $0) ?? "—")" }.joined(separator: " | "))
}

private func probeLatency(_ id: Int64, model: URL) async {
    let store = Store()
    let turns = store.turns(meetingID: id)
    let iv = store.interview(meetingID: id) ?? Interview(meetingID: id)
    var extra = ["-c", "16384", "-np", "2", "--reasoning-budget", "0", "--jinja"]
    let draft = model.deletingLastPathComponent().appendingPathComponent("mtp-" + model.lastPathComponent)
    if FileManager.default.fileExists(atPath: draft.path) { extra += ["--spec-draft-model", draft.path, "--spec-type", "draft-mtp"] }
    let p = LlamaProcess(name: "itest", model: model, port: freePort(), extra: extra)
    do { try await p.start() } catch { print("сервер: \(error)"); return }
    defer { p.stop() }
    let llm = LLMClient(chatURL: p.baseURL, embedURL: p.baseURL)
    print("реплик: \(turns.count), карта: \(iv.plan?.questions.count ?? 0) вопросов")
    // Как в живом режиме: разбор после каждой фразы кандидата
    for k in turns.indices where AppState.isCandidate(turns[k]) {
        let (q, a) = AppState.lastExchange(Array(turns[...k]))
        guard let qt = q.first else { continue }
        let at = a.map(\.text).joined(separator: " ")
        guard at.count >= 60 else { continue }
        print("\n=== после фразы «\(turns[k].text.suffix(50))» — пауза \(AppState.pauseNeeded(turns[k].text)) с")
        await timedProbe(llm, AppState.probeRequest(iv, questionText: q.map(\.text).joined(separator: " "), answerText: at, questionTurnID: qt.id))
    }
}
