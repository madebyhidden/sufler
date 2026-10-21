using System.Collections.ObjectModel;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Sufler;

/// <summary>
/// Режим собеседований: подготовка по вакансии и резюме, карта вопросов, разбор ответов прямо во время разговора,
/// итоговая оценка с матрицей компетенций и база вакансий и резюме. Та же логика и те же промпты, что на Mac.
/// </summary>
public sealed partial class AppCore
{
    // MARK: Режим

    /// <summary>"classic" — суфлёр встреч, "interview" — суфлёр собеседований.</summary>
    public string AppMode
    {
        get => Settings.Get("appMode", "classic");
        set { Settings.Set("appMode", value); Raise(); Raise(nameof(InterviewMode)); }
    }
    public bool InterviewMode => AppMode == "interview";

    private InterviewData? _interview;
    private bool _preparing, _evaluating, _probing;
    private string _prepNote = "", _evalNote = "", _deepStatus = "";
    /// <summary>Подготовка, карта, разборы и оценка открытого собеседования.</summary>
    public InterviewData? Interview { get => _interview; private set => Set(ref _interview, value); }
    public bool Preparing { get => _preparing; private set => Set(ref _preparing, value); }
    public string PrepNote { get => _prepNote; private set => Set(ref _prepNote, value); }
    public bool Evaluating { get => _evaluating; private set => Set(ref _evaluating, value); }
    public string EvalNote { get => _evalNote; private set => Set(ref _evalNote, value); }
    public bool Probing { get => _probing; private set => Set(ref _probing, value); }
    public string DeepStatus { get => _deepStatus; private set => Set(ref _deepStatus, value); }

    /// <summary>Собеседование открыто, но ещё не начиналось — показываем подготовку.</summary>
    public bool InterviewPrep => Selected is { IsInterview: true } && Turns.Count == 0 && !SelectedIsRecording;

    private CancellationTokenSource? _interviewSave, _probeRun;

    /// <summary>Сменили режим в настройках: открываем то, что относится к новому режиму.</summary>
    public void ModeChanged()
    {
        Raise(nameof(InterviewMode));
        if (Selected is { } s && s.IsInterview != InterviewMode) Select(Meetings.FirstOrDefault(m => m.IsInterview == InterviewMode));
        if (InterviewMode) RefreshLibrary();
    }

    private void LoadInterview(Meeting? m)
    {
        _probeRun?.Cancel();
        Interview = m is { IsInterview: true } ? _store.Interview(m.Id) ?? new InterviewData { MeetingId = m.Id } : null;
    }

    /// <summary>Новое собеседование: сначала подготовка, запись — потом, кнопкой.</summary>
    public void NewInterview()
    {
        if (IsRecording) return;
        var m = _store.CreateMeeting("Собеседование " + DateTime.Now.ToString("d MMMM, HH:mm", Ru.Culture), "interview");
        Meetings.Insert(0, m);
        Select(m);
    }

    /// <summary>Правка собеседования: сохраняем с задержкой, чтобы не писать в базу на каждую букву.</summary>
    public void EditInterview(Action<InterviewData> change)
    {
        if (Interview is not { } iv) return;
        change(iv);
        _interviewSave?.Cancel();
        var cts = _interviewSave = new CancellationTokenSource();
        _ = Task.Delay(400, cts.Token).ContinueWith(t => { if (!t.IsCanceled) Post(() => _store.SaveInterview(iv)); });
    }

    private void SaveInterviewNow()
    {
        _interviewSave?.Cancel();
        if (Interview is { } iv) _store.SaveInterview(iv);
    }

    public void SetCandidate(string name)
    {
        EditInterview(iv => iv.Candidate = name);
        var n = name.Trim();
        if (Selected is { IsInterview: true } m && m.Title.StartsWith("Собеседование") && n.Length > 0)
        {
            m.Title = "Собеседование: " + n;
            _store.Update(m);
        }
    }

    public void TogglePlanQuestion(PlanQuestion q)
    {
        q.Asked = !q.Asked;
        if (q.Asked) q.Skipped = false;
        EditInterview(_ => { });
        Raise(nameof(NextPlanQuestion));
    }

    public void SkipPlanQuestion(PlanQuestion q)
    {
        q.Skipped = true;
        EditInterview(_ => { });
        Raise(nameof(NextPlanQuestion));
    }

    /// <summary>Следующий вопрос, который стоит задать: обязательные, кейсы, про человека, с подковыркой.</summary>
    public PlanQuestion? NextPlanQuestion
    {
        get
        {
            var open = Interview?.Plan?.Questions.Where(q => !q.Asked && !q.Skipped).ToList() ?? [];
            foreach (var k in Verdicts.PlanKinds) if (open.FirstOrDefault(q => q.Kind == k) is { } q) return q;
            return null;
        }
    }

    public void MarkProbe(Probe p, bool used)
    {
        if (used) p.Used = true; else p.Dismissed = true;
        EditInterview(_ => { });
    }

    /// <summary>Кандидат — любой голос, кроме владельца: звук звонка или другой человек у того же микрофона.</summary>
    public static bool IsCandidate(Turn t) => t.Speaker == Speaker.Them || t.VoiceKey != 0;

    /// <summary>Доля речи кандидата: если интервьюер говорит больше — что-то идёт не так.</summary>
    public double? TalkShare
    {
        get
        {
            int me = 0, them = 0;
            foreach (var t in Turns) if (IsCandidate(t)) them += t.Text.Length; else me += t.Text.Length;
            return me + them > 200 ? (double)them / (me + them) : null;
        }
    }

    /// <summary>Владение темой по последним ответам: свежие весят больше.</summary>
    public double? Mastery
    {
        get
        {
            var xs = (Interview?.Probes ?? []).Where(p => p.Mastery is not null).Select(p => p.Mastery!.Value).TakeLast(5).ToList();
            if (xs.Count == 0) return null;
            double sum = 0, w = 0;
            for (int i = 0; i < xs.Count; i++) { sum += xs[i] * (i + 1); w += i + 1; }
            return sum / w;
        }
    }

    // MARK: Как отвечал: паузы, темп, «ээ»

    /// Когда кандидат начал говорить реплику и сколько секунд речи в ней — для маркеров «долго думал», «медленно говорит».
    private readonly Dictionary<long, DateTime> _turnStarts = new();
    private readonly Dictionary<long, double> _turnSpeech = new();

    private void NoteSpeech(Turn t, int samples, bool created)
    {
        double seconds = samples / 16000.0;
        if (created) _turnStarts[t.Id] = DateTime.Now.AddSeconds(-seconds);
        _turnSpeech[t.Id] = _turnSpeech.GetValueOrDefault(t.Id) + seconds;
    }

    private static readonly HashSet<string> FillerWords = ["э", "ээ", "эээ", "эм", "эмм", "ммм", "мм", "ну", "типа", "короче", "вот", "значит", "блин"];

    /// <summary>Как кандидат отвечал: пауза после вопроса, темп и слова-паразиты. Считается по самой речи, без модели.</summary>
    private AnswerStats Stats(List<Turn> question, List<Turn> answer)
    {
        var text = string.Join(" ", answer.Select(t => t.Text)).ToLowerInvariant();
        var words = Regex.Split(text, @"[^\p{L}\p{N}]+").Where(w => w.Length > 0).ToList();
        double fill = words.Count(FillerWords.Contains) + Regex.Matches(text, "как бы").Count;
        double speech = answer.Sum(t => _turnSpeech.GetValueOrDefault(t.Id));
        double? latency = question.Count > 0 && _turnStarts.TryGetValue(answer[0].Id, out var start) ? Math.Max(0, (start - question[^1].Ts).TotalSeconds) : null;
        return new AnswerStats
        {
            Latency = latency, Words = words.Count, Fillers = words.Count == 0 ? 0 : fill * 100 / words.Count,
            Pace = speech > 2 ? words.Count / speech : null,
        };
    }

