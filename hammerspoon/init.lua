-- init.lua — Thinking Out Loud (fork of local-whisper): Hammerspoon-only dictation
-- Hold a modifier key → record → transcribe → insert at cursor
-- No Karabiner needed. Just Hammerspoon + ffmpeg + whisper.cpp

require("hs.ipc")

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

local HOME = os.getenv("HOME")
local TMPDIR = os.getenv("TMPDIR") or "/tmp"
local WHISPER_TMP = TMPDIR .. "/whisper-dictate"
local CHUNK_DIR = WHISPER_TMP .. "/chunks"

-- Config directory (all user settings live here)
local CONFIG_DIR = HOME .. "/.thinking-out-loud"
os.execute("mkdir -p '" .. CONFIG_DIR .. "'")

-- External binaries (absolute paths, with ARM/Intel fallback)
local FFMPEG = hs.fs.attributes("/opt/homebrew/bin/ffmpeg") and "/opt/homebrew/bin/ffmpeg" or "/usr/local/bin/ffmpeg"
local WHISPER_BIN = HOME .. "/whisper.cpp/build/bin/whisper-cli"
local MODELS_DIR = HOME .. "/whisper.cpp/models"

-- All user/app file paths live in a single table so the main chunk stays well
-- under Lua's 200-local ceiling. One module-local (`P`) replaces ~18 separate
-- `*_FILE` / `*_PATH` declarations that used to sit at chunk scope.
local P = {
    -- User preferences (all in ~/.thinking-out-loud/)
    modelFile           = CONFIG_DIR .. "/model",
    langFile            = CONFIG_DIR .. "/lang",
    outputFile          = CONFIG_DIR .. "/output",
    preferredLangsFile  = CONFIG_DIR .. "/preferred_langs",
    enterFile           = CONFIG_DIR .. "/enter",
    promptFile          = CONFIG_DIR .. "/prompt",
    recentFile          = CONFIG_DIR .. "/recent.json",
    historyFile         = CONFIG_DIR .. "/history.json",
    audioDeviceFile     = CONFIG_DIR .. "/audio_device",
    themeFile           = CONFIG_DIR .. "/theme",
    -- LLM refinement
    refineFile          = CONFIG_DIR .. "/refine",
    refinePromptFile    = CONFIG_DIR .. "/refine_prompt",
    refineModelFile     = CONFIG_DIR .. "/refine_model",
    refinePreamblesFile = CONFIG_DIR .. "/refine_preambles.json",
    -- System paths (outside CONFIG_DIR)
    logFile             = WHISPER_TMP .. "/whisper-dictate.log",
    actionsFile         = HOME .. "/.hammerspoon/local_whisper_actions.lua",
    overlayHtml         = HOME .. "/.hammerspoon/overlay.html",
    dashboardHtml       = HOME .. "/.hammerspoon/dashboard.html",
}

-- Scan available models
local function getAvailableModels()
    local models = {}
    local ok, iter, dir = pcall(hs.fs.dir, MODELS_DIR)
    if not ok then return models end
    for file in iter, dir do
        local name = file:match("^ggml%-(.+)%.bin$")
        if name then table.insert(models, name) end
    end
    table.sort(models)
    return models
end

-- Get/set active model
local function getModelName()
    local saved = ""
    local f = io.open(P.modelFile, "r")
    if f then saved = f:read("*a"):gsub("%s+", ""); f:close() end
    if saved ~= "" then
        -- Verify model file exists
        local path = MODELS_DIR .. "/ggml-" .. saved .. ".bin"
        local attr = hs.fs.attributes(path)
        if attr then return saved end
    end
    return "medium"  -- default
end

local function getModelPath()
    return MODELS_DIR .. "/ggml-" .. getModelName() .. ".bin"
end

-- Audio device: ":default" for system default, ":0", ":1" etc. for specific
-- Note: avfoundation requires colon prefix for audio-only (":0" not "0")
-- Primary source of truth is ~/.thinking-out-loud/audio_device (set via menu bar);
-- this literal is the install-time default used on first run.
local AUDIO_DEVICE = ":default"

do
    local f = io.open(CONFIG_DIR .. "/audio_device", "r")
    if f then
        local v = f:read("*a"):gsub("%s+", ""); f:close()
        if v ~= "" then AUDIO_DEVICE = v end
    end
end

-- Auto-fix missing colon prefix (common setup mistake)
if AUDIO_DEVICE ~= ":default" and not AUDIO_DEVICE:match("^:") then
    AUDIO_DEVICE = ":" .. AUDIO_DEVICE
end

-- Trigger key: "rightAlt", "rightCmd", "rightCtrl"
local TRIGGER_KEY = "rightCtrl"

-- (File paths consolidated into the `P` table above.)

-- Auto-stop on silence
local AUTO_STOP_SILENCE_SECONDS = 3
local AUTO_STOP_THRESHOLD_DB = -40

-- LLM refinement (requires Ollama)
local REFINE_DEFAULT_MODEL = "gemma3:4b"
local REFINE_MIN_CHARS = 50  -- skip refinement for short text
-- Refine timeout scales with input length. Qwen 2.5 3B on M4 runs ~50 tok/s;
-- a paragraph-length output needs several seconds. Too-tight timeout causes
-- long dictations to silently fall back to raw text.
local REFINE_TIMEOUT_BASE = 4.0     -- seconds baseline (cold + short text)
local REFINE_TIMEOUT_PER_CHAR = 0.03  -- +30ms per input char
local REFINE_TIMEOUT_MAX = 20.0     -- hard ceiling for very long dictations
local function refineTimeoutFor(text)
    local t = REFINE_TIMEOUT_BASE + #text * REFINE_TIMEOUT_PER_CHAR
    if t > REFINE_TIMEOUT_MAX then t = REFINE_TIMEOUT_MAX end
    return t
end
local REFINE_WARM_INTERVAL = 60  -- seconds between warm-keeper pings
local REFINE_WARM_KEEP_ALIVE = "10m"  -- Ollama keep_alive window
local REFINE_DEFAULT_PROMPT = [[You are a text cleanup tool. Output ONLY the cleaned text, nothing else.

Rules:
- Fix punctuation and capitalization.
- Remove filler words: um, uh, you know, I mean.
- Keep every sentence. Do not drop content.
- Do not add commentary or preambles like "Here is" or "Sure".

Numbered list rule (follow exactly):
- DEFAULT: output flowing sentences with NO numbering (no "1.", "2.", "3.").
- ONLY add numbered list formatting if the input literally contains the words "first", "second", "third" (or "one", "two", "three") used as enumeration markers.
- Example A (NO numbering): "Checking it now. It is coming. I do not like it." → "Checking it now. It is coming. I do not like it."
- Example B (USE numbering): "First, buy milk. Second, eat bread. Third, sleep." → "1. Buy milk.\n2. Eat bread.\n3. Sleep."
- If unsure, DO NOT number.]]

-- Fallback preamble patterns used when P.refinePreamblesFile is missing/invalid.
local REFINE_DEFAULT_PREAMBLES = {
    "^[Hh]ere%s+is%s+the%s+cleaned%s+text:%s*\n?",
    "^[Hh]ere'?s?%s+the%s+cleaned[%-]?%s*text:%s*\n?",
    "^[Hh]ere%s+is%s+the%s+refined%s+text:%s*\n?",
    "^[Ss]ure[,!]?%s*[Hh]?e?r?e?'?s?%s*t?h?e?%s*",
}

local function getRefineModel()
    local f = io.open(P.refineModelFile, "r")
    if f then
        local val = f:read("*a"):gsub("%s+", ""); f:close()
        if val ~= "" then return val end
    end
    return REFINE_DEFAULT_MODEL
end

local function getRefinePrompt()
    local f = io.open(P.refinePromptFile, "r")
    if f then
        local content = f:read("*a"); f:close()
        content = content:gsub("^%s+", ""):gsub("%s+$", "")
        if content ~= "" then return content end
    end
    return REFINE_DEFAULT_PROMPT
end

local function hasOllama()
    -- Check if Ollama API is reachable
    local ok = os.execute("curl -s -o /dev/null -w '' http://localhost:11434/api/tags 2>/dev/null")
    if ok then return true end
    -- Fallback: check if binary exists
    return os.execute("command -v ollama >/dev/null 2>&1")
end

local function getRefineMode()
    local f = io.open(P.refineFile, "r")
    if not f then return false end
    local val = f:read("*a"):gsub("%s+", ""); f:close()
    return val == "on"
end

local function setRefineMode(on)
    local f = io.open(P.refineFile, "w")
    if f then f:write(on and "on" or "off"); f:close() end
end

-- Forward decls for warm-keeper (defined alongside refineWithOllama below).
local startWarmKeeperRef, stopWarmKeeperRef

local function cycleRefine()
    local current = getRefineMode()
    setRefineMode(not current)
    if not current and startWarmKeeperRef then startWarmKeeperRef()
    elseif current and stopWarmKeeperRef then stopWarmKeeperRef() end
end

-- Timing
local PARTIAL_INTERVAL = 2.0   -- seconds between partial transcriptions
local OVERLAY_LINGER = 2.0     -- seconds to show final text before closing

-- Known whisper hallucinations on silence/short audio
local HALLUCINATIONS = {
    "you", "thank you", "thanks for watching", "thanks for listening",
    "bye", "goodbye", "the end", "thank you for watching",
    "subscribe", "like and subscribe", "see you", "you.",
    "(applause)", "(keyboard clicking)", "(typing)", "(silence)",
    "(soft music)", "(lighter clicking)", "(applauding)",
    "[BLANK_AUDIO]", "[silence]",
}

--------------------------------------------------------------------------------
-- Trigger key mapping
--------------------------------------------------------------------------------

local TRIGGER_MASKS = {
    rightAlt  = hs.eventtap.event.rawFlagMasks["deviceRightAlternate"],
    rightCmd  = hs.eventtap.event.rawFlagMasks["deviceRightCommand"],
    rightCtrl = hs.eventtap.event.rawFlagMasks["deviceRightControl"],
}

local triggerMask = TRIGGER_MASKS[TRIGGER_KEY]
if not triggerMask then
    hs.notify.new({ title = "Thinking Out Loud", informativeText = "ERROR: Invalid TRIGGER_KEY: " .. TRIGGER_KEY }):send()
    return
end

--------------------------------------------------------------------------------
-- Utilities
--------------------------------------------------------------------------------

