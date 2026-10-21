namespace Sufler;

/// <summary>Режет поток 16 кГц на фразы по паузам. Та же логика, что в версии для Mac.</summary>
public sealed class Segmenter
{
    public readonly record struct Event(bool Final, float[] Samples);

    private const int Frame = 320; // 20 мс
    /// <summary>Сколько тишины считать концом фразы, в отсчётах (по умолчанию полсекунды).</summary>
    private readonly int _endSilence;

    public Segmenter(int endSilence = 16000 * 5 / 10) => _endSilence = endSilence;
    private readonly List<float> _pending = new();
    private readonly List<float> _preroll = new();
    private List<float> _buf = new();
    private readonly Queue<float> _recent = new();
    private bool _inSpeech;
    private int _silence, _voiced, _hot, _lastPartial;
    private float _noise = 0.001f;

    public bool Speaking => _inSpeech;

    public List<Event> Feed(float[] x)
    {
        var events = new List<Event>();
        _pending.AddRange(x);
        int i = 0;
        while (_pending.Count - i >= Frame)
        {
            float sum = 0;
            for (int k = i; k < i + Frame; k++) sum += _pending[k] * _pending[k];
            float rms = MathF.Sqrt(sum / Frame);
            _recent.Enqueue(rms);
            if (_recent.Count > 75) _recent.Dequeue();
            // Если фон вырос уже во время фразы, старая оценка тишины не даст заметить паузу
            float floor = MathF.Max(_noise, (_recent.Count >= 40 ? _recent.Min() : 0) * 1.3f);
            float thr = MathF.Max(0.0025f, floor * 3);
            bool loud = rms > thr;
            var frame = _pending.GetRange(i, Frame);
            i += Frame;

            if (!_inSpeech)
            {
                if (!loud) _noise = 0.97f * _noise + 0.03f * rms;
                _preroll.AddRange(frame);
                int keep = 16000 * 3 / 10;
                if (_preroll.Count > keep) _preroll.RemoveRange(0, _preroll.Count - keep);
                _hot = loud ? _hot + 1 : 0;
                if (_hot >= 3)
                {
                    _inSpeech = true;
                    _buf = new List<float>(_preroll);
                    _preroll.Clear();
                    _silence = 0;
                    _voiced = _hot * Frame;
                    _lastPartial = 0;
                    _hot = 0;
                }
                continue;
            }

            _buf.AddRange(frame);
            if (loud) { _silence = 0; _voiced += Frame; } else _silence += Frame;

            bool endOfPhrase = _silence >= _endSilence;
            bool longAndPaused = _buf.Count >= 16000 * 12 && _silence >= 16000 * 2 / 10;
            bool tooLong = _buf.Count >= 16000 * 20;
            if (endOfPhrase || longAndPaused || tooLong)
            {
                if (_voiced >= 16000 * 35 / 100) events.Add(new Event(true, _buf.ToArray()));
                Reset();
            }
            else if (_buf.Count - _lastPartial >= 16000 * 13 / 10 && _silence == 0)
            {
                _lastPartial = _buf.Count;
                events.Add(new Event(false, _buf.ToArray()));
            }
        }
        _pending.RemoveRange(0, i);
        return events;
    }

    public float[]? Flush()
    {
        var tail = _inSpeech && _voiced >= 16000 * 25 / 100 ? _buf.ToArray() : null;
        Reset();
        _pending.Clear();
        return tail;
    }

    private void Reset()
    {
        _buf = new List<float>();
        _inSpeech = false;
        _silence = _voiced = _hot = _lastPartial = 0;
    }
}
