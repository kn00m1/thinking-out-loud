-- Copy to: ~/.hammerspoon/local_whisper_actions.lua
-- Optional hooks for local-whisper dictation output.
--
-- Hooks:
--   beforeInsert(ctx)  -> runs once before default insertion
--   actions = { ... }  -> ordered list of actions (function or {name, when|pattern, run})
--   afterInsert(ctx)   -> runs after default insertion (or after insert is skipped)
--
-- Context helpers:
--   ctx.text, ctx.originalText, ctx.lang, ctx.outputMode
--   ctx:appendToFile(path, line)
--   ctx:launchApp("Safari")
--   ctx:runShell("ollama run ...", optionalInputText)
--   ctx:setText("new text"), ctx:disableInsert(), ctx:enableInsert()
--   ctx:notify("message"), ctx:log("message")

local HOME = os.getenv("HOME")
local NOTES_ROOT = HOME .. "/Notes/dictation"

local function dailyFile(name)
    return string.format("%s/%s-%s.md", NOTES_ROOT, name, os.date("%Y-%m-%d"))
end

return {
    beforeInsert = function(ctx)
        local note = ctx.text:match("^note:%s*(.+)$")
        if note then
            ctx:appendToFile(dailyFile("notes"), "- " .. note)
            ctx:disableInsert()
            ctx:notify("Saved note")
            return
        end

        local journal = ctx.text:match("^journal:%s*(.+)$")
        if journal then
            ctx:appendToFile(dailyFile("journal"), journal)
            ctx:disableInsert()
            ctx:notify("Saved journal entry")
            return
        end

        local appName = ctx.text:match("^open%s+(.+)$")
        if appName then
            ctx:launchApp(appName)
            ctx:disableInsert()
            return
        end
    end,

    actions = {
        {
            name = "todo-to-file",
            pattern = "^todo:%s*(.+)$",
            run = function(ctx)
                local task = ctx.text:match("^todo:%s*(.+)$")
                if task then
                    ctx:appendToFile(dailyFile("tasks"), "- [ ] " .. task)
                    ctx:disableInsert()
                end
            end,
        },
        {
            name = "optional-local-llm-rewrite",
            when = function(ctx)
                return ctx.text:match("^rewrite:%s*(.+)$") ~= nil
            end,
            run = function(ctx)
                local payload = ctx.text:match("^rewrite:%s*(.+)$")
                if not payload then return end

                -- Example with local ollama CLI; replace with your local command.
                local ok, output = ctx:runShell(
                    "ollama run llama3.2 \"Rewrite the input as a concise professional email.\"",
                    payload
                )
                if ok and output and output:gsub("%s+", "") ~= "" then
                    ctx:setText(output)
                else
                    ctx:notify("Rewrite hook failed; using original text")
                end
            end,
        },
    },

    afterInsert = function(ctx)
        if ctx.inserted then
            ctx:log("inserted text: " .. ctx.text)
        end
    end,
}
