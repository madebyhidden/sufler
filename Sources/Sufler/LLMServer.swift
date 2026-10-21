import Foundation

/// Встроенный llama-server: приложение само поднимает его как дочерний процесс и гасит при выходе.
final class LlamaProcess {
    let port: Int
    private var process: Process?
    private let args: [String]
    private let name: String

    init(name: String, model: URL, port: Int, extra: [String]) {
        self.name = name
        self.port = port
        self.args = ["-m", model.path, "--host", "127.0.0.1", "--port", String(port), "-ngl", "99", "--no-webui", "--offline"] + extra
    }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    func start() async throws {
        guard let bin = Paths.llamaServer else { throw err("Не найден llama-server") }
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        p.currentDirectoryURL = bin.deletingLastPathComponent()
        let logURL = Paths.supportDir.appendingPathComponent("llama-\(name).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let fh = try FileHandle(forWritingTo: logURL)
        p.standardOutput = fh
        p.standardError = fh
        try p.run()
        process = p
        try? "\(p.processIdentifier)".write(to: pidFile, atomically: true, encoding: .utf8)

        // Ждём, пока модель загрузится
        for _ in 0..<600 {
            if !p.isRunning { throw err("llama-server (\(name)) завершился при запуске, см. \(logURL.path)") }
            var req = URLRequest(url: baseURL.appendingPathComponent("health"))
            req.timeoutInterval = 1
            if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw err("llama-server (\(name)) не ответил вовремя")
    }

    func stop() {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(at: pidFile)
    }

    private var pidFile: URL { Paths.supportDir.appendingPathComponent("llama-\(name).pid") }

    /// Если прошлый запуск упал и оставил сервер висеть — убираем его.
    static func killStale(name: String) {
        let f = Paths.supportDir.appendingPathComponent("llama-\(name).pid")
        guard let s = try? String(contentsOf: f, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/ps")
        check.arguments = ["-p", String(pid), "-o", "ppid=,comm="]
        let pipe = Pipe()
        check.standardOutput = pipe
        try? check.run()
        check.waitUntilExit()
        let comm = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // Гасим только осиротевший сервер (родитель — launchd): у работающего второго окна приложения свой, живой
        let fields = comm.split(separator: " ", maxSplits: 1).map(String.init)
        if fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "1", fields[1].contains("llama-server") { kill(pid, SIGTERM) }
        try? FileManager.default.removeItem(at: f)
    }
}

struct ChatMessage: Codable {
    var role: String
    var content: String
}

/// Клиент к встроенным серверам (чат и эмбеддинги).
final class LLMClient {
    let chatURL: URL
    let embedURL: URL
    private let session: URLSession

    init(chatURL: URL, embedURL: URL) {
        self.chatURL = chatURL
        self.embedURL = embedURL
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 300
        session = URLSession(configuration: cfg)
    }

    /// Сколько токенов модель прочитала и написала — для экрана «Статистика»
    var onUsage: ((Int, Int) -> Void)?

    private func reportUsage(_ obj: [String: Any]) {
        if let u = obj["usage"] as? [String: Any], let p = u["prompt_tokens"] as? Int, let c = u["completion_tokens"] as? Int { onUsage?(p, c); return }
        if let t = obj["timings"] as? [String: Any], let p = t["prompt_n"] as? Int, let c = t["predicted_n"] as? Int { onUsage?(p, c) }
    }

    private func body(_ messages: [ChatMessage], schema: [String: Any]?, maxTokens: Int, temperature: Double, stream: Bool, grammar: String? = nil) -> Data {
        var b: [String: Any] = [
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": stream,
            "cache_prompt": true,
            // Gemma 4 иначе «думает вслух» прямо в ответе
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        if let schema {
            b["response_format"] = ["type": "json_schema", "json_schema": ["name": "out", "strict": true, "schema": schema]]
        }
        if let grammar { b["grammar"] = grammar }
        if stream { b["stream_options"] = ["include_usage": true] }
        return try! JSONSerialization.data(withJSONObject: b)
    }

    func chat(_ messages: [ChatMessage], schema: [String: Any]? = nil, maxTokens: Int = 512, temperature: Double = 0.2) async throws -> String {
        var req = URLRequest(url: chatURL.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body(messages, schema: schema, maxTokens: maxTokens, temperature: temperature, stream: false)
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw err("Модель вернула ошибку: " + (String(data: data, encoding: .utf8) ?? "").prefix(300))
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let obj { reportUsage(obj) }
        let msg = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])
        return (msg?["content"] as? String) ?? ""
    }

    func chatStream(_ messages: [ChatMessage], schema: [String: Any]? = nil, maxTokens: Int = 1024, temperature: Double = 0.3, grammar: String? = nil) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: chatURL.appendingPathComponent("v1/chat/completions"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = body(messages, schema: schema, maxTokens: maxTokens, temperature: temperature, stream: true, grammar: grammar)
                    let (bytes, _) = try await session.bytes(for: req)
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = line.dropFirst(6)
                        if payload == "[DONE]" { break }
                        guard let d = payload.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if obj["usage"] != nil || obj["timings"] != nil { reportUsage(obj) }
                        guard let delta = (obj["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any],
                              let piece = delta["content"] as? String else { continue }
                        cont.yield(piece)
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var req = URLRequest(url: embedURL.appendingPathComponent("v1/embeddings"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["input": texts])
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw err("Сервер эмбеддингов вернул ошибку") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = (obj?["data"] as? [[String: Any]]) ?? []
        return rows.map { (($0["embedding"] as? [NSNumber]) ?? []).map { $0.floatValue } }
    }
}
