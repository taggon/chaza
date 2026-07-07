#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(node -p "require('./npm/chaza/package.json').version")
ROOT="$(pwd)"

# zig target → npm platform-arch
TARGETS=(
  "aarch64-macos:darwin-arm64"
  "x86_64-macos:darwin-x64"
  "aarch64-linux:linux-arm64"
  "x86_64-linux:linux-x64"
  "x86_64-windows:win32-x64"
)

NPM_DIR="$ROOT/npm"
SCOPE_DIR="$NPM_DIR/@chaza"

rm -rf "$SCOPE_DIR"
mkdir -p "$SCOPE_DIR"

# Compile TypeScript loader
echo "→ Compiling TypeScript..."
(cd "$NPM_DIR/chaza" && npm run build)

FAILED=()

for entry in "${TARGETS[@]}"; do
  zig_target="${entry%%:*}"
  npm_platform="${entry##*:}"
  os="${npm_platform%%-*}"
  cpu="${npm_platform##*-}"

  echo "→ Building $zig_target → @chaza/$npm_platform"

  if ! zig build -Dtarget="$zig_target" -Doptimize=ReleaseFast 2>&1; then
    echo "  ERROR: build failed"
    FAILED+=("$npm_platform")
    continue
  fi

  pkg_dir="$SCOPE_DIR/$npm_platform"
  mkdir -p "$pkg_dir/bin"

  if [[ "$os" == "win32" ]]; then
    cp zig-out/bin/chaza.exe "$pkg_dir/bin/chaza.exe"
  else
    cp zig-out/bin/chaza "$pkg_dir/bin/chaza"
    chmod +x "$pkg_dir/bin/chaza"
  fi

  cat > "$pkg_dir/package.json" << EOF
{
  "name": "@chaza/$npm_platform",
  "version": "$VERSION",
  "description": "chaza CLI binary for $npm_platform",
  "os": ["$os"],
  "cpu": ["$cpu"],
  "files": ["bin/"]
}
EOF

  echo "  ✓ @chaza/$npm_platform"
done

echo ""
echo "npm packages ready under npm/"
echo ""

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAILED:"
  for t in "${FAILED[@]}"; do echo "  - @chaza/$t"; done
  exit 1
fi
