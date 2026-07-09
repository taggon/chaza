#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(node -p "require('./npm/chaza/package.json').version")
DESCRIPTION=$(node -p "require('./npm/chaza/package.json').description")
KEYWORDS=$(node -p "JSON.stringify(require('./npm/chaza/package.json').keywords)")
ROOT="$(pwd)"

# zig target → npm platform-arch
TARGETS=(
  "aarch64-macos:darwin-arm64"
  "x86_64-macos:darwin-x64"
  "aarch64-linux:linux-arm64"
  "x86_64-linux:linux-x64"
  "aarch64-windows:win32-arm64"
  "x86_64-windows:win32-x64"
)

NPM_DIR="$ROOT/npm"
SCOPE_DIR="$NPM_DIR/@chaza-cli"

rm -rf "$SCOPE_DIR"
mkdir -p "$SCOPE_DIR"

# Compile TypeScript loader
echo "→ Compiling TypeScript..."
(cd "$NPM_DIR/chaza" && npm run build)

# Copy LICENSE to npm root
cp "$ROOT/LICENSE" "$NPM_DIR/chaza/LICENSE"

FAILED=()

for entry in "${TARGETS[@]}"; do
  zig_target="${entry%%:*}"
  npm_platform="${entry##*:}"
  os="${npm_platform%%-*}"
  cpu="${npm_platform##*-}"

  echo "→ Building $zig_target → @chaza-cli/$npm_platform"

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

  # Copy LICENSE to a platform-specific package
  cp "$ROOT/LICENSE" "$pkg_dir/LICENSE"

  cat > "$pkg_dir/package.json" << EOF
{
  "name": "@chaza-cli/$npm_platform",
  "version": "$VERSION",
  "description": "$DESCRIPTION",
  "os": ["$os"],
  "cpu": ["$cpu"],
  "files": ["bin/"],
  "keywords": $KEYWORDS
}
EOF

  cat > "$pkg_dir/README.md" << EOF
# @chaza-cli/$npm_platform

This package provides $npm_platform for [chaza](https://npmjs.com/package/chaza).
EOF

  echo "  ✓ @chaza-cli/$npm_platform"
done

echo ""
echo "npm packages ready under npm/"
echo ""

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "FAILED:"
  for t in "${FAILED[@]}"; do echo "  - @chaza-cli/$t"; done
  exit 1
fi
