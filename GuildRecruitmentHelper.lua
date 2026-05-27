local addonName = ...

local frame = CreateFrame("Frame", "GuildRecruitmentHelperFrame")
local state = {
    db = nil,
    isSpamming = false,
    whisperSessions = {},
    selectedChannelKey = nil,
    selectedApplicant = nil,
}

local defaults = {
    questions = {
        "What class/spec do you play?",
        "What raid days and times can you attend?",
        "Tell us briefly about your raiding experience.",
    },
}

local COMMAND_APPLY = "!apply"
local COMMAND_NEXT = "!next"

local function EnsureDB()
    if not GuildRecruitmentHelperDB then
        GuildRecruitmentHelperDB = {}
    end

    if type(GuildRecruitmentHelperDB.channelConfigs) ~= "table" then
        GuildRecruitmentHelperDB.channelConfigs = {}
    end

    if type(GuildRecruitmentHelperDB.applications) ~= "table" then
        GuildRecruitmentHelperDB.applications = {}
    end

    if type(GuildRecruitmentHelperDB.questions) ~= "table" or #GuildRecruitmentHelperDB.questions == 0 then
        GuildRecruitmentHelperDB.questions = {}
        for i = 1, #defaults.questions do
            GuildRecruitmentHelperDB.questions[i] = defaults.questions[i]
        end
    end

    state.db = GuildRecruitmentHelperDB
end

local function Trim(text)
    if not text then
        return ""
    end

    return text:match("^%s*(.-)%s*$") or ""
end

local function EnumerateChannels()
    local options = {
        {
            key = "CHAT:SAY",
            label = "Say",
            mode = "CHAT",
            chatType = "SAY",
        },
        {
            key = "CHAT:YELL",
            label = "Yell",
            mode = "CHAT",
            chatType = "YELL",
        },
    }

    local channels = { GetChannelList() }
    for i = 1, #channels, 3 do
        local channelID = channels[i]
        local channelName = channels[i + 1]
        if channelID and channelName and channelName ~= "" then
            table.insert(options, {
                key = "CHANNEL:" .. channelName,
                label = "Channel - " .. channelName,
                mode = "CHANNEL",
                channelName = channelName,
            })
        end
    end

    return options
end

local function GetChannelOptionByKey(key)
    local options = EnumerateChannels()
    for i = 1, #options do
        if options[i].key == key then
            return options[i]
        end
    end
end

local function EnsureConfigForOption(option)
    local cfg = state.db.channelConfigs[option.key]
    if not cfg then
        cfg = {
            message = "",
            interval = 300,
            enabled = false,
            nextSendAt = nil,
            mode = option.mode,
            chatType = option.chatType,
            channelName = option.channelName,
        }
        state.db.channelConfigs[option.key] = cfg
    else
        cfg.mode = option.mode
        cfg.chatType = option.chatType
        cfg.channelName = option.channelName
    end

    return cfg
end

local ui = {}

local function RefreshAnswersText()
    if not ui.answersBox then
        return
    end

    if not state.selectedApplicant then
        ui.answersBox:SetText("No applicant selected.")
        return
    end

    local application = state.db.applications[state.selectedApplicant]
    if not application then
        ui.answersBox:SetText("No application found.")
        return
    end

    local lines = {}
    table.insert(lines, "Applicant: " .. state.selectedApplicant)
    local submittedLabel = "Unknown"
    if application.submittedAt then
        submittedLabel = date("%Y-%m-%d %H:%M:%S", application.submittedAt)
    end
    table.insert(lines, "Submitted: " .. submittedLabel)
    table.insert(lines, "")

    local questions = state.db.questions
    for i = 1, #questions do
        table.insert(lines, "Q" .. i .. ": " .. questions[i])
        table.insert(lines, "A" .. i .. ": " .. (application.answers[i] or ""))
        table.insert(lines, "")
    end

    ui.answersBox:SetText(table.concat(lines, "\n"))
end

local function GetSortedApplicants()
    local names = {}
    for playerName in pairs(state.db.applications) do
        table.insert(names, playerName)
    end
    table.sort(names)
    return names
end

