# -*- coding: utf-8 -*-
"""Resident Piper daemon.

Loads the voice model once and then drains the queue directory in order. That
solves three problems:

  * loading the model costs about 2 seconds, and that price is paid only at
    startup
  * utterances queue instead of interrupting each other, so narration is not cut
    off by whatever comes next
  * short, repeated sentences (typically "Claude needs your permission ...") are
    stored as finished WAV files and played back with no delay at all

Playback is asynchronous and is interrupted by a stop flag file. That is the
whole point: the daemon must **not** be killed to make it fall silent, because
the model would leave memory and the next utterance would start several seconds
late.

Never started directly. The hooks launch it through tts-common.ps1.
"""
import os
import re
import sys
import json
import time
import wave
import queue
import msvcrt
import hashlib
import threading
import winsound

SCRIPTS = os.path.dirname(os.path.abspath(__file__))


def resolve_data_root():
    """Find the data root: everything mutable lives there, not in the program.

    Installed as a plugin, the program directory is version-bound and its path
    changes on every update, so config, voice models and cache would be lost
    each time. The order matches the one in tts-common.ps1.

    The argument comes first, because the daemon is started by Start-PiperDaemon
    and does not necessarily inherit the hook's environment variables.
    """
    if len(sys.argv) > 1 and sys.argv[1].strip():
        return sys.argv[1].strip()
    for var in ("CLAUDE_TTS_DATA", "CLAUDE_PLUGIN_DATA"):
        val = os.environ.get(var)
        if val:
            return val
    return os.path.join(os.path.expanduser("~"), ".claude", "read-aloud", "data")


DATA     = resolve_data_root()
QUEUE    = os.path.join(DATA, "queue")
CACHE    = os.path.join(DATA, "cache")
PIDFILE  = os.path.join(DATA, "piper.pid")
LOCKFILE = os.path.join(DATA, "piper.lock")
STOPFLAG = os.path.join(DATA, "stop.flag")
# Exists only while speech is actually happening. The waiting tone reads it to
# keep quiet in the meantime: a gentle tone on top of speech sounds like a fault,
# not like a signal.
SPEAKFLAG = os.path.join(DATA, "speaking.flag")
CFGPATH  = os.path.join(DATA, "tts-config.json")
LOGPATH  = os.path.join(DATA, "tts.log")
VOICEDIR = os.path.join(DATA, "voices")

CACHE_MAX_CHARS = 300      # only short, repeated messages are worth storing
LOG_MAX_BYTES   = 2 * 1024 * 1024
_seq = 0
_log_writes = 0


def rotate_log():
    """Keep one generation of the log and no more.

    Nothing used to trim it. Every hook, both loops and this daemon append to
    the same file, and after half a day of real use it was the largest thing in
    the data root. os.replace can fail if another process happens to hold the
    file open, which is fine: the next writer tries again."""
    try:
        if os.path.getsize(LOGPATH) > LOG_MAX_BYTES:
            os.replace(LOGPATH, LOGPATH + ".1")
    except OSError:
        pass


def log(msg):
    global _log_writes
    # Checked now and then rather than on every line. The daemon is long lived
    # and writes a line per queue item, so a stat per write would be waste, but
    # it must not be able to run for hours without ever looking.
    if _log_writes % 100 == 0:
        rotate_log()
    _log_writes += 1
    try:
        with open(LOGPATH, "a", encoding="utf-8") as f:
            f.write("%s piper %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S"), msg))
    except OSError:
        pass


