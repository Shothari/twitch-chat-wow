-- Chat Twitch : bouton de minimap qui pilote la fenêtre du programme « Chat Twitch ».
--
-- Un addon WoW n'a pas accès à Internet ni aux autres programmes. Pour transmettre
-- l'ordre « afficher / masquer / verrouiller », l'addon affiche un minuscule carré
-- de couleur dans le coin en haut à gauche de l'écran ; le programme Chat Twitch
-- lit la couleur de ce pixel et applique l'état demandé.
--   magenta (255,0,255)   = fenêtre affichée
--   (255,85,255)          = fenêtre affichée et verrouillée (clics transmis au jeu)
--   (255,170,255)         = fenêtre masquée
--   (255,0,128)           = « relancer le chat » (pendant 3 secondes)
--   (255,128,0)           = « lancer TikTok LIVE Studio » (pendant 1,5 seconde)
--   (255,128,64)          = « ouvrir ma chaîne Twitch »
--   (255,128,128)         = « lancer OBS »

local ADDON_NAME = ...
local DB

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9146FFChat Twitch|r : " .. msg)
end

---------------------------------------------------------------- Signal
local signal = CreateFrame("Frame", "TwitchChatWoWSignal", UIParent)
signal:SetFrameStrata("TOOLTIP")
signal:SetFrameLevel(100)
signal:SetIgnoreParentScale(true)
signal:SetScale(1)
signal:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
signal:SetSize(3, 3)
local signalTex = signal:CreateTexture(nil, "OVERLAY")
signalTex:SetAllPoints()

local restartUntil = 0
local actionUntil, actionBlue = 0, 0

-- Fenêtres du jeu devant lesquelles le chat s'efface (fiche perso, carte, métiers, talents...)
local GAME_PANELS = {
    "CharacterFrame", "PaperDollFrame", "WorldMapFrame", "SpellBookFrame", "PlayerSpellsFrame",
    "TalentFrame", "PlayerTalentFrame", "ClassTalentFrame", "TradeSkillFrame", "CraftFrame", "ProfessionsFrame",
    "QuestLogFrame", "QuestLogDetailFrame", "FriendsFrame", "GuildFrame", "CommunitiesFrame", "GameMenuFrame",
    "SettingsPanel", "InterfaceOptionsFrame", "VideoOptionsFrame", "AudioOptionsFrame", "KeyBindingFrame",
    "AuctionFrame", "AuctionHouseFrame", "MerchantFrame", "MailFrame", "OpenMailFrame", "BankFrame",
    "GossipFrame", "QuestFrame", "TaxiFrame", "TrainerFrame", "ClassTrainerFrame", "LFGParentFrame",
    "PVEFrame", "PVPFrame", "HonorFrame", "AchievementFrame", "CollectionsJournal", "EncounterJournal",
    "MacroFrame", "AddonList", "HelpFrame", "InspectFrame", "TradeFrame", "LootFrame", "ItemTextFrame",
}

-- Rectangle d'une fenêtre (et de ses volets attachés) en pixels de l'écran
local function PhysHeight()
    if GetPhysicalScreenSize then
        local _, h = GetPhysicalScreenSize()
        if h and h > 0 then return h end
    end
    return 1080
end
-- Certaines fenêtres sont plus grandes que ce qu'on voit : on prend alors leurs parties visibles
local PANEL_PARTS = {
    WorldMapFrame = { "BorderFrame", "ScrollContainer", "NavBar", "TitleCanvasSpacerFrame", "SidePanelToggle", "QuestLog", "MiniBorderFrame" },
}
-- Mesure protégée : en combat, certaines fenêtres sont « restreintes » et le jeu
-- refuse de les mesurer (erreur Lua). On les ignore simplement.
local function RawRect(f, px)
    if type(f) ~= "table" or not f.GetRect then return nil end
    if f.IsForbidden and f:IsForbidden() then return nil end
    if f.IsAnchoringRestricted then
        local okR, restricted = pcall(f.IsAnchoringRestricted, f)
        if not okR or restricted then return nil end
    end
    local ok, l, b, w, h = pcall(f.GetRect, f)
    if not ok or type(l) ~= "number" or type(b) ~= "number" or type(w) ~= "number" or type(h) ~= "number" then return nil end
    if w < 2 or h < 2 then return nil end
    local okS, es = pcall(f.GetEffectiveScale, f)
    if not okS or type(es) ~= "number" then return nil end
    local s = es * px
    return { l * s, b * s, (l + w) * s, (b + h) * s }
