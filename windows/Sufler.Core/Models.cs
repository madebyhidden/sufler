using System.ComponentModel;
using System.IO.Compression;
using System.Net.Http.Headers;

namespace Sufler;

/// <summary>То, что приложение скачивает при первом запуске: модели и движок языковой модели.</summary>
public sealed class ModelItem : INotifyPropertyChanged
{
    public required string File { get; init; }
    public required string Title { get; init; }
    public required string Note { get; init; }
    public required string Url { get; init; }
    public required long Size { get; init; }
    /// <summary>Архив, который после загрузки надо распаковать в папку (движок llama.cpp).</summary>
    public string? UnzipTo { get; init; }
    /// <summary>Мелкий служебный файл: в списке на экране установки показывается компактно.</summary>
    public bool Minor { get; init; }

    private double _progress;
    private string _state = "";
    private bool _ready;
    public bool Ready { get => _ready; set { _ready = value; Raise(nameof(Ready)); Raise(nameof(CanDelete)); } }
    /// <summary>Файл лежит на диске, но выбранным сейчас моделям не нужен.</summary>
    public bool Extra { get; init; }
    public bool CanDelete => Ready && UnzipTo is null;
    public double Progress { get => _progress; set { _progress = value; Raise(nameof(Progress)); } }
    public string State { get => _state; set { _state = value; Raise(nameof(State)); } }
    public string SizeText => Size >= 1_000_000_000 ? $"{Size / 1e9:0.0} ГБ" : Size >= 1_000_000 ? $"{Size / 1e6:0} МБ" : $"{Math.Max(1, Size / 1000)} КБ";

    public event PropertyChangedEventHandler? PropertyChanged;
    private void Raise(string n) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(n));
}

/// <summary>Сведения о компьютере: их заполняет оболочка под конкретную систему.</summary>
public static class Machine
{
    public static double RamGb = 16;
    public static string Cpu = "";
    public static string GpuName = "";
    public static double VramGb;
    public static string Os = "";

    /// <summary>Есть отдельная видеокарта, на которую имеет смысл класть модели.</summary>
    public static bool Discrete => VramGb >= 3.5;
    public static bool LowMemory => RamGb < 9.5;
    /// <summary>Модель по умолчанию: большая — только там, где есть видеокарта и запас памяти.</summary>
    public static string DefaultProfile => Discrete && RamGb >= 12 ? "e4b" : "e2b";

    public static string Summary =>
        $"{Cpu}, {Environment.ProcessorCount} потоков, память {RamGb:0} ГБ, " +
        (GpuName.Length > 0 ? $"{GpuName} ({(Discrete ? $"{VramGb:0} ГБ" : "встроенная")})" : "видеокарта не найдена") + $", {Os}";
}

public static class Models
{
    public const string Whisper = "ggml-large-v3-turbo-q5_0.bin";
    public const string Giga = "gigaam-v3-e2e-ctc.int8.onnx";
    public const string GigaTokens = "gigaam-v3-e2e-ctc.tokens.txt";
    public const string Embed = "embeddinggemma-300M-Q8_0.gguf";
    public const string VoicePrint = "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx";
    public const string VoiceSegments = "pyannote-segmentation-3-0.onnx";
    public const string LlamaZip = "llama-b11558-bin-win-vulkan-x64.zip";

    /// <summary>Какая Gemma выбрана: "e4b" — обычная, "e2b" — лёгкая для ноутбуков без видеокарты.</summary>
    public static string Profile
    {
        get => Settings.Get("model", Machine.DefaultProfile);
        set => Settings.Set("model", value);
    }

    /// <summary>Чем распознавать речь: "giga" — GigaAM v3 (русский, быстро на любом процессоре), "whisper" — Whisper turbo (любой язык, нужна видеокарта).</summary>
    public static string Asr
    {
        get => Settings.Get("asr", "giga");
        set => Settings.Set("asr", value);
    }

    /// <summary>Своя модель в формате GGUF вместо Gemma; пусто — модель по умолчанию.</summary>
    public static string CustomChat
    {
        get { var p = Settings.Get("chatModelPath", ""); return p.Length > 0 && File.Exists(p) ? p : ""; }
        set => Settings.Set("chatModelPath", value);
    }

