"""Synthesizes the bundled alert sounds: Sounds/<theme>/<waiting|done|error>.wav for the
voice, pixel and marimba themes (the system theme uses macOS's own sounds). Needs numpy,
for this script only -- the app plays the committed files. Usage:
  python3 scripts/dev/make-sounds.py Sounds
"""
import os
import sys
import wave

import numpy as np

SR = 44100
OUT = sys.argv[1]
# Max A-weighted loudness of every sound: 3 dB under the mean of Ping, Glass and Basso.
TARGET_DB = -28.28604259021512
rng = np.random.default_rng(7)

SEMI = {'C': -9, 'C#': -8, 'D': -7, 'D#': -6, 'E': -5, 'F': -4, 'F#': -3,
        'G': -2, 'G#': -1, 'A': 0, 'A#': 1, 'B': 2}


def hz(n):
    return 440 * 2 ** ((SEMI[n[:-1]] + 12 * (int(n[-1]) - 4)) / 12)


def cents(c):
    return 2 ** (np.asarray(c) / 1200)


def taxis(dur):
    return np.arange(int(round(dur * SR))) / SR


def smooth(x):  # 0..1 -> 0..1 ease in-out
    x = np.clip(x, 0, 1)
    return x * x * (3 - 2 * x)


def env(t, attack=0.005, tau=None, sustain=0.0, release=0.03):
    d = t[-1] if len(t) else 0
    a = np.sin(np.clip(t / attack, 0, 1) * np.pi / 2) ** 2
    e = np.ones_like(t) if tau is None else sustain + (1 - sustain) * np.exp(-np.maximum(t - attack, 0) / tau)
    r = np.sin(np.clip((d - t) / release, 0, 1) * np.pi / 2) ** 2
    return a * e * r


def additive(f, amps, n_harm=48):
    """f: instantaneous fundamental per sample; amps(k, f) -> per-sample amplitude."""
    phase = 2 * np.pi * np.cumsum(f) / SR
    out = np.zeros_like(f)
    for k in range(1, n_harm + 1):
        fk = k * f
        guard = np.clip((15000 - fk) / 3000, 0, 1)
        if not guard.any():
            break
        out += amps(k, f) * guard * np.sin(k * phase)
    return out


def tilt(k, f, fc):
    return 1 / np.sqrt(1 + (k * f / fc) ** 4)


def drift(t, depth=0.004):
    """Slow random pitch wander so voices don't sound like a test tone."""
    pts = rng.normal(0, 1, 8)
    x = np.interp(t / max(t[-1], 1e-9) * 7, np.arange(8), pts)
    return cents(x * depth * 1200)


def vibrato(t, rate, depth, onset=0.0, ramp=0.06):
    g = smooth((t - onset) / ramp)
    return 1 + depth * g * np.sin(2 * np.pi * rate * t)


class Buf:
    def __init__(self, dur):
        self.x = np.zeros(int(dur * SR))

    def add(self, at, sig, gain=1.0):
        i = int(at * SR)
        n = min(len(sig), len(self.x) - i)
        self.x[i:i + n] += gain * sig[:n]
        return self


# ---------- effects ----------

def comb(x, delay, g):
    d = int(delay * SR)
    y = x.copy()
    for n in range(d, len(y)):
        y[n] += g * y[n - d]
    return y


def allpass(x, delay, g):
    d = int(delay * SR)
    y = np.zeros_like(x)
    for n in range(len(x)):
        xd = x[n - d] if n >= d else 0.0
        yd = y[n - d] if n >= d else 0.0
        y[n] = -g * x[n] + xd + g * yd
    return y


def onepole(x, fc):
    a = np.exp(-2 * np.pi * fc / SR)
    y = np.zeros_like(x)
    acc = 0.0
    for n in range(len(x)):
        acc = (1 - a) * x[n] + a * acc
        y[n] = acc
    return y