def load_config():
    try:
        with open(CFGPATH, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        log("config unreadable: %s" % e)
        return {}


_lock_handle = None


def claim_singleton():
    """Ensure only one daemon runs. False if another already holds the lock.

    The pid file was not lock enough. It is only written AFTER Python has
    started, and the hooks fire in clusters: two of them could both see a
    missing pid file and each start a daemon. Since PATH also offered two
    different pythonw.exe, we ended up with four. They read the queue directory
    independently, grabbed the same message and spoke it on top of each other.
    That was the "several voices" talking over one another on approvals.

    An OS lock does not have that hole: it is held by the process itself, and
    Windows releases it when the process dies. A stale lock therefore cannot
    occur, and the startup race is closed no matter how many launchers fire.
    """
    global _lock_handle
    try:
        _lock_handle = open(LOCKFILE, "a+")
        _lock_handle.seek(0)
        msvcrt.locking(_lock_handle.fileno(), msvcrt.LK_NBLCK, 1)
        return True
    except OSError:
        return False


def stop_requested():
    return os.path.exists(STOPFLAG)


def clear_stop():
    try:
        os.remove(STOPFLAG)
    except OSError:
        pass


def drain_queue(cutoff=None):
    """Throw away the backlog the stop was aimed at, and nothing newer.

    The cutoff is the moment silence was asked for. Without it this deleted
    whatever happened to be in the directory when the daemon got round to
    looking, and the hooks queue again immediately: UserPromptSubmit asks for
    silence and then starts the working message about a second later. That
    message was being swallowed by the stop that came before it."""
    try:
        for f in os.listdir(QUEUE):
            if not f.endswith(".txt"):
                continue
            p = os.path.join(QUEUE, f)
            try:
                if cutoff is not None and os.path.getmtime(p) > cutoff:
                    continue
                os.remove(p)
            except OSError:
                pass
    except OSError:
        pass


def prune_cache(cfg):
    """Hold the cache to a ceiling, oldest use out first.

    Only short messages are cached, on the theory that they repeat word for
    word. Tool announcements broke that: they carry the command's own
    description, so every one of them is unique, cached once and never played
    again. Twelve hours of real use left 337 files and 40 MB that nothing would
    ever read.

    Recency is the file's mtime, which a cache hit touches. Windows atime is
    not reliable enough to lean on."""
    try:
        limit_files = int(cfg.get("cacheMaxFiles", 300))
        limit_bytes = float(cfg.get("cacheMaxMb", 30)) * 1024 * 1024
    except (TypeError, ValueError):
        limit_files, limit_bytes = 300, 30 * 1024 * 1024
    # Zero or less means no ceiling on that dimension, not a ceiling of zero.
    if limit_files <= 0:
        limit_files = float("inf")
    if limit_bytes <= 0:
        limit_bytes = float("inf")
    if limit_files == float("inf") and limit_bytes == float("inf"):
        return
    entries = []
    total = 0
    try:
        for name in os.listdir(CACHE):
            if not name.endswith(".wav"):
                continue
            p = os.path.join(CACHE, name)
            try:
                st = os.stat(p)
            except OSError:
                continue
            entries.append((st.st_mtime, st.st_size, p))
            total += st.st_size
    except OSError:
        return
    entries.sort()                      # oldest use first
    removed = 0
    for mtime, size, p in entries:
        if len(entries) - removed <= limit_files and total <= limit_bytes:
            break
        try:
            os.remove(p)
            total -= size
            removed += 1
        except OSError:
            pass
    if removed:
        log("cache: removed %d of %d files, %.1f MB left" % (removed, len(entries), total / 1048576.0))


# Em dash, en dash, and a hyphen surrounded by spaces. All three are used as a
# pause mid-sentence, exactly like a full stop between two.
DASH_SPLIT = re.compile(u"\\s*[\u2014\u2013]\\s*|\\s+-\\s+")


def split_segments(text, min_chars=45, min_dash=25):
    """Split into chunks, and say which kind of pause belongs in front of each.

    One sentence per chunk leaves room for an artificial pause between them, and
    Piper synthesises sentence by sentence anyway. Each sentence is then split
    at dashes, which in practice read as a pause.

    Very short fragments ("Yes." "In short:") are appended to the previous one,
    so the reading does not turn choppy, both for sentences and for dashes.

    Returns a list of (text, kind), where kind is 'sentence' or 'dash' and
    describes the pause IN FRONT of the chunk. The very first pause is skipped.
    """
    parts = [p for p in re.split(r"(?<=[.!?:])\s+", text) if p]
    sentences = []
    for p in parts:
        if sentences and len(p) < min_chars:
            sentences[-1] = sentences[-1] + " " + p
        else:
            sentences.append(p)

    segs = []
    for s in sentences:
        pieces = [x.strip() for x in DASH_SPLIT.split(s) if x.strip()]
        merged = []
        for piece in pieces:
            if merged and len(piece) < min_dash:
                # Too short to earn its own pause. Join it on with a comma,
                # otherwise the pause disappears entirely and the words run
                # together: "Short - ok" would be read as "Short ok".
                tail = merged[-1]
                sep = " " if tail.endswith((",", ";", ":")) else ", "
                merged[-1] = tail + sep + piece
            else:
                merged.append(piece)
        for j, piece in enumerate(merged):
            segs.append((piece, "sentence" if j == 0 else "dash"))
    return segs


def make_syn_config(cfg):
    """Translate rate and volume into Piper's SynthesisConfig, if it exists."""
    try:
        from piper import SynthesisConfig
    except ImportError:
        return None
    kwargs = {}
    try:
        rate = min(max(float(cfg.get("rate", 1.0)), 0.5), 6.0)
        # length_scale is duration: above 1 is slower, so it is the inverse.
        kwargs["length_scale"] = 1.0 / rate
    except (TypeError, ValueError):
        pass
    try:
        kwargs["volume"] = min(max(float(cfg.get("volume", 100)) / 100.0, 0.0), 1.0)
    except (TypeError, ValueError):
        pass
    try:
        return SynthesisConfig(**kwargs)
    except TypeError:
        try:
            return SynthesisConfig()
        except Exception:
            return None


def wav_duration(path):
    try:
        with wave.open(path, "rb") as w:
            return w.getnframes() / float(w.getframerate())
    except (OSError, wave.Error):
        return 0.0


def play_interruptible(path):
    """Play asynchronously and watch the stop flag along the way.

    Returns False if silence was requested mid-playback.
    """
    dur = wav_duration(path)
    try:
        winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)
    except Exception as e:
        log("playback failed: %s" % e)
        return True
    # The tail needs room. Playback is asynchronous, and Windows itself takes a
    # moment to get going, so the real end time falls after the duration. With
    # too little margin the next PlaySound cuts off the last word, and that is
    # exactly what the user heard as the question being clipped.
    deadline = time.time() + dur + 0.30
    while time.time() < deadline:
        if stop_requested():
            try:
                winsound.PlaySound(None, winsound.SND_PURGE)
            except Exception:
                pass
            return False
        time.sleep(0.05)
    return True


