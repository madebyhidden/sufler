using System.Collections.ObjectModel;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Sufler;

/// <summary>
/// Сохраняет распознанные фразы встречи в один сжатый файл, чтобы их можно было переслушать.
/// Пишется только речь, без тишины, кодеком Opus: час речи занимает около 11 МБ.
/// Формат свой и простой: метка «SFA1», затем кадры по 20 мс — длина (2 байта) и сжатые данные.
/// </summary>
public sealed class MeetingAudio : IDisposable
{
    private const int Frame = 320; // 20 мс при 16 кГц

    public static string Dir
    {
        get
        {
            var d = Path.Combine(Models.Root, "Audio");
            Directory.CreateDirectory(d);
            return d;
        }
    }

    public static string PathOf(long meetingId) => Path.Combine(Dir, meetingId + ".sfa");
    public static bool Exists(long meetingId) => File.Exists(PathOf(meetingId));

    public static void Delete(long meetingId)
    {
        try { File.Delete(PathOf(meetingId)); } catch { }
    }

    /// <summary>Убирает записи старше заданного числа дней.</summary>
    public static void Cleanup(int days)
    {
        try
        {
            foreach (var f in Directory.GetFiles(Dir))
                if (File.GetLastWriteTime(f) < DateTime.Now.AddDays(-days)) File.Delete(f);
        }
        catch { }
    }

    private FileStream? _file;
    private readonly Concentus.IOpusEncoder _encoder = Concentus.OpusCodecFactory.CreateEncoder(16000, 1, Concentus.Enums.OpusApplication.OPUS_APPLICATION_VOIP);
    private long _frames;
    private readonly byte[] _packet = new byte[1500];

    public MeetingAudio(long meetingId)
    {
        _encoder.Bitrate = 24000;
        _file = new FileStream(PathOf(meetingId), FileMode.Create, FileAccess.Write, FileShare.Read);
        _file.Write("SFA1"u8);
    }

    /// <summary>Дописывает фразу. Возвращает, где она лежит в файле: начало и конец в секундах.</summary>
    public (double Start, double End) Append(float[] samples)
    {
        if (_file is null || samples.Length == 0) return (0, 0);
        double start = _frames * Frame / 16000.0;
        var frame = new float[Frame];
        for (int i = 0; i < samples.Length; i += Frame)
        {
            int n = Math.Min(Frame, samples.Length - i);
            Array.Clear(frame);
            Array.Copy(samples, i, frame, 0, n);
            int len = _encoder.Encode(frame, Frame, _packet, _packet.Length);
            _file.WriteByte((byte)len);
            _file.WriteByte((byte)(len >> 8));
            _file.Write(_packet, 0, len);
            _frames++;
        }
        // Сразу на диск: если приложение упадёт, записанное останется
        _file.Flush();
        return (start, _frames * Frame / 16000.0);
    }

    /// <summary>Читает кусок записи (секунды от начала) обратно в звук 16 кГц.</summary>
    public static float[] Read(long meetingId, double start, double end)
    {
        using var f = new FileStream(PathOf(meetingId), FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        var head = new byte[4];
        if (f.Read(head) != 4 || head[0] != 'S' || head[1] != 'F' || head[2] != 'A') return [];
        long first = Math.Max(0, (long)(start * 16000 / Frame)), last = (long)Math.Ceiling(end * 16000 / Frame);
        // Декодеру нужно несколько кадров разгона перед нужным местом, иначе начало прозвучит с искажением
        long warm = Math.Max(0, first - 5);
        var decoder = Concentus.OpusCodecFactory.CreateDecoder(16000, 1);
        var pcm = new List<float>();
        var buf = new byte[1500];
        var frame = new float[Frame];
        var len2 = new byte[2];
        for (long i = 0; i < last; i++)
        {
            if (f.Read(len2) != 2) break;
            int len = len2[0] | len2[1] << 8;
            if (len <= 0 || len > buf.Length) break;
            if (i < warm) { f.Position += len; continue; }
            if (f.Read(buf, 0, len) != len) break;
            int n = decoder.Decode(buf.AsSpan(0, len), frame, Frame);
            if (i >= first) pcm.AddRange(frame.AsSpan(0, n));
        }
        return pcm.ToArray();
    }

    public void Dispose()
    {
        try { _file?.Dispose(); } catch { }
        _file = null;
    }
}

public static class Corrections
{
    /// <summary>Словарь исправлений хранится строками «как услышано = как правильно».</summary>
    public static List<(string Wrong, string Right)> Parse(string text)
    {
        var list = new List<(string, string)>();
        foreach (var line in text.Split('\n'))
        {
            var parts = line.Split('=');
            if (parts.Length != 2) continue;
            string a = parts[0].Trim(), b = parts[1].Trim();
            if (a.Length > 0 && b.Length > 0 && a != b) list.Add((a, b));
        }
        return list;
    }

