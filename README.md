# local-whisper

A fast, fully-local speech-to-text dictation tool for macOS, powered by [whisper.cpp](https://github.com/ggml-org/whisper.cpp). No subscriptions, no cloud — just local transcription optimized for Apple Silicon.

Hold **Right Cmd**, speak, release — text appears at your cursor.

## Features

- **Hold-to-dictate**: Hold a modifier key to record, release to transcribe and insert
- **Live preview**: Streaming overlay shows partial transcription while you speak
- **Recording indicator**: Pulsing red dot and elapsed timer in the overlay
- **Insert at cursor**: Final text is pasted (or typed) into any app on release
- **Multi-language**: English, Portuguese, and auto-detect with preferred language fallback
- **Custom vocabulary**: Provide a prompt file to improve recognition of domain-specific terms
- **Text post-processing**: Auto-capitalize, remove filler words (um, uh, hmm), clean whitespace
- **App-aware processing**: Skips auto-capitalize in terminals and code editors
- **Action hooks**: Route dictation to notes, launch apps, or pipe to local LLM commands
- **Auto-stop on silence**: Automatically stops recording after 3 seconds of silence
- **Undo**: Ctrl+Alt+Z to undo the last dictation
- **Menu bar icon**: Shows recording status, click for quick settings access
- **Fully local**: All processing on-device via whisper.cpp — nothing leaves your machine

## Requirements

- macOS (Apple Silicon recommended — tested on M4)
- [Homebrew](https://brew.sh)

## Install

```bash
git clone https://github.com/luisalima/local-whisper.git
cd local-whisper
./install.sh
```

The installer handles everything: Homebrew dependencies, building whisper.cpp, downloading models, and setting up Hammerspoon. It then runs `setup.sh` which walks you through choosing your trigger key, microphone, and granting permissions.

To change the trigger key or re-run setup later:

```bash
./setup.sh
```

<details>
<summary>Manual install (if you prefer)</summary>

```bash
# 1. Dependencies
brew install ffmpeg cmake git
brew install --cask hammerspoon

# 2. Build whisper.cpp
cd ~
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp
cmake -B build
cmake --build build -j --config Release

# 3. Download model (~1.5 GB)
./models/download-ggml-model.sh medium

# 4. Optional: download tiny model for faster live preview
./models/download-ggml-model.sh tiny

# 5. Copy Hammerspoon config
cp hammerspoon/init.lua ~/.hammerspoon/init.lua
```

</details>

## Uninstall

```bash
./uninstall.sh
```

Removes Hammerspoon config, `~/.local-whisper/` settings, and temp files. Optionally removes `~/whisper.cpp`. Does not uninstall Homebrew packages.

## Setup

### Permissions (System Settings > Privacy & Security)

| App | Permission |
|-----|-----------|
| Hammerspoon | Accessibility, Microphone |
| Terminal (or your terminal app) | Accessibility (for `hs` CLI) |

### Hammerspoon CLI

Open Hammerspoon console and run once:

```lua
hs.ipc.cliInstall()
```

This installs the `hs` command-line tool used for IPC.

### Audio device

Find your microphone device index:

```bash
ffmpeg -f avfoundation -list_devices true -i ""
```

Update `AUDIO_DEVICE` in `~/.hammerspoon/init.lua` if it's not `:1`.

## Hotkeys

| Shortcut | Action |
|----------|--------|
| Hold Right Cmd | Record, transcribe, insert |
| Ctrl+Alt+E | Set language: English |
| Ctrl+Alt+P | Set language: Portuguese |
| Ctrl+Alt+A | Set language: Auto-detect |
| Ctrl+Alt+T | Cycle languages |
| Ctrl+Alt+M | Cycle whisper model |
| Ctrl+Alt+O | Toggle output mode (paste / type) |
| Ctrl+Alt+Return | Toggle enter-after-insert mode |
| Ctrl+Alt+S | Toggle settings overlay |
| Ctrl+Alt+Z | Undo last dictation |
| Ctrl+Alt+R | Reload action hooks config |
| Ctrl+Alt+X | Emergency stop |

## Menu bar

A persistent menu bar icon (🎙) shows recording status (turns red ● when recording). Click it to:

- See current language, model, output mode, enter mode, and preferred languages
- Click any setting to cycle it
- Open the settings overlay
- Reload action hooks
- Emergency stop

## Custom vocabulary prompt

Create `~/.local-whisper/prompt` with terms whisper should recognize better:

```
Claude, Hammerspoon, whisper.cpp, Karabiner, ffmpeg, macOS, Lua, Anthropic
```

This is passed as `--prompt` to whisper-cli for both partial and final transcription.

## Faster live preview

By default, partial transcription uses the same model as final transcription. For faster live preview, download a smaller model:

```bash
cd ~/whisper.cpp/models
./download-ggml-model.sh tiny
```

The system automatically picks the smallest available model (tiny > base > small) for partials while keeping your chosen model for the final transcription.

## App-aware text processing

Post-processing adapts to the frontmost application when you start recording:

- **Terminals** (Terminal, iTerm2, Warp): skips auto-capitalize (commands are lowercase)
- **Code editors** (VS Code, Xcode, Zed, Sublime Text): skips auto-capitalize
- **Everything else**: auto-capitalizes first letter, removes filler words

The active app is also available in action hooks as `ctx.appName` and `ctx.appBundleID`.

## Custom post-dictation actions

You can hook custom logic after transcription to trigger automations, route text to files, launch apps, or pipe to a local LLM.

1. Copy the example file:

```bash
cp hammerspoon/local_whisper_actions.example.lua ~/.hammerspoon/local_whisper_actions.lua
```

2. Edit `~/.hammerspoon/local_whisper_actions.lua` and customize your rules.
3. The config auto-reloads when the file changes (or use Ctrl+Alt+R to force reload).

### Hook context

| Field / Method | Description |
|---------------|-------------|
| `ctx.text` | Current text (mutable via `ctx:setText()`) |
| `ctx.textLower` | Lowercase version for case-insensitive matching |
| `ctx.originalText` | Original transcription (immutable) |
| `ctx.lang` | Language used for transcription |
| `ctx.outputMode` | "paste" or "type" |
| `ctx.appName` | App name where dictation started (e.g. "Safari") |
| `ctx.appBundleID` | Bundle ID (e.g. "com.apple.Safari") |
| `ctx:setText(text)` | Replace text before insertion |
| `ctx:disableInsert()` | Skip cursor insertion (for command-only actions) |
| `ctx:appendToFile(path, line)` | Append a line to a file (creates parent dirs) |
| `ctx:launchApp("Safari")` | Launch or focus an app |
| `ctx:runShell("cmd", input)` | Run a shell command with optional stdin |
| `ctx:keystroke({"cmd"}, "a")` | Fire a keystroke |
| `ctx:notify("msg")` | Show a notification |
| `ctx.handled` | Set to `true` to skip remaining actions |

### Example voice commands

- `note: buy coffee` — append to daily notes file, skip insertion
- `journal: today was productive` — append to daily journal
- `open app Safari` — launch or focus an app
- `todo: call mom` — append to daily tasks file

Patterns in `actions[].pattern` match against `ctx.textLower` (case-insensitive), so "Note: Buy coffee" matches `^note:`.

For a full guide on designing trigger phrases, writing custom commands, and testing — see **[docs/VOICE_COMMANDS.md](docs/VOICE_COMMANDS.md)**.

## How it works

```
Modifier key hold/release (detected by Hammerspoon eventtap)
  → ffmpeg records chunked WAV segments (1s each)
  → Partial transcription loop: concat latest chunks → whisper-cli (tiny model)
  → On release: concat all chunks → final whisper-cli transcription (chosen model)
  → Post-processing: remove fillers, capitalize, app-aware adjustments
  → Action hooks: beforeInsert → actions → text insertion → afterInsert
  → Text inserted at cursor via paste (Cmd+V) or keystroke
```

## Auto-stop on silence

Recording automatically stops after 3 consecutive seconds of silence (< -40 dB). This is useful for hands-free dictation. Configure thresholds in `init.lua`:

```lua
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40
```

## Troubleshooting

- **No transcription output**: Check `$TMPDIR/whisper-dictate/whisper-dictate.log` for errors (run `echo $TMPDIR` to find the path)
- **Wrong microphone**: Run `ffmpeg -f avfoundation -list_devices true -i ""` and update `AUDIO_DEVICE` in init.lua
- **`hs` command not found**: Run `hs.ipc.cliInstall()` in Hammerspoon console
- **Permissions errors**: Ensure Hammerspoon has Accessibility and Microphone permissions in System Settings
- **Action hooks not loading**: Check the log file for "actions:" messages. Ensure `~/.hammerspoon/local_whisper_actions.lua` returns a table.
- **Overlay not appearing**: Hammerspoon may need Accessibility permission re-granted after updates

## Disclaimer

This project was **vibe-coded** — built quickly with AI assistance for personal use. It works on my machine (M4 MacBook Pro), it might work on yours. PRs and issues welcome.

## License

[MIT](LICENSE)