def cache_key(text, cfg):
    raw = "%s|%s|%s|%s" % (text, cfg.get("piperModel", ""), cfg.get("rate", 1.0), cfg.get("volume", 100))
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()


def synth_to(path, voice, text, syn):
    with wave.open(path, "wb") as w:
        if syn is not None:
            voice.synthesize_wav(text, w, syn_config=syn)
        else:
            voice.synthesize_wav(text, w)


def speak(voice, text, syn, cfg, pause=0.35, dash_pause=None):
    """Synthesise on a thread, play on this one. Sound arrives early, no gaps.

    An utterance is never interrupted by anything except silence. There used to
    be a mechanism here that let a permission question break in between two
    sentences and read the rest afterwards. It worked, but it cut a sentence in
    half mid-thought, and it sounded like a fault. The question now waits its
    turn; the ordering is guaranteed instead by holding the description back.
    """
    global _seq
    if dash_pause is None:
        dash_pause = pause

    # Short messages are often repeated word for word. If one is stored, play it
    # straight away.
    if len(text) <= CACHE_MAX_CHARS:
        key = cache_key(text, cfg)
        cached = os.path.join(CACHE, key + ".wav")
        if os.path.exists(cached):
            # Touch it: the mtime is what prune_cache reads as "last used", so
            # a message that keeps coming back is the last to be thrown out.
            try:
                os.utime(cached, None)
            except OSError:
                pass
            play_interruptible(cached)
            return
        try:
            os.makedirs(CACHE, exist_ok=True)
            # Write alongside and move into place. The cache name is a hash of
            # the text, so two daemons wrote to the same file at once and left
            # half a WAV behind, which then wrecked playback every single time
            # that message came round again. os.replace is atomic: the file
            # exists either whole or not at all.
            tmp = "%s.%d.tmp" % (cached, os.getpid())
            synth_to(tmp, voice, text, syn)
            os.replace(tmp, cached)
            play_interruptible(cached)
            return
        except Exception as e:
            log("cache synthesis failed: %s" % e)

    segments = split_segments(text)
    if not segments:
        return None

    q = queue.Queue(maxsize=3)
    abort = threading.Event()

    def produce():
        global _seq
        try:
            for chunk, kind in segments:
                if stop_requested() or abort.is_set():
                    break
                _seq += 1
                path = os.path.join(DATA, "say-%d-%d.wav" % (os.getpid(), _seq))
                synth_to(path, voice, chunk, syn)
                q.put((path, kind))
        except Exception as e:
            log("synthesis failed: %s" % e)
        finally:
            q.put(None)

    threading.Thread(target=produce, daemon=True).start()

    def discard(p):
        try:
            os.remove(p)
        except OSError:
            pass

    first = True
    while True:
        item = q.get()
        if item is None:
            break
        path, kind = item
        if stop_requested():
            discard(path)
            continue
        if not first:
            gap = dash_pause if kind == "dash" else pause
            if gap > 0:
                time.sleep(gap)
        first = False
        try:
            play_interruptible(path)
        finally:
            discard(path)


