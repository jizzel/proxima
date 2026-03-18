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
    # Single ARM64 binary; runs natively on Apple Silicon, via Rosetta 2 on Intel.
    ASSET="proxima-macos-arm64"
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
  USE_CURL=1
elif command -v wget &>/dev/null; then
  USE_CURL=0
else
  echo "curl or wget is required" >&2; exit 1
fi

fetch() {
  if [ "$USE_CURL" -eq 1 ]; then
    curl -fsSL "$1" ${2:+-o "$2"}
  else
    if [ -n "${2:-}" ]; then
      wget -qO "$2" "$1"
    else
      wget -qO- "$1"
    fi
  fi
}

LATEST_TAG=$(
  fetch "https://api.github.com/repos/$REPO/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p'
)

if [ -z "$LATEST_TAG" ]; then
  echo "Could not determine latest release tag" >&2; exit 1
fi

DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_TAG/$ASSET"

# ── Download and install ──────────────────────────────────────────────────────

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

echo "Installing Proxima $LATEST_TAG ($ASSET) → $INSTALL_DIR/$BINARY_NAME"

fetch "$DOWNLOAD_URL" "$TMP"

chmod +x "$TMP"

# Use sudo only if install dir isn't writable by current user.
if [ -w "$INSTALL_DIR" ]; then
  mv "$TMP" "$INSTALL_DIR/$BINARY_NAME"
else
  echo "  (requires sudo to write to $INSTALL_DIR)"
  sudo mv "$TMP" "$INSTALL_DIR/$BINARY_NAME"
fi

echo "Done. Run: proxima --version"
