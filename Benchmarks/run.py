#!/usr/bin/env python3
"""Build a temporary native benchmark and keep a machine-readable result."""
import argparse
import hashlib
import os
import signal
import time
import json
import platform
import plistlib
import shutil
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources"
FILES = [Path(__file__).with_name("Bench.m")] + [
    SOURCE / (name + ".m") for name in ("Player", "Interpolator", "MetalEngine", "NativeMotion")
]
FRAMEWORKS = ["Metal", "MetalKit", "VideoToolbox", "AppKit", "AVFoundation",
              "CoreMedia", "CoreVideo", "QuartzCore"]


def require_idle_preview():
    status = subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "FrameBridge"],
                            stdout=subprocess.DEVNULL).returncode
    if status == 0:
        print("FrameBridge 正在使用中，基准已退出。", file=sys.stderr)
        raise SystemExit(75)
    if status != 1:
        raise SystemExit("无法确认播放器状态，已停止基准。")


def run_isolated(command, capture_output=False, timeout=180):
    require_idle_preview()
    pipe = subprocess.PIPE if capture_output else None
    with subprocess.Popen(command, stdout=pipe, stderr=pipe, text=True, start_new_session=True) as proc:
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    out, err = proc.communicate(timeout=0.5)
                    break
                except subprocess.TimeoutExpired:
                    require_idle_preview()
                    if time.monotonic() >= deadline:
                        raise SystemExit("Benchmark timed out")
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
        if proc.returncode:
            raise SystemExit(err or f"{command[0]} failed ({proc.returncode})")
        return out


def build(directory):
    contents = directory / "Bench.app" / "Contents"
    exe = contents / "MacOS" / "Bench"
    exe.parent.mkdir(parents=True)
    resources = contents / "Resources"
    resources.mkdir()
    (contents / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.framebridge.benchmark", "CFBundleExecutable": "Bench",
        "CFBundlePackageType": "APPL", "CFBundleName": "FrameBridge Benchmark",
        "NSHighResolutionCapable": True
    }))
    shutil.copy(SOURCE / "Pipeline.metal", resources)
    cmd = ["xcrun", "clang", "-fobjc-arc", "-O2", "-mmacosx-version-min=26.0",
           "-I", SOURCE, *FILES, "-o", exe]
    for name in FRAMEWORKS:
        cmd.extend(["-framework", name])
    run_isolated(cmd)
    run_isolated(["codesign", "--force", "--sign", "-", contents.parent])
    return exe


def digest(paths):
    h = hashlib.sha256()
    for path in paths:
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1 << 20), b""):
                h.update(block)
    return h.hexdigest()


def measure(exe, *args):
    return json.loads(run_isolated([exe, *map(str, args)], capture_output=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--buffers", type=float, nargs="+", help="Playback buffer candidates in milliseconds; defaults to the app setting")
    parser.add_argument("--seconds", type=int, default=6)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--clip", type=Path, help="Optional 1080p60 raw NV12 or FFV1 MKV capture")
    parser.add_argument("--against", type=Path, help="Reference report; compare against its selected buffer")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--check", action="store_true", help="Check the shipping profile against the bundled reference and fixture")
    args = parser.parse_args()
    if args.check:
        if args.against or args.buffers or args.clip:
            parser.error("--check uses the shipped profile, reference and fixture")
        args.clip = ROOT / "Benchmarks/fixtures/gameplay.mkv"
        args.against = ROOT / "Benchmarks/reference.json"
    if not args.buffers:
        settings = plistlib.loads((ROOT / "Info.plist").read_bytes())
        args.buffers = [settings.get("FrameBridgeDetailBufferMS", 44)]
    if not (args.rounds >= 1 and 3 <= args.seconds <= 120 and all(16 <= n <= 100 for n in args.buffers)):
        parser.error("use at least one round, 3–120 seconds and buffers of 16–100 ms")
    require_idle_preview()
    with tempfile.TemporaryDirectory() as tmp:
        exe = build(Path(tmp))
        hw = subprocess.check_output(["sysctl", "-n", "hw.model"], text=True).strip()
        result = {"schema": 1, "machine": hw, "macOS": platform.mac_ver()[0],
                  "seconds": args.seconds, "rounds": args.rounds,
                  "fixture": digest([FILES[0]]), "source": digest(FILES[1:] + [SOURCE / "Pipeline.metal"]),
                  "quality": {"synthetic": measure(exe, "quality")}, "runs": []}
        if args.clip:
            clip = args.clip
            if clip.suffix.lower() == ".mkv":
                if not shutil.which("ffmpeg"):
                    parser.error("ffmpeg is required to unpack MKV fixtures")
                clip = Path(tmp) / "clip.nv12"
                run_isolated(["ffmpeg", "-v", "error", "-nostdin", "-i", args.clip,
                                "-map", "0:v:0", "-fps_mode", "passthrough", "-pix_fmt", "nv12",
                                "-f", "rawvideo", clip])
            result["clip_sha256"] = digest([clip])
            result["quality"]["capture"] = measure(exe, "quality", clip)
        for r in range(args.rounds):
            # Rotate the first profile each round to distribute warm-up and load.
            n = r % len(args.buffers)
            for ms in args.buffers[n:] + args.buffers[:n]:
                row = measure(exe, "playback", ms, args.seconds)
                result["runs"].append(row)
                print(json.dumps(row), flush=True)
    profiles = []
    for ms in sorted(set(args.buffers)):
        runs = [r for r in result["runs"] if r["buffer_ms"] == ms]
        summary = {k: statistics.median(r[k] for r in runs) for k in runs[0]}
        summary["min_unique_fps"] = min(r["unique_fps"] for r in runs)
        profiles.append(summary)
    result["profiles"] = profiles
    passed = [p for p in profiles if p["min_unique_fps"] >= 59 and p["generated_fps"] >= 29]
    failures = []
    if args.against:
        base = json.loads(args.against.read_text())
        if any(result.get(k) != base.get(k) for k in ("schema", "fixture", "clip_sha256", "machine", "macOS", "seconds", "rounds")):
            failures.append("incompatible reference environment, fixture or duration")
        ref = base.get("selected")
        if not ref:
            failures.append("reference has no passing profile")
        else:
            passed = [p for p in passed if p["original_p95_ms"] <= ref["original_p95_ms"] + 2
                      and p["unique_fps"] >= ref["unique_fps"] - 0.5]
        for scene, metrics in result["quality"].items():
            for k in ("mae", "edge_mae", "bad_edge_pct", "edge_gradient_error"):
                baseline = base["quality"].get(scene, {}).get(k)
                if baseline is None or metrics[k] > baseline * 1.03 + 0.05:
                    failures.append(f"{scene} {k} exceeds reference tolerance")
    if not passed:
        failures.append("no playout profile passed")
    result["selected"] = min(passed, key=lambda p: (p["original_p95_ms"], p["original_p50_ms"])) if passed and not failures else None
    result["failures"] = failures
    args.out.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"selected": result["selected"], "failures": failures}, indent=2))
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
