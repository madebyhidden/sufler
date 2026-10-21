import Foundation

enum Speaker: String, Codable {
    case me = "Я"
    case them = "Собеседник"
}

/// Режет поток 16 кГц на фразы по паузам. Не потокобезопасен — вызывать из одной очереди.
final class Segmenter {
    /// Сколько тишины считать концом фразы, в отсчётах (по умолчанию полсекунды)
    private let endSilence: Int

    init(endSilence: Int = 16000 * 5 / 10) { self.endSilence = endSilence }

    enum Event {
        case partial([Float])
        case final([Float])
    }

    private let frame = 320  // 20 мс
    private var pending: [Float] = []
    private var preroll: [Float] = []
    private var buf: [Float] = []
    private var inSpeech = false
    private var silence = 0
    private var voiced = 0
    private var hot = 0
    private var noise: Float = 0.001
    /// Громкость последних полутора секунд: по её минимуму видно фоновый шум даже посреди речи
    private var recent: [Float] = []
    private var lastPartial = 0

    /// Сейчас идёт фраза (ещё не закрыта паузой)
    var speaking: Bool { inSpeech }

    func feed(_ x: [Float]) -> [Event] {
        var events: [Event] = []
        pending.append(contentsOf: x)
        var i = 0
        while pending.count - i >= frame {
            let f = Array(pending[i..<i + frame])
            i += frame
            var sum: Float = 0
            for v in f { sum += v * v }
            let rms = (sum / Float(frame)).squareRoot()
            recent.append(rms)
            if recent.count > 75 { recent.removeFirst() }
            // Если фон вырос уже во время фразы (включили вентилятор, зашумел собеседник),
            // старая оценка тишины не даст заметить паузу — берём максимум из двух оценок
            let floor = max(noise, (recent.count >= 40 ? (recent.min() ?? 0) : 0) * 1.3)
            let thr = max(0.0025, floor * 3)
            let loud = rms > thr

            if !inSpeech {
                if !loud { noise = 0.97 * noise + 0.03 * rms }
                preroll.append(contentsOf: f)
                if preroll.count > 16000 * 3 / 10 { preroll.removeFirst(preroll.count - 16000 * 3 / 10) }
                hot = loud ? hot + 1 : 0
                if hot >= 3 {
                    inSpeech = true
                    buf = preroll
                    preroll = []
                    silence = 0
                    voiced = hot * frame
                    lastPartial = 0
                    hot = 0
                }
                continue
            }

            buf.append(contentsOf: f)
            if loud { silence = 0; voiced += frame } else { silence += frame }

            let endOfPhrase = silence >= endSilence
            let longAndPaused = buf.count >= 16000 * 12 && silence >= 16000 * 2 / 10
            let tooLong = buf.count >= 16000 * 20
            if endOfPhrase || longAndPaused || tooLong {
                if voiced >= 16000 * 35 / 100 { events.append(.final(buf)) }
                reset()
            } else if buf.count - lastPartial >= 16000 * 13 / 10, silence == 0 {
                lastPartial = buf.count
                events.append(.partial(buf))
            }
        }
        pending.removeFirst(i)
        return events
    }

    /// Вернуть недоговорённый хвост при остановке записи.
    func flush() -> [Float]? {
        defer { reset(); pending = [] }
        return (inSpeech && voiced >= 16000 * 25 / 100) ? buf : nil
    }

    private func reset() {
        buf = []
        inSpeech = false
        silence = 0
        voiced = 0
        hot = 0
        lastPartial = 0
    }
}

/// Связывает источники звука с Whisper: готовые фразы идут по очереди, черновики — только когда движок свободен.
final class TranscriptionPipeline {
    private let whisper: WhisperEngine
    private let queue = DispatchQueue(label: "sufler.pipeline")
    private var segmenters: [Speaker: Segmenter] = [.me: Segmenter(), .them: Segmenter()]
    private var finals: [(Speaker, [Float], Double)] = []
    private var partials: [Speaker: ([Float], Double)] = [:]
    private var busy = false
    /// Хвост уже распознанного разговора — контекст для следующей фразы
    private var context = ""
    /// Громкость звука звонка по кадрам 20 мс за последнюю минуту — чтобы узнавать его эхо в микрофоне
    private var systemEnv: [Float] = []
    private var systemEnvEnd = 0.0
    /// Индикаторы «есть звук»: сообщаем наружу только смену состояния, а не каждый кусок звука —
    /// иначе интерфейс перерисовывается десятки раз в секунду и греет процессор
    private var active: [Speaker: Bool] = [:]
    private var quietSince: [Speaker: Double] = [:]
    private let stateLock = NSLock()
    private var speakingNow: [Speaker: Bool] = [:]

