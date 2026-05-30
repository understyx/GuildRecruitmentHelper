local addonName = ...

local frame = CreateFrame("Frame", "GuildRecruitmentHelperFrame")
local state = {
    db = nil,
    isSpamming = false,
    whisperSessions = {},
    activeTab = "spam",
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
local COMMAND_CANCEL = "!cancel"
local MIN_SPAM_INTERVAL = 60

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
    for i = 1, #channels, 2 do
        local channelID = channels[i]
        local channelName = channels[i + 1]
        if channelID and channelName and channelName ~= "" then
            table.insert(options, {
                key = "CHANNEL:" .. channelName,
                label = "/" .. channelID .. " - " .. channelName,
                mode = "CHANNEL",
                channelName = channelName,
                channelID = channelID,
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

local function BuildApplicationText(playerName)
    if not playerName then
        return "No applicant selected."
    end

    local application = state.db.applications[playerName]
    if not application then
        return "No application found."
    end

    local lines = {}
    table.insert(lines, "Applicant: " .. playerName)
    local submittedLabel = application.submittedAtText or "Unknown"
    if submittedLabel == "Unknown" and application.submittedAt then
        submittedLabel = tostring(application.submittedAt)
    end
    table.insert(lines, "Submitted: " .. submittedLabel)
    table.insert(lines, "")

    local questions = state.db.questions
    for i = 1, #questions do
        table.insert(lines, "Q" .. i .. ": " .. questions[i])
        table.insert(lines, "A" .. i .. ": " .. (application.answers[i] or ""))
        table.insert(lines, "")
    end

    return table.concat(lines, "\n")
end

local function RefreshAnswersText()
    if not ui.answersBox then
        return
    end

    ui.answersBox:SetText(BuildApplicationText(state.selectedApplicant))
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

-- Builds (or refreshes) the per-channel spam rows inside the scroll child.
-- Each row has: channel label | message editbox | interval editbox | enabled checkbox | save button.
local function BuildSpamRows()
    local scrollChild = ui.spamScrollChild
    if not scrollChild then
        return
    end

    local options = EnumerateChannels()
    local rowH = 30
    local contentH = rowH * #options + 4
    if contentH < 1 then
        contentH = 1
    end
    scrollChild:SetHeight(contentH)

    for i = 1, #options do
        local option = options[i]
        local cfg = EnsureConfigForOption(option)
        local yTop = -(i - 1) * rowH - 2

        local row = ui.spamRows[i]
        if not row then
            row = {}
            ui.spamRows[i] = row

            row.label = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.label:SetWidth(130)
            row.label:SetJustifyH("LEFT")

            row.msgBox = CreateFrame("EditBox", "GRHSpamMsg" .. i, scrollChild, "InputBoxTemplate")
            row.msgBox:SetWidth(300)
            row.msgBox:SetHeight(20)
            row.msgBox:SetAutoFocus(false)
            row.msgBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            row.intBox = CreateFrame("EditBox", "GRHSpamInt" .. i, scrollChild, "InputBoxTemplate")
            row.intBox:SetWidth(50)
            row.intBox:SetHeight(20)
            row.intBox:SetNumeric(true)
            row.intBox:SetAutoFocus(false)
            row.intBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            row.check = CreateFrame("CheckButton", "GRHSpamCheck" .. i, scrollChild, "UICheckButtonTemplate")
            _G["GRHSpamCheck" .. i .. "Text"]:SetText("")

            row.saveBtn = CreateFrame("Button", "GRHSpamSave" .. i, scrollChild, "UIPanelButtonTemplate")
            row.saveBtn:SetWidth(60)
            row.saveBtn:SetHeight(22)
            row.saveBtn:SetText("Save")
        end

        -- Reposition each element for this row
        row.label:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yTop - 7)
        row.msgBox:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 140, yTop - 4)
        row.intBox:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 448, yTop - 4)
        row.check:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 504, yTop - 1)
        row.saveBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 534, yTop - 3)

        -- Populate current config values
        row.label:SetText(option.label)
        row.msgBox:SetText(cfg.message or "")
        row.intBox:SetText(tostring(cfg.interval or 300))
        row.check:SetChecked(cfg.enabled and true or false)

        -- Per-row save closure
        do
            local capturedOption = option
            local capturedRow = row
            row.saveBtn:SetScript("OnClick", function()
                local c = EnsureConfigForOption(capturedOption)
                c.message = Trim(capturedRow.msgBox:GetText())
                c.interval = tonumber(capturedRow.intBox:GetText()) or 300
                if c.interval < MIN_SPAM_INTERVAL then
                    c.interval = MIN_SPAM_INTERVAL
                    capturedRow.intBox:SetText(tostring(c.interval))
                end
                c.enabled = capturedRow.check:GetChecked() and true or false
                c.nextSendAt = nil
                DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Saved spam config for " .. capturedOption.label)
            end)
        end

        row.label:Show()
        row.msgBox:Show()
        row.intBox:Show()
        row.check:Show()
        row.saveBtn:Show()
    end

    -- Hide rows that are no longer needed
    for i = #options + 1, #ui.spamRows do
        local row = ui.spamRows[i]
        if row then
            if row.label then row.label:Hide() end
            if row.msgBox then row.msgBox:Hide() end
            if row.intBox then row.intBox:Hide() end
            if row.check then row.check:Hide() end
            if row.saveBtn then row.saveBtn:Hide() end
        end
    end
