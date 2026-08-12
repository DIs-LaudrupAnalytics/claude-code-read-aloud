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


def wake_tone(frames, freq, lead, dur, amp=0.50, lead_amp=0.01):
    """One continuous tone that wakes a sleeping Bluetooth link, then sounds.

    The lead-in is the same note at an amplitude you cannot hear. It exists only
    to keep signal on the link; see the note further down for the failure it
    fixes.

    Built as ONE tone with a rising envelope rather than two tones back to back,
    and that is the whole trick. Two segments each faded to zero at their edges,
    so the carrier died away in the moment before the beep began and the codec
    was handed a step to reproduce. It worked, in that the beep was audible at
    last, but the listener described it as not at all smooth, which for a sound
    heard every three seconds while you think is most of the point. Here the
    amplitude only ever rises, and the phase runs unbroken from the first sample
    to the last, so there is nothing to click on."""
    n_lead = int(RATE * lead)
    n_body = int(RATE * dur)
    ramp = max(1, int(RATE * 0.04))     # into the audible part
    fade = max(1, int(RATE * 0.06))     # out at the end
    start = max(1, int(RATE * 0.02))    # into the carrier, so it does not click
    total = n_lead + n_body
    for i in range(total):
        if i < n_lead:
            env = lead_amp * (min(i, start) / float(start))
        else:
            j = i - n_lead
            if j < ramp:
                # From the carrier up to full level, never back down.
                env = lead_amp + (amp - lead_amp) * (j / float(ramp))
            elif j > n_body - fade:
                env = amp * ((n_body - j) / float(fade))
            else:
                env = amp
        frames.append(int(32767 * env * math.sin(2 * math.pi * freq * i / RATE)))


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
#
# Raising the level did not fix it, and the reason was not the sound at all.
# Found on 12 August 2026 by playing the file from a console, where it was heard,
# and from the hidden loop, where it was not: the listener is on Bluetooth. The
# A2DP link powers down after a few seconds of silence and takes up to a second
# to come back, so a 200 ms beep is over before the headset is receiving. Speech
# survives this because it is long enough to lose only its opening; a short tone
# is lost whole. The log looked perfectly healthy throughout, since the file
# really was played, into a device that was not listening yet.
#
# The lead-in is the fix: about a second of the same tone at an amplitude you
# cannot hear, which is signal enough to hold the link open, followed by the beep
# itself at full level. It costs nothing audible and nothing in latency, because
# the tone is not what you are waiting for. Do not remove it because the file
# looks strangely long for a single note, and do not "simplify" it to a plain
# beep: that is the version that was inaudible for weeks.
f = []
wake_tone(f, 880.0, 0.90, 0.20)
write("waiting", f)