    /// <summary>Похоже, что кандидат подсматривает в нейросеть: по оценкам модели и по поведению (долгая пауза → гладкий ответ без «ээ»).</summary>
    public (double Score, List<string> Reasons)? AiSuspicion
    {
        get
        {
            var ps = (Interview?.Probes ?? []).Where(p => p.Ai is not null).TakeLast(4).ToList();
            if (ps.Count < 2) return null;
            double score = ps.Average(p => p.Ai!.Value);
            int smooth = ps.Count(p => p.Stats is { Fillers: < 1, Words: >= 50 } st && (st.Latency ?? 0) >= 6);
            score += (double)smooth / ps.Count;
            var reasons = ps.Where(p => p.Ai >= 2 && p.AiWhy.Length > 0).Select(p => p.AiWhy).ToList();
            if (smooth > 0) reasons.Insert(0, $"долгая пауза перед гладким ответом без «ээ» — {smooth} из {ps.Count}");
            return (Math.Min(3, score), reasons.Distinct().Take(4).ToList());
        }
    }

    // MARK: Глубокая модель

    public const string Deep = "gemma-4-26B-A4B-it-Q4_0.gguf";
    public const string DeepDraft = "mtp-gemma-4-26B-A4B-it-Q4_0.gguf";
    private readonly LlamaServer _deepServer = new();
    private readonly LlmClient _deepLlm = new();

    public static List<ModelItem> DeepItems() =>
    [
        new() { File = Deep, Title = "Gemma 4 26B", Note = "Карта вопросов и оценка кандидата", Size = 14_618_145_824,
                Url = "https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF/resolve/main/" + Deep },
        new() { File = DeepDraft, Title = "Ускоритель Gemma 26B", Note = "Ускоряет глубокую модель", Size = 251_939_520,
                Url = "https://huggingface.co/ggml-org/gemma-4-26B-A4B-it-GGUF/resolve/main/" + DeepDraft, Minor = true },
    ];

    /// <summary>Глубокой модели нужна видеокарта или много памяти: она весит почти 15 ГБ.</summary>
    public static bool DeepFits => (Machine.Discrete && Machine.RamGb >= 15) || Machine.RamGb >= 30;
    public bool DeepReady => Models.IsReady(DeepItems()[0]);

    private bool _deepDownloading;
    private double _deepProgress;
    public bool DeepDownloading { get => _deepDownloading; private set => Set(ref _deepDownloading, value); }
    public double DeepProgress { get => _deepProgress; private set => Set(ref _deepProgress, value); }

