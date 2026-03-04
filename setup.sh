#!/usr/bin/env bash
# setup.sh — post-install setup for local-whisper
# Automates: permissions prompts, Hammerspoon CLI, Karabiner rule activation, shortcut config
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
error() { echo -e "${RED}[x]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KARABINER_CONFIG="$HOME/.config/karabiner/karabiner.json"
KARABINER_RULES_DIR="$HOME/.config/karabiner/assets/complex_modifications"

echo ""
echo -e "${BOLD}local-whisper setup${NC}"
echo ""

# ─── Step 1: Choose trigger key ─────────────────────────────────────────────
echo -e "${BOLD}Step 1: Choose your dictation trigger key${NC}"
echo ""
echo "  1) right_option  (default — Right Option / Right Alt)"
echo "  2) right_command  (Right Command)"
echo "  3) right_control  (Right Control)"
echo "  4) fn             (Globe / Fn key)"
echo ""
read -r -p "Choice [1]: " KEY_CHOICE
KEY_CHOICE="${KEY_CHOICE:-1}"

case "$KEY_CHOICE" in
    1) TRIGGER_KEY="right_option";  TRIGGER_LABEL="Right Option" ;;
    2) TRIGGER_KEY="right_command"; TRIGGER_LABEL="Right Command" ;;
    3) TRIGGER_KEY="right_control"; TRIGGER_LABEL="Right Control" ;;
    4) TRIGGER_KEY="fn";            TRIGGER_LABEL="Fn / Globe" ;;
    *) TRIGGER_KEY="right_option";  TRIGGER_LABEL="Right Option" ;;
esac

ok "Trigger key: $TRIGGER_LABEL ($TRIGGER_KEY)"

# Generate Karabiner rule with chosen key
RULE_FILE="$KARABINER_RULES_DIR/local-whisper.json"
mkdir -p "$KARABINER_RULES_DIR"
cat > "$RULE_FILE" << JSONEOF
{
    "title": "local-whisper: ${TRIGGER_LABEL} hold-to-dictate",
    "rules": [
        {
            "description": "${TRIGGER_LABEL}: hold = record + transcribe, tap = normal ${TRIGGER_KEY}",
            "manipulators": [
                {
                    "type": "basic",
                    "from": {
                        "key_code": "${TRIGGER_KEY}",
                        "modifiers": {
                            "optional": ["any"]
                        }
                    },
                    "to": [
                        {
                            "shell_command": "/bin/bash -lc \"${HOME}/whisper-dictate/start_record.sh >> ${HOME}/whisper-dictate.log 2>&1\""
                        }
                    ],
                    "to_if_alone": [
                        {
                            "key_code": "${TRIGGER_KEY}"
                        }
                    ],
                    "to_after_key_up": [
                        {
                            "shell_command": "/bin/bash -lc \"${HOME}/whisper-dictate/stop_transcribe.sh >> ${HOME}/whisper-dictate.log 2>&1\""
                        }
                    ],
                    "parameters": {
                        "basic.to_if_alone_timeout_milliseconds": 200
                    }
                }
            ]
        }
    ]
}
JSONEOF
ok "Karabiner rule written to $RULE_FILE"

# ─── Step 2: Activate rule in karabiner.json ─────────────────────────────────
echo ""
echo -e "${BOLD}Step 2: Activating Karabiner rule${NC}"

# Launch Karabiner if not running (it creates karabiner.json on first launch)
if ! pgrep -q "karabiner_console" && ! pgrep -q "Karabiner-Elements" && ! pgrep -q "karabiner_grabber"; then
    info "Launching Karabiner-Elements..."
    open -a "Karabiner-Elements"
    sleep 3
fi

# Wait for karabiner.json to exist (Karabiner creates it on first launch)
WAIT_COUNT=0
while [[ ! -f "$KARABINER_CONFIG" ]] && [[ $WAIT_COUNT -lt 10 ]]; do
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [[ -f "$KARABINER_CONFIG" ]]; then
    # Check if our rule is already in the active profile
    if python3 -c "
import json, sys
with open('$KARABINER_CONFIG') as f:
    cfg = json.load(f)
for p in cfg.get('profiles', []):
    if p.get('selected'):
        for r in p.get('complex_modifications', {}).get('rules', []):
            if 'local-whisper' in r.get('description', ''):
                sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        ok "Rule already active in Karabiner profile"
    else
        # Add the rule to the selected profile
        python3 -c "
import json
with open('$KARABINER_CONFIG') as f:
    cfg = json.load(f)
with open('$RULE_FILE') as f:
    rule_data = json.load(f)
for p in cfg.get('profiles', []):
    if p.get('selected'):
        if 'complex_modifications' not in p:
            p['complex_modifications'] = {'rules': []}
        if 'rules' not in p['complex_modifications']:
            p['complex_modifications']['rules'] = []
        p['complex_modifications']['rules'].extend(rule_data['rules'])
        break
