using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sufler;

/// <summary>Встроенный llama-server: приложение само поднимает его как дочерний процесс и гасит при выходе.</summary>
public sealed class LlamaServer : IDisposable
{
    private Process? _process;
    private StreamWriter? _log;
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(5) };
    public int Port { get; private set; }
    public string LogPath { get; private set; } = "";
    public string BaseUrl => $"http://127.0.0.1:{Port}";
    public bool Running => _process is { HasExited: false };

    public async Task Start(string exe, string model, string extraArgs, string logPath, CancellationToken ct = default)
    {
        Dispose();
        Port = FreePort();
        LogPath = logPath;
        var psi = new ProcessStartInfo(exe, $"-m \"{model}\" --host 127.0.0.1 --port {Port} --no-webui --offline {extraArgs}")
        {
            WorkingDirectory = Path.GetDirectoryName(exe)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
        };
        var process = _process = Process.Start(psi) ?? throw new Exception("Не удалось запустить llama-server");
        var log = _log = new StreamWriter(new FileStream(logPath, FileMode.Create, FileAccess.Write, FileShare.ReadWrite), Encoding.UTF8) { AutoFlush = true };
        void Write(string? line) { if (line is not null) lock (log) { try { log.WriteLine(line); } catch { } } }
        process.OutputDataReceived += (_, e) => Write(e.Data);
        process.ErrorDataReceived += (_, e) => Write(e.Data);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();

        // Ждём, пока модель загрузится
        for (int i = 0; i < 900; i++)
        {
            ct.ThrowIfCancellationRequested();
            if (process.HasExited) throw new Exception($"llama-server завершился при запуске, см. {logPath}");
            try
            {
                using var r = await Http.GetAsync(BaseUrl + "/health", ct);
                if (r.StatusCode == HttpStatusCode.OK) return;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch { }
            await Task.Delay(300, ct);
        }
        throw new Exception("llama-server не ответил вовремя");
    }

    public string ReadLog()
    {
        try
        {
            using var fs = new FileStream(LogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var r = new StreamReader(fs);
            return r.ReadToEnd();
        }
        catch { return ""; }
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        int port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    public void Dispose()
    {
        try { if (_process is { HasExited: false }) _process.Kill(true); } catch { }
        try { _process?.Dispose(); } catch { }
        _process = null;
        try { _log?.Dispose(); } catch { }
        _log = null;
    }
}

public sealed record ChatMessage(string Role, string Content);

/// <summary>Клиент к встроенным серверам: разговорная модель и модель поиска (эмбеддинги).</summary>
public sealed class LlmClient
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(5) };
    public string ChatUrl { get; set; } = "";
    public string EmbedUrl { get; set; } = "";

    /// <summary>Сколько токенов модель прочитала и написала — для экрана «Статистика».</summary>
    public Action<int, int>? OnUsage;

    private void ReportUsage(JsonElement root)
    {
        try
        {
            if (root.TryGetProperty("usage", out var u) && u.ValueKind == JsonValueKind.Object && u.TryGetProperty("prompt_tokens", out var p) && u.TryGetProperty("completion_tokens", out var c))
                OnUsage?.Invoke(p.GetInt32(), c.GetInt32());
            else if (root.TryGetProperty("timings", out var t) && t.TryGetProperty("prompt_n", out var pn) && t.TryGetProperty("predicted_n", out var cn))
                OnUsage?.Invoke(pn.GetInt32(), cn.GetInt32());
        }
        catch { }
    }

    private string Body(IEnumerable<ChatMessage> messages, JsonNode? schema, int maxTokens, double temperature, bool stream, bool cache = true)
    {
        var b = new JsonObject
        {
            ["messages"] = new JsonArray(messages.Select(m => (JsonNode)new JsonObject { ["role"] = m.Role, ["content"] = m.Content }).ToArray()),
            ["max_tokens"] = maxTokens,
            ["temperature"] = temperature,
            ["stream"] = stream,
            ["cache_prompt"] = cache,
            // Gemma 4 иначе «думает вслух» прямо в ответе
            ["chat_template_kwargs"] = new JsonObject { ["enable_thinking"] = false },
        };
        if (stream) b["stream_options"] = new JsonObject { ["include_usage"] = true };
        if (schema is not null)
            b["response_format"] = new JsonObject { ["type"] = "json_schema", ["json_schema"] = new JsonObject { ["name"] = "out", ["strict"] = true, ["schema"] = schema.DeepClone() } };
        return b.ToJsonString();
    }

    private StringContent Json(string body) => new(body, Encoding.UTF8, "application/json");

    public async Task<string> Chat(IEnumerable<ChatMessage> messages, JsonNode? schema = null, int maxTokens = 512, double temperature = 0.2, CancellationToken ct = default)
    {
        using var resp = await _http.PostAsync(ChatUrl + "/v1/chat/completions", Json(Body(messages, schema, maxTokens, temperature, false)), ct);
        var text = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode) throw new Exception("Модель вернула ошибку: " + TextTools.Head(text, 300));
        using var doc = JsonDocument.Parse(text);
        ReportUsage(doc.RootElement);
        return doc.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString() ?? "";
    }

    /// <summary>Ответ по заданной схеме, уже разобранный. null — модель не справилась.</summary>
    public async Task<JsonNode?> ChatJson(string system, string user, JsonNode schema, int maxTokens, double temperature = 0.1)
    {
        try { return JsonNode.Parse(await Chat([new("system", system), new("user", user)], schema, maxTokens, temperature)); }
        catch { return null; }
    }

    /// <summary>Потоковый ответ: куски текста по мере генерации.</summary>
    public async IAsyncEnumerable<string> ChatStream(IEnumerable<ChatMessage> messages, int maxTokens = 1024, double temperature = 0.3, [EnumeratorCancellation] CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, ChatUrl + "/v1/chat/completions") { Content = Json(Body(messages, null, maxTokens, temperature, true)) };
        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        using var reader = new StreamReader(await resp.Content.ReadAsStreamAsync(ct), Encoding.UTF8);
        while (await reader.ReadLineAsync(ct) is { } line)
        {
            if (!line.StartsWith("data: ")) continue;
            var payload = line[6..];
            if (payload == "[DONE]") break;
            string? piece = null;
            try
            {
                using var doc = JsonDocument.Parse(payload);
                if (doc.RootElement.TryGetProperty("usage", out _) || doc.RootElement.TryGetProperty("timings", out _)) ReportUsage(doc.RootElement);
                var delta = doc.RootElement.GetProperty("choices")[0].GetProperty("delta");
                if (delta.TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String) piece = c.GetString();
            }
            catch { }
            if (!string.IsNullOrEmpty(piece)) yield return piece;
        }
    }

    public async Task<List<float[]>> Embed(IReadOnlyList<string> texts, CancellationToken ct = default)
    {
        if (texts.Count == 0) return [];
        var body = new JsonObject { ["input"] = new JsonArray(texts.Select(t => (JsonNode)t).ToArray()) }.ToJsonString();
        using var resp = await _http.PostAsync(EmbedUrl + "/v1/embeddings", Json(body), ct);
        if (!resp.IsSuccessStatusCode) throw new Exception("Модель поиска вернула ошибку");
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        return doc.RootElement.GetProperty("data").EnumerateArray()
            .Select(row => row.GetProperty("embedding").EnumerateArray().Select(x => x.GetSingle()).ToArray()).ToList();
    }

    /// <summary>
    /// Замер скорости на типовой работе: прочитать кусок разговора и выдать начало ответа.
    /// Возвращает, сколько секунд заняло бы найти вопрос (≈250 токенов прочитать, ≈30 написать).
    /// </summary>
    public async Task<(double Seconds, double Read, double Write)> Measure(string system, CancellationToken ct)
    {
        var body = Body([new("system", system), new("user", "Перескажи инструкцию своими словами в трёх предложениях.")], null, 40, 0.1, false, cache: false);
        using var resp = await _http.PostAsync(ChatUrl + "/v1/chat/completions", Json(body), ct);
        resp.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        var t = doc.RootElement.GetProperty("timings");
        double read = t.GetProperty("prompt_per_second").GetDouble(), write = t.GetProperty("predicted_per_second").GetDouble();
        if (read <= 0 || write <= 0) throw new Exception("нет замера");
        return (250 / read + 30 / write, read, write);
    }
}