os.execute("mkdir -p '" .. WHISPER_TMP .. "'")

local function log(msg)
    local f = io.open(P.logFile, "a")
    if f then
        f:write(os.date("[%H:%M:%S] ") .. msg .. "\n")
        f:close()
    end
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function writeFile(path, content)
    local f = io.open(path, "w")
    if not f then return end
    f:write(content)
    f:close()
end

local function getLang()
    local lang = readFile(P.langFile):gsub("%s+", "")
    if lang == "en" or lang == "pt" or lang == "auto" then return lang end
    return "en"
end

local function getOutputMode()
    local mode = readFile(P.outputFile):gsub("%s+", "")
    if mode == "type" then return "type" end
    return "paste"
end

local function getPreferredLangs()
    local content = readFile(P.preferredLangsFile):gsub("%s+$", "")
    if content == "" then return {"en", "pt"} end
    local langs = {}
    for lang in content:gmatch("[^,]+") do
        lang = lang:match("^%s*(.-)%s*$")
        if lang ~= "" then table.insert(langs, lang) end
    end
    return #langs > 0 and langs or {"en", "pt"}
end

local function getEnterMode()
    local mode = readFile(P.enterFile):gsub("%s+", "")
    return mode == "on"
end

local function shellQuote(text)
    return "'" .. tostring(text):gsub("'", "'\\''") .. "'"
end

local function expandPath(path)
    if type(path) ~= "string" then return nil end
    if path:sub(1, 2) == "~/" then return HOME .. path:sub(2) end
    return path
end

local function ensureParentDir(path)
    local parent = path:match("^(.*)/[^/]+$")
    if not parent or parent == "" then return true end
    local ok = os.execute("mkdir -p " .. shellQuote(parent))
    return ok == true or ok == 0
end

local function normalizeText(text)
    return ((text or ""):gsub("%s+", " ")):gsub("^%s+", ""):gsub("%s+$", "")
end

-- App bundle IDs where auto-capitalize should be skipped (terminals, code editors)
local NO_CAPITALIZE_APPS = {
    ["com.apple.Terminal"] = true,
    ["com.googlecode.iterm2"] = true,
    ["dev.warp.Warp-Stable"] = true,
    ["com.microsoft.VSCode"] = true,
    ["com.apple.dt.Xcode"] = true,
    ["com.jetbrains.intellij"] = true,
    ["com.sublimetext.4"] = true,
    ["com.github.atom"] = true,
    ["dev.zed.Zed"] = true,
}

-- Text post-processing: capitalize, remove fillers, clean whitespace
-- appBundleID is optional; when provided, adjusts behavior per-app
local function postProcess(text, appBundleID)
    -- Trim
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return text end
    -- Remove filler words (standalone, case-insensitive)
    text = text:gsub("%f[%w][Uu][mm]%f[%W]", "")
    text = text:gsub("%f[%w][Uu][hh]%f[%W]", "")
    text = text:gsub("%f[%w][Hh][Mm][Mm]+%f[%W]", "")
    -- Remove "like," used as filler (comma-following)
    text = text:gsub("%f[%w][Ll]ike,%s*", "")
    -- Collapse multiple spaces
    text = text:gsub("%s+", " ")
    -- Trim again after removals
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Auto-capitalize first letter (skip for terminals and code editors)
    if not (appBundleID and NO_CAPITALIZE_APPS[appBundleID]) then
        text = text:gsub("^%l", string.upper)
    end
    return text
end

-- Forward decl — set later once the overlay bridge is defined.
local signalRefineState = function(_, _) end

-- Lazy-loaded preamble patterns. Reload by setting refinePreambles = nil.
local refinePreambles = nil
local function getRefinePreambles()
    if refinePreambles then return refinePreambles end
    local f = io.open(P.refinePreamblesFile, "r")
    if f then
        local content = f:read("*a"); f:close()
        local ok, parsed = pcall(hs.json.decode, content)
        if ok and parsed and type(parsed.patterns) == "table" and #parsed.patterns > 0 then
            refinePreambles = parsed.patterns
            return refinePreambles
        end
        log("refine: preambles file invalid, using defaults")
    end
    refinePreambles = REFINE_DEFAULT_PREAMBLES
    return refinePreambles
end

local function stripPreambles(text)
    for _, pat in ipairs(getRefinePreambles()) do
        text = text:gsub(pat, "", 1)
    end
    return text:gsub("^%s+", "")
end

-- curl exit codes we treat as "Ollama unreachable" (connection refused, DNS, etc).
local CURL_CONN_FAILED = { [6] = true, [7] = true, [28] = true }

