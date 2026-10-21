import FluidAudio
import Foundation

/// Различает собеседников по голосу: снимает «отпечаток» с каждой фразы и сопоставляет с уже слышанными.
final class VoiceID {
    private let diarizer = DiarizerManager()
    private let queue = DispatchQueue(label: "sufler.voice", qos: .userInitiated)
    /// Отпечатки голосов ведём отдельно по каналам: микрофон и звук звонка не смешиваются
    private struct Channel {
        var centroids: [[Float]] = []
        var counts: [Int] = []
        var last = 0
    }
    private var channels: [Int: Channel] = [:]
    private var centroids: [[Float]] = []
    private var counts: [Int] = []
    private var last = 0
    private var echoCheck: [[Float]] = []

    static var modelsDir: URL? {
        guard let seg = Paths.model("voice/pyannote_segmentation.mlmodelc") else { return nil }
        return seg.deletingLastPathComponent()
    }

    init(dir: URL) throws {
        let models = try DiarizerModels.load(
            localSegmentationModel: dir.appendingPathComponent("pyannote_segmentation.mlmodelc"),
            localEmbeddingModel: dir.appendingPathComponent("wespeaker_v2.mlmodelc"))
        diarizer.initialize(models: models)
    }

    func reset() {
        queue.sync { channels = [:]; centroids = []; counts = []; last = 0 }
    }

    /// Номер говорящего с единицы; 0 — определить не удалось; -1 — в микрофон попал голос из колонок (эхо звонка).
    func identify(_ samples: [Float], channel: Int = 0) -> Int {
        queue.sync {
            let st = channels[channel] ?? Channel()
            centroids = st.centroids; counts = st.counts; last = st.last
            echoCheck = channel == 0 ? (channels[1]?.centroids ?? []) : []
            let r = self.run(samples)
            if r == -1 { return -1 }
            channels[channel] = Channel(centroids: centroids, counts: counts, last: last)
            return r
        }
    }

    /// Делит фразу на части по смене говорящего. Если говорит один человек — возвращает её целиком.
    func split(_ samples: [Float]) -> [Range<Int>] {
        let whole = [0..<samples.count]
        // На коротком звуке смену голоса надёжно не поймать
        guard samples.count >= 16000 * 3 else { return whole }
        return queue.sync {
            guard let result = try? diarizer.performCompleteDiarization(samples, sampleRate: 16000) else { return whole }
            // Склеиваем подряд идущие куски одного голоса, мелочь короче 0,7 с не считаем отдельным говорящим
            var runs: [(id: String, start: Float, end: Float)] = []
            for seg in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where seg.durationSeconds >= 0.7 {
                if let last = runs.last, last.id == seg.speakerId {
                    runs[runs.count - 1].end = seg.endTimeSeconds
                } else {
                    runs.append((seg.speakerId, seg.startTimeSeconds, seg.endTimeSeconds))
                }
            }
            guard runs.count >= 2 else { return whole }
            var cuts: [Int] = []
            for i in 1..<runs.count {
                // Граница — между концом одного и началом другого; уточняем по самому тихому месту рядом
                let mid = Int((runs[i - 1].end + runs[i].start) / 2 * 16000)
                let lo = max(0, mid - 4000), hi = min(samples.count - 320, mid + 4000)
                guard lo < hi else { continue }
                var best = mid, bestE = Float.greatestFiniteMagnitude
                var k = lo
                while k < hi {
                    var e: Float = 0
                    for j in k..<k + 320 { e += samples[j] * samples[j] }
                    if e < bestE { bestE = e; best = k + 160 }
                    k += 160
                }
                cuts.append(best)
            }
            var ranges: [Range<Int>] = []
            var from = 0
            for c in cuts where c - from >= 16000 * 7 / 10 && samples.count - c >= 16000 * 7 / 10 {
                ranges.append(from..<c)
                from = c
            }
            ranges.append(from..<samples.count)
            return ranges
        }
    }

    private func run(_ input: [Float]) -> Int {
        // В хвосте фразы — пауза, по которой её отрезали; в отпечаток она не нужна
        var s = input
        if s.count > 16000 * 2 { s.removeLast(16000 / 2) }
        if s.count > 160_000 { s = Array(s.prefix(160_000)) }
        let seconds = Double(s.count) / 16000
        guard seconds >= 0.8, let e = try? diarizer.extractSpeakerEmbedding(from: s), !e.isEmpty else { return last }

        // Микрофон услышал того же, кто сейчас звучит в звонке, — это колонки, а не новый человек
        if echoCheck.contains(where: { cosine($0, e) >= 0.5 }) { return -1 }

        var best = -1
        var bestSim: Float = -1
        for (i, c) in centroids.enumerated() {
            let sim = cosine(c, e)
            if sim > bestSim { bestSim = sim; best = i }
        }
        // Уверенное совпадение: уточняем отпечаток говорящего
        if best >= 0, bestSim >= 0.5 {
            update(best, e)
            last = best + 1
            return last
        }
        // Похоже, но не наверняка — относим к ближайшему, отпечаток не трогаем
        if best >= 0, bestSim >= 0.36 || seconds < 2.0 {
            last = best + 1
            return last
        }
        // Новый голос заводим только по достаточно длинной фразе
        if seconds >= 2.0 || centroids.isEmpty {
            centroids.append(e)
            counts.append(1)
            last = centroids.count
            return last
        }
        return last
    }

    private func update(_ i: Int, _ e: [Float]) {
        let n = Float(min(counts[i], 20))
        var c = centroids[i]
        var norm: Float = 0
        for k in 0..<c.count { c[k] = (c[k] * n + e[k]) / (n + 1); norm += c[k] * c[k] }
        norm = norm.squareRoot() + 1e-9
        for k in 0..<c.count { c[k] /= norm }
        centroids[i] = c
        counts[i] += 1
    }

    /// Скачать модели голоса в папку (вызывается один раз при сборке: `Sufler --fetch-voice <dir>`).
    static func fetch(to dir: URL) async throws {
        _ = try await DiarizerModels.download(to: dir)
    }
}
