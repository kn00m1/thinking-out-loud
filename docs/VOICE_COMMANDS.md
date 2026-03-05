# Voice Commands Guide

local-whisper can do more than insert text. With action hooks, you can turn spoken phrases into commands — save notes, launch apps, pipe text through a local LLM, or trigger any Hammerspoon automation.

This guide explains how to create your own voice commands.

## Quick start

1. Copy the example config:

```bash
cp hammerspoon/local_whisper_actions.example.lua ~/.hammerspoon/local_whisper_actions.lua
```

2. Edit `~/.hammerspoon/local_whisper_actions.lua` with your rules
3. The config auto-reloads when you save (or use menu bar > Reload Actions)

## How it works

After whisper transcribes your speech, local-whisper runs your hooks before inserting the text:

```
Speech → whisper → post-processing → beforeInsert → actions[] → insert at cursor → afterInsert
```

At each hook, you can inspect the text, modify it, suppress insertion, or trigger side effects.

## Designing trigger phrases

The key challenge: whisper needs to transcribe your command phrase reliably. Here's what works well and what doesn't.

### Good trigger phrases

- **Start with a distinctive keyword followed by a colon**: "note:", "todo:", "journal:", "search:"
  - Whisper reliably transcribes these because they're common English words
  - The colon acts as a clear separator between command and content
- **Use multi-word prefixes for actions**: "open app", "send to", "save as"
  - Two words are more distinctive than one — less chance of false matches
- **Use words whisper knows well**: common English words, app names, technical terms in your prompt file

### Phrases to avoid

- **Single common words**: "stop", "go", "save" — too likely to match normal dictation
- **Homophones**: "write" vs "right", "male" vs "mail"
- **Mumbled or quiet commands**: whisper may hallucinate or mishear low-volume speech
- **Non-English commands when using English mode**: switch to the right language first

### Tip: add commands to your vocabulary prompt

If whisper keeps mishearing your command word, add it to `~/.local-whisper/prompt`:

```
note, todo, journal, rewrite, open app, search
```

This biases whisper toward recognizing these exact words.

## Writing your first command

Open `~/.hammerspoon/local_whisper_actions.lua`. The file returns a table with three optional hooks:

```lua
return {
    beforeInsert = function(ctx)
        -- runs first, good for simple command matching
    end,

    actions = {
        -- ordered list of pattern-based or conditional actions
    },

    afterInsert = function(ctx)
        -- runs last, good for logging or post-insertion side effects
    end,
}
```

### Example: "remind: call mom at 5pm"

```lua
beforeInsert = function(ctx)
    local reminder = ctx.textLower:match("^remind:%s*(.+)$")
    if reminder then
        local origText = ctx.text:match("^%w+:%s*(.+)$")
        ctx:appendToFile("~/reminders.md", "- " .. (origText or reminder))
        ctx:disableInsert()  -- don't paste "remind: call mom" into the app
        ctx:notify("Reminder saved")
        ctx.handled = true   -- skip remaining actions
        return
    end
end,
```

Key points:
- Match against `ctx.textLower` (case-insensitive) — whisper may or may not capitalize
- Extract content from `ctx.text` (original case) for the actual data
- Call `ctx:disableInsert()` so the command phrase doesn't get typed into your app
- Set `ctx.handled = true` to skip the actions list (short-circuit)

## The context object

Every hook receives a `ctx` object with these fields and methods:

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `ctx.text` | string | Current text (mutable via `ctx:setText()`) |
| `ctx.textLower` | string | Lowercase version (auto-updated by `setText`) |
| `ctx.originalText` | string | Original transcription, never changes |
| `ctx.lang` | string | Language: "en", "pt", or "auto" |
| `ctx.outputMode` | string | "paste" or "type" |
| `ctx.appName` | string | App name at recording start, e.g. "Safari" |
| `ctx.appBundleID` | string | Bundle ID, e.g. "com.apple.Safari" |
| `ctx.insert` | bool | Whether text will be inserted (default: true) |
| `ctx.inserted` | bool | Whether text was actually inserted (set after insertion) |
| `ctx.handled` | bool | Set to true to skip remaining actions |
| `ctx.timestamp` | number | Unix timestamp |

### Methods

| Method | Description |
|--------|-------------|
| `ctx:setText("new text")` | Replace the text (also updates `textLower`) |
| `ctx:disableInsert()` | Suppress text insertion at cursor |
| `ctx:enableInsert()` | Re-enable insertion (if previously disabled) |
| `ctx:appendToFile(path, line)` | Append a line to a file (creates parent dirs, expands `~/`) |
| `ctx:launchApp("Safari")` | Launch or focus a macOS app |
| `ctx:runShell("cmd", input)` | Run a shell command with optional stdin text |
| `ctx:keystroke({"cmd"}, "a")` | Fire a keystroke (modifier table + key) |
| `ctx:notify("message")` | Show a macOS notification |
| `ctx:log("message")` | Write to the whisper-dictate log file |

## Common patterns

### Pattern 1: Route text to a file

Save voice notes, journal entries, or todos to dated files.

```lua
local HOME = os.getenv("HOME")

local function dailyFile(name)
    return string.format("%s/Notes/%s-%s.md", HOME, name, os.date("%Y-%m-%d"))
end

-- In beforeInsert:
local note = ctx.textLower:match("^note:%s*(.+)$")
if note then
    local content = ctx.text:match("^%w+:%s*(.+)$")
    ctx:appendToFile(dailyFile("notes"), "- " .. (content or note))
    ctx:disableInsert()
    ctx:notify("Saved note")
    ctx.handled = true
    return
end
```

