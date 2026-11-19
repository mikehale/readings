#!/usr/bin/env python3
"""Short-lived XTTSv2 synth with Curt speaker wav + hard RSS kill.

Uses ebook2audiobook's coqui XTTS-v2 snapshot + voices/.../Curt.wav.
"""
from __future__ import annotations

import argparse
import os
import re
import resource
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

GIB = 2**30
RSS_KILL_GIB = 14.0


def immediate_free_gib() -> float:
    page = int(subprocess.check_output(["pagesize"], text=True))
    out = subprocess.check_output(["vm_stat"], text=True)

    def n(label: str) -> int:
        m = re.search(rf"{re.escape(label)}:\s+(\d+)", out)
        return int(m.group(1)) * page if m else 0

    return (n("Pages free") + n("Pages speculative") + n("Pages purgeable")) / GIB


def phys_footprint_gib() -> float:
    try:
        import ctypes
        import ctypes.util

        lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libSystem.dylib")
        buf = ctypes.create_string_buffer(512)
        if lib.proc_pid_rusage(os.getpid(), 0, buf) == 0:
            return int.from_bytes(buf.raw[72:80], "little") / GIB
    except Exception:
        pass
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / GIB


def maxrss_gib() -> float:
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / GIB


class RssKiller:
    def __init__(self, limit_gib: float, interval_s: float = 0.25):
        self.limit_gib = limit_gib
        self.interval_s = interval_s
        self.peak = 0.0
        self._stop = threading.Event()
        self._thread = None

    def __enter__(self):
        self._thread = threading.Thread(target=self._run, name="rss-killer", daemon=True)
        self._thread.start()
        return self

    def _run(self):
        while not self._stop.wait(self.interval_s):
            fp = phys_footprint_gib()
            if fp > self.peak:
                self.peak = fp
            if fp > self.limit_gib:
                print(
                    f"GUARD ABORT: phys_footprint {fp:.2f} GiB > {self.limit_gib:.2f} GiB",
                    flush=True,
                )
                os.kill(os.getpid(), signal.SIGKILL)

    def __exit__(self, *exc):
        self._stop.set()
        if self._thread:
            self._thread.join(timeout=1)
        return False


def wav_to_mp3(wav: Path, mp3: Path) -> None:
    subprocess.check_call(
        ["ffmpeg", "-y", "-i", str(wav), "-codec:a", "libmp3lame", "-q:a", "2", str(mp3)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--text", required=True, type=Path)
    ap.add_argument("--speaker-wav", required=True, type=Path)
    ap.add_argument("--model-dir", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    ap.add_argument("--rss-kill-gib", type=float, default=RSS_KILL_GIB)
    ap.add_argument("--min-free-gib", type=float, default=0.0)
    ap.add_argument("--language", default="en")
    args = ap.parse_args()

    free = immediate_free_gib()
    print(
        f"preflight immediate_free_GiB={free:.3f} need>={args.min_free_gib:.1f} "
        f"rss_kill={args.rss_kill_gib:.1f} device={args.device}",
        flush=True,
    )
    if free < args.min_free_gib:
        print(f"ABORT: free {free:.3f} < {args.min_free_gib:.1f}", flush=True)
        return 2

    text = args.text.read_text().strip()
    if not text:
        print("ABORT: empty text", flush=True)
        return 2
    if not args.speaker_wav.is_file():
        print(f"ABORT: missing speaker {args.speaker_wav}", flush=True)
        return 2
    model_dir = args.model_dir
    for name in ("config.json", "model.pth", "vocab.json"):
        if not (model_dir / name).exists():
            print(f"ABORT: missing {name} in {model_dir}", flush=True)
            return 2

    os.environ.setdefault("COQUI_TOS_AGREED", "1")
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
    os.environ.setdefault("OMP_NUM_THREADS", "2")
    if args.device == "mps":
        os.environ["PYTORCH_MPS_HIGH_WATERMARK_RATIO"] = "0.30"
        os.environ["PYTORCH_MPS_LOW_WATERMARK_RATIO"] = "0.00"

    out = args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    wav_out = out.with_suffix(".wav") if out.suffix.lower() == ".mp3" else out

    with RssKiller(args.rss_kill_gib) as killer:
        t0 = time.time()
        print(f"loading XTTSv2 from {model_dir} device={args.device}…", flush=True)
        import torch

        # Coqui XTTS checkpoints need weights_only=False (trusted local coqui/XTTS-v2).
        _orig_load = torch.load

        def _load(*a, **k):
            k.setdefault("weights_only", False)
            return _orig_load(*a, **k)

        torch.load = _load  # type: ignore[assignment]

        from TTS.api import TTS

        if args.device == "cpu":
            torch.set_num_threads(max(1, min(4, os.cpu_count() or 2)))

        # gpu=False for CPU; for MPS pass gpu=True is CUDA-oriented — load then .to(device)
        tts = TTS(model_path=str(model_dir), config_path=str(model_dir / "config.json"), gpu=False)
        if args.device == "mps":
            try:
                tts.to("mps")
            except Exception as exc:
                print(f"MPS move failed ({exc}); staying on CPU", flush=True)
                args.device = "cpu"

        print(
            f"loaded in {time.time() - t0:.1f}s "
            f"footprint={phys_footprint_gib():.2f}GiB maxrss={maxrss_gib():.2f}GiB",
            flush=True,
        )

        t1 = time.time()
        tts.tts_to_file(
            text=text,
            speaker_wav=str(args.speaker_wav),
            language=args.language,
            file_path=str(wav_out),
        )
        gen_s = time.time() - t1
        print(
            f"gen={gen_s:.1f}s wrote {wav_out} "
            f"footprint={phys_footprint_gib():.2f}GiB maxrss={maxrss_gib():.2f}GiB "
            f"peak_guard={killer.peak:.2f}GiB",
            flush=True,
        )
        del tts
        if args.device == "mps":
            try:
                import gc

                gc.collect()
                torch.mps.empty_cache()
            except Exception:
                pass

    if out.suffix.lower() == ".mp3":
        wav_to_mp3(wav_out, out)
        print(f"wrote {out}", flush=True)
        try:
            wav_out.unlink()
        except OSError:
            pass

    print(f"done peak_guard_GiB={killer.peak:.2f} maxrss_GiB={maxrss_gib():.2f}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
