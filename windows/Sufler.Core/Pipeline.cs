namespace Sufler;

/// <summary>Связывает источники звука с распознаванием: готовые фразы идут по очереди, черновики — только когда движок свободен.</summary>
public sealed class Pipeline
{
    private readonly ISpeechEngine _engine;
    private readonly object _lock = new();
    private readonly Dictionary<string, Segmenter> _segmenters = new() { [Speaker.Me] = new(), [Speaker.Them] = new() };
    private readonly Queue<(string Speaker, float[] Samples, DateTime End)> _finals = new();
    private readonly Dictionary<string, (float[] Samples, DateTime End)> _partials = new();
    private bool _busy;
    /// <summary>Громкость звука звонка по кадрам 20 мс за последнюю минуту — чтобы узнавать его эхо в микрофоне.</summary>
    private readonly List<float> _systemEnv = new();
    private DateTime _systemEnvEnd;
    private readonly Dictionary<string, bool> _active = new();
    private readonly Dictionary<string, DateTime> _quietSince = new();

    public VoiceId? Voice;
    /// <summary>Черновик фразы (пустая строка — убрать черновик).</summary>
    public Action<string, string>? OnPartial;
    /// <summary>Готовая фраза: кто, текст, номер голоса, сам звук (чтобы его сохранить), за сколько распознана.</summary>
    public Action<string, string, int, float[], double>? OnFinal;
    /// <summary>Индикатор «есть звук»: сообщаем только смену состояния.</summary>
    public Action<string, bool>? OnLevel;

    public Pipeline(ISpeechEngine engine) => _engine = engine;

    /// <summary>Говорит ли кто-нибудь прямо сейчас (фраза начата и ещё не закончена).</summary>
    public bool AnyoneSpeaking { get { lock (_lock) return _segmenters.Values.Any(s => s.Speaking); } }
    /// <summary>Есть нераспознанные фразы.</summary>
    public bool Pending { get { lock (_lock) return _busy || _finals.Count > 0; } }

    public void Reset()
    {
        lock (_lock)
        {
            _segmenters[Speaker.Me] = new();
            _segmenters[Speaker.Them] = new();
            _finals.Clear();
            _partials.Clear();
            _systemEnv.Clear();
            _active.Clear();
            _quietSince.Clear();
        }
    }

    public void Feed(string speaker, float[] samples)
    {
        var now = DateTime.UtcNow;
        bool? level = null;
        lock (_lock)
        {
            float peak = 0;
            foreach (var v in samples) peak = MathF.Max(peak, MathF.Abs(v));
            bool loud = peak > 0.02f;
            if (loud) _quietSince.Remove(speaker); else _quietSince.TryAdd(speaker, now);
            // Гаснет индикатор не сразу, а через 0,4 с тишины — чтобы не мигал между словами
            bool was = _active.GetValueOrDefault(speaker);
            bool on = loud || (was && (now - _quietSince.GetValueOrDefault(speaker, now)).TotalSeconds < 0.4);
            if (on != was) { _active[speaker] = on; level = on; }

            if (speaker == Speaker.Them)
            {
                _systemEnv.AddRange(Envelope(samples));
                if (_systemEnv.Count > 3000) _systemEnv.RemoveRange(0, _systemEnv.Count - 3000);
                _systemEnvEnd = now;
            }
            foreach (var ev in _segmenters[speaker].Feed(samples))
            {
                if (ev.Final) { _partials.Remove(speaker); _finals.Enqueue((speaker, ev.Samples, now)); }
                else _partials[speaker] = (ev.Samples, now);
            }
        }
        if (level is { } l) OnLevel?.Invoke(speaker, l);
        Pump();
    }

    /// <summary>Остановка записи: недоговорённые хвосты отправляем на распознавание.</summary>
    public void Flush(string? only = null)
    {
        lock (_lock)
        {
            foreach (var (sp, seg) in _segmenters)
            {
                if (only is not null && sp != only) continue;
                if (seg.Flush() is { } tail) _finals.Enqueue((sp, tail, DateTime.UtcNow));
                _partials.Remove(sp);
            }
        }
        Pump();
    }