end
local function SafeVisible(f)
    if type(f) ~= "table" or not f.IsVisible then return false end
    if f.IsForbidden and f:IsForbidden() then return false end
    local ok, v = pcall(f.IsVisible, f)
    return ok and v and true or false
end
local function FrameRect(f, px, name)
    local parts = name and PANEL_PARTS[name]
    if parts then
        local u
        for _, key in ipairs(parts) do
            local c = f[key]
            if SafeVisible(c) then
                local r = RawRect(c, px)
                if r then
                    if not u then u = r else
                        u = { math.min(u[1], r[1]), math.min(u[2], r[2]), math.max(u[3], r[3]), math.max(u[4], r[4]) }
                    end
                end
            end
        end
        if u then return u end
    end
    return RawRect(f, px)
end
local function OpenPanelRects()
    local physH = PhysHeight()
    local px = physH / 768
    local seen, list = {}, {}
    local function add(name)
        local f = _G[name]
        if type(f) == "table" and not seen[f] and f.GetRect and SafeVisible(f) then
            seen[f] = true
            local r = FrameRect(f, px, name)
            if r then
                -- coordonnées WoW (origine en bas) -> écran (origine en haut)
                table.insert(list, { r[1], physH - r[4], r[3], physH - r[2] })
            end
        end
    end
    for _, name in ipairs(GAME_PANELS) do add(name) end
    if type(UIPanelWindows) == "table" then for name in pairs(UIPanelWindows) do add(name) end end
    -- 3 rectangles au plus : les suivants sont fusionnés dans le dernier
    while #list > 3 do
        local a, z = list[3], table.remove(list)
        a[1] = math.min(a[1], z[1]); a[2] = math.min(a[2], z[2]); a[3] = math.max(a[3], z[3]); a[4] = math.max(a[4], z[4])
    end
    return list, physH
end

-- Bande de données à côté du signal : chaque case porte 3 bits (rouge, vert, bleu = 0 ou 255)
local CELL_PX, DATA_X, MAX_CELLS = 4, 8, 49
local cells = {}
local dataFrame = CreateFrame("Frame", "TwitchChatWoWData", UIParent)
dataFrame:SetFrameStrata("TOOLTIP")
dataFrame:SetFrameLevel(100)
dataFrame:SetIgnoreParentScale(true)
dataFrame:SetScale(1)
dataFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
dataFrame:SetSize(1, 1)
for i = 1, MAX_CELLS do
    local t = dataFrame:CreateTexture(nil, "OVERLAY")
    t:Hide()
    cells[i] = t
