using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Whisper.net;
using Whisper.net.LibraryLoader;

namespace Sufler;

/// <summary>Распознавание речи: тот же Whisper large-v3-turbo q5, что и на Mac. Один поток работы с моделью.</summary>
public sealed class WhisperEngine : ISpeechEngine
{
    private readonly WhisperFactory _factory;
    private readonly WhisperProcessor _final;
    private readonly WhisperProcessor _fast;
    private readonly SemaphoreSlim _gate = new(1, 1);

    /// <summary>На чём реально считает модель: видеокарта (Vulkan/CUDA) или процессор.</summary>
    public string Backend { get; }
    public string Name => "Whisper turbo";

    public WhisperEngine(string modelPath, string language, bool gpu)
    {
        // На отдельной видеокарте Whisper летает; на встроенной графике он медленнее, чем на процессоре
        // (на ноутбуке с Iris Xe фраза в 2,3 с распознавалась 3,8 с), поэтому там видеокарту не трогаем
        RuntimeOptions.RuntimeLibraryOrder = gpu ? [RuntimeLibrary.Cuda, RuntimeLibrary.Vulkan, RuntimeLibrary.Cpu] : [RuntimeLibrary.Cpu];
        _factory = WhisperFactory.FromPath(modelPath);
        Backend = RuntimeOptions.LoadedLibrary?.ToString() ?? "неизвестно";
        int threads = Math.Clamp(Environment.ProcessorCount / 2, 2, 8);
        _final = _factory.CreateBuilder().WithLanguage(language).WithThreads(threads).WithNoContext().WithProbabilities().Build();
        _fast = _factory.CreateBuilder().WithLanguage(language).WithThreads(threads).WithNoContext().Build();
    }

    public async Task<(string Text, double Seconds)> Transcribe(float[] input, bool fast)
    {
        await _gate.WaitAsync();
        try
        {
            var sw = Stopwatch.StartNew();
            double seconds = input.Length / 16000.0;
            var samples = SpeechText.Normalize(input);
            // Whisper отказывается от аудио короче секунды
            int min = 16000 + 3200;
            if (samples.Length < min) Array.Resize(ref samples, min);

            var sb = new StringBuilder();
            float probSum = 0;
            int probCount = 0;
            await foreach (var seg in (fast ? _fast : _final).ProcessAsync(samples))
            {
                if (seg.NoSpeechProbability > 0.6f) continue;
                sb.Append(seg.Text);
                if (!fast) { probSum += seg.Probability; probCount++; }
            }
            var text = SpeechText.Clean(sb.ToString());
            if (!fast && text.Length > 0 && probCount > 0)
            {
                // Чем короче звук, тем строже: короткие шумы и междометия превращаются в выдуманные слова
                float confidence = probSum / probCount;
                float floor = seconds < 1.5 ? 0.6f : seconds < 3 ? 0.45f : 0.3f;
                if (confidence < floor) text = "";
            }
            return (text, sw.Elapsed.TotalSeconds);
        }
        finally { _gate.Release(); }
    }

    public void Dispose()
    {
        _final.Dispose();
        _fast.Dispose();
        _factory.Dispose();
    }
}
