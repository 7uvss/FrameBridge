"""CPU-only screen of the stationary-luma branch using saved 1080p NV12 footage."""
import json
import re
from pathlib import Path
import subprocess
import sys

WIDTH, HEIGHT = 1920, 1080
RADII = (2, 3, 4)
LIMITS = (1, 2, 3)
def shader_settings(shader):
    matches = re.findall(r"constant int stationary(Radius|Limit)=(\d+);", shader)
    settings = dict(matches)
    if len(matches) != 2 or set(settings) != {"Radius", "Limit"}:
        raise ValueError("Stationary shader configuration unavailable")
    return int(settings["Radius"]), int(settings["Limit"])



def sample_clip(path):
    # Keep decoder, filter and encoder on one CPU thread each. No capture devices.
    command = ["ffmpeg", "-nostdin", "-v", "error", "-hwaccel", "none", "-threads", "1",
               "-filter_threads", "1", "-i", path, "-map", "0:v:0", "-vf", "extractplanes=y",
               "-an", "-threads", "1", "-fps_mode", "passthrough", "-f", "rawvideo", "-"]
    scores = [{(r, t): [0, 0, 0] for r in RADII for t in LIMITS} for _ in range(2)]
    edges = [0, 0]
    with subprocess.Popen(command, stdout=subprocess.PIPE) as proc:
        frames = []
        index = 0
        while True:
            frame = proc.stdout.read(WIDTH * HEIGHT)
            if not frame:
                break
            if len(frame) != WIDTH * HEIGHT:
                raise ValueError("Incomplete luma plane")
            if index % 2 == 0:
                frames.append(frame)
            index += 1
            if len(frames) != 3:
                continue
            left, truth, right = frames
            # Disjoint time blocks; omit the boundary triplet shared by both.
            start = index - 5
            if start < 56 or start >= 60:
                split = int(start >= 60)
                for y in range(8 + start // 4 % 5, HEIGHT - 8, 11):
                    for x in range(8 + start // 4 % 7, WIDTH - 8, 13):
                        k = y * WIDTH + x
                        if abs(truth[k+1]-truth[k-1]) + abs(truth[k+WIDTH]-truth[k-WIDTH]) < 32:
                            continue
                        edges[split] += 1
                        center = abs(left[k] - right[k])
                        if center > max(LIMITS):
                            continue
                        error = abs((left[k] + right[k])/2 - truth[k])
                        for radius in RADII:
                            drift = center
                            for row in (-radius*WIDTH, radius*WIDTH):
                                for col in (-radius, radius):
                                    j = k + row + col
                                    drift = max(drift, abs(left[j] - right[j]))
                            for limit in LIMITS:
                                if drift <= limit:
                                    counts = scores[split][radius, limit]
                                    counts[0] += 1
                                    counts[1] += int(error <= 3)
                                    counts[2] += int(error >= 24)
            frames = [right]
        if proc.wait() or not all(edges):
            raise ValueError("Fixture decode failed or the time slices have no edges")
    return scores, edges


def main():
    shader = Path(__file__).resolve().parents[1] / "Sources/Pipeline.metal"
    current = shader_settings(shader.read_text())
    scores, edges = sample_clip(sys.argv[1])
    rows = []
    for key in scores[0]:
        row = {"radius": key[0], "limit": key[1]}
        for part, counts, total in zip(("train", "holdout"), scores, edges):
            seen, good, bad = counts[key]
            row[part] = {"edges": total, "accepted": seen, "accurate": good, "severe": bad,
                         "accurate_pct": 100 * good/total, "severe_pct": 100 * bad/total}
        rows.append(row)
    baseline = next(r for r in rows if (r["radius"], r["limit"]) == current)
    def passes(r, part):
        return (r[part]["accurate_pct"] > baseline[part]["accurate_pct"]
                and r[part]["severe_pct"] <= baseline[part]["severe_pct"] + 0.05)
    shortlist = sorted((r for r in rows if passes(r, "train")),
                       key=lambda r: -r["train"]["accurate_pct"])[:2]
    print(json.dumps({"profiles": rows, "baseline": baseline,
                      "shortlist": [r for r in shortlist if passes(r, "holdout")]}))


if __name__ == "__main__":
    main()
