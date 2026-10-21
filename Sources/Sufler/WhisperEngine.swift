import Foundation
import whisper

/// Обёртка над whisper.cpp. Один контекст, все вызовы идут через последовательную очередь.
final class WhisperEngine {
    private var ctx: OpaquePointer?
    private let queue = DispatchQueue(label: "sufler.whisper", qos: .userInitiated)

    init(modelPath: String) throws {
        var cp = whisper_context_default_params()
        cp.use_gpu = true
        cp.flash_attn = true
        ctx = whisper_init_from_file_with_params(modelPath, cp)
        if ctx == nil { throw NSError(domain: "Sufler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось загрузить модель Whisper"]) }
    }

    deinit { if let ctx { whisper_free(ctx) } }

    /// - Parameters:
    ///   - names: имена и термины из настроек — подсказка, как их писать;
    ///   - context: конец уже распознанного разговора — с ним Whisper реже путает похожие по звучанию слова;
    ///   - fast: черновой проход для «живой» строки.
    func transcribe(_ input: [Float], language: String, names: String = "", context: String = "", fast: Bool) async -> String {
        await withCheckedContinuation { cont in
            queue.async { cont.resume(returning: self.run(input, language: language, names: names, context: context, fast: fast)) }
        }
    }

    private func run(_ input: [Float], language: String, names: String, context: String, fast: Bool) -> String {
        guard let ctx else { return "" }
        let seconds = Double(input.count) / 16000
        var samples = input

        // Тихую речь (звонок на малой громкости) подтягиваем до рабочего уровня
        var peak: Float = 0
        for v in samples { peak = max(peak, abs(v)) }
        if peak > 0.002, peak < 0.5 {
            let gain = min(0.7 / peak, 10)
            for i in samples.indices { samples[i] *= gain }
        }
        // whisper.cpp отказывается от аудио короче секунды
        let minCount = 16000 + 3200
        if samples.count < minCount { samples.append(contentsOf: [Float](repeating: 0, count: minCount - samples.count)) }

        // Готовые фразы распознаём лучевым поиском — он точнее жадного; черновики — жадным, ради скорости
        var p = whisper_full_default_params(fast ? WHISPER_SAMPLING_GREEDY : WHISPER_SAMPLING_BEAM_SEARCH)
        p.n_threads = 4
        p.no_context = true
        p.no_timestamps = true
        p.single_segment = false
        p.print_special = false
        p.print_progress = false
        p.print_realtime = false
        p.print_timestamps = false
        p.suppress_blank = true
        p.suppress_nst = true
        p.translate = false
        p.detect_language = false
        p.temperature = 0
        if fast {
            p.greedy.best_of = 1
            p.temperature_inc = 0
        } else {
            p.beam_search.beam_size = 3
        }

        // Подсказку даём только длинным фразам: на коротких звуках и тишине Whisper
        // начинает «читать» саму подсказку — отсюда выдуманные имена на месте «угу»
        var prompt = ""
        if !fast, seconds >= 2.0 {
            var parts: [String] = []
            if seconds >= 3.0, !names.isEmpty { parts.append(names + ".") }
            if !context.isEmpty { parts.append(context) }
            prompt = parts.joined(separator: " ")
        }

        var text = ""
        var probSum: Float = 0
        var probCount = 0
        language.withCString { lang in
            prompt.withCString { pr in
                p.language = lang
                p.initial_prompt = prompt.isEmpty ? nil : pr
                let rc = samples.withUnsafeBufferPointer { whisper_full(ctx, p, $0.baseAddress, Int32($0.count)) }
                guard rc == 0 else { return }
                let eot = whisper_token_eot(ctx)
                let n = whisper_full_n_segments(ctx)
                for i in 0..<n {
                    if whisper_full_get_segment_no_speech_prob(ctx, i) > 0.6 { continue }
                    if let c = whisper_full_get_segment_text(ctx, i) { text += String(cString: c) }
                    for t in 0..<whisper_full_n_tokens(ctx, i) where whisper_full_get_token_id(ctx, i, t) < eot {
                        probSum += whisper_full_get_token_p(ctx, i, t)
                        probCount += 1
                    }
                }
            }
        }
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty, !fast else { return cleaned }

        // Уверенность модели в своих словах. Чем короче звук, тем строже: именно короткие
        // шумы и междометия превращаются в выдуманные слова
        let confidence = probCount > 0 ? probSum / Float(probCount) : 0
        let floor: Float = seconds < 1.5 ? 0.6 : (seconds < 3 ? 0.45 : 0.3)
        if confidence < floor {
            log(String(format: "whisper: отброшено «%@» (уверенность %.2f, %.1f с)", cleaned, confidence, seconds))
            return ""
        }
        // Модель вернула слова из подсказки вместо речи
        if !prompt.isEmpty {
            let said = Self.words(cleaned), hint = Self.words(names)
            if !said.isEmpty, said.count <= 8, said.isSubset(of: hint) {
                log("whisper: отброшено эхо подсказки «\(cleaned)»")
                return ""
            }
        }
        return cleaned
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Whisper на тишине и шуме любит «досочинять» титры — отсекаем известные фразы.
    private static let junk = [
        "продолжение следует", "субтитры", "редактор субтитров", "корректор", "спасибо за просмотр",
        "подписывайтесь на канал", "thanks for watching", "thank you for watching", "dimatorzok",
    ]

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = t.lowercased()
        if low.count < 60, junk.contains(where: { low.contains($0) }) { return "" }
        if t.allSatisfy({ !$0.isLetter && !$0.isNumber }) { return "" }
        // Зацикливание декодера: одна и та же пара слов много раз подряд
        let w = t.lowercased().split(separator: " ")
        if w.count >= 12, Set(w).count * 4 < w.count { return "" }
        return t
    }
}
