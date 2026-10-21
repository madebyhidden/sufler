using System.Collections.ObjectModel;
using System.Text;
using System.Text.RegularExpressions;

namespace Sufler;

/// <summary>Источник звука: микрофон или звук системы. Отдаёт 16 кГц моно.</summary>
public interface IAudioInput
{
    event Action<float[]>? Samples;
    void Start();
    void Stop();
}

/// <summary>
/// Вся логика «Суфлёра» без интерфейса: встречи, запись, вопросы, факты, база знаний, чат.
/// Оболочка под конкретную систему только показывает это состояние и вызывает методы.
/// Методы вызываются из потока интерфейса.
/// </summary>
public sealed partial class AppCore : Observable, IDisposable
{
    private readonly SynchronizationContext? _ui = SynchronizationContext.Current;
    private readonly Store _store;
    private readonly LlmClient _llm = new();
    private readonly LlamaServer _chatServer = new(), _embedServer = new();
    private ISpeechEngine? _speech;
    private string _speechKind = "";
    private Pipeline? _pipeline;
    private VoiceId? _voice;
    private IAudioInput? _mic, _system;
    private Dictionary<int, string> _voiceNames = new();
    private long _examinedTurnId;
    private int _examinedLen;
    private DateTime? _candidateSince;
    private CancellationTokenSource? _detectWait;
    private CancellationTokenSource? _notesSave;
    private bool _starting;
    /// <summary>Сколько текста можно показать модели за раз — зависит от размера её окна.</summary>
    private int _budget = 7000;

    // То, что даёт оболочка
    public Func<bool, IAudioInput>? AudioFactory;          // true — звук системы, false — микрофон
    public Func<ISpeechEngine>? WhisperFactory;
    public Action<string, string>? Notify;

    // Движки
    private string _asrStatus = "Загружаю распознавание речи…", _llmStatus = "Загружаю языковую модель…";
    private bool _asrReady, _llmReady, _embedReady, _asrFailed, _llmFailed;
    public string AsrStatus { get => _asrStatus; private set => Set(ref _asrStatus, value); }
    public string LlmStatus { get => _llmStatus; private set => Set(ref _llmStatus, value); }
    public bool AsrReady { get => _asrReady; private set => Set(ref _asrReady, value); }
    public bool LlmReady { get => _llmReady; private set => Set(ref _llmReady, value); }
    public bool EmbedReady { get => _embedReady; private set => Set(ref _embedReady, value); }
    public bool AsrFailed { get => _asrFailed; private set => Set(ref _asrFailed, value); }
    public bool LlmFailed { get => _llmFailed; private set => Set(ref _llmFailed, value); }

    // Данные
    public ObservableCollection<Meeting> Meetings { get; } = new();
    public ObservableCollection<Turn> Turns { get; } = new();
    /// <summary>Черновики фраз, которые ещё звучат.</summary>
    public ObservableCollection<Turn> Partials { get; } = new();
    /// <summary>Вопросы открытой встречи, свежий — первым.</summary>
    public ObservableCollection<Question> Questions { get; } = new();
    public ObservableCollection<ChatLine> Chat { get; } = new();
    public ObservableCollection<Fact> Facts { get; } = new();
    public ObservableCollection<Doc> Docs { get; } = new();

    // Состояние
    private Meeting? _selected;
    private bool _isRecording, _detecting, _answering, _summarizing, _chatBusy, _showKb, _micMuted, _levelMe, _levelThem;
    private long _recordingId;
    private string _errorText = "", _pendingQuestion = "", _kbStatus = "";
    public Meeting? Selected { get => _selected; private set { if (Set(ref _selected, value)) Raise(nameof(SelectedIsRecording)); } }
    public bool IsRecording { get => _isRecording; private set { if (Set(ref _isRecording, value)) Raise(nameof(SelectedIsRecording)); } }
    /// <summary>Встреча, которая сейчас пишется (или дописывается после остановки); 0 — нет такой.</summary>
    public long RecordingId { get => _recordingId; private set { if (Set(ref _recordingId, value)) Raise(nameof(SelectedIsRecording)); } }
    public bool SelectedIsRecording => IsRecording && Selected is not null && Selected.Id == RecordingId;
    public bool Detecting { get => _detecting; private set => Set(ref _detecting, value); }
    public bool Answering { get => _answering; private set => Set(ref _answering, value); }
    public bool Summarizing { get => _summarizing; private set => Set(ref _summarizing, value); }
    public bool ChatBusy { get => _chatBusy; private set => Set(ref _chatBusy, value); }
    /// <summary>Открыта база знаний, а не встреча.</summary>
    public bool ShowKb { get => _showKb; set { if (Set(ref _showKb, value)) { Chat.Clear(); } } }
    public bool MicMuted { get => _micMuted; private set => Set(ref _micMuted, value); }
    public bool LevelMe { get => _levelMe; private set => Set(ref _levelMe, value); }
    public bool LevelThem { get => _levelThem; private set => Set(ref _levelThem, value); }
    public string ErrorText { get => _errorText; set => Set(ref _errorText, value); }
    /// <summary>Вопрос, который модель прямо сейчас дописывает.</summary>
    public string PendingQuestion { get => _pendingQuestion; private set => Set(ref _pendingQuestion, value); }
    public string KbStatus { get => _kbStatus; private set => Set(ref _kbStatus, value); }

