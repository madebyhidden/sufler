using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using Microsoft.Data.Sqlite;

namespace Sufler;

/// <summary>Объект, за изменениями которого следит интерфейс.</summary>
public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    public void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public static class Speaker
{
    public const string Me = "Я";
    public const string Them = "Собеседник";
}

public sealed class Meeting : Observable
{
    private string _title = "", _notes = "", _summary = "";
    /// <summary>Названия, которые стоит перепроверить после встречи (JSON).</summary>
    public string Checks { get; set; } = "";
    private DateTime? _endedAt;
    private bool _recording;

    public long Id { get; init; }
    private DateTime _startedAt;
    public DateTime StartedAt { get => _startedAt; set { if (Set(ref _startedAt, value)) { Raise(nameof(DateText)); Raise(nameof(DayText)); Raise(nameof(TimeText)); } } }
    /// <summary>"" — обычная встреча, "interview" — собеседование.</summary>
    public string Kind { get; init; } = "";
    public bool IsInterview => Kind == "interview";
    public string Title { get => _title; set => Set(ref _title, value); }
    public DateTime? EndedAt { get => _endedAt; set { if (Set(ref _endedAt, value)) Raise(nameof(TimeText)); } }
    public string Notes { get => _notes; set => Set(ref _notes, value); }
    public string Summary { get => _summary; set => Set(ref _summary, value); }
    /// <summary>Идёт запись именно этой встречи.</summary>
    public bool Recording { get => _recording; set => Set(ref _recording, value); }

    public string DateText => StartedAt.ToString("d MMM, HH:mm", Ru.Culture);
    public string DayText => StartedAt.ToString("ddd, d MMMM", Ru.Culture);
    public string TimeText => EndedAt is { } e ? $"{StartedAt:HH:mm} – {e:HH:mm}" : "";
}

public sealed class Turn : Observable
{
    private string _text = "", _label = "";
    private DateTime _ts;
    private int _voice;

    public long Id { get; init; }
    public long MeetingId { get; init; }
    public required string Speaker { get; init; }
    public DateTime Ts { get => _ts; set { if (Set(ref _ts, value)) Raise(nameof(TimeText)); } }
    public string Text { get => _text; set => Set(ref _text, value); }
    public int Voice { get => _voice; set { if (Set(ref _voice, value)) { Raise(nameof(VoiceKey)); Raise(nameof(IsMe)); } } }
    /// <summary>Как реплика подписана: «Я», «Собеседник 2» или имя, которое дал пользователь.</summary>
    public string Label { get => _label; set => Set(ref _label, value); }
    /// <summary>Черновик: фраза ещё звучит и будет переписана.</summary>
    public bool Live { get; init; }
    /// <summary>Где эта реплика лежит в сохранённом звуке встречи, в секундах; 0–0 — звука нет.</summary>
    public double AudioStart { get; set; }
    public double AudioEnd { get; set; }
    private bool _canPlay, _playing;
    /// <summary>Реплику можно переслушать: звук сохранён и запись уже остановлена.</summary>
    public bool CanPlay { get => _canPlay; set => Set(ref _canPlay, value); }
    public bool Playing { get => _playing; set => Set(ref _playing, value); }

    /// <summary>Ключ голоса внутри встречи: 0 — владелец (или не определён), плюс — собеседники из звонка,
    /// минус — другие люди, которых слышит микрофон.</summary>
    public int VoiceKey => Speaker == Sufler.Speaker.Me ? (Voice >= 2 ? -Voice : 0) : Voice;
    public bool IsMe => Speaker == Sufler.Speaker.Me && VoiceKey == 0;
    public string TimeText => Live ? "…" : Ts.ToString("HH:mm");
}

public sealed class Question : Observable
{
    private string _question = "", _addressee = "", _asker = "", _topic = "", _context = "", _answer = "";
    private bool _forMe, _big;