end

-- Persist whatever is currently typed in the question editboxes back to the DB.
local function SaveQuestionEdits()
    if not ui.formRows then
        return
    end
    local questions = state.db.questions
    for i = 1, #questions do
        local row = ui.formRows[i]
        if row and row.qBox then
            local txt = Trim(row.qBox:GetText())
            if txt ~= "" then
                questions[i] = txt
            end
        end
    end
end

-- Builds (or refreshes) the question rows inside the Form Creation scroll child.
-- Each row has: index label | question editbox | delete button.
local function BuildQuestionRows()
    local scrollChild = ui.formScrollChild
    if not scrollChild then
        return
    end

    local questions = state.db.questions
    local rowH = 28
    local contentH = rowH * #questions + 4
    if contentH < 1 then
        contentH = 1
    end
    scrollChild:SetHeight(contentH)

    for i = 1, #questions do
        local yTop = -(i - 1) * rowH - 2

        local row = ui.formRows[i]
        if not row then
            row = {}
            ui.formRows[i] = row

            row.indexLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.indexLabel:SetWidth(28)
            row.indexLabel:SetJustifyH("RIGHT")

            row.qBox = CreateFrame("EditBox", "GRHFormQ" .. i, scrollChild, "InputBoxTemplate")
            row.qBox:SetWidth(502)
            row.qBox:SetHeight(20)
            row.qBox:SetAutoFocus(false)
            row.qBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            row.delBtn = CreateFrame("Button", "GRHFormDel" .. i, scrollChild, "UIPanelButtonTemplate")
            row.delBtn:SetWidth(62)
            row.delBtn:SetHeight(22)
            row.delBtn:SetText("Delete")
        end

        row.indexLabel:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, yTop - 6)
        row.qBox:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 36, yTop - 4)
        row.delBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 544, yTop - 3)

        row.indexLabel:SetText("Q" .. i .. ":")
        row.qBox:SetText(questions[i] or "")

        -- Per-row delete closure; saves other edits first so they aren't lost
        do
            local capturedIndex = i
            row.delBtn:SetScript("OnClick", function()
                SaveQuestionEdits()
                table.remove(state.db.questions, capturedIndex)
                BuildQuestionRows()
            end)
        end

        row.indexLabel:Show()
        row.qBox:Show()
        row.delBtn:Show()
    end

    -- Hide rows that are no longer needed
    for i = #questions + 1, #ui.formRows do
        local row = ui.formRows[i]
        if row then
            if row.indexLabel then row.indexLabel:Hide() end
            if row.qBox then row.qBox:Hide() end
            if row.delBtn then row.delBtn:Hide() end
        end
    end
end

-- Shows the requested tab and populates its content.
local function SwitchTab(tab)
    state.activeTab = tab
    if tab == "spam" then ui.spamPanel:Show() else ui.spamPanel:Hide() end
    if tab == "form" then ui.formPanel:Show() else ui.formPanel:Hide() end
    if tab == "apps" then ui.appsPanel:Show() else ui.appsPanel:Hide() end

    if tab == "spam" then
        BuildSpamRows()
    elseif tab == "form" then
        BuildQuestionRows()
    else
        local applicants = GetSortedApplicants()
        if #applicants > 0 and not state.selectedApplicant then
            state.selectedApplicant = applicants[1]
        end
        RefreshApplicantDropdownText()
        RefreshAnswersText()
    end
end