    // Настройки
    public string MyName { get => Settings.Get("myName", ""); set { Settings.Set("myName", value); Raise(); } }
    public string Glossary { get => Settings.Get("glossary", ""); set { Settings.Set("glossary", value); Raise(); } }
    public bool CaptureMic { get => Settings.Flag("captureMic", true); set { Settings.SetFlag("captureMic", value); Raise(); } }
    public bool CaptureSystem { get => Settings.Flag("captureSystem", true); set { Settings.SetFlag("captureSystem", value); Raise(); } }

    // Замеры
    private readonly List<double> _phraseSpeed = new(), _cardDelay = new();
    private string _diagSpeech = "", _diagLlm = "", _diagLast = "";
    private DateTime _lastPhraseEnd;

    public AppCore()
    {
        _llm.OnUsage = (p, c) => Post(() => { Count("llm_requests"); Count("llm_in", p); Count("llm_out", c); });
        _store = new Store(Path.Combine(Models.Root, "sufler.sqlite"));
        foreach (var m in _store.Meetings()) Meetings.Add(m);
        foreach (var d in _store.Documents()) Docs.Add(d);
        foreach (var f in _store.Facts()) { f.Meta = FactMeta(f); Facts.Add(f); }
        LoadLibrary();
        MeetingAudio.Cleanup(30);
        if (Meetings.FirstOrDefault(m => m.IsInterview == InterviewMode) is { } first) Select(first);
        Turns.CollectionChanged += (_, _) => Raise(nameof(InterviewPrep));
    }

    private void Post(Action a)
    {
        if (_ui is null) a(); else _ui.Post(_ => a(), null);
    }