    private static Regex Word(string w) => new(@"(?<![\p{L}\p{N}])" + Regex.Escape(w) + @"(?![\p{L}\p{N}])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>Заменяет слово целиком, без учёта регистра; внутри других слов ничего не трогает.</summary>
    public static string Replace(string text, string wrong, string right) => Word(wrong).Replace(text, _ => right);
    public static bool Contains(string text, string word) => Word(word).IsMatch(text);
    public static string Apply(string text, List<(string Wrong, string Right)> pairs) => pairs.Aggregate(text, (t, p) => Replace(t, p.Wrong, p.Right));
}

public sealed partial class AppCore
{
    // То, что даёт оболочка
    /// <summary>Проиграть звук 16 кГц; второй параметр — что вызвать по окончании. Возвращает «остановить».</summary>
    public Func<float[], Action, Action>? PlayAudio;
    /// <summary>Показать уведомление «похоже, начался звонок» (имя приложения).</summary>
    public Action<string>? OfferRecording;

    public const string DefaultWatchApps = "Zoom, Teams, Telegram, Discord, Slack, Skype, Webex, WhatsApp, Viber, Телемост, Толк, Chrome, Firefox, Edge, Yandex, Browser, Opera, Brave";

    public bool KeepAudio { get => Settings.Flag("keepAudio", true); set { Settings.SetFlag("keepAudio", value); Raise(); } }
    /// <summary>Словарь исправлений: строки «как услышано = как правильно».</summary>
    public string CorrectionsText { get => Settings.Get("corrections", ""); set { Settings.Set("corrections", value); Raise(); } }
    public bool WatchCalls { get => Settings.Flag("watchCalls", true); set { Settings.SetFlag("watchCalls", value); Raise(); } }
    public string WatchApps { get => Settings.Get("watchApps", DefaultWatchApps); set { Settings.Set("watchApps", value); Raise(); } }

    public ObservableCollection<NameCheck> NameChecks { get; } = new();
    private bool _checkingNames, _dictating;
    private string _callOffer = "", _chatInput = "";
    public bool CheckingNames { get => _checkingNames; private set => Set(ref _checkingNames, value); }
    public bool Dictating { get => _dictating; private set => Set(ref _dictating, value); }
    /// <summary>Приложение, в котором, похоже, начался звонок: показываем предложение начать запись.</summary>
    public string CallOffer { get => _callOffer; set => Set(ref _callOffer, value); }
    /// <summary>Текст в поле ввода чата: туда же пишет диктовка.</summary>
    public string ChatInput { get => _chatInput; set => Set(ref _chatInput, value); }

    private MeetingAudio? _audio;
    private Action? _stopPlayback;
    private Turn? _playing;
    private volatile Action<float[]>? _dictationSink;
    private IAudioInput? _dictationMic;
    private int _dictationToken;
    private string _dictationBase = "";
    private readonly Dictionary<string, DateTime> _lastCallOffer = new();

    /// <summary>Микрофон один, а слушателей двое: пока идёт диктовка, звук уходит ей и в расшифровку встречи не попадает.</summary>
    private void RouteMic(float[] samples)
    {
        var sink = _dictationSink;
        if (sink is not null) sink(samples);
        else _pipeline?.Feed(Speaker.Me, samples);
    }

    // MARK: Переслушать реплику

    private void RefreshCanPlay()
    {
        bool file = Selected is { } m && m.Id != RecordingId && PlayAudio is not null && MeetingAudio.Exists(m.Id);
        foreach (var t in Turns) t.CanPlay = file && t.AudioEnd > t.AudioStart;
        foreach (var c in NameChecks) c.CanPlay = Turns.FirstOrDefault(t => t.Id == c.TurnId)?.CanPlay == true;
    }