    public static string Chat => Profile == "e2b" ? "gemma-4-E2B-it-Q4_0.gguf" : "gemma-4-E4B-it-Q4_0.gguf";
    public static string Draft => Profile == "e2b" ? "mtp-gemma-4-E2B-it-Q4_0.gguf" : "mtp-gemma-4-E4B-it-Q4_0.gguf";
    public static string ChatTitle => CustomChat.Length > 0 ? Path.GetFileNameWithoutExtension(CustomChat) : Profile == "e2b" ? "Gemma 4 E2B" : "Gemma 4 E4B";
    public static string ChatPath => CustomChat.Length > 0 ? CustomChat : PathOf(Chat);

    private static string? _root;
    /// <summary>Папка с данными приложения: модели, база, настройки.</summary>
    public static string Root
    {
        get
        {
            _root ??= Environment.GetEnvironmentVariable("SUFLER_HOME") is { Length: > 0 } home
                ? home
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Sufler");
            Directory.CreateDirectory(_root);
            return _root;
        }
        set => _root = value;
    }

    public static string Dir
    {
        get
        {
            var dir = Path.Combine(Root, "Models");
            Directory.CreateDirectory(dir);
            return dir;
        }
    }

    public static string LlamaDir => Path.Combine(Root, "llama-bin");
    /// <summary>Для проверок на другой системе можно подставить свой llama-server.</summary>
    public static string? LlamaExeOverride;
    public static string LlamaExe => LlamaExeOverride ?? Path.Combine(LlamaDir, "llama-server.exe");
    public static string PathOf(string file) => Path.Combine(Dir, file);
    public static bool Has(string file) => File.Exists(PathOf(file));

