import AVFoundation
import AppKit
import CoreAudio
import Foundation

// MARK: Звук встречи

/// Сохраняет распознанные фразы встречи в один сжатый файл, чтобы их можно было переслушать.
/// Пишется только речь, без тишины: час речи занимает около 15 МБ.
final class MeetingAudio {
    static var dir: URL {
        let d = Paths.supportDir.appendingPathComponent("Audio")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(_ meetingID: Int64) -> URL { dir.appendingPathComponent("\(meetingID).caf") }

    static func delete(_ meetingID: Int64) { try? FileManager.default.removeItem(at: url(meetingID)) }

    /// Убирает записи старше заданного числа дней.
    static func cleanup(olderThanDays days: Int) {
        let limit = Date().addingTimeInterval(-Double(days) * 86400)
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < limit {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private var file: AVAudioFile?
    private var written: Int64 = 0
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    init?(meetingID: Int64) {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000]
        guard let f = try? AVAudioFile(forWriting: Self.url(meetingID), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false) else { return nil }
        file = f
    }

    /// Дописывает фразу. Возвращает, где она лежит в файле: начало и конец в секундах.
    func append(_ samples: [Float]) -> (Double, Double)? {
        guard let file, !samples.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        guard (try? file.write(from: buf)) != nil else { return nil }
        let start = Double(written) / 16000
        written += Int64(samples.count)
        return (start, Double(written) / 16000)
    }

    func close() { file = nil }
}

// MARK: Микрофон: встреча или диктовка

/// Микрофон один, а слушателей двое: расшифровка встречи и диктовка вопроса в чат.
/// Пока идёт диктовка, звук уходит ей и в расшифровку встречи не попадает.
final class MicRouter {
    private let lock = NSLock()
    private var meeting: (([Float]) -> Void)?
    private var dictation: (([Float]) -> Void)?

    func setMeeting(_ f: (([Float]) -> Void)?) { lock.lock(); meeting = f; lock.unlock() }
    func setDictation(_ f: (([Float]) -> Void)?) { lock.lock(); dictation = f; lock.unlock() }

    func route(_ samples: [Float]) {
        lock.lock()
        let target = dictation ?? meeting
        lock.unlock()
        target?(samples)
    }
}

// MARK: Начался звонок

/// Следит, какие приложения включили микрофон: если это приложение для звонков или браузер —
/// скорее всего, начался созвон, и стоит предложить запись.
final class CallWatcher {
    static let defaultApps = "Zoom, Teams, Telegram, Discord, Slack, Skype, FaceTime, Webex, WhatsApp, Viber, Телемост, Толк, Chrome, Safari, Firefox, Edge, Arc, Яндекс, Opera, Brave"

    /// Приложение только что начало пользоваться микрофоном: его имя и строка для сверки со списком (имя и идентификатор).
    var onMicStarted: ((String, String) -> Void)?
    private var timer: DispatchSourceTimer?
    private var active = Set<pid_t>()
    private var primed = false

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sufler.callwatch", qos: .utility))
        t.schedule(deadline: .now() + 2, repeating: 3)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil; active = []; primed = false }

    private func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func poll() {
        var a = addr(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return }

        var now = Set<pid_t>()
        var names: [pid_t: (String, String)] = [:]
        for obj in ids {
            var running: UInt32 = 0
            var s = UInt32(MemoryLayout<UInt32>.size)
            var ra = addr(kAudioProcessPropertyIsRunningInput)
            guard AudioObjectGetPropertyData(obj, &ra, 0, nil, &s, &running) == noErr, running != 0 else { continue }
            var pid: pid_t = 0
            s = UInt32(MemoryLayout<pid_t>.size)
            var pa = addr(kAudioProcessPropertyPID)
            guard AudioObjectGetPropertyData(obj, &pa, 0, nil, &s, &pid) == noErr, pid != getpid() else { continue }
            var bundle: CFString = "" as CFString
            s = UInt32(MemoryLayout<CFString>.size)
            var ba = addr(kAudioProcessPropertyBundleID)
            _ = withUnsafeMutablePointer(to: &bundle) { AudioObjectGetPropertyData(obj, &ba, 0, nil, &s, $0) }
            now.insert(pid)
            names[pid] = Self.appName(pid: pid, bundleID: bundle as String)
        }
        // При первом проходе только запоминаем, кто уже с микрофоном: звонок, начатый до нас, не «начался»
        let fresh = primed ? now.subtracting(active) : []
        active = now
        primed = true
        for pid in fresh { if let n = names[pid] { onMicStarted?(n.0, n.1) } }
    }

    /// Понятное имя приложения. Браузеры и мессенджеры держат микрофон во вспомогательных процессах
    /// («Google Chrome Helper») — поднимаемся до основного приложения по идентификатору.
    private static func appName(pid: pid_t, bundleID: String) -> (String, String) {
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.processIdentifier == pid }), app.activationPolicy == .regular, let n = app.localizedName { return (n, n + " " + bundleID) }
        let parent = apps.filter { $0.activationPolicy == .regular }
            .filter { a in a.bundleIdentifier.map { !$0.isEmpty && bundleID.hasPrefix($0) } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
        if let n = parent?.localizedName { return (n, n + " " + bundleID) }
        return (bundleID, bundleID)
    }
}

// MARK: Проверка названий

/// Слово из расшифровки, которое, похоже, распознано неверно: пользователь подтверждает или исправляет его.
struct NameCheck: Identifiable, Codable, Hashable {
    var id = UUID()
    var heard: String
    var guess: String
    var quote: String
    var turnID: Int64 = 0
}

enum Corrections {
    /// Словарь исправлений хранится строками «как услышано = как правильно».
    static func parse(_ text: String) -> [(String, String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "=")
            guard parts.count == 2 else { return nil }
            let a = parts[0].trimmingCharacters(in: .whitespaces), b = parts[1].trimmingCharacters(in: .whitespaces)
            return a.isEmpty || b.isEmpty || a == b ? nil : (a, b)
        }
    }

    /// Заменяет слово целиком, без учёта регистра; внутри других слов ничего не трогает.
    static func replace(_ text: String, _ wrong: String, _ right: String) -> String {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: wrong) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: right))
    }

    static func apply(_ text: String, _ pairs: [(String, String)]) -> String {
        pairs.reduce(text) { replace($0, $1.0, $1.1) }
    }

    static func contains(_ text: String, _ word: String) -> Bool {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