    private bool _disposed;

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        try { StopPlayback(); _dictationMic?.Stop(); _audio?.Dispose(); } catch { }
        _mic?.Stop();
        _system?.Stop();
        _chatServer.Dispose();
        _embedServer.Dispose();
        _deepServer.Dispose();
        _speech?.Dispose();
        _voice?.Dispose();
        _store.Dispose();
    }

    private static void Log(string text)
    {
        try { File.AppendAllText(Path.Combine(Models.Root, "error.log"), $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {text}\n"); } catch { }
    }

    // MARK: Запуск движков

    /// <summary>Запуск, перезапуск и остановка движков идут строго по очереди: два запуска разом
    /// делили бы одну модель и роняли приложение.</summary>
    private readonly SemaphoreSlim _bootGate = new(1, 1);

    public async Task Boot()
    {
        await _bootGate.WaitAsync();
        try { await Task.WhenAll(BootSpeech(), BootLlm()); }
        finally { _bootGate.Release(); }
    }

    private async Task BootSpeech()
    {
        if (AsrReady && _speechKind == Models.Asr) return;
        AsrReady = false;
        AsrFailed = false;
        bool giga = Models.Asr != "whisper";
        AsrStatus = giga ? "Загружаю GigaAM…" : "Загружаю Whisper…";
        try
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            _speech?.Dispose();
            _speech = await Task.Run(() => giga || WhisperFactory is null
                ? new GigaEngine(Models.PathOf(Models.Giga), Models.PathOf(Models.GigaTokens))
                : WhisperFactory());
            _speechKind = Models.Asr;
            // Прогрев: первый проход всегда медленнее остальных
            await _speech.Transcribe(new float[16000], true);
            _diagSpeech = $"{_speech.Name}: {_speech.Backend}, загрузка {sw.Elapsed.TotalSeconds:0.0} с";
            var p = new Pipeline(_speech);
            p.OnPartial = (sp, text) => Post(() => { if (text.Length > 0) _lastSoundAt = DateTime.UtcNow; SetPartial(sp, text); });
            p.OnFinal = (sp, text, who, samples, took) => Post(() =>
            {
                double seconds = samples.Length / 16000.0;
                _phraseSpeed.Add(took / Math.Max(0.5, seconds));
                _diagLast = $"{_speech?.Name}: последняя фраза {seconds:0.0} с распознана за {took:0.00} с";
                AddTurn(sp, text, who, samples);
            });
            p.OnLevel = (sp, on) => Post(() => { _lastSoundAt = DateTime.UtcNow; if (sp == Speaker.Me) LevelMe = on; else LevelThem = on; });
            if (_voice is null && Models.Has(Models.VoicePrint))
            {
                try
                {
                    var seg = Models.Has(Models.VoiceSegments) ? Models.PathOf(Models.VoiceSegments) : null;
                    var v = await Task.Run(() =>
                    {
                        var x = new VoiceId(Models.PathOf(Models.VoicePrint), seg);
                        // Прогрев, чтобы первая фраза не ждала загрузки модели
                        x.Identify(new float[32000], 0);
                        x.Reset();
                        return x;
                    });
                    _voice = v;
                }
                catch (Exception ex) { Log("голоса: " + ex); }
            }
            p.Voice = _voice;
            _pipeline = p;
            AsrReady = true;
            AsrStatus = _speech.Name;
        }
        catch (Exception ex)
        {
            Log("распознавание: " + ex);
            AsrStatus = "Распознавание речи не загрузилось";
            AsrFailed = true;
        }
    }

    /// <summary>Остановить все движки и отпустить файлы моделей — например, чтобы модель можно было удалить.</summary>
    public async Task StopEngines()
    {
        await _bootGate.WaitAsync();
        try { StopNow(); }
        finally { _bootGate.Release(); }
    }

    private void StopNow()
    {
        _chatServer.Dispose();
        _embedServer.Dispose();
        LlmReady = EmbedReady = AsrReady = false;
        _pipeline = null;
        _speech?.Dispose();
        _speech = null;
        _speechKind = "";
        _voice?.Dispose();
        _voice = null;
        AsrStatus = "Распознавание речи остановлено";
        LlmStatus = "Языковая модель остановлена";
    }

    /// <summary>Перезапуск языковой модели и поиска: после загрузки моделей или смены модели в настройках.</summary>
    public async Task Restart()
    {
        await _bootGate.WaitAsync();
        try
        {
            _chatServer.Dispose();
            _embedServer.Dispose();
            LlmReady = false;
            EmbedReady = false;
            await Task.WhenAll(BootSpeech(), BootLlm());
        }
        finally { _bootGate.Release(); }
    }

    private async Task BootLlm()
    {
        if (LlmReady) return;
        LlmFailed = false;
        if (!File.Exists(Models.ChatPath) || !File.Exists(Models.LlamaExe))
        {
            LlmStatus = "Нет языковой модели";
            LlmFailed = true;
            return;
        }
        LlmStatus = $"Загружаю {Models.ChatTitle}…";
        try
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            string how = await StartChatOnBestDevice();
            double load = sw.Elapsed.TotalSeconds;
            _llm.ChatUrl = _chatServer.BaseUrl;
            _llm.EmbedUrl = _chatServer.BaseUrl;
            // Прогрев: первый запрос идёт в разы дольше остальных. Делаем его заранее, с настоящей инструкцией — заодно она попадает в кэш
            LlmStatus = "Прогреваю модель…";
            sw.Restart();
            await foreach (var _ in _llm.ChatStream([new("system", QuestionSystem()), new("user", "Контекст:\n(пусто)\n\nНовые реплики:\nЯ: Проверка связи.")], 8, 0.1)) { }
            _diagLlm = $"{Models.ChatTitle}: {how}; загрузка {load:0.0} с, прогрев {sw.Elapsed.TotalSeconds:0.0} с";
            LlmReady = true;
            LlmStatus = Models.ChatTitle;
        }
        catch (Exception ex)
        {
            Log("языковая модель: " + ex);
            LlmStatus = "Языковая модель не запустилась";
            LlmFailed = true;
        }
        if (Models.Has(Models.Embed))
        {
            try
            {
                await _embedServer.Start(Models.LlamaExe, Models.PathOf(Models.Embed),
                    $"-ngl {(Machine.Discrete ? 99 : 0)} --embedding --pooling mean -c 2048 -np 1 -b 2048 -ub 2048", Path.Combine(Models.Root, "llama-embed.log"));
                _llm.EmbedUrl = _embedServer.BaseUrl;
                EmbedReady = true;
            }
            catch (Exception ex) { Log("поиск: " + ex); }
        }
    }

    private Task StartChat(bool gpu, bool draft, CancellationToken ct = default)
    {
        // Окно модели: чем меньше памяти, тем оно короче. Два места — чтобы чат не сбивал кэш поиска вопросов
        int slots = Machine.LowMemory ? 1 : 2;
        int perSlot = Machine.LowMemory ? 4096 : Machine.Discrete ? 8192 : 6144;
        _budget = perSlot >= 8192 ? 9000 : perSlot >= 6144 ? 7000 : 4500;
        var args = $"-ngl {(gpu ? 99 : 0)} -c {perSlot * slots} -np {slots} --reasoning-budget 0 --jinja";
        if (draft && Models.CustomChat.Length == 0 && Models.Has(Models.Draft)) args += $" --spec-draft-model \"{Models.PathOf(Models.Draft)}\" --spec-type draft-mtp";
        return _chatServer.Start(Models.LlamaExe, Models.ChatPath, args, Path.Combine(Models.Root, "llama-chat.log"), ct);
    }

    /// <summary>
    /// Запускает Gemma там, где она быстрее. С отдельной видеокартой всё ясно. Со встроенной графикой заранее
    /// не угадать: она делит память с процессором и бывает как вдвое быстрее его, так и медленнее. Поэтому
    /// один раз меряем оба варианта на типовом запросе и запоминаем лучший.
    /// </summary>
    private async Task<string> StartChatOnBestDevice()
    {
        if (Machine.Discrete)
        {
            // Ускоритель (вторая маленькая модель) помогает только на видеокарте
            await StartChat(true, true);
            return GpuInfo();
        }
        string key = "device-" + Path.GetFileName(Models.ChatPath);
        string saved = Settings.Get(key, "");
        // Мало памяти — встроенную графику не пробуем: она забирает под модель ту же оперативную память
        if (saved == "" && (Machine.LowMemory || Machine.GpuName.Length == 0)) saved = "cpu";
        if (saved == "gpu")
        {
            try
            {
                using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(120));
                await StartChat(true, false, limit.Token);
                return "встроенная графика — " + GpuInfo();
            }
            catch { saved = "cpu"; }
        }
        await StartChat(false, false);
        if (saved == "cpu") return "процессор";

        _llm.ChatUrl = _chatServer.BaseUrl;
        LlmStatus = "Подбираю режим: проверяю процессор…";
        var cpu = await _llm.Measure(QuestionPrompt, CancellationToken.None);
        string verdict = $"процессор {cpu.Seconds:0.0} с на вопрос (читает {cpu.Read:0}, пишет {cpu.Write:0} токенов/с)";
        LlmStatus = "Подбираю режим: проверяю встроенную графику…";
        try
        {
            // Графике даём ограниченное время: если она явно медленнее или зависла — остаёмся на процессоре
            using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(90 + cpu.Seconds * 4));
            await StartChat(true, false, limit.Token);
            _llm.ChatUrl = _chatServer.BaseUrl;
            await _llm.Measure(QuestionPrompt, limit.Token); // первый проход на графике компилирует шейдеры — не считаем
            var gpu = await _llm.Measure(QuestionPrompt, limit.Token);
            verdict += $", графика {gpu.Seconds:0.0} с (читает {gpu.Read:0}, пишет {gpu.Write:0})";
            if (gpu.Seconds < cpu.Seconds * 0.85)
            {
                Settings.Set(key, "gpu");
                return "встроенная графика; " + verdict;
            }
        }
        catch (Exception ex) { verdict += ", графика не справилась (" + ex.GetType().Name + ")"; }
        Settings.Set(key, "cpu");
        await StartChat(false, false);
        return "процессор; " + verdict;
    }

    /// <summary>Что llama.cpp сказал про видеокарту: имя и сколько слоёв модели на неё поместилось.</summary>
    private string GpuInfo()
    {
        var log = _chatServer.ReadLog();
        var dev = Regex.Match(log, @"ggml_vulkan: \d+ = ([^|\r\n]+)");
        var off = Regex.Match(log, @"offloaded (\d+)/(\d+) layers to GPU");
        var parts = new List<string>();
        if (dev.Success) parts.Add(dev.Groups[1].Value.Trim());
        if (off.Success) parts.Add($"на видеокарте {off.Groups[1].Value} из {off.Groups[2].Value} слоёв");
        return parts.Count > 0 ? string.Join(", ", parts) : "видеокарта";
    }

    /// <summary>Текст для кнопки «Скопировать замеры».</summary>
    public string Diagnostics(string version)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"Суфлёр для Windows {version}");
        sb.AppendLine(Machine.Summary);
        foreach (var s in new[] { _diagSpeech, _diagLlm, _diagLast }) if (s.Length > 0) sb.AppendLine(s);
        sb.AppendLine($"Поиск по базе: {(EmbedReady ? "готов" : "не запущен")}; голоса: {(_voice is null ? "нет" : "есть")}");
        if (_phraseSpeed.Count > 0) sb.AppendLine($"Распознавание: в среднем {_phraseSpeed.Average():0.00} с на секунду речи, фраз: {_phraseSpeed.Count}");
        if (_cardDelay.Count > 0) sb.AppendLine($"Вопрос: от конца фразы до карточки в среднем {_cardDelay.Average():0.00} с, худший {_cardDelay.Max():0.00} с, вопросов: {_cardDelay.Count}");
        return sb.ToString();
    }

    // MARK: Встречи

    public void Select(Meeting? m)
    {
        if (m is not null) ShowKb = false;
        if (ReferenceEquals(m, Selected)) return;
        Selected = m;
        Raise(nameof(InterviewPrep));
        Turns.Clear();
        Questions.Clear();
        Partials.Clear();
        Chat.Clear();
        _meetingVectors.Clear();
        _voiceNames = new();
        StopPlayback();
        LoadChecks(m);
        if (m is null) { LoadInterview(null); return; }
        _voiceNames = _store.VoiceNames(m.Id);
        foreach (var t in _store.Turns(m.Id)) { t.Label = Label(t); Turns.Add(t); }
        var qs = _store.Questions(m.Id);
        for (int i = qs.Count - 1; i >= 0; i--) { qs[i].Big = i == qs.Count - 1; Questions.Add(qs[i]); }
        _examinedTurnId = Turns.Count > 0 ? Turns[^1].Id : 0;
        _examinedLen = Turns.Count > 0 ? Turns[^1].Text.Length : 0;
        RefreshCanPlay();
        LoadInterview(m);
        Raise(nameof(InterviewPrep));
    }

    public void Delete(Meeting m)
    {
        if (m.Id == RecordingId) return;
        _store.DeleteMeeting(m.Id);
        MeetingAudio.Delete(m.Id);
        Meetings.Remove(m);
        if (ReferenceEquals(Selected, m)) { Selected = null; Select(Meetings.FirstOrDefault()); }
    }

    public void SetTitle(string text)
    {
        if (Selected is null || Selected.Title == text) return;
        Selected.Title = text;
        _store.Update(Selected);
    }

    public void SetNotes(string text)
    {
        if (Selected is null || Selected.Notes == text) return;
        var m = Selected;
        m.Notes = text;
        _notesSave?.Cancel();
        var cts = _notesSave = new CancellationTokenSource();
        _ = Task.Delay(500, cts.Token).ContinueWith(t => { if (!t.IsCanceled) Post(() => _store.Update(m)); });
    }

    // MARK: Запись

    public void ToggleRecording()
    {
        if (IsRecording) Stop(); else Start();
    }

    private void Start()
    {
        if (!AsrReady || _pipeline is null) { ErrorText = "Распознавание речи ещё загружается"; return; }
        if (_starting || RecordingId != 0) return;
        _starting = true;
        try
        {
            ErrorText = "";
            Meeting m;
            // Подготовленное собеседование, которое ещё не начиналось, пишем в него же
            if (Selected is { IsInterview: true } prepared && Turns.Count == 0)
            {
                m = prepared;
                m.StartedAt = DateTime.Now;
                _store.SetStarted(m.Id, m.StartedAt);
                int at = Meetings.IndexOf(m);
                if (at > 0) Meetings.Move(at, 0);
            }
            else
            {
                m = InterviewMode
                    ? _store.CreateMeeting("Собеседование " + DateTime.Now.ToString("d MMMM, HH:mm", Ru.Culture), "interview")
                    : _store.CreateMeeting("Встреча " + DateTime.Now.ToString("d MMMM, HH:mm", Ru.Culture));
                Meetings.Insert(0, m);
                Select(m);
            }
            RecordingId = m.Id;
            m.Recording = true;
            _examinedTurnId = 0;
            _examinedLen = 0;
            _candidateSince = null;
            _voice?.Reset();
            _pipeline.Reset();
            CallOffer = "";
            _audio?.Dispose();
            _audio = null;
            if (KeepAudio) { try { _audio = new MeetingAudio(m.Id); } catch (Exception ex) { Log("звук встречи: " + ex.Message); } }

            MicMuted = !CaptureMic;
            if (AudioFactory is not null)
            {
                if (CaptureSystem)
                {
                    try
                    {
                        _system = AudioFactory(true);
                        _system.Samples += s => _pipeline?.Feed(Speaker.Them, s);
                        _system.Start();
                    }
                    catch (Exception ex) { ErrorText = "Звук системы: " + ex.Message; _system = null; }
                }
                if (CaptureMic) StartMic();
            }
            IsRecording = true;
            _ = WatchSilence();
        }
        finally { _starting = false; }
    }

    private void StartMic()
    {
        try
        {
            _mic = AudioFactory!(false);
            _mic.Samples += RouteMic;
            _mic.Start();
            MicMuted = false;
        }
        catch (Exception ex)
        {
            ErrorText = "Микрофон: " + ex.Message + ". Проверьте, что он подключён и разрешён: Параметры → Конфиденциальность → Микрофон.";
            _mic = null;
            MicMuted = true;
        }
    }

    /// <summary>Выключить или включить микрофон прямо во время записи. Звук звонка продолжает писаться.</summary>
    public void ToggleMic()
    {
        if (!IsRecording || AudioFactory is null) return;
        if (!MicMuted)
        {
            _mic?.Stop();
            _mic = null;
            _pipeline?.Flush(Speaker.Me);
            MicMuted = true;
            LevelMe = false;
            return;
        }
        StartMic();
    }

    /// <summary>Подать звук напрямую, минуя микрофон и звук системы: для проверок.</summary>
    public void FeedAudio(string speaker, float[] samples) => _pipeline?.Feed(speaker, samples);

    private void Stop()
    {
        MicMuted = false;
        if (Dictating) CancelDictation();
        _mic?.Stop(); _mic = null;
        _system?.Stop(); _system = null;
        _pipeline?.Flush();
        IsRecording = false;
        LevelMe = LevelThem = false;
        var m = Meetings.FirstOrDefault(x => x.Id == RecordingId);
        if (m is null) { RecordingId = 0; return; }
        m.EndedAt = DateTime.Now;
        Count("meetings");
        Count("recorded_minutes", (m.EndedAt.Value - m.StartedAt).TotalMinutes);
        m.Recording = false;
        _store.Update(m);
        _ = Finish(m);
    }

    private async Task Finish(Meeting m)
    {
        // Даём распознаванию дожевать хвост: на слабом компьютере в очереди может быть несколько фраз
        await Task.Delay(700);
        for (int i = 0; i < 100 && _pipeline?.Pending == true; i++) await Task.Delay(200);
        await Task.Delay(300);
        RecordingId = 0;
        Partials.Clear();
        _audio?.Dispose();
        _audio = null;
        RefreshCanPlay();
        Raise(nameof(InterviewPrep));
        if (m.IsInterview)
        {
            // Ответы кандидата в общую базу фактов не тащим: там рабочие договорённости, а не люди
            await EvaluateInterview(m);
            await Summarize(m);
            await CheckNames(m);
            await Index(m);
            return;
        }
        await Summarize(m);
        await CheckNames(m);
        await ExtractFacts(m);
        await Index(m);
    }

    private void SetPartial(string speaker, string text)
    {
        if (RecordingId == 0 || Selected?.Id != RecordingId) { Partials.Clear(); return; }
        var old = Partials.FirstOrDefault(p => p.Speaker == speaker);
        if (text.Length == 0) { if (old is not null) Partials.Remove(old); return; }
        if (old is not null) old.Text = text;
        else Partials.Add(new Turn { Speaker = speaker, Text = text, Label = speaker, Live = true });
    }

    private DateTime _lastSoundAt = DateTime.UtcNow;
    /// <summary>Через сколько минут тишины запись останавливается сама; 0 — никогда.</summary>
    public int AutoStopMinutes
    {
        get => int.TryParse(Settings.Get("autoStopMinutes", "10"), out int m) ? m : 10;
        set { Settings.Set("autoStopMinutes", value.ToString()); Raise(); }
    }

    /// <summary>Забыли остановить запись после звонка: если долго тихо — останавливаем сами.</summary>
    private async Task WatchSilence()
    {
        _lastSoundAt = DateTime.UtcNow;
        while (IsRecording)
        {
            await Task.Delay(10000);
            if (!IsRecording) return;
            // Пока индикатор звука горит, тишины нет — даже если слов не распознано
            if (LevelMe || LevelThem || _pipeline?.AnyoneSpeaking == true) _lastSoundAt = DateTime.UtcNow;
            int minutes = AutoStopMinutes;
            if (minutes > 0 && (DateTime.UtcNow - _lastSoundAt).TotalMinutes >= minutes)
            {
                ToggleRecording();
                Notify?.Invoke("Запись остановлена", $"{minutes} мин было тихо — похоже, встреча закончилась. Итог уже составляется.");
                return;
            }
        }
    }

    private void AddTurn(string speaker, string heard, int who, float[] samples)
    {
        if (RecordingId == 0) return;
        _lastSoundAt = DateTime.UtcNow;
        // Словарь исправлений: названия, которые распознавание стабильно коверкает, сразу пишем правильно
        var text = Corrections.Apply(heard, Corrections.Parse(CorrectionsText));
        Count("words", text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length);
        Count("phrases");
        bool shown = Selected?.Id == RecordingId;
        var now = DateTime.Now;
        _lastPhraseEnd = DateTime.UtcNow;
        // Пока открыта другая встреча, реплики копим в базе и догружаем при возврате
        if (!shown)
        {
            var (a, b) = _audio?.Append(samples) ?? (0, 0);
            _store.AddTurn(RecordingId, speaker, text, who, a, b);
            return;
        }

        // Микрофон слышит колонки: если реплика совпала с только что сказанной собеседником — это эхо
        var dup = Turns.Skip(Math.Max(0, Turns.Count - 6)).FirstOrDefault(t => (now - t.Ts).TotalSeconds < 10 && t.Speaker != speaker && TextTools.Similarity(t.Text, text) > 0.6);
        if (dup is not null)
        {
            if (speaker == Speaker.Me) return;
            _store.DeleteTurn(dup.Id);
            Turns.Remove(dup);
        }
        // Речь режется по коротким паузам; подряд идущие куски одного голоса склеиваем в одну реплику
        var last = Turns.Count > 0 ? Turns[^1] : null;
        if (last is not null && last.Speaker == speaker && (last.Voice == who || who == 0 || last.Voice == 0) && (now - last.Ts).TotalSeconds < 3.5 && last.Text.Length < 400)
        {
            last.Text += " " + text;
            last.Ts = now;
            if (last.Voice == 0 && who != 0) { last.Voice = who; last.Label = Label(last); }
            if (_audio is not null)
            {
                var (a, b) = _audio.Append(samples);
                if (last.AudioEnd == 0) last.AudioStart = a;
                last.AudioEnd = b;
            }
            _store.UpdateTurn(last);
            NoteSpeech(last, samples.Length, false);
        }
        else
        {
            var (a, b) = _audio?.Append(samples) ?? (0, 0);
            var t = _store.AddTurn(RecordingId, speaker, text, who, a, b);
            t.Label = Label(t);
            NoteSpeech(t, samples.Length, true);
            Turns.Add(t);
        }
        if (Interview is not null && Selected?.IsInterview == true) ConsiderProbe();
        else ConsiderDetect(text);
    }

    // MARK: Голоса

    /// <summary>Как реплика подписана в расшифровке и в запросах к модели.</summary>
    public string Label(Turn t) => LabelOf(t, _voiceNames);

    private static string LabelOf(Turn t, Dictionary<int, string> names)
    {
        int key = t.VoiceKey;
        if (key == 0) return t.Speaker;
        if (names.TryGetValue(key, out var n)) return n;
        return key < 0 ? $"Голос {-key}" : $"Собеседник {key}";
    }

    public string VoiceName(int key) => _voiceNames.GetValueOrDefault(key, "");

    public void RenameVoice(int key, string name)
    {
        if (Selected is null) return;
        var n = name.Trim();
        if (n.Length == 0 || key == 0) return;
        _voiceNames[key] = n;
        _store.SetVoiceName(Selected.Id, key, n);
        foreach (var t in Turns) t.Label = Label(t);
    }

    // MARK: Моё имя

    /// <summary>Есть ли в тексте имя или фамилия владельца. Сравниваем по основе слова, чтобы ловить падежи:
    /// «Денис», «Дениса», «Денису».</summary>
    public bool IsMyName(string text)
    {
        var mine = Regex.Split(MyName.ToLowerInvariant(), @"[^\p{L}]+").Where(w => w.Length >= 3).ToList();
        if (mine.Count == 0 || text.Length == 0) return false;
        var words = Regex.Split(text.ToLowerInvariant(), @"[^\p{L}]+").ToHashSet();
        return mine.Any(name => words.Any(w => IsForm(w, name)));
    }

    /// <summary>Слово — это имя в одном из падежей: «Денис», «Дениса», «Денису»; «Аня», «Ани», «Аню».
    /// Сравниваем не по началу слова, а по окончаниям: иначе короткое имя «Ден» находилось в «денег» и «день».</summary>
    public static bool IsForm(string word, string name)
    {
        if (word == name) return true;
        string root = name;
        string[] endings = ["а", "у", "е", "ом", "ы"];
        switch (name[^1])
        {
            case 'а' or 'я': root = name[..^1]; endings = ["а", "я", "ы", "и", "е", "у", "ю", "ой", "ей", "ою", "ею"]; break;
            case 'й': root = name[..^1]; endings = ["й", "я", "ю", "ем", "е"]; break;
            case 'ь': root = name[..^1]; endings = ["ь", "я", "ю", "ем", "е", "и"]; break;
        }
        return word.StartsWith(root) && endings.Contains(word[root.Length..]);
    }

    // MARK: Последний вопрос

    private static readonly string[] AskWords = ["скажи", "расскажи", "подскажи", "объясни", "напомни", "уточни", "покажи", "пришли", "скинь", "ответь", "можешь", "можете", "сможешь", "сможете"];

    /// <summary>Дёшево отсекаем реплики, в которых вопроса заведомо нет, чтобы не гонять модель на каждую фразу.</summary>
    private static bool LooksLikeQuestion(string text)
    {
        var t = text.ToLowerInvariant();
        return t.Contains('?') || AskWords.Any(t.Contains);
    }

    /// <summary>Модель зовём не сразу, а когда говорящий договорил: так она видит мысль целиком
    /// (в том числе «спросил и сам ответил») и карточка не перерисовывается по несколько раз.</summary>
    private void ConsiderDetect(string text)
    {
        if (!LlmReady) return;
        if (LooksLikeQuestion(text) && _candidateSince is null) _candidateSince = DateTime.UtcNow;
        if (_candidateSince is not { } since || Detecting) return;
        _detectWait?.Cancel();
        var cts = _detectWait = new CancellationTokenSource();
        _ = Run();

        async Task Run()
        {
            // Фраза уже закрыта паузой, так что обычно идём к модели сразу. Ждём, только если
            // человек уже продолжил говорить: возможно, он сам отвечает на свой вопрос
            while (_pipeline?.AnyoneSpeaking == true && (DateTime.UtcNow - since).TotalSeconds < 4)
            {
                await Task.Delay(150);
                if (cts.IsCancellationRequested) return;
            }
            if (cts.IsCancellationRequested || Detecting) return;
            _candidateSince = null;
            Detecting = true;
            try { await Detect(); } finally { Detecting = false; }
            if (_candidateSince is not null) ConsiderDetect("");
        }
    }

    public const string QuestionPrompt = """
        Ты ассистент на встрече. Тебе дают расшифровку разговора — она автоматическая, в ней бывают ошибки. «Я» — владелец приложения, остальные подписи — другие участники.
        В блоке «Новые реплики» определи, есть ли ПРЯМОЙ вопрос или просьба, на которые говорящий на самом деле ждёт ответа от другого человека.
        Сначала определи тип:
        - прямой — вопрос или просьба обращены к собеседнику, и ответа пока нет;
        - риторический — вопрос ради эффекта, ответа не ждут («ну кто так делает?»);
        - сам ответил — говорящий тут же сам на него отвечает («и что я сделал? а сделал я вот что…»);
        - в воздух — размышление вслух, ни к кому не обращено, или говорящий сам от него отмахнулся;
        - пустой — «алло», «слышно?», «да?», «понятно?», обрывок без смысла;
        - нет — вопросов и просьб в новых репликах нет.
        Если в новых репликах несколько вопросов, бери последний прямой. Вопросы из блока «Контекст» не бери — они уже обработаны.
        Первая строка ответа всегда: ТИП: <тип>
        Если тип не «прямой», больше ничего не пиши. Если «прямой», добавь ровно пять строк, без пояснений и разметки:
        ВОПРОС: сам вопрос одной чёткой фразой; восстанови из контекста, о чём спрашивают (без «это», «там», «он»)
        КОМУ: имя человека, к которому обратились по имени в реплике с вопросом; если имени не называли — поставь -
        КТО: кто задал вопрос — так, как он подписан в диалоге
        ТЕМА: о чём сейчас разговор, 3–6 слов
        ПОДРОБНО: 1–2 предложения: что обсуждали прямо перед вопросом и что нужно помнить, чтобы ответить
        Не выдумывай имён и фактов.
        """;

    private string QuestionSystem()
    {
        var system = QuestionPrompt;
        var names = Glossary.Trim();
        if (names.Length > 0) system += $"\nИмена и термины, которые могут встречаться: {names}";
        var me = MyName.Trim();
        if (me.Length > 0) system += $"\nВладельца приложения зовут: {me}. Если в реплике с вопросом обращаются к нему по имени или фамилии — в строке КОМУ напиши это имя.";
        return system;
    }

    private async Task Detect()
    {
        long id = RecordingId != 0 ? RecordingId : Selected?.Id ?? 0;
        if (id == 0 || Turns.Count == 0) return;
        var lastTurn = Turns[^1];
        // Делим хвост разговора на уже проверенное («Контекст») и новое: вопрос ищем только в новом.
        // Окно сдвигаем не на каждой реплике, а шагами по шесть: начало запроса тогда совпадает с прошлым,
        // и модель не перечитывает его заново — на процессоре это главная экономия времени
        var ctx = new List<string>();
        var fresh = new List<string>();
        int from = Turns.Count <= 13 ? 0 : (Turns.Count - 8) / 6 * 6;
        for (int i = from; i < Turns.Count; i++)
        {
            var t = Turns[i];
            if (t.Id < _examinedTurnId) ctx.Add($"{t.Label}: {t.Text}");
            else if (t.Id == _examinedTurnId)
            {
                int cut = Math.Min(_examinedLen, t.Text.Length);
                var old = t.Text[..cut].Trim();
                var neu = t.Text[cut..].Trim();
                if (old.Length > 0) ctx.Add($"{t.Label}: {old}");
                if (neu.Length > 0) fresh.Add($"{t.Label}: {neu}");
            }
            else fresh.Add($"{t.Label}: {t.Text}");
        }
        if (fresh.Count == 0) return;
        long markId = lastTurn.Id;
        int markLen = lastTurn.Text.Length;
        var phraseEnd = _lastPhraseEnd;
        var freshText = string.Join(" ", fresh);
        var user = "Контекст:\n" + (ctx.Count == 0 ? "(пусто)" : string.Join("\n", ctx)) + "\n\nНовые реплики:\n" + string.Join("\n", fresh);
        var me = MyName.Trim();

        var acc = new StringBuilder();
        Question? q = null;
        bool decided = false;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        double firstToken = 0;
        string? Field(string key)
        {
            var s = acc.ToString();
            int i = s.IndexOf(key + ": ", StringComparison.Ordinal);
            if (i < 0) return null;
            i += key.Length + 2;
            int j = s.IndexOf('\n', i);
            return (j < 0 ? s[i..] : s[i..j]).Trim();
        }
        try
        {
            await foreach (var piece in _llm.ChatStream([new("system", QuestionSystem()), new("user", user)], 240, 0.1))
            {
                if (firstToken == 0) firstToken = sw.Elapsed.TotalSeconds;
                acc.Append(piece);
                var s = acc.ToString();
                // Первая строка — тип. Показываем только прямые вопросы, на которые ждут ответа
                if (!s.Contains('\n')) continue;
                if (Field("ТИП") is not { } type || !type.ToLowerInvariant().StartsWith("прям")) break;
                if (!decided)
                {
                    PendingQuestion = Field("ВОПРОС") ?? "";
                    if (!s.Contains("\nКОМУ:") || Field("ВОПРОС") is not { Length: > 3 } text) continue;
                    decided = true;
                    PendingQuestion = "";
                    text = char.ToUpper(text[0]) + text[1..];
                    if (!".?!…".Contains(text[^1])) text += "?";
                    // Уже показанный вопрос не трогаем: карточка не должна прыгать и переписываться
                    if (Questions.Take(6).Any(x => TextTools.Similarity(x.Text, text) > 0.55)) break;
                    q = new Question { MeetingId = id, Ts = DateTime.Now, Text = text, Big = true };
                    _store.AddQuestion(q);
                    foreach (var old in Questions) old.Big = false;
                    Questions.Insert(0, q);
                    Count("questions");
                    // Главный замер: сколько прошло от конца фразы до появления вопроса на экране
                    double sincePhrase = (DateTime.UtcNow - phraseEnd).TotalSeconds;
                    _cardDelay.Add(sincePhrase);
                    _diagLast = $"{Models.ChatTitle}: первый токен {firstToken:0.00} с, вопрос готов через {sw.Elapsed.TotalSeconds:0.00} с; от конца фразы до карточки {sincePhrase:0.00} с";
                }
                if (q is null) continue;
                if (Field("КОМУ") is { } whom && s.Contains("\nКТО:"))
                {
                    q.Addressee = IsNameFrom(whom, freshText) ? whom.Trim().TrimEnd('.', ',') : "";
                    // Вопрос к владельцу: имя назвала модель или оно прямо прозвучало в новых репликах
                    if (!q.ForMe && (IsMyName(q.Addressee) || (q.Addressee.Length == 0 && IsMyName(freshText))))
                    {
                        q.ForMe = true;
                        Count("questions_me");
                        if (q.Addressee.Length == 0) q.Addressee = me.Split(',', ' ')[0];
                        Notify?.Invoke("Вопрос к вам", q.Text);
                    }
                }
                if (Field("КТО") is { } who && s.Contains("\nТЕМА:")) q.Asker = who;
                if (Field("ТЕМА") is { } topic) q.Topic = topic;
                if (Field("ПОДРОБНО") is { } detail) q.Context = detail;
            }
            if (q is not null) _store.Update(q);
        }
        catch (Exception ex) { Log("поиск вопроса: " + ex.Message); }
        PendingQuestion = "";
        _examinedTurnId = markId;
        _examinedLen = markLen;
    }

    /// <summary>
    /// Имя адресата принимаем, только если оно действительно прозвучало в новых репликах:
    /// маленькие модели любят подставлять сюда «Собеседник», «Я» или что-нибудь из контекста.
    /// </summary>
    private static bool IsNameFrom(string whom, string said)
    {
        var w = whom.Trim().TrimEnd('.', ',');
        if (w.Length < 2 || w == Speaker.Me || w.Contains("обеседник") || w.Contains("ладелец") || w.StartsWith("Голос")) return false;
        var stem = w.Split(' ')[0].ToLowerInvariant();
        stem = stem[..Math.Min(3, stem.Length)];
        // В начале реплики стоит подпись говорящего — её за имя не считаем
        return Regex.Split(said.ToLowerInvariant(), @"[^\p{L}]+").Any(x => x.Length >= 2 && x.StartsWith(stem) && x != "собеседник" && x != "голос");
    }

    /// <summary>Подсказка к ответу: ищем по базе прошлых встреч и по текущему разговору.</summary>
    public async Task SuggestAnswer(Question q)
    {
        if (!LlmReady || Answering) return;
        Answering = true;
        try
        {
            var found = (await Retrieve(q.Text, 5)).Select(x => x.Text).ToList();
            var user = new StringBuilder($"Вопрос: {q.Text}\n");
            if (q.Topic.Length > 0) user.Append($"Тема: {q.Topic}\n");
            if (q.Context.Length > 0) user.Append($"Контекст: {q.Context}\n");
            user.Append("\nТекущий разговор:\n" + TranscriptTail(20));
            if (found.Count > 0) user.Append("\n\nИз базы знаний и прошлых встреч:\n" + string.Join("\n---\n", found));
            const string system = "Ты подсказываешь владельцу приложения, что ответить на вопрос во время встречи. Дай короткую подсказку на русском: 2–4 предложения или пара пунктов. Опирайся только на данные ниже; если данных не хватает, честно скажи, чего не хватает.";
            var acc = new StringBuilder();
            await foreach (var piece in _llm.ChatStream([new("system", system), new("user", user.ToString())], 350))
            {
                acc.Append(piece);
                q.Answer = TextTools.Tidy(acc.ToString());
            }
            _store.Update(q);
        }
        catch (Exception ex) { ErrorText = ex.Message; }
        finally { Answering = false; }
    }

    private string TranscriptTail(int n, int maxChars = 2400)
    {
        var lines = Turns.Skip(Math.Max(0, Turns.Count - n)).Select(t => $"{t.Label}: {t.Text}").ToList();
        while (string.Join("\n", lines).Length > maxChars && lines.Count > 3) lines.RemoveAt(0);
        return string.Join("\n", lines);
    }

    private string Transcript(long meetingId)
    {
        var names = _store.VoiceNames(meetingId);
        return string.Join("\n", _store.Turns(meetingId).Select(t => $"{LabelOf(t, names)}: {t.Text}"));
    }
}