local function refineWithOllama(text, callback)
    if not getRefineMode() or not hasOllama() or #text < REFINE_MIN_CHARS then
        callback(text)
        return
    end
    log("refine: sending to Ollama API (" .. #text .. " chars)")
    signalRefineState("refining", nil)
    local prompt = getRefinePrompt() .. "\n\n" .. text
    local model = getRefineModel()
    local jsonPayload = hs.json.encode({
        model = model,
        prompt = prompt,
        stream = false,
        keep_alive = REFINE_WARM_KEEP_ALIVE,
    })
    local tmpPayload = WHISPER_TMP .. "/refine_payload.json"
    local f = io.open(tmpPayload, "w")
    if f then f:write(jsonPayload); f:close() end

    local settled = false
    local timeoutTimer = nil
    local curlTask = nil

    local function finish(reason, refined)
        if settled then return end
        settled = true
        if timeoutTimer then timeoutTimer:stop(); timeoutTimer = nil end
        if reason == "ok" then
            log("refine: success (" .. #refined .. " chars)")
            signalRefineState("idle", nil)
            callback(refined)
        else
            log("refine: " .. reason)
            signalRefineState("error", reason)
            callback(text)
        end
    end

    local timeout = refineTimeoutFor(text)
    curlTask = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
        if settled then return end
        if code == 0 and stdout and #stdout > 0 then
            local ok, result = pcall(hs.json.decode, stdout)
            if ok and result then
                if result.error then
                    local err = tostring(result.error)
                    if err:lower():match("model.*not%s*found") or err:lower():match("not%s*found") then
                        finish("model_missing", nil); return
                    end
                    finish("http_error:" .. err:sub(1, 60), nil); return
                end
                if result.response then
                    local refined = stripPreambles(result.response:gsub("^%s+", ""):gsub("%s+$", ""))
                    if refined ~= "" then finish("ok", refined); return end
                end
            end
            finish("bad_response", nil); return
        end
        if CURL_CONN_FAILED[code] then
            finish("ollama_offline", nil); return
        end
        finish("curl_exit_" .. tostring(code), nil)
    end, {
        "-s", "--max-time", tostring(timeout + 1), "-X", "POST",
        "http://localhost:11434/api/generate",
        "-H", "Content-Type: application/json",
        "-d", "@" .. tmpPayload,
    })
    curlTask:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
    curlTask:start()

    timeoutTimer = hs.timer.doAfter(timeout, function()
        if settled then return end
        if curlTask and curlTask.isRunning and curlTask:isRunning() then
            pcall(function() curlTask:terminate() end)
        end
        finish("timeout", nil)
    end)
end

-- ─── Warm-keeper ────────────────────────────────────────────────────────────
-- Periodic tiny ping to Ollama so the refine model stays resident. Stops
-- itself when refine is disabled or Ollama unreachable. Cheap (<50ms on warm).
local warmTimer = nil
local warmKickTimer = nil  -- retained to survive GC until the one-shot fires
local function pingOllama()
    if not getRefineMode() then return end
    if not hasOllama() then return end
    local model = getRefineModel()
    local payload = hs.json.encode({
        model = model,
        prompt = "",
        stream = false,
        keep_alive = REFINE_WARM_KEEP_ALIVE,
    })
    local tmpPayload = WHISPER_TMP .. "/refine_warm.json"
    local f = io.open(tmpPayload, "w")
    if f then f:write(payload); f:close() end
    local task = hs.task.new("/usr/bin/curl", function(code)
        -- Silent on success and on connection failures (Ollama may just be
        -- down transiently; the keeper retries next interval). Log only
        -- unexpected curl exits so real breakage is visible.
        if code ~= 0 and not CURL_CONN_FAILED[code] then
            log("warm: curl exit " .. tostring(code))
        end
    end, {
        "-s", "--max-time", "5", "-X", "POST",
        "http://localhost:11434/api/generate",
        "-H", "Content-Type: application/json",
        "-d", "@" .. tmpPayload,
    })
    task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
    task:start()
end

local function startWarmKeeper()
    if warmTimer then return end
    warmTimer = hs.timer.new(REFINE_WARM_INTERVAL, pingOllama)
    warmTimer:start()
    warmKickTimer = hs.timer.doAfter(0.5, pingOllama)  -- retained to avoid GC
end

local function stopWarmKeeper()
    if warmTimer then warmTimer:stop(); warmTimer = nil end
end

-- Publish to the forward decls used by cycleRefine above, and kick on load
-- if refine is already enabled.
startWarmKeeperRef = startWarmKeeper
stopWarmKeeperRef = stopWarmKeeper
if getRefineMode() then startWarmKeeper() end

local function isHallucination(text)
    local lower = text:lower():gsub("^%s+", ""):gsub("%s+$", "")
    -- strip trailing period for comparison
    local stripped = lower:gsub("[%.%!%?]+$", "")
    for _, h in ipairs(HALLUCINATIONS) do
        if stripped == h:lower() or lower == h:lower() then return true end
    end
    -- Also filter anything in brackets/parens (whisper noise markers)
    if lower:match("^%[.*%]$") or lower:match("^%(.*%)$") then return true end
    return false
end

local function getChunkFiles()
    local chunks = {}
    local ok, iter, dir = pcall(hs.fs.dir, CHUNK_DIR)
    if not ok then return chunks end
    for file in iter, dir do
        if file:match("^chunk_.*%.wav$") then
            table.insert(chunks, CHUNK_DIR .. "/" .. file)
        end
    end
    table.sort(chunks)
    return chunks
end

-- Cycle helpers
local function cycleLang()
    local cycle = { en = "pt", pt = "auto", auto = "en" }
    local next = cycle[getLang()] or "en"
    writeFile(P.langFile, next)
    return next
end

local function cycleModel()
    local models = getAvailableModels()
    if #models == 0 then return getModelName() end
    local current = getModelName()
    local next = models[1]
    for i, m in ipairs(models) do
        if m == current and models[i + 1] then
            next = models[i + 1]
            break
        end
    end
    if next == current then next = models[1] end
    writeFile(P.modelFile, next)
    return next
end

local function cycleOutput()
    local next = (getOutputMode() == "paste") and "type" or "paste"
    writeFile(P.outputFile, next)
    return next
end

local function cycleEnter()
    local next = getEnterMode() and "off" or "on"
    writeFile(P.enterFile, next)
    return next
end

-- List avfoundation audio input devices. Returns array of {index=":N", name="..."}.
-- Cached for the lifetime of this Hammerspoon load (cleared on reload).
local audioDeviceCache = nil
local function listAudioDevices()
    if audioDeviceCache then return audioDeviceCache end
    local cmd = FFMPEG .. " -f avfoundation -list_devices true -i '' 2>&1 || true"
    local out = hs.execute(cmd, false) or ""
    local devices = {}
    local inAudio = false
    for line in out:gmatch("[^\n]+") do
        if line:match("AVFoundation audio devices") then
            inAudio = true
        elseif line:match("AVFoundation video devices") then
            inAudio = false
        elseif inAudio then
            local idx, name = line:match("%[(%d+)%]%s+(.+)$")
            if idx and name then
                table.insert(devices, { index = ":" .. idx, name = name:gsub("%s+$", "") })
            end
        end
    end
    audioDeviceCache = devices
    return devices
end

local function setAudioDevice(device)
    writeFile(P.audioDeviceFile, device)
    hs.reload()
end

-- Pick fastest available model for live partial transcription
local function getPartialModelPath()
    local preferred = { "tiny", "tiny.en", "base", "base.en", "small", "small.en" }
    for _, name in ipairs(preferred) do
        local path = MODELS_DIR .. "/ggml-" .. name .. ".bin"
        if hs.fs.attributes(path) then return path end
    end
    return getModelPath()  -- fall back to main model
end

-- Read custom vocabulary prompt for whisper
local function getPromptArgs()
    local content = readFile(P.promptFile):gsub("%s+$", "")
    if content ~= "" then return { "--prompt", content } end
    return {}
end

--------------------------------------------------------------------------------
-- App-aware context (captured at recording start)
--------------------------------------------------------------------------------

local capturedAppName = nil
local capturedAppBundleID = nil

local function captureActiveApp()
    local app = hs.application.frontmostApplication()
    if app then
        capturedAppName = app:name()
        capturedAppBundleID = app:bundleID()
    else
        capturedAppName = nil
        capturedAppBundleID = nil
    end
end

--------------------------------------------------------------------------------
-- Optional post-dictation action hooks (user config)
--------------------------------------------------------------------------------

local actionConfig = nil
local actionConfigMtime = 0

local function safeHookCall(label, fn, ctx)
    local ok, err = pcall(fn, ctx)
    if not ok then
        log("actions: " .. label .. " failed: " .. tostring(err))
    end
end

-- Auto-reload: check mtime and reload if file changed
local function loadActionConfig()
    local attr = hs.fs.attributes(P.actionsFile)
    if not attr then
        actionConfig = nil
        actionConfigMtime = 0
        return nil
    end

    local mtime = attr.modification or 0
    if actionConfig and mtime == actionConfigMtime then
        return actionConfig
    end

    local chunk, err = loadfile(P.actionsFile)
    if not chunk then
        log("actions: could not load config: " .. tostring(err))
        return nil
    end

    local ok, cfg = pcall(chunk)
    if not ok then
        log("actions: config execution failed: " .. tostring(cfg))
        return nil
    end
    if type(cfg) ~= "table" then
        log("actions: config must return a table")
        return nil
    end

    actionConfig = cfg
    actionConfigMtime = mtime
    log("actions: loaded " .. P.actionsFile)
    return actionConfig
end

local function reloadActionConfig()
    actionConfigMtime = 0
    actionConfig = nil
    return loadActionConfig()
end

local function buildActionContext(text, lang, mode)
    local ctx = {
        text = text,
        textLower = text:lower(),
        originalText = text,
        lang = lang,
        outputMode = mode,
        appName = capturedAppName,
        appBundleID = capturedAppBundleID,
        insert = true,
        inserted = false,
        handled = false,
        timestamp = os.time(),
        isoTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    function ctx:setText(newText)
        if type(newText) ~= "string" then return end
        self.text = normalizeText(newText)
        self.textLower = self.text:lower()
    end

    function ctx:disableInsert()
        self.insert = false
    end

    function ctx:enableInsert()
        self.insert = true
    end

    function ctx:launchApp(appName)
        if type(appName) ~= "string" or appName == "" then return false end
        return hs.application.launchOrFocus(appName)
    end

    function ctx:appendToFile(path, line)
        local resolved = expandPath(path)
        if not resolved or resolved == "" then return false, "invalid path" end
        if not ensureParentDir(resolved) then return false, "mkdir failed" end
        local f = io.open(resolved, "a")
        if not f then return false, "open failed" end
        f:write(tostring(line or self.text or "") .. "\n")
        f:close()
        return true
    end

    function ctx:runShell(command, inputText)
        if type(command) ~= "string" or command == "" then
            return false, "", "invalid command", 1
        end
        local token = tostring(os.time()) .. "_" .. tostring(math.random(1000000))
        local stdinPath = WHISPER_TMP .. "/action_stdin_" .. token .. ".txt"
        writeFile(stdinPath, tostring(inputText or self.text or ""))
        local output, ok, kind, rc = hs.execute(command .. " < " .. shellQuote(stdinPath), true)
        os.remove(stdinPath)
        return ok, output, kind, rc
    end

    function ctx:keystroke(mods, key)
        hs.eventtap.keyStroke(mods or {}, key)
    end

    function ctx:notify(message)
        hs.notify.new({ title = "Thinking Out Loud", informativeText = tostring(message) }):send()
    end

    function ctx:log(message)
        log("action: " .. tostring(message))
    end

    return ctx
end

local function runActionList(actions, ctx)
    if type(actions) ~= "table" then return end
    for i, action in ipairs(actions) do
        if ctx.handled then break end
        if type(action) == "function" then
            safeHookCall("actions[" .. i .. "]", action, ctx)
        elseif type(action) == "table" and type(action.run) == "function" then
            local name = action.name or ("actions[" .. i .. "]")
            local shouldRun = true
            if type(action.when) == "function" then
                local ok, res = pcall(action.when, ctx)
                if not ok then
                    shouldRun = false
                    log("actions: " .. name .. ".when failed: " .. tostring(res))
                else
                    shouldRun = not not res
                end
            elseif type(action.pattern) == "string" then
                shouldRun = ctx.textLower:match(action.pattern) ~= nil
            end
            if shouldRun then
                safeHookCall(name, action.run, ctx)
            end
        end
    end
end

local function runPreInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.beforeInsert) == "function" then
        safeHookCall("beforeInsert", cfg.beforeInsert, ctx)
    end
    if not ctx.handled then
        runActionList(cfg.actions, ctx)
    end
end

local function runPostInsertActions(ctx)
    local cfg = loadActionConfig()
    if type(cfg) ~= "table" then return end
    if type(cfg.afterInsert) == "function" then
        safeHookCall("afterInsert", cfg.afterInsert, ctx)
    end
end

-- Global reload function (used by hotkey and menu bar)
WhisperActions = WhisperActions or {}
function WhisperActions.reload()
    local cfg = reloadActionConfig()
    if cfg then
        hs.notify.new({ title = "Thinking Out Loud", informativeText = "Action hooks reloaded" }):send()
    else
        hs.notify.new({ title = "Thinking Out Loud", informativeText = "No action hook config found" }):send()
    end
end

--------------------------------------------------------------------------------
-- Overlay UI (hs.webview — HTML/CSS/JS)
--------------------------------------------------------------------------------
-- All visuals live in ~/.hammerspoon/overlay.html. This Lua module only:
--  (1) creates/positions the webview, (2) pushes state via evaluateJavaScript.
-- Theme switching is just a body class change on the JS side.

local AVAILABLE_THEMES = { "liquid", "editorial", "fog", "ink", "glass-black", "neon", "arc-card" }
local DEFAULT_THEME = "liquid"

-- Read HTML template once at load. Shared across all overlay instances.
local OVERLAY_HTML = nil
do
    local f = io.open(P.overlayHtml, "r")
    if f then OVERLAY_HTML = f:read("*a"); f:close() end
    if not OVERLAY_HTML or OVERLAY_HTML == "" then
        log("overlay: WARNING — " .. P.overlayHtml .. " missing or empty; using fallback stub")
        OVERLAY_HTML = "<html><body style='background:#222;color:#fff;font:12px sans-serif;padding:12px'>overlay.html missing</body></html>"
    end
end

local function getTheme()
    local f = io.open(P.themeFile, "r")
    if f then
        local v = f:read("*a"):gsub("%s+", ""); f:close()
        for _, t in ipairs(AVAILABLE_THEMES) do
            if t == v then return v end
        end
    end
    return DEFAULT_THEME
end

local function setTheme(name)
    for _, t in ipairs(AVAILABLE_THEMES) do
        if t == name then writeFile(P.themeFile, name); hs.reload(); return end
    end
end

local overlay = nil  -- hs.webview instance

-- Lua → JS bridge. Safe against missing overlay.
local function jsEval(code)
    if overlay and overlay.evaluateJavaScript then overlay:evaluateJavaScript(code) end
end

-- Escape a string for single-quoted JS literal.
local function jsStr(s)
    return (s or ""):gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "")
end

-- No-op shims: the old canvas API had these; callers still invoke them.
local function refreshOverlayLabels() end
local function setOverlayStatus() end

-- Fixed webview viewport. The pill sits at the bottom; the transcript card
-- grows upward from it. Height is tall enough for a ~6-line transcript card
-- plus the pill and padding; body transparent so empty area doesn't render.
local OVERLAY_W = 400
local OVERLAY_H = 220

