#!/bin/zsh
set -eu
cd "${0:A:h}"
dest="${APP_DEST:-../FrameBridge.app}"
dest="${dest:A}"
mkdir -p "${dest:h}"
stage=$(mktemp -d "${dest:h}/.framebridge-build.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/FrameBridge.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Sources/Pipeline.metal "$app/Contents/Resources/"
cp Info.plist "$app/Contents/Info.plist"
xcrun clang -fobjc-arc -O2 -mmacosx-version-min=26.0 Sources/*.m -o "$app/Contents/MacOS/FrameBridge" -framework Metal -framework MetalKit -framework VideoToolbox -framework AppKit -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework QuartzCore
identity="${FRAMEBRIDGE_SIGN_IDENTITY:-}"
if [[ -z "$identity" && -f .signing-identity ]]; then
    identity=$(<.signing-identity)
fi
identity="${identity:--}"
codesign --force --sign "$identity" --timestamp=none "$app"
codesign --verify --strict "$app"
python3 - "$app" "$dest" <<'PY'
import ctypes
import os
import subprocess
import sys
from pathlib import Path

app, dest = map(Path, sys.argv[1:])
processes = subprocess.check_output(["ps", "-axww", "-o", "comm="], text=True).splitlines()
if str(dest / "Contents/MacOS/FrameBridge") in (p.strip() for p in processes):
    sys.exit("FrameBridge is using this bundle. Publish after the preview closes.")
if dest.exists():
    # Atomically exchange complete bundles on the same volume.
    swap = ctypes.CDLL(None, use_errno=True).renamex_np
    swap.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    if swap(os.fsencode(app), os.fsencode(dest), 2) != 0:
        raise OSError(ctypes.get_errno(), "Cannot exchange FrameBridge bundles")
else:
    os.rename(app, dest)
PY
