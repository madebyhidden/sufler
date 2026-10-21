using System.Diagnostics;
using System.IO;
using System.Windows.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Sufler;

/// <summary>Проигрывание сохранённого звука реплики.</summary>
public static class Player
{
    /// <summary>Играет звук 16 кГц; возвращает действие «остановить».</summary>
    public static Action Play(float[] samples, Action done)
    {
        var bytes = new byte[samples.Length * 2];
        for (int i = 0; i < samples.Length; i++)
        {
            short v = (short)Math.Clamp(samples[i] * 32767f, short.MinValue, short.MaxValue);
            bytes[i * 2] = (byte)v;
            bytes[i * 2 + 1] = (byte)(v >> 8);
        }
        var stream = new RawSourceWaveStream(new MemoryStream(bytes), new WaveFormat(16000, 16, 1));
        var output = new WaveOutEvent();
        bool finished = false;
        output.PlaybackStopped += (_, _) =>
        {
            if (finished) return;
            finished = true;
            try { output.Dispose(); stream.Dispose(); } catch { }
            done();
        };
        output.Init(stream);
        output.Play();
        return () => { try { output.Stop(); } catch { } };
    }
}

/// <summary>
/// Следит, какие приложения включили микрофон: если это приложение для звонков или браузер —
/// скорее всего, начался созвон, и стоит предложить запись.
/// </summary>
public sealed class CallWatcher
{
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(3) };
    private HashSet<int> _active = new();
    private bool _primed;
    /// <summary>Приложение только что начало пользоваться микрофоном: как его показать и с чем сверять список.</summary>
    public event Action<string, string>? MicStarted;

    public CallWatcher() => _timer.Tick += (_, _) => Poll();

    public void Start() => _timer.Start();
    public void Stop() { _timer.Stop(); _active = new(); _primed = false; }

    private void Poll()
    {
        var now = new HashSet<int>();
        try
        {
            using var devices = new MMDeviceEnumerator();
            foreach (var device in devices.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
            {
                try
                {
                    var manager = device.AudioSessionManager;
                    manager.RefreshSessions();
                    var sessions = manager.Sessions;
                    for (int i = 0; i < sessions.Count; i++)
                    {
                        var s = sessions[i];
                        int pid = (int)s.GetProcessID;
                        if (s.State == NAudio.CoreAudioApi.Interfaces.AudioSessionState.AudioSessionStateActive && pid != 0 && pid != Environment.ProcessId) now.Add(pid);
                    }
                }
                catch { }
                finally { device.Dispose(); }
            }
        }
        catch { return; }
        // При первом проходе только запоминаем, кто уже с микрофоном: звонок, начатый до нас, не «начался»
        var fresh = _primed ? now.Where(p => !_active.Contains(p)).ToList() : [];
        _active = now;
        _primed = true;
        foreach (int pid in fresh)
        {
            var (name, haystack) = Describe(pid);
            if (name.Length > 0) MicStarted?.Invoke(name, haystack);
        }
    }

    /// <summary>Понятное имя приложения: «Zoom Meetings», «Google Chrome» — из описания его файла.</summary>
    private static (string Name, string Haystack) Describe(int pid)
    {
        try
        {
            using var p = Process.GetProcessById(pid);
            string exe = p.ProcessName, desc = "", product = "";
            try
            {
                var info = p.MainModule?.FileVersionInfo;
                desc = info?.FileDescription?.Trim() ?? "";
                product = info?.ProductName?.Trim() ?? "";
            }
            catch { }
            string name = desc.Length > 0 ? desc : product.Length > 0 ? product : exe;
            return (name, $"{exe} {desc} {product}");
        }
        catch { return ("", ""); }
    }
}