Trigger: "note: buy groceries after work"
Result: appends `- buy groceries after work` to `~/Notes/notes-2026-03-05.md`

### Pattern 2: Launch or focus an app

```lua
local function parseOpenAppCommand(text)
    local lower = text:lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    local appName = lower:match("^open%s+app%s+(.+)$")
    if not appName then return nil end
    -- Get original-case version
    local orig = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return orig:sub(#orig - #appName + 1):gsub("[%.%,%!%?;:%s]+$", "")
end

-- In beforeInsert:
local appName = parseOpenAppCommand(ctx.text)
if appName then
    ctx:launchApp(appName)
    ctx:disableInsert()
    ctx.handled = true
    return
end
```

Trigger: "open app Safari" or "open app Visual Studio Code"

### Pattern 3: App-aware behavior

Adjust text based on which app you're dictating into.

```lua
-- In the actions list:
{
    name = "slack-casual",
    when = function(ctx)
        return ctx.appBundleID == "com.tinyspeck.slackmacgap"
    end,
    run = function(ctx)
        -- Remove trailing period (Slack messages don't need them)
        ctx:setText(ctx.text:gsub("%.$", ""))
        -- Lowercase first letter for casual tone
        ctx:setText(ctx.text:gsub("^%u", string.lower))
    end,
},
```

**Finding bundle IDs**: in Hammerspoon console, run:
```lua
hs.application.frontmostApplication():bundleID()
```

Or from Terminal:
```bash
osascript -e 'id of app "Slack"'
```

### Pattern 4: Transform text with a local LLM

Pipe dictation through Ollama or any local command.

```lua
{
    name = "rewrite-professional",
    pattern = "^rewrite:%s*(.+)$",
    run = function(ctx)
        local payload = ctx.text:match("^%w+:%s*(.+)$")
        if not payload then return end
        ctx:notify("Rewriting...")
        local ok, output = ctx:runShell(
            'ollama run llama3.2 "Rewrite this as a professional email. Output only the rewritten text."',
            payload
        )
        if ok and output and output:gsub("%s+", "") ~= "" then
            ctx:setText(output)
        else
            ctx:notify("Rewrite failed; using original")
        end
    end,
},
```

Trigger: "rewrite: hey can you send me that thing we talked about"
Result: inserts a professionally rewritten version

**Note**: `ctx:runShell()` blocks the UI while running. This is fine for fast commands (<1s) but for LLM calls that take several seconds, the overlay will freeze. A future version may add async support.

### Pattern 5: Fire keystrokes

Trigger keyboard shortcuts by voice.

```lua
{
    name = "select-all",
    when = function(ctx) return ctx.textLower:match("^select all%p*$") end,
    run = function(ctx)
        ctx:disableInsert()
        ctx:keystroke({"cmd"}, "a")
        ctx.handled = true
    end,
},
{
    name = "copy-that",
    when = function(ctx) return ctx.textLower:match("^copy that%p*$") end,
    run = function(ctx)
        ctx:disableInsert()
        ctx:keystroke({"cmd"}, "c")
        ctx:notify("Copied")
        ctx.handled = true
    end,
},
```

### Pattern 6: Conditional with the actions list

The `actions` list supports three formats:

```lua
actions = {
    -- 1. Simple function
    function(ctx)
        -- runs unconditionally
    end,

    -- 2. Pattern-based (matches ctx.textLower)
    {
        name = "my-action",
        pattern = "^search:%s*(.+)$",
        run = function(ctx)
            -- runs when pattern matches
        end,
    },

    -- 3. Conditional
    {
        name = "my-other-action",
        when = function(ctx)
            return ctx.lang == "pt" and ctx.textLower:match("^nota:")
        end,
        run = function(ctx)
            -- runs when `when` returns true
        end,
    },
}
```

Actions run in order and stop early if any action sets `ctx.handled = true`.

## Testing your commands

1. **Check the log**: after dictating, check `$TMPDIR/whisper-dictate/whisper-dictate.log`
   ```bash
   tail -20 $TMPDIR/whisper-dictate/whisper-dictate.log
   ```
   Look for `action:` and `actions:` lines to see what fired.

2. **Use ctx:log()**: add `ctx:log("matched: " .. ctx.text)` in your hooks to trace execution.

3. **Test incrementally**: add one command at a time, dictate it, check the log. Lua syntax errors in the config will be logged and the file will be skipped (graceful failure).

4. **Reload after edits**: the config auto-reloads on file save (checks mtime). You can also use the menu bar > Reload Actions.

5. **Test pattern matching in Hammerspoon console**:
   ```lua
   print(("Note: buy coffee"):lower():match("^note:%s*(.+)$"))
   -- prints: buy coffee
   ```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Command not triggering | Check the log for what whisper actually transcribed — it may differ from what you said. Add the command word to your prompt file. |
| Config not loading | Check log for "actions: could not load" errors. Usually a Lua syntax error — look for missing `end`, commas, or quotes. |
| `ctx:runShell()` hangs | The command is blocking. Make sure the shell command exits quickly. For LLMs, set a timeout or use a faster model. |
| Wrong app detected | The app is captured when you **start** recording, not when text is inserted. Make sure the target app is focused before you hold the trigger key. |
| Pattern matches normal speech | Make your trigger phrase more specific. "note:" is better than "note" because the colon prevents false matches on sentences containing "note". |
| `appendToFile` not creating file | Check the path is valid and the directory is writable. Paths starting with `~/` are expanded automatically. |