    public long Id { get; set; }
    public long MeetingId { get; init; }
    public DateTime Ts { get; init; }
    public string Text { get => _question; set => Set(ref _question, value); }
    public string Addressee { get => _addressee; set { if (Set(ref _addressee, value)) Raise(nameof(AddresseeText)); } }
    public string Asker { get => _asker; set { if (Set(ref _asker, value)) Raise(nameof(AskerText)); } }
    public string Topic { get => _topic; set => Set(ref _topic, value); }
    public string Context { get => _context; set => Set(ref _context, value); }
    public string Answer { get => _answer; set => Set(ref _answer, value); }
    /// <summary>Вопрос обращён к владельцу приложения.</summary>
    public bool ForMe { get => _forMe; set => Set(ref _forMe, value); }
    /// <summary>Самый свежий вопрос — показывается крупной карточкой.</summary>
    public bool Big { get => _big; set => Set(ref _big, value); }

    public string AddresseeText => Addressee.Length > 0 ? "Кому: " + Addressee : "";
    public string AskerText => Asker.Length == 0 ? "" : Asker == Speaker.Me ? "спросил я" : "спросил: " + Asker;
    public string TimeText => Ts.ToString("HH:mm");
}

public sealed class Fact : Observable
{
    private string _text = "", _previous = "", _meta = "";

    public long Id { get; init; }
    public string Text { get => _text; set => Set(ref _text, value); }
    public string Previous { get => _previous; set => Set(ref _previous, value); }
    public long MeetingId { get; set; }
    public DateTime CreatedAt { get; init; }
    public DateTime UpdatedAt { get; set; }
    public float[] Vector { get; set; } = [];
    /// <summary>Подпись под фактом: когда добавлен и из какой встречи.</summary>
    public string Meta { get => _meta; set => Set(ref _meta, value); }
}

public sealed class Doc
{
    public long Id { get; init; }
    public required string Title { get; init; }
    public required string Path { get; init; }
    public DateTime AddedAt { get; init; }
    public int Chars { get; init; }
    public string Meta => $"{AddedAt.ToString("d MMM", Ru.Culture)} · {Chars / 1000 + 1} тыс. знаков";
}

/// <summary>Слово из расшифровки, которое, похоже, распознано неверно: пользователь подтверждает или исправляет его.</summary>
public sealed class NameCheck : Observable
{
    private string _input = "";
    private bool _canPlay;
    public string Heard { get; set; } = "";
    public string Guess { get; set; } = "";
    public string Quote { get; set; } = "";
    public long TurnId { get; set; }
    /// <summary>Что пользователь вписал в поле «как правильно».</summary>
    [System.Text.Json.Serialization.JsonIgnore] public string Input { get => _input; set => Set(ref _input, value); }
    [System.Text.Json.Serialization.JsonIgnore] public bool CanPlay { get => _canPlay; set => Set(ref _canPlay, value); }
    [System.Text.Json.Serialization.JsonIgnore] public string HeardText => $"«{Heard}»";
}

public sealed record Chunk(long MeetingId, string Text, float[] Vector, string Source);

/// <summary>Изменение в базе фактов: сделанное по просьбе или предложенное ревизией.</summary>
public sealed class FactOp
{
    public required string Op { get; init; }      // add | update | delete
    public long FactId { get; init; }
    public string Text { get; init; } = "";
    public string Old { get; set; } = "";
    public string Reason { get; init; } = "";
}

public sealed class ChatLine : Observable
{
    private string _text = "";
    private bool _opsPending;

    public required string Role { get; init; }
    public string Text { get => _text; set { if (Set(ref _text, value)) Raise(nameof(Shown)); } }
    public ObservableCollection<string> Sources { get; } = new();
    public ObservableCollection<FactOp> Ops { get; } = new();
    /// <summary>Изменения предложены и ждут кнопки «Применить».</summary>
    public bool OpsPending { get => _opsPending; set => Set(ref _opsPending, value); }
    public bool IsUser => Role == "user";
    /// <summary>Текст для показа: модель любит списки со звёздочками — превращаем их в аккуратные пункты.</summary>
    public string Shown => Text.Length == 0 ? "…" : TextTools.Tidy(Text);
}

public static class Ru
{
    public static readonly System.Globalization.CultureInfo Culture = System.Globalization.CultureInfo.GetCultureInfo("ru-RU");
}

/// <summary>Локальная база: встречи, реплики, вопросы, факты и векторы для поиска. Та же схема, что на Mac.</summary>
public sealed class Store : IDisposable
{
    private readonly SqliteConnection _db;

