using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Sufler;

/// <summary>Куда отправлять общую статистику и отзывы. Пока адрес пустой, приложение ничего никуда не отправляет.</summary>
public static class Telemetry
{
    public const string Endpoint = "https://minijir.space/sufler";
    public static bool Enabled => Endpoint.Length > 0;
}

/// <summary>Сводка для экрана «Статистика».</summary>
public sealed class UsageSummary
{
    public int Meetings, Words, Questions, QuestionsForMe, Facts, Documents, Chunks, LlmRequests, LlmIn, LlmOut, ChatQuestions;
    public double RecordedHours, DatabaseMb, AudioMb;
    /// <summary>Последние 30 дней: минуты записи и слова.</summary>
    public List<(DateTime Day, double Minutes, int Words)> Days = new();
}

public sealed partial class AppCore
{
    private static readonly HttpClient TelemetryHttp = new() { Timeout = TimeSpan.FromSeconds(20) };

    /// <summary>Плюс к дневному счётчику. Хранится только в базе на этом компьютере.</summary>
    public void Count(string key, double value = 1)
    {
        try { _store.Bump(key, value, DateTime.Now.ToString("yyyy-MM-dd")); } catch { }
    }

    public UsageSummary UsageSummary()
    {
        var u = new UsageSummary
        {
            Meetings = (int)_store.Scalar("SELECT COUNT(*) FROM meetings"),
            RecordedHours = _store.Scalar("SELECT COALESCE(SUM(ended_at - started_at), 0) FROM meetings WHERE ended_at IS NOT NULL") / 3600,
            // Слова считаем по пробелам: для статистики этого достаточно
            Words = (int)_store.Scalar("SELECT COALESCE(SUM(LENGTH(text) - LENGTH(REPLACE(text, ' ', '')) + 1), 0) FROM turns WHERE LENGTH(text) > 0"),
            Questions = (int)_store.Scalar("SELECT COUNT(*) FROM questions"),
            QuestionsForMe = (int)_store.Scalar("SELECT COUNT(*) FROM questions WHERE for_me = 1"),
            Facts = (int)_store.Scalar("SELECT COUNT(*) FROM facts"),
            Documents = (int)_store.Scalar("SELECT COUNT(*) FROM documents"),
            Chunks = (int)_store.Scalar("SELECT COUNT(*) FROM chunks"),
        };
        long Size(string f) => File.Exists(f) ? new FileInfo(f).Length : 0;
        var db = Path.Combine(Models.Root, "sufler.sqlite");
        u.DatabaseMb = (Size(db) + Size(db + "-wal")) / 1e6;
        try { u.AudioMb = Directory.GetFiles(MeetingAudio.Dir).Sum(Size) / 1e6; } catch { }
        foreach (var (_, kv) in _store.Usage("0000"))
        {
            u.LlmRequests += (int)kv.GetValueOrDefault("llm_requests");
            u.LlmIn += (int)kv.GetValueOrDefault("llm_in");
            u.LlmOut += (int)kv.GetValueOrDefault("llm_out");
            u.ChatQuestions += (int)kv.GetValueOrDefault("chat_questions");
        }
        // Активность по дням берём из самих встреч — так видна и история до появления счётчиков
        var start = DateTime.Today.AddDays(-29);
        var minutes = new Dictionary<string, double>();
        foreach (var m in Meetings.Where(m => m.StartedAt >= start))
        {
            var d = m.StartedAt.ToString("yyyy-MM-dd");
            minutes[d] = minutes.GetValueOrDefault(d) + Math.Max(0, ((m.EndedAt ?? m.StartedAt) - m.StartedAt).TotalMinutes);
        }
        var words = _store.WordsByDay(start);
        for (int i = 0; i < 30; i++)
        {
            var day = start.AddDays(i);
            var k = day.ToString("yyyy-MM-dd");
            u.Days.Add((day, minutes.GetValueOrDefault(k), words.GetValueOrDefault(k)));
        }
        return u;
    }

    // MARK: Общая статистика (только с согласия)

    /// <summary>«unknown» — ещё не спрашивали, «yes» — разрешили, «no» — отказались.</summary>
    public string TelemetryConsent { get => Settings.Get("telemetryConsent", "unknown"); set { Settings.Set("telemetryConsent", value); Raise(); } }

    /// <summary>Постоянный случайный номер установки: по нему считаются люди, но он ни с чем не связан.</summary>
    public static string InstallId
    {
        get
        {
            var id = Settings.Get("installId", "");
            if (id.Length == 0) Settings.Set("installId", id = Guid.NewGuid().ToString());
            return id;
        }
    }

