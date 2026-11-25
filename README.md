# FrameBridge

FrameBridge plays PS5 HDMI capture on an Apple Silicon Mac. Its interpolation mode targets 1080p at 60 fps from a 30 fps game carried over a 60 Hz HDMI signal. You can also view the capture at its native frame rate. Both modes play HDMI audio through the Mac’s current audio output.

## Build and play

You need macOS 26 or later, Xcode or Apple Command Line Tools with the macOS 26 SDK or later, and Python 3. The app looks for a capture card named `USB3 Video` and an audio device named `USB3 Digital Audio`. Connect the PS5 to the card’s HDMI input and the card to the Mac over USB. Keep the controller connected to the PS5.

From the repository root, run

```sh
./build.sh
open ../FrameBridge.app
```

Allow camera access for video and microphone access for HDMI audio. The preview opens at the available screen size. Use the green window button to enter full screen.

Open the **Output** menu (输出) to switch modes during play. Both modes share the same capture and audio sessions.

| Menu item | What it does |
| --- | --- |
| Frame interpolation (补帧) | Selects one original frame every two 60 Hz capture slots and generates a midpoint between consecutive selected frames. The cadence stays fixed even when the game itself reaches 60 fps. If capture slots go missing, the player keeps the available originals and resumes interpolation when consecutive pairs return. |
| Native output (原生输出) | Displays the latest frame from the card directly. Use this for games already running at 60 fps or to compare the original picture with the interpolated output. |
| Reconnect (重新连接) | Reopens the capture session after a device or connection change. |

## How interpolation works

AVFoundation requests SDR video in video-range NV12. After capture starts, FrameBridge reapplies the supported 60 Hz frame duration because the card can renegotiate to 20 Hz during startup. A Core Video Metal texture cache maps the luma and chroma planes for GPU processing.

For each consecutive pair of selected originals, VideoToolbox generates a 720p reference midpoint while Metal aligns the originals at capture resolution. Metal searches for large camera translations on a downsampled image, checks the motion at different heights and refines local displacement to quarter-pixel precision. Where local brightness and texture agree with the reference, the shader restores high-frequency luma detail from the aligned originals. When one endpoint is occluded, the shader can recover detail from the other. Matching stationary neighborhoods help preserve HUD text and fine textures. Fast turns, thin objects and newly revealed backgrounds can still produce visible artifacts.

The player queues the 720p reference as soon as it is ready. The display shader can scale it directly to the viewport while capture-resolution detail restoration runs. If detail restoration finishes before the midpoint is consumed, the restored frame takes its place at the same timestamp.

VideoToolbox runs on a separate queue with one job in flight. A Metal path can generate the midpoint when the model is unavailable or busy. The player queues each selected original immediately so it can still appear when its midpoint misses the presentation deadline.

## Frame pacing and latency

The default playback buffer is 33 ms. On high-refresh displays the renderer checks for new frames up to 120 times per second and allows up to three drawable buffers with at most two render submissions in flight. HDMI audio goes directly through `AVCaptureAudioPreviewOutput` without an additional video-delay adjustment.

The runtime log counts selected originals (选取), queued midpoints (补), frames actually presented (显示), and midpoints actually presented (上屏补帧). A static scene can still produce new timestamps. A slow interval is a gap longer than 22 ms between presentations of distinct frames. Software latency measures the time from an original frame entering the player until its first presentation. Measuring controller-to-screen latency also requires accounting for the game, HDMI capture, USB transfer and panel response.

To inspect recent playback, query the numeric performance records in the macOS unified log.

```sh
/usr/bin/log show --last 15m --style compact --predicate 'subsystem == "local.framebridge.preview" AND category == "performance"'
```

Each record covers `interval_s` seconds. Divide frame counts by this duration to get fps. The VT columns track the VideoToolbox-guided path and the Metal columns track the standalone fallback. Each path reports jobs started, midpoints produced, midpoints queued and distinct midpoints presented. Jobs can cross a reporting boundary, so sum counts over multiple records. `original_latency_p50_ms=-1` means no original-frame latency sample was available in the interval.

## Run benchmarks

Use an idle or dedicated Mac with the display awake. Keep the refresh rate and system load comparable between runs. The benchmark builds a separate executable from the same player and shaders. It exits if FrameBridge is open, including when the preview opens during a test.

```sh
python3 Benchmarks/run.py --out /tmp/framebridge-check.json
```

The default quality test generates a reproducible 1080p pan with thin poles, occlusions and a stationary HUD. It withholds known intermediate frames, reconstructs them and compares the results against the originals. The report includes mean absolute luma error, edge error, edge-gradient error, the fraction of edge pixels with large errors, and median and P95 generation time.

To test your own footage, pass `--clip` with a 1080p60 raw NV12 file or an FFV1-encoded MKV. MKV decoding requires FFmpeg. Some historical reports used a locally held two-second gameplay clip. Reproducing those reports with `--check` requires that exact clip at `Benchmarks/fixtures/gameplay.mkv` and the reference machine and OS. For other setups, establish a local reference and reuse the same clip for comparisons.

```sh
python3 Benchmarks/run.py --buffers 33 --clip /path/to/capture.mkv --out /tmp/reference.json
python3 Benchmarks/run.py --buffers 32 33 34 --clip /path/to/capture.mkv --against /tmp/reference.json --out /tmp/candidates.json
```

The playout test feeds a 60 Hz stream made from a 30 fps sequence with each frame repeated twice. It uses a real Metal window and counts each original and generated frame on its first presentation. By default it warms up for two seconds, then measures six seconds per round for three rounds. A passing profile presents at least 59 distinct frames per second in every round and a median of at least 29 generated frames per second. Against a matching reference, the median presentation rate may drop by up to 0.5 fps and original-frame P95 latency may increase by up to 2 ms. Each quality error may increase by up to 3% of its reference value plus 0.05. The command writes the individual rounds to JSON and exits with a nonzero status if a threshold is missed.

## Update a local installation

Close the preview before installing a new app build. The build script compiles into a staging directory, verifies the signature, then replaces the bundle at `../FrameBridge.app`. It uses ad hoc signing by default. To keep a consistent signing identity across updates, put your Apple Development certificate fingerprint in the local `.signing-identity` file or set `FRAMEBRIDGE_SIGN_IDENTITY`. The environment variable takes precedence. macOS may request camera and microphone access again when the signing identity changes.

For a shader-only change, run `./hot-update.sh` to install the current Metal source for the current build number. The running app compiles the new pipelines in the background and switches after compilation succeeds. Shader function names, arguments and texture layouts must match the running build. Run `./hot-update.sh --reset` to restore the bundled shader. Changes to capture, audio or Objective-C scheduling require a full app build.

## Project language

Use English for repository documentation, commit messages, issues, pull requests and release notes. When reporting a playback issue, include the output mode, capture format and display refresh rate so others can reproduce it.
