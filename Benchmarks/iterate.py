"""Run a bounded, unattended candidate comparison against an immutable source snapshot."""
import argparse
import difflib
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import time
from pathlib import Path
from probe_stationary import shader_settings

ROOT = Path(__file__).resolve().parents[1]
BUSY = 75


def save(path, obj):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n")
    temp.replace(path)


def snapshot(dest):
    dest.mkdir()
    shutil.copytree(ROOT / "Sources", dest / "Sources")
    for name in ("Info.plist", "build.sh"):
        shutil.copy2(ROOT / name, dest / name)
    if (ROOT / ".signing-identity").is_file():
        shutil.copy2(ROOT / ".signing-identity", dest / ".signing-identity")
    dst = dest / "Benchmarks"
    dst.mkdir()
    for name in ("run.py", "Bench.m", "reference.json", "probe_stationary.py"):
        shutil.copy2(ROOT / "Benchmarks" / name, dst / name)
    (dst / "fixtures").mkdir()
    shutil.copyfile(ROOT / "Benchmarks/fixtures/gameplay.mkv", dst / "fixtures/gameplay.mkv")


def preview_active():
    code = subprocess.run(["/usr/bin/pgrep", "-u", str(os.getuid()), "-x", "FrameBridge"],
                          stdout=subprocess.DEVNULL).returncode
    if code not in (0, 1):
        raise RuntimeError("Unable to check live preview")
    return code == 0


def trial(root, name, work, buffers, state, publish):
    output = work / (name + ".json")
    state["trial"] = name
    while True:
        if preview_active():
            state["state"] = "waiting_for_preview_exit"
            publish()
            while preview_active():
                time.sleep(5)
        state["state"] = "measuring"
        publish()
        with (work / (name + ".log")).open("a") as log:
            bench = root / "Benchmarks"
            result = subprocess.run([sys.executable, bench / "run.py", "--buffers", *map(str, buffers),
                                     "--clip", bench / "fixtures/gameplay.mkv", "--against",
                                     bench / "reference.json", "--out", output], stdout=log, stderr=log)
        if result.returncode == BUSY:
            continue
        if result.returncode not in (0, 1) or not output.exists():
            raise RuntimeError(f"{name} failed; see {name}.log")
        return json.loads(output.read_text())


def compare(base, test):
    if not test["selected"]:
        return None
    # Judge the shipping implementation and candidate on identical samples.
    for scene, old in base["quality"].items():
        for field in ("mae", "edge_mae", "bad_edge_pct", "edge_gradient_error"):
            if test["quality"][scene][field] > old[field] * 1.03 + 0.05:
                return None
    old = base["profiles"][0]
    ratio = test["quality"]["capture"]["edge_mae"] / base["quality"]["capture"]["edge_mae"]
    choices = []
    for p in test["profiles"]:
        gain = old["original_p95_ms"] - p["original_p95_ms"]
        if (p["min_unique_fps"] >= 59 and p["generated_fps"] >= 29 and
            p["unique_fps"] >= old["unique_fps"] - 0.5 and gain >= -2 and
            (ratio <= .99 or gain >= 2)):
            choices.append((p["original_p95_ms"], p["buffer_ms"]))
    return min(choices) if choices else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    args = parser.parse_args()
    work, report = args.work.resolve(), args.report.resolve()
    work.mkdir(parents=True, exist_ok=False)
    state = {"state": "screening", "pid": os.getpid(), "trials": {}}
    def publish():
        save(report, state)
    try:
        publish()
        baseline = work / "baseline"
        snapshot(baseline)
        shader_path = Path("Sources/Pipeline.metal")
        original = (baseline / shader_path).read_text()
        bench = baseline / "Benchmarks"
        raw = subprocess.check_output(["/usr/sbin/taskpolicy", "-b", "/usr/bin/nice", "-n", "15",
                                       sys.executable, bench / "probe_stationary.py",
                                       bench / "fixtures/gameplay.mkv"], text=True)
        screen = json.loads(raw)
        state["cpu_screen"] = screen
        state["fixture_sha256"] = hashlib.sha256((bench / "fixtures/gameplay.mkv").read_bytes()).hexdigest()
        publish()
        settings = plistlib.loads((baseline / "Info.plist").read_bytes())
        current_buffer = settings["FrameBridgeDetailBufferMS"]
        base = trial(baseline, "shipping", work, [current_buffer], state, publish)
        state["trials"]["shipping"] = base
        winners = []
        for row in screen["shortlist"]:
            radius, limit = row["radius"], row["limit"]
            name = f"radius-{radius}-limit-{limit}"
            root = work / name
            shutil.copytree(baseline, root, ignore=shutil.ignore_patterns("gameplay.mkv"))
            os.link(bench / "fixtures/gameplay.mkv", root / "Benchmarks/fixtures/gameplay.mkv")
            old_radius, old_limit = shader_settings(original)
            shader = original.replace(f"stationaryRadius={old_radius};", f"stationaryRadius={radius};")
            shader = shader.replace(f"stationaryLimit={old_limit};", f"stationaryLimit={limit};")
            (root / shader_path).write_text(shader)
            test = trial(root, name, work, [40, 38], state, publish)
            state["trials"][name] = test
            score = compare(base, test)
            if score is not None:
                winners.append((*score, name))
            publish()
        state["state"] = "no_candidate_passed"
        for _, ms, name in sorted(winners):
            root = work / name
            confirmed = trial(root, name + "-confirm", work, [ms], state, publish)
            state["trials"][name + "-confirm"] = confirmed
            if compare(base, confirmed) is None:
                state["state"] = "no_candidate_passed"
                continue
            settings = root / "Info.plist"
            info = plistlib.loads(settings.read_bytes())
            info["FrameBridgeDetailBufferMS"] = ms
            major, minor, patch = info["CFBundleShortVersionString"].split(".")
            info["CFBundleShortVersionString"] = f"{major}.{minor}.{int(patch)+1}"
            info["CFBundleVersion"] = str(int(info["CFBundleVersion"]) + 1)
            settings.write_bytes(plistlib.dumps(info))
            binary = work / "FrameBridge.app"
            subprocess.run(["/usr/sbin/taskpolicy", "-b", root / "build.sh"], check=True,
                           env={**os.environ, "APP_DEST": str(binary)})
            subprocess.run(["codesign", "--verify", "--strict", binary], check=True)
            target = args.candidate.resolve()
            if target.exists():
                raise FileExistsError(target)
            binary.rename(target)
            (work / "accepted.patch").write_text("".join(difflib.unified_diff(
                original.splitlines(True), (root / shader_path).read_text().splitlines(True),
                fromfile="a/Sources/Pipeline.metal", tofile="b/Sources/Pipeline.metal")))
            state.update(state="candidate_ready", candidate=str(target), profile=name, buffer_ms=ms)
            break
        publish()
    except BaseException as error:
        state.update(state="stopped", reason=str(error))
        publish()
        raise


if __name__ == "__main__":
    main()
