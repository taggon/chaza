#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TARGETS=(
    "x86_64-linux-gnu"
    "x86_64-macos-none"
    "aarch64-linux-gnu"
    "aarch64-macos-none"
    "x86_64-windows-gnu"
    "aarch64-windows-gnu"
)

mkdir -p dist

# Detect stat flavor (BSD vs GNU)
filesize() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

FAILED=()

for target in "${TARGETS[@]}"; do
    echo "→ Building $target..."
    if ! zig build -Dtarget="$target" -Doptimize=ReleaseSafe 2>&1; then
        echo "  ERROR: build failed for $target"
        FAILED+=("$target")
        continue
    fi

    if [[ "$target" == *windows* ]]; then
        bin="zig-out/bin/chaza.exe"
        out="dist/chaza-$target.exe"
    else
        bin="zig-out/bin/chaza"
        out="dist/chaza-$target"
    fi

    if [[ -f "$bin" ]]; then
        mv "$bin" "$out"
        echo "  → $out ($(filesize "$out") bytes)"
    else
        echo "  ERROR: $bin not found"
        FAILED+=("$target")
        continue
    fi
done

echo ""
echo "Cross-compile matrix complete:"
ls -la dist/

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    echo "FAILED targets:"
    for t in "${FAILED[@]}"; do
        echo "  - $t"
    done
fi