    public Store(string path)
    {
        _db = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path }.ToString());
        _db.Open();
        Exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS meetings(id INTEGER PRIMARY KEY, title TEXT, started_at REAL, ended_at REAL, notes TEXT DEFAULT '', summary TEXT DEFAULT '');
            CREATE TABLE IF NOT EXISTS turns(id INTEGER PRIMARY KEY, meeting_id INTEGER, ts REAL, speaker TEXT, text TEXT, voice INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS questions(id INTEGER PRIMARY KEY, meeting_id INTEGER, ts REAL, question TEXT, addressee TEXT, asker TEXT, context TEXT, answer TEXT DEFAULT '', topic TEXT DEFAULT '', for_me INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, meeting_id INTEGER, text TEXT, vector BLOB, doc_id INTEGER DEFAULT 0);
            CREATE INDEX IF NOT EXISTS turns_m ON turns(meeting_id);
            CREATE INDEX IF NOT EXISTS chunks_m ON chunks(meeting_id);
            CREATE TABLE IF NOT EXISTS voices(meeting_id INTEGER, voice INTEGER, name TEXT, PRIMARY KEY(meeting_id, voice));
            CREATE TABLE IF NOT EXISTS documents(id INTEGER PRIMARY KEY, title TEXT, path TEXT, added_at REAL, chars INTEGER);
            CREATE TABLE IF NOT EXISTS facts(id INTEGER PRIMARY KEY, text TEXT, previous TEXT DEFAULT '', meeting_id INTEGER DEFAULT 0, created_at REAL, updated_at REAL, vector BLOB);
            CREATE TABLE IF NOT EXISTS interviews(meeting_id INTEGER PRIMARY KEY, data TEXT);
            CREATE TABLE IF NOT EXISTS vacancies(id INTEGER PRIMARY KEY, title TEXT, text TEXT, notes TEXT DEFAULT '', created_at REAL);
            CREATE TABLE IF NOT EXISTS resumes(id INTEGER PRIMARY KEY, vacancy_id INTEGER, name TEXT, text TEXT, created_at REAL);
            """);
        // Колонки, добавленные позже: на базе, где они уже есть, команда просто вернёт ошибку
        foreach (var sql in new[]
        {
            "ALTER TABLE turns ADD COLUMN audio_start REAL DEFAULT 0",
            "ALTER TABLE turns ADD COLUMN audio_end REAL DEFAULT 0",
            "ALTER TABLE meetings ADD COLUMN checks TEXT DEFAULT ''",
            "ALTER TABLE meetings ADD COLUMN kind TEXT DEFAULT ''",
        })
        {
            try { Exec(sql); } catch { }
        }
    }

    public void Dispose() => _db.Dispose();

    // MARK: Статистика использования — только на этом компьютере

    /// <summary>Плюс к дневному счётчику (слова, токены, вопросы и т. п.).</summary>
    public void Bump(string key, double value, string day)
    {
        Exec("CREATE TABLE IF NOT EXISTS usage(day TEXT, key TEXT, value REAL, PRIMARY KEY(day, key));");
        Run("INSERT INTO usage(day, key, value) VALUES($p0,$p1,$p2) ON CONFLICT(day, key) DO UPDATE SET value = value + excluded.value", day, key, value);
    }

    public Dictionary<string, Dictionary<string, double>> Usage(string since)
    {
        Exec("CREATE TABLE IF NOT EXISTS usage(day TEXT, key TEXT, value REAL, PRIMARY KEY(day, key));");
        var map = new Dictionary<string, Dictionary<string, double>>();
        using var c = Cmd("SELECT day, key, value FROM usage WHERE day >= $p0", since);
        using var r = c.ExecuteReader();
        while (r.Read())
        {
            if (!map.TryGetValue(r.GetString(0), out var d)) map[r.GetString(0)] = d = new();
            d[r.GetString(1)] = r.GetDouble(2);
        }
        return map;
    }

    public double Scalar(string sql, params object?[] args)
    {
        using var c = Cmd(sql, args);
        var v = c.ExecuteScalar();
        return v is null or DBNull ? 0 : Convert.ToDouble(v);
    }

    /// <summary>Встречи, минуты записи, слова и вопросы по дням после указанного дня — посчитанные по самим встречам.</summary>
    public Dictionary<string, Dictionary<string, double>> DerivedDays(string after)
    {
        var map = new Dictionary<string, Dictionary<string, double>>();
        void Add(string sql, string key)
        {
            using var c = Cmd(sql, after);
            using var r = c.ExecuteReader();
            while (r.Read())
            {
                if (r.IsDBNull(0)) continue;
                if (!map.TryGetValue(r.GetString(0), out var d)) map[r.GetString(0)] = d = new();
                d[key] = r.IsDBNull(1) ? 0 : r.GetDouble(1);
            }
        }
        Add("SELECT date(started_at, 'unixepoch', 'localtime') d, COUNT(*) FROM meetings GROUP BY d HAVING d > $p0", "meetings");
        Add("SELECT date(started_at, 'unixepoch', 'localtime') d, SUM(COALESCE(ended_at, started_at) - started_at) / 60.0 FROM meetings GROUP BY d HAVING d > $p0", "recorded_minutes");
        Add("SELECT date(ts, 'unixepoch', 'localtime') d, SUM(LENGTH(text) - LENGTH(REPLACE(text, ' ', '')) + 1) FROM turns GROUP BY d HAVING d > $p0", "words");
        Add("SELECT date(ts, 'unixepoch', 'localtime') d, COUNT(*) FROM questions GROUP BY d HAVING d > $p0", "questions");
        Add("SELECT date(ts, 'unixepoch', 'localtime') d, SUM(for_me) FROM questions GROUP BY d HAVING d > $p0", "questions_me");
        return map;
    }

    /// <summary>Слова по дням (по отметкам времени реплик) начиная с указанного момента.</summary>
    public Dictionary<string, int> WordsByDay(DateTime since)
    {
        var map = new Dictionary<string, int>();
        using var c = Cmd("SELECT ts, LENGTH(text) - LENGTH(REPLACE(text, ' ', '')) + 1 FROM turns WHERE ts >= $p0", Unix(since));
        using var r = c.ExecuteReader();
        while (r.Read())
        {
            var d = Local(r.GetDouble(0)).ToString("yyyy-MM-dd");
            map[d] = map.GetValueOrDefault(d) + r.GetInt32(1);
        }
        return map;
    }

    private void Exec(string sql)
    {
        using var c = _db.CreateCommand();
        c.CommandText = sql;
        c.ExecuteNonQuery();
    }

    private SqliteCommand Cmd(string sql, params object?[] args)
    {
        var c = _db.CreateCommand();
        c.CommandText = sql;
        for (int i = 0; i < args.Length; i++) c.Parameters.AddWithValue("$p" + i, args[i] ?? DBNull.Value);
        return c;
    }

    private long Insert(string sql, params object?[] args)
    {
        using var c = Cmd(sql + "; SELECT last_insert_rowid();", args);
        return (long)c.ExecuteScalar()!;
    }

    private void Run(string sql, params object?[] args)
    {
        using var c = Cmd(sql, args);
        c.ExecuteNonQuery();
    }

    private static double Unix(DateTime t) => new DateTimeOffset(t.ToUniversalTime()).ToUnixTimeMilliseconds() / 1000.0;
    private static DateTime Local(double s) => DateTimeOffset.FromUnixTimeMilliseconds((long)(s * 1000)).LocalDateTime;

    private static byte[] Blob(float[] v)
    {
        var b = new byte[v.Length * 4];
        Buffer.BlockCopy(v, 0, b, 0, b.Length);
        return b;
    }

    private static float[] Floats(object o)
    {
        if (o is not byte[] b) return [];
        var v = new float[b.Length / 4];
        Buffer.BlockCopy(b, 0, v, 0, v.Length * 4);
        return v;
    }

    // MARK: Встречи

    public Meeting CreateMeeting(string title, string kind = "")
    {
        var now = DateTime.Now;
        long id = Insert("INSERT INTO meetings(title, started_at, kind) VALUES($p0,$p1,$p2)", title, Unix(now), kind);
        return new Meeting { Id = id, Title = title, StartedAt = now, Kind = kind };
    }

    /// <summary>Начало встречи переносим на момент, когда запись реально началась (собеседование готовят заранее).</summary>
    public void SetStarted(long id, DateTime at) => Run("UPDATE meetings SET started_at=$p0 WHERE id=$p1", Unix(at), id);

    public List<Meeting> Meetings()
    {
        var list = new List<Meeting>();
        using var c = Cmd("SELECT id,title,started_at,ended_at,notes,summary,checks,kind FROM meetings ORDER BY started_at DESC");
        using var r = c.ExecuteReader();
        while (r.Read())
            list.Add(new Meeting
            {
                Id = r.GetInt64(0), Title = r.GetString(1), StartedAt = Local(r.GetDouble(2)),
                EndedAt = r.IsDBNull(3) ? null : Local(r.GetDouble(3)),
                Notes = r.IsDBNull(4) ? "" : r.GetString(4), Summary = r.IsDBNull(5) ? "" : r.GetString(5), Checks = r.IsDBNull(6) ? "" : r.GetString(6),
                Kind = r.IsDBNull(7) ? "" : r.GetString(7),
            });
        return list;
    }

    public void Update(Meeting m) =>
        Run("UPDATE meetings SET title=$p0, ended_at=$p1, notes=$p2, summary=$p3, checks=$p4 WHERE id=$p5", m.Title, m.EndedAt is { } e ? Unix(e) : null, m.Notes, m.Summary, m.Checks, m.Id);

    public void DeleteMeeting(long id)
    {
        foreach (var t in new[] { "turns", "questions", "chunks", "voices", "interviews" }) Run($"DELETE FROM {t} WHERE meeting_id=$p0", id);
        Run("DELETE FROM meetings WHERE id=$p0", id);
    }

    // MARK: Реплики и вопросы

    public Turn AddTurn(long meetingId, string speaker, string text, int voice, double audioStart = 0, double audioEnd = 0)
    {
        var now = DateTime.Now;
        long id = Insert("INSERT INTO turns(meeting_id, ts, speaker, text, voice, audio_start, audio_end) VALUES($p0,$p1,$p2,$p3,$p4,$p5,$p6)", meetingId, Unix(now), speaker, text, voice, audioStart, audioEnd);
        return new Turn { Id = id, MeetingId = meetingId, Speaker = speaker, Ts = now, Text = text, Voice = voice, AudioStart = audioStart, AudioEnd = audioEnd };
    }

    public void UpdateTurn(Turn t) =>
        Run("UPDATE turns SET text=$p0, ts=$p1, voice=$p2, audio_start=$p3, audio_end=$p4 WHERE id=$p5", t.Text, Unix(t.Ts), t.Voice, t.AudioStart, t.AudioEnd, t.Id);
    public void DeleteTurn(long id) => Run("DELETE FROM turns WHERE id=$p0", id);

    public List<Turn> Turns(long meetingId)
    {
        var list = new List<Turn>();
        using var c = Cmd("SELECT id,ts,speaker,text,voice,audio_start,audio_end FROM turns WHERE meeting_id=$p0 ORDER BY id", meetingId);
        using var r = c.ExecuteReader();
        while (r.Read())
            list.Add(new Turn
            {
                Id = r.GetInt64(0), MeetingId = meetingId, Ts = Local(r.GetDouble(1)),
                Speaker = r.GetString(2) == Speaker.Me ? Speaker.Me : Speaker.Them, Text = r.GetString(3), Voice = r.IsDBNull(4) ? 0 : r.GetInt32(4),
                AudioStart = r.IsDBNull(5) ? 0 : r.GetDouble(5), AudioEnd = r.IsDBNull(6) ? 0 : r.GetDouble(6),
            });
        return list;
    }

    public Dictionary<int, string> VoiceNames(long meetingId)
    {
        var map = new Dictionary<int, string>();
        using var c = Cmd("SELECT voice, name FROM voices WHERE meeting_id=$p0", meetingId);
        using var r = c.ExecuteReader();
        while (r.Read()) map[r.GetInt32(0)] = r.GetString(1);
        return map;
    }

    public void SetVoiceName(long meetingId, int voice, string name) =>
        Run("INSERT OR REPLACE INTO voices(meeting_id, voice, name) VALUES($p0,$p1,$p2)", meetingId, voice, name);

    public void AddQuestion(Question q) =>
        q.Id = Insert("INSERT INTO questions(meeting_id, ts, question, addressee, asker, context) VALUES($p0,$p1,$p2,$p3,$p4,$p5)", q.MeetingId, Unix(q.Ts), q.Text, q.Addressee, q.Asker, q.Context);

    public void Update(Question q) =>
        Run("UPDATE questions SET question=$p0, addressee=$p1, asker=$p2, topic=$p3, context=$p4, answer=$p5, for_me=$p6 WHERE id=$p7",
            q.Text, q.Addressee, q.Asker, q.Topic, q.Context, q.Answer, q.ForMe ? 1 : 0, q.Id);

    public List<Question> Questions(long meetingId)
    {
        var list = new List<Question>();
        using var c = Cmd("SELECT id,ts,question,addressee,asker,context,answer,topic,for_me FROM questions WHERE meeting_id=$p0 ORDER BY id", meetingId);
        using var r = c.ExecuteReader();
        string S(int i) => r.IsDBNull(i) ? "" : r.GetString(i);
        while (r.Read())
            list.Add(new Question
            {
                Id = r.GetInt64(0), MeetingId = meetingId, Ts = Local(r.GetDouble(1)), Text = S(2), Addressee = S(3), Asker = S(4),
                Context = S(5), Answer = S(6), Topic = S(7), ForMe = !r.IsDBNull(8) && r.GetInt64(8) != 0,
            });
        return list;
    }

    // MARK: Векторы

    public void ReplaceChunks(long meetingId, List<(string Text, float[] Vector)> chunks)
    {
        using var tx = _db.BeginTransaction();
        Run("DELETE FROM chunks WHERE meeting_id=$p0", meetingId);
        foreach (var (t, v) in chunks) Run("INSERT INTO chunks(meeting_id, text, vector) VALUES($p0,$p1,$p2)", meetingId, t, Blob(v));
        tx.Commit();
    }

    public void AddDocChunks(long docId, List<(string Text, float[] Vector)> chunks)
    {
        using var tx = _db.BeginTransaction();
        foreach (var (t, v) in chunks) Run("INSERT INTO chunks(meeting_id, doc_id, text, vector) VALUES(0,$p0,$p1,$p2)", docId, t, Blob(v));
        tx.Commit();
    }

    public List<Chunk> AllChunks()
    {
        var list = new List<Chunk>();
        using var c = Cmd("SELECT c.meeting_id, c.text, c.vector, COALESCE(d.title, m.title, '') FROM chunks c LEFT JOIN documents d ON d.id=c.doc_id LEFT JOIN meetings m ON m.id=c.meeting_id");
        using var r = c.ExecuteReader();
        while (r.Read()) list.Add(new Chunk(r.GetInt64(0), r.GetString(1), Floats(r.GetValue(2)), r.GetString(3)));
        return list;
    }

    // MARK: Факты

    public List<Fact> Facts()
    {
        var list = new List<Fact>();
        using var c = Cmd("SELECT id,text,previous,meeting_id,created_at,updated_at,vector FROM facts ORDER BY updated_at DESC");
        using var r = c.ExecuteReader();
        while (r.Read())
            list.Add(new Fact
            {
                Id = r.GetInt64(0), Text = r.GetString(1), Previous = r.IsDBNull(2) ? "" : r.GetString(2), MeetingId = r.IsDBNull(3) ? 0 : r.GetInt64(3),
                CreatedAt = Local(r.GetDouble(4)), UpdatedAt = Local(r.GetDouble(5)), Vector = Floats(r.GetValue(6)),
            });
        return list;
    }

    public Fact AddFact(string text, long meetingId, float[] vector)
    {
        var now = DateTime.Now;
        long id = Insert("INSERT INTO facts(text, meeting_id, created_at, updated_at, vector) VALUES($p0,$p1,$p2,$p3,$p4)", text, meetingId, Unix(now), Unix(now), Blob(vector));
        return new Fact { Id = id, Text = text, MeetingId = meetingId, CreatedAt = now, UpdatedAt = now, Vector = vector };
    }

    /// <summary>Новая формулировка заменяет старую; старую храним, чтобы было видно, что изменилось.</summary>
    public void UpdateFact(Fact f) =>
        Run("UPDATE facts SET text=$p0, previous=$p1, meeting_id=$p2, updated_at=$p3, vector=$p4 WHERE id=$p5", f.Text, f.Previous, f.MeetingId, Unix(f.UpdatedAt), Blob(f.Vector), f.Id);

    public void DeleteFact(long id) => Run("DELETE FROM facts WHERE id=$p0", id);

    // MARK: Собеседования

    public InterviewData? Interview(long meetingId)
    {
        using var c = Cmd("SELECT data FROM interviews WHERE meeting_id=$p0", meetingId);
        return c.ExecuteScalar() is string json ? InterviewData.FromJson(json) : null;
    }

    public void SaveInterview(InterviewData iv) =>
        Run("INSERT OR REPLACE INTO interviews(meeting_id, data) VALUES($p0,$p1)", iv.MeetingId, iv.ToJson());

    public List<Vacancy> Vacancies()
    {
        var list = new List<Vacancy>();
        using var c = Cmd("SELECT id,title,text,notes,created_at FROM vacancies ORDER BY created_at DESC");
        using var r = c.ExecuteReader();
        while (r.Read()) list.Add(new Vacancy { Id = r.GetInt64(0), Title = r.GetString(1), Text = r.IsDBNull(2) ? "" : r.GetString(2), Notes = r.IsDBNull(3) ? "" : r.GetString(3), CreatedAt = Local(r.GetDouble(4)) });
        return list;
    }

    public Vacancy AddVacancy(string title, string text, string notes = "")
    {
        var now = DateTime.Now;
        long id = Insert("INSERT INTO vacancies(title, text, notes, created_at) VALUES($p0,$p1,$p2,$p3)", title, text, notes, Unix(now));
        return new Vacancy { Id = id, Title = title, Text = text, Notes = notes, CreatedAt = now };
    }

    public void Update(Vacancy v) => Run("UPDATE vacancies SET title=$p0, text=$p1, notes=$p2 WHERE id=$p3", v.Title, v.Text, v.Notes, v.Id);

    public void DeleteVacancy(long id)
    {
        Run("DELETE FROM resumes WHERE vacancy_id=$p0", id);
        Run("DELETE FROM vacancies WHERE id=$p0", id);
    }

    public List<Resume> Resumes()
    {
        var list = new List<Resume>();
        using var c = Cmd("SELECT id,vacancy_id,name,text,created_at FROM resumes ORDER BY created_at DESC");
        using var r = c.ExecuteReader();
        while (r.Read()) list.Add(new Resume { Id = r.GetInt64(0), VacancyId = r.IsDBNull(1) ? 0 : r.GetInt64(1), Name = r.GetString(2), Text = r.IsDBNull(3) ? "" : r.GetString(3), CreatedAt = Local(r.GetDouble(4)) });
        return list;
    }

    public Resume AddResume(long vacancyId, string name, string text)
    {
        var now = DateTime.Now;
        long id = Insert("INSERT INTO resumes(vacancy_id, name, text, created_at) VALUES($p0,$p1,$p2,$p3)", vacancyId, name, text, Unix(now));
        return new Resume { Id = id, VacancyId = vacancyId, Name = name, Text = text, CreatedAt = now };
    }

    public void Update(Resume r) => Run("UPDATE resumes SET vacancy_id=$p0, name=$p1, text=$p2 WHERE id=$p3", r.VacancyId, r.Name, r.Text, r.Id);
    public void DeleteResume(long id) => Run("DELETE FROM resumes WHERE id=$p0", id);

    // MARK: Документы

    public Doc AddDocument(string title, string path, int chars)
    {
        var now = DateTime.Now;
        long id = Insert("INSERT INTO documents(title, path, added_at, chars) VALUES($p0,$p1,$p2,$p3)", title, path, Unix(now), chars);
        return new Doc { Id = id, Title = title, Path = path, AddedAt = now, Chars = chars };
    }

    public List<Doc> Documents()
    {
        var list = new List<Doc>();
        using var c = Cmd("SELECT id,title,path,added_at,chars FROM documents ORDER BY added_at DESC");
        using var r = c.ExecuteReader();
        while (r.Read()) list.Add(new Doc { Id = r.GetInt64(0), Title = r.GetString(1), Path = r.GetString(2), AddedAt = Local(r.GetDouble(3)), Chars = r.GetInt32(4) });
        return list;
    }

    public void DeleteDocument(long id)
    {
        Run("DELETE FROM chunks WHERE doc_id=$p0", id);
        Run("DELETE FROM documents WHERE id=$p0", id);
    }
}