    public async Task DownloadDeep()
    {
        if (DeepDownloading) return;
        DeepDownloading = true;
        try
        {
            using var http = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            var items = DeepItems().Where(m => !Models.IsReady(m)).ToList();
            long total = items.Sum(m => m.Size), done = 0;
            foreach (var m in items)
            {
                long before = done;
                m.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(ModelItem.Progress)) Post(() => DeepProgress = total > 0 ? (before + m.Size * m.Progress) / total : 0); };
                await Task.Run(() => Models.Download(m, http, CancellationToken.None));
                done += m.Size;
            }
            DeepProgress = 1;
        }
        catch (Exception ex) { ErrorText = "Не удалось скачать Gemma 4 26B: " + ex.Message + ". Нажмите «Скачать» ещё раз — загрузка продолжится."; }
        finally { DeepDownloading = false; Raise(nameof(DeepReady)); }
    }

    /// <summary>
    /// Работа на глубокой модели: подготовка карты и итоговая оценка. Две модели вместе не помещаются даже в 16 ГБ видеопамяти,
    /// поэтому основную на это время выгружаем, а после — поднимаем обратно. Во время собеседования 26B в памяти нет.
    /// Если глубокой модели нет или она не влезает — работаем на основной.
    /// </summary>
    private async Task RunDeep(Func<LlmClient, bool, Task> work)
    {
        if (!DeepFits || !DeepReady || !File.Exists(Models.LlamaExe)) { await work(_llm, false); return; }
        await _bootGate.WaitAsync();
        bool unloaded = false;
        try
        {
            unloaded = Machine.Discrete ? Machine.VramGb < 24 : Machine.RamGb < 40;
            if (unloaded)
            {
                _chatServer.Dispose();
                LlmReady = false;
                LlmStatus = "Основная модель уступила место Gemma 26B";
            }
            DeepStatus = "Загружаю Gemma 4 26B…";
            // --fit сам решает, сколько слоёв положить на видеокарту, а что оставить в памяти: экспертов MoE
            // выгоднее держать на процессоре, чем не запуститься вовсе
            var args = "-fit on -c 16384 -np 1 --reasoning-budget 0 --jinja";
            if (Machine.Discrete && Models.Has(DeepDraft)) args += $" --spec-draft-model \"{Models.PathOf(DeepDraft)}\" --spec-type draft-mtp";
            bool deep;
            try
            {
                await _deepServer.Start(Models.LlamaExe, Models.PathOf(Deep), args, Path.Combine(Models.Root, "llama-deep.log"));
                _deepLlm.ChatUrl = _deepLlm.EmbedUrl = _deepServer.BaseUrl;
                DeepStatus = "Gemma 4 26B думает…";
                deep = true;
            }
            catch (Exception ex)
            {
                Log("глубокая модель: " + ex.Message);
                _deepServer.Dispose();
                DeepStatus = "Gemma 26B не запустилась — работаю на основной";
                if (unloaded) { await RestartChat(); unloaded = false; }
                deep = false;
            }
            await work(deep ? _deepLlm : _llm, deep);
        }
        finally
        {
            _deepServer.Dispose();
            if (unloaded) await RestartChat();
            if (!DeepStatus.Contains("не запустилась")) DeepStatus = "";
            _bootGate.Release();
        }
    }

    private async Task RestartChat()
    {
        LlmStatus = $"Загружаю {Models.ChatTitle}…";
        try
        {
            await StartChatOnBestDevice();
            _llm.ChatUrl = _chatServer.BaseUrl;
            if (!EmbedReady) _llm.EmbedUrl = _chatServer.BaseUrl;
            LlmReady = true;
            LlmStatus = Models.ChatTitle;
        }
        catch (Exception ex)
        {
            Log("языковая модель после 26B: " + ex);
            LlmStatus = "Языковая модель не запустилась";
            LlmFailed = true;
        }
    }

    // MARK: Подготовка: карта вопросов

    public const string PrepPrompt = """
        Ты — опытный интервьюер и HR-партнёр. Готовишь карту вопросов к собеседованию по описанию вакансии и резюме кандидата.
        Важно: резюме и требования вакансии часто не совпадают — это нормально. Не делай на расхождениях акцент, не строй вопросов в духе «почему у вас нет X». Задача — на практике проверить, справится ли человек с тем, что требует вакансия, опираясь на его реальный опыт.
        Собери:
        - requirements — 5–10 ключевых требований вакансии, каждое в 2–6 словах;
        - brief — кто перед нами по резюме: 3–4 коротких предложения (опыт, уровень, сильные стороны), без оценок;
        - focus — 3–6 пунктов, что стоит проверить особенно: громкие заявленные достижения, неясности, места, где нужен личный вклад и цифры;
        - questions — вопросы четырёх видов:
          • must — 8–12 обязательных: по каждому ключевому требованию хотя бы один, через реальный опыт («расскажите, как вы…», «какой был последний случай, когда…»);
          • person — 5–7 вопросов, чтобы понять, что за человек: мотивация, ценности, отношение к ошибкам, конфликтам, ответственности, обратной связи. Они должны звучать как обычные рабочие вопросы — истинную цель кандидат не должен угадать; её пиши в purpose;
          • case — 1–2 кейса на бизнес-логику: живая задача из области вакансии, которую кандидат решает вслух («Спроектируйте агента-шоппера для маркетплейса: как будете его делать?», «Продажи в регионе упали на 20% — с чего начнёте?»). Кейс открытый, без единственного правильного ответа: проверяем, как человек думает, — уточняет ли цель и пользователя, раскладывает ли задачу на части, думает ли о метриках успеха, рисках, крайних случаях, стоимости и компромиссах, предлагает ли простой первый шаг. В listen перечисли, что отличает сильное решение;
          • tricky — 4–6 с подковыркой: проверка глубины и честности — «а что бы вы сделали иначе», просьба посчитать или разобрать кейс-ловушку, личный вклад в заявленное достижение, вопрос, где правильный ответ — «не знаю» или «зависит от». Без унижения и подвохов ради подвохов.
        Для каждого вопроса: text — сам вопрос, как его произнести, по-русски, естественно; purpose — что на самом деле проверяем; listen — что хотим услышать в сильном ответе и какие тревожные сигналы; requirement — к какому требованию относится (или пустая строка).
        """;

    private static readonly JsonNode PrepSchema = Schema("""
        {"type":"object","properties":{
          "requirements":{"type":"array","items":{"type":"string"}},
          "brief":{"type":"string"},
          "focus":{"type":"array","items":{"type":"string"}},
          "questions":{"type":"array","items":{"type":"object","properties":{
            "kind":{"type":"string","enum":["must","case","person","tricky"]},
            "text":{"type":"string"},"purpose":{"type":"string"},"listen":{"type":"string"},"requirement":{"type":"string"}},
            "required":["kind","text","purpose","listen","requirement"],"additionalProperties":false}}},
         "required":["requirements","brief","focus","questions"],"additionalProperties":false}
        """);

    public async Task BuildPlan()
    {
        if (Interview is not { } iv || Preparing) return;
        var vacancy = iv.Vacancy.Trim();
        var resume = iv.Resume.Trim();
        if (vacancy.Length == 0 && resume.Length == 0) { ErrorText = "Добавьте описание вакансии или резюме — по ним собирается карта вопросов."; return; }
        if (!LlmReady && !(DeepFits && DeepReady)) { ErrorText = "Языковая модель ещё загружается."; return; }
        SaveInterviewToLibrary();
        Preparing = true;
        PrepNote = "Готовлю модель…";
        long mid = iv.MeetingId;
        try
        {
            var user = "Вакансия:\n" + (vacancy.Length == 0 ? "(не указана — опирайся на резюме)" : TextTools.Head(vacancy, 14000));
            user += "\n\nРезюме кандидата:\n" + (resume.Length == 0 ? "(нет — составь вопросы по вакансии)" : TextTools.Head(resume, 14000));
            if (iv.Notes.Trim().Length > 0) user += "\n\nАкценты интервьюера:\n" + iv.Notes;
            InterviewPlan? plan = null;
            await RunDeep(async (llm, deep) =>
            {
                PrepNote = deep ? "Gemma 26B собирает карту вопросов…" : "Собираю карту вопросов…";
                var raw = await llm.Chat([new("system", PrepPrompt), new("user", user)], PrepSchema, 6000, 0.4);
                plan = ParsePlan(raw);
                if (plan is not null) plan.Deep = deep;
            });
            if (plan is null) { ErrorText = "Модель вернула неполную карту — попробуйте ещё раз."; return; }
            if (Interview?.MeetingId == mid) { Interview.Plan = plan; SaveInterviewNow(); Raise(nameof(NextPlanQuestion)); }
            else if (_store.Interview(mid) is { } other) { other.Plan = plan; _store.SaveInterview(other); }
        }
        catch (Exception ex) { ErrorText = "Не удалось собрать карту: " + ex.Message; }
        finally { Preparing = false; PrepNote = ""; }
    }

    private static InterviewPlan? ParsePlan(string raw)
    {
        try
        {
            var o = JsonNode.Parse(raw)!;
            var plan = new InterviewPlan
            {
                Requirements = Strings(o["requirements"]),
                Brief = (string?)o["brief"] ?? "",
                Focus = Strings(o["focus"]),
            };
            foreach (var q in o["questions"]?.AsArray() ?? [])
            {
                var text = ((string?)q?["text"] ?? "").Trim();
                if (text.Length == 0) continue;
                plan.Questions.Add(new PlanQuestion
                {
                    Kind = (string?)q!["kind"] ?? "must", Text = text, Purpose = (string?)q["purpose"] ?? "",
                    Listen = (string?)q["listen"] ?? "", Requirement = (string?)q["requirement"] ?? "",
                });
            }
            return plan.Questions.Count > 0 ? plan : null;
        }
        catch { return null; }
    }

    private static List<string> Strings(JsonNode? n) => n?.AsArray().Select(x => ((string?)x ?? "").Trim()).Where(x => x.Length > 0).ToList() ?? [];

    // MARK: Во время собеседования: доуточнения

    /// <summary>Сколько тишины ждать после фразы кандидата. Живой человек делает паузы посреди мысли: оборвался
    /// на «и…», «потому что…», «ну», запятой — ждём дольше; закончил мысль — показываем быстро.</summary>
    public static double PauseNeeded(string text)
    {
        var t = text.Trim().ToLowerInvariant();
        if (t.EndsWith(',') || t.EndsWith('…') || t.EndsWith("...") || t.EndsWith('-') || t.EndsWith('—')) return 2.4;
        var last = Regex.Split(t, @"[^\p{L}]+").LastOrDefault(w => w.Length > 0) ?? "";
        string[] hanging = ["и", "а", "но", "или", "что", "чтобы", "потому", "поэтому", "который", "которая", "которые", "которое", "если", "когда", "как", "это", "то", "ну", "вот", "типа", "значит", "в", "на", "с", "по", "для", "из", "к", "у", "о", "от", "при", "мы", "я", "он", "там", "тоже", "также"];
        string[] fillers = ["э", "ээ", "эээ", "эм", "эмм", "ммм", "мм", "м", "ам", "хм"];
        if (hanging.Contains(last) || fillers.Contains(last)) return 2.4;
        if (t.EndsWith('.') || t.EndsWith('?') || t.EndsWith('!')) return 0.6;
        return 1.0;
    }

    /// <summary>Последний обмен: подряд идущие реплики интервьюера и всё, что кандидат сказал после.</summary>
    public static (List<Turn> Question, List<Turn> Answer) LastExchange(IReadOnlyList<Turn> turns)
    {
        var answer = new List<Turn>();
        var question = new List<Turn>();
        for (int i = turns.Count - 1; i >= 0; i--)
        {
            var t = turns[i];
            if (IsCandidate(t)) { if (question.Count == 0) answer.Insert(0, t); else break; }
            else question.Insert(0, t);
            if (question.Count >= 3) break;
        }
        return (question, answer);
    }

    /// <summary>
    /// Разбор начинаем сразу, как только фраза кандидата распознана, — модель думает, пока мы ждём паузу.
    /// Заговорил снова — разбор отменяется и начинается заново по всему ответу.
    /// </summary>
    private void ConsiderProbe()
    {
        if (!LlmReady || Interview is not { } iv || Turns.Count == 0 || !IsCandidate(Turns[^1])) return;
        var (question, answer) = LastExchange(Turns);
        if (question.Count == 0 || answer.Count == 0) return;
        var answerText = string.Join(" ", answer.Select(t => t.Text));
        if (answerText.Length < 60) return;
        var questionText = string.Join(" ", question.Select(t => t.Text));
        long qid = question[0].Id;
        var stats = Stats(question, answer);
        var user = ProbeRequest(iv, questionText, answerText, qid) + "\nКак отвечал: " + stats.Line;
        double pause = PauseNeeded(Turns[^1].Text);
        _probeRun?.Cancel();
        var cts = _probeRun = new CancellationTokenSource();
        _ = Run();

        async Task Run()
        {
            Probing = true;
            var acc = new StringBuilder();
            bool done = false;
            _ = Generate();
            // Фраза уже закрыта паузой распознавания — её тоже засчитываем
            double quiet = 0.4;
            bool shown = false, drafted = false;
            try
            {
                while (!cts.IsCancellationRequested)
                {
                    await Task.Delay(100, cts.Token);
                    quiet = _pipeline?.AnyoneSpeaking == true ? 0 : quiet + 0.1;
                    var s = acc.ToString();
                    if (Interview != iv) break;
                    // Знакомство, прощание, «слышно?» — это не ответ, разбирать и оценивать нечего
                    if (IsSmallTalk(s)) { DropProbe(iv, qid); break; }
                    if (!done && !ProbeReady(s)) continue;
                    // Модель считает, что кандидат оборвался на полуслове, — даём ему договорить
                    bool unfinished = ProbeField(s, "ЗАКОНЧИЛ")?.ToLowerInvariant().StartsWith("нет") == true;
                    double need = unfinished ? Math.Max(pause, 3.0) : pause;
                    if (quiet < need && !shown)
                    {
                        // Уточнение уже готово — показываем черновиком, чтобы интервьюер видел его заранее
                        if (!drafted) { CommitProbe(iv, s, qid, questionText, stats, true, false); drafted = true; }
                        continue;
                    }
                    CommitProbe(iv, s, qid, questionText, stats, false, !shown);
                    shown = true;
                    if (done) break;
                }
            }
            catch (OperationCanceledException) { }
            finally { cts.Cancel(); if (_probeRun == cts) Probing = false; }

            async Task Generate()
            {
                try
                {
                    await foreach (var piece in _llm.ChatStream([new("system", ProbePrompt), new("user", user)], 260, 0.2, cts.Token)) acc.Append(piece);
                }
                catch { }
                done = true;
            }
        }
    }

    public const string ProbePrompt = """
        Ты подсказываешь интервьюеру на собеседовании. Расшифровка автоматическая, в ней бывают ошибки распознавания — не цепляйся к словам.
        Тебе дают требования вакансии, кратко о кандидате, карту вопросов с id, уже разобранные ответы, а также последний вопрос интервьюера и ответ кандидата.
        Ответь строками, без разметки и пояснений, в таком порядке:
        ТИП: ответ — кандидат отвечает по существу; светское — знакомство, приветствие, прощание, благодарность, «слышно ли меня», организационные моменты, рассказ интервьюера о компании или вопросы кандидата об условиях. Если светское — больше ничего не пиши.
        ОЦЕНКА: strong — конкретно, с примерами, цифрами и личным вкладом; ok — по делу, хватает; vague — общие слова, «мы делали», нет примера или своей роли; evasive — уходит от вопроса; contradiction — расходится с резюме или с тем, что он говорил раньше; red_flag — тревожный сигнал (перекладывает вину, неэтично, токсично о прошлой команде). Напиши одно слово.
        ЗАКОНЧИЛ: да — мысль завершена; нет — ответ оборвался на полуслове и кандидат явно собирается продолжить.
        ИИ: похоже ли, что кандидат зачитывает ответ нейросети или поиска, число 0–3 и через тире почему, 2–6 слов. 0 — живая речь: паузы, самоисправления, личные детали; 1 — гладко, но есть живое; 2 — книжные обороты, структура «во-первых… во-вторых», общие формулировки без своего опыта; 3 — явно читает текст: определения как из учебника, перечисления, ни одной личной детали. Учитывай строку «Как отвечал»: долгая пауза перед гладким ответом без «ээ» — тревожный знак. Живая речь не бывает идеальной.
        УТОЧНЕНИЕ: сам вопрос — ровно те слова, которые интервьюер произнесёт вслух кандидату, без пояснений для интервьюера. Если оценка vague, evasive, contradiction или red_flag — один уточняющий вопрос, который стоит задать прямо сейчас: короткий, естественный, без обвинений («А что именно делали лично вы?», «Сколько это было в цифрах?», «Вы говорили, что…, а сейчас…, как это сочетается?»). Если ИИ 2–3 — уточнение обязательно, даже при strong или ok: спроси про личный случай с деталями, которые нельзя подсмотреть («Когда это было у вас? Что пошло не так?»). Иначе, если strong или ok, — поставь -. Не дозадавай ради дозадавания.
        В ТЕМЕ: насколько кандидат владеет темой, число 0–5. 5 — свободно: объясняет, почему так, называет компромиссы и детали; 4 — уверенно; 3 — знает основы, но поверхностно; 2 — плавает: путается, перечисляет термины без объяснения, отвечает не на тот вопрос, много «ну… эм…», заученные фразы; 1 — почти не понимает; 0 — не знает. Оценивай понимание, а не красноречие.
        СУТЬ: суть ответа одним коротким предложением.
        ПОЧЕМУ: почему такая оценка, 3–8 слов, для интервьюера.
        ЗАКРЫТО: id вопросов из карты, на которые этот обмен по сути ответил, через запятую; если нет — -
        Будь строгим, как опытный нанимающий менеджер:
        - перечисление названий, терминов и этапов без объяснения, как это работает и почему так, — это vague, В ТЕМЕ не выше 2;
        - «мы сделали», «внедрили», «использовали» без своей роли, примера или цифры — vague;
        - strong и В ТЕМЕ 4–5 — только когда кандидат объясняет механику, компромиссы, ошибки или результат в цифрах;
        - ответ оборвался посередине — оценивай то, что уже сказано, а в ЗАКОНЧИЛ ставь нет.
        Каждая строка начинается со своего ключа, например «ОЦЕНКА: vague».
        """;

    public static readonly string[] ProbeKeys = ["ТИП", "ОЦЕНКА", "ЗАКОНЧИЛ", "ИИ", "УТОЧНЕНИЕ", "В ТЕМЕ", "СУТЬ", "ПОЧЕМУ", "ЗАКРЫТО"];

    /// <summary>Модель сочла обмен светской беседой: знакомство, прощание, организационное.</summary>
    public static bool IsSmallTalk(string acc) => ProbeField(acc, "ТИП")?.ToLowerInvariant().StartsWith("светск") == true;

    /// <summary>Значение строки ответа; строка должна быть уже дописана. Маленькая модель иногда пропускает «КЛЮЧ:»
    /// и пишет одни значения — тогда берём строку по порядку.</summary>
    public static string? ProbeField(string acc, string key)
    {
        int n = Array.IndexOf(ProbeKeys, key);
        if (n < 0) return null;
        var lines = acc.Split('\n').SkipLast(1).Select(l => l.Trim()).Where(l => l.Length > 0 && !l.StartsWith("```")).ToList();
        if (lines.FirstOrDefault(l => l.ToUpperInvariant().StartsWith(key + ":")) is { } keyed) return keyed[(key.Length + 1)..].Trim();
        if (n >= lines.Count) return null;
        var line = lines[n];
        if (ProbeKeys.Any(k => k != key && line.ToUpperInvariant().StartsWith(k + ":"))) return null;
        return line;
    }

    /// <summary>Уточнение уже можно показывать: дописаны ТИП, ОЦЕНКА, ЗАКОНЧИЛ, ИИ и УТОЧНЕНИЕ.</summary>
    public static bool ProbeReady(string acc) => acc.Split('\n').SkipLast(1).Count(l => l.Trim().Length > 0) >= 5;

    /// <summary>Кладёт разбор в собеседование. Вызывается, как только готово уточнение, и ещё раз — когда модель допишет остальное.</summary>
    /// <summary>Обмен оказался светской беседой — прежний разбор того же обмена (по первым фразам) убираем.</summary>
    private void DropProbe(InterviewData iv, long questionTurnId)
    {
        var p = iv.Probes.LastOrDefault(x => x.QuestionTurnId == questionTurnId);
        if (p is null) return;
        iv.Probes.Remove(p);
        EditInterview(_ => { });
        Raise(nameof(Mastery));
        Raise(nameof(AiSuspicion));
    }

    private void CommitProbe(InterviewData iv, string raw, long questionTurnId, string question, AnswerStats stats, bool draft, bool notify)
    {
        var acc = raw.EndsWith('\n') ? raw : raw + "\n";
        var word = Regex.Match((ProbeField(acc, "ОЦЕНКА") ?? "ok").ToLowerInvariant(), @"[a-z_]+").Value;
        string[] known = ["strong", "ok", "vague", "evasive", "contradiction", "red_flag"];
        var verdict = known.Contains(word) ? word : "ok";
        var follow = (ProbeField(acc, "УТОЧНЕНИЕ") ?? "").Trim(' ', '-', '—', '«', '»', '"');
        // Маленькая модель иногда начинает с пометки «ИИ 2 —» — отрезаем её
        follow = Regex.Replace(follow, @"^(ИИ|AI)\s*\d\s*[-—:]\s*", "");
        var aiLine = ProbeField(acc, "ИИ") ?? "";
        int? ai = aiLine.FirstOrDefault(char.IsDigit) is var ad and >= '0' and <= '9' ? Math.Clamp(ad - '0', 0, 3) : null;
        var aiWhy = aiLine.TrimStart('0', '1', '2', '3', ' ', '—', '-', ':').Trim();
        // Хороший ответ не дозадаём — кроме случая, когда он похож на зачитанный из нейросети
        if ((verdict is "strong" or "ok" && (ai ?? 0) < 2) || follow.Length < 8) follow = "";
        int? mastery = (ProbeField(acc, "В ТЕМЕ") ?? "").FirstOrDefault(char.IsDigit) is var c and >= '0' and <= '9' ? Math.Clamp(c - '0', 0, 5) : null;
        var covered = (ProbeField(acc, "ЗАКРЫТО") ?? "").Split([',', ' ', '[', ']'], StringSplitOptions.RemoveEmptyEntries)
            .Select(x => TextTools.Head(x, 8).ToUpperInvariant()).Where(x => x.Length >= 4).ToHashSet();

        // Кандидат продолжил тот же ответ — обновляем прежний разбор, а не плодим карточки
        var p = iv.Probes.LastOrDefault(x => x.QuestionTurnId == questionTurnId);
        bool isNew = p is null;
        // Черновик стал окончательным — это тоже «новое» уточнение для уведомления
        bool newFollowup = follow.Length > 0 && (follow != p?.Followup || p?.Draft == true);
        if (p is null)
        {
            p = new Probe { QuestionTurnId = questionTurnId, Question = question };
            iv.Probes.Add(p);
        }
        else if (newFollowup) { p.Used = false; p.Dismissed = false; }
        p.Verdict = verdict;
        p.Followup = follow;
        p.Gist = ProbeField(acc, "СУТЬ") ?? p.Gist;
        p.Reason = ProbeField(acc, "ПОЧЕМУ") ?? p.Reason;
        p.Mastery = mastery ?? p.Mastery;
        if (ai is not null) { p.Ai = ai; p.AiWhy = aiWhy; }
        p.Stats = stats;
        p.Draft = draft;
        foreach (var q in iv.Plan?.Questions ?? []) if (covered.Contains(q.Id.ToUpperInvariant()) && !q.Asked) q.Asked = true;
        EditInterview(_ => { });
        Raise(nameof(Mastery));
        Raise(nameof(AiSuspicion));
        Raise(nameof(NextPlanQuestion));
        if (isNew) Raise(nameof(Interview));
        if (notify && !draft && newFollowup) ProbeShown?.Invoke(p);
    }

    /// <summary>Новое уточнение появилось: оболочка может показать уведомление, если окно не на виду.</summary>
    public Action<Probe>? ProbeShown;

    /// <summary>Запрос к модели. Неизменная часть (требования, кандидат, вся карта) идёт первой — её llama-server держит в кэше,
    /// и каждый разбор пересчитывает только хвост с ответом.</summary>
    public static string ProbeRequest(InterviewData iv, string questionText, string answerText, long questionTurnId)
    {
        var user = new StringBuilder();
        if (iv.Plan is { } plan)
        {
            if (plan.Requirements.Count > 0) user.Append("Требования вакансии: " + string.Join("; ", plan.Requirements) + "\n");
            if (plan.Brief.Length > 0) user.Append("Кандидат по резюме: " + plan.Brief + "\n");
            if (plan.Questions.Count > 0) user.Append("\nКарта вопросов:\n" + string.Join("\n", plan.Questions.Take(30).Select(q => $"[{q.Id}] {q.Text}")) + "\n");
        }
        else if (iv.Vacancy.Length > 0) user.Append("Вакансия: " + TextTools.Head(iv.Vacancy, 1500) + "\n");
        var earlier = iv.Probes.Where(p => p.QuestionTurnId != questionTurnId).TakeLast(6).ToList();
        if (earlier.Count > 0) user.Append("\nРанее кандидат говорил:\n" + string.Join("\n", earlier.Select(p => "— " + p.Gist)) + "\n");
        user.Append("\nВопрос интервьюера: " + TextTools.Tail(questionText, 700) + "\nОтвет кандидата: " + TextTools.Tail(answerText, 2500));
        return user.ToString();
    }

    // MARK: После собеседования: оценка и матрица компетенций

    public const string EvalPrompt = """
        Ты — опытный нанимающий менеджер. По расшифровке собеседования оцени кандидата относительно требований вакансии. «Я» и голоса на стороне интервьюера — те, кто проводит собеседование; «Собеседник» — кандидат. Расшифровка автоматическая, с ошибками распознавания.
        Правила честной оценки:
        - Оценивай только по тому, что прозвучало. Нет доказательств — ставь низкую уверенность, а не низкий балл «на всякий случай».
        - Расхождения резюме и вакансии — не минус сами по себе; важно, что человек показал на собеседовании.
        - Не оценивай пол, возраст, внешность, акцент и прочее, не относящееся к работе.
        - Знакомство, приветствие, прощание, благодарности, «слышно ли меня», рассказ интервьюера о компании и вопросы кандидата об условиях — не ответы. Не ставь по ним баллы и не делай выводов: обычное прощание — это не минус.
        Верни:
        - competencies — 6–10 компетенций: по ключевым требованиям вакансии плюс 1–3 личностные (ответственность, коммуникация, обучаемость — что реально проявилось). name — 2–4 слова; requirement — к какому требованию относится; score 0–5 (0 — не проявлено, 1 — слабо, 2 — ниже ожиданий, 3 — соответствует, 4 — сильно, 5 — выдающееся); evidence — короткая опора из разговора, лучше близко к цитате; confidence — high, medium или low;
        - fit — соответствие требованиям вакансии в процентах, 0–100;
        - verdict — strong_yes, yes, maybe или no;
        - summary — 2–3 предложения итога для нанимающего менеджера;
        - portrait — психологический и рабочий портрет: как человек думает, как говорит о прошлых командах и ошибках, что его мотивирует, в какой среде раскроется и где будет трудно. 4–6 предложений, бережно и по делу;
        - strengths — 2–5 сильных сторон; risks — 2–5 рисков и тревожных сигналов;
        - mismatches — где сказанное расходится с резюме или само с собой (если нет — пусто), без драматизации;
        - nextSteps — 2–4 пункта: что проверить на следующем этапе или у рекомендателей;
        - integrity — самостоятельность ответов: признаки, что кандидат пользовался подсказками нейросети или поиска во время собеседования — долгие паузы перед гладкими книжными ответами без «ээ», ответы как из учебника без личного опыта, резкий контраст между отточенными ответами и тем, как он справляется с уточнениями. level — none, low, medium или high; signs — 0–4 коротких наблюдения. Не обвиняй — только наблюдения; живая неидеальная речь — это нормально;
        - business — бизнес-логика: как кандидат думает в рамках задачи — по кейсам («спроектируйте…», «как бы вы сделали…») и любым ответам, где он рассуждал о решении. Смотри: понял ли цель бизнеса и пользователя, задал ли уточняющие вопросы, разложил ли задачу на части, подумал ли о метриках успеха, рисках, крайних случаях, стоимости и компромиссах, предложил ли простой первый шаг. score 0–5; summary — 2–3 предложения; approach — 2–5 шагов, как он рассуждал; gaps — 1–4 пункта, что упустил; confidence — high, medium или low (low, если кейсов почти не было).
        Пиши на русском — все поля, включая названия компетенций и требований (не «Go & Highload», а «Go и высокие нагрузки»).
        """;

    private static readonly JsonNode EvalSchema = Schema("""
        {"type":"object","properties":{
          "competencies":{"type":"array","items":{"type":"object","properties":{
            "name":{"type":"string"},"requirement":{"type":"string"},"score":{"type":"integer"},"evidence":{"type":"string"},
            "confidence":{"type":"string","enum":["high","medium","low"]}},
            "required":["name","requirement","score","evidence","confidence"],"additionalProperties":false}},
          "fit":{"type":"integer"},
          "verdict":{"type":"string","enum":["strong_yes","yes","maybe","no"]},
          "summary":{"type":"string"},"portrait":{"type":"string"},
          "strengths":{"type":"array","items":{"type":"string"}},
          "risks":{"type":"array","items":{"type":"string"}},
          "mismatches":{"type":"array","items":{"type":"string"}},
          "nextSteps":{"type":"array","items":{"type":"string"}},
          "integrity":{"type":"object","properties":{"level":{"type":"string","enum":["none","low","medium","high"]},"signs":{"type":"array","items":{"type":"string"}}},
            "required":["level","signs"],"additionalProperties":false},
          "business":{"type":"object","properties":{
            "score":{"type":"integer"},"summary":{"type":"string"},
            "approach":{"type":"array","items":{"type":"string"}},
            "gaps":{"type":"array","items":{"type":"string"}},
            "confidence":{"type":"string","enum":["high","medium","low"]}},
            "required":["score","summary","approach","gaps","confidence"],"additionalProperties":false}},
         "required":["competencies","fit","verdict","summary","portrait","strengths","risks","mismatches","nextSteps","integrity","business"],"additionalProperties":false}
        """);

    public async Task EvaluateInterview(Meeting m)
    {
        if (Evaluating) return;
        var names = _store.VoiceNames(m.Id);
        var turns = _store.Turns(m.Id);
        if (turns.Count < 4) return;
        var iv = Interview?.MeetingId == m.Id ? Interview : _store.Interview(m.Id) ?? new InterviewData { MeetingId = m.Id };
        Evaluating = true;
        EvalNote = "Готовлю модель…";
        try
        {
            var text = string.Join("\n", turns.Select(t => $"{LabelOf(t, names)}: {t.Text}"));
            bool bigWindow = DeepFits && DeepReady;
            int budget = bigWindow ? 40000 : Math.Max(_budget * 2, 12000);
            // Совсем длинное собеседование сжимаем по частям основной моделью — до того, как её выгрузить
            if (text.Length > budget && LlmReady)
            {
                EvalNote = "Собеседование длинное — сжимаю расшифровку…";
                var digests = new List<string>();
                foreach (var part in TextTools.SplitLines(text, _budget))
                    digests.Add(await _llm.Chat([
                        new("system", "Сожми фрагмент расшифровки собеседования: вопросы интервьюера и суть ответов кандидата, с конкретикой, цифрами и показательными цитатами. На русском."),
                        new("user", part),
                    ], null, 700));
                text = string.Join("\n\n", digests);
            }
            var user = new StringBuilder();
            if (iv.Plan is { } plan)
            {
                if (plan.Requirements.Count > 0) user.Append("Требования вакансии:\n" + string.Join("\n", plan.Requirements.Select(r => "- " + r)) + "\n\n");
                if (plan.Brief.Length > 0) user.Append("Кандидат по резюме: " + plan.Brief + "\n\n");
            }
            else
            {
                if (iv.Vacancy.Length > 0) user.Append("Вакансия:\n" + TextTools.Head(iv.Vacancy, 6000) + "\n\n");
                if (iv.Resume.Length > 0) user.Append("Резюме:\n" + TextTools.Head(iv.Resume, 6000) + "\n\n");
            }
            // Как отвечал по ходу: паузы и похожесть на зачитанный текст — для блока самостоятельности
            var behaviour = iv.Probes.Where(p => p.Ai is not null || p.Stats is not null).Select(p =>
                "- " + TextTools.Head(p.Gist, 90) + (p.Stats is { } st ? $" ({st.Line})" : "") + (p.Ai is { } a ? $"; похоже на зачитанное: {a}/3" + (p.AiWhy.Length > 0 ? " — " + p.AiWhy : "") : "")).ToList();
            if (behaviour.Count > 0) user.Append("Как кандидат отвечал по ходу:\n" + string.Join("\n", behaviour) + "\n\n");
            var ms = iv.Probes.Where(p => p.Mastery is not null).Select(p => p.Mastery!.Value.ToString()).ToList();
            if (ms.Count > 0) user.Append("Владение темой по ответам (0–5): " + string.Join(", ", ms) + "\n\n");
            var flagged = iv.Probes.Where(p => p.Verdict is not ("ok" or "strong")).ToList();
            if (flagged.Count > 0) user.Append("Отметки по ходу собеседования:\n" + string.Join("\n", flagged.Select(p => $"- {Verdicts.Title(p.Verdict)}: {p.Gist}")) + "\n\n");
            if (m.Notes.Length > 0) user.Append("Заметки интервьюера:\n" + m.Notes + "\n\n");
            user.Append("Расшифровка собеседования:\n" + text);

            InterviewReport? report = null;
            await RunDeep(async (llm, deep) =>
            {
                EvalNote = deep ? "Gemma 26B оценивает кандидата…" : "Оцениваю кандидата…";
                var raw = await llm.Chat([new("system", EvalPrompt), new("user", user.ToString())], EvalSchema, 4000, 0.2);
                report = ParseReport(raw);
                if (report is not null) report.Deep = deep;
            });
            if (report is null) { ErrorText = "Модель вернула неполную оценку — нажмите «Пересобрать»."; return; }
            iv.Report = report;
            if (Interview == iv)
            {
                // Резюме вставляли вручную и карту не собирали — кандидат всё равно попадает в базу
                if (iv.ResumeId is null) SaveInterviewToLibrary();
                SaveInterviewNow();
            }
            else _store.SaveInterview(iv);
            RefreshLibrary();
        }
        catch (Exception ex) { ErrorText = "Не удалось оценить кандидата: " + ex.Message; }
        finally { Evaluating = false; EvalNote = ""; }
    }

    private static InterviewReport? ParseReport(string raw)
    {
        try
        {
            var o = JsonNode.Parse(raw)!;
            var r = new InterviewReport
            {
                Fit = Math.Clamp((int?)o["fit"] ?? 0, 0, 100), Verdict = (string?)o["verdict"] ?? "maybe",
                Summary = (string?)o["summary"] ?? "", Portrait = (string?)o["portrait"] ?? "",
                Strengths = Strings(o["strengths"]), Risks = Strings(o["risks"]), Mismatches = Strings(o["mismatches"]), NextSteps = Strings(o["nextSteps"]),
            };
            foreach (var c in o["competencies"]?.AsArray() ?? [])
                if (c is not null)
                    r.Competencies.Add(new Competency
                    {
                        Name = (string?)c["name"] ?? "", Requirement = (string?)c["requirement"] ?? "", Score = Math.Clamp((int?)c["score"] ?? 0, 0, 5),
                        Evidence = (string?)c["evidence"] ?? "", Confidence = (string?)c["confidence"] ?? "medium",
                    });
            if (o["integrity"] is { } ig) r.Integrity = new Integrity { Level = (string?)ig["level"] ?? "none", Signs = Strings(ig["signs"]) };
            if (o["business"] is { } b)
                r.Business = new BusinessThinking
                {
                    Score = Math.Clamp((int?)b["score"] ?? 0, 0, 5), Summary = (string?)b["summary"] ?? "",
                    Approach = Strings(b["approach"]), Gaps = Strings(b["gaps"]), Confidence = (string?)b["confidence"] ?? "medium",
                };
            return r.Competencies.Count > 0 ? r : null;
        }
        catch { return null; }
    }

    /// <summary>Чат по собеседованию знает вакансию, карту и оценку.</summary>
    private string InterviewContext()
    {
        if (Interview is not { } iv || Selected?.Id != iv.MeetingId) return "";
        var s = new StringBuilder("\n\nЭто собеседование. «Я» — интервьюер, «Собеседник» и другие голоса — кандидат" + (iv.Candidate.Length > 0 ? $" ({iv.Candidate})" : "") + ".\n");
        if (iv.Plan is { } p)
        {
            if (p.Requirements.Count > 0) s.Append("Требования вакансии: " + string.Join("; ", p.Requirements) + "\n");
            if (p.Brief.Length > 0) s.Append("Кандидат по резюме: " + p.Brief + "\n");
        }
        else if (iv.Vacancy.Length > 0) s.Append("Вакансия: " + TextTools.Head(iv.Vacancy, 2000) + "\n");
        if (iv.Report is { } r)
        {
            s.Append($"Оценка: соответствие {r.Fit}%, {Verdicts.Hire(r.Verdict)}. {r.Summary}\nКомпетенции: " + string.Join(", ", r.Competencies.Select(c => $"{c.Name} {c.Score}/5")) + "\n");
            if (r.Business is { } b) s.Append($"Бизнес-логика: {b.Score}/5. {b.Summary}\n");
        }
        return s.ToString();
    }

    /// <summary>Оценка простым текстом — для буфера обмена и Word.</summary>
    public string ReportText()
    {
        if (Interview?.Report is not { } r) return "";
        var s = new StringBuilder($"{Selected?.Title ?? "Собеседование"}\n\nСоответствие вакансии: {r.Fit}% — {Verdicts.Hire(r.Verdict)}\n\n{r.Summary}\n\nМатрица компетенций:\n");
        foreach (var c in r.Competencies) s.Append($"• {c.Name}: {c.Score}/5 — {c.Evidence}\n");
        if (r.Integrity is { Level: not "none" } ig)
        {
            s.Append($"\nСамостоятельность ответов: {ig.Title}\n");
            if (ig.Signs.Count > 0) s.Append(string.Join("\n", ig.Signs.Select(x => "• " + x)) + "\n");
        }
        if (r.Business is { } b)
        {
            s.Append($"\nБизнес-логика: {b.Score}/5\n{b.Summary}\n");
            if (b.Approach.Count > 0) s.Append("\nКак рассуждал:\n" + string.Join("\n", b.Approach.Select(x => "• " + x)) + "\n");
            if (b.Gaps.Count > 0) s.Append("\nЧто упустил:\n" + string.Join("\n", b.Gaps.Select(x => "• " + x)) + "\n");
        }
        s.Append($"\nПортрет:\n{r.Portrait}\n");
        void List(string t, List<string> xs) { if (xs.Count > 0) s.Append($"\n{t}:\n" + string.Join("\n", xs.Select(x => "• " + x)) + "\n"); }
        List("Сильные стороны", r.Strengths);
        List("Риски", r.Risks);
        List("Расхождения", r.Mismatches);
        List("Что проверить дальше", r.NextSteps);
        return s.ToString();
    }

    /// <summary>Оценка в разметке итога: так её умеет сохранять в Word тот же оформитель.</summary>
    public Meeting? ReportAsMeeting()
    {
        if (Selected is not { } m || ReportText() is not { Length: > 0 } text) return null;
        var md = string.Join("\n", text.Split('\n').Skip(2).Select(l =>
            l.StartsWith("• ") ? "- " + l[2..] : l.EndsWith(':') && !l.Contains('—') ? "**" + l.TrimEnd(':') + "**" : l));
        if (m.Summary.Length > 0) md += "\n\n**Итог разговора**\n" + m.Summary;
        return new Meeting { Id = m.Id, Title = m.Title, StartedAt = m.StartedAt, Summary = md };
    }

    // MARK: База собеседований: вакансии и резюме

    public ObservableCollection<Vacancy> Vacancies { get; } = new();
    public ObservableCollection<Resume> Resumes { get; } = new();
    private Vacancy? _libVacancy;
    private Resume? _libResume;
    private bool _libLoose;
    public Vacancy? LibVacancy { get => _libVacancy; set { if (Set(ref _libVacancy, value)) { if (value is not null) LibLoose = false; Raise(nameof(LibResumes)); } } }
    /// <summary>Открыта группа «Без вакансии».</summary>
    public bool LibLoose { get => _libLoose; set { if (Set(ref _libLoose, value)) Raise(nameof(LibResumes)); } }
    public Resume? LibResume { get => _libResume; set => Set(ref _libResume, value); }
    /// <summary>Кандидаты открытой вакансии.</summary>
    public List<Resume> LibResumes => Resumes.Where(r => LibLoose ? r.VacancyId == 0 : r.VacancyId == LibVacancy?.Id).ToList();
    public bool HasLooseResumes => Resumes.Any(r => r.VacancyId == 0);
    private CancellationTokenSource? _librarySave;

    private void LoadLibrary()
    {
        foreach (var v in _store.Vacancies()) Vacancies.Add(v);
        foreach (var r in _store.Resumes()) Resumes.Add(r);
        RefreshLibrary();
    }

    /// <summary>Итоги собеседований — в карточки кандидатов, счётчики — в список вакансий.</summary>
    public void RefreshLibrary()
    {
        var results = new Dictionary<long, CandidateResult>();
        // Встречи идут от новых к старым: первое найденное — последнее собеседование
        foreach (var m in Meetings.Where(m => m.IsInterview))
        {
            if (_store.Interview(m.Id) is not { ResumeId: { } rid } iv) continue;
            if (!results.ContainsKey(rid) || (results[rid].Report is null && iv.Report is not null))
                results[rid] = new CandidateResult { MeetingId = m.Id, Date = m.StartedAt, Report = iv.Report };
        }
        foreach (var r in Resumes) r.Result = results.GetValueOrDefault(r.Id);
        foreach (var v in Vacancies)
        {
            var rs = Resumes.Where(r => r.VacancyId == v.Id).ToList();
            int passed = rs.Count(r => r.Result is not null);
            v.Subtitle = $"кандидатов: {rs.Count}" + (passed > 0 ? $" · прошли: {passed}" : "");
        }
        Raise(nameof(LibResumes));
        Raise(nameof(HasLooseResumes));
    }

    public void OpenLibrary()
    {
        ShowKb = true;
        LibVacancy ??= Vacancies.FirstOrDefault();
        RefreshLibrary();
    }

    /// <summary>Название по первой содержательной строке текста.</summary>
    private static string TitleFrom(string text, string fallback)
    {
        var line = text.Split('\n').Select(l => l.Trim()).FirstOrDefault(l => l.Length >= 3) ?? "";
        if (line.Length > 70) line = line[..70] + "…";
        return line.Length > 0 ? line : fallback;
    }

    public Vacancy NewVacancy(string text = "", string title = "")
    {
        var v = _store.AddVacancy(title.Length > 0 ? title : TitleFrom(text, "Новая вакансия"), text);
        Vacancies.Insert(0, v);
        LibVacancy = v;
        LibResume = null;
        RefreshLibrary();
        return v;
    }

    public void SaveVacancy(Vacancy v) => Debounced(() => _store.Update(v));
    public void SaveResume(Resume r) => Debounced(() => _store.Update(r));

    private void Debounced(Action save)
    {
        _librarySave?.Cancel();
        var cts = _librarySave = new CancellationTokenSource();
        _ = Task.Delay(400, cts.Token).ContinueWith(t => { if (!t.IsCanceled) Post(save); });
    }

    public void DeleteVacancy(Vacancy v)
    {
        _store.DeleteVacancy(v.Id);
        Vacancies.Remove(v);
        foreach (var r in Resumes.Where(r => r.VacancyId == v.Id).ToList()) Resumes.Remove(r);
        if (LibVacancy == v) { LibVacancy = Vacancies.FirstOrDefault(); LibResume = null; }
        RefreshLibrary();
    }

    public Resume NewResume(long vacancyId, string name = "", string text = "")
    {
        var r = _store.AddResume(vacancyId, name.Length > 0 ? name : TitleFrom(text, "Новый кандидат"), text);
        Resumes.Insert(0, r);
        LibResume = r;
        RefreshLibrary();
        return r;
    }

    public void MoveResume(Resume r, long vacancyId)
    {
        r.VacancyId = vacancyId;
        _store.Update(r);
        RefreshLibrary();
    }

    public void DeleteResume(Resume r)
    {
        _store.DeleteResume(r.Id);
        Resumes.Remove(r);
        if (LibResume == r) LibResume = null;
        RefreshLibrary();
    }

    /// <summary>Собеседование по резюме из базы: вакансия, резюме и акценты уже на месте — остаётся собрать карту.</summary>
    public void StartInterview(Resume r)
    {
        if (IsRecording) return;
        NewInterview();
        var v = Vacancies.FirstOrDefault(x => x.Id == r.VacancyId);
        EditInterview(iv =>
        {
            iv.ResumeId = r.Id;
            iv.Resume = r.Text;
            iv.VacancyId = v?.Id;
            iv.Vacancy = v?.Text ?? "";
            iv.Notes = v?.Notes ?? "";
        });
        SetCandidate(r.Name);
        SaveInterviewNow();
        Raise(nameof(Interview));
        RefreshLibrary();
    }

    /// <summary>На экране подготовки: подставить вакансию из базы.</summary>
    public void UseVacancy(Vacancy v)
    {
        EditInterview(iv =>
        {
            iv.VacancyId = v.Id;
            iv.Vacancy = v.Text;
            if (iv.Notes.Trim().Length == 0) iv.Notes = v.Notes;
        });
        Raise(nameof(Interview));
    }

    public void UseResume(Resume r)
    {
        EditInterview(iv =>
        {
            iv.ResumeId = r.Id;
            iv.Resume = r.Text;
            if (iv.VacancyId is null && Vacancies.FirstOrDefault(v => v.Id == r.VacancyId) is { } v) { iv.VacancyId = v.Id; iv.Vacancy = v.Text; }
        });
        SetCandidate(r.Name);
        Raise(nameof(Interview));
    }

    /// <summary>Вставленное вручную сохраняем в базу, чтобы в следующий раз не грузить заново.</summary>
    public void SaveInterviewToLibrary()
    {
        if (Interview is not { } iv) return;
        var vText = iv.Vacancy.Trim();
        var rText = iv.Resume.Trim();
        var vac = iv.VacancyId is { } vid0 ? Vacancies.FirstOrDefault(v => v.Id == vid0) : null;
        if (vac is null && vText.Length > 0)
        {
            vac = _store.AddVacancy(TitleFrom(vText, "Вакансия"), vText, iv.Notes);
            Vacancies.Insert(0, vac);
        }
        else if (vac is not null && vText.Length > 0 && vac.Text != vText) { vac.Text = vText; _store.Update(vac); }
        var res = iv.ResumeId is { } rid0 ? Resumes.FirstOrDefault(r => r.Id == rid0) : null;
        if (res is null && rText.Length > 0)
        {
            var name = iv.Candidate.Trim();
            res = _store.AddResume(vac?.Id ?? 0, name.Length > 0 ? name : TitleFrom(rText, "Кандидат"), rText);
            Resumes.Insert(0, res);
        }
        else if (res is not null && rText.Length > 0 && res.Text != rText) { res.Text = rText; _store.Update(res); }
        if (iv.VacancyId != vac?.Id || iv.ResumeId != res?.Id)
        {
            iv.VacancyId = vac?.Id;
            iv.ResumeId = res?.Id;
            SaveInterviewNow();
        }
        RefreshLibrary();
    }
}