    /// <summary>Проиграть звук реплики; повторное нажатие останавливает.</summary>
    public void Play(Turn t)
    {
        bool same = ReferenceEquals(_playing, t);
        StopPlayback();
        if (same || !t.CanPlay || PlayAudio is null) return;
        try
        {
            var samples = MeetingAudio.Read(t.MeetingId, Math.Max(0, t.AudioStart - 0.1), t.AudioEnd);
            if (samples.Length == 0) return;
            _playing = t;
            t.Playing = true;
            _stopPlayback = PlayAudio(samples, () => Post(() => { if (ReferenceEquals(_playing, t)) StopPlayback(); }));
        }
        catch (Exception ex)
        {
            StopPlayback();
            ErrorText = "Не удалось проиграть запись: " + ex.Message;
        }
    }

    public void StopPlayback()
    {
        var stop = _stopPlayback;
        _stopPlayback = null;
        if (_playing is not null) _playing.Playing = false;
        _playing = null;
        try { stop?.Invoke(); } catch { }
    }

    public void PlayCheck(NameCheck c)
    {
        if (Turns.FirstOrDefault(t => t.Id == c.TurnId) is { } t) Play(t);
    }

    // MARK: Вопрос голосом

    /// <summary>Диктовка вопроса в чат: говорите — после паузы вопрос отправится сам. Повторное нажатие отменяет.</summary>
    public void ToggleDictation()
    {
        if (Dictating) { CancelDictation(); return; }
        if (!AsrReady || _speech is null) { ErrorText = "Распознавание речи ещё загружается."; return; }
        if (AudioFactory is null && _mic is null) { ErrorText = "Микрофон недоступен."; return; }
        int token = ++_dictationToken;
        _dictationBase = ChatInput.Trim().Length == 0 ? "" : ChatInput.Trim() + " ";
        // Для вопроса пауза длиннее, чем в разговоре: человек подбирает слова
        var seg = new Segmenter(16000 * 11 / 10);
        var engine = _speech;
        var gate = new object();
        bool closed = false;
        _dictationSink = samples =>
        {
            List<Segmenter.Event> events;
            lock (gate)
            {
                if (closed) return;
                events = seg.Feed(samples);
                if (events.Any(e => e.Final)) closed = true;
            }
            foreach (var e in events)
            {
                var ev = e;
                _ = Task.Run(async () =>
                {
                    try
                    {
                        var (text, _) = await engine.Transcribe(ev.Samples, !ev.Final);
                        Post(() =>
                        {
                            if (!Dictating || _dictationToken != token) return;
                            if (ev.Final) FinishDictation(text);
                            else if (text.Length > 0) ChatInput = _dictationBase + text;
                        });
                    }
                    catch { Post(() => { if (_dictationToken == token) CancelDictation(); }); }
                });
            }
        };
        // Вне записи (или при выключенном микрофоне) микрофон включаем сами и выключим после вопроса
        if (_mic is null)
        {
            try
            {
                _dictationMic = AudioFactory!(false);
                _dictationMic.Samples += RouteMic;
                _dictationMic.Start();
            }
            catch (Exception ex)
            {
                _dictationSink = null;
                _dictationMic = null;
                ErrorText = "Микрофон: " + ex.Message;
                return;
            }
        }
        Dictating = true;
        // Если так ничего и не сказали — не держим микрофон включённым
        _ = Task.Delay(12000).ContinueWith(_ => Post(() =>
        {
            if (Dictating && _dictationToken == token && (ChatInput == _dictationBase || ChatInput.Length == 0)) CancelDictation();
        }));
    }

    public void CancelDictation()
    {
        _dictationToken++;
        _dictationSink = null;
        try { _dictationMic?.Stop(); } catch { }
        _dictationMic = null;
        Dictating = false;
    }

    private void FinishDictation(string text)
    {
        var q = (_dictationBase + text).Trim();
        CancelDictation();
        if (text.Length == 0 || q.Length == 0) return;
        ChatInput = "";
        _ = Ask(q);
    }