end
local lastBits = nil
local function UpdateDataStrip()
    local bits = {}
    local list, physH = {}, PhysHeight()
    if DB and DB.behind then list = OpenPanelRects() end
    -- en-tête : nombre de rectangles (0 à 3) sur 2 bits, puis le bit « données présentes »
    local n = #list
    table.insert(bits, 1); table.insert(bits, math.floor(n / 2) % 2); table.insert(bits, n % 2)
    for _, r in ipairs(list) do
        local v = { math.floor(r[1] + 0.5), math.floor(r[2] + 0.5), math.floor(r[3] + 0.5), math.floor(r[4] + 0.5) }
        for _, x in ipairs(v) do
            x = math.max(0, math.min(4095, x))
            for k = 11, 0, -1 do table.insert(bits, math.floor(x / 2 ^ k) % 2) end
        end
    end
    while #bits % 3 ~= 0 do table.insert(bits, 0) end
    local key = table.concat(bits)
    if key == lastBits then return end
    lastBits = key
    local unit = 768 / physH   -- 1 pixel de l'écran en unités d'interface (échelle 1)
    local used = #bits / 3
    for i = 1, MAX_CELLS do
        local t = cells[i]
        if i <= used then
            local r, g, b = bits[(i - 1) * 3 + 1], bits[(i - 1) * 3 + 2], bits[(i - 1) * 3 + 3]
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", dataFrame, "TOPLEFT", (DATA_X + (i - 1) * CELL_PX) * unit, 0)
            t:SetSize(CELL_PX * unit, CELL_PX * unit)
            t:SetColorTexture(r, g, b, 1)
            t:Show()
        else
            t:Hide()
        end
    end
end

local function UpdateSignal()
    if GetTime() < restartUntil then
        signalTex:SetColorTexture(1, 0, 128 / 255, 1)
        return
    end
    if GetTime() < actionUntil then
        signalTex:SetColorTexture(1, 128 / 255, actionBlue / 255, 1)
        return
    end
    local g
    if not DB.shown then g = 170 elseif DB.locked then g = 85 else g = 0 end
    signalTex:SetColorTexture(1, g / 255, 1, 1)
end

-- Tout est protégé : une erreur ne doit jamais remonter au jeu à chaque image.
local errorShown = false
local function Tick()
    UpdateSignal()
    UpdateDataStrip()
end
signal:SetScript("OnUpdate", function(self, elapsed)
    if not DB then return end
    local ok, err = pcall(Tick)
    if not ok and not errorShown then
        errorShown = true
        DB.lastError = tostring(err)
        Print("|cffff4040erreur interne ignorée|r (" .. tostring(err) .. ")")
    end
end)

---------------------------------------------------------------- Bouton de minimap
local btn = CreateFrame("Button", "TwitchChatWoWMinimapButton", Minimap)
btn:SetSize(31, 31)
btn:SetFrameStrata("MEDIUM")
btn:SetFrameLevel(8)
btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
btn:RegisterForDrag("LeftButton")
btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

local border = btn:CreateTexture(nil, "OVERLAY")
border:SetSize(53, 53)
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetPoint("TOPLEFT")

local bg = btn:CreateTexture(nil, "BACKGROUND")
bg:SetSize(20, 20)
bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
bg:SetPoint("TOPLEFT", 7, -5)

local icon = btn:CreateTexture(nil, "ARTWORK")
icon:SetSize(18, 18)
icon:SetTexture("Interface\\AddOns\\Twitch Chat WoW\\icon")
icon:SetPoint("TOPLEFT", 6.5, -6)

local function UpdateIcon()
    if DB.shown then icon:SetDesaturated(false); icon:SetAlpha(1)
    else icon:SetDesaturated(true); icon:SetAlpha(0.6) end
end

local function UpdatePosition()
    local a = math.rad(DB.angle or 200)
    local dx, dy = math.cos(a), math.sin(a)
    local w = Minimap:GetWidth() / 2 + 6
    local h = Minimap:GetHeight() / 2 + 6
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local x, y
    if shape == "SQUARE" then
        x = math.max(-w, math.min(dx * w * 1.4142, w))
        y = math.max(-h, math.min(dy * h * 1.4142, h))
    else
        x, y = dx * w, dy * h
    end
    btn:ClearAllPoints()
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

