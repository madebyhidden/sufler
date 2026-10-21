using System.Diagnostics;
using System.Text.RegularExpressions;
using SherpaOnnx;

namespace Sufler;

/// <summary>Распознавание речи: общий вид для обоих движков.</summary>
public interface ISpeechEngine : IDisposable
{
    string Name { get; }
    /// <summary>На чём считает модель: процессор или видеокарта.</summary>
    string Backend { get; }
    Task<(string Text, double Seconds)> Transcribe(float[] input, bool fast);
}

/// <summary>
/// GigaAM v3 (Сбер) — модель именно для русской речи, сразу с пунктуацией. На обычном процессоре ноутбука
/// работает в десятки раз быстрее реального времени, видеокарта ей не нужна.
/// </summary>
public sealed class GigaEngine : ISpeechEngine
{
    private readonly OfflineRecognizer _rec;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public string Name => "GigaAM v3";
    public string Backend { get; }

    public GigaEngine(string modelPath, string tokensPath)
    {
        int threads = Math.Clamp(Environment.ProcessorCount / 4, 2, 4);
        var c = new OfflineRecognizerConfig();
        c.FeatConfig.SampleRate = 16000;
        c.FeatConfig.FeatureDim = 64;
        c.ModelConfig.NeMoCtc.Model = modelPath;
        c.ModelConfig.Tokens = tokensPath;
        c.ModelConfig.NumThreads = threads;
        c.ModelConfig.Provider = "cpu";
        c.DecodingMethod = "greedy_search";
        _rec = new OfflineRecognizer(c);
        Backend = $"процессор, {threads} потока";
    }

    public async Task<(string Text, double Seconds)> Transcribe(float[] input, bool fast)
    {
        await _gate.WaitAsync();
        try
        {
            var sw = Stopwatch.StartNew();
            var samples = SpeechText.Normalize(input);
            // Совсем короткий звук модель не переваривает — дополняем тишиной до полсекунды
            if (samples.Length < 8000) Array.Resize(ref samples, 8000);
            string text = await Task.Run(() =>
            {
                using var s = _rec.CreateStream();
                s.AcceptWaveform(16000, samples);
                _rec.Decode(s);
                return s.Result.Text ?? "";
            });
            return (SpeechText.Clean(text), sw.Elapsed.TotalSeconds);
        }
        finally { _gate.Release(); }
    }

    public void Dispose() => _rec.Dispose();
}

/// <summary>Общая для движков подготовка звука и чистка текста.</summary>
public static class SpeechText
{
    /// <summary>Тихую речь подтягиваем до рабочего уровня.</summary>
    public static float[] Normalize(float[] input)
    {
        var samples = (float[])input.Clone();
        float peak = 0;
        foreach (var v in samples) peak = MathF.Max(peak, MathF.Abs(v));
        if (peak > 0.002f && peak < 0.5f)
        {
            float gain = MathF.Min(0.7f / peak, 10);
            for (int i = 0; i < samples.Length; i++) samples[i] *= gain;
        }
        return samples;
    }

    private static readonly string[] Junk =
    [
        "продолжение следует", "субтитры", "редактор субтитров", "корректор", "спасибо за просмотр",
        "подписывайтесь на канал", "thanks for watching", "thank you for watching", "dimatorzok",
    ];

    public static string Clean(string s)
    {
        var t = Regex.Replace(s.Replace("\n", " "), @"\[[^\]]*\]|\([^)]*\)|\*[^*]*\*", "").Trim();
        var low = t.ToLowerInvariant();
        if (low.Length < 60 && Junk.Any(low.Contains)) return "";
        if (!t.Any(char.IsLetterOrDigit)) return "";
        var w = low.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (w.Length >= 12 && w.Distinct().Count() * 4 < w.Length) return "";
        return t;
    }
}