    // MARK: Проверка названий

    private void LoadChecks(Meeting? m)
    {
        NameChecks.Clear();
        if (m is null || m.Checks.Length == 0) return;
        try
        {
            foreach (var c in JsonSerializer.Deserialize<List<NameCheck>>(m.Checks) ?? []) { c.Input = c.Guess; NameChecks.Add(c); }
        }
        catch { }
    }

    private void SaveChecks(Meeting m, List<NameCheck> list)
    {
        m.Checks = list.Count == 0 ? "" : JsonSerializer.Serialize(list);
        _store.Update(m);
        if (ReferenceEquals(Selected, m)) { LoadChecks(m); RefreshCanPlay(); }
    }

    private List<string> KnownNames =>
        Glossary.Split(',', '\n').Concat(Corrections.Parse(CorrectionsText).Select(p => p.Right)).Select(s => s.Trim()).Where(s => s.Length > 0).ToList();

    /// <summary>После встречи: просим модель показать названия и имена, которые, похоже, распознаны неверно.
    /// Пользователь подтверждает или исправляет — исправления уходят в словарь и применяются впредь.</summary>
    public async Task CheckNames(Meeting m)
    {
        if (!LlmReady) return;
        var all = _store.Turns(m.Id);
        if (all.Count < 2) return;
        CheckingNames = true;
        try
        {
            var text = TextTools.Tail(string.Join("\n", all.Select(t => t.Text)), _budget);
            var known = KnownNames;
            var system = """
                Расшифровка встречи сделана автоматически. Распознавание часто искажает имена, фамилии, названия компаний, продуктов, проектов и редкие профессиональные термины.
                Найди в тексте такие слова, которые выглядят искажёнными или бессмысленными либо одно и то же название записано по-разному.
                Для каждого верни:
                heard — слово или название точно так, как оно записано в расшифровке;
                guess — как оно, вероятно, пишется правильно; если не знаешь — пустая строка;
                quote — короткая цитата из расшифровки с этим словом, до 12 слов.
                Не включай обычные слова, разговорные словечки, числа и то, что написано правильно. Не больше 8 пунктов. Если ничего подозрительного нет — верни пустой список.
                """;
            if (known.Count > 0) system += "\nЭти названия уже проверены, их не включай: " + string.Join(", ", known);
            var schema = Schema("""{"type":"object","properties":{"items":{"type":"array","items":{"type":"object","properties":{"heard":{"type":"string"},"guess":{"type":"string"},"quote":{"type":"string"}},"required":["heard","guess","quote"],"additionalProperties":false}}},"required":["items"],"additionalProperties":false}""");
            var o = await _llm.ChatJson(system, text, schema, 700);
            var list = new List<NameCheck>();
            foreach (var it in (o?["items"] as JsonArray ?? []).Take(8))
            {
                var heard = (it?["heard"]?.GetValue<string>() ?? "").Trim(' ', '\n', '"', '«', '»', '.', ',');
                var guess = (it?["guess"]?.GetValue<string>() ?? "").Trim(' ', '\n', '"', '«', '»', '.');
                // Берём только то, что действительно есть в тексте, и не длиннее названия из трёх слов
                if (heard.Length < 3 || heard.Split(' ').Length > 3) continue;
                var turn = all.FirstOrDefault(t => Corrections.Contains(t.Text, heard));
                if (turn is null) continue;
                bool Same(string a) => string.Equals(a, heard, StringComparison.OrdinalIgnoreCase);
                if (known.Any(Same) || list.Any(c => Same(c.Heard))) continue;
                if (Same(guess)) guess = "";
                // Числа и даты модель иногда отмечает зря: без догадки, как правильно, их не показываем
                if (guess.Length == 0 && heard.Any(char.IsDigit)) continue;
                // Лёгкая модель без догадки отмечает обычные имена («Марина», «Денис») — такие пункты только мешают
                if (guess.Length == 0 && Models.CustomChat.Length == 0 && Models.Profile == "e2b") continue;
                list.Add(new NameCheck { Heard = heard, Guess = guess, Quote = Snippet(turn.Text, heard), TurnId = turn.Id });
            }
            SaveChecks(m, list);
        }
        catch (Exception ex) { Log("проверка названий: " + ex.Message); }
        finally { CheckingNames = false; }
    }

