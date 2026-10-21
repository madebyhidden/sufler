using System.Collections.ObjectModel;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Sufler;

// MARK: Данные собеседования. Хранятся одним JSON на встречу — так же, как на Mac

/// <summary>Вопрос из карты: обязательный, кейс на бизнес-логику, «про человека» (цель скрыта) или с подковыркой.</summary>
public sealed class PlanQuestion : Observable
{
    private bool _asked, _skipped;
    public string Id { get; set; } = Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();
    /// <summary>must | case | person | tricky</summary>
    public string Kind { get; set; } = "must";
    public string Text { get; set; } = "";
    /// <summary>Что на самом деле проверяем; для вопросов «про человека» это скрытая цель.</summary>
    public string Purpose { get; set; } = "";
    /// <summary>Что хотим услышать в сильном ответе и какие тревожные сигналы.</summary>
    public string Listen { get; set; } = "";
    public string Requirement { get; set; } = "";
    public bool Asked { get => _asked; set { if (Set(ref _asked, value)) Raise(nameof(CheckGlyph)); } }
    public bool Skipped { get => _skipped; set { if (Set(ref _skipped, value)) Raise(nameof(CheckGlyph)); } }

    [JsonIgnore] public string KindTitle => Verdicts.Kind(Kind);
    [JsonIgnore] public string PurposeText => Purpose.Length == 0 ? "" : (Kind == "person" ? "Скрытая цель: " : "Проверяем: ") + Purpose;
    [JsonIgnore] public string CheckGlyph => Asked ? "" : Skipped ? "" : "";
}

public sealed class InterviewPlan
{
    public List<string> Requirements { get; set; } = [];
    /// <summary>Кто перед нами по резюме: 3–4 предложения.</summary>
    public string Brief { get; set; } = "";
    /// <summary>Что проверить особенно: заявленные достижения, неясности.</summary>
    public List<string> Focus { get; set; } = [];
    public ObservableCollection<PlanQuestion> Questions { get; set; } = [];
    /// <summary>Карту собрала глубокая модель.</summary>
    public bool Deep { get; set; }
}

/// <summary>Разбор одного ответа кандидата прямо во время собеседования.</summary>
public sealed class Probe : Observable
{
    private string _gist = "", _verdict = "ok", _followup = "", _reason = "";
    private bool _used, _dismissed;
    private int? _mastery;
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public DateTime Ts { get; set; } = DateTime.Now;
    /// <summary>Реплика интервьюера, с которой начался обмен: по ней один ответ не разбираем дважды.</summary>
    public long QuestionTurnId { get; set; }
    public string Question { get; set; } = "";
    public string Gist { get => _gist; set => Set(ref _gist, value); }
    /// <summary>strong | ok | vague | evasive | contradiction | red_flag</summary>
    public string Verdict { get => _verdict; set { if (Set(ref _verdict, value)) Raise(nameof(VerdictTitle)); } }
    public string Followup { get => _followup; set { if (Set(ref _followup, value)) Raise(nameof(Active)); } }
    public string Reason { get => _reason; set => Set(ref _reason, value); }
    public bool Used { get => _used; set { if (Set(ref _used, value)) Raise(nameof(Active)); } }
    public bool Dismissed { get => _dismissed; set { if (Set(ref _dismissed, value)) Raise(nameof(Active)); } }
    /// <summary>Насколько кандидат владеет темой: 0 — не знает, 5 — свободно.</summary>
    public int? Mastery { get => _mastery; set { if (Set(ref _mastery, value)) Raise(nameof(MasteryText)); } }
    /// <summary>Похоже ли, что кандидат зачитывает ответ нейросети: 0 — живая речь, 3 — явно читает текст.</summary>
    public int? Ai { get => _ai; set => Set(ref _ai, value); }
    private int? _ai;
    public string AiWhy { get; set; } = "";
    /// <summary>Как отвечал: пауза перед ответом, темп, «ээ».</summary>
    public AnswerStats? Stats { get; set; }
    /// <summary>Уточнение готово, а кандидат ещё не договорил — показываем бледно, чтобы интервьюер видел заранее.</summary>
    public bool Draft { get => _draft; set => Set(ref _draft, value); }
    private bool _draft;

    [JsonIgnore] public string VerdictTitle => Verdicts.Title(Verdict);
    [JsonIgnore] public string MasteryText => Mastery is { } m ? $"в теме {m}/5" : "";
    /// <summary>Уточнение есть и ещё не задано и не отклонено.</summary>
    [JsonIgnore] public bool Active => Followup.Length > 0 && !Used && !Dismissed;
    [JsonIgnore] public string TimeText => Ts.ToString("HH:mm");
}

