#!/bin/sh
# chaza installer — curl -fsSL <url> | sh
set -eu

GITHUB_REPO="taggon/chaza"
INSTALL_DIR="${CHAZA_INSTALL_DIR:-$HOME/.chaza/bin}"

# ── Platform detection ──

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin) os="darwin" ;;
  Linux)  os="linux"  ;;
  *) printf 'Unsupported OS: %s\n' "$OS" >&2; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64) arch="x64"   ;;
  arm64|aarch64) arch="arm64" ;;
  *) printf 'Unsupported arch: %s\n' "$ARCH" >&2; exit 1 ;;
esac

TARGET="${os}-${arch}"

# ── Resolve latest version ──

printf 'Detecting latest version...\n'
VERSION="$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" \
  | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)"

if [ -z "$VERSION" ]; then
  printf 'Could not determine latest version.\n' >&2
  exit 1
fi

printf 'Latest version: %s\n' "$VERSION"

# ── Download ──

URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/chaza-${TARGET}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

printf 'Downloading %s...\n' "$URL"
curl -fsSL -o "$TMPDIR/chaza" "$URL"
chmod +x "$TMPDIR/chaza"

# ── Install ──

mkdir -p "$INSTALL_DIR"
mv "$TMPDIR/chaza" "$INSTALL_DIR/chaza"

printf '\n'
printf 'Installed to %s/chaza\n' "$INSTALL_DIR"
printf '\n'

# ── PATH check ──

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    printf 'Add chaza to your PATH:\n'
    printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
    printf '\n'
    # .zshrc / .bashrc hint
    SHELL_NAME="$(basename "$SHELL" 2>/dev/null || echo sh)"
    case "$SHELL_NAME" in
      zsh)  rc="$HOME/.zshrc" ;;
      bash) rc="$HOME/.bashrc" ;;
      *)    rc="" ;;
    esac
    if [ -n "$rc" ] && [ -f "$rc" ] && ! grep -q "$INSTALL_DIR" "$rc" 2>/dev/null; then
      printf 'Add this line to %s:\n' "$rc"
      printf '  export PATH="%s:$PATH"\n' "$INSTALL_DIR"
    fi
    ;;
esac

printf 'Run "chaza --help" to get started.\n'
