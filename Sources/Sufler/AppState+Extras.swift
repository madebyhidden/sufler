import AVFoundation
import AppKit
import Foundation

extension AppState {
    // MARK: Переслушать реплику

    func hasAudio(_ t: Turn) -> Bool {
        t.audioEnd > t.audioStart && t.meetingID == selectedID && selectedHasAudio
    }

    /// Есть ли у открытой встречи сохранённый звук. Проверяем один раз, а не для каждой реплики при каждой перерисовке.
    func refreshHasAudio() {
        let has = selectedID.map { $0 != recordingID && FileManager.default.fileExists(atPath: MeetingAudio.url($0).path) } ?? false
        if has != selectedHasAudio { selectedHasAudio = has }
    }

    /// Проиграть звук реплики; повторное нажатие останавливает.
    func play(_ t: Turn) {
        if playingTurnID == t.id { stopPlayback(); return }
        stopPlayback()
        // Во время записи не играем: микрофон услышит колонки, и это попадёт в расшифровку
        guard !isRecording else { errorText = "Переслушать можно после остановки записи."; return }
        guard hasAudio(t), let p = try? AVAudioPlayer(contentsOf: MeetingAudio.url(t.meetingID)) else { return }
        let start = max(0, t.audioStart - 0.15)
        p.currentTime = start
        guard p.play() else { return }
        player = p
        playingTurnID = t.id
        let length = t.audioEnd - start + 0.2
        playStop = Task {
            try? await Task.sleep(nanoseconds: UInt64(length * 1_000_000_000))
            if !Task.isCancelled { stopPlayback() }
        }
    }

    func stopPlayback() {
        playStop?.cancel()
        playStop = nil
        player?.stop()
        player = nil
        playingTurnID = nil
    }

    // MARK: Вопрос голосом