    /// Говорит ли кто-нибудь прямо сейчас (фраза начата и ещё не закончена).
    var anyoneSpeaking: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return speakingNow.values.contains(true)
    }

    var language = "ru"
    var prompt = ""
    var onPartial: ((Speaker, String) -> Void)?
    var voice: VoiceID?
    /// Готовая фраза: кто, текст, номер голоса и сам звук — чтобы его можно было сохранить и переслушать
    var onFinal: ((Speaker, String, Int, [Float]) -> Void)?
    var onLevel: ((Speaker, Float) -> Void)?

    init(whisper: WhisperEngine) { self.whisper = whisper }

    func feed(_ speaker: Speaker, _ samples: [Float]) {
        let now = CFAbsoluteTimeGetCurrent()
        queue.async {
            var peak: Float = 0
            for v in samples { peak = max(peak, abs(v)) }
            let loud = peak > 0.02
            if loud { self.quietSince[speaker] = nil } else if self.quietSince[speaker] == nil { self.quietSince[speaker] = now }
            // Гаснет индикатор не сразу, а через 0,4 с тишины — чтобы не мигал между словами
            let on = loud || (now - (self.quietSince[speaker] ?? now) < 0.4 && self.active[speaker] == true)
            if on != (self.active[speaker] ?? false) {
                self.active[speaker] = on
                self.onLevel?(speaker, on ? 1 : 0)
            }
            if speaker == .them {
                self.systemEnv.append(contentsOf: Self.envelope(samples))
                if self.systemEnv.count > 3000 { self.systemEnv.removeFirst(self.systemEnv.count - 3000) }
                self.systemEnvEnd = now
            }
            for e in self.segmenters[speaker]!.feed(samples) {
                switch e {
                case .final(let s):
                    self.partials[speaker] = nil
                    self.finals.append((speaker, s, now))
                case .partial(let s):
                    self.partials[speaker] = (s, now)
                }
            }
            let sp = self.segmenters[speaker]!.speaking
            self.stateLock.lock(); self.speakingNow[speaker] = sp; self.stateLock.unlock()
            self.pump()
        }
    }

    /// Новая встреча — прежний контекст не нужен.
    func resetContext() { queue.async { self.context = ""; self.systemEnv = [] } }

    func flush() {
        let now = CFAbsoluteTimeGetCurrent()
        queue.async {
            for (sp, seg) in self.segmenters {
                if let tail = seg.flush() { self.finals.append((sp, tail, now)) }
            }
            self.partials = [:]
            self.pump()
        }
    }

    private func pump() {
        guard !busy else { return }
        if !finals.isEmpty {
            let (sp, s, t) = finals.removeFirst()
            run(sp, s, endTime: t, final: true)
        } else if let (sp, (s, t)) = partials.first {
            partials[sp] = nil
            run(sp, s, endTime: t, final: false)
        }
    }

    private static func envelope(_ x: [Float]) -> [Float] {
        var out: [Float] = []
        var i = 0
        while i + 320 <= x.count {
            var sum: Float = 0
            for k in i..<i + 320 { sum += x[k] * x[k] }
            out.append((sum / 320).squareRoot())
            i += 320
        }
        return out
    }

    /// Насколько фраза из микрофона повторяет по рисунку громкости то, что в это же время играло в звонке.
    /// Эхо из колонок повторяет его почти точно (с небольшой задержкой), собственная речь — нет.
    private func echoScore(_ mic: [Float], endTime: Double) -> Float {
        let m = Self.envelope(mic)
        guard m.count >= 25, !systemEnv.isEmpty else { return 0 }
        var best: Float = 0
        // Микрофон слышит колонки с задержкой; плюс неточность наших отметок времени
        for lagFrames in stride(from: -10, through: 30, by: 2) {
            let endIdx = systemEnv.count - 1 - Int((systemEnvEnd - endTime) / 0.02) - lagFrames
            let startIdx = endIdx - m.count + 1
            guard startIdx >= 0, endIdx < systemEnv.count else { continue }
            let s = Array(systemEnv[startIdx...endIdx])
            var ms: Float = 0, ss: Float = 0
            for k in 0..<m.count { ms += m[k]; ss += s[k] }
            ms /= Float(m.count); ss /= Float(m.count)
            // В звонке в это время тихо — эху взяться неоткуда
            guard ss > 0.002 else { continue }
            var num: Float = 0, dm: Float = 0, ds: Float = 0
            for k in 0..<m.count {
                let a = m[k] - ms, b = s[k] - ss
                num += a * b; dm += a * a; ds += b * b
            }
            let r = num / ((dm * ds).squareRoot() + 1e-9)
            if r > best { best = r }
        }
        return best
    }

    private func run(_ speaker: Speaker, _ samples: [Float], endTime: Double, final: Bool) {
        // Микрофон поймал звук из колонок — не распознаём вовсе
        if speaker == .me {
            let score = echoScore(samples, endTime: endTime)
            if score > 0.6 {
                if final { log(String(format: "эхо звонка в микрофоне отброшено (сходство %.2f)", score)); onPartial?(speaker, "") }
                pump()
                return
            }
        }
        busy = true
        let lang = language, pr = prompt
        var ctx = context
        Task.detached(priority: .userInitiated) {
            guard final else {
                let text = await self.whisper.transcribe(samples, language: lang, fast: true)
                self.queue.async {
                    self.busy = false
                    if !text.isEmpty, !self.finals.contains(where: { $0.0 == speaker }) { self.onPartial?(speaker, text) }
                    self.pump()
                }
                return
            }
            // Если внутри фразы сменился говорящий (перебили без паузы) — режем её по этой границе
            let channel = speaker == .me ? 0 : 1
            let parts = self.voice?.split(samples) ?? [0..<samples.count]
            var out: [(String, Int, [Float])] = []
            for r in parts {
                let piece = Array(samples[r])
                let text = await self.whisper.transcribe(piece, language: lang, names: pr, context: ctx, fast: false)
                guard !text.isEmpty else { continue }
                // Голоса различаем в обоих каналах: за одним микрофоном тоже может быть несколько человек
                let who = self.voice?.identify(piece, channel: channel) ?? 0
                ctx = String((ctx + " " + text).suffix(220))
                if who != -1 { out.append((text, who, piece)) }
            }
            let newContext = ctx
            self.queue.async {
                self.busy = false
                self.context = newContext
                self.onPartial?(speaker, "")
                for (text, who, piece) in out { self.onFinal?(speaker, text, who, piece) }
                self.pump()
            }
        }
    }
}