    private static List<float> Envelope(float[] x)
    {
        var list = new List<float>(x.Length / 320);
        for (int i = 0; i + 320 <= x.Length; i += 320)
        {
            float sum = 0;
            for (int k = i; k < i + 320; k++) sum += x[k] * x[k];
            list.Add(MathF.Sqrt(sum / 320));
        }
        return list;
    }

    /// <summary>
    /// Насколько фраза из микрофона повторяет по рисунку громкости то, что в это же время играло в звонке.
    /// Эхо из колонок повторяет его почти точно (с небольшой задержкой), собственная речь — нет.
    /// </summary>
    private float EchoScore(float[] mic, DateTime end)
    {
        var m = Envelope(mic);
        if (m.Count < 25 || _systemEnv.Count == 0) return 0;
        float best = 0;
        // Микрофон слышит колонки с задержкой; плюс неточность наших отметок времени
        for (int lag = -10; lag <= 30; lag += 2)
        {
            int endIdx = _systemEnv.Count - 1 - (int)((_systemEnvEnd - end).TotalSeconds / 0.02) - lag;
            int startIdx = endIdx - m.Count + 1;
            if (startIdx < 0 || endIdx >= _systemEnv.Count) continue;
            float ms = 0, ss = 0;
            for (int k = 0; k < m.Count; k++) { ms += m[k]; ss += _systemEnv[startIdx + k]; }
            ms /= m.Count; ss /= m.Count;
            // В звонке в это время тихо — эху взяться неоткуда
            if (ss <= 0.002f) continue;
            float num = 0, dm = 0, ds = 0;
            for (int k = 0; k < m.Count; k++)
            {
                float a = m[k] - ms, b = _systemEnv[startIdx + k] - ss;
                num += a * b; dm += a * a; ds += b * b;
            }
            float r = num / (MathF.Sqrt(dm * ds) + 1e-9f);
            if (r > best) best = r;
        }
        return best;
    }

    private void Pump()
    {
        string speaker;
        float[] samples;
        DateTime end;
        bool final;
        lock (_lock)
        {
            if (_busy) return;
            while (true)
            {
                if (_finals.Count > 0) { (speaker, samples, end) = _finals.Dequeue(); final = true; }
                else if (_partials.Count > 0)
                {
                    speaker = _partials.Keys.First();
                    (samples, end) = _partials[speaker];
                    _partials.Remove(speaker);
                    final = false;
                }
                else return;
                // Микрофон поймал звук из колонок — не распознаём вовсе
                if (speaker == Speaker.Me && EchoScore(samples, end) > 0.6f)
                {
                    if (final) { var sp = speaker; Task.Run(() => OnPartial?.Invoke(sp, "")); }
                    continue;
                }
                break;
            }
            _busy = true;
        }
        _ = Task.Run(async () =>
        {
            try
            {
                if (!final)
                {
                    var (text, _) = await _engine.Transcribe(samples, true);
                    bool stale;
                    lock (_lock) stale = _finals.Any(f => f.Speaker == speaker);
                    if (text.Length > 0 && !stale) OnPartial?.Invoke(speaker, text);
                }
                else
                {
                    // Если внутри фразы сменился говорящий (перебили без паузы) — режем её по этой границе
                    int channel = speaker == Speaker.Me ? 0 : 1;
                    var parts = Voice?.Split(samples) ?? [(0, samples.Length)];
                    var done = new List<(string Text, int Who, float[] Samples, double Took)>();
                    foreach (var (from, to) in parts)
                    {
                        var piece = parts.Count == 1 ? samples : samples[from..to];
                        var (text, took) = await _engine.Transcribe(piece, false);
                        if (text.Length == 0) continue;
                        // Голоса различаем в обоих каналах: за одним микрофоном тоже может быть несколько человек
                        int who = Voice?.Identify(piece, channel) ?? 0;
                        if (who != -1) done.Add((text, who, piece, took));
                    }
                    OnPartial?.Invoke(speaker, "");
                    foreach (var d in done) OnFinal?.Invoke(speaker, d.Text, d.Who, d.Samples, d.Took);
                }
            }
            catch { }
            lock (_lock) _busy = false;
            Pump();
        });
    }
}