local function createOverlay()
    local cursor = hs.mouse.absolutePosition()
    -- Pick the screen containing the cursor (multi-monitor).
    local screen = hs.screen.mainScreen()
    for _, s in ipairs(hs.screen.allScreens()) do
        local f = s:frame()
        if cursor.x >= f.x and cursor.x < f.x + f.w
           and cursor.y >= f.y and cursor.y < f.y + f.h then
            screen = s
            break
        end
    end
    local frame = screen:frame()
    local offset = 30
    local x = (cursor.x < frame.x + frame.w / 2)
        and (cursor.x + offset)
        or  (cursor.x - OVERLAY_W - offset)
    local y = (cursor.y < frame.y + frame.h / 2)
        and (cursor.y + offset)
        or  (cursor.y - OVERLAY_H - offset)
    x = math.max(frame.x + 10, math.min(x, frame.x + frame.w - OVERLAY_W - 10))
    y = math.max(frame.y + 10, math.min(y, frame.y + frame.h - OVERLAY_H - 10))

    overlay = hs.webview.new({ x = x, y = y, w = OVERLAY_W, h = OVERLAY_H },
        { developerExtrasEnabled = true })
    overlay:windowStyle({ "borderless" })
    overlay:level(hs.canvas.windowLevels.floating)
    overlay:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    overlay:allowTextEntry(false)
    overlay:transparent(true)
    overlay:shadow(false)

    -- Bake the current theme + recording state into the HTML *before* load so the
    -- overlay renders correctly the instant WKWebView parses it (avoids a race
    -- where evaluateJavaScript fires before DOM-ready).
    local classes = "theme-" .. getTheme()
    if isRecording then classes = classes .. " recording" end
    local html = OVERLAY_HTML:gsub('body class="theme%-liquid"', 'body class="' .. classes .. '"', 1)
    overlay:html(html)
end

local function showOverlay()
    overlayPinned = false
    if overlay then overlay:delete() end
    createOverlay()
    overlay:show()
    overlay:bringToFront(true)
end

local function hideOverlay()
    if overlayPinned then return end
    if overlay then overlay:delete(); overlay = nil end
end

local function forceHideOverlay()
    overlayPinned = false
    if overlay then overlay:delete(); overlay = nil end
end

local function setOverlayText(text)
    jsEval("lw.setTranscript('" .. jsStr(text) .. "')")
end

-- Drive refine status visible in the overlay dot (idle/refining/error).
-- Defined here (after jsEval) and assigned to the forward decl declared
-- near refineWithOllama. `reason` is the structured error code when state=="error".
signalRefineState = function(state, reason)
    jsEval(string.format("lw.setRefineState && lw.setRefineState('%s','%s')",
        jsStr(state or "idle"), jsStr(reason or "")))
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local isRecording = false
local overlayPinned = false
local ffmpegTask = nil
local partialTimer = nil
local partialBusy = false
local lastChunkCount = 0

-- Audio level metering. ffmpeg's `astats` filter emits RMS dB per ~50ms window
-- and `ametadata` prints it to stderr (line-buffered, flushes in real time). The
-- hs.task stream callback parses each chunk; a separate 20Hz timer throttles
-- the push into the webview (rAF handles final smoothing on the JS side).
-- Wrapped in do...end so internal constants/state stay out of the main chunk's
-- 200-local budget. Functions are forward-declared and re-bound inside.
local parseMeterChunk, startMeterPushing, stopMeterPushing
do
    local METER_DB_FLOOR = -60
    local METER_PUSH_INTERVAL = 0.05
    -- Noise gate: during the first N seconds of each recording, track the
    -- loudest ambient reading and use it as the dynamic silence floor for the
    -- rest of the session. Bars stay at 0 during the calibration window.
    local METER_CALIBRATION_SEC = 0.4
    local METER_MIN_RANGE = 20         -- clamp range so a noisy room can't collapse the scale
    local METER_SPEECH_DB = -25        -- readings above this during calibration = likely speech
    local METER_FALLBACK_BASELINE = -45  -- used when calibration is contaminated by speech

    local meterPushTimer = nil
    local meterLevel = 0.0
    local meterBaseline = nil
    local meterCalibrationMax = -100
    local meterCalibrationStart = 0

    parseMeterChunk = function(chunk)
        for rms in chunk:gmatch("lavfi%.astats%.Overall%.RMS_level=([^\r\n]+)") do
            local db
            if rms == "-inf" or rms == "nan" then
                db = METER_DB_FLOOR
            else
                db = tonumber(rms)
            end
            if db then
                if not meterBaseline then
                    -- Still calibrating: track the loudest reading in the window.
                    if db > meterCalibrationMax then meterCalibrationMax = db end
                    if hs.timer.secondsSinceEpoch() - meterCalibrationStart >= METER_CALIBRATION_SEC then
                        local b = meterCalibrationMax
                        -- If the user started speaking during calibration, the
                        -- max is way too high to be noise — use a safe default.
                        if b > METER_SPEECH_DB then b = METER_FALLBACK_BASELINE end
                        if b < METER_DB_FLOOR then b = METER_DB_FLOOR end
                        if b > -METER_MIN_RANGE then b = -METER_MIN_RANGE end
                        meterBaseline = b
                    end
                    meterLevel = 0
                else
                    local range = -meterBaseline
                    if range < METER_MIN_RANGE then range = METER_MIN_RANGE end
                    local level = (db - meterBaseline) / range
                    if level < 0 then level = 0 elseif level > 1 then level = 1 end
                    meterLevel = level
                end
            end
        end
    end

    startMeterPushing = function()
        meterLevel = 0
        meterBaseline = nil
        meterCalibrationMax = -100
        meterCalibrationStart = hs.timer.secondsSinceEpoch()
        if meterPushTimer then meterPushTimer:stop() end
        meterPushTimer = hs.timer.doEvery(METER_PUSH_INTERVAL, function()
            jsEval(string.format("window.lw&&window.lw.level&&window.lw.level(%.3f)", meterLevel))
        end)
    end

    stopMeterPushing = function()
        if meterPushTimer then meterPushTimer:stop(); meterPushTimer = nil end
        meterLevel = 0
    end
end

-- Menu bar
local menuBar = nil

-- Recording indicator state
local pulseTimer = nil
local clockTimer = nil
local recordingStartTime = 0
local pulseAlpha = 1.0
local pulseFading = true

-- Undo state
local lastInsertedText = nil

-- Dictation history (newest first, persisted to ~/.thinking-out-loud/history.json
-- at `P.historyFile`). Replaces the previous "recent.json" 10-entry cap.
-- Entries: {text, time, inserted, app, model, chars}.
local MAX_RECENT = 500

local recentDictations = {}

local function loadRecentDictations()
    -- Primary: history.json
    local f = io.open(P.historyFile, "r")
    -- Migration fallback: one-time bootstrap from legacy recent.json
    if not f then f = io.open(P.recentFile, "r") end
    if not f then return end
    local data = f:read("*a"); f:close()
    local ok, result = pcall(hs.json.decode, data)
    if ok and type(result) == "table" then
        for i = #recentDictations, 1, -1 do recentDictations[i] = nil end
        for i, entry in ipairs(result) do recentDictations[i] = entry end
    end
end

local function saveRecentDictations()
    local ok, json = pcall(hs.json.encode, recentDictations)
    if not ok then return end
    local f = io.open(P.historyFile, "w")
    if f then f:write(json); f:close() end
end

loadRecentDictations()

--------------------------------------------------------------------------------
-- History Dashboard (hs.webview)
-- Wrapped in do...end so dashboard state/template stays out of the main chunk's
-- 200-local budget. `openDashboard` is forward-declared (used by menu bar +
-- Cmd+Shift+H hotkey) and re-bound inside.
--------------------------------------------------------------------------------

local openDashboard
do

local DASHBOARD_HTML_PATH = HOME .. "/.hammerspoon/dashboard.html"
local DASHBOARD_HTML = nil
do
    local f = io.open(DASHBOARD_HTML_PATH, "r")
    if f then DASHBOARD_HTML = f:read("*a"); f:close() end
    if not DASHBOARD_HTML or DASHBOARD_HTML == "" then
        log("dashboard: WARNING — dashboard.html missing")
        DASHBOARD_HTML = "<html><body style='background:#222;color:#fff;font:13px sans-serif;padding:20px'>dashboard.html missing</body></html>"
    end
end

local dashboard = nil
local dashboardPrevApp = nil  -- track the app focused before we opened the dashboard

local function pushHistoryToDashboard()
    if not dashboard then return end
    local ok, json = pcall(hs.json.encode, recentDictations)
    if not ok then return end
    -- Escape for JS single-quote string
    local esc = json:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "")
    dashboard:evaluateJavaScript("lw.load('" .. esc .. "')")
end

