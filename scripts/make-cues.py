# -*- coding: utf-8 -*-
"""Generates the two small cue sounds.

They exist to give an answer immediately. Even a short sentence has to be
synthesised and may sit behind something else in the queue, while a finished WAV
file plays instantly. Run once; the files then live in cues/.
"""
import os
import math
import wave
import struct

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
CUES = os.path.join(os.path.dirname(SCRIPTS), "cues")
RATE = 22050


def tone(frames, freq, dur, amp=0.55):
    """A sine tone with a soft fade in and out, so it does not click."""
    n = int(RATE * dur)
    fade = max(1, int(n * 0.25))
    for i in range(n):
        env = 1.0
        if i < fade:
            env = i / float(fade)
        elif i > n - fade:
            env = (n - i) / float(fade)
        frames.append(int(32767 * amp * env * math.sin(2 * math.pi * freq * i / RATE)))


def silence(frames, dur):
    frames.extend([0] * int(RATE * dur))


def write(name, frames):
    path = os.path.join(CUES, name + ".wav")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", f) for f in frames))
    print("wrote %s (%.2f s)" % (path, len(frames) / float(RATE)))


os.makedirs(CUES, exist_ok=True)

# There are only TWO tones. The approval sequence used to have a rising
# three-note figure at the question and a short acknowledgement at the answer,
# but both said the same thing as the speech a moment later, and both lay on top
# of it. The waiting tone now carries the whole sequence: it begins once the
# question has been read and stops when speech resumes. Silence means "you are
# up".

# Submitted: two FALLING tones. Means "your prompt has been sent".
#
# The shape carries the meaning, not the pitch: this one falls, and the waiting
# tone is a single note. That makes them distinguishable without thinking about
# it.
#
# The first attempt was a single tone at 392 Hz for 90 ms, chosen because it was
# the only low one. It played correctly, the log showed as much, but it could
# not be heard: laptop speakers reproduce poorly below about 500 Hz, and 90 ms
# is too short for the ear to register a low tone. Both tones now sit in the
# range small speakers can actually manage.
f = []
tone(f, 784.0, 0.11, amp=0.60)
silence(f, 0.02)
tone(f, 587.3, 0.16, amp=0.60)
write("submitted", f)

# Waiting: one gentle tone, repeated for as long as something is pending.
#
# It is the only tone heard more than once, and therefore the only one where
# discretion matters more than clarity. It has to be ignorable while you think,
# but missed immediately when it stops. The stopping, not the tone, is the
# message.
#
# Kept above 500 Hz and above 100 ms for the same reason as the other.
#
# It started at 0.30 amplitude and 110 ms, the weakest and shortest sound in the
# system. The log showed 26 tones played over 83 seconds, and the user heard
# none of them. Discreet is good, inaudible is not. It now sits at the same
# level as the other one; it still sounds softer, because it is a single note
# rather than a figure.
f = []
tone(f, 880.0, 0.20, amp=0.50)
write("waiting", f)