def sweep_orphans():
    """Clear files left behind by a killed daemon: WAV fragments, a claimed
    queue item and half-written cache files. The claimed queue item ('.mine')
    belongs on the list: if the daemon dies mid-utterance the file would
    otherwise sit there forever, invisible, because the queue directory is only
    scanned for '.txt'."""
    cutoff = time.time() - 300
    try:
        for name in os.listdir(DATA):
            if name.startswith("say-") and name.endswith(".wav"):
                p = os.path.join(DATA, name)
                try:
                    if os.path.getmtime(p) < cutoff:
                        os.remove(p)
                except OSError:
                    pass
    except OSError:
        pass
    for folder, suffix in ((QUEUE, ".mine"), (CACHE, ".tmp")):
        try:
            for name in os.listdir(folder):
                if name.endswith(suffix):
                    try:
                        os.remove(os.path.join(folder, name))
                    except OSError:
                        pass
        except OSError:
            pass


def main():
    os.makedirs(QUEUE, exist_ok=True)
    os.makedirs(CACHE, exist_ok=True)
    if not claim_singleton():
        # Another daemon is already tending the queue. Leave quietly: do not
        # touch the pid file, the stop flag or the queue on the way out.
        log("another daemon holds the lock - exiting without touching anything")
        return
    with open(PIDFILE, "w", encoding="ascii") as f:
        f.write(str(os.getpid()))
    sweep_orphans()
    rotate_log()
    prune_cache(load_config())
    next_prune = time.time() + 600
    clear_stop()
    # A marker left behind by a killed daemon would make the waiting tone
    # believe speech was happening, and then it would never sound at all.
    try:
        os.remove(SPEAKFLAG)
    except OSError:
        pass

    from piper import PiperVoice

    voice = None
    loaded_model = None
    idle_since = time.time()

    # Load the model right away instead of waiting for the first queue item. It
    # used to sit inside the loop, so the 2 to 3 seconds of loading hit the
    # first utterance after every startup, which is exactly where the delay is
    # most audible. Now the price is paid while Claude is still thinking and the
    # queue is empty. If loading fails we do nothing: the loop tries again with
    # the same code, and a missing model is logged there.
    try:
        _cfg0 = load_config()
        _model0 = _cfg0.get("piperModel", "en_US-lessac-medium")
        _onnx0 = os.path.join(VOICEDIR, _model0 + ".onnx")
        if _cfg0.get("enabled", False) and os.path.exists(_onnx0):
            t0 = time.time()
            voice = PiperVoice.load(_onnx0)
            loaded_model = _model0
            log("preloaded %s in %.1f s" % (_model0, time.time() - t0))
    except Exception as e:
        log("preload failed: %s" % e)

    try:
        while True:
            cfg = load_config()
            if not cfg.get("enabled", False):
                break

            if stop_requested():
                # The flag's own timestamp is the moment silence was asked for.
                # Anything queued after it belongs to what comes next, not to
                # the backlog being thrown away.
                try:
                    cutoff = os.path.getmtime(STOPFLAG)
                except OSError:
                    cutoff = time.time()
                drain_queue(cutoff)
                clear_stop()

            idle_timeout = float(cfg.get("idleTimeout", 1800))
            try:
                items = sorted(f for f in os.listdir(QUEUE) if f.endswith(".txt"))
            except OSError:
                items = []

            if not items:
                if time.time() - idle_since > idle_timeout:
                    break
                # Housekeeping belongs in the quiet moments. Doing it between
                # two utterances would put a directory listing in front of
                # speech that is already waiting to be heard.
                if time.time() >= next_prune:
                    prune_cache(cfg)
                    next_prune = time.time() + 600
                time.sleep(0.1)
                continue

            idle_since = time.time()

            # '2-' is a held tool announcement. The PreToolUse hook fires before
            # Claude Code decides whether to ask for permission, so without this
            # delay the description of the command would always come before the
            # question. We let it lie for a moment; when an approval lands it
            # sorts as '0-' in front and is read first.
            if items[0].startswith("2-"):
                hold = float(cfg.get("holdMs", 900)) / 1000.0
                try:
                    age = time.time() - os.path.getmtime(os.path.join(QUEUE, items[0]))
                except OSError:
                    age = hold
                if age < hold:
                    time.sleep(0.05)
                    continue

            # Discard stale speech. If the daemon has been down, or simply busy,
            # a pile can build up, and then the whole stack is read out in a
            # row afterwards. Speech about something that happened two minutes
            # ago is no longer a help; it is noise on top of the present.
            stale = float(cfg.get("staleMs", 45000)) / 1000.0
            try:
                age = time.time() - os.path.getmtime(os.path.join(QUEUE, items[0]))
            except OSError:
                age = 0.0
            if stale > 0 and age > stale:
                try:
                    os.remove(os.path.join(QUEUE, items[0]))
                except OSError:
                    pass
                log("discarded stale queue item (%.0f s): %s" % (age, items[0]))
                continue

            # Make sure the model is loaded BEFORE claiming an item. Claiming
            # deletes the queue file, so a load failure here used to lose the
            # message as well as killing the daemon: the exception escaped main,
            # the process exited, and the next utterance spawned a fresh daemon
            # that died on the next item. Permanent silence, one process per
            # utterance. Loading first means a failure costs nothing but this
            # daemon, and the queue survives for a later attempt.
            #
            # The load is guarded for the same reason the preload is. A model
            # file can exist and still be unloadable: an interrupted download
            # leaves the .onnx without its .onnx.json sidecar. Test-PiperReady
            # now checks for both, but that is a race, not a guarantee.
            model = cfg.get("piperModel", "en_US-lessac-medium")
            if model != loaded_model:
                onnx = os.path.join(VOICEDIR, model + ".onnx")
                if not os.path.exists(onnx):
                    log("model missing: %s" % onnx)
                    break
                try:
                    t0 = time.time()
                    voice = PiperVoice.load(onnx)
                    loaded_model = model
                    log("loaded %s in %.1f s" % (model, time.time() - t0))
                except Exception as e:
                    log("could not load %s: %s - exiting, queue left intact" % (onnx, e))
                    break

            # Claim the item by renaming it BEFORE the text is read. The order
            # used to be the other way round: read, speak, remove, and then two
            # processes could read the same message and say it simultaneously.
            # Only one rename can succeed. The lock above makes that unlikely;
            # this makes it impossible.
            src = os.path.join(QUEUE, items[0])
            path = src + ".mine"
            try:
                os.rename(src, path)
            except OSError:
                continue
            log("queue: %s" % items[0])
            try:
                with open(path, "r", encoding="utf-8") as f:
                    text = f.read()
            except OSError:
                text = ""
            try:
                os.remove(path)
            except OSError:
                pass
            if not text.strip():
                continue

            sent_pause = float(cfg.get("sentencePause", 0.35))
            dash_pause = float(cfg.get("dashPause", sent_pause))
            # Mark that speech is happening, while it happens. The waiting tone
            # uses it to stay quiet, and to notice that speech has resumed.
            try:
                with open(SPEAKFLAG, "w", encoding="ascii") as f:
                    f.write("x")
            except OSError:
                pass
            try:
                speak(voice, text, make_syn_config(cfg), cfg, sent_pause, dash_pause)
            finally:
                try:
                    os.remove(SPEAKFLAG)
                except OSError:
                    pass

            # A gap BETWEEN two queue items. Inside an item there is a pause
            # between sentences, but two items ran straight into each other, so
            # the question and the description sounded like one sentence being
            # cut off by the next. They are two different messages and should be
            # heard as two.
            gap = float(cfg.get("itemPause", 0.6))
            if gap > 0:
                time.sleep(gap)
    finally:
        try:
            with open(PIDFILE, "r", encoding="ascii") as f:
                if f.read().strip() == str(os.getpid()):
                    os.remove(PIDFILE)
        except OSError:
            pass


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        log("CRASH: %s" % e)
        sys.exit(1)
