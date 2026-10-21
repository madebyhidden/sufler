using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace Sufler;

/// <summary>Захват звука через WASAPI: микрофон или всё, что играет система. Отдаёт 16 кГц моно.</summary>
public sealed class AudioSource : IAudioInput, IDisposable
{
    private readonly bool _loopback;
    private WasapiCapture? _capture;
    private BufferedWaveProvider? _buffer;
    private ISampleProvider? _chain;
    private readonly float[] _tmp = new float[16000];

    public event Action<float[]>? Samples;

    public AudioSource(bool loopback) => _loopback = loopback;

    public void Start()
    {
        _capture = _loopback ? new WasapiLoopbackCapture() : new WasapiCapture();
        var fmt = _capture.WaveFormat;
        _buffer = new BufferedWaveProvider(fmt) { DiscardOnBufferOverflow = true, ReadFully = false, BufferDuration = TimeSpan.FromSeconds(5) };
        ISampleProvider s = _buffer.ToSampleProvider();
        if (fmt.Channels == 2) s = new StereoToMonoSampleProvider(s);
        else if (fmt.Channels > 2) s = new MultiToMono(s);
        _chain = new WdlResamplingSampleProvider(s, 16000);
        _capture.DataAvailable += (_, e) =>
        {
            if (e.BytesRecorded == 0 || _buffer is null || _chain is null) return;
            _buffer.AddSamples(e.Buffer, 0, e.BytesRecorded);
            int n;
            while ((n = _chain.Read(_tmp, 0, _tmp.Length)) > 0)
            {
                var chunk = new float[n];
                Array.Copy(_tmp, chunk, n);
                Samples?.Invoke(chunk);
                if (n < _tmp.Length) break;
            }
        };
        _capture.StartRecording();
    }

    public void Stop()
    {
        try { _capture?.StopRecording(); } catch { }
        _capture?.Dispose();
        _capture = null;
    }

    public void Dispose() => Stop();

    /// <summary>Сведение многоканального звука (5.1 и т. п.) в моно.</summary>
    private sealed class MultiToMono : ISampleProvider
    {
        private readonly ISampleProvider _src;
        private readonly int _ch;
        private float[] _buf = Array.Empty<float>();
        public WaveFormat WaveFormat { get; }

        public MultiToMono(ISampleProvider src)
        {
            _src = src;
            _ch = src.WaveFormat.Channels;
            WaveFormat = WaveFormat.CreateIeeeFloatWaveFormat(src.WaveFormat.SampleRate, 1);
        }

        public int Read(float[] buffer, int offset, int count)
        {
            int need = count * _ch;
            if (_buf.Length < need) _buf = new float[need];
            int got = _src.Read(_buf, 0, need) / _ch;
            for (int i = 0; i < got; i++)
            {
                float sum = 0;
                for (int c = 0; c < _ch; c++) sum += _buf[i * _ch + c];
                buffer[offset + i] = sum / _ch;
            }
            return got;
        }
    }
}