    /// Диктовка вопроса в чат: говорите — после паузы вопрос отправится сам. Повторное нажатие отменяет.
    func toggleDictation() {
        if dictating { cancelDictation(); return }
        guard asrReady, let engine = speechEngine else { errorText = "Распознавание речи ещё загружается."; return }
        Task {
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                errorText = "Нет доступа к микрофону. Разрешите его в Системных настройках → Конфиденциальность → Микрофон."
                return
            }
            dictationToken += 1
            let token = dictationToken
            dictationBase = chatInput.isEmpty ? "" : chatInput.trimmingCharacters(in: .whitespaces) + " "
            // Для вопроса пауза длиннее, чем в разговоре: человек подбирает слова
            let seg = Segmenter(endSilence: 16000 * 11 / 10)
            let queue = DispatchQueue(label: "sufler.dictation")
            let lang = language
            let names = [myName, glossary].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: ", ")
            var closed = false
            micRouter.setDictation { [weak self] samples in
                queue.async {
                    guard !closed else { return }
                    for e in seg.feed(samples) {
                        switch e {
                        case .partial(let s):
                            Task {
                                let text = await engine.transcribe(s, language: lang, fast: true)
                                await MainActor.run { [weak self] in
                                    guard let self, self.dictating, self.dictationToken == token, !text.isEmpty else { return }
                                    self.chatInput = self.dictationBase + text
                                }
                            }
                        case .final(let s):
                            closed = true
                            Task {
                                let text = await engine.transcribe(s, language: lang, names: names, fast: false)
                                await MainActor.run { [weak self] in self?.finishDictation(text, token: token) }
                            }
                        }
                    }
                }
            }
            // Вне записи (или при выключенном микрофоне) микрофон включаем сами и выключим после вопроса
            dictationOwnsMic = !isRecording || micMuted
            if dictationOwnsMic {
                do { try micDevice.start() } catch {
                    micRouter.setDictation(nil)
                    errorText = "Микрофон: " + error.localizedDescription
                    return
                }
            }
            dictating = true
            // Если так ничего и не сказали — не держим микрофон включённым
            try? await Task.sleep(nanoseconds: 12_000_000_000)
            if dictating, dictationToken == token, chatInput == dictationBase || chatInput.isEmpty { cancelDictation() }
        }
    }

    private func releaseDictationMic() {
        micRouter.setDictation(nil)
        if dictationOwnsMic { micDevice.stop() }
        dictationOwnsMic = false
        dictating = false
    }

    func cancelDictation() {
        dictationToken += 1
        releaseDictationMic()
    }

    private func finishDictation(_ text: String, token: Int) {
        guard dictating, dictationToken == token else { return }
        releaseDictationMic()
        let q = (dictationBase + text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !q.isEmpty else { return }
        chatInput = ""
        ask(q)
    }

    // MARK: Проверка названий

    func decodeChecks(_ raw: String) -> [NameCheck] {
        guard let d = raw.data(using: .utf8), let list = try? JSONDecoder().decode([NameCheck].self, from: d) else { return [] }
        return list
    }

    private func saveChecks(_ id: Int64, _ list: [NameCheck]) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[i].checks = list.isEmpty ? "" : (String(data: (try? JSONEncoder().encode(list)) ?? Data(), encoding: .utf8) ?? "")
        meetingStore.update(meetings[i])
        if selectedID == id { nameChecks = list }
    }

    private var knownNames: [String] {
        (glossary.components(separatedBy: CharacterSet(charactersIn: ",\n")) + Corrections.parse(corrections).map { $0.1 })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// После встречи: просим модель показать названия и имена, которые, похоже, распознаны неверно.
    /// Пользователь подтверждает или исправляет — исправления уходят в словарь и применяются впредь.
    func checkNames(_ id: Int64) async {
        guard let llm = chatClient, llmReady else { return }
        let all = meetingStore.turns(meetingID: id)
        guard all.count >= 2 else { return }
        if selectedID == id { checkingNames = true }
        defer { checkingNames = false }
        var text = all.map { $0.text }.joined(separator: "\n")
        if text.count > 9000 { text = String(text.suffix(9000)) }
        let known = knownNames
        var system = """
        Расшифровка встречи сделана автоматически. Распознавание часто искажает имена, фамилии, названия компаний, продуктов, проектов и редкие профессиональные термины.
        Найди в тексте такие слова, которые выглядят искажёнными или бессмысленными либо одно и то же название записано по-разному.
        Для каждого верни:
        heard — слово или название точно так, как оно записано в расшифровке;
        guess — как оно, вероятно, пишется правильно; если не знаешь — пустая строка;
        quote — короткая цитата из расшифровки с этим словом, до 12 слов.
        Не включай обычные слова, разговорные словечки, числа и то, что написано правильно. Не больше 8 пунктов. Если ничего подозрительного нет — верни пустой список.
        """
        if !known.isEmpty { system += "\nЭти названия уже проверены, их не включай: " + known.joined(separator: ", ") }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["items": ["type": "array", "items": [
                "type": "object",
                "properties": ["heard": ["type": "string"], "guess": ["type": "string"], "quote": ["type": "string"]],
                "required": ["heard", "guess", "quote"], "additionalProperties": false,
            ]]],
            "required": ["items"], "additionalProperties": false,
        ]
        guard let raw = try? await llm.chat([.init(role: "system", content: system), .init(role: "user", content: text)], schema: schema, maxTokens: 700, temperature: 0.1),
              let d = raw.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let items = o["items"] as? [[String: Any]] else { return }
        var list: [NameCheck] = []
        for it in items.prefix(8) {
            let heard = ((it["heard"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \n\"«».,"))
            var guess = ((it["guess"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \n\"«»."))
            // Берём только то, что действительно есть в тексте, и не длиннее названия из трёх слов
            guard heard.count >= 3, heard.split(separator: " ").count <= 3,
                  let turn = all.first(where: { Corrections.contains($0.text, heard) }) else { continue }
            if known.contains(where: { $0.caseInsensitiveCompare(heard) == .orderedSame }) || list.contains(where: { $0.heard.caseInsensitiveCompare(heard) == .orderedSame }) { continue }
            if guess.caseInsensitiveCompare(heard) == .orderedSame { guess = "" }
            // Числа и даты модель иногда отмечает зря: без догадки, как правильно, их не показываем
            if guess.isEmpty, heard.contains(where: { $0.isNumber }) { continue }
            list.append(NameCheck(heard: heard, guess: guess, quote: Self.snippet(turn.text, around: heard), turnID: turn.id))
        }
        saveChecks(id, list)
    }

    /// Кусочек реплики вокруг слова — чтобы было понятно, о чём речь.
    private static func snippet(_ text: String, around word: String) -> String {
        guard let r = text.range(of: word, options: .caseInsensitive) else { return String(text.prefix(90)) }
        let from = text.index(r.lowerBound, offsetBy: -45, limitedBy: text.startIndex) ?? text.startIndex
        let to = text.index(r.upperBound, offsetBy: 45, limitedBy: text.endIndex) ?? text.endIndex
        return (from > text.startIndex ? "…" : "") + text[from..<to] + (to < text.endIndex ? "…" : "")
    }

    private func addToGlossary(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        let have = glossary.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespaces) }
        guard !n.isEmpty, !have.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        let g = glossary.trimmingCharacters(in: .whitespacesAndNewlines)
        glossary = g.isEmpty ? n : g + ", " + n
    }

    /// Ответ пользователя по слову: `right` — как правильно. Пусто или то же самое — слово было записано верно.
    func resolveCheck(_ check: NameCheck, right: String) {
        guard let id = selectedID else { return }
        let fixed = right.trimmingCharacters(in: .whitespacesAndNewlines)
        saveChecks(id, nameChecks.filter { $0.id != check.id })
        if fixed.isEmpty || fixed == check.heard {
            addToGlossary(check.heard)
            return
        }
        // В словарь — чтобы в следующих встречах это слово сразу писалось правильно
        let line = "\(check.heard) = \(fixed)"
        let c = corrections.trimmingCharacters(in: .whitespacesAndNewlines)
        corrections = c.isEmpty ? line : c + "\n" + line
        addToGlossary(fixed)

        // И исправляем уже записанное в этой встрече: реплики, вопросы, итог, название, факты
        func fix(_ s: String) -> String { Corrections.replace(s, check.heard, fixed) }
        for i in turns.indices where Corrections.contains(turns[i].text, check.heard) {
            turns[i].text = fix(turns[i].text)
            meetingStore.updateTurn(turns[i])
        }
        for i in questions.indices {
            var q = questions[i]
            q.question = fix(q.question); q.topic = fix(q.topic); q.context = fix(q.context); q.addressee = fix(q.addressee)
            if q != questions[i] { questions[i] = q; meetingStore.update(q) }
        }
        if let i = meetings.firstIndex(where: { $0.id == id }) {
            meetings[i].summary = fix(meetings[i].summary)
            meetings[i].title = fix(meetings[i].title)
            meetingStore.update(meetings[i])
        }
        for i in facts.indices where facts[i].meetingID == id && Corrections.contains(facts[i].text, check.heard) {
            facts[i].text = fix(facts[i].text)
            meetingStore.updateFact(facts[i])
        }
        meetingVecCache = [:]
    }

    func playCheck(_ check: NameCheck) {
        if let t = turns.first(where: { $0.id == check.turnID }) { play(t) }
    }

    // MARK: Начался звонок

    func startCallWatcher() {
        Notifier.shared.onStartRecording = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.callOffer = nil
                if !self.isRecording, self.asrReady { self.toggleRecording() }
            }
        }
        callWatcher.onMicStarted = { [weak self] name, haystack in
            Task { @MainActor in self?.micStarted(by: name, haystack) }
        }
        if watchCalls { callWatcher.start() }
    }

    func watchCallsChanged() {
        if watchCalls { callWatcher.start() } else { callWatcher.stop(); callOffer = nil }
    }

    private func micStarted(by name: String, _ haystack: String) {
        guard watchCalls, !isRecording, recordingID == nil, !showSetup, asrReady else { return }
        let list = watchApps.components(separatedBy: CharacterSet(charactersIn: ",\n")).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        let hay = haystack.lowercased()
        guard list.contains(where: { hay.contains($0) }) else { return }
        // Одно и то же приложение не предлагаем чаще раза в пять минут: микрофон в звонке включают и выключают
        if let last = lastCallOffer[name], Date().timeIntervalSince(last) < 300 { return }
        lastCallOffer[name] = Date()
        callOffer = name
        Notifier.shared.offerRecording(app: name)
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if callOffer == name { callOffer = nil }
        }
    }

    // MARK: Компактный режим

    /// Сворачивает окно в маленькую плашку поверх всех окон (и поверх полноэкранных приложений) и обратно.
    func toggleCompact() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) ?? NSApp.mainWindow else { return }
        if !compact {
            // В компактном окне показываем ту встречу, которая сейчас пишется
            if let id = recordingID { select(id) }
            if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
            frameBeforeCompact = w.frame
            compact = true
            DispatchQueue.main.async {
                w.level = .floating
                w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                w.isMovableByWindowBackground = true
                let screen = (w.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
                let size = NSSize(width: 400, height: 360)
                w.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16, width: size.width, height: size.height), display: true, animate: true)
            }
        } else {
            compact = false
            DispatchQueue.main.async {
                w.level = .normal
                w.collectionBehavior.subtract([.canJoinAllSpaces, .fullScreenAuxiliary])
                w.isMovableByWindowBackground = false
                if let f = self.frameBeforeCompact { w.setFrame(f, display: true, animate: true) }
            }
        }
    }
}
