#!/usr/bin/env python3
"""Synthesizes Mukker's three dictation cues and writes them for both platforms.

    python3 scripts/make-sounds.py

- dictation-start.wav: a gentle rising two-note chime (E5 -> B5), recording has begun.
- dictation-stop.wav:  the mirror, falling (B5 -> E5), recording ended and transcription begins.
- dictation-paste.wav: one very soft, short, higher bell, the text has been pasted.

Each note is a sine plus a little soft 2nd harmonic with a ~5 ms attack and an exponential decay,
and the whole clip gets a short fade-out so it ends at exactly zero (no clicks). 16-bit mono
44.1 kHz. Written to App/Resources/Sounds/ (macOS bundle) and
windows/src/Mukker.App/Assets/Sounds/ (Windows app). Standard library only.
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44100
ROOT = Path(__file__).resolve().parent.parent
OUT_DIRS = [ROOT / "App/Resources/Sounds", ROOT / "windows/src/Mukker.App/Assets/Sounds"]

E5, B5, E6 = 659.25, 987.77, 1318.51


def note(freq, length, decay_ms, attack_ms=5.0, harmonic=0.18):
    """One bell-ish note: sine + soft 2nd harmonic, linear attack, exponential decay."""
    n = int(RATE * length)
    attack = int(RATE * attack_ms / 1000)
    tau = decay_ms / 1000
    out = []
    for i in range(n):
        t = i / RATE
        env = math.exp(-t / tau)
        if i < attack:
            env *= i / attack
        tone = math.sin(2 * math.pi * freq * t) + harmonic * math.sin(4 * math.pi * freq * t)
        out.append(env * tone / (1 + harmonic))
    return out


def mix(parts, total):
    """Sums (start_seconds, samples) parts into a buffer of `total` seconds."""
    buf = [0.0] * int(RATE * total)
    for start, samples in parts:
        offset = int(RATE * start)
        for i, s in enumerate(samples):
            if offset + i < len(buf):
                buf[offset + i] += s
    return buf


def finish(buf, peak_db, fade_ms=15):
    """Fade out the tail to zero and normalise to the requested peak."""
    fade = int(RATE * fade_ms / 1000)
    for i in range(fade):
        buf[-1 - i] *= i / fade
    top = max(abs(s) for s in buf) or 1
    gain = 10 ** (peak_db / 20) / top
    return [s * gain for s in buf]


def write(name, buf):
    data = b"".join(struct.pack("<h", int(round(max(-1, min(1, s)) * 32767))) for s in buf)
    for directory in OUT_DIRS:
        directory.mkdir(parents=True, exist_ok=True)
        with wave.open(str(directory / name), "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(RATE)
            w.writeframes(data)
    print(f"{name}: {len(buf) / RATE * 1000:.0f} ms, {len(data) + 44} bytes")


def two_notes(first, second):
    return mix([(0.0, note(first, 0.14, 55)), (0.075, note(second, 0.15, 70))], 0.23)


write("dictation-start.wav", finish(two_notes(E5, B5), -6))
write("dictation-stop.wav", finish(two_notes(B5, E5), -6))
write("dictation-paste.wav", finish(mix([(0.0, note(E6, 0.12, 30, harmonic=0.1))], 0.12), -12))