/// <summary>Как кандидат отвечал — считается по самой речи, без модели, поэтому видно сразу.</summary>
public sealed class AnswerStats
{
    /// <summary>Сколько секунд молчал после вопроса, прежде чем начать.</summary>
    public double? Latency { get; set; }
    public int Words { get; set; }
    /// <summary>«ээ», «ну», «как бы» на 100 слов.</summary>
    public double Fillers { get; set; }
    /// <summary>Слов в секунду речи.</summary>
    public double? Pace { get; set; }

    /// <summary>Маркеры для интервьюера: текст и цвет.</summary>
    [JsonIgnore]
    public List<(string Text, string Color)> Markers
    {
        get
        {
            var m = new List<(string, string)>();
            if (Latency is >= 6) m.Add(($"Долго думал: {(int)Latency} с", "#F0932B"));
            if (Fillers >= 6) m.Add(("Много «ээ» и «ну»", "#F0932B"));
            if (Pace is < 1.3 && Words >= 15) m.Add(("Говорит медленно, с паузами", "#F0932B"));
            if (Words < 12) m.Add(("Очень короткий ответ", "#F0932B"));
            if (Fillers < 1 && Words >= 50 && (Latency ?? 0) >= 4) m.Add(("Гладко, как по написанному", "#8E5CE6"));
            return m;
        }
    }

    [JsonIgnore]
    public string Line
    {
        get
        {
            var s = new List<string>();
            if (Latency is { } l) s.Add($"пауза перед ответом {Math.Round(l)} с");
            if (Pace is { } p) s.Add($"темп {p.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)} слова в секунду");
            s.Add($"«ээ», «ну», «как бы» — {Fillers:0} на 100 слов");
            s.Add($"{Words} слов");
            return string.Join("; ", s);
        }
    }
}

/// <summary>Самостоятельность ответов: признаки, что кандидат подсматривал в нейросеть или поиск.</summary>
public sealed class Integrity
{
    /// <summary>none | low | medium | high</summary>
    public string Level { get; set; } = "none";
    public List<string> Signs { get; set; } = [];
    [JsonIgnore]
    public string Title => Level switch
    {
        "high" => "Похоже, отвечал с подсказками ИИ", "medium" => "Есть признаки подсказок ИИ",
        "low" => "Отдельные ответы звучат как зачитанные", _ => "Отвечал сам",
    };
}

public sealed class Competency
{
    public string Name { get; set; } = "";
    public string Requirement { get; set; } = "";
    /// <summary>0 — не проявлено, 5 — сильно выше ожиданий.</summary>
    public int Score { get; set; }
    public string Evidence { get; set; } = "";
    /// <summary>high | medium | low</summary>
    public string Confidence { get; set; } = "medium";
}

/// <summary>Как кандидат думает в рамках бизнес-задачи: «спроектируйте агента-шоппера — как будете делать?»</summary>
public sealed class BusinessThinking
{
    public int Score { get; set; }
    public string Summary { get; set; } = "";
    /// <summary>Как рассуждал, по шагам.</summary>
    public List<string> Approach { get; set; } = [];
    /// <summary>Что упустил: пользователь, метрики, риски, стоимость.</summary>
    public List<string> Gaps { get; set; } = [];
    public string Confidence { get; set; } = "medium";
}

public sealed class InterviewReport
{
    /// <summary>Соответствие требованиям вакансии, 0–100.</summary>
    public int Fit { get; set; }
    /// <summary>strong_yes | yes | maybe | no</summary>
    public string Verdict { get; set; } = "maybe";
    public string Summary { get; set; } = "";
    public string Portrait { get; set; } = "";
    public List<Competency> Competencies { get; set; } = [];
    public List<string> Strengths { get; set; } = [];
    public List<string> Risks { get; set; } = [];
    public List<string> Mismatches { get; set; } = [];
    public List<string> NextSteps { get; set; } = [];
    public BusinessThinking? Business { get; set; }
    public Integrity? Integrity { get; set; }
    public bool Deep { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.Now;
}

public sealed class InterviewData : Observable
{
    private InterviewPlan? _plan;
    private InterviewReport? _report;
    public long MeetingId { get; set; }
    public string Candidate { get; set; } = "";
    public string Vacancy { get; set; } = "";
    public string Resume { get; set; } = "";
    /// <summary>Акценты интервьюера: на что смотреть особенно.</summary>
    public string Notes { get; set; } = "";
    public InterviewPlan? Plan { get => _plan; set => Set(ref _plan, value); }
    public ObservableCollection<Probe> Probes { get; set; } = [];
    public InterviewReport? Report { get => _report; set => Set(ref _report, value); }
    /// <summary>Откуда взяты вакансия и резюме в базе собеседований; null — вставлены вручную.</summary>
    public long? VacancyId { get; set; }
    public long? ResumeId { get; set; }

    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.Never };
    public string ToJson() => JsonSerializer.Serialize(this, Json);
    public static InterviewData? FromJson(string json)
    {
        try { return JsonSerializer.Deserialize<InterviewData>(json, Json); } catch { return null; }
    }
}

