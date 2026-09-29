#!/bin/bash
# Build the self-contained Python runtime the worker runs in, at build/runtime.
#
# It is a relocatable CPython from python-build-standalone, pinned by release
# and checked against its SHA-256, with exactly the worker's pinned packages
# installed into it and nothing resolved beyond them (see worker/pyproject.toml
# for why --no-deps). The app bundle copies this directory to
# Contents/Resources/runtime.
set -euo pipefail

PYTHON_RELEASE="20260924"
PYTHON_ARCHIVE="cpython-3.12.14+${PYTHON_RELEASE}-aarch64-apple-darwin-install_only_stripped.tar.gz"
PYTHON_SHA256="c2edb321cd32ec2b170df208db0446dccc4398db602ca27cf2079098fb1f7d9d"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/${PYTHON_ARCHIVE//+/%2B}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$ROOT/build/cache"
RUNTIME="$ROOT/build/runtime"
ARCHIVE_PATH="$CACHE/$PYTHON_ARCHIVE"

command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/" >&2; exit 1; }

# The archive is cached between builds, and verified every time it is used...
mkdir -p "$CACHE"
if [[ ! -f "$ARCHIVE_PATH" ]]; then
    curl --fail --location --silent --show-error --output "$ARCHIVE_PATH.partial" "$PYTHON_URL"
    mv "$ARCHIVE_PATH.partial" "$ARCHIVE_PATH"
fi
actual="$(shasum -a 256 "$ARCHIVE_PATH" | cut -d' ' -f1)"
if [[ "$actual" != "$PYTHON_SHA256" ]]; then
    echo "SHA-256 mismatch for $PYTHON_ARCHIVE: expected $PYTHON_SHA256, got $actual" >&2
    exit 1
fi

# A fresh runtime every build, so nothing from a previous build survives...
rm -rf "$RUNTIME"
mkdir -p "$RUNTIME"
tar -xzf "$ARCHIVE_PATH" -C "$RUNTIME" --strip-components 1
PYTHON="$RUNTIME/bin/python3"

# The standalone build marks itself externally managed; this runtime is
# private to the app, so installing into it directly is the point...
rm -f "$RUNTIME"/lib/python3.12/EXTERNALLY-MANAGED
# Wheels are chosen for the oldest macOS PrivacyFlow supports, not for the
# machine building it: a wheel built for a newer macOS will not load on an
# older one, and uv otherwise picks the newest this machine can run...
MINIMUM_MACOS="14.0"
export MACOSX_DEPLOYMENT_TARGET="$MINIMUM_MACOS"
uv pip install --python "$PYTHON" --python-platform aarch64-apple-darwin --no-deps \
    --requirement "$ROOT/worker/pyproject.toml"
uv pip install --python "$PYTHON" --python-platform aarch64-apple-darwin --no-deps "$ROOT/worker"

# Parts of the standard library the worker never loads: the test suite, the
# GUI toolkits and their Tcl/Tk libraries, and the package bootstrappers...
LIB="$RUNTIME/lib/python3.12"
rm -rf "$LIB"/{test,idlelib,tkinter,turtledemo,ensurepip,lib2to3} "$RUNTIME"/lib/{tcl,tk,itcl,thread}* \
    "$RUNTIME"/share "$RUNTIME"/include
rm -rf "$LIB"/site-packages/pip "$LIB"/site-packages/pip-*.dist-info

# Only the interpreter is run. The packages' command-line launchers are not,
# and each one names this machine's build path in its first line, as does the
# record of where the worker was installed from...
find "$RUNTIME/bin" -mindepth 1 ! -name python3 ! -name python3.12 -delete
rm -f "$LIB"/site-packages/*.dist-info/direct_url.json
find "$RUNTIME" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$RUNTIME" -type d \( -name tests -o -name test \) -path '*/site-packages/*' -prune -exec rm -rf {} +

# The bundle is signed and must not be written to at run time, so bytecode is
# compiled now. Unchecked hashes keep it valid whatever timestamps copying and
# signing leave behind. The build directory is stripped from the source paths
# recorded in it, which would otherwise publish this machine's home directory;
# Python replaces the recorded path with the real one when it loads the file...
"$PYTHON" -I -B -m compileall -f -q -j 0 --invalidation-mode unchecked-hash -s "$RUNTIME" "$RUNTIME/lib" >/dev/null

# Prove the runtime can load everything the worker loads, at the versions it
# pins, without anything from this machine. The worker imports its libraries
# lazily, so importing the worker alone would prove little...
env -i HOME="$HOME" "$PYTHON" -I -B -c "
import mlx.core, mlx_lm, onnxruntime, transformers
from privacyflow_worker import worker
from privacyflow_worker.recognizer import _import_mlx_whisper
_import_mlx_whisper()
worker._check_pinned_versions()
" || { echo "The built runtime cannot load the worker's libraries" >&2; exit 1; }

# Every binary must load on the oldest supported macOS...
while IFS= read -r -d '' candidate; do
    file --brief "$candidate" | grep -q "Mach-O" || continue
    required="$(vtool -show-build "$candidate" 2>/dev/null | awk '/minos/ { print $2; exit }' || true)"
    if [[ "$(printf '%s\n%s\n' "$required" "$MINIMUM_MACOS" | sort -V | tail -1)" != "$MINIMUM_MACOS" ]]; then
        echo "$candidate requires macOS $required, newer than the supported $MINIMUM_MACOS" >&2
        exit 1
    fi
done < <(find "$RUNTIME" -type f -print0)

# Nothing that ships may name the machine it was built on...
leaks="$(LC_ALL=C /usr/bin/grep -rlaF "$HOME" "$RUNTIME" || true)"
if [[ -n "$leaks" ]]; then
    echo "The built runtime contains this machine's home directory path in:" >&2
    echo "$leaks" >&2
    exit 1
fi

echo "Runtime built at $RUNTIME ($(du -sh "$RUNTIME" | cut -f1))"