    public static List<ModelItem> Catalog()
    {
        bool light = Profile == "e2b";
        string repo = light ? "gemma-4-E2B-it-GGUF" : "gemma-4-E4B-it-GGUF";
        const string giga = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16/resolve/main/";
        var list = new List<ModelItem>();
        if (Asr == "whisper")
            list.Add(new() { File = Whisper, Title = "Whisper large-v3-turbo", Note = "Распознавание речи на любом языке", Size = 574_041_195,
                             Url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin" });
        else
        {
            list.Add(new() { File = Giga, Title = "GigaAM v3", Note = "Распознавание русской речи", Size = 224_893_661, Url = giga + "model.int8.onnx" });
            list.Add(new() { File = GigaTokens, Title = "Словарь GigaAM", Note = "Нужен модели распознавания", Size = 2_007, Url = giga + "tokens.txt", Minor = true });
        }
        if (CustomChat.Length == 0)
        {
            list.Add(new() { File = Chat, Title = light ? "Gemma 4 E2B" : "Gemma 4 E4B", Note = "Вопросы, итог встречи, чат, факты", Size = light ? 2_841_481_184 : 4_590_807_392,
                             Url = $"https://huggingface.co/ggml-org/{repo}/resolve/main/{Chat}" });
            // Ускоритель помогает только на отдельной видеокарте
            if (Machine.Discrete)
                list.Add(new() { File = Draft, Title = "Ускоритель Gemma", Note = "Делает ответы быстрее", Size = light ? 59_235_872 : 59_678_240,
                                 Url = $"https://huggingface.co/ggml-org/{repo}/resolve/main/{Draft}", Minor = true });
        }
        list.Add(new() { File = Embed, Title = "EmbeddingGemma", Note = "Поиск по базе знаний и прошлым встречам", Size = 333_590_944,
                         Url = "https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF/resolve/main/embeddinggemma-300M-Q8_0.gguf" });
        list.Add(new() { File = VoicePrint, Title = "Голоса", Note = "Различает собеседников по голосу", Size = 28_281_164,
                         Url = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx" });
        list.Add(new() { File = VoiceSegments, Title = "Смена говорящего", Note = "Делит фразу, когда человека перебили", Size = 5_992_913,
                         Url = "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/main/model.onnx", Minor = true });
        list.Add(new() { File = LlamaZip, Title = "Движок llama.cpp", Note = "Запускает языковые модели", Size = 32_000_000, UnzipTo = LlamaDir,
                         Url = "https://github.com/ggml-org/llama.cpp/releases/download/b11558/llama-b11558-bin-win-vulkan-x64.zip", Minor = true });
        return list;
    }

    /// <summary>Файлы в папке моделей, которые выбранным сейчас моделям не нужны: прежняя модель после смены, недокачанные остатки.</summary>
    public static List<ModelItem> Unused()
    {
        var used = Catalog().Select(m => m.File).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var list = new List<ModelItem>();
        foreach (var f in Directory.GetFiles(Dir).OrderByDescending(f => new FileInfo(f).Length))
        {
            var name = Path.GetFileName(f);
            bool part = name.EndsWith(".part");
            if (used.Contains(part ? name[..^5] : name) || name.StartsWith('.')) continue;
            list.Add(new ModelItem { File = name, Title = name, Note = part ? "Недокачанный файл — можно удалить" : "Сейчас не используется — можно удалить", Url = "", Size = new FileInfo(f).Length, Extra = true });
        }
        return list;
    }

    public static void Delete(ModelItem m)
    {
        File.Delete(PathOf(m.File));
        if (File.Exists(PathOf(m.File) + ".part")) File.Delete(PathOf(m.File) + ".part");
    }

    public static bool IsReady(ModelItem m) =>
        m.UnzipTo is not null ? File.Exists(LlamaExe) : File.Exists(PathOf(m.File)) && new FileInfo(PathOf(m.File)).Length >= m.Size;

    /// <summary>Скачивание с докачкой: если связь оборвалась, повторный запуск продолжит с того же места.</summary>
    public static async Task Download(ModelItem m, HttpClient http, CancellationToken ct)
    {
        var dest = PathOf(m.File);
        var part = dest + ".part";
        long have = File.Exists(part) ? new FileInfo(part).Length : 0;
        using var req = new HttpRequestMessage(HttpMethod.Get, m.Url);
        if (have > 0) req.Headers.Range = new RangeHeaderValue(have, null);
        using var resp = await http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        if (have > 0 && resp.StatusCode != System.Net.HttpStatusCode.PartialContent) have = 0; // сервер не умеет докачку — начинаем заново
        resp.EnsureSuccessStatusCode();
        long total = have + (resp.Content.Headers.ContentLength ?? Math.Max(0, m.Size - have));
        await using (var src = await resp.Content.ReadAsStreamAsync(ct))
        await using (var dst = new FileStream(part, have > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
        {
            var buf = new byte[1 << 20];
            int n;
            long done = have, lastReport = 0;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                done += n;
                if (done - lastReport > 4_000_000) { lastReport = done; m.Progress = total > 0 ? (double)done / total : 0; }
            }
        }
        if (m.UnzipTo is not null)
        {
            Directory.CreateDirectory(m.UnzipTo);
            ZipFile.ExtractToDirectory(part, m.UnzipTo, true);
            File.Delete(part);
            // В некоторых архивах файлы лежат во вложенной папке — поднимаем их наверх
            if (!File.Exists(LlamaExe))
            {
                var found = Directory.GetFiles(m.UnzipTo, "llama-server.exe", SearchOption.AllDirectories).FirstOrDefault();
                if (found is not null)
                    foreach (var f in Directory.GetFiles(Path.GetDirectoryName(found)!))
                        File.Move(f, Path.Combine(m.UnzipTo, Path.GetFileName(f)), true);
            }
        }
        else
        {
            File.Move(part, dest, true);
        }
        m.Progress = 1;
    }
}

/// <summary>Настройки приложения: маленький файл рядом с моделями.</summary>
public static class Settings
{
    private static string FilePath => Path.Combine(Models.Root, "settings.json");
    private static Dictionary<string, string>? _cache;

    private static Dictionary<string, string> Load()
    {
        if (_cache is not null) return _cache;
        try { _cache = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(FilePath)); } catch { }
        return _cache ??= new();
    }

    public static string Get(string key, string fallback) => Load().TryGetValue(key, out var v) ? v : fallback;

    public static bool Flag(string key, bool fallback) => Get(key, fallback ? "1" : "0") == "1";
    public static void SetFlag(string key, bool value) => Set(key, value ? "1" : "0");

    public static void Set(string key, string value)
    {
        Load()[key] = value;
        try { File.WriteAllText(FilePath, System.Text.Json.JsonSerializer.Serialize(_cache)); } catch { }
    }
}