def reverb(x, mix=0.12, size=0.6):
    x = np.concatenate([x, np.zeros(int(0.5 * SR))])
    wet = sum(comb(x, d, size) for d in (0.0297, 0.0371, 0.0411, 0.0437)) / 4
    wet = allpass(allpass(wet, 0.005, 0.7), 0.0017, 0.7)
    wet = onepole(wet, 5000)
    return x + mix * wet


def echo(x, delay, fb, tone=4000):
    x = np.concatenate([x, np.zeros(int(0.4 * SR))])
    d = int(delay * SR)
    y = x.copy()
    for n in range(d, len(y)):
        y[n] += fb * y[n - d]
    return onepole(y, tone) * 0.3 + y * 0.7


# ---------- voices ----------

VOWELS = {'i': (270, 2290, 3010), 'u': (300, 870, 2240), 'a': (730, 1090, 2440),
          'e': (530, 1840, 2480), 'o': (570, 840, 2410)}


def formant_track(t, keys, scale=1.3):
    d = t[-1]
    times = [k[0] * d for k in keys]
    return [np.interp(t, times, [VOWELS[k[1]][i] * scale for k in keys]) for i in range(3)]


def syllable(dur, f, vowels, attack=0.008, release=0.04, tau=None, sustain=0.0):
    """Little creature voice: harmonic source shaped by moving formants."""
    t = taxis(dur)
    f = f(t) if callable(f) else np.full_like(t, f)
    f = f * drift(t)
    F = formant_track(t, vowels)
    B = (260, 360, 480)
    G = (1.0, 0.75, 0.35)

    def amps(k, f0):
        fk = k * f0
        res = 0.10 + sum(g / (1 + ((fk - Fi) / b) ** 2) for Fi, b, g in zip(F, B, G))
        return res / k ** 0.6 * tilt(k, f0, 4200)

    return additive(f, amps) * env(t, attack, tau, sustain, release)


def pulse_k(k, duty):
    return abs(2 / (k * np.pi) * np.sin(k * np.pi * duty))


def tri_k(k):
    return 8 / (np.pi ** 2 * k ** 2) if k % 2 else 0.0


def pix(dur, f, duty=0.25, tri=0.5, fc=2600, attack=0.003, tau=0.05, sustain=0.6, release=0.02):
    """Soft chiptune: pulse + triangle, rounded off at the top."""
    t = taxis(dur)
    f = f(t) if callable(f) else np.full_like(t, f)
    amps = lambda k, f0: ((1 - tri) * pulse_k(k, duty) + tri * 1.6 * tri_k(k)) * tilt(k, f0, fc)
    return additive(f, amps) * env(t, attack, tau, sustain, release)


MARIMBA = [(1.0, 1.0, 0.40), (3.93, 0.30, 0.09), (9.2, 0.08, 0.03)]
MUTED = [(1.0, 1.0, 0.20), (3.93, 0.15, 0.05), (9.2, 0.03, 0.02)]
GLOCK = [(1.0, 1.0, 0.70), (2.76, 0.40, 0.25), (5.4, 0.20, 0.12), (8.93, 0.10, 0.06)]


def mallet(f, partials=MARIMBA, dur=None, click=0.12, bend=None):
    dur = dur or max(p[2] for p in partials) * 5
    t = taxis(dur)
    base = np.full_like(t, f)
    if bend:
        c, start, length = bend
        base = base * cents(c * smooth((t - start) / length))
    phase = 2 * np.pi * np.cumsum(base) / SR
    out = sum(a * np.exp(-t / tau) * np.sin(r * phase) for r, a, tau in partials if f * r < 15000)
    out = out * np.clip(t / 0.0015, 0, 1) * env(t, 0.0001, None, 0, 0.02)
    if click:
        n = int(0.02 * SR)
        nz = onepole(rng.normal(0, 1, n), 3000) * np.exp(-np.arange(n) / SR / 0.004)
        out[:n] += click * nz
    return out


# ---------- voice: Critter's own little voice ----------