btn:SetScript("OnDragStart", function(self)
    self:LockHighlight()
    self:SetScript("OnUpdate", function()
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local s = Minimap:GetEffectiveScale()
        DB.angle = math.deg(math.atan2(py / s - my, px / s - mx)) % 360
        UpdatePosition()
    end)
end)
btn:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    self:UnlockHighlight()
end)

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff9146FFChat Twitch|r")
    GameTooltip:AddLine(DB.shown and (DB.locked and "Fenêtre affichée, verrouillée" or "Fenêtre affichée") or "Fenêtre masquée", 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Clic gauche : afficher / masquer le chat", 1, 0.82, 0)
    GameTooltip:AddLine("Clic droit : menu (verrouiller, relancer...)", 1, 0.82, 0)
    GameTooltip:AddLine("Glisser : déplacer ce bouton", 1, 0.82, 0)
    GameTooltip:Show()
end
btn:SetScript("OnEnter", ShowTooltip)
btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function Refresh()
    UpdateSignal()
    UpdateIcon()
    if GameTooltip:GetOwner() == btn then ShowTooltip(btn) end
end

local function RestartChat()
    restartUntil = GetTime() + 3
    UpdateSignal()
    C_Timer.After(3.1, Refresh)
    Print("relance de la fenêtre du chat...")
end

local function SendAction(blue, text)
    actionUntil, actionBlue = GetTime() + 1.5, blue
    UpdateSignal()
    C_Timer.After(1.6, Refresh)
    Print(text)
end
local function LaunchTikTok() SendAction(0, "lancement de TikTok LIVE Studio... Ouvre ensuite la fenêtre du chat dans LIVE Studio.") end
local function OpenTwitch() SendAction(64, "ouverture de ta chaîne Twitch dans le navigateur...") end
local function LaunchOBS() SendAction(128, "lancement d'OBS Studio...") end

---------------------------------------------------------------- Menu (clic droit)
local menu = CreateFrame("Frame", "TwitchChatWoWMenu", UIParent, "BackdropTemplate")
menu:SetFrameStrata("DIALOG")
menu:SetClampedToScreen(true)
menu:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
menu:SetBackdropColor(0.07, 0.05, 0.03, 0.95)
menu:SetBackdropBorderColor(0.85, 0.68, 0.35, 1)
menu:Hide()

local menuTitle = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
menuTitle:SetPoint("TOPLEFT", 12, -10)
menuTitle:SetText("|cff9146FFChat Twitch|r")

local menuItems = {}
local function AddMenuItem(getText, onClick)
    local b = CreateFrame("Button", nil, menu)
    b:SetHeight(18)
    b:SetPoint("LEFT", menu, "LEFT", 8, 0)
    b:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
    b:SetPoint("TOP", menu, "TOP", 0, -28 - #menuItems * 18)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", 6, 0)
    b.label = fs
    b.getText = getText
    b:SetScript("OnClick", function() menu:Hide(); onClick() end)
    table.insert(menuItems, b)
end

AddMenuItem(function() return DB.shown and "Masquer le chat" or "Afficher le chat" end,
    function() DB.shown = not DB.shown; Refresh() end)
AddMenuItem(function() return DB.locked and "Déverrouiller" or "Verrouiller (clics transmis au jeu)" end,
    function() DB.locked = not DB.locked; if DB.locked then DB.shown = true end; Refresh() end)
AddMenuItem(function() return DB.behind and "Passer derrière les fenêtres du jeu : |cff00ff00oui|r" or "Passer derrière les fenêtres du jeu : |cffff4040non|r" end,
    function() DB.behind = not DB.behind; Refresh() end)
AddMenuItem(function() return "Relancer le chat" end, RestartChat)
AddMenuItem(function() return "|cff9146FFOuvrir ma chaîne Twitch|r" end, OpenTwitch)
AddMenuItem(function() return "|cff9146FFLancer OBS (stream Twitch)|r" end, LaunchOBS)
AddMenuItem(function() return "|cff25F4EELancer TikTok LIVE Studio|r" end, LaunchTikTok)
AddMenuItem(function() return "|cff999999Fermer ce menu|r" end, function() end)

menu:SetSize(270, 36 + #menuItems * 18)

local idle = 0
menu:SetScript("OnUpdate", function(self, elapsed)
    if MouseIsOver(self) or MouseIsOver(btn) then idle = 0 else idle = idle + elapsed end
    if idle > 2 then self:Hide() end
end)

local function OpenMenu()
    for _, b in ipairs(menuItems) do b.label:SetText(b.getText()) end
    GameTooltip:Hide()
    menu:ClearAllPoints()
    local x = btn:GetCenter()
    if x and x > GetScreenWidth() / 2 then
        menu:SetPoint("TOPRIGHT", btn, "BOTTOMLEFT", 0, 0)
    else
        menu:SetPoint("TOPLEFT", btn, "BOTTOMRIGHT", 0, 0)
    end
    idle = 0
    menu:Show()
end

btn:SetScript("OnClick", function(self, button)
    if button == "RightButton" then
        if menu:IsShown() then menu:Hide() else OpenMenu() end
    else
        DB.shown = not DB.shown
        Refresh()
    end
end)

---------------------------------------------------------------- Commandes
SLASH_TWITCHCHATWOW1 = "/twitch"
SLASH_TWITCHCHATWOW2 = "/chattwitch"
SlashCmdList.TWITCHCHATWOW = function(msg)
    msg = strlower(strtrim(msg or ""))
    if msg == "show" or msg == "afficher" then DB.shown = true
    elseif msg == "hide" or msg == "masquer" then DB.shown = false
    elseif msg == "lock" or msg == "verrouiller" then DB.locked = true; DB.shown = true
    elseif msg == "unlock" or msg == "deverrouiller" then DB.locked = false
    elseif msg == "relancer" or msg == "restart" or msg == "reload" then RestartChat(); return
    elseif msg == "tiktok" then LaunchTikTok(); return
    elseif msg == "chaine" or msg == "chaîne" then OpenTwitch(); return
    elseif msg == "obs" then LaunchOBS(); return
    elseif msg == "debug" then
        local px = PhysHeight() / 768
        local function show(n, f)
            local r = RawRect(f, px)
            if r then Print(string.format("%s : %d,%d -> %d,%d", n, r[1], PhysHeight() - r[4], r[3], PhysHeight() - r[2])) end
        end
        for _, name in ipairs(GAME_PANELS) do
            local f = _G[name]
            if SafeVisible(f) then
                show(name, f)
                for k, c in pairs(f) do
                    if type(k) == "string" and type(c) == "table" and c.GetRect and c ~= f and SafeVisible(c) then show("  ." .. k, c) end
                end
            end
        end
        return
    elseif msg == "bouton" or msg == "button" then
        DB.hideButton = not DB.hideButton
        btn:SetShown(not DB.hideButton)
        Print(DB.hideButton and "bouton de minimap masqué (/twitch bouton pour le remettre)." or "bouton de minimap affiché.")
        return
    elseif msg == "" then DB.shown = not DB.shown
    else
        Print("/twitch (afficher/masquer), /twitch lock, /twitch unlock, /twitch relancer, /twitch tiktok, /twitch chaine, /twitch obs, /twitch bouton")
        return
    end
    Refresh()
end

---------------------------------------------------------------- Démarrage
local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        TwitchChatWoWDB = TwitchChatWoWDB or {}
        DB = TwitchChatWoWDB
        if DB.shown == nil then DB.shown = true end
        if DB.locked == nil then DB.locked = false end
        if DB.angle == nil then DB.angle = 200 end
        if DB.behind == nil then DB.behind = true end
        btn:SetShown(not DB.hideButton)
        Refresh()
    elseif event == "PLAYER_LOGIN" then
        UpdatePosition()
        Refresh()
        if not DB.hintShown then
            DB.hintShown = true
            Print("bienvenue ! Si la fenêtre du chat n'apparaît pas, double-clique une fois sur |cffffd100INSTALLER (une seule fois).bat|r dans le dossier Interface\\AddOns\\Twitch Chat WoW. La fenêtre apparaîtra toute seule.")
        end
    end
end)
