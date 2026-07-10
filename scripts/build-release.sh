#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Cross-compile all targets, output standalone binaries to dist/.
# Binary names match install.sh expectations: chaza-{os}-{arch}[.exe]

TARGETS=(
  "aarch64-macos:darwin-arm64"
  "x86_64-macos:darwin-x64"
  "aarch64-linux:linux-arm64"
  "x86_64-linux:linux-x64"
  "x86_64-windows:win32-x64"
)

rm -rf dist
mkdir -p dist

filesize() {
  stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

FAILED=()

for entry in "${TARGETS[@]}"; do
  zig_target="${entry%%:*}"
  npm_platform="${entry##*:}"

  echo "→ Building $zig_target..."
  if ! zig build -Dtarget="$zig_target" -Doptimize=ReleaseFast 2>&1; then
    echo "  ERROR: build failed"
    FAILED+=("$npm_platform")
    continue
  fi

  if [[ "$npm_platform" == win32-* ]]; then
    cp zig-out/bin/chaza.exe "dist/chaza-${npm_platform}.exe"
  else
    cp zig-out/bin/chaza "dist/chaza-${npm_platform}"
    chmod +x "dist/chaza-${npm_platform}"
  fi

  out="dist/chaza-${npm_platform}"
  [[ "$npm_platform" == win32-* ]] && out="${out}.exe"
  echo "  ✓ ${out} ($(filesize "$out") bytes)"
done

echo ""
echo "Release binaries ready in dist/:"
ls -lh dist/

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "FAILED:"
  for t in "${FAILED[@]}"; do echo "  - chaza-$t"; done
  exit 1
fi
