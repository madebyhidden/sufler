using SherpaOnnx;

namespace Sufler;

/// <summary>Различает собеседников по голосу: снимает «отпечаток» с каждой фразы и сопоставляет с уже слышанными.</summary>
public sealed class VoiceId : IDisposable
{
    private readonly SpeakerEmbeddingExtractor _extractor;
    private readonly OfflineSpeakerDiarization? _diarizer;
    private readonly object _gate = new();

    /// <summary>Отпечатки голосов ведём отдельно по каналам: микрофон и звук звонка не смешиваются.</summary>
    private sealed class Channel
    {
        public readonly List<float[]> Centroids = new();
        public readonly List<int> Counts = new();
        public int Last;
    }
    private readonly Dictionary<int, Channel> _channels = new();

    // Пороги сходства подобраны на записях разных людей (модель CAM++): один и тот же голос даёт 0,7–0,9,
    // разные — обычно 0,1–0,4
    private const float Same = 0.55f, Maybe = 0.42f;

    public VoiceId(string printModel, string? segmentModel)
    {
        int threads = Math.Clamp(Environment.ProcessorCount / 4, 1, 2);
        var c = new SpeakerEmbeddingExtractorConfig { Model = printModel, NumThreads = threads, Provider = "cpu" };
        _extractor = new SpeakerEmbeddingExtractor(c);
        if (segmentModel is not null && File.Exists(segmentModel))
        {
            var d = new OfflineSpeakerDiarizationConfig();
            d.Segmentation.Pyannote.Model = segmentModel;
            d.Segmentation.NumThreads = threads;
            d.Embedding.Model = printModel;
            d.Embedding.NumThreads = threads;
            d.Clustering.NumClusters = -1;
            d.Clustering.Threshold = 0.6f;
            d.MinDurationOn = 0.3f;
            d.MinDurationOff = 0.3f;
            try { _diarizer = new OfflineSpeakerDiarization(d); } catch { _diarizer = null; }
        }
    }

    public void Reset() { lock (_gate) _channels.Clear(); }

    public float[]? Print(float[] samples)
    {
        using var s = _extractor.CreateStream();
        s.AcceptWaveform(16000, samples);
        s.InputFinished();
        if (!_extractor.IsReady(s)) return null;
        var e = _extractor.Compute(s);
        return e is { Length: > 0 } ? e : null;
    }

    /// <summary>Номер говорящего с единицы; 0 — определить не удалось; -1 — в микрофон попал голос из колонок (эхо звонка).</summary>
    public int Identify(float[] input, int channel)
    {
        lock (_gate)
        {
            if (!_channels.TryGetValue(channel, out var st)) _channels[channel] = st = new Channel();
            // В хвосте фразы — пауза, по которой её отрезали; в отпечаток она не нужна
            var s = input;
            if (s.Length > 16000 * 2) s = s[..^8000];
            if (s.Length > 160_000) s = s[..160_000];
            double seconds = s.Length / 16000.0;
            float[]? e = null;
            if (seconds >= 0.8) { try { e = Print(s); } catch { } }
            if (e is null) return st.Last;

            // Микрофон услышал того же, кто сейчас звучит в звонке, — это колонки, а не новый человек
            if (channel == 0 && _channels.TryGetValue(1, out var call) && call.Centroids.Any(c => TextTools.Cosine(c, e) >= Same)) return -1;

            int best = -1;
            float bestSim = -1;
            for (int i = 0; i < st.Centroids.Count; i++)
            {
                float sim = TextTools.Cosine(st.Centroids[i], e);
                if (sim > bestSim) { bestSim = sim; best = i; }
            }
            // Уверенное совпадение: уточняем отпечаток говорящего
            if (best >= 0 && bestSim >= Same)
            {
                Update(st, best, e);
                return st.Last = best + 1;
            }
            // Похоже, но не наверняка — относим к ближайшему, отпечаток не трогаем
            if (best >= 0 && (bestSim >= Maybe || seconds < 2.0)) return st.Last = best + 1;
            // Новый голос заводим только по достаточно длинной фразе
            if (seconds >= 2.0 || st.Centroids.Count == 0)
            {
                st.Centroids.Add(e);
                st.Counts.Add(1);
                return st.Last = st.Centroids.Count;
            }
            return st.Last;
        }
    }

    private static void Update(Channel st, int i, float[] e)
    {
        float n = Math.Min(st.Counts[i], 20);
        var c = st.Centroids[i];
        float norm = 0;
        for (int k = 0; k < c.Length; k++) { c[k] = (c[k] * n + e[k]) / (n + 1); norm += c[k] * c[k]; }
        norm = MathF.Sqrt(norm) + 1e-9f;
        // Отпечаток модели не единичной длины — сохраняем его масштаб, сравнение всё равно идёт по косинусу
        float scale = MathF.Sqrt(e.Sum(x => x * x)) / norm;
        for (int k = 0; k < c.Length; k++) c[k] *= scale;
        st.Counts[i]++;
    }

    /// <summary>Делит фразу на части по смене говорящего. Если говорит один человек — возвращает её целиком.</summary>
    public List<(int From, int To)> Split(float[] samples)
    {
        var whole = new List<(int, int)> { (0, samples.Length) };
        // На коротком звуке смену голоса надёжно не поймать
        if (_diarizer is null || samples.Length < 16000 * 4) return whole;
        lock (_gate)
        {
            OfflineSpeakerDiarizationSegment[] segs;
            try { segs = _diarizer.Process(samples); } catch { return whole; }
            // Склеиваем подряд идущие куски одного голоса, мелочь короче 0,7 с не считаем отдельным говорящим
            var runs = new List<(int Id, float Start, float End)>();
            foreach (var seg in segs.OrderBy(x => x.Start))
            {
                if (seg.End - seg.Start < 0.7f) continue;
                if (runs.Count > 0 && runs[^1].Id == seg.Speaker) runs[^1] = (seg.Speaker, runs[^1].Start, seg.End);
                else runs.Add((seg.Speaker, seg.Start, seg.End));
            }
            if (runs.Count < 2) return whole;
            var cuts = new List<int>();
            for (int i = 1; i < runs.Count; i++)
            {
                // Граница — между концом одного и началом другого; уточняем по самому тихому месту рядом
                int mid = (int)((runs[i - 1].End + runs[i].Start) / 2 * 16000);
                int lo = Math.Max(0, mid - 4000), hi = Math.Min(samples.Length - 320, mid + 4000);
                if (lo >= hi) continue;
                int best = mid;
                float bestE = float.MaxValue;
                for (int k = lo; k < hi; k += 160)
                {
                    float en = 0;
                    for (int j = k; j < k + 320; j++) en += samples[j] * samples[j];
                    if (en < bestE) { bestE = en; best = k + 160; }
                }
                cuts.Add(best);
            }
            var ranges = new List<(int, int)>();
            int from = 0;
            foreach (int c in cuts)
            {
                if (c - from < 16000 * 7 / 10 || samples.Length - c < 16000 * 7 / 10) continue;
                ranges.Add((from, c));
                from = c;
            }
            ranges.Add((from, samples.Length));
            return ranges;
        }
    }

    public void Dispose()
    {
        _extractor.Dispose();
        _diarizer?.Dispose();
    }
}
