VERSION = "0.0.1"

local micro   = import("micro")
local config  = import("micro/config")
local strings = import("strings")
local util    = import("micro/util")

---@type string Plugin name
local plugName = "gutter_message"
---@module 'tooltip'
local TooltipModule = nil

--NOTE: Top-level call to load the colorscheme without errors.
config.AddRuntimeFile(plugName, config.RTColorscheme, "colorscheme/gutter-message.micro")

local function log(...)
    -- micro.Log("[" .. plugName .. "]", unpack(arg))
end

---Creates tables for completions and suggestions using the plugin’s options
---`opts` and the last argument, which may be partial.
---@param opts table  List of options for the plugin.
---@param lastArg string  Last argument (may be partial).
---@return table<string>, table<string> -- completions and suggestions
local function CompleteOpts(opts, lastArg)
    local suggestions = {}
    local completions = {}

    for i=1,#opts do
        local opt = opts[i]
        local optPrefix = string.sub(opt, 1, #lastArg)

        if optPrefix > lastArg then break end

        local startIdx, endIdx = string.find(opt, lastArg, 1, true)
        if endIdx and startIdx == 1 then
            local completion = string.sub(opt, endIdx + 1, #opt)
            table.insert(completions, completion)
            table.insert(suggestions, opt)
        end
    end

    return completions, suggestions
end

---@class (exact) Plugin Keeps the state of the plugin.
---@field tooltip Tooltip | nil Only instance for tooltip.
---@field name string Tooltip's buffer name.
---@field gutterMsgs table | nil Copy (sorted and merged) on Lua side of the Messages[] from Micro.
---@field msgIdx number | nil Index in gutterMsgs, Message to display.
local Plugin = {
    tooltip = nil,
    name = "Gutter Message",
    gutterMsgs = nil,
    msgIdx = nil
}

---Reset the plugin state. Closes the tooltip only if it exists and is not already closing.
---@param from string Name of the function that calls this function.
local function PluginReset(from)
    log("PluginReset from", from)
    if Plugin.tooltip and not Plugin.tooltip:IsClosing() then
        Plugin.tooltip = Plugin.tooltip:Close()
    end
    Plugin.gutterMsgs = nil
    Plugin.msgIdx = nil
end

---@enum (key) GoDirection
---Direction to go in `GoMessageFromCurrentLoc()`
local GODIRECTION = { NEXT = 1, PREV = -1}

---Sorts messages by line and column, merging them if they are in the same location.
---@param msgs Message[] Messages from the Buffer.
---@return Message[] List of Messages (same structure as the input).
local function SortAndMergeMsgs(msgs)
    local msgsTable = {}
    for i = 1, #msgs do
        local msg = msgs[i]
        table.insert(msgsTable, {
            Msg   = msg.Msg,
            Start = { X = msg.Start.X, Y = msg.Start.Y},
            End   = { X = msg.End.X,   Y = msg.End.Y},
            Kind  = msg.Kind,
            Owner = msg.Owner,
        })
    end

    table.sort(msgsTable, function (a, b) --start to end
        local aS = a.Start
        local bS = b.Start
        return aS.Y < bS.Y or (aS.Y == bS.Y and aS.X < bS.X)
    end)

    --merge any messages with the same Start
    local i = 1
    while i < #msgsTable - 1 do
        if msgsTable[i].Start.X == msgsTable[i+1].Start.X and
           msgsTable[i].Start.Y == msgsTable[i+1].Start.Y
        then
            --NOTE: Use spaces around "\n" to split later by " "
            msgsTable[i].Msg = "* " .. msgsTable[i].Msg .. " \n " ..
                               "* " .. table.remove(msgsTable, i + 1).Msg
        end
        i = i + 1
    end

    return msgsTable
end

---Checks if the BufPane `bp` has any messages
---@param bp BufPane The BufPane to check for messages.
---@return boolean `true` if `bp` has messages, `false` otherwise.
local function HasMessages(bp)
    return bp and bp.Buf.Messages and #bp.Buf.Messages > 0
end

---Go to the following message in the `bp` BufPane in the specified `direction`,
---starting from the given location `loc`.
---@param bp BufPane The BufPane to search.
---@param loc Loc The starting location.
---@param direction GoDirection The direction in which to search for the message.
---@return boolean `true` if a message was found, `false` otherwise.
local function GoMessageFromCurrentLoc(bp, loc, direction)
    if not HasMessages(bp) then
        PluginReset("GoMessageFromCurrentLoc")
        return false
    end

    Plugin.gutterMsgs = SortAndMergeMsgs(bp.Buf.Messages)

    local msgIdx = nil
    local start, stop, condition
    if direction == GODIRECTION.NEXT then
        start, stop = 1, #Plugin.gutterMsgs
        condition = function(cl, ml) --current and message locations
            return cl.Y < ml.Y or (cl.Y == ml.Y and cl.X < ml.X)
        end
    elseif direction == GODIRECTION.PREV then
        start, stop = #Plugin.gutterMsgs, 1
        condition = function(cl, ml) --current and message locations
            return cl.Y > ml.Y or (cl.Y == ml.Y and cl.X > ml.X)
        end
    else error("Invalid direction value") end

    for i = start, stop, direction do
        if condition(loc, Plugin.gutterMsgs[i].Start) then
            msgIdx = i; break
        end
    end

    if not msgIdx then msgIdx = start end

    bp.Cursor:GotoLoc(Plugin.gutterMsgs[msgIdx].Start)
    bp:Center() -- >> bp:Relocate()
    Plugin.msgIdx = msgIdx
    return true
end

---Go to the previous message in the `bp` BufPane.
---@param bp BufPane The BufPane to navigate through.
local function PrevMessage(bp)
    local curLoc = bp.Cursor.Loc
    if not GoMessageFromCurrentLoc(bp, -curLoc, GODIRECTION.PREV) then
        micro.InfoBar():Error(string.format("%s: No messages in %s", plugName, bp:Name()))
        return false
    end
    return true
end

---Go to the next message in the `bp` BufPane.
---@param bp BufPane The BufPane to navigate through.
local function NextMessage(bp)
    local curLoc = bp.Cursor.Loc
    if not GoMessageFromCurrentLoc(bp, -curLoc, GODIRECTION.NEXT) then
        micro.InfoBar():Error(string.format("%s: No messages in %s", plugName, bp:Name()))
        return false
    end
    return true
end

---Checks if the current line has a message.
---@param bp BufPane The BufPane to check for messages.
---@return boolean `true` if the current line has a message, `false` otherwise.
local function HasCurrentLineMessage(bp)
    assert(bp)
    if not bp.Buf.Messages then return false end
    if not Plugin.gutterMsgs then
        Plugin.gutterMsgs = SortAndMergeMsgs(bp.Buf.Messages)
    end

    local curLine = bp.Cursor.Loc.Y
    for i = 1,#Plugin.gutterMsgs do
        if Plugin.gutterMsgs[i].Start.Y == curLine then
            Plugin.msgIdx = i
            return true
        end
    end
    Plugin.msgIdx = nil
    return false
end

---Generate the header message (owner + kind).
---@param msg Message The gutter message to format.
---@return string # The formatted message.
local function HeaderFromMessage(msg)
    assert(msg)
    local MESSAGE = { INFO = 0, WARN = 1, ERROR = 2 }
    local typeStr
    if     msg.Kind == MESSAGE.INFO  then typeStr = "INFO"
    elseif msg.Kind == MESSAGE.WARN  then typeStr = "WARN"
    elseif msg.Kind == MESSAGE.ERROR then typeStr = "ERROR"
    else error("unknown kind of MsgType.") end
    return string.format("[%s] %s", typeStr, msg.Owner)
end

---Displays the tooltip with the message formatted.
---@param bp BufPane The BufPane where the tooltip will be displayed.
---@param chained boolean Indicates if the function is called in a chain with Next/PrevMessage().
local function DisplayMessage(bp, chained)
    if not Plugin.msgIdx or not chained then
        if not HasCurrentLineMessage(bp) then
            micro.InfoBar():Error(plugName..": No message in current line")
            return
        end
    end

    local screen = TooltipModule.ScreenSize()
    local minTooltipWidth = math.floor(screen.Width / 3)
    local maxTooltipWidth = screen.Width - 4 -- minus 4 columns for example

    local gutterMsg = Plugin.gutterMsgs[Plugin.msgIdx]
    local header = HeaderFromMessage(gutterMsg)
    local headerLen = util.CharacterCountInString(header)
    --NOTE: `linter` plugin only returns 1 line as Msg
    local messageLen = util.CharacterCountInString(gutterMsg.Msg)
    local longestLine = headerLen < messageLen and messageLen or headerLen

    local cursorScreen = TooltipModule.ScreenLocFromBufLoc(bp, gutterMsg.Start)

    local spaceRight = screen.Width - cursorScreen.X
    local shiftX = 0
    local width
    if spaceRight < minTooltipWidth then log("spaceRight: too small, shiftX + min")
        width = minTooltipWidth
        --Shift to match right top corner with the location provided
        shiftX = -(width - 1)
    elseif spaceRight > maxTooltipWidth then log("spaceRight: too big")
        width = maxTooltipWidth
    else log("spaceRight: enough")
        width = spaceRight
    end

    -- NOTE now we split longestLine if needed!
    local message
    local tooltipHeight
    local splitMessage = longestLine > width and true or false
    if not splitMessage then
        message = gutterMsg.Msg
        tooltipHeight = 3 -- 1:header + 1:msg + 1:statusline

    else
        local msgWordsArray = strings.SplitAfter(gutterMsg.Msg, " ")

        local words = {}
        local breaks = {}
        local lastValidIdx = 1
        local currentLen = 0
        for i = 1, #msgWordsArray do
            local len = util.CharacterCountInString(msgWordsArray[i])
            currentLen = currentLen + len

            if len == 2 and string.sub(msgWordsArray[i], 1, 1) == "\n" then
                msgWordsArray[i] = ""
                table.insert(breaks, lastValidIdx)
                currentLen = 0
            end

            if currentLen > width - 1 then --NOTE -1 make space for \n for concat
                table.insert(breaks, lastValidIdx)
                currentLen = len
            else
                lastValidIdx = i
            end

            table.insert(words, msgWordsArray[i])
        end

        local idx = 1
        local msgLines = {}
        local msgLineLengths = {}
        for _, br in ipairs(breaks) do
            local line = table.concat(words, "", idx, br)
            line = strings.TrimRight(line, " ")
            local lineLen = util.CharacterCountInString(line)
            table.insert(msgLines, line)
            table.insert(msgLineLengths, lineLen)
            idx = br + 1
        end

        --last line remaining
        local line = table.concat(words, "", idx, #words)
        local lineLen = util.CharacterCountInString(line)
        table.insert(msgLines, line)
        table.insert(msgLineLengths, lineLen)

        longestLine = math.max(unpack(msgLineLengths))
        assert(longestLine < width - 1, "leave space for \n to line concat")

        local lineCount = #msgLines
        for i = 1, lineCount do
            local pad = longestLine - msgLineLengths[i]
            msgLines[i] = msgLines[i] .. string.rep(" ", pad)
        end

        tooltipHeight = 2 + lineCount -- 1:header + 1:statusline + lineCount
        message = table.concat(msgLines, "\n")
    end

    local tooltipWidth = longestLine + 1 -- + 1 space for \n

    local shiftY
    local spaceAbove = cursorScreen.Y
    local spaceBelow = screen.Height - cursorScreen.Y
    if tooltipHeight > spaceBelow then log("tooltipHeight: doesnt fit below")
        if tooltipHeight > spaceAbove then log("tooltipHeight: doesnt fit above")
            if spaceAbove > math.floor(spaceBelow * 1.5) then
                log("tooltipHeight: fit above")
                shiftY = -(tooltipHeight)
                tooltipHeight = spaceAbove
            else log("tooltipHeight: fit below")
                tooltipHeight = spaceBelow
                shiftY = 1
            end
        else log("tooltipHeight: does fit above")
            shiftY = -(tooltipHeight)
        end
    else log("tooltipHeight: does fit below")
        shiftY = 1
    end

    local tooltipText = string.format("%s%s\n%s",
        header, string.rep(" ", longestLine - headerLen),
        message
    )

    assert(not Plugin.tooltip, "tooltip should arrive as nil")
    Plugin.tooltip = TooltipModule.Tooltip.new(
        Plugin.name, tooltipText,
        cursorScreen.X + shiftX, cursorScreen.Y + shiftY,
        tooltipWidth, tooltipHeight, {
            ["diff"] = false,
            ["ruler"] = false,
            ["filetype"] = "gutter-message", --NOTE: MUST be equal to syntax value
            ["softwrap"] = true,
            ["diffgutter"] = false,
            ["statusline"] = false,
            ["statusformatl"] = "$(filename)",
            ["statusformatr"] = "",
    })
end

---Options and actions available for the plugin.
local PluginActions = {
    ["display"] = function (bp) DisplayMessage(bp, false) end,
    ["dnext"]   = function (bp) local _ = NextMessage(bp) and DisplayMessage(bp, true) end,
    ["dprev"]   = function (bp) local _ = PrevMessage(bp) and DisplayMessage(bp, true) end,
    ["next"]    = function (bp) NextMessage(bp) end,
    ["prev"]    = function (bp) PrevMessage(bp) end,
}

---Plugin entry point.
---@param bp BufPane
---@param args userdata
function PluginEntry(bp, args)
    if not bp then return end

    --NOTE: This is to enable the execution of the plugin when inside the tooltip.
    if Plugin.tooltip then
        assert(Plugin.tooltip:IsTooltip(bp), "If tooltip is open we MUST be inside Tooltip.")
        local origin = Plugin.tooltip.origin
        Plugin.tooltip = Plugin.tooltip:Close()
        PluginEntry(origin, args)
        return
    end

    local argc = #args
    if argc == 0 then --assume NextMessage
        NextMessage(bp)
    elseif argc == 1 then
        local opt = args[1]

        local action = PluginActions[opt]
        if not action then
            local format = "%s: Unknown option (%s). See `> help %s`"
            micro.InfoBar():Error(string.format(format, plugName, opt, plugName))
            return
        end
        action(bp)
    else
        local format = "%s: Wrong number of arguments (%d). See `> help %s`"
        micro.InfoBar():Error(string.format(format, plugName, argc, plugName))
    end
end


---Plugin option completer
---@param buf Buffer InfoBar's Buffer
---@return table<string>, table<string> # completions and suggestions
local function PluginCompleter(buf)
    local opts = {}

    --Do NOT autocomplete after first argument
    local args = strings.Split(buf:Line(0), " ")
    if #args > 2 then return nil, nil end

    for k, _ in pairs(PluginActions) do table.insert(opts, k) end
    table.sort(opts)
    return CompleteOpts(opts, buf:GetArg())
end

function init()
    package.path = config.ConfigDir .. "/plug/?.lua;" .. package.path
    config.MakeCommand(plugName, PluginEntry, PluginCompleter)
    config.AddRuntimeFile(plugName, config.RTSyntax, "syntax/gutter-message.yaml")
    TooltipModule = require('micro-gutter-message.tooltip')
end

---If we are quitting the tooltip's BufPane, we intercept Quit() and use Tooltip:Close().
---@param bp BufPane
---@return boolean `true` if the Quit action should proceed, `false` otherwise.
function preQuit(bp)
    if not bp then return true end
    if not Plugin.tooltip or Plugin.tooltip:IsClosing() then
        return true -- Continue
    end

    if Plugin.tooltip:IsTooltip(bp) then
        Plugin.tooltip = Plugin.tooltip:Close()
        return false -- Cancel
    end
end

---If the tooltip exists and is not closing, close it.
---@param from string The name of the caller function.
local function IfTooltipCloseIt(from)
    log("IfTooltipCloseIt from: ", from)
    if Plugin.tooltip and not Plugin.tooltip:IsClosing() then
        Plugin.tooltip = Plugin.tooltip:Close()
    end
end

-- NOTE: MouseWheel*() do not have any effect.
-- NOTE: Mouse scroll does not work inside the tooltip. This is likely due to
-- the tree node and being over a BufPane with a higher "priority" index, which
-- is the one that receives the scroll events.

function onScrollUp(_)   IfTooltipCloseIt("onScrollUp") end
function onScrollDown(_) IfTooltipCloseIt("onScrollDown") end

--Close the tooltip when entering Shell/Command mode (inside InfoBar) or ESC.

function onShellMode(_)   IfTooltipCloseIt("onShellMode") end
function onCommandMode(_) IfTooltipCloseIt("onCommandMode") end
function onEscape(_)      IfTooltipCloseIt("onEscape") end

---Close the tooltip before adding a Tab. It seems that I cannot catch the events
---with `onAnyEvent`. Do not reset the plugin; this will occur in other actions.
function preAddTab(_) IfTooltipCloseIt("preAddTab"); return true end

--Reset the plugin when the BufPane is changed (tabs or splits). If the buffer is
--replaced, we need to save it to run the linter, so the plugin will be reset as well.

function onPreviousTab(_)   PluginReset("onPreviousTab") end
function onNextTab(_)       PluginReset("onNextTab") end
function onNextSplit(_)     PluginReset("onNextSplit") end
function onPreviousSplit(_) PluginReset("onPreviousSplit") end
function onUnsplit(_)       PluginReset("onUnsplit") end

---NOTE: This is mandatory to handle; otherwise, the Vsplit will be created
---inside the Tooltip, resulting in an Hsplit. `onAnyEvent()` catches this too late.
---@param bp BufPane
function preVSplit(bp)
    if Plugin.tooltip and Plugin.tooltip:IsTooltip(bp) then
        IfTooltipCloseIt("preVSplit");
        return false -- NOTE: true here crashes micro
    end
    return true
end

---@param bp BufPane
function preHSplit(bp)
    if Plugin.tooltip and Plugin.tooltip:IsTooltip(bp) then
        IfTooltipCloseIt("preHSplit");
        return false -- NOTE: true here crashes micro
    end
    return true
end

---Reset the plugin when the buffer is opened and it is not a tooltip or a new one.
---@param buf Buffer
function onBufferOpen(buf)
    local bufName = buf:GetName()
    if bufName ~= Plugin.name and bufName ~= "No name" then
        PluginReset("onBufferOpen")
    end
end

-- I can not detect `RunInteractiveShell` nor Screen termination...
-- but I can detect executed actions for `command:` and `command-edit:` with
-- pre()` because the name asigned to is an empty string ;)
-- NOTE: the redraw of the tooltip has beend remove because this is always
-- triggered when a command is called, so we cannot reuse anymore the BufPane
-- between calls.
function pre(_) IfTooltipCloseIt("pre") end

---When a buffer is saved, the linter is executed again, so gutter messages may
---change (reset `gutterMsgs`). If `save` is executed in the tooltip, do not reset.
---@param bp BufPane
function onSave(bp)
    if bp and Plugin.tooltip and Plugin.tooltip:IsTooltip(bp) then return end
    PluginReset("onSave")
end

function preMousePress(bp)
    if Plugin.tooltip and not Plugin.tooltip:IsClosing() then
        Plugin.tooltip = Plugin.tooltip:Close()
        return false
    end
    return true
end

function preMouseMultiCursor(_)
    if Plugin.tooltip and not Plugin.tooltip:IsClosing() then
        Plugin.tooltip = Plugin.tooltip:Close()
        return false
    end
    return true
end