def voice_waiting():
    b = Buf(0.6)
    b.add(0.0, syllable(0.085, lambda t: hz('F#5') * cents(-150 * (1 - smooth(t / 0.025))),
                        [(0, 'u'), (0.3, 'i'), (1, 'i')]), 0.8)
    b.add(0.125, syllable(0.24, lambda t: (760 + (hz('D6') - 760) * (t / 0.24) ** 2) * vibrato(t, 7, 0.012, 0.15),
                          [(0, 'u'), (0.35, 'i'), (1, 'i')], release=0.05))
    return reverb(b.x, 0.12)


def voice_done():
    b = Buf(0.9)
    b.add(0.0, syllable(0.075, hz('E5'), [(0, 'i'), (0.4, 'a'), (1, 'a')]), 0.75)
    b.add(0.105, syllable(0.075, hz('A5'), [(0, 'i'), (0.4, 'a'), (1, 'a')]), 0.85)

    def yay(t):
        up = cents(-100 * (1 - smooth(t / 0.04)))
        fall = cents(-80 * smooth((t - 0.24) / 0.06))
        return hz('C#6') * up * fall * vibrato(t, 6.5, 0.015, 0.1)
    b.add(0.21, syllable(0.30, yay, [(0, 'i'), (0.2, 'a'), (0.7, 'a'), (1, 'e')], release=0.07))
    for at, n, g in ((0.30, 'E7', 0.10), (0.38, 'A7', 0.08), (0.47, 'C#8', 0.06)):
        b.add(at, mallet(hz(n), GLOCK, 0.4, click=0), g)
    return reverb(b.x, 0.14)


def voice_error():
    b = Buf(0.75)
    b.add(0.0, syllable(0.11, lambda t: hz('E5') * cents(-80 * (1 - smooth(t / 0.03))), [(0, 'a'), (1, 'a')]), 0.85)

    def droop(t):
        return hz('C#5') * cents(-400 * smooth((t - 0.12) / 0.22)) * vibrato(t, 5, 0.025, 0.12, 0.1)
    s = syllable(0.38, droop, [(0, 'o'), (0.5, 'o'), (1, 'u')], release=0.14, tau=0.3, sustain=0.4)
    b.add(0.15, s)
    return reverb(b.x, 0.12)


# ---------- pixel: soft chiptune, one note per 60 ms tick ----------

def pixel_waiting():
    b = Buf(0.6)
    b.add(0.0, pix(0.06, hz('B5')), 0.8)
    b.add(0.06, pix(0.15, lambda t: hz('E6') * cents(40 * smooth((t - 0.09) / 0.06))))
    return reverb(echo(b.x, 0.135, 0.22), 0.06)


def pixel_done():
    b = Buf(0.9)
    for i, n in enumerate(('C6', 'E6', 'G6')):
        b.add(0.06 * i, pix(0.06, hz(n)), 0.7 + 0.08 * i)
    b.add(0.18, pix(0.30, lambda t: hz('C7') * vibrato(t, 6, 0.01, 0.08), tau=0.12, sustain=0.5, release=0.08))
    b.add(0.18, pix(0.30, hz('C6'), duty=0.5, tri=1.0, fc=1500, tau=0.12, sustain=0.4, release=0.08), 0.35)
    for at, n, g in ((0.32, 'G7', 0.16), (0.38, 'E7', 0.12), (0.44, 'C8', 0.09)):
        b.add(at, pix(0.035, hz(n), tri=1.0, tau=0.02, sustain=0.2, release=0.015), g)
    return reverb(echo(b.x, 0.135, 0.2), 0.06)


def pixel_error():
    b = Buf(0.8)
    b.add(0.0, pix(0.09, hz('C5'), tri=0.7, fc=1800), 0.9)

    def slide(t):
        return hz('A4') * cents(-700 * smooth((t - 0.04) / 0.30)) * (1 + 0.03 * smooth(t / 0.3) * np.sin(2 * np.pi * 9 * t))
    b.add(0.12, pix(0.36, slide, tri=0.8, fc=1500, tau=0.25, sustain=0.3, release=0.08))
    return reverb(echo(b.x, 0.135, 0.15), 0.06)