local function InitializeUI()
    -- Dimensions
    local panelLeft   = 12
    local panelTop    = -72
    local panelWidth  = 696
    local panelHeight = 380
    local scrollW     = panelWidth - 20   -- room for scrollbar
    local childW      = panelWidth - 44

    local main = CreateFrame("Frame", "GuildRecruitmentHelperMainFrame", UIParent)
    main:SetWidth(720)
    main:SetHeight(470)
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

    -- Tab buttons
    local tabDefs = {
        { key = "spam", label = "Chat Spam",    width = 100 },
        { key = "form", label = "Form Creation", width = 110 },
        { key = "apps", label = "Applications",  width = 100 },
    }
    ui.tabButtons = {}
    local tabX = 20
    for _, tabDef in ipairs(tabDefs) do
        local btn = CreateFrame("Button", "GRHTab_" .. tabDef.key, main, "UIPanelButtonTemplate")
        btn:SetWidth(tabDef.width)
        btn:SetHeight(24)
        btn:SetPoint("TOPLEFT", main, "TOPLEFT", tabX, -40)
        btn:SetText(tabDef.label)
        local capturedKey = tabDef.key
        btn:SetScript("OnClick", function() SwitchTab(capturedKey) end)
        ui.tabButtons[tabDef.key] = btn
        tabX = tabX + tabDef.width + 4
    end

    -- ================================================================
    -- CHAT SPAM PANEL
    -- ================================================================
    local spamPanel = CreateFrame("Frame", "GRHSpamPanel", main)
    spamPanel:SetPoint("TOPLEFT", main, "TOPLEFT", panelLeft, panelTop)
    spamPanel:SetWidth(panelWidth)
    spamPanel:SetHeight(panelHeight)
    ui.spamPanel = spamPanel

    -- Column headers
    local hdrChan = spamPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrChan:SetPoint("TOPLEFT", spamPanel, "TOPLEFT", 4, -2)
    hdrChan:SetText("Channel")

    local hdrMsg = spamPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrMsg:SetPoint("TOPLEFT", spamPanel, "TOPLEFT", 140, -2)
    hdrMsg:SetText("Message")

    local hdrInt = spamPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrInt:SetPoint("TOPLEFT", spamPanel, "TOPLEFT", 448, -2)
    hdrInt:SetText("Interval")

    local hdrOn = spamPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrOn:SetPoint("TOPLEFT", spamPanel, "TOPLEFT", 506, -2)
    hdrOn:SetText("On")

    local spamScroll = CreateFrame("ScrollFrame", "GRHSpamScrollFrame", spamPanel, "UIPanelScrollFrameTemplate")
    spamScroll:SetPoint("TOPLEFT", spamPanel, "TOPLEFT", 0, -18)
    spamScroll:SetWidth(scrollW)
    spamScroll:SetHeight(panelHeight - 50)
    ui.spamScrollFrame = spamScroll

    local spamScrollChild = CreateFrame("Frame", "GRHSpamScrollChild", spamScroll)
    spamScrollChild:SetWidth(childW)
    spamScrollChild:SetHeight(1)
    spamScroll:SetScrollChild(spamScrollChild)
    ui.spamScrollChild = spamScrollChild
    ui.spamRows = {}

    local toggleSpamBtn = CreateFrame("Button", "GRHToggleSpamBtn", spamPanel, "UIPanelButtonTemplate")
    toggleSpamBtn:SetPoint("BOTTOMLEFT", spamPanel, "BOTTOMLEFT", 0, 2)
    toggleSpamBtn:SetWidth(110)
    toggleSpamBtn:SetHeight(24)
    toggleSpamBtn:SetText("Start Spam")
    toggleSpamBtn:SetScript("OnClick", function(self)
        state.isSpamming = not state.isSpamming
        if state.isSpamming then
            self:SetText("Stop Spam")
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Channel spam enabled.")
        else
            self:SetText("Start Spam")
            DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Channel spam disabled.")
        end
    end)
    ui.toggleSpamButton = toggleSpamBtn

    -- ================================================================
    -- FORM CREATION PANEL
    -- ================================================================
    local formPanel = CreateFrame("Frame", "GRHFormPanel", main)
    formPanel:SetPoint("TOPLEFT", main, "TOPLEFT", panelLeft, panelTop)
    formPanel:SetWidth(panelWidth)
    formPanel:SetHeight(panelHeight)
    formPanel:Hide()
    ui.formPanel = formPanel

    local fHdrNum = formPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fHdrNum:SetPoint("TOPLEFT", formPanel, "TOPLEFT", 4, -2)
    fHdrNum:SetText("#")

    local fHdrQ = formPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fHdrQ:SetPoint("TOPLEFT", formPanel, "TOPLEFT", 36, -2)
    fHdrQ:SetText("Question text (sent when player uses !apply / !next)")

    local formScroll = CreateFrame("ScrollFrame", "GRHFormScrollFrame", formPanel, "UIPanelScrollFrameTemplate")
    formScroll:SetPoint("TOPLEFT", formPanel, "TOPLEFT", 0, -18)
    formScroll:SetWidth(scrollW)
    formScroll:SetHeight(panelHeight - 50)
    ui.formScrollFrame = formScroll

    local formScrollChild = CreateFrame("Frame", "GRHFormScrollChild", formScroll)
    formScrollChild:SetWidth(childW)
    formScrollChild:SetHeight(1)
    formScroll:SetScrollChild(formScrollChild)
    ui.formScrollChild = formScrollChild
    ui.formRows = {}

    local addQBtn = CreateFrame("Button", "GRHAddQBtn", formPanel, "UIPanelButtonTemplate")
    addQBtn:SetPoint("BOTTOMLEFT", formPanel, "BOTTOMLEFT", 0, 2)
    addQBtn:SetWidth(110)
    addQBtn:SetHeight(24)
    addQBtn:SetText("Add Question")
    addQBtn:SetScript("OnClick", function()
        SaveQuestionEdits()
        table.insert(state.db.questions, "Enter your question here")
        BuildQuestionRows()
    end)

    local saveAllQBtn = CreateFrame("Button", "GRHSaveAllQBtn", formPanel, "UIPanelButtonTemplate")
    saveAllQBtn:SetPoint("BOTTOMLEFT", formPanel, "BOTTOMLEFT", 118, 2)
    saveAllQBtn:SetWidth(90)
    saveAllQBtn:SetHeight(24)
    saveAllQBtn:SetText("Save All")
    saveAllQBtn:SetScript("OnClick", function()
        SaveQuestionEdits()
        DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99[GRH]|r Application questions saved.")
    end)

    -- ================================================================
    -- APPLICATIONS PANEL
    -- ================================================================
    local appsPanel = CreateFrame("Frame", "GRHAppsPanel", main)
    appsPanel:SetPoint("TOPLEFT", main, "TOPLEFT", panelLeft, panelTop)
    appsPanel:SetWidth(panelWidth)
    appsPanel:SetHeight(panelHeight)
    appsPanel:Hide()
    ui.appsPanel = appsPanel

    local applicantLabel = appsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    applicantLabel:SetPoint("TOPLEFT", appsPanel, "TOPLEFT", 4, -2)
    applicantLabel:SetText("Applicant")

    local applicantDropdown = CreateFrame("Frame", "GuildRecruitmentHelperApplicantDropdown", appsPanel, "UIDropDownMenuTemplate")
    applicantDropdown:SetPoint("TOPLEFT", appsPanel, "TOPLEFT", -16, -18)
    ui.applicantDropdown = applicantDropdown

    local answersScrollFrame = CreateFrame("ScrollFrame", "GuildRecruitmentHelperAnswersScrollFrame", appsPanel, "UIPanelScrollFrameTemplate")
    answersScrollFrame:SetPoint("TOPLEFT", appsPanel, "TOPLEFT", 0, -52)
    answersScrollFrame:SetWidth(scrollW)
    answersScrollFrame:SetHeight(panelHeight - 82)
    ui.answersScrollFrame = answersScrollFrame

    local answersBox = CreateFrame("EditBox", "GuildRecruitmentHelperAnswersBox", answersScrollFrame)
    answersBox:SetMultiLine(true)
    answersBox:SetFontObject(ChatFontNormal)
    answersBox:SetWidth(childW)
    answersBox:SetAutoFocus(false)
    answersBox:EnableMouse(true)
    answersBox:SetHyperlinksEnabled(true)
    answersBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    answersBox:SetScript("OnChar", function() end)
    answersBox:SetScript("OnHyperlinkClick", function(_, link, text, button)
        SetItemRef(link, text, button)
    end)
    answersBox:SetScript("OnHyperlinkEnter", function(_, link)
        GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end)
    answersBox:SetScript("OnHyperlinkLeave", function()
        GameTooltip:Hide()
    end)
    answersScrollFrame:SetScrollChild(answersBox)
    ui.answersBox = answersBox

    local refreshBtn = CreateFrame("Button", "GRHRefreshAppsBtn", appsPanel, "UIPanelButtonTemplate")
    refreshBtn:SetPoint("BOTTOMLEFT", appsPanel, "BOTTOMLEFT", 0, 2)
    refreshBtn:SetWidth(120)
    refreshBtn:SetHeight(24)
    refreshBtn:SetText("Refresh Applicants")
    refreshBtn:SetScript("OnClick", function()
        RefreshApplicantDropdownText()
        RefreshAnswersText()
    end)

    -- Copy popup (created lazily on first use)
    local copyPopupFrame, copyPopupEditBox

    local function ShowCopyPopup()
        if not copyPopupFrame then
            local popup = CreateFrame("Frame", "GRHCopyPopupFrame", UIParent)
            popup:SetWidth(500)
            popup:SetHeight(350)
            popup:SetPoint("CENTER")
            popup:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                tile = true,
                tileSize = 32,
                edgeSize = 32,
                insets = { left = 11, right = 12, top = 12, bottom = 11 }
            })
            popup:EnableMouse(true)
            popup:SetMovable(true)
            popup:RegisterForDrag("LeftButton")
            popup:SetScript("OnDragStart", function(self) self:StartMoving() end)
            popup:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
            popup:SetFrameStrata("DIALOG")
            popup:Hide()

            local popupTitle = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            popupTitle:SetPoint("TOP", 0, -14)
            popupTitle:SetText("Copy Application (Ctrl+A, Ctrl+C)")

            local popupClose = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
            popupClose:SetPoint("TOPRIGHT", -5, -5)
            popupClose:SetScript("OnClick", function() popup:Hide() end)

            local popupScroll = CreateFrame("ScrollFrame", "GRHCopyScrollFrame", popup, "UIPanelScrollFrameTemplate")
            popupScroll:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -30)
            popupScroll:SetPoint("BOTTOMRIGHT", popup, "BOTTOMRIGHT", -30, 10)

            local popupEdit = CreateFrame("EditBox", "GRHCopyEditBox", popupScroll)
            popupEdit:SetMultiLine(true)
            popupEdit:SetFontObject(ChatFontNormal)
            popupEdit:SetWidth(440)
            popupEdit:SetAutoFocus(false)
            popupEdit:SetScript("OnEscapePressed", function() popup:Hide() end)
            popupScroll:SetScrollChild(popupEdit)

            copyPopupFrame = popup
            copyPopupEditBox = popupEdit
        end

        copyPopupEditBox:SetText(BuildApplicationText(state.selectedApplicant))
        copyPopupEditBox:SetFocus()
        copyPopupEditBox:HighlightText()
        copyPopupFrame:Show()
    end

    local copyBtn = CreateFrame("Button", "GRHCopyAppBtn", appsPanel, "UIPanelButtonTemplate")
    copyBtn:SetPoint("BOTTOMLEFT", appsPanel, "BOTTOMLEFT", 128, 2)
    copyBtn:SetWidth(130)
    copyBtn:SetHeight(24)
    copyBtn:SetText("Copy Application")
    copyBtn:SetScript("OnClick", ShowCopyPopup)

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
    SendChatMessage("Thanks for applying! Type !cancel at any time to cancel. Question 1: " .. firstQuestion, "WHISPER", nil, playerName)
end

local function CompleteSession(playerName, session)
    local submittedAt = time()
    local submittedAtText = tostring(submittedAt)
    if type(date) == "function" then
        submittedAtText = date("%Y-%m-%d %H:%M:%S", submittedAt)
    end

    state.db.applications[playerName] = {
        submittedAt = submittedAt,
        submittedAtText = submittedAtText,
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

    SendChatMessage("Answer recorded. Type !next when done answering, !cancel to cancel, or keep typing to add more.", "WHISPER", nil, playerName)
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
            SendChatMessage("Your application is already in progress. Continue answering, use !next to move to the next question, or !cancel to cancel.", "WHISPER", nil, playerName)
        else
            StartApplySession(playerName)
        end
        return
    end

    if strlower(text) == COMMAND_CANCEL then
        if state.whisperSessions[playerName] then
            state.whisperSessions[playerName] = nil
            SendChatMessage("Your application has been cancelled. You can start a new one with !apply.", "WHISPER", nil, playerName)
        else
            SendChatMessage("You don't have an active application to cancel.", "WHISPER", nil, playerName)
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

    BuildSpamRows()
    SwitchTab(state.activeTab or "spam")
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
