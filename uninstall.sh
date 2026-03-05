#!/usr/bin/env bash
# uninstall.sh — remove local-whisper from your system
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }

HAMMERSPOON_DIR="$HOME/.hammerspoon"
CONFIG_DIR="$HOME/.local-whisper"
WHISPER_CPP_DIR="$HOME/whisper.cpp"
WHISPER_TMP="${TMPDIR:-/tmp}/whisper-dictate"

echo ""
echo -e "${BOLD}local-whisper uninstaller${NC}"
echo ""
echo "This will remove local-whisper configuration files."
echo "It will NOT uninstall Homebrew packages (ffmpeg, cmake, hammerspoon)."
echo ""
read -r -p "Continue? [y/N] " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY]$ ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# ─── Hammerspoon config ─────────────────────────────────────────────────────
if [[ -f "$HAMMERSPOON_DIR/init.lua" ]] && grep -q "local-whisper" "$HAMMERSPOON_DIR/init.lua"; then
    rm "$HAMMERSPOON_DIR/init.lua"
    ok "Removed ~/.hammerspoon/init.lua"

    if [[ -f "$HAMMERSPOON_DIR/init.lua.backup" ]]; then
        mv "$HAMMERSPOON_DIR/init.lua.backup" "$HAMMERSPOON_DIR/init.lua"
        ok "Restored init.lua.backup"
    fi
else
    info "No local-whisper init.lua found (skipped)"
fi

if [[ -f "$HAMMERSPOON_DIR/local_whisper_actions.lua" ]]; then
    rm "$HAMMERSPOON_DIR/local_whisper_actions.lua"
    ok "Removed ~/.hammerspoon/local_whisper_actions.lua"
fi

# ─── Config directory ────────────────────────────────────────────────────────
if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    ok "Removed ~/.local-whisper/"
fi

# ─── Temp files ──────────────────────────────────────────────────────────────
if [[ -d "$WHISPER_TMP" ]]; then
    rm -rf "$WHISPER_TMP"
    ok "Removed temp files"
fi

# ─── whisper.cpp (optional) ──────────────────────────────────────────────────
echo ""
if [[ -d "$WHISPER_CPP_DIR" ]]; then
    read -r -p "Also remove ~/whisper.cpp (models + build)? This frees ~2 GB. [y/N] " REMOVE_WHISPER
    if [[ "$REMOVE_WHISPER" =~ ^[yY]$ ]]; then
        rm -rf "$WHISPER_CPP_DIR"
        ok "Removed ~/whisper.cpp"
    else
        info "Kept ~/whisper.cpp"
    fi
else
    info "~/whisper.cpp not found (skipped)"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}Uninstall complete.${NC}"
echo ""
echo "To also remove Homebrew packages (optional):"
echo "  brew uninstall --cask hammerspoon"
echo "  brew uninstall ffmpeg cmake"
echo ""
