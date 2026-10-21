import Foundation

/// Где лежат модели и движки. Сначала ищем внутри .app, затем рядом с проектом (для запуска из исходников).
enum Paths {
    static let whisperModel = "ggml-large-v3-turbo-q5_0.bin"
    static let chatModel = "gemma-4-E4B-it-Q4_0.gguf"
    static let embedModel = "embeddinggemma-300M-Q8_0.gguf"
    /// Маленькая модель-черновик: угадывает токены вперёд и ускоряет генерацию Gemma
    static let draftModel = "mtp-gemma-4-E4B-it-Q4_0.gguf"
    /// Глубокая модель для собеседований: MoE, активны ~4B параметров — думает глубже, а работает почти так же быстро
    static let deepModel = "gemma-4-26B-A4B-it-Q4_0.gguf"
    static let deepDraftModel = "mtp-gemma-4-26B-A4B-it-Q4_0.gguf"

    private static var roots: [URL] {
        var r: [URL] = []
        if let res = Bundle.main.resourceURL { r.append(res) }
        // Модели, скачанные при первом запуске, лежат в Application Support
        r.append(supportDir)
        if let env = ProcessInfo.processInfo.environment["SUFLER_ROOT"] { r.append(URL(fileURLWithPath: env)) }
        r.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        return r
    }

    /// Языковая модель: выбранный в настройках GGUF, иначе встроенная или скачанная Gemma.
    static var chatModelURL: URL? {
        if let custom = UserDefaults.standard.string(forKey: "chatModelPath"), !custom.isEmpty, FileManager.default.fileExists(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let u = model(chatModel), fileSize(u) > 4_500_000_000 { return u }
        return nil
    }

    static func fileSize(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0
    }

    static func model(_ name: String) -> URL? {
        for root in roots {
            let u = root.appendingPathComponent("Models").appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static var llamaServer: URL? {
        for root in roots {
            for dir in ["llama-bin", "Vendor/llama-bin"] {
                let u = root.appendingPathComponent(dir).appendingPathComponent("llama-server")
                if FileManager.default.isExecutableFile(atPath: u.path) { return u }
            }
        }
        return nil
    }

    static var downloadedModelsDir: URL {
        let dir = supportDir.appendingPathComponent("Models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Sufler")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(("[sufler] " + s + "\n").data(using: .utf8)!)
}
