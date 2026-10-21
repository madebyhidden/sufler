"""Музыка и звуковые эффекты для ролика — синтезированы с нуля, без чужих сэмплов (никаких авторских прав).
Запуск: python make_sound.py out.wav   (нужен numpy)"""
import sys, wave
import numpy as np

SR = 44100
DUR = 33.0
BPM = 100
BEAT = 60 / BPM
N = int(SR * DUR)
rng = np.random.default_rng(7)
music = np.zeros((N, 2))
sfx = np.zeros((N, 2))


def note(f):  # MIDI → Гц
    return 440 * 2 ** ((f - 69) / 12)


def place(buf, t, sig, pan=0.0, gain=1.0):
    i = int(t * SR)
    if i >= N: return
    sig = sig[: N - i]
    l, r = np.cos((pan + 1) * np.pi / 4), np.sin((pan + 1) * np.pi / 4)
    buf[i:i + len(sig), 0] += sig * l * gain
    buf[i:i + len(sig), 1] += sig * r * gain


def env(n, a=0.005, d=0.3):
    t = np.arange(n) / SR
    e = np.minimum(1, t / max(a, 1e-4)) * np.exp(-t / d)
    return e


def lowpass(x, cutoff):
    a = np.exp(-2 * np.pi * cutoff / SR)
    y = np.empty_like(x); s = 0.0
    for i in range(len(x)):
        s = (1 - a) * x[i] + a * s; y[i] = s
    return y


def highpass(x, cutoff):
    return x - lowpass(x, cutoff)


# Гармония: Am — F — C — G, по такту (4 доли) на аккорд
chords = [[57, 60, 64], [53, 57, 60], [48, 52, 55, 60], [55, 59, 62]]
bass_roots = [45, 41, 48, 43]
bar = 4 * BEAT

# Подушка: мягкая пила с расстройкой, сглаженная
t_all = np.arange(N) / SR
pad = np.zeros(N)
for b in range(int(DUR / bar) + 1):
    ch = chords[b % 4]
    i0, i1 = int(b * bar * SR), min(N, int((b + 1) * bar * SR) + int(0.3 * SR))
    tt = np.arange(i1 - i0) / SR
    seg = np.zeros(i1 - i0)
    for m in ch:
        for det in (-0.08, 0.08):
            f = note(m + 12) * 2 ** (det / 12)
            seg += ((tt * f) % 1 * 2 - 1) * 0.05
    e = np.minimum(1, tt / 0.6) * np.minimum(1, (bar + 0.3 - tt) / 0.3).clip(0, 1)
    pad[i0:i1] += seg * e
pad = lowpass(pad, 1400)
music[:, 0] += pad * 0.9
music[:, 1] += np.roll(pad, 300) * 0.9  # чуть шире стерео

# Арпеджио-щипок восьмыми — с момента, когда появляется приложение (3.2 с)
step = BEAT / 2
k = 0
t = 3.2
while t < 28.6:
    b = int(t / bar)
    ch = chords[b % 4]
    m = ch[[0, 1, 2, 1, 0, 2, 1, 2][k % 8]] + 24
    n = int(0.35 * SR)
    tt = np.arange(n) / SR
    f = note(m)
    s = (np.sin(2 * np.pi * f * tt) + 0.35 * np.sin(4 * np.pi * f * tt) + 0.1 * np.sin(6 * np.pi * f * tt)) * env(n, 0.002, 0.12)
    place(music, t, s, pan=0.35 if k % 2 else -0.35, gain=0.16)
    t += step; k += 1

# Бас и ударные — после крючка
for i in range(int(3.2 / BEAT), int(28.8 / BEAT)):
    tb = i * BEAT
    b = int(tb / bar)
    # бас: корень на каждую долю, синус с лёгким перегрузом
    n = int(BEAT * SR * 0.9); tt = np.arange(n) / SR
    s = np.tanh(2.2 * np.sin(2 * np.pi * note(bass_roots[b % 4]) * tt)) * env(n, 0.005, 0.35)
    place(music, tb, s, gain=0.22)
    # бочка: синус с падением частоты
    n = int(0.35 * SR); tt = np.arange(n) / SR
    f = 50 + 90 * np.exp(-tt * 30)
    kick = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 9)
    place(music, tb, kick, gain=0.55)
    # хэт на слабую долю
    n = int(0.06 * SR)
    hat = highpass(rng.standard_normal(n), 7000) * env(n, 0.001, 0.02)
    place(music, tb + BEAT / 2, hat, pan=0.2, gain=0.10)
    # хлопок на 2 и 4 — со сцены «вопрос к вам»
    if tb >= 6.4 and i % 2 == 1:
        n = int(0.18 * SR)
        clap = lowpass(highpass(rng.standard_normal(n), 900), 5000) * env(n, 0.002, 0.06)
        place(music, tb, clap, gain=0.20)

