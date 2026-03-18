#!/usr/bin/env bash
# Proxima install script
# Usage: curl -fsSL https://raw.githubusercontent.com/jizzel/proxima/main/install.sh | sh
set -euo pipefail

REPO="jizzel/proxima"
INSTALL_DIR="${PROXIMA_INSTALL_DIR:-/usr/local/bin}"
BINARY_NAME="proxima"

# ── Detect platform ───────────────────────────────────────────────────────────

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
  Darwin)
    case "$ARCH" in
      arm64)  ASSET="proxima-macos-arm64" ;;
      x86_64) ASSET="proxima-macos-x64"   ;;
      *)      echo "Unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
    esac
    ;;
  Linux)
    case "$ARCH" in
      x86_64) ASSET="proxima-linux-x64" ;;
      *)      echo "Unsupported Linux architecture: $ARCH" >&2; exit 1 ;;
    esac
    ;;
  *)
    echo "Unsupported OS: $OS" >&2
    echo "For Windows, download a binary from https://github.com/$REPO/releases" >&2
    exit 1
    ;;
esac

# ── Resolve latest release tag ────────────────────────────────────────────────

if command -v curl &>/dev/null; then
  FETCH="curl -fsSL"
elif command -v wget &>/dev/null; then
  FETCH="wget -qO-"
else
  echo "curl or wget is required" >&2; exit 1
fi

LATEST_TAG=$(
  $FETCH "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"tag_name"' \
  | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
)

if [ -z "$LATEST_TAG" ]; then
  echo "Could not determine latest release tag" >&2; exit 1
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$ASSET"

# ── Download and install ──────────────────────────────────────────────────────

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "Installing Proxima $LATEST_TAG ($ASSET) → $INSTALL_DIR/$BINARY_NAME"

$FETCH "$DOWNLOAD_URL" -o "$TMP" 2>/dev/null || {
  # wget variant doesn't support -o
  $FETCH "$DOWNLOAD_URL" > "$TMP"
}

chmod +x "$TMP"

# Use sudo only if install dir isn't writable by current user.
if [ -w "$INSTALL_DIR" ]; then
  mv "$TMP" "$INSTALL_DIR/$BINARY_NAME"
else
  echo "  (requires sudo to write to $INSTALL_DIR)"
  sudo mv "$TMP" "$INSTALL_DIR/$BINARY_NAME"
fi

echo "Done. Run: proxima --version"