    /// <summary>Ровно то, что уйдёт на сервер. Показывается пользователю в настройках.</summary>
    public JsonObject TelemetryPayload(string version)
    {
        var last = Settings.Get("telemetrySentDay", "0000");
        var today = DateTime.Now.ToString("yyyy-MM-dd");
        var days = _store.Usage(last).Where(d => string.CompareOrdinal(d.Key, last) > 0).ToDictionary(d => d.Key, d => d.Value);
        // Встречи, слова и вопросы берём из самих встреч — так уходит и история, и ничего не считается дважды
        foreach (var (day, kv) in _store.DerivedDays(last))
        {
            if (!days.TryGetValue(day, out var d)) days[day] = d = new();
            foreach (var (k, v) in kv) d[k] = v;
        }
        // Отметка «сегодня приложение открывали» — по ней видно, сколько людей пользуется
        if (!days.TryGetValue(today, out var t)) days[today] = t = new();
        t["active"] = 1;
        var arr = new JsonArray();
        foreach (var (day, kv) in days.OrderBy(d => d.Key))
        {
            var counters = new JsonObject();
            foreach (var (k, v) in kv) counters[k] = Math.Round(v, 2);
            arr.Add(new JsonObject { ["day"] = day, ["counters"] = counters });
        }
        return new JsonObject
        {
            ["install"] = InstallId, ["app"] = "windows", ["version"] = version, ["os"] = Machine.Os,
            ["memory_gb"] = (int)Math.Round(Machine.RamGb), ["gpu"] = Machine.Discrete ? "discrete" : "integrated", ["mode"] = AppMode, ["days"] = arr,
        };
    }

    /// <summary>Если человек согласился: счётчики за прошедшие дни и за сегодня. Без согласия ничего не делает.</summary>
    public async Task SendTelemetryIfAllowed(string version)
    {
        if (TelemetryConsent != "yes" || !Telemetry.Enabled) return;
        try
        {
            using var resp = await TelemetryHttp.PostAsync(Telemetry.Endpoint + "/v1/usage", new StringContent(TelemetryPayload(version).ToJsonString(), Encoding.UTF8, "application/json"));
            // Сегодняшний день ещё не закончился — в следующий раз отправим его снова, сервер просто обновит цифры
            if (resp.IsSuccessStatusCode) Settings.Set("telemetrySentDay", DateTime.Now.AddDays(-1).ToString("yyyy-MM-dd"));
        }
        catch { }
    }

    /// <summary>Пока приложение открыто — отправляем раз в несколько часов, чтобы день не терялся.</summary>
    public async Task TelemetryLoop(string version)
    {
        while (true)
        {
            await SendTelemetryIfAllowed(version);
            await FlushOutbox();
            await Task.Delay(TimeSpan.FromHours(4));
        }
    }

    public void SetTelemetry(bool allowed, string version)
    {
        // Отказ — и ничего не уходит: ни сейчас, ни потом. Накопленное остаётся только на этом компьютере
        TelemetryConsent = allowed ? "yes" : "no";
        if (allowed) _ = SendTelemetryIfAllowed(version);
    }

    // MARK: Отзывы

    private static string Outbox
    {
        get
        {
            var d = Path.Combine(Models.Root, "Outbox");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public int PendingFeedback => Directory.GetFiles(Outbox, "*.json").Length;

    /// <summary>Отзыв кладём в очередь и отправляем, как только есть куда. Тексты встреч сюда не попадают.</summary>
    public void SubmitFeedback(string kind, string text, string contact, bool attachInfo, string version)
    {
        var item = new JsonObject { ["kind"] = kind, ["text"] = text, ["contact"] = contact, ["created"] = DateTime.UtcNow.ToString("o"), ["app"] = "windows", ["version"] = version };
        if (attachInfo)
        {
            item["os"] = Machine.Os;
            item["memory_gb"] = (int)Math.Round(Machine.RamGb);
            item["models"] = $"{AsrStatus}; {LlmStatus}; {Machine.Cpu}; {Machine.GpuName}";
            item["mode"] = AppMode;
        }
        File.WriteAllText(Path.Combine(Outbox, Guid.NewGuid() + ".json"), item.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        _ = FlushOutbox();
    }

    public async Task FlushOutbox()
    {
        if (!Telemetry.Enabled) return;
        foreach (var f in Directory.GetFiles(Outbox, "*.json"))
        {
            try
            {
                using var resp = await TelemetryHttp.PostAsync(Telemetry.Endpoint + "/v1/feedback", new StringContent(File.ReadAllText(f), Encoding.UTF8, "application/json"));
                if (resp.IsSuccessStatusCode) File.Delete(f);
            }
            catch { }
        }
    }
}