# ---------- marimba: a few soft mallet taps ----------

def marimba_waiting():
    b = Buf(0.9)
    b.add(0.0, mallet(hz('A5')), 0.85)
    b.add(0.11, mallet(hz('E6')), 1.0)
    b.add(0.25, mallet(hz('E6'), click=0.05), 0.28)
    return reverb(b.x, 0.15)


def marimba_done():
    b = Buf(1.2)
    for i, n in enumerate(('C6', 'E6', 'G6', 'C7')):
        b.add(0.055 * i, mallet(hz(n)), 0.7 + 0.1 * i)
    for at, n, g in ((0.27, 'G7', 0.22), (0.33, 'C8', 0.16), (0.40, 'E8', 0.10)):
        b.add(at, mallet(hz(n), GLOCK, 0.6, click=0), g)
    return reverb(b.x, 0.16)


def marimba_error():
    b = Buf(0.9)
    b.add(0.0, mallet(hz('E5'), MUTED, 0.5), 1.0)
    b.add(0.14, mallet(hz('C#5'), MUTED, 0.6, bend=(-50, 0.03, 0.2)), 1.0)
    t = taxis(0.12)
    thud = np.sin(2 * np.pi * np.cumsum(120 * cents(-600 * t / 0.12)) / SR) * env(t, 0.002, 0.03, 0, 0.03)
    b.add(0.14, thud, 0.25)
    return reverb(b.x, 0.12)


# ---------- loudness + io ----------

def a_weight(f):
    f2 = f ** 2
    ra = (12194 ** 2 * f2 ** 2) / ((f2 + 20.6 ** 2) * np.sqrt((f2 + 107.7 ** 2) * (f2 + 737.9 ** 2)) * (f2 + 12194 ** 2))
    return ra * 10 ** (2 / 20)


def loudness(x):
    """Max A-weighted RMS over 100 ms windows, in dB."""
    spec = np.fft.rfft(x)
    xw = np.fft.irfft(spec * a_weight(np.fft.rfftfreq(len(x), 1 / SR)), len(x))
    w = int(0.1 * SR)
    p = np.convolve(xw ** 2, np.ones(w) / w, 'valid') if len(xw) > w else [np.mean(xw ** 2)]
    return 10 * np.log10(max(np.max(p), 1e-12))


def trim(x, floor_db=-50):
    idx = np.nonzero(np.abs(x) > 10 ** (floor_db / 20) * np.max(np.abs(x)))[0]
    x = x[:idx[-1] + int(0.01 * SR)] if len(idx) else x
    n = min(len(x), int(0.01 * SR))
    x[-n:] *= np.linspace(1, 0, n)
    return x


def write(path, x):
    pcm = np.int16(np.clip(x, -1, 1) * 32767)
    with wave.open(path, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


THEMES = {
    'voice': (voice_waiting, voice_done, voice_error),
    'pixel': (pixel_waiting, pixel_done, pixel_error),
    'marimba': (marimba_waiting, marimba_done, marimba_error),
}


def main():
    # Rendered in this order, which is the order they draw from `rng`.
    for theme, fns in THEMES.items():
        os.makedirs(os.path.join(OUT, theme), exist_ok=True)
        for state, fn in zip(('waiting', 'done', 'error'), fns):
            x = trim(fn())
            x *= 10 ** ((TARGET_DB - loudness(x)) / 20)
            peak = float(np.max(np.abs(x)))
            if peak > 0.89:
                x *= 0.89 / peak
            path = os.path.join(OUT, theme, f'{state}.wav')
            write(path, x)
            print(f'{path}  {len(x) / SR:.2f}s  peak {peak:.2f}')


main()