/// <summary>Вакансия в базе собеседований: под ней лежат резюме кандидатов.</summary>
public sealed class Vacancy : Observable
{
    private string _title = "", _subtitle = "";
    public long Id { get; init; }
    public string Title { get => _title; set => Set(ref _title, value); }
    public string Text { get; set; } = "";
    public string Notes { get; set; } = "";
    public DateTime CreatedAt { get; init; }
    /// <summary>«кандидатов: 3 · прошли: 2»</summary>
    public string Subtitle { get => _subtitle; set => Set(ref _subtitle, value); }
}

public sealed class Resume : Observable
{
    private string _name = "";
    private long _vacancyId;
    private CandidateResult? _result;
    public long Id { get; init; }
    public long VacancyId { get => _vacancyId; set => Set(ref _vacancyId, value); }
    public string Name { get => _name; set => Set(ref _name, value); }
    public string Text { get; set; } = "";
    public DateTime CreatedAt { get; init; }
    /// <summary>Итог последнего собеседования с этим кандидатом.</summary>
    public CandidateResult? Result { get => _result; set { if (Set(ref _result, value)) { Raise(nameof(ResultText)); Raise(nameof(ResultColor)); } } }
    public string ResultText => Result?.Label ?? "ещё не собеседовали";
    /// <summary>Цвет отметки: по проценту соответствия; синий — собеседовали, но оценки нет; пусто — не собеседовали.</summary>
    public string ResultColor => Result is null ? "" : Result.Report is { } r ? Verdicts.FitColor(r.Fit) : "#3B82F6";
}

/// <summary>Чем закончилось последнее собеседование с кандидатом.</summary>
public sealed class CandidateResult
{
    public long MeetingId { get; init; }
    public DateTime Date { get; init; }
    public InterviewReport? Report { get; init; }
    public string Label
    {
        get
        {
            var d = Date.ToString("d MMM", Ru.Culture);
            return Report is { } r ? $"{r.Fit}% · {Verdicts.Hire(r.Verdict)} · {d}" : $"собеседование {d}, без оценки";
        }
    }
}

public static class Verdicts
{
    /// <summary>Порядок видов вопросов в карте и в подсказке «следующий вопрос».</summary>
    public static readonly string[] PlanKinds = ["must", "case", "person", "tricky"];

    public static string Title(string v) => v switch
    {
        "strong" => "Сильный ответ", "ok" => "Ответ по делу", "vague" => "Размыто", "evasive" => "Уходит от ответа",
        "contradiction" => "Противоречие", "red_flag" => "Тревожный сигнал", _ => v,
    };

    public static string Hire(string v) => v switch
    {
        "strong_yes" => "Однозначно брать", "yes" => "Скорее подходит", "maybe" => "Под вопросом", "no" => "Не подходит", _ => v,
    };

    public static string Kind(string k) => k switch
    {
        "must" => "Обязательные", "case" => "Кейсы на бизнес-логику", "person" => "Про человека", "tricky" => "С подковыркой", _ => k,
    };

    public static string VerdictColor(string v) => v switch { "strong" => "#2EAD5B", "ok" => "#3B82F6", "vague" or "evasive" => "#F0932B", _ => "#E5484D" };
    public static string KindColor(string k) => k switch { "must" => "#008799", "case" => "#5856D6", "person" => "#8E5CE6", _ => "#E0569B" };
    public static string FitColor(int fit) => fit >= 75 ? "#2EAD5B" : fit >= 50 ? "#F0932B" : "#E5484D";
    public static string ScoreColor(double s) => s >= 4 ? "#2EAD5B" : s >= 3 ? "#3B82F6" : s >= 2 ? "#F0932B" : "#E5484D";
    public static string MasteryColor(double v) => v >= 3.8 ? "#2EAD5B" : v >= 2.5 ? "#F0932B" : "#E5484D";
    public static string MasteryTitle(double v) => v >= 3.8 ? "Уверенно в теме" : v >= 2.5 ? "Местами плавает" : "Плавает в теме";
}
