-- Copy to: ~/.hammerspoon/local_whisper_actions.lua
-- Voice commands for local-whisper dictation.
-- All commands start with "voice command" to prevent false matches on normal speech.
--
-- Hooks:
--   beforeInsert(ctx)  -> runs before text insertion
--   actions = { ... }  -> ordered list of actions
--   afterInsert(ctx)   -> runs after insertion
--
-- Context fields:
--   ctx.text, ctx.textLower, ctx.originalText
--   ctx.lang, ctx.outputMode
--   ctx.appName, ctx.appBundleID   -- app that was focused when recording started
--   ctx.insert, ctx.inserted, ctx.handled
--   ctx.timestamp, ctx.isoTime     -- when the dictation was recorded
--
-- Context methods:
--   ctx:setText("new text")
--   ctx:disableInsert(), ctx:enableInsert()
--   ctx:launchApp("Safari")
--   ctx:appendToFile(path, line)
--   ctx:runShell("command", optionalInputText)
--   ctx:keystroke({"cmd"}, "a")      -- fire a keystroke
--   ctx:notify("message"), ctx:log("message")
--
-- Patterns match against ctx.textLower (case-insensitive).
-- Set ctx.handled = true in any hook to skip remaining actions.
-- Config auto-reloads when the file changes.

local HOME = os.getenv("HOME")

return {
    beforeInsert = function(ctx)

        -- "voice command cancel/abort" — can appear anywhere in the text
        local stripped = ctx.textLower:gsub("[%.%,%!%?]+$", "")
        if stripped:match("voice%s+command%s+cancel%s*$")
            or stripped:match("voice%s+command%s+abort%s*$") then
            ctx:disableInsert()
            ctx:notify("Dictation discarded")
            ctx.handled = true
            return
        end

        -- All other commands require "voice command" at the start
        local action = stripped:match("^voice%s+command%s+(.+)$")
        if not action then return end

        -- "voice command note <anything>" — save to ~/whisper_notes.md
        local note = action:match("^note[%s%p]+(.+)$")
        if note then
            local origStripped = ctx.text:gsub("[%.%,%!%?]+$", "")
            local content = origStripped:match("%w+%s+%w+%s+%w+[%s%p]+(.+)$") or note
            ctx:appendToFile(HOME .. "/whisper_notes.md", "- " .. content)
            ctx:disableInsert()
            ctx:notify("Note saved: " .. content)
            ctx.handled = true
            return
        end

        -- "voice command remind <anything>" — create a macOS Reminder
        local reminder = action:match("^remind[%s%p]+(.+)$")
            or action:match("^reminder[%s%p]+(.+)$")
        if reminder then
            local origStripped = ctx.text:gsub("[%.%,%!%?]+$", "")
            local content = origStripped:match("%w+%s+%w+%s+%w+[%s%p]+(.+)$") or reminder
            local script = string.format(
                'tell application "Reminders" to make new reminder with properties {name:"%s"}',
                content:gsub('"', '\\"')
            )
            ctx:runShell("osascript -e '" .. script:gsub("'", "'\\''") .. "'")
            ctx:launchApp("Reminders")
            ctx:disableInsert()
            ctx:notify("Reminder added: " .. content)
            ctx.handled = true
            return
        end

        -- "voice command open app <name>" — launch or focus an app
        local app = action:match("^open%s+app%s+(.+)$")
        if app then
            local origStripped = ctx.text:gsub("[%.%,%!%?]+$", "")
            local origApp = origStripped:match("%w+%s+%w+%s+%w+%s+%w+%s+(.+)$") or app
            origApp = origApp:gsub("[%s]+$", "")
            ctx:launchApp(origApp)
            ctx:disableInsert()
            ctx.handled = true
            return
        end

        -- "voice command select all" — Cmd+A
        if action == "select all" then
            ctx:disableInsert()
            ctx:keystroke({"cmd"}, "a")
            ctx.handled = true
            return
        end

        -- "voice command copy" — Cmd+C
        if action == "copy" or action == "copy that" then
            ctx:disableInsert()
            ctx:keystroke({"cmd"}, "c")
            ctx:notify("Copied")
            ctx.handled = true
            return
        end

        -- "voice command paste" — Cmd+V
        if action == "paste" or action == "paste that" then
            ctx:disableInsert()
            ctx:keystroke({"cmd"}, "v")
            ctx.handled = true
            return
        end

        -- "voice command undo" — Cmd+Z
        if action == "undo" then
            ctx:disableInsert()
            ctx:keystroke({"cmd"}, "z")
            ctx.handled = true
            return
        end

    end,

    actions = {},

    afterInsert = function(ctx)
        if ctx.inserted then
            ctx:log("inserted [" .. (ctx.appName or "?") .. "]: " .. ctx.text)
        elseif ctx.handled then
            ctx:log("command [" .. (ctx.appName or "?") .. "]: " .. ctx.originalText)
        end
    end,
}