openDashboard = function()
    if dashboard then dashboard:bringToFront(true); return end

    -- Remember focus so "paste" can restore the previous app.
    local fa = hs.application.frontmostApplication()
    dashboardPrevApp = fa and fa:bundleID() or nil

    local screen = hs.screen.mainScreen():frame()
    local w, h = 820, 600
    local x = screen.x + (screen.w - w) / 2
    local y = screen.y + (screen.h - h) / 2

    local controller = hs.webview.usercontent.new("lw")
    controller:setCallback(function(msg)
        local body = msg and msg.body
        if type(body) ~= "table" then return end
        local action = body.action

        if action == "ready" then
            pushHistoryToDashboard()

        elseif action == "copy" then
            if body.text then hs.pasteboard.setContents(body.text) end

        elseif action == "paste" then
            if not body.text then return end
            hs.pasteboard.setContents(body.text)
            -- Close dashboard, restore previous app, then synthesize Cmd+V.
            if dashboard then dashboard:delete(); dashboard = nil end
            hs.timer.doAfter(0.05, function()
                if dashboardPrevApp then
                    local app = hs.application.applicationsForBundleID(dashboardPrevApp)[1]
                    if app then app:activate() end
                end
                hs.timer.doAfter(0.1, function()
                    hs.eventtap.keyStroke({"cmd"}, "v")
                end)
            end)

        elseif action == "delete" then
            -- Delete by timestamp (stable across filters)
            local time = body.time
            for i, entry in ipairs(recentDictations) do
                if entry.time == time then
                    table.remove(recentDictations, i)
                    break
                end
            end
            saveRecentDictations()
            pushHistoryToDashboard()

        elseif action == "export" then
            local path = os.getenv("HOME") .. "/Downloads/thinking-out-loud-history-"
                .. os.date("%Y%m%d-%H%M%S") .. ".md"
            local f = io.open(path, "w")
            if not f then return end
            f:write("# Thinking Out Loud — dictation history\n\n")
            f:write("Exported " .. os.date("%Y-%m-%d %H:%M:%S") .. " — " .. #recentDictations .. " entries\n\n")
            for _, e in ipairs(recentDictations) do
                local ts = os.date("%Y-%m-%d %H:%M", e.time)
                f:write("## " .. ts .. "  ·  " .. (e.app or "?") .. "  ·  " .. (e.model or "?") .. "\n\n")
                if e.refined and e.refined ~= e.text then
                    f:write("**Refined:** " .. e.refined .. "\n\n")
                    f:write("**Raw:** " .. (e.text or "") .. "\n\n")
                else
                    f:write((e.text or "") .. "\n\n")
                end
            end
            f:close()
            log("dashboard: exported " .. #recentDictations .. " entries → " .. path)
        end
    end)

    dashboard = hs.webview.new({ x = x, y = y, w = w, h = h },
        { developerExtrasEnabled = true }, controller)
    dashboard:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    dashboard:windowTitle("Thinking Out Loud — History")
    dashboard:allowTextEntry(true)
    dashboard:level(hs.canvas.windowLevels.normal)
    -- Clear our stale reference when the user closes the window with the red X
    -- (otherwise openDashboard thinks it's still open and refuses to reopen).
    dashboard:windowCallback(function(action, webview, state)
        if action == "closing" then
            dashboard = nil
        end
    end)
    dashboard:deleteOnClose(true)
    dashboard:html(DASHBOARD_HTML)
    dashboard:show()
    dashboard:bringToFront(true)

    -- Safety: if "ready" didn't fire, push history after 400ms.
    hs.timer.doAfter(0.4, pushHistoryToDashboard)
end

local function closeDashboard()
    if dashboard then dashboard:delete(); dashboard = nil end
end

end -- end of Dashboard do-block

-- Auto-stop state
local silentChunkCount = 0
local silenceTimer = nil
local lastCheckedChunk = 0

--------------------------------------------------------------------------------
-- Menu bar status icon
--------------------------------------------------------------------------------

local function makeWaveformIcon(color, asTemplate)
    local w, h = 18, 18
    local c = hs.canvas.new({ x = 0, y = 0, w = w, h = h })
    -- Bar heights (symmetric waveform: short-medium-tall-medium-short)
    local bars = { 0.3, 0.55, 1.0, 0.55, 0.3 }
    local barW = 2
    local gap = 1.5
    local totalW = #bars * barW + (#bars - 1) * gap
    local startX = (w - totalW) / 2
    for i, scale in ipairs(bars) do
        local barH = math.floor(h * 0.75 * scale)
        local x = startX + (i - 1) * (barW + gap)
        local y = (h - barH) / 2
        c:appendElements({
            type = "rectangle",
            frame = { x = x, y = y, w = barW, h = barH },
            fillColor = color,
            roundedRectRadii = { xRadius = 1, yRadius = 1 },
            action = "fill",
        })
    end
    local img = c:imageFromCanvas()
    c:delete()
    img:template(asTemplate)
    return img
end

function updateMenuBar()
    if not menuBar then return end
    if isRecording then
        local icon = makeWaveformIcon({ red = 1, green = 0.15, blue = 0.15, alpha = 1 }, false)
        menuBar:setIcon(icon, false)
    else
        local icon = makeWaveformIcon({ red = 0, green = 0, blue = 0, alpha = 1 }, true)
        menuBar:setIcon(icon, true)
    end
end

-- Forward-declare meeting state and functions (defined in Meeting mode section below)
local meetingRecording = false
local meetingStartTime = nil
local startMeeting, stopMeeting

local function buildMenuBarMenu()
    local items = {}

    -- Current status
    table.insert(items, { title = isRecording and "● Recording..." or "Idle", disabled = true })
    table.insert(items, { title = "-" })

    -- Language
    local langDisplay = getLang():upper()
    table.insert(items, {
        title = "Language: " .. langDisplay,
        fn = function() cycleLang(); updateMenuBar() end,
    })

    -- Model
    table.insert(items, {
        title = "Model: " .. getModelName(),
        fn = function() cycleModel(); updateMenuBar() end,
    })

    -- Microphone picker (submenu listing avfoundation audio devices)
    do
        local devices = listAudioDevices()
        local currentLabel = AUDIO_DEVICE
        for _, d in ipairs(devices) do
            if d.index == AUDIO_DEVICE then currentLabel = d.name break end
        end
        local submenu = {}
        table.insert(submenu, {
            title = ":default (system)",
            checked = AUDIO_DEVICE == ":default",
            fn = function() setAudioDevice(":default") end,
        })
        for _, d in ipairs(devices) do
            table.insert(submenu, {
                title = d.index .. "  " .. d.name,
                checked = d.index == AUDIO_DEVICE,
                fn = function() setAudioDevice(d.index) end,
            })
        end
        table.insert(items, {
            title = "Microphone: " .. currentLabel,
            menu = submenu,
        })
    end

    -- Theme picker (submenu) — 7 webview themes
    do
        local current = getTheme()
        local submenu = {}
        for _, name in ipairs(AVAILABLE_THEMES) do
            table.insert(submenu, {
                title = name,
                checked = name == current,
                fn = function() setTheme(name) end,
            })
        end
        table.insert(items, { title = "Theme: " .. current, menu = submenu })
    end

    -- Output mode
    table.insert(items, {
        title = "Output: " .. getOutputMode():upper(),
        fn = function() cycleOutput(); updateMenuBar() end,
    })

    -- Enter mode
    local enterState = getEnterMode() and "ON" or "OFF"
    table.insert(items, {
        title = "Enter after insert: " .. enterState,
        fn = function() cycleEnter(); updateMenuBar() end,
    })

    -- LLM refinement
    if hasOllama() then
        local refineState = getRefineMode() and "ON" or "OFF"
        table.insert(items, {
            title = "LLM Refine: " .. refineState .. " (" .. getRefineModel() .. ")",
            fn = function() cycleRefine(); updateMenuBar() end,
        })
    else
        table.insert(items, {
            title = "LLM Refine (install ollama.com)",
            disabled = true,
        })
    end

    -- Preferred langs
    local preferred = table.concat(getPreferredLangs(), ", ")
    table.insert(items, { title = "Preferred: " .. preferred, disabled = true })

    table.insert(items, { title = "-" })

    -- Meeting mode
    if meetingRecording then
        local elapsed = hs.timer.secondsSinceEpoch() - (meetingStartTime or 0)
        local mins = math.floor(elapsed / 60)
        table.insert(items, {
            title = "⏹ Stop Meeting Notes (" .. mins .. "m)",
            fn = function() stopMeeting() end,
        })
    else
        table.insert(items, {
            title = "🎙 Start Meeting Notes",
            fn = function() startMeeting() end,
        })
    end

    -- History dashboard (replaces the old inline "Recent Dictations" list)
    table.insert(items, { title = "-" })
    local historyLabel = (#recentDictations == 0)
        and "History… (empty)"
        or  ("History… (" .. #recentDictations .. ")")
    table.insert(items, {
        title = historyLabel,
        fn = function() openDashboard() end,
    })

    table.insert(items, { title = "-" })

    -- Reload actions
    table.insert(items, {
        title = "Reload Actions",
        fn = function() WhisperActions.reload() end,
    })

    -- Emergency stop
    table.insert(items, { title = "-" })
    table.insert(items, {
        title = "Emergency Stop",
        fn = function() emergencyStop() end,
    })

    return items
end

local function createMenuBar()
    -- Clean up previous instance on reload
    if menuBar then menuBar:delete(); menuBar = nil end
    menuBar = hs.menubar.new()
    if not menuBar then return end
    updateMenuBar()
    menuBar:setMenu(buildMenuBarMenu)
end

--------------------------------------------------------------------------------
-- Recording indicator (pulsing dot + timer)
--------------------------------------------------------------------------------

local function startRecordingIndicator()
    if not overlay then return end
    recordingStartTime = hs.timer.secondsSinceEpoch()

    -- CSS drives the dot pulse + waveform animation; we just flip the body class.
    jsEval("lw.setRecording(true); lw.setTimer('0:00')")

    -- Lua ticks the timer once per second.
    clockTimer = hs.timer.doEvery(1, function()
        if not overlay then return end
        local elapsed = math.floor(hs.timer.secondsSinceEpoch() - recordingStartTime)
        local min = math.floor(elapsed / 60)
        local sec = elapsed % 60
        jsEval(string.format("lw.setTimer('%d:%02d')", min, sec))
    end)
end

local function stopRecordingIndicator()
    if pulseTimer then pulseTimer:stop(); pulseTimer = nil end  -- legacy (unused now)
    if clockTimer then clockTimer:stop(); clockTimer = nil end
    jsEval("lw.setRecording(false)")
end

--------------------------------------------------------------------------------
-- Emergency stop (forward declaration)
--------------------------------------------------------------------------------

function emergencyStop()
    log("emergency stop")
    isRecording = false
    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    stopRecordingIndicator()
    if ffmpegTask and ffmpegTask:isRunning() then ffmpegTask:interrupt() end
    ffmpegTask = nil
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    forceHideOverlay()
    updateMenuBar()
    os.execute("killall whisper-cli 2>/dev/null")
    hs.notify.new({ title = "Thinking Out Loud", informativeText = "Stopped" }):send()
end

--------------------------------------------------------------------------------
-- Partial transcription (live preview while recording)
--------------------------------------------------------------------------------

local function doPartialTranscribe()
    if partialBusy or not isRecording then return end

    local chunks = getChunkFiles()
    local numChunks = #chunks
    if numChunks < 3 then return end

    local completed = numChunks - 1  -- skip last chunk (being written)
    if completed <= lastChunkCount then return end

    partialBusy = true

    -- Transcribe ALL completed chunks from the start, every partial tick. This
    -- gives cumulative text that grows with the dictation, so the overlay
    -- renders a stable paragraph (only the new tail fades in). Whisper tiny
    -- on M4 runs ~20× realtime, so 30s of audio transcribes in ~1.5s —
    -- partialBusy guards against overlap for longer recordings.
    local startIdx = 1
    local batchList = WHISPER_TMP .. "/partial_concat.txt"
    local f = io.open(batchList, "w")
    for i = startIdx, completed do
        f:write("file '" .. chunks[i] .. "'\n")
    end
    f:close()

    local batchWav = WHISPER_TMP .. "/partial_batch.wav"
    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            partialBusy = false
            return
        end
        local lang = getLang()
        -- In auto mode, use first preferred lang for speed during partial transcription
        if lang == "auto" then lang = getPreferredLangs()[1] end
        local whisperArgs = { "-m", getPartialModelPath(), "-f", batchWav, "-l", lang, "-nt", "--no-prints" }
        local promptArgs = getPromptArgs()
        for _, a in ipairs(promptArgs) do table.insert(whisperArgs, a) end
        local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
            partialBusy = false
            lastChunkCount = completed
            if code2 ~= 0 or not isRecording then return end
            local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
            if text ~= "" and not isHallucination(text) then
                -- Show the full cumulative partial — the transcript card wraps and
                -- grows with content, so no tail-windowing needed.
                setOverlayText(text)
                log("partial: " .. text)
            end
        end, whisperArgs)
        whisperTask:start()
    end, { "-y", "-f", "concat", "-safe", "0", "-i", batchList, "-c", "copy", batchWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Final transcription
--------------------------------------------------------------------------------

-- Low-level text insertion at cursor
local function insertTextAtCursor(text, mode)
    if mode == "paste" then
        local oldClipboard = hs.pasteboard.getContents()
        hs.pasteboard.setContents(text)
        hs.eventtap.keyStroke({"cmd"}, "v")
        hs.timer.doAfter(0.3, function()
            if oldClipboard then hs.pasteboard.setContents(oldClipboard) end
        end)
    else
        hs.eventtap.keyStrokes(text)
    end
end

-- Finish insertion after all processing (post-process, refine, hooks).
-- preRefineText: the post-processed whisper output BEFORE refine ran. Only set
-- when refine actually ran, so history can distinguish original vs refined.
local function finishInsertion(text, detectedLang, preRefineText)
    -- Build action context and run pre-insert hooks
    local ctx = buildActionContext(normalizeText(text), detectedLang or getLang(), getOutputMode())
    if preRefineText then
        ctx.originalText = preRefineText
    end
    runPreInsertActions(ctx)

    local finalText = normalizeText(ctx.text)
    if finalText == "" then
        log("final: empty text after actions")
        hideOverlay()
        return
    end

    if ctx.insert then
        -- Track for undo
        lastInsertedText = finalText
        insertTextAtCursor(finalText, ctx.outputMode)
        ctx.inserted = true

        -- Press Enter after insertion if enter mode is on
        if getEnterMode() then
            hs.timer.doAfter(0.15, function()
                hs.eventtap.keyStroke({}, "return")
            end)
        end
    else
        log("final: insertion disabled by action hooks")
    end

    ctx.text = finalText
    runPostInsertActions(ctx)

    -- Track in history
    table.insert(recentDictations, 1, {
        text = ctx.originalText,
        refined = ctx.text ~= ctx.originalText and ctx.text or nil,
        time = os.time(),
        inserted = ctx.inserted,
        app = capturedAppName or "?",
        model = getModelName(),
        chars = #(ctx.originalText or ""),
        lang = detectedLang or getLang(),
    })
    while #recentDictations > MAX_RECENT do
        table.remove(recentDictations)
    end
    saveRecentDictations()

    local display = finalText
    if detectedLang then display = display .. " [" .. detectedLang:upper() .. "]" end
    setOverlayText(display)
    hs.sound.getByFile("/System/Library/Sounds/Glass.aiff"):play()
    hs.timer.doAfter(OVERLAY_LINGER, hideOverlay)
end

-- Insert transcribed text at cursor, with post-processing, optional LLM refinement, and action hooks
local function insertTranscribedText(text, detectedLang)
    if text == "" or isHallucination(text) then
        hideOverlay()
        return
    end

    -- Apply app-aware post-processing
    text = postProcess(text, capturedAppBundleID)
    if text == "" then hideOverlay(); return end

    -- Skip LLM refinement for voice commands (refine would strip the prefix)
    local isVoiceCommand = text:lower():match("voice%s+command")

    -- Optional LLM refinement (async, skips short text and voice commands)
    if not isVoiceCommand and getRefineMode() and #text >= REFINE_MIN_CHARS then
        setOverlayText("Refining...")
        local preRefineText = normalizeText(text)
        refineWithOllama(text, function(refined)
            finishInsertion(refined, detectedLang, preRefineText)
        end)
    else
        finishInsertion(text, detectedLang)
    end
end

local function doFinalTranscription()
    local chunks = getChunkFiles()
    if #chunks < 2 then
        log("final: not enough chunks, skipping")
        hideOverlay()
        return
    end

    setOverlayText("Transcribing...")

    local concatFile = WHISPER_TMP .. "/concat.txt"
    local f = io.open(concatFile, "w")
    for _, chunk in ipairs(chunks) do
        f:write("file '" .. chunk .. "'\n")
    end
    f:close()

    local finalWav = WHISPER_TMP .. "/final.wav"
    local lang = getLang()
    local preferred = getPreferredLangs()

    local concatTask = hs.task.new(FFMPEG, function(code)
        if code ~= 0 then
            log("final: concat failed")
            setOverlayText("Error: concat failed")
            hs.timer.doAfter(2, hideOverlay)
            return
        end

        local promptArgs = getPromptArgs()

        if lang == "auto" then
            -- Auto mode: run without --no-prints to capture detected language from stderr
            local autoArgs = { "-m", getModelPath(), "-f", finalWav, "-l", "auto", "-nt" }
            for _, a in ipairs(promptArgs) do table.insert(autoArgs, a) end
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2, err2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    setOverlayText("Error: transcription failed")
                    hs.timer.doAfter(2, hideOverlay)
                    return
                end

                -- Parse detected language from whisper stderr
                local detected = (err2 or ""):match("auto%-detected language:%s*(%w+)")
                log("auto-detected: " .. tostring(detected))

                local inPreferred = false
                if detected then
                    for _, pl in ipairs(preferred) do
                        if detected == pl then inPreferred = true; break end
                    end
                end

                if inPreferred then
                    local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                    log("final (auto/" .. detected .. "): '" .. text .. "'")
                    insertTranscribedText(text, detected)
                else
                    -- Detected language not in preferred list — re-transcribe with first preferred
                    local fallback = preferred[1]
                    log("auto-detect got '" .. tostring(detected) .. "', re-running with " .. fallback)
                    setOverlayText("Re-transcribing (" .. fallback:upper() .. ")...")
                    local retryArgs = { "-m", getModelPath(), "-f", finalWav, "-l", fallback, "-nt", "--no-prints" }
                    for _, a in ipairs(promptArgs) do table.insert(retryArgs, a) end
                    local retryTask = hs.task.new(WHISPER_BIN, function(code3, out3)
                        if code3 ~= 0 then
                            log("final: retry whisper failed")
                            setOverlayText("Error: transcription failed")
                            hs.timer.doAfter(2, hideOverlay)
                            return
                        end
                        local text = (out3 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                        log("final (retry/" .. fallback .. "): '" .. text .. "'")
                        insertTranscribedText(text, fallback)
                    end, retryArgs)
                    retryTask:start()
                end
            end, autoArgs)
            whisperTask:start()
        else
            -- Specific language mode
            local langArgs = { "-m", getModelPath(), "-f", finalWav, "-l", lang, "-nt", "--no-prints" }
            for _, a in ipairs(promptArgs) do table.insert(langArgs, a) end
            local whisperTask = hs.task.new(WHISPER_BIN, function(code2, out2)
                if code2 ~= 0 then
                    log("final: whisper failed")
                    setOverlayText("Error: transcription failed")
                    hs.timer.doAfter(2, hideOverlay)
                    return
                end
                local text = (out2 or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
                log("final: '" .. text .. "'")
                insertTranscribedText(text)
            end, langArgs)
            whisperTask:start()
        end
    end, { "-y", "-f", "concat", "-safe", "0", "-i", concatFile, "-c", "copy", finalWav })
    concatTask:start()
end

--------------------------------------------------------------------------------
-- Auto-stop on silence
--------------------------------------------------------------------------------

local function checkSilence()
    if not isRecording then return end
    local chunks = getChunkFiles()
    local numChunks = #chunks
    -- Only check completed chunks (not the one being written)
    local completed = numChunks - 1
    if completed <= lastCheckedChunk then return end

    -- Check the latest completed chunk
    local chunkPath = chunks[completed]
    lastCheckedChunk = completed

    local volTask = hs.task.new(FFMPEG, function(code, out, err)
        if code ~= 0 or not isRecording then return end
        local maxVol = (err or ""):match("max_volume:%s*([-%.%d]+)")
        if maxVol then
            maxVol = tonumber(maxVol)
            if maxVol and maxVol < AUTO_STOP_THRESHOLD_DB then
                silentChunkCount = silentChunkCount + 1
                log("silence: chunk " .. completed .. " vol=" .. maxVol .. "dB (count=" .. silentChunkCount .. ")")
                if silentChunkCount >= AUTO_STOP_SILENCE_SECONDS then
                    log("auto-stop: " .. AUTO_STOP_SILENCE_SECONDS .. "s of silence")
                    stopRecording()
                end
            else
                silentChunkCount = 0
            end
        end
    end, { "-i", chunkPath, "-af", "volumedetect", "-f", "null", "-" })
    volTask:start()
end

--------------------------------------------------------------------------------
-- Start / stop recording
--------------------------------------------------------------------------------

local function startRecording()
    if isRecording then return end
    isRecording = true
    log("recording: start")

    os.execute("rm -rf '" .. CHUNK_DIR .. "'")
    os.execute("mkdir -p '" .. CHUNK_DIR .. "'")

    captureActiveApp()
    log("recording: app=" .. tostring(capturedAppName) .. " (" .. tostring(capturedAppBundleID) .. ")")

    showOverlay()
    startRecordingIndicator()
    updateMenuBar()
    hs.sound.getByFile("/System/Library/Sounds/Pop.aiff"):play()

    ffmpegTask = hs.task.new(FFMPEG,
        function(code, out, err)
            log("recording: ffmpeg exited " .. tostring(code))
            if code == 251 or code == 1 then
                log("recording: ERROR — ffmpeg failed to open audio device '" .. AUDIO_DEVICE .. "'. Check device format (should be :default, :0, :1) and microphone permissions.")
            end
        end,
        function(task, stdOut, stdErr)
            -- Stream callback fires incrementally while ffmpeg runs. ametadata
            -- output comes through stderr (its default destination via av_log),
            -- which is line-buffered by ffmpeg so RMS values arrive in real time.
            if stdErr and #stdErr > 0 then parseMeterChunk(stdErr) end
            return true
        end,
        {
            "-f", "avfoundation", "-i", AUDIO_DEVICE,
            "-ac", "1", "-ar", "16000",
            -- Measure RMS per 50ms; ametadata prints to stderr (no file= arg).
            -- Filters are pass-through, so the audio still flows to the segmenter.
            "-af", "astats=metadata=1:reset=1:length=0.05,ametadata=mode=print:key=lavfi.astats.Overall.RMS_level",
            "-f", "segment", "-segment_time", "1", "-segment_format", "wav",
            CHUNK_DIR .. "/chunk_%03d.wav"
        })
    ffmpegTask:start()
    startMeterPushing()

    lastChunkCount = 0
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0
    partialTimer = hs.timer.doEvery(PARTIAL_INTERVAL, doPartialTranscribe)
    silenceTimer = hs.timer.doEvery(1.0, checkSilence)
end

local function stopRecording()
    if not isRecording then return end
    isRecording = false
    log("recording: stop")

    if partialTimer then partialTimer:stop(); partialTimer = nil end
    if silenceTimer then silenceTimer:stop(); silenceTimer = nil end
    stopMeterPushing()
    partialBusy = false
    silentChunkCount = 0
    lastCheckedChunk = 0

    stopRecordingIndicator()
    updateMenuBar()

    if ffmpegTask and ffmpegTask:isRunning() then
        ffmpegTask:interrupt()
    end
    ffmpegTask = nil

    hs.sound.getByFile("/System/Library/Sounds/Tink.aiff"):play()

    -- Brief delay for ffmpeg to finalize last chunk
    hs.timer.doAfter(0.3, doFinalTranscription)
end

--------------------------------------------------------------------------------
-- Key detection (replaces Karabiner)
--------------------------------------------------------------------------------

-- Map trigger key to generic modifier name for polling
local GENERIC_MOD = { rightAlt = "alt", rightCmd = "cmd", rightCtrl = "ctrl" }
local genericMod = GENERIC_MOD[TRIGGER_KEY]

local releasePoller = nil

-- Global so we can inspect state via hs -c
_whisper = { modTap = nil, recording = false }

local modTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(event)
    -- Wrap in pcall so errors don't kill the eventtap
    local ok, err = pcall(function()
        local rawFlags = event:rawFlags()
        local triggered = (rawFlags & triggerMask) > 0

        if triggered and not isRecording then
            startRecording()
            -- Poll for release since flagsChanged doesn't fire on key-up
            if releasePoller then releasePoller:stop() end
            releasePoller = hs.timer.doEvery(0.1, function()
                local mods = hs.eventtap.checkKeyboardModifiers()
                if not mods[genericMod] then
                    releasePoller:stop()
                    releasePoller = nil
                    stopRecording()
                end
            end)
        elseif not triggered and isRecording then
            if releasePoller then releasePoller:stop(); releasePoller = nil end
            stopRecording()
        end
    end)
    if not ok then log("eventtap error: " .. tostring(err)) end

    return false
end)
modTap:start()
_whisper.modTap = modTap

-- Re-enable eventtap if it gets disabled (e.g. by secure input)
hs.timer.doEvery(5, function()
    if not modTap:isEnabled() then
        log("eventtap was disabled, re-enabling")
        modTap:start()
    end
end)

--------------------------------------------------------------------------------
-- Meeting mode
-- Wrapped in do...end to keep section-local state out of the main chunk's
-- 200-local budget. `meetingRecording` / `meetingStartTime` / `startMeeting` /
-- `stopMeeting` are forward-declared at module scope (near buildMenuBarMenu)
-- and re-bound here via upvalue assignment.
--------------------------------------------------------------------------------

do

local MEETINGS_DIR = CONFIG_DIR .. "/meetings"
local MEETING_CHUNK_SECONDS = 30
local meetingFfmpegTask = nil
local meetingChunkDir = WHISPER_TMP .. "/meeting_chunks"
local meetingTranscript = {}
local meetingNotepad = nil
local meetingTranscribeTimer = nil
local meetingChunkIndex = 0

-- Check if BlackHole virtual audio driver is installed
local function hasBlackHole()
    local bh = hs.audiodevice.findInputByName("BlackHole 2ch")
    return bh ~= nil
end

-- Get BlackHole device string for ffmpeg (audio-only via avfoundation)
local function getBlackHoleDevice()
    local devices = hs.audiodevice.allInputDevices()
    for _, dev in ipairs(devices) do
        if dev:name() == "BlackHole 2ch" then
            return ":BlackHole 2ch"
        end
    end
    return nil
end

-- Show BlackHole setup instructions
local function showBlackHoleSetup()
    local msg = "Meeting mode requires BlackHole (free virtual audio driver).\n\n"
        .. "Step 1: Install BlackHole\n"
        .. "  brew install blackhole-2ch\n"
        .. "  (Reboot after install)\n\n"
        .. "Step 2: Create Multi-Output Device\n"
        .. "  1. Open Audio MIDI Setup (Spotlight → 'Audio MIDI')\n"
        .. "  2. Click '+' at bottom left → Create Multi-Output Device\n"
        .. "  3. Check both your speakers/headphones AND BlackHole 2ch\n"
        .. "  4. Set this Multi-Output as your system output\n\n"
        .. "This routes audio to both your ears and BlackHole for recording."
    hs.dialog.blockAlert("Meeting Mode Setup", msg, "OK")
end

-- Notepad HTML
local function meetingNotepadHTML(meetingTitle)
    return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        background: #1a1a2e;
        color: #e0e0e0;
        display: flex;
        flex-direction: column;
        height: 100vh;
        overflow: hidden;
    }
    .header {
        padding: 10px 14px;
        background: #16213e;
        border-bottom: 1px solid #0f3460;
        display: flex;
        justify-content: space-between;
        align-items: center;
        flex-shrink: 0;
    }
    .header h2 {
        font-size: 13px;
        color: #e94560;
        font-weight: 600;
    }
    .timer {
        font-size: 12px;
        color: #888;
        font-family: monospace;
    }
    .tabs {
        display: flex;
        background: #16213e;
        border-bottom: 1px solid #0f3460;
        flex-shrink: 0;
    }
    .tab {
        padding: 6px 14px;
        font-size: 12px;
        cursor: pointer;
        color: #888;
        border-bottom: 2px solid transparent;
    }
    .tab.active {
        color: #e94560;
        border-bottom-color: #e94560;
    }
    .tab:hover { color: #ccc; }
    .panel {
        flex: 1;
        display: none;
        overflow: hidden;
    }
    .panel.active { display: flex; flex-direction: column; }
    #notes {
        flex: 1;
        background: #1a1a2e;
        color: #e0e0e0;
        border: none;
        padding: 12px 14px;
        font-size: 13px;
        line-height: 1.5;
        resize: none;
        outline: none;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
    }
    #notes::placeholder { color: #555; }
    #transcript {
        flex: 1;
        padding: 12px 14px;
        font-size: 12px;
        line-height: 1.6;
        overflow-y: auto;
        color: #bbb;
        white-space: pre-wrap;
    }
    .chunk {
        margin-bottom: 8px;
        padding-bottom: 8px;
        border-bottom: 1px solid #222;
    }
    .chunk-time {
        font-size: 10px;
        color: #e94560;
        margin-bottom: 2px;
    }
    .status {
        padding: 4px 14px;
        font-size: 11px;
        color: #555;
        background: #16213e;
        border-top: 1px solid #0f3460;
        flex-shrink: 0;
    }
</style>
</head>
<body>
    <div class="header">
        <h2>]] .. meetingTitle .. [[</h2>
        <span class="timer" id="timer">0:00</span>
    </div>
    <div class="tabs">
        <div class="tab active" onclick="switchTab('notes')">My Notes</div>
        <div class="tab" onclick="switchTab('transcript')">Live Transcript</div>
    </div>
    <div class="panel active" id="panel-notes">
        <textarea id="notes" placeholder="Type your meeting notes here...&#10;&#10;Tips:&#10;- Key decisions&#10;- Action items&#10;- Questions to follow up"></textarea>
    </div>
    <div class="panel" id="panel-transcript">
        <div id="transcript"></div>
    </div>
    <div class="status" id="status">Recording from BlackHole 2ch...</div>
<script>
    function switchTab(name) {
        document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
        document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
        document.querySelector('.tab[onclick*="' + name + '"]').classList.add('active');
        document.getElementById('panel-' + name).classList.add('active');
    }

    // Timer
    let startTime = Date.now();
    setInterval(() => {
        let elapsed = Math.floor((Date.now() - startTime) / 1000);
        let min = Math.floor(elapsed / 60);
        let sec = elapsed % 60;
        document.getElementById('timer').textContent = min + ':' + (sec < 10 ? '0' : '') + sec;
    }, 1000);

    // Called from Lua to append transcript chunks
    function appendTranscript(time, text) {
        let div = document.createElement('div');
        div.className = 'chunk';
        div.innerHTML = '<div class="chunk-time">' + time + '</div>' + text;
        let container = document.getElementById('transcript');
        container.appendChild(div);
        container.scrollTop = container.scrollHeight;
    }

    function setStatus(msg) {
        document.getElementById('status').textContent = msg;
    }

    function getNotes() {
        return document.getElementById('notes').value;
    }
</script>
</body>
</html>]]
end

-- Create and show the notepad window
local function showMeetingNotepad()
    if meetingNotepad then meetingNotepad:delete(); meetingNotepad = nil end

    local screen = hs.screen.mainScreen():frame()
    local w, h = 380, 500
    local x = screen.x + screen.w - w - 20
    local y = screen.y + 60

    local title = os.date("Meeting — %H:%M")

    meetingNotepad = hs.webview.new({ x = x, y = y, w = w, h = h })
    meetingNotepad:windowStyle({ "titled", "closable", "resizable", "miniaturizable" })
    meetingNotepad:level(hs.canvas.windowLevels.floating)
    meetingNotepad:allowTextEntry(true)
    meetingNotepad:windowTitle("Meeting Notes")
    meetingNotepad:html(meetingNotepadHTML(title))
    meetingNotepad:show()
    meetingNotepad:bringToFront()
end

-- Get user notes from the notepad
local function getMeetingNotes(callback)
    if not meetingNotepad then callback(""); return end
    meetingNotepad:evaluateJavaScript("getNotes()", function(result, err)
        callback(result or "")
    end)
end

-- Append a transcript chunk to the notepad
local function appendTranscriptToNotepad(timeStr, text)
    if not meetingNotepad then return end
    local escaped = text:gsub("\\", "\\\\"):gsub("'", "\\'"):gsub("\n", "\\n"):gsub("\r", "")
    local timeEscaped = timeStr:gsub("'", "\\'")
    meetingNotepad:evaluateJavaScript("appendTranscript('" .. timeEscaped .. "', '" .. escaped .. "')")
end

local function setNotepadStatus(msg)
    if not meetingNotepad then return end
    local escaped = msg:gsub("\\", "\\\\"):gsub("'", "\\'")
    meetingNotepad:evaluateJavaScript("setStatus('" .. escaped .. "')")
end

-- Transcribe a meeting chunk
local function transcribeMeetingChunk(chunkPath, chunkIdx)
    local elapsed = math.floor(hs.timer.secondsSinceEpoch() - meetingStartTime)
    local min = math.floor(elapsed / 60)
    local sec = elapsed % 60
    local timeStr = string.format("%d:%02d", min, sec)

    local model = getModelPath()
    local task = hs.task.new(WHISPER_BIN, function(code, stdout, stderr)
        if code ~= 0 then
            log("meeting: transcription failed for chunk " .. chunkIdx)
            return
        end
        local text = stdout:gsub("%[.*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if text ~= "" and not isHallucination(text) then
            table.insert(meetingTranscript, { time = timeStr, text = text })
            appendTranscriptToNotepad(timeStr, text)
            log("meeting: chunk " .. chunkIdx .. " → " .. #text .. " chars")
        end
    end, {
        "-m", model,
        "-f", chunkPath,
        "--no-prints",
        "-t", "4",
    })
    task:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
    task:start()
end

-- Check for new meeting chunks and transcribe them
local function processMeetingChunks()
    if not meetingRecording then return end
    local chunks = {}
    local ok, iter, dir = pcall(hs.fs.dir, meetingChunkDir)
    if not ok then return end
    for file in iter, dir do
        if file:match("%.wav$") then table.insert(chunks, file) end
    end
    table.sort(chunks)

    -- Transcribe any new chunks (skip the last one, it's still being written)
    for i, chunk in ipairs(chunks) do
        if i > meetingChunkIndex and i < #chunks then
            meetingChunkIndex = i
            transcribeMeetingChunk(meetingChunkDir .. "/" .. chunk, i)
        end
    end
end

-- Save meeting output as markdown
local function saveMeetingOutput(notes, callback)
    os.execute("mkdir -p '" .. MEETINGS_DIR .. "'")
    local filename = os.date("%Y-%m-%d-%H%M") .. ".md"
    local filepath = MEETINGS_DIR .. "/" .. filename

    -- Build transcript text
    local transcriptText = ""
    for _, chunk in ipairs(meetingTranscript) do
        transcriptText = transcriptText .. "[" .. chunk.time .. "] " .. chunk.text .. "\n\n"
    end

    -- Build the markdown
    local md = "# Meeting Notes — " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"

    if notes and notes:gsub("%s+", "") ~= "" then
        md = md .. "## My Notes\n\n" .. notes .. "\n\n"
    end

    if transcriptText ~= "" then
        md = md .. "## Transcript\n\n" .. transcriptText
    end

    -- Try to summarize with Ollama
    if getRefineMode() and hasOllama() and #transcriptText > 100 then
        setNotepadStatus("Generating summary with Ollama...")
        local summaryPrompt = "Summarize this meeting transcript into: 1) Key Points (bullet list), 2) Action Items (bullet list), 3) Decisions Made (bullet list). Be concise. Output ONLY the summary in markdown format.\n\n" .. transcriptText:sub(1, 4000)
        local jsonPayload = hs.json.encode({
            model = getRefineModel(),
            prompt = summaryPrompt,
            stream = false,
        })
        local tmpPayload = WHISPER_TMP .. "/meeting_summary_payload.json"
        local f = io.open(tmpPayload, "w")
        if f then f:write(jsonPayload); f:close() end
        local task = hs.task.new("/usr/bin/curl", function(code, stdout, stderr)
            if code == 0 and stdout and #stdout > 0 then
                local ok, result = pcall(hs.json.decode, stdout)
                if ok and result and result.response then
                    local summary = result.response:gsub("^%s+", ""):gsub("%s+$", "")
                    if summary ~= "" then
                        md = "# Meeting Notes — " .. os.date("%Y-%m-%d %H:%M") .. "\n\n"
                            .. "## Summary\n\n" .. summary .. "\n\n"
                        if notes and notes:gsub("%s+", "") ~= "" then
                            md = md .. "## My Notes\n\n" .. notes .. "\n\n"
                        end
                        md = md .. "## Full Transcript\n\n" .. transcriptText
                        log("meeting: summary generated (" .. #summary .. " chars)")
                    end
                end
            end
            -- Save regardless of summary success
            local fout = io.open(filepath, "w")
            if fout then fout:write(md); fout:close() end
            log("meeting: saved to " .. filepath)
            setNotepadStatus("Saved to " .. filepath)
            callback(filepath)
        end, {
            "-s", "-X", "POST",
            "http://localhost:11434/api/generate",
            "-H", "Content-Type: application/json",
            "-d", "@" .. tmpPayload,
            "--max-time", "60",
        })
        task:setEnvironment({ HOME = HOME, PATH = "/usr/bin:/bin" })
        task:start()
    else
        local fout = io.open(filepath, "w")
        if fout then fout:write(md); fout:close() end
        log("meeting: saved to " .. filepath)
        setNotepadStatus("Saved to " .. filepath)
        callback(filepath)
    end
end

-- Start meeting recording
startMeeting = function()
    if meetingRecording then return end
    if not hasBlackHole() then
        showBlackHoleSetup()
        return
    end

    meetingRecording = true
    meetingStartTime = hs.timer.secondsSinceEpoch()
    meetingTranscript = {}
    meetingChunkIndex = 0

    os.execute("rm -rf '" .. meetingChunkDir .. "'")
    os.execute("mkdir -p '" .. meetingChunkDir .. "'")

    log("meeting: start")

    -- Show notepad
    showMeetingNotepad()

    -- Start recording from BlackHole
    local bhDevice = getBlackHoleDevice()
    meetingFfmpegTask = hs.task.new(FFMPEG, function(code, out, err)
        log("meeting: ffmpeg exited " .. tostring(code))
    end, {
        "-f", "avfoundation", "-i", bhDevice,
        "-ac", "1", "-ar", "16000",
        "-f", "segment", "-segment_time", tostring(MEETING_CHUNK_SECONDS),
        "-segment_format", "wav",
        meetingChunkDir .. "/chunk_%04d.wav"
    })
    meetingFfmpegTask:setEnvironment({ HOME = HOME, PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" })
    meetingFfmpegTask:start()

    -- Periodically check for new chunks and transcribe
    meetingTranscribeTimer = hs.timer.doEvery(MEETING_CHUNK_SECONDS + 2, processMeetingChunks)

    updateMenuBar()
    hs.notify.new({ title = "Thinking Out Loud", informativeText = "Meeting recording started" }):send()
end

-- Stop meeting recording
stopMeeting = function()
    if not meetingRecording then return end
    meetingRecording = false
    log("meeting: stop")

    -- Stop ffmpeg
    if meetingFfmpegTask and meetingFfmpegTask:isRunning() then
        meetingFfmpegTask:interrupt()
    end
    meetingFfmpegTask = nil

    -- Stop transcription timer
    if meetingTranscribeTimer then meetingTranscribeTimer:stop(); meetingTranscribeTimer = nil end

    -- Process any remaining chunks
    setNotepadStatus("Transcribing final chunks...")
    hs.timer.doAfter(2, function()
        -- Transcribe remaining chunks
        meetingChunkIndex = 0  -- reset to process all
        local chunks = {}
        local ok, iter, dir = pcall(hs.fs.dir, meetingChunkDir)
        if ok then
            for file in iter, dir do
                if file:match("%.wav$") then table.insert(chunks, file) end
            end
        end
        table.sort(chunks)

        -- Count already-transcribed chunks and only do remaining
        local alreadyDone = #meetingTranscript
        local remaining = #chunks - alreadyDone
        if remaining > 0 then
            setNotepadStatus("Transcribing " .. remaining .. " remaining chunks...")
        end

        -- Wait a bit for final transcriptions, then save
        local waitTime = math.max(remaining * 3, 2)
        hs.timer.doAfter(waitTime, function()
            getMeetingNotes(function(notes)
                saveMeetingOutput(notes, function(filepath)
                    updateMenuBar()
                    hs.notify.new({
                        title = "Meeting notes saved",
                        informativeText = filepath,
                    }):send()
                end)
            end)
        end)
    end)

    updateMenuBar()
end

end -- end of Meeting mode do-block

--------------------------------------------------------------------------------
-- Startup
--------------------------------------------------------------------------------

-- Request mic permission (child processes via hs.task inherit it)
if type(hs.microphoneState) == "function" and not hs.microphoneState() then
    log("requesting microphone permission")
    hs.microphoneState(true)
end

-- Create default preferred langs file if it doesn't exist
if readFile(P.preferredLangsFile) == "" then
    writeFile(P.preferredLangsFile, "en,pt")
end

-- Global hotkey: Cmd+Shift+H opens the history dashboard from anywhere.
hs.hotkey.bind({"cmd", "shift"}, "H", function() openDashboard() end)

-- Create menu bar icon
createMenuBar()

-- Load action hooks
local actionsEnabled = loadActionConfig() ~= nil
log("actions: " .. (actionsEnabled and "enabled" or "disabled"))

local enterStatus = getEnterMode() and "⏎" or ""
local actionsFlag = actionsEnabled and " +actions" or ""
log("loaded (trigger=" .. TRIGGER_KEY .. ", lang=" .. getLang() .. ", output=" .. getOutputMode() .. ", model=" .. getModelName() .. ", preferred=" .. table.concat(getPreferredLangs(), ",") .. ")")
hs.notify.new({
    title = "Thinking Out Loud",
    informativeText = "Loaded (" .. getLang():upper() .. " / " .. getOutputMode():upper() .. enterStatus .. " / " .. getModelName() .. actionsFlag .. ") — hold " .. TRIGGER_KEY
}):send()

--------------------------------------------------------------------------------
-- Optional personal extensions. Any .lua file alongside init.lua can be loaded
-- here. pcall() keeps the dictation core running even if a module is missing
-- or throws on load.
--------------------------------------------------------------------------------
pcall(require, "term_launcher")