# Финал: громкость музыки плавно уходит к концу
fade = np.ones(N)
f0 = int(30.5 * SR)
fade[f0:] = np.linspace(1, 0, N - f0) ** 1.5
music *= fade[:, None]


# ——— Эффекты ———
def whoosh(dur=0.5, rising=True):
    n = int(dur * SR); tt = np.arange(n) / SR
    noise = rng.standard_normal(n)
    out = np.zeros(n)
    # полосовой шум, центр полосы скользит
    lo = 300; hi = 4500
    cut = np.linspace(lo, hi, n) if rising else np.linspace(hi, lo, n)
    a = np.exp(-2 * np.pi * cut / SR)
    s1 = s2 = 0.0
    for i in range(n):
        s1 = (1 - a[i]) * noise[i] + a[i] * s1
        s2 = (1 - a[i]) * s1 + a[i] * s2
        out[i] = s1 - s2
    e = np.sin(np.pi * np.clip(tt / dur, 0, 1)) ** 2
    return out * e * 3


def pop(f=900):
    n = int(0.09 * SR); tt = np.arange(n) / SR
    fr = f * (1 + 0.5 * tt / 0.09)
    return np.sin(2 * np.pi * np.cumsum(fr) / SR) * env(n, 0.001, 0.025)


def ding():
    n = int(1.2 * SR); tt = np.arange(n) / SR
    s = 0
    for f, g in ((1318.5, 1), (1760, 0.6), (2637, 0.25)):
        s = s + g * np.sin(2 * np.pi * f * tt)
    s2 = np.zeros(n); d = int(0.12 * SR)
    for f, g in ((1760, 1), (2349, 0.5)):
        s2[d:] += g * np.sin(2 * np.pi * f * tt[: n - d])
    return (s * np.exp(-tt * 5) + s2 * np.exp(-np.maximum(0, tt - 0.12) * 4)) * 0.35


def chime(m):
    n = int(0.9 * SR); tt = np.arange(n) / SR
    f = note(m)
    return (np.sin(2 * np.pi * f * tt) + 0.3 * np.sin(2 * np.pi * 2 * f * tt)) * env(n, 0.003, 0.35) * 0.5


def impact():
    n = int(1.6 * SR); tt = np.arange(n) / SR
    f = 40 + 70 * np.exp(-tt * 8)
    boom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-tt * 2.5)
    crash = lowpass(rng.standard_normal(n), 6000) * np.exp(-tt * 3) * 0.25
    return boom + crash


def riser(dur=1.4):
    w = whoosh(dur, True)
    tt = np.arange(len(w)) / SR
    return w * (tt / dur) ** 2 * 1.4


# Переходы между сценами
for t in (2.90, 6.10, 11.27, 15.70, 19.70, 24.50):
    place(sfx, t - 0.05, whoosh(0.45), gain=0.22)
place(sfx, 27.3, riser(1.45), gain=0.30)
place(sfx, 28.75, impact(), gain=0.65)

# Крючок: тревожный «тик» на вопрос
place(sfx, 0.90, pop(520), gain=0.35)
place(sfx, 1.25, pop(470), gain=0.30)
# Появление приложения и плашки «начался звонок»
place(sfx, 3.35, chime(76), gain=0.5)
place(sfx, 4.20, pop(820), gain=0.4)
# Уведомление «вопрос к вам» и карточка
place(sfx, 6.73, ding(), gain=0.8)
place(sfx, 7.60, pop(980), gain=0.35)
# Реплики расшифровки, компактное окно, итог, чат
for t in (12.20, 13.10, 14.00):
    place(sfx, t, pop(880), pan=-0.2, gain=0.32)
place(sfx, 16.20, whoosh(0.3, False), gain=0.14)
place(sfx, 16.90, pop(760), gain=0.38)
for t in (20.30, 21.97, 22.6, 23.2):
    place(sfx, t, pop(1040), pan=0.2, gain=0.26)
for i, t in enumerate((25.30, 25.80, 26.50, 27.00)):
    place(sfx, t, pop(820 + 60 * i), pan=-0.15 if i % 2 else 0.15, gain=0.30)
# Финал: три строки «Всё локально / Бесплатно / Открытый код»
for t, m in ((29.6, 81), (30.3, 84), (31.0, 88)):
    place(sfx, t, chime(m), gain=0.45)

mix = music * 0.8 + sfx
mix = np.tanh(mix * 1.1)  # мягкий ограничитель
mix /= np.abs(mix).max() / 0.89
out = (mix * 32767).astype(np.int16)
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(out.tobytes())
print("ok", sys.argv[1])