local function RefreshApplicantDropdownText()
    if not ui.applicantDropdown then
        return
    end

    if state.selectedApplicant then
        UIDropDownMenu_SetText(ui.applicantDropdown, state.selectedApplicant)
    else
        UIDropDownMenu_SetText(ui.applicantDropdown, "Select applicant")
    end
end

local function RefreshConfigFields()
    if not state.selectedChannelKey then
        return
    end

    local option = GetChannelOptionByKey(state.selectedChannelKey)
    if not option then
        local first = EnumerateChannels()[1]
        if not first then
            return
        end
        option = first
        state.selectedChannelKey = option.key
    end

    local cfg = EnsureConfigForOption(option)
    ui.messageBox:SetText(cfg.message or "")
    ui.intervalBox:SetText(tostring(cfg.interval or 300))
    ui.enabledCheck:SetChecked(cfg.enabled and true or false)
    UIDropDownMenu_SetText(ui.channelDropdown, option.label)
end

local function InitializeUI()
    local main = CreateFrame("Frame", "GuildRecruitmentHelperMainFrame", UIParent)
    main:SetWidth(720)
    main:SetHeight(430)
    main:SetPoint("CENTER")
    main:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    main:EnableMouse(true)
    main:SetMovable(true)
    main:RegisterForDrag("LeftButton")
    main:SetScript("OnDragStart", function(self) self:StartMoving() end)
    main:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    main:Hide()
    ui.main = main

    local title = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("GuildRecruitmentHelper")

    local close = CreateFrame("Button", nil, main, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -5, -5)

    local spamHeader = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    spamHeader:SetPoint("TOPLEFT", 20, -44)
    spamHeader:SetText("Channel Spam")

    local channelLabel = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    channelLabel:SetPoint("TOPLEFT", 20, -72)
    channelLabel:SetText("Channel")

    local channelDropdown = CreateFrame("Frame", "GuildRecruitmentHelperChannelDropdown", main, "UIDropDownMenuTemplate")
    channelDropdown:SetPoint("TOPLEFT", -14, -84)
    ui.channelDropdown = channelDropdown

    local messageLabel = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    messageLabel:SetPoint("TOPLEFT", 20, -120)
    messageLabel:SetText("Message")

    local messageBox = CreateFrame("EditBox", "GuildRecruitmentHelperMessageBox", main, "InputBoxTemplate")
    messageBox:SetPoint("TOPLEFT", 20, -140)
    messageBox:SetWidth(310)
    messageBox:SetHeight(24)
    messageBox:SetAutoFocus(false)
    messageBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.messageBox = messageBox

    local intervalLabel = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    intervalLabel:SetPoint("TOPLEFT", 20, -174)
    intervalLabel:SetText("Interval (seconds)")

    local intervalBox = CreateFrame("EditBox", "GuildRecruitmentHelperIntervalBox", main, "InputBoxTemplate")
    intervalBox:SetPoint("TOPLEFT", 20, -194)
    intervalBox:SetWidth(80)
    intervalBox:SetHeight(24)
    intervalBox:SetNumeric(true)
    intervalBox:SetAutoFocus(false)
    intervalBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    ui.intervalBox = intervalBox

    local enabledCheck = CreateFrame("CheckButton", "GuildRecruitmentHelperEnabledCheck", main, "UICheckButtonTemplate")
    enabledCheck:SetPoint("TOPLEFT", 118, -194)
    _G[enabledCheck:GetName() .. "Text"]:SetText("Enabled")
    ui.enabledCheck = enabledCheck

    local saveButton = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    saveButton:SetPoint("TOPLEFT", 20, -230)
    saveButton:SetWidth(110)
    saveButton:SetHeight(24)
    saveButton:SetText("Save Config")
    saveButton:SetScript("OnClick", function()
        local key = state.selectedChannelKey
        if not key then
            return
        end

        local option = GetChannelOptionByKey(key)
        if not option then
            return
        end

        local cfg = EnsureConfigForOption(option)
        cfg.message = Trim(ui.messageBox:GetText())
        cfg.interval = tonumber(ui.intervalBox:GetText()) or 300
        if cfg.interval < 5 then
            cfg.interval = 5
        end
        cfg.enabled = ui.enabledCheck:GetChecked() and true or false
        cfg.nextSendAt = nil
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Saved channel config for " .. option.label)
    end)

    local toggleSpamButton = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    toggleSpamButton:SetPoint("TOPLEFT", 140, -230)
    toggleSpamButton:SetWidth(110)
    toggleSpamButton:SetHeight(24)
    toggleSpamButton:SetText("Start Spam")
    toggleSpamButton:SetScript("OnClick", function(self)
        state.isSpamming = not state.isSpamming
        if state.isSpamming then
            self:SetText("Stop Spam")
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Channel spam enabled.")
        else
            self:SetText("Start Spam")
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Channel spam disabled.")
        end
    end)
    ui.toggleSpamButton = toggleSpamButton

    local formsHeader = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    formsHeader:SetPoint("TOPLEFT", 370, -44)
    formsHeader:SetText("Applications")

    local applicantLabel = main:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    applicantLabel:SetPoint("TOPLEFT", 370, -72)
    applicantLabel:SetText("Applicant")

    local applicantDropdown = CreateFrame("Frame", "GuildRecruitmentHelperApplicantDropdown", main, "UIDropDownMenuTemplate")
    applicantDropdown:SetPoint("TOPLEFT", 336, -84)
    ui.applicantDropdown = applicantDropdown

    local scrollFrame = CreateFrame("ScrollFrame", "GuildRecruitmentHelperAnswersScrollFrame", main, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 370, -126)
    scrollFrame:SetWidth(320)
    scrollFrame:SetHeight(260)
    ui.answersScrollFrame = scrollFrame

    local answersBox = CreateFrame("EditBox", "GuildRecruitmentHelperAnswersBox", scrollFrame)
    answersBox:SetMultiLine(true)
    answersBox:SetFontObject(ChatFontNormal)
    answersBox:SetWidth(300)
    answersBox:SetAutoFocus(false)
    answersBox:EnableMouse(true)
    answersBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scrollFrame:SetScrollChild(answersBox)
    ui.answersBox = answersBox

    local refreshFormsButton = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    refreshFormsButton:SetPoint("TOPLEFT", 370, -392)
    refreshFormsButton:SetWidth(120)
    refreshFormsButton:SetHeight(24)
    refreshFormsButton:SetText("Refresh Forms")
    refreshFormsButton:SetScript("OnClick", function()
        RefreshApplicantDropdownText()
        RefreshAnswersText()
    end)

    UIDropDownMenu_Initialize(channelDropdown, function(self, level)
        local options = EnumerateChannels()
        for i = 1, #options do
            local option = options[i]
            local info = UIDropDownMenu_CreateInfo()
            info.text = option.label
            info.value = option.key
            info.func = function()
                state.selectedChannelKey = option.key
                UIDropDownMenu_SetText(channelDropdown, option.label)
                RefreshConfigFields()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)

    UIDropDownMenu_Initialize(applicantDropdown, function(self, level)
        local applicants = GetSortedApplicants()
        for i = 1, #applicants do
            local applicant = applicants[i]
            local info = UIDropDownMenu_CreateInfo()
            info.text = applicant
            info.value = applicant
            info.func = function()
                state.selectedApplicant = applicant
                UIDropDownMenu_SetText(applicantDropdown, applicant)
                RefreshAnswersText()
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
end

local function SendConfiguredMessage(cfg)
    if cfg.mode == "CHAT" and cfg.chatType then
        SendChatMessage(cfg.message, cfg.chatType)
        return true
    end

    if cfg.mode == "CHANNEL" and cfg.channelName then
        local channelID = GetChannelName(cfg.channelName)
        if channelID and channelID > 0 then
            SendChatMessage(cfg.message, "CHANNEL", nil, channelID)
            return true
        end
    end

    return false
end

local function TickSpammer(elapsed)
    if not state.isSpamming then
        return
    end

    local now = GetTime()
    for _, cfg in pairs(state.db.channelConfigs) do
        if cfg.enabled and cfg.message and cfg.message ~= "" and cfg.interval and cfg.interval > 0 then
            if not cfg.nextSendAt or now >= cfg.nextSendAt then
                if SendConfiguredMessage(cfg) then
                    cfg.nextSendAt = now + cfg.interval
                else
                    cfg.nextSendAt = now + 15
                end
            end
        end
    end
end

local function StartApplySession(playerName)
    state.whisperSessions[playerName] = {
        questionIndex = 1,
        currentAnswer = "",
        answers = {},
    }

    local firstQuestion = state.db.questions[1] or "No questions configured."
    SendChatMessage("Thanks for applying! Question 1: " .. firstQuestion, "WHISPER", nil, playerName)
end

local function CompleteSession(playerName, session)
    state.db.applications[playerName] = {
        submittedAt = time(),
        answers = session.answers,
    }
    state.whisperSessions[playerName] = nil

    SendChatMessage("Application complete. Thank you! We'll review your answers soon.", "WHISPER", nil, playerName)
    RefreshApplicantDropdownText()
    RefreshAnswersText()
end

local function HandleSessionMessage(playerName, message)
    local session = state.whisperSessions[playerName]
    if not session then
        return
    end

    local text = Trim(message)
    if strlower(text) == COMMAND_NEXT then
        if session.currentAnswer == "" then
            SendChatMessage("Please provide an answer before using !next.", "WHISPER", nil, playerName)
            return
        end

        session.answers[session.questionIndex] = session.currentAnswer
        session.currentAnswer = ""

        if session.questionIndex >= #state.db.questions then
            CompleteSession(playerName, session)
            return
        end

        session.questionIndex = session.questionIndex + 1
        local question = state.db.questions[session.questionIndex]
        SendChatMessage("Question " .. session.questionIndex .. ": " .. question, "WHISPER", nil, playerName)
        return
    end

    if session.currentAnswer == "" then
        session.currentAnswer = text
    else
        session.currentAnswer = session.currentAnswer .. " " .. text
    end

    SendChatMessage("Answer recorded. Type !next when done answering, or keep typing to add more.", "WHISPER", nil, playerName)
end

local function HandleWhisper(message, sender)
    local playerName = sender and sender:match("^[^%-]+") or sender
    if not playerName then
        return
    end

    local text = Trim(message)
    if text == "" then
        return
    end

    if strlower(text) == COMMAND_APPLY then
        if state.whisperSessions[playerName] then
            SendChatMessage("Your application is already in progress. Continue answering and use !next when ready.", "WHISPER", nil, playerName)
        else
            StartApplySession(playerName)
        end
        return
    end

    HandleSessionMessage(playerName, text)
end

local function ToggleUI()
    if ui.main:IsShown() then
        ui.main:Hide()
        return
    end

    local options = EnumerateChannels()
    if not state.selectedChannelKey and options[1] then
        state.selectedChannelKey = options[1].key
    end

    RefreshConfigFields()

    local applicants = GetSortedApplicants()
    if #applicants > 0 and not state.selectedApplicant then
        state.selectedApplicant = applicants[1]
    end
    RefreshApplicantDropdownText()
    RefreshAnswersText()
    ui.main:Show()
end

local updateAccumulator = 0
frame:SetScript("OnUpdate", function(_, elapsed)
    updateAccumulator = updateAccumulator + elapsed
    if updateAccumulator < 1 then
        return
    end

    TickSpammer(updateAccumulator)
    updateAccumulator = 0
end)

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...
        if loadedAddon ~= addonName then
            return
        end

        EnsureDB()
        InitializeUI()
        return
    end

    if event == "CHAT_MSG_WHISPER" then
        local message, sender = ...
        HandleWhisper(message, sender)
    end
end)

frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_WHISPER")

SLASH_GUILDRECRUITMENTHELPER1 = "/grh"
SLASH_GUILDRECRUITMENTHELPER2 = "/guildrecruitmenthelper"
SlashCmdList.GUILDRECRUITMENTHELPER = function(msg)
    local command = strlower(Trim(msg or ""))
    if command == "start" then
        state.isSpamming = true
        if ui.toggleSpamButton then
            ui.toggleSpamButton:SetText("Stop Spam")
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Channel spam enabled.")
        return
    end

    if command == "stop" then
        state.isSpamming = false
        if ui.toggleSpamButton then
            ui.toggleSpamButton:SetText("Start Spam")
        end
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Channel spam disabled.")
        return
    end

    ToggleUI()
end