    /// <summary>Кусочек реплики вокруг слова — чтобы было понятно, о чём речь.</summary>
    private static string Snippet(string text, string word)
    {
        int i = text.IndexOf(word, StringComparison.OrdinalIgnoreCase);
        if (i < 0) return TextTools.Head(text, 90);
        int from = Math.Max(0, i - 45), to = Math.Min(text.Length, i + word.Length + 45);
        return (from > 0 ? "…" : "") + text[from..to] + (to < text.Length ? "…" : "");
    }

    private void AddToGlossary(string name)
    {
        var n = name.Trim();
        if (n.Length == 0 || Glossary.Split(',', '\n').Any(k => string.Equals(k.Trim(), n, StringComparison.OrdinalIgnoreCase))) return;
        var g = Glossary.Trim();
        Glossary = g.Length == 0 ? n : g + ", " + n;
    }

    /// <summary>Ответ пользователя по слову: right — как правильно. Пусто или то же самое — слово было записано верно.</summary>
    public void ResolveCheck(NameCheck check, string right)
    {
        if (Selected is not { } m) return;
        var fixedName = right.Trim();
        var rest = NameChecks.Where(c => !ReferenceEquals(c, check)).ToList();
        if (fixedName.Length == 0 || fixedName == check.Heard)
        {
            AddToGlossary(check.Heard);
            SaveChecks(m, rest);
            return;
        }
        // В словарь — чтобы в следующих встречах это слово сразу писалось правильно
        var line = $"{check.Heard} = {fixedName}";
        var c0 = CorrectionsText.Trim();
        CorrectionsText = c0.Length == 0 ? line : c0 + "\n" + line;
        AddToGlossary(fixedName);

        // И исправляем уже записанное в этой встрече: реплики, вопросы, итог, название, факты
        string Fix(string s) => Corrections.Replace(s, check.Heard, fixedName);
        foreach (var t in Turns.Where(t => Corrections.Contains(t.Text, check.Heard)).ToList())
        {
            t.Text = Fix(t.Text);
            _store.UpdateTurn(t);
        }
        foreach (var q in Questions)
        {
            string before = q.Text + q.Topic + q.Context + q.Addressee;
            q.Text = Fix(q.Text); q.Topic = Fix(q.Topic); q.Context = Fix(q.Context); q.Addressee = Fix(q.Addressee);
            if (before != q.Text + q.Topic + q.Context + q.Addressee) _store.Update(q);
        }
        m.Summary = Fix(m.Summary);
        m.Title = Fix(m.Title);
        foreach (var f in Facts.Where(f => f.MeetingId == m.Id && Corrections.Contains(f.Text, check.Heard)))
        {
            f.Text = Fix(f.Text);
            _store.UpdateFact(f);
        }
        _meetingVectors.Clear();
        SaveChecks(m, rest);
    }

    // MARK: Начался звонок

    /// <summary>Оболочка сообщает: приложение начало пользоваться микрофоном. name — как его показать, haystack — с чем сверять список.</summary>
    public void MicStartedBy(string name, string haystack)
    {
        if (!WatchCalls || IsRecording || RecordingId != 0 || !AsrReady) return;
        var hay = haystack.ToLowerInvariant();
        var list = WatchApps.Split(',', '\n').Select(s => s.Trim().ToLowerInvariant()).Where(s => s.Length > 0);
        if (!list.Any(hay.Contains)) return;
        // Одно и то же приложение не предлагаем чаще раза в пять минут: микрофон в звонке включают и выключают
        if (_lastCallOffer.TryGetValue(name, out var last) && (DateTime.UtcNow - last).TotalSeconds < 300) return;
        _lastCallOffer[name] = DateTime.UtcNow;
        CallOffer = name;
        OfferRecording?.Invoke(name);
        _ = Task.Delay(60000).ContinueWith(_ => Post(() => { if (CallOffer == name) CallOffer = ""; }));
    }

    /// <summary>Согласие на предложение начать запись.</summary>
    public void AcceptCallOffer()
    {
        CallOffer = "";
        if (!IsRecording && AsrReady) ToggleRecording();
    }
}