with open('$KARABINER_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=4)
" 2>/dev/null && ok "Rule activated in Karabiner profile" || warn "Could not auto-activate rule — enable it manually in Karabiner > Complex Modifications"
    fi
else
    warn "karabiner.json not found — open Karabiner-Elements, then run this script again"
fi

# ─── Step 3: Permissions ────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 3: macOS permissions${NC}"
echo ""

# Find hs binary for accessibility check
HS_CHECK=""
if [[ -x "/usr/local/bin/hs" ]]; then
    HS_CHECK="/usr/local/bin/hs"
elif [[ -x "/opt/homebrew/bin/hs" ]]; then
    HS_CHECK="/opt/homebrew/bin/hs"
fi

FFMPEG_BIN="$(brew --prefix)/bin/ffmpeg"
ALL_OK=true

# ── Input Monitoring (Karabiner) ──
if pgrep -q karabiner_grabber 2>/dev/null; then
    ok "Input Monitoring: granted (karabiner_grabber running)"
else
    ALL_OK=false
    warn "Input Monitoring: not yet granted"
    echo -e "  Enable ${BOLD}karabiner_grabber${NC} and ${BOLD}karabiner_observer${NC}"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" 2>/dev/null || true
    read -r -p "  Press Enter when done..."

    # Re-check
    if pgrep -q karabiner_grabber 2>/dev/null; then
        ok "Input Monitoring: granted"
    else
        warn "Input Monitoring: still not detected — Karabiner may need a restart"
    fi
fi

# ── Accessibility (Hammerspoon) ──
if [[ -n "$HS_CHECK" ]] && "$HS_CHECK" -c "return hs.accessibilityState()" 2>/dev/null | grep -q "true"; then
    ok "Accessibility: granted (Hammerspoon)"
else
    ALL_OK=false
    warn "Accessibility: not yet granted"
    echo -e "  Enable ${BOLD}Hammerspoon${NC}"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
    read -r -p "  Press Enter when done..."

    # Re-check
    if [[ -n "$HS_CHECK" ]] && "$HS_CHECK" -c "return hs.accessibilityState()" 2>/dev/null | grep -q "true"; then
        ok "Accessibility: granted"
    else
        warn "Accessibility: could not verify — make sure Hammerspoon is enabled"
    fi
fi

# ── Microphone (Terminal) ──
if "$FFMPEG_BIN" -f avfoundation -i ":default" -t 0.1 -f null - 2>/dev/null; then
    ok "Microphone: granted"
else
    ALL_OK=false
    warn "Microphone: not yet granted"
    echo -e "  Enable your ${BOLD}terminal app${NC} (Terminal, iTerm2, etc.)"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone" 2>/dev/null || true
    read -r -p "  Press Enter when done..."

    # Re-check
    if "$FFMPEG_BIN" -f avfoundation -i ":default" -t 0.1 -f null - 2>/dev/null; then
        ok "Microphone: granted"
    else
        warn "Microphone: could not verify — you may need to restart your terminal"
    fi
fi

if [[ "$ALL_OK" == true ]]; then
    ok "All permissions already granted"
fi

# ─── Step 4: Hammerspoon CLI ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Step 4: Hammerspoon CLI${NC}"

# Launch Hammerspoon if not running
if ! pgrep -q Hammerspoon; then
    info "Launching Hammerspoon..."
    open -a "Hammerspoon"
    sleep 2
fi

if [[ -x "/usr/local/bin/hs" ]]; then
    ok "Hammerspoon CLI already installed"
elif [[ -x "/opt/homebrew/bin/hs" ]]; then
    ok "Hammerspoon CLI already installed (homebrew path)"
else
    warn "Hammerspoon CLI (hs) not found."
    echo ""
    echo -e "  Open the Hammerspoon console (click menu bar icon > Console) and run:"
    echo ""
    echo -e "    ${BOLD}hs.ipc.cliInstall()${NC}"
    echo ""
    read -r -p "  Press Enter when done..."

    # Verify
    if [[ -x "/usr/local/bin/hs" ]] || [[ -x "/opt/homebrew/bin/hs" ]]; then
        ok "Hammerspoon CLI installed"
    else
        warn "hs not found — scripts won't be able to signal the overlay"
        warn "You can run hs.ipc.cliInstall() later from the Hammerspoon console"
    fi
fi

# Reload Hammerspoon config
HS_BIN=""
if [[ -x "/usr/local/bin/hs" ]]; then
    HS_BIN="/usr/local/bin/hs"
elif [[ -x "/opt/homebrew/bin/hs" ]]; then
    HS_BIN="/opt/homebrew/bin/hs"
fi

if [[ -n "$HS_BIN" ]]; then
    "$HS_BIN" -c "hs.reload()" 2>/dev/null && ok "Hammerspoon config reloaded" || warn "Could not reload — click the Hammerspoon menu bar icon > Reload Config"
else
    warn "Reload Hammerspoon manually: menu bar icon > Reload Config"
fi

# ─── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}────────────────────────────────────────────────${NC}"
echo -e "${GREEN}${BOLD}Setup complete!${NC}"
echo -e "${BOLD}────────────────────────────────────────────────${NC}"
echo ""
echo -e "Hold ${BOLD}${TRIGGER_LABEL}${NC}, speak, and release."
echo ""
echo -e "Hotkeys:"
echo "  Ctrl+Alt+E/P/A  — set language (en / pt / auto)"
echo "  Ctrl+Alt+T      — cycle languages"
echo "  Ctrl+Alt+O      — toggle paste / type mode"
echo ""
echo -e "To change the trigger key later, run: ${BOLD}./setup.sh${NC}"
echo ""
