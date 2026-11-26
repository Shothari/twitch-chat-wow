#Requires -Version 5.1
<#
    Twitch Chat Overlay pour WoW Forever
    ------------------------------------
    Fenêtre de chat Twitch, au style de l'interface WoW, posée par-dessus le jeu.

    - Connexion à ton compte Twitch (autorisation officielle Twitch, aucun mot de passe stocké).
    - Clic droit sur un message : supprimer, timeout 1 min / 10 min, bannir.
    - Messages retenus par AutoMod : boutons Autoriser / Refuser.
    - Zone de saisie en bas pour écrire dans ton chat.
    - Ctrl+Alt+T (ou le cadenas) : mode "clic à travers" (la souris passe au jeu).
    - Clic droit sur la barre de titre (chat déverrouillé) : changer de chaîne, se reconnecter, replacer, quitter.
#>
param([string]$Channel, [switch]$WithGame, [switch]$Restart)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $here 'config.json'
$tokenPath  = Join-Path $here 'twitch-token.dat'
$logPath    = Join-Path $here 'overlay.log'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing, Microsoft.VisualBasic

function Write-Log([string]$text) {
    try { Add-Content -Path $logPath -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $text) -Encoding UTF8 } catch {}
}

# Une seule fenêtre de chat à la fois
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\WoWTwitchChatOverlay')
$waitMs = if ($Restart) { 15000 } else { 0 }   # en cas de relance, attendre que l'ancienne fenêtre soit fermée
$gotMutex = $false
try { $gotMutex = $script:mutex.WaitOne($waitMs) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) { exit }

try {
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- Config
$cfg = [ordered]@{
    ClientId    = ''     # Client ID de ton application sur dev.twitch.tv
    Channel     = ''     # vide = ta propre chaîne
    Left        = -1     # -1 = centré à l'écran
    Top         = -1
    Width       = 560
    Height      = 460
    Opacity     = 0.85   # opacité du fond (0 = invisible, 1 = plein)
    FontSize    = 16
    MaxMessages = 150
    Tab         = 'twitch'   # onglet affiché : twitch ou tiktok
}
if (Test-Path $configPath) {
    try {
        $saved = Get-Content -Raw -Path $configPath -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in @($cfg.Keys)) {
            if ($null -ne $saved.$k -and "$($saved.$k)" -ne '') { $cfg[$k] = $saved.$k }
        }
    } catch { Write-Log "config.json illisible, valeurs par défaut utilisées : $_" }
}
if ($Channel) { $cfg.Channel = $Channel }
$cfg.Channel = "$($cfg.Channel)".Trim().ToLower()

function Save-Config {
    try { $cfg | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8 } catch { Write-Log "Sauvegarde config impossible : $_" }
}

function Read-ChannelName([string]$current) {
    $v = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Nom de la chaîne Twitch à afficher.`n`nLaisse vide pour ta propre chaîne.", "Chat Twitch", $current)
    $v = "$v".Trim().ToLower()
    $v = $v -replace '^.*twitch\.tv/', '' -replace '^#', '' -replace '[/?].*$', ''
    return $v
}

if (-not "$($cfg.ClientId)".Trim()) {
    try { Start-Process 'https://dev.twitch.tv/console/apps/create' } catch {}
    $id = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Première utilisation : colle ici le « Client ID » de ton application Twitch.`n`n" +
        "La page dev.twitch.tv vient de s'ouvrir. Suis l'étape 1 du fichier LISEZMOI.txt pour créer l'application (2 minutes, une seule fois).",
        "Chat Twitch - Client ID", '')
    $id = "$id".Trim()
    if (-not $id) { exit }
    $cfg.ClientId = $id
}
Save-Config

# ---------------------------------------------------------------- Fonctions Twitch communes (fenêtre + connexion)
$commonCode = @'
function Get-ErrText($err) {
    $m = $null
    try { if ($err.ErrorDetails -and $err.ErrorDetails.Message) { $m = $err.ErrorDetails.Message } } catch {}
    if (-not $m) { $m = $err.Exception.GetBaseException().Message }
    try { $j = $m | ConvertFrom-Json; if ($j.message) { $m = [string]$j.message } } catch {}
    return [string]$m
}
function Get-HttpStatus($err) { try { return [int]$err.Exception.Response.StatusCode } catch { return 0 } }

function Save-Token {
    $o = @{ access = $State.Access; refresh = $State.Refresh } | ConvertTo-Json -Compress
    $sec = ConvertTo-SecureString $o -AsPlainText -Force | ConvertFrom-SecureString   # chiffré pour ton compte Windows
    Set-Content -Path $State.TokenPath -Value $sec -Encoding ASCII
}
function Read-Token {
    if (-not (Test-Path $State.TokenPath)) { return $false }
    try {
        $sec = (Get-Content -Raw -Path $State.TokenPath).Trim() | ConvertTo-SecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        $o = $plain | ConvertFrom-Json
        $State.Access = $o.access; $State.Refresh = $o.refresh
        return $true
    } catch { return $false }
}
function Update-Token([string]$stale) {
    [Threading.Monitor]::Enter($State.Lock)
    try {
        if ($State.Access -and $State.Access -ne $stale) { return $true }   # déjà rafraîchi par l'autre thread
        if (-not $State.Refresh) { return $false }
        $r = Invoke-RestMethod -UseBasicParsing -Method Post -Uri 'https://id.twitch.tv/oauth2/token' -TimeoutSec 15 -Body @{
            client_id = $State.ClientId; grant_type = 'refresh_token'; refresh_token = $State.Refresh }
        $State.Access = $r.access_token; $State.Refresh = $r.refresh_token
        Save-Token
        return $true
    } catch { return $false }
    finally { [Threading.Monitor]::Exit($State.Lock) }
}
function Invoke-Helix([string]$Method, [string]$Path, $Body = $null) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $tok = $State.Access
        $p = @{
            UseBasicParsing = $true; Method = $Method; TimeoutSec = 15
            Uri = 'https://api.twitch.tv/helix/' + $Path
            Headers = @{ 'Authorization' = "Bearer $tok"; 'Client-Id' = $State.ClientId }
        }
        if ($null -ne $Body) {
            $p.ContentType = 'application/json; charset=utf-8'
            $p.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 6 -Compress))
        }
        try { return (Invoke-RestMethod @p) }
        catch {
            $err = $_
            if ($attempt -eq 0 -and (Get-HttpStatus $err) -eq 401 -and (Update-Token $tok)) { continue }
            throw (New-Object System.Exception (Get-ErrText $err))
        }
    }
}
'@
. ([scriptblock]::Create($commonCode))

# ---------------------------------------------------------------- Win32
if (-not ('OvNative' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class OvNative {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("gdi32.dll")] public static extern uint GetPixel(IntPtr hdc, int x, int y);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}
"@
}
if (-not ('OvMouse' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class OvMouse {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
"@
}
$GWL_EXSTYLE       = -20
$WS_EX_TRANSPARENT = 0x20
$WS_EX_TOOLWINDOW  = 0x80
$WS_EX_LAYERED     = 0x80000
$HOTKEY_ID         = 9001
$MOD_ALT = 0x1; $MOD_CONTROL = 0x2; $VK_T = 0x54

# ---------------------------------------------------------------- État partagé
$queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$State = [hashtable]::Synchronized(@{
    Run = $true; Ws = $null; Paused = $false
    Channel = $cfg.Channel; ClientId = "$($cfg.ClientId)".Trim(); TokenPath = $tokenPath
    Access = $null; Refresh = $null; UserId = $null; Login = $null; BroadcasterId = $null
    Lock = (New-Object object)
})

# ---------------------------------------------------------------- Worker : connexion Twitch (EventSub WebSocket)
$worker = {
    param($Queue, $State, $CommonCode)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    . ([scriptblock]::Create($CommonCode))

    function Push([hashtable]$item) { $Queue.Enqueue($item) }
    function Say([string]$text) { Push @{ Kind = 'sys'; Text = $text } }

    $Scopes = 'user:read:chat user:write:chat moderator:manage:chat_messages moderator:manage:banned_users moderator:manage:automod'

    function Test-Token {
        if (-not $State.Access) { return $false }
        try {
            $v = Invoke-RestMethod -UseBasicParsing -Uri 'https://id.twitch.tv/oauth2/validate' -TimeoutSec 15 -Headers @{ Authorization = "OAuth $($State.Access)" }
            $State.UserId = [string]$v.user_id; $State.Login = [string]$v.login
            return $true
        } catch { return $false }
    }

    function Start-DeviceLogin {
        $d = Invoke-RestMethod -UseBasicParsing -Method Post -Uri 'https://id.twitch.tv/oauth2/device' -TimeoutSec 15 -Body @{
            client_id = $State.ClientId; scopes = $Scopes }
        Say ("Autorisation Twitch : une page s'ouvre dans ton navigateur. Connecte-toi avec ton compte Twitch, vérifie le code " +
             $d.user_code + " puis clique sur Autoriser.")
        try { Start-Process $d.verification_uri } catch { Say ("Ouvre cette adresse : " + $d.verification_uri) }
        $deadline = (Get-Date).AddSeconds([int]$d.expires_in)
        $interval = [Math]::Max(2, [int]$d.interval)
        while ($State.Run -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $interval
            try {
                $r = Invoke-RestMethod -UseBasicParsing -Method Post -Uri 'https://id.twitch.tv/oauth2/token' -TimeoutSec 15 -Body @{
                    client_id = $State.ClientId; scopes = $Scopes; device_code = $d.device_code
                    grant_type = 'urn:ietf:params:oauth:grant-type:device_code' }
                $State.Access = $r.access_token; $State.Refresh = $r.refresh_token
                Save-Token
                return $true
            } catch {
                $m = Get-ErrText $_
                if ($m -match 'pending') { continue }
                if ($m -match 'slow') { $interval += 5; continue }
                throw "autorisation refusée ou expirée ($m)"
            }
        }
        throw "le délai d'autorisation est dépassé"
    }

    function Connect-Account {
        if (-not $State.Access) { [void](Read-Token) }
        if (Test-Token) { return }
        if ($State.Refresh -and (Update-Token $State.Access) -and (Test-Token)) { return }
        $State.Access = $null; $State.Refresh = $null
        [void](Start-DeviceLogin)
        if (-not (Test-Token)) { throw "le jeton Twitch reçu est invalide" }
    }

    function Add-Sub([string]$type, [string]$version, [hashtable]$cond, [string]$sid) {
        [void](Invoke-Helix 'POST' 'eventsub/subscriptions' @{
            type = $type; version = $version; condition = $cond
            transport = @{ method = 'websocket'; session_id = $sid } })
    }

    $enc = New-Object System.Text.UTF8Encoding($false)

    while ($State.Run) {
        $chanReq = $State.Channel
        if ($State.Paused) { Start-Sleep -Milliseconds 300; continue }
        $ws = $null
        $delay = 5
        try {
            # 1) Compte Twitch
            try { Connect-Account }
            catch {
                $State.Paused = $true
                Say ("Connexion à Twitch impossible : " + $_.Exception.Message + ". Clic droit sur la barre de titre du chat > « Se connecter à Twitch » pour réessayer.")
                continue
            }

            # 2) Chaîne à suivre
            $chan = if ($chanReq) { $chanReq } else { $State.Login }
            $u = Invoke-Helix 'GET' ('users?login=' + [Uri]::EscapeDataString($chan))
            if (-not $u.data) { throw "chaîne introuvable : $chan" }
            $State.BroadcasterId = [string]$u.data[0].id
            Push @{ Kind = 'ready'; Name = [string]$u.data[0].display_name; Login = $State.Login }

            # Emotes BetterTTV (globales + chaîne)
            $bttv = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
            try {
                foreach ($em in @(Invoke-RestMethod -UseBasicParsing -Uri 'https://api.betterttv.net/3/cached/emotes/global' -TimeoutSec 10)) {
                    if ($em.code -and $em.id) { $bttv[[string]$em.code] = 'https://cdn.betterttv.net/emote/' + [string]$em.id + '/2x' }
                }
            } catch {}
            try {
                $bu = Invoke-RestMethod -UseBasicParsing -Uri ('https://api.betterttv.net/3/cached/users/twitch/' + $State.BroadcasterId) -TimeoutSec 10
                foreach ($em in @($bu.channelEmotes) + @($bu.sharedEmotes)) {
                    if ($em -and $em.code -and $em.id) { $bttv[[string]$em.code] = 'https://cdn.betterttv.net/emote/' + [string]$em.id + '/2x' }
                }
            } catch {}

            # 3) WebSocket EventSub
            $ws = New-Object System.Net.WebSockets.ClientWebSocket
            $State.Ws = $ws
            [void]$ws.ConnectAsync([Uri]'wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30', [Threading.CancellationToken]::None).GetAwaiter().GetResult()

            $buf = New-Object byte[] 65536
            $ms = New-Object System.IO.MemoryStream
            while ($State.Run -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open -and $State.Channel -eq $chanReq) {
                $cts = New-Object System.Threading.CancellationTokenSource
                $cts.CancelAfter(45000)   # aucun keepalive pendant 45 s = connexion morte
                try {
                    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buf)
                    $r = $ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
                } finally { $cts.Dispose() }
                if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'connexion fermée par Twitch' }
                $ms.Write($buf, 0, $r.Count)
                if (-not $r.EndOfMessage) { continue }
                $json = $enc.GetString($ms.ToArray())
                $ms.SetLength(0)
                $j = $json | ConvertFrom-Json

                switch ([string]$j.metadata.message_type) {
                    'session_welcome' {
                        $sid = [string]$j.payload.session.id
                        $b = $State.BroadcasterId; $me = $State.UserId
                        foreach ($t in 'channel.chat.message', 'channel.chat.message_delete', 'channel.chat.clear_user_messages', 'channel.chat.clear') {
                            Add-Sub $t '1' @{ broadcaster_user_id = $b; user_id = $me } $sid
                        }
                        try {
                            Add-Sub 'automod.message.hold'   '2' @{ broadcaster_user_id = $b; moderator_user_id = $me } $sid
                            Add-Sub 'automod.message.update' '2' @{ broadcaster_user_id = $b; moderator_user_id = $me } $sid
                            Say ("Connecté en tant que " + $State.Login + " sur #" + $chan + ". AutoMod actif. Clic droit sur un message pour le modérer.")
                        } catch {
                            Say ("Connecté sur #" + $chan + ", mais AutoMod indisponible : " + $_.Exception.Message)
                        }
                    }
                    'session_reconnect' { throw 'Twitch demande une reconnexion' }
                    'revocation'        { Say ("Abonnement Twitch révoqué : " + $j.payload.subscription.type) }
                    'notification' {
                        $e = $j.payload.event
                        switch ([string]$j.payload.subscription.type) {
                            'channel.chat.message' {
                                $badges = @(); foreach ($bd in @($e.badges)) { if ($bd) { $badges += [string]$bd.set_id } }
                                $parts = @()
                                foreach ($fr in @($e.message.fragments)) {
                                    if (-not $fr) { continue }
                                    if ([string]$fr.type -eq 'emote' -and $fr.emote -and $fr.emote.id) {
                                        $parts += ,@{ U = 'https://static-cdn.jtvnw.net/emoticons/v2/' + [string]$fr.emote.id + '/default/dark/2.0'; T = [string]$fr.text }
                                    } elseif ($bttv.Count -gt 0) {
                                        $acc = ''
                                        foreach ($tok in [regex]::Split([string]$fr.text, '(\s+)')) {
                                            if ($tok -and $bttv.ContainsKey($tok)) {
                                                if ($acc) { $parts += ,@{ T = $acc }; $acc = '' }
                                                $parts += ,@{ U = $bttv[$tok]; T = $tok }
                                            } else { $acc += $tok }
                                        }
                                        if ($acc) { $parts += ,@{ T = $acc } }
                                    } else { $parts += ,@{ T = [string]$fr.text } }
                                }
                                Push @{ Kind = 'msg'; Name = [string]$e.chatter_user_name; Login = [string]$e.chatter_user_login
                                        UserId = [string]$e.chatter_user_id; Color = [string]$e.color; Text = [string]$e.message.text
                                        MsgId = [string]$e.message_id; Badges = $badges; Parts = $parts }
                            }
                            'channel.chat.message_delete'      { Push @{ Kind = 'del'; MsgId = [string]$e.message_id } }
                            'channel.chat.clear_user_messages' { Push @{ Kind = 'clearuser'; UserId = [string]$e.target_user_id } }
                            'channel.chat.clear'               { Push @{ Kind = 'clear' } }
                            'automod.message.hold' {
                                $why = 'AutoMod'
                                if ($e.reason -eq 'blocked_term') { $why = 'terme bloqué' }
                                elseif ($e.automod -and $e.automod.category) { $why = 'AutoMod : ' + $e.automod.category + ', niveau ' + $e.automod.level }
                                Push @{ Kind = 'held'; HeldId = [string]$e.message_id; Name = [string]$e.user_name; UserId = [string]$e.user_id
                                        Text = [string]$e.message.text; Reason = $why }
                            }
                            'automod.message.update' {
                                Push @{ Kind = 'heldupdate'; HeldId = [string]$e.message_id; Status = [string]$e.status; By = [string]$e.moderator_user_name }
                            }
                        }
                    }
                }
            }
        }
        catch {
            if ($State.Run -and $State.Channel -eq $chanReq) {
                Say ("Déconnecté (" + $_.Exception.GetBaseException().Message + "). Nouvelle tentative dans $delay s...")
                for ($i = 0; $i -lt ($delay * 10) -and $State.Run -and $State.Channel -eq $chanReq; $i++) { Start-Sleep -Milliseconds 100 }
            }
        }
        finally {
            if ($ws) { try { $ws.Dispose() } catch {} }
        }
    }
}

$ps = [PowerShell]::Create()
[void]$ps.AddScript($worker).AddArgument($queue).AddArgument($State).AddArgument($commonCode)
[void]$ps.BeginInvoke()

# ---------------------------------------------------------------- Worker TikTok : lecture du chat de TikTok LIVE Studio
# LIVE Studio doit être lancé avec --remote-debugging-port=9222 (raccourci « TikTok LIVE Studio (Chat WoW) »).
# On lit, en local et en lecture seule, la page du chat de LIVE Studio et on récupère les nouveaux messages.
$ttWorker = {
    param($Queue, $State)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    function Say([string]$t) { $Queue.Enqueue(@{ Kind = 'ttsys'; Text = $t }) }

    $collector = @'
(function () {
  if (window.__wowtt && window.__wowtt.v === 2) return 'ok';
  var st = { v: 2, q: [], seen: {} };
  window.__wowtt = st;
  function txt(el) { return el ? (el.textContent || '').trim() : ''; }
  function scan() {
    var rows = document.querySelectorAll('#comment-list [data-index]');
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i];
      var ui = row.querySelector('[class^="user-info-"],[id^="-ChatMsg-"]');
      var id = ui && ui.id;
      if (!id || st.seen[id]) continue;
      st.seen[id] = 1;
      var name = txt(row.querySelector('[class^="username-"]'));
      var t = row.querySelector('[class^="msg-content-"] .text') || row.querySelector('[class^="msg-content-"]');
      var text = txt(t), parts = [];
      if (t) {
        var w = document.createTreeWalker(t, NodeFilter.SHOW_TEXT | NodeFilter.SHOW_ELEMENT, null);
        var n;
        while ((n = w.nextNode())) {
          if (n.nodeType === 3) { if (n.nodeValue) parts.push({ T: n.nodeValue }); }
          else if (n.tagName === 'IMG') {
            var src = n.currentSrc || n.src || '';
            if (/^https?:/i.test(src)) parts.push({ U: src, T: n.alt || '' });
            else if (n.alt) parts.push({ T: n.alt });
          }
        }
      }
      if (name || text || parts.length) st.q.push({ id: id, name: name, text: text, parts: parts });
    }
  }
  scan();
  new MutationObserver(scan).observe(document.documentElement, { childList: true, subtree: true });
  setInterval(scan, 700);
  return 'installed';
})()
'@
    $pull = "(function(){ if(!window.__wowtt) return null; return JSON.stringify(window.__wowtt.q.splice(0)); })()"
    $probe = "!!document.querySelector('#comment-list')"

    $enc = New-Object System.Text.UTF8Encoding($false)
    $script:msgId = 0

    function Receive-Text($ws) {
        $buf = New-Object byte[] 65536
        $ms = New-Object System.IO.MemoryStream
        do {
            $cts = New-Object System.Threading.CancellationTokenSource
            $cts.CancelAfter(10000)
            try { $r = $ws.ReceiveAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList (,$buf)), $cts.Token).GetAwaiter().GetResult() }
            finally { $cts.Dispose() }
            if ($r.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw 'fenêtre LIVE Studio fermée' }
            $ms.Write($buf, 0, $r.Count)
        } while (-not $r.EndOfMessage)
        return $enc.GetString($ms.ToArray())
    }

    function Invoke-Eval($ws, [string]$expr) {
        $script:msgId++
        $id = $script:msgId
        $json = @{ id = $id; method = 'Runtime.evaluate'; params = @{ expression = $expr; returnByValue = $true } } | ConvertTo-Json -Compress -Depth 5
        $b = $enc.GetBytes($json)
        [void]$ws.SendAsync((New-Object 'System.ArraySegment[byte]' -ArgumentList (,$b)), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        while ($true) {
            $resp = Receive-Text $ws | ConvertFrom-Json
            if ($resp.id -eq $id) {
                if ($resp.result.exceptionDetails) { return $null }
                return $resp.result.result.value
            }
        }
    }

    function Open-Ws([string]$url) {
        $ws = New-Object System.Net.WebSockets.ClientWebSocket
        [void]$ws.ConnectAsync([Uri]$url, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
        return $ws
    }

    function Find-ChatTarget {
        $list = Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:9222/json/list' -TimeoutSec 3
        $cands = @($list | Where-Object { $_.webSocketDebuggerUrl -and $_.type -in @('page', 'webview', 'iframe', 'other') })
        # La fenêtre de chat flottante d'abord, puis les autres pages qui contiennent une liste de commentaires
        $ordered = @($cands | Where-Object { $_.url -match 'liveChatFloat' }) + @($cands | Where-Object { $_.url -notmatch 'liveChatFloat' })
        foreach ($t in $ordered) {
            $ws = $null
            try {
                $ws = Open-Ws $t.webSocketDebuggerUrl
                if ((Invoke-Eval $ws $probe) -eq $true) { return @{ Ws = $ws; Url = $t.url } }
            } catch {}
            if ($ws) { try { $ws.Dispose() } catch {} }
        }
        return $null
    }

    $lastStatus = ''
    while ($State.Run) {
        $conn = $null
        try {
            try { $conn = Find-ChatTarget } catch { $conn = $null }
            if (-not $conn) {
                $s = 'notfound'
                if ($s -ne $lastStatus) {
                    Say "TikTok LIVE Studio n'est pas détecté. Lance-le avec le raccourci « TikTok LIVE Studio (Chat WoW) » sur ton bureau, puis ouvre le chat du live."
                    $lastStatus = $s
                }
                for ($i = 0; $i -lt 50 -and $State.Run; $i++) { Start-Sleep -Milliseconds 100 }
                continue
            }
            $ws = $conn.Ws
            [void](Invoke-Eval $ws $collector)
            if ($lastStatus -ne 'ok') { Say 'Connecté au chat de TikTok LIVE Studio.'; $lastStatus = 'ok' }
            while ($State.Run -and $ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
                $v = Invoke-Eval $ws $pull
                if ($null -eq $v) { [void](Invoke-Eval $ws $collector) }   # page rechargée : on réinstalle le collecteur
                else {
                    foreach ($m in @($v | ConvertFrom-Json)) {
                        if ($m) {
                            $parts = @(); foreach ($pt in @($m.parts)) { if ($pt) { $parts += ,@{ T = [string]$pt.T; U = [string]$pt.U } } }
                            $Queue.Enqueue(@{ Kind = 'tt'; Name = [string]$m.name; Text = [string]$m.text; MsgId = [string]$m.id; Parts = $parts })
                        }
                    }
                }
                Start-Sleep -Milliseconds 400
            }
        } catch {
            if ($lastStatus -eq 'ok') { Say ('Chat TikTok déconnecté (' + $_.Exception.GetBaseException().Message + '). Nouvelle tentative...'); $lastStatus = 'lost' }
            for ($i = 0; $i -lt 30 -and $State.Run; $i++) { Start-Sleep -Milliseconds 100 }
        } finally {
            if ($conn -and $conn.Ws) { try { $conn.Ws.Dispose() } catch {} }
        }
    }
}

$ps2 = [PowerShell]::Create()
[void]$ps2.AddScript($ttWorker).AddArgument($queue).AddArgument($State)
[void]$ps2.BeginInvoke()


# ---------------------------------------------------------------- Fenêtre WPF
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Twitch Chat" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="CanResizeWithGrip"
        MinWidth="280" MinHeight="200" FontFamily="Segoe UI, Segoe UI Emoji, Segoe UI Symbol">
  <Window.Resources>
    <LinearGradientBrush x:Key="Bronze" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#E2C27A" Offset="0"/>
      <GradientStop Color="#9C7230" Offset="0.45"/>
      <GradientStop Color="#5A3C14" Offset="1"/>
    </LinearGradientBrush>
    <Style x:Key="WowButton" TargetType="Button">
      <Setter Property="Width" Value="22"/>
      <Setter Property="Height" Value="22"/>
      <Setter Property="Margin" Value="3,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{StaticResource Bronze}"
                    BorderThickness="1.5" CornerRadius="2">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.8"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <LinearGradientBrush x:Key="RedBtn" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#C8281C" Offset="0"/><GradientStop Color="#6E0E08" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="DarkBtn" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#4A3520" Offset="0"/><GradientStop Color="#1A120A" Offset="1"/>
    </LinearGradientBrush>
    <LinearGradientBrush x:Key="OrangeBtn" StartPoint="0,0" EndPoint="0,1">
      <GradientStop Color="#D9821E" Offset="0"/><GradientStop Color="#7A3A08" Offset="1"/>
    </LinearGradientBrush>
    <Style x:Key="FlatButton" TargetType="Button">
      <Setter Property="Width" Value="20"/>
      <Setter Property="Height" Value="18"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Foreground" Value="#FFD100"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#33FFD100"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="16,16,0,0">
    <Border x:Name="Frame" BorderBrush="{StaticResource Bronze}" BorderThickness="3" CornerRadius="4">
      <Border BorderBrush="#000000" BorderThickness="1" CornerRadius="2">
        <Grid x:Name="Root">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <!-- Barre de titre (comme "Carte &amp; journal des quêtes") -->
          <Border x:Name="Header" Grid.Row="0" Height="28" BorderBrush="{StaticResource Bronze}" BorderThickness="0,0,0,2" Cursor="SizeAll">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                <GradientStop Color="#2E2116" Offset="0"/><GradientStop Color="#0E0905" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <Grid>
              <TextBlock x:Name="TitleText" Text="Chat Twitch" Foreground="#FFD100" FontSize="16"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Margin="40,0,112,0" TextTrimming="CharacterEllipsis">
                <TextBlock.Effect><DropShadowEffect Color="Black" BlurRadius="2" ShadowDepth="1" Opacity="1"/></TextBlock.Effect>
              </TextBlock>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,3,0">
                <Button x:Name="BtnClear" Style="{StaticResource WowButton}" Background="{StaticResource DarkBtn}" ToolTip="Vider le chat de l'onglet actif">
                  <Canvas Width="14" Height="14">
                    <Line X1="13" Y1="1" X2="7.2" Y2="6.8" Stroke="#C98B3A" StrokeThickness="1.8" StrokeStartLineCap="Round"/>
                    <Path Fill="#FFD100" Data="M5.6,5.2 L8.8,8.4 L6.2,12.6 C4.2,13.6 2.2,13.6 0.6,13.4 C0.4,11.8 0.6,9.8 1.4,7.8 Z"/>
                    <Path Stroke="#7A5418" StrokeThickness="0.8" Data="M3.2,8.6 L1.6,12.2 M4.8,10 L3.4,13.2 M6.4,10.6 L5.2,13"/>
                    <Line X1="5" Y1="5.8" X2="8.2" Y2="9" Stroke="#C98B3A" StrokeThickness="1.4"/>
                  </Canvas>
                </Button>
                <Button x:Name="BtnMinus" Style="{StaticResource WowButton}" Background="{StaticResource DarkBtn}" ToolTip="Fond plus transparent">
                  <TextBlock Text="−" Foreground="#FFD100" FontWeight="Bold" FontSize="14" Margin="0,-3,0,0"/>
                </Button>
                <Button x:Name="BtnPlus" Style="{StaticResource WowButton}" Background="{StaticResource DarkBtn}" ToolTip="Fond plus opaque">
                  <TextBlock Text="+" Foreground="#FFD100" FontWeight="Bold" FontSize="14" Margin="0,-3,0,0"/>
                </Button>
                <Button x:Name="BtnLock" Style="{StaticResource WowButton}" Background="{StaticResource OrangeBtn}"
                        ToolTip="Clic à travers : la souris passe au jeu (Ctrl+Alt+T pour revenir)">
                  <Canvas Width="10" Height="12">
                    <Path Data="M2,6 L2,3.5 A3,3 0 0 1 8,3.5 L8,6" Stroke="#FFD100" StrokeThickness="1.6"/>
                    <Rectangle Canvas.Left="0" Canvas.Top="5.5" Width="10" Height="6.5" Fill="#FFD100" RadiusX="1" RadiusY="1"/>
                  </Canvas>
                </Button>
                <Button x:Name="BtnClose" Style="{StaticResource WowButton}" Background="{StaticResource RedBtn}" ToolTip="Masquer (le bouton de la minimap le réaffiche)">
                  <Path Data="M0,0 L9,9 M9,0 L0,9" Stroke="#FFD100" StrokeThickness="2.2"/>
                </Button>
              </StackPanel>
            </Grid>
          </Border>

          <!-- Bandeau de section (comme "Les Paluns") -->
          <Border x:Name="SubHeader" Grid.Row="1" Visibility="Collapsed" Margin="8,6,8,2" Padding="10,3,4,3" CornerRadius="2"
                  BorderBrush="#6B4E25" BorderThickness="1">
            <Border.Background>
              <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                <GradientStop Color="#4A3520" Offset="0"/><GradientStop Color="#2A1D10" Offset="0.7"/><GradientStop Color="#1A120A" Offset="1"/>
              </LinearGradientBrush>
            </Border.Background>
            <DockPanel>
              <StackPanel DockPanel.Dock="Right" Orientation="Horizontal">
              </StackPanel>
              <TextBlock x:Name="ChanText" Foreground="#D9C7A0" FontSize="16" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
          </Border>

          <!-- Onglets Twitch / TikTok -->
          <DockPanel Grid.Row="1" Margin="10,6,10,0" LastChildFill="True">
          <StackPanel DockPanel.Dock="Right" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,0,0,3">
            <Border x:Name="BtnOBS" Cursor="Hand" Width="28" Height="24" CornerRadius="3" BorderThickness="1" BorderBrush="#5A3C14" Background="#1A120A" Margin="0,0,4,0" ToolTip="Lancer OBS (stream Twitch)">
              <Grid>
                <TextBlock x:Name="TxtOBS" Text="OBS" FontSize="10" FontWeight="Bold" Foreground="#E8D9B0" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Image x:Name="ImgOBS" Width="18" Height="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <Border x:Name="BtnTT" Cursor="Hand" Width="28" Height="24" CornerRadius="3" BorderThickness="1" BorderBrush="#5A3C14" Background="#1A120A" ToolTip="Lancer TikTok LIVE Studio">
              <Grid>
                <TextBlock x:Name="TxtTT" Text="TT" FontSize="10" FontWeight="Bold" Foreground="#25F4EE" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Image x:Name="ImgTT" Width="18" Height="18" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
            </Border>
          </StackPanel>
          <StackPanel x:Name="TabBar" Orientation="Horizontal">
            <Border x:Name="TabTwitch" Cursor="Hand" CornerRadius="4,4,0,0" BorderThickness="1,1,1,0" Padding="14,3" Margin="0,0,4,0">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="8" Height="8" Fill="#9146FF" Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="TabTwitchText" Text="Twitch" FontSize="15" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
            <Border x:Name="TabTikTok" Cursor="Hand" CornerRadius="4,4,0,0" BorderThickness="1,1,1,0" Padding="14,3">
              <StackPanel Orientation="Horizontal">
                <Ellipse Width="8" Height="8" Fill="#25F4EE" Margin="0,0,6,0" VerticalAlignment="Center"/>
                <TextBlock x:Name="TabTikTokText" Text="TikTok" FontSize="15" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
          </StackPanel>
          </DockPanel>

          <Border Grid.Row="2" Margin="8,0,8,4" BorderBrush="#6B4E25" BorderThickness="1" CornerRadius="0,2,2,2">
            <Grid>
              <ScrollViewer x:Name="Scroll" VerticalScrollBarVisibility="Hidden" Margin="6,4,4,4">
                <StackPanel x:Name="Messages"/>
              </ScrollViewer>
              <ScrollViewer x:Name="ScrollTT" VerticalScrollBarVisibility="Hidden" Margin="6,4,4,4" Visibility="Collapsed">
                <StackPanel x:Name="MessagesTT"/>
              </ScrollViewer>
            </Grid>
          </Border>

          <!-- Zone de saisie -->
          <Border x:Name="InputBar" Grid.Row="3" Margin="8,2,20,8" BorderBrush="#6B4E25" BorderThickness="1" CornerRadius="2" Background="#E00A0705">
            <Grid>
              <TextBox x:Name="ChatInput" Background="Transparent" Foreground="White" CaretBrush="#FFD100" BorderThickness="0"
                       Padding="6,4" FontSize="15" MaxLength="500"/>
              <TextBlock x:Name="Placeholder" Text="Envoyer un message dans le chat..." Foreground="#806F55" Margin="9,5,0,0"
                         IsHitTestVisible="False" FontSize="15"/>
            </Grid>
          </Border>
        </Grid>
      </Border>
    </Border>

    <!-- Médaillon rond en haut à gauche (comme sur la carte) -->
    <Grid x:Name="Emblem" Width="56" Height="56" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="-16,-16,0,0" Cursor="SizeAll">
      <Ellipse Stroke="{StaticResource Bronze}" StrokeThickness="4">
        <Ellipse.Fill>
          <RadialGradientBrush>
            <GradientStop Color="#3A2A1A" Offset="0"/><GradientStop Color="#120C06" Offset="1"/>
          </RadialGradientBrush>
        </Ellipse.Fill>
      </Ellipse>
      <Ellipse Margin="4" Stroke="#000000" StrokeThickness="1"/>
      <Viewbox Width="26" Height="26">
        <Canvas Width="22" Height="22">
          <Path Data="M2,0 L21,0 L21,13 L16,18 L12,18 L9,21 L9,18 L2,18 Z" Fill="#9146FF" Stroke="#E2C27A" StrokeThickness="0.8"/>
          <Rectangle Canvas.Left="9" Canvas.Top="5" Width="2.2" Height="6" Fill="White"/>
          <Rectangle Canvas.Left="14" Canvas.Top="5" Width="2.2" Height="6" Fill="White"/>
        </Canvas>
      </Viewbox>
    </Grid>
  </Grid>
</Window>
"@

$win         = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$root        = $win.FindName('Root')
$frame       = $win.FindName('Frame')
$header      = $win.FindName('Header')
$subHeader   = $win.FindName('SubHeader')
$emblem      = $win.FindName('Emblem')
$chanText    = $win.FindName('TitleText')   # le nom de la chaîne s'affiche dans le titre
$scroll      = $win.FindName('Scroll')
$messages    = $win.FindName('Messages')
$inputBar    = $win.FindName('InputBar')
$chatInput   = $win.FindName('ChatInput')
$placeholder = $win.FindName('Placeholder')
$scrollTT    = $win.FindName('ScrollTT')
$messagesTT  = $win.FindName('MessagesTT')
$tabTwitch   = $win.FindName('TabTwitch')
$tabTikTok   = $win.FindName('TabTikTok')
$tabTwitchTx = $win.FindName('TabTwitchText')
$tabTikTokTx = $win.FindName('TabTikTokText')

# Police d'ElvUI (PT Sans Narrow), copiée dans le dossier Fonts
$fontFile = Join-Path $here 'Fonts\PTSansNarrow.ttf'
if (Test-Path $fontFile) {
    try {
        $fontDir = New-Object System.Uri ((Join-Path $here 'Fonts') + '\')
        $win.FontFamily = New-Object System.Windows.Media.FontFamily($fontDir, './#PT Sans Narrow, Segoe UI Emoji, Segoe UI Symbol')
    } catch { Write-Log "Police PT Sans Narrow non chargée : $_" }
}

function Set-DefaultPlacement {
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Width = 560; $win.Height = 460
    $win.Left = $wa.Left + ($wa.Width - $win.Width) / 2
    $win.Top  = $wa.Top + ($wa.Height - $win.Height) / 2
}
$win.Width = [double]$cfg.Width; $win.Height = [double]$cfg.Height
$vsW = [System.Windows.SystemParameters]::VirtualScreenWidth; $vsH = [System.Windows.SystemParameters]::VirtualScreenHeight
if (([double]$cfg.Left -eq -1 -and [double]$cfg.Top -eq -1) -or [double]$cfg.Left -lt (80 - $win.Width) -or [double]$cfg.Top -lt -20 -or [double]$cfg.Left -gt ($vsW - 80) -or [double]$cfg.Top -gt ($vsH - 40)) {
    # pas encore de position, ou fenêtre presque hors de l'écran : on la centre
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Left + ($wa.Width - $win.Width) / 2
    $win.Top  = $wa.Top + ($wa.Height - $win.Height) / 2
} else {
    $win.Left = [double]$cfg.Left; $win.Top = [double]$cfg.Top
}
$chanText.Text = if ($cfg.Channel) { "Chat Twitch - " + $cfg.Channel } else { "Chat Twitch" }

$brushConv = New-Object System.Windows.Media.BrushConverter
function Get-Brush([string]$hex) { return $brushConv.ConvertFromString($hex) }

$bgBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(18, 13, 9))
$bgBrush.Opacity = [double]$cfg.Opacity
$root.Background = $bgBrush

$palette = @('#FF4500', '#1E90FF', '#9ACD32', '#FF69B4', '#DAA520', '#00FF7F', '#D2691E', '#5F9EA0', '#B22222', '#8A2BE2', '#2E8B57', '#FF7F50')
$white  = Get-Brush '#F2F2F2'
$grey   = Get-Brush '#A8A8A8'
$gold   = Get-Brush '#FFD100'
$hover  = Get-Brush '#26FFD100'
$transp = [System.Windows.Media.Brushes]::Transparent
$badgeInfo = @{
    broadcaster = @('Streamer', '#E91916')
    moderator   = @('Mod', '#00AD03')
    vip         = @('VIP', '#E005B9')
}
$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.Color = [System.Windows.Media.Colors]::Black; $shadow.BlurRadius = 3; $shadow.ShadowDepth = 1; $shadow.Opacity = 1

$msgIndex  = @{}   # message_id -> TextBlock
$heldIndex = @{}   # message AutoMod -> éléments du bloc

function Get-NameBrush([string]$name, [string]$hex) {
    if ($hex -match '^#[0-9A-Fa-f]{6}$') { return Get-Brush $hex }
    $sum = 0; foreach ($c in $name.ToCharArray()) { $sum += [int]$c }
    return Get-Brush $palette[$sum % $palette.Count]
}

function New-Run([string]$text, $brush, [switch]$Bold, [switch]$Italic) {
    $r = [System.Windows.Documents.Run]::new($text)
    $r.Foreground = $brush
    if ($Bold) { $r.FontWeight = 'Bold' }
    if ($Italic) { $r.FontStyle = 'Italic' }
    return $r
}

$emoteCache = @{}
$emoteFailed = @{}
# Emojis en couleur : images Twemoji (la police de la fenêtre ne sait les dessiner qu'en noir et blanc)
$emojiRx = New-Object System.Text.RegularExpressions.Regex ('(?:[\uD83C-\uD83E][\uDC00-\uDFFF]|[☀-➿⬅-⭕⤴⤵〰〽㊗㊙‼⁉™ℹ↔-↪⌚⌛⌨⏏-⏺Ⓜ▪-◾©®])️?(?:‍(?:[\uD83C-\uD83E][\uDC00-\uDFFF]|[☀-➿⬅-⭕])️?)*')

function Get-EmojiUrl([string]$e) {
    $cps = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $e.Length; $i++) {
        if ([char]::IsHighSurrogate($e[$i]) -and $i + 1 -lt $e.Length) { $cp = [char]::ConvertToUtf32($e[$i], $e[$i + 1]); $i++ }
        else { $cp = [int]$e[$i] }
        $cps.Add(('{0:x}' -f $cp))
    }
    if (-not $cps.Contains('200d')) { [void]$cps.RemoveAll([Predicate[string]]{ param($x) $x -eq 'fe0f' }) }
    return 'https://cdn.jsdelivr.net/gh/jdecked/twemoji@15.1.0/assets/72x72/' + ($cps -join '-') + '.png'
}

function Add-InlineImage($tb, [string]$url, [string]$alt, [double]$scale) {
    if ($emoteFailed.ContainsKey($url)) { if ($alt) { $tb.Inlines.Add((New-Run $alt $white)) }; return }
    $bmp = $emoteCache[$url]
    if (-not $bmp) {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit(); $bmp.UriSource = [Uri]$url; $bmp.CacheOption = 'OnLoad'; $bmp.EndInit()
        if ($emoteCache.Count -gt 800) { $emoteCache.Clear() }
        $emoteCache[$url] = $bmp
    }
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $bmp
    $img.Height = [Math]::Round([double]$cfg.FontSize * $scale)
    $img.Stretch = 'Uniform'
    $img.Margin = '1,-2,1,-4'
    $img.Tag = @{ Url = $url; Alt = $alt }
    if ($alt) { $img.ToolTip = $alt }
    $holder = New-Object System.Windows.Controls.Grid
    [void]$holder.Children.Add($img)
    # Image introuvable : on remet le texte à la place
    $img.Add_ImageFailed({
        param($s, $ev)
        try {
            $emoteFailed[$s.Tag.Url] = 1
            $h = $s.Parent; $h.Children.Clear()
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = [string]$s.Tag.Alt; $t.Foreground = $white
            [void]$h.Children.Add($t)
        } catch {}
    })
    $ui = New-Object System.Windows.Documents.InlineUIContainer($holder)
    $ui.BaselineAlignment = 'Center'
    $tb.Inlines.Add($ui)
}

function Add-TextWithEmoji($tb, [string]$text) {
    if (-not $text) { return }
    $pos = 0
    foreach ($m in $emojiRx.Matches($text)) {
        if ($m.Index -gt $pos) { $tb.Inlines.Add((New-Run $text.Substring($pos, $m.Index - $pos) $white)) }
        try { Add-InlineImage $tb (Get-EmojiUrl $m.Value) $m.Value 1.3 }
        catch { $tb.Inlines.Add((New-Run $m.Value $white)) }
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $text.Length) { $tb.Inlines.Add((New-Run $text.Substring($pos) $white)) }
}

function Add-MessageBody($tb, $item) {
    $tb.Inlines.Add((New-Run ' : ' $white))
    $parts = @($item.Parts | Where-Object { $_ })
    if ($parts.Count -eq 0) { Add-TextWithEmoji $tb $item.Text; return }
    foreach ($pt in $parts) {
        if ($pt.U) {
            try { Add-InlineImage $tb $pt.U $pt.T 1.6; continue } catch {}
        }
        Add-TextWithEmoji $tb $pt.T
    }
}

function New-Line {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.TextWrapping = 'Wrap'
    $tb.FontSize = [double]$cfg.FontSize
    $tb.Margin = '0,1,0,1'
    $tb.Padding = '2,0,2,0'
    $tb.Effect = $shadow
    return $tb
}

function Fill-MessageLine($tb, $item, [bool]$deleted) {
    $tb.Inlines.Clear()
    foreach ($b in @($item.Badges)) {
        if ($badgeInfo.ContainsKey($b)) {
            $tb.Inlines.Add((New-Run ('[' + $badgeInfo[$b][0] + ']  ') (Get-Brush $badgeInfo[$b][1]) -Bold))
        }
    }
    $tb.Inlines.Add((New-Run $item.Name (Get-NameBrush $item.Name $item.Color) -Bold))
    if ($deleted) { $tb.Inlines.Add((New-Run ' : <message supprimé>' $grey -Italic)) }
    else          { Add-MessageBody $tb $item }
}

function Add-Element($el) {
    [void]$messages.Children.Add($el)
    while ($messages.Children.Count -gt [int]$cfg.MaxMessages) { $messages.Children.RemoveAt(0) }
    if ($msgIndex.Count -gt 2000) { $msgIndex.Clear() }
}

function Add-TTElement($el) {
    [void]$messagesTT.Children.Add($el)
    while ($messagesTT.Children.Count -gt [int]$cfg.MaxMessages) { $messagesTT.Children.RemoveAt(0) }
}

function Add-Sys([string]$text) {
    $tb = New-Line
    $tb.Inlines.Add((New-Run $text $grey -Italic))
    Add-Element $tb
    $scroll.UpdateLayout(); $scroll.ScrollToEnd()
}

# ----- Menu clic droit sur un message
$msgMenu = New-Object System.Windows.Controls.ContextMenu
$miWho   = New-Object System.Windows.Controls.MenuItem; $miWho.IsEnabled = $false; $miWho.FontWeight = 'Bold'
$miDel   = New-Object System.Windows.Controls.MenuItem; $miDel.Header = 'Supprimer le message'
$miTo1   = New-Object System.Windows.Controls.MenuItem; $miTo1.Header = 'Timeout 1 minute'
$miTo10  = New-Object System.Windows.Controls.MenuItem; $miTo10.Header = 'Timeout 10 minutes'
$miTo60  = New-Object System.Windows.Controls.MenuItem; $miTo60.Header = 'Timeout 1 heure'
$miBan   = New-Object System.Windows.Controls.MenuItem; $miBan.Header = 'Bannir...'
foreach ($m in @($miWho, (New-Object System.Windows.Controls.Separator), $miDel, $miTo1, $miTo10, $miTo60, (New-Object System.Windows.Controls.Separator), $miBan)) {
    [void]$msgMenu.Items.Add($m)
}
$msgMenu.Add_Opened({ $miWho.Header = $msgMenu.PlacementTarget.Tag.Name })

function Invoke-ModAction([string]$what) {
    $t = $msgMenu.PlacementTarget.Tag
    if (-not $t) { return }
    $b = $State.BroadcasterId; $me = $State.UserId
    try {
        switch ($what) {
            'delete' {
                [void](Invoke-Helix 'DELETE' ("moderation/chat?broadcaster_id=$b&moderator_id=$me&message_id=" + $t.MsgId))
            }
            'ban' {
                $ok = [System.Windows.MessageBox]::Show("Bannir définitivement " + $t.Name + " de la chaîne ?", "Bannir", 'YesNo', 'Warning')
                if ($ok -ne 'Yes') { return }
                [void](Invoke-Helix 'POST' "moderation/bans?broadcaster_id=$b&moderator_id=$me" @{ data = @{ user_id = $t.UserId } })
                Add-Sys ($t.Name + " a été banni.")
            }
            default {
                $sec = [int]$what
                [void](Invoke-Helix 'POST' "moderation/bans?broadcaster_id=$b&moderator_id=$me" @{ data = @{ user_id = $t.UserId; duration = $sec } })
                Add-Sys ($t.Name + " est en timeout pour " + [int]($sec / 60) + " min.")
            }
        }
    } catch { Add-Sys ("Action impossible : " + $_.Exception.Message) }
}
$miDel.Add_Click({  Invoke-ModAction 'delete' })
$miTo1.Add_Click({  Invoke-ModAction '60' })
$miTo10.Add_Click({ Invoke-ModAction '600' })
$miTo60.Add_Click({ Invoke-ModAction '3600' })
$miBan.Add_Click({  Invoke-ModAction 'ban' })

# ----- Bloc AutoMod
function Resolve-Held([string]$heldId, [string]$action) {
    try {
        [void](Invoke-Helix 'POST' 'moderation/automod/message' @{ user_id = $State.UserId; msg_id = $heldId; action = $action })
        if ($action -eq 'ALLOW') { Set-HeldStatus $heldId 'Approved' '' } else { Set-HeldStatus $heldId 'Denied' '' }
    } catch { Add-Sys ("AutoMod : action impossible : " + $_.Exception.Message) }
}

function Set-HeldStatus([string]$heldId, [string]$status, [string]$by) {
    $h = $heldIndex[$heldId]
    if (-not $h) { return }
    switch ($status) {
        'Approved' { $txt = 'Autorisé'; $col = '#3FBF3F' }
        'Denied'   { $txt = 'Refusé';   $col = '#E04040' }
        'Expired'  { $txt = 'Expiré';   $col = '#A8A8A8' }
        default    { $txt = $status;    $col = '#A8A8A8' }
    }
    if ($by) { $txt += ' par ' + $by }
    $h.Buttons.Visibility = 'Collapsed'
    $h.Status.Text = $txt
    $h.Status.Foreground = Get-Brush $col
    $h.Status.Visibility = 'Visible'
    $h.Border.BorderBrush = Get-Brush $col
}

function New-HeldButton([string]$label, [string]$c1, [string]$c2, [string]$heldId, [string]$action) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $win.FindResource('WowButton')
    $btn.Width = [double]::NaN; $btn.Height = 24; $btn.Margin = '0,4,6,0'
    $g = New-Object System.Windows.Media.LinearGradientBrush ((Get-Brush $c1).Color), ((Get-Brush $c2).Color), 90
    $btn.Background = $g
    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $label; $lbl.Foreground = $gold; $lbl.FontWeight = 'Bold'; $lbl.Margin = '12,0,12,0'
    $btn.Content = $lbl
    $btn.Tag = @($heldId, $action)
    $btn.Add_Click({ param($s, $e) Resolve-Held $s.Tag[0] $s.Tag[1] })
    return $btn
}

function Add-HeldBlock($item) {
    $bd = New-Object System.Windows.Controls.Border
    $bd.BorderBrush = Get-Brush '#D9821E'; $bd.BorderThickness = '3,1,1,1'; $bd.CornerRadius = '2'
    $bd.Background = Get-Brush '#3326160A'; $bd.Padding = '8,4,8,6'; $bd.Margin = '0,4,0,4'
    $sp = New-Object System.Windows.Controls.StackPanel

    $t1 = New-Line
    $t1.Inlines.Add((New-Run 'Message retenu ' $gold -Bold))
    $t1.Inlines.Add((New-Run ('(' + $item.Reason + ')') $grey -Italic))
    $t2 = New-Line
    $t2.Inlines.Add((New-Run $item.Name (Get-NameBrush $item.Name '') -Bold))
    $t2.Inlines.Add((New-Run (' : ' + $item.Text) $white))

    $btns = New-Object System.Windows.Controls.StackPanel
    $btns.Orientation = 'Horizontal'
    [void]$btns.Children.Add((New-HeldButton 'Autoriser' '#3E9B2E' '#1C4A12' $item.HeldId 'ALLOW'))
    [void]$btns.Children.Add((New-HeldButton 'Refuser'   '#C8281C' '#6E0E08' $item.HeldId 'DENY'))

    $st = New-Line
    $st.FontWeight = 'Bold'; $st.Visibility = 'Collapsed'

    foreach ($x in @($t1, $t2, $btns, $st)) { [void]$sp.Children.Add($x) }
    $bd.Child = $sp
    $heldIndex[$item.HeldId] = @{ Border = $bd; Buttons = $btns; Status = $st }
    Add-Element $bd
}

function Add-ChatItem($item) {
    switch ($item.Kind) {
        'sys' {
            $tb = New-Line
            $tb.Inlines.Add((New-Run $item.Text $grey -Italic))
            Add-Element $tb
        }
        'msg' {
            $tb = New-Line
            Fill-MessageLine $tb $item $false
            $tb.Tag = $item
            $tb.ContextMenu = $msgMenu
            $tb.Add_MouseEnter({ $this.Background = $hover })
            $tb.Add_MouseLeave({ $this.Background = $transp })
            $msgIndex[$item.MsgId] = $tb
            Add-Element $tb
        }
        'del' {
            $tb = $msgIndex[$item.MsgId]
            if ($tb) { Fill-MessageLine $tb $tb.Tag $true }
        }
        'clearuser' {
            foreach ($c in $messages.Children) {
                if ($c.Tag -is [hashtable] -and $c.Tag.UserId -eq $item.UserId) { Fill-MessageLine $c $c.Tag $true }
            }
        }
        'clear' {
            $messages.Children.Clear(); $msgIndex.Clear(); $heldIndex.Clear()
            $tb = New-Line; $tb.Inlines.Add((New-Run 'Le chat a été vidé par un modérateur.' $grey -Italic)); Add-Element $tb
        }
        'held'       { Add-HeldBlock $item }
        'heldupdate' { Set-HeldStatus $item.HeldId $item.Status $item.By }
        'ready'      { $chanText.Text = 'Chat Twitch - ' + $item.Name }
        'tt' {
            $tb = New-Line
            $tb.Inlines.Add((New-Run $item.Name (Get-NameBrush $item.Name '') -Bold))
            Add-MessageBody $tb $item
            Add-TTElement $tb
        }
        'ttsys' {
            $tb = New-Line
            $tb.Inlines.Add((New-Run $item.Text $grey -Italic))
            Add-TTElement $tb
        }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
$timer.Add_Tick({
    $atBottom = ($scroll.VerticalOffset -ge ($scroll.ScrollableHeight - 4))
    $atBottomTT = ($scrollTT.VerticalOffset -ge ($scrollTT.ScrollableHeight - 4))
    $item = $null; $added = $false
    while ($queue.TryDequeue([ref]$item)) {
        try { Add-ChatItem $item } catch { Write-Log ("Affichage : " + $_) }
        $added = $true
        if ($item.Kind -in @('msg', 'held') -and $cfg.Tab -eq 'tiktok' -and -not $script:unread.twitch) { $script:unread.twitch = $true; Update-TabLabels }
        if ($item.Kind -eq 'tt' -and $cfg.Tab -ne 'tiktok' -and -not $script:unread.tiktok) { $script:unread.tiktok = $true; Update-TabLabels }
    }
    if ($added) {
        $scroll.UpdateLayout()
        if ($atBottom) { $scroll.ScrollToEnd() }
        if ($atBottomTT) { $scrollTT.ScrollToEnd() }
    }
})

# ----- Onglets
$script:unread = @{ twitch = $false; tiktok = $false }
function Set-Tab([string]$tab) {
    $cfg.Tab = $tab
    $onBg  = Get-Brush '#4A3520'; $offBg = Get-Brush '#1A120A'
    $onBd  = Get-Brush '#C9A55A'; $offBd = Get-Brush '#5A3C14'
    $isTw = ($tab -ne 'tiktok')
    $tabTwitch.Background = if ($isTw) { $onBg } else { $offBg }
    $tabTwitch.BorderBrush = if ($isTw) { $onBd } else { $offBd }
    $tabTikTok.Background = if ($isTw) { $offBg } else { $onBg }
    $tabTikTok.BorderBrush = if ($isTw) { $offBd } else { $onBd }
    $scroll.Visibility   = if ($isTw) { 'Visible' } else { 'Collapsed' }
    $scrollTT.Visibility = if ($isTw) { 'Collapsed' } else { 'Visible' }
    $inputBar.Visibility = if ($isTw) { 'Visible' } else { 'Collapsed' }
    $script:unread[$(if ($isTw) { 'twitch' } else { 'tiktok' })] = $false
    Update-TabLabels
    if ($isTw) { $scroll.ScrollToEnd() } else { $scrollTT.ScrollToEnd() }
}
function Update-TabLabels {
    $isTw = ($cfg.Tab -ne 'tiktok')
    $tabTwitchTx.Text = 'Twitch' + $(if ($script:unread.twitch) { ' •' } else { '' })
    $tabTikTokTx.Text = 'TikTok' + $(if ($script:unread.tiktok) { ' •' } else { '' })
    $tabTwitchTx.Foreground = if ($isTw) { $gold } else { Get-Brush '#B8A27A' }
    $tabTikTokTx.Foreground = if ($isTw) { Get-Brush '#B8A27A' } else { $gold }
}
$tabTwitch.Add_MouseLeftButtonDown({ Set-Tab 'twitch' })
$tabTikTok.Add_MouseLeftButtonDown({ Set-Tab 'tiktok' })
Set-Tab ([string]$cfg.Tab)

# ----- Envoi de message
$chatInput.Add_TextChanged({ $placeholder.Visibility = if ($chatInput.Text) { 'Collapsed' } else { 'Visible' } })
$chatInput.Add_KeyDown({
    param($s, $e)
    if ($e.Key -ne 'Return') { return }
    $e.Handled = $true
    $txt = $chatInput.Text.Trim()
    if (-not $txt) { return }
    if (-not $State.BroadcasterId) { Add-Sys "Pas encore connecté à Twitch."; return }
    try {
        $r = Invoke-Helix 'POST' 'chat/messages' @{ broadcaster_id = $State.BroadcasterId; sender_id = $State.UserId; message = $txt }
        $d = @($r.data)[0]
        if ($d -and -not $d.is_sent) { Add-Sys ("Message refusé par Twitch : " + $d.drop_reason.message) }
        else { $chatInput.Text = '' }
    } catch { Add-Sys ("Envoi impossible : " + $_.Exception.Message) }
})

# ---------------------------------------------------------------- Clic à travers
# Quand la fenêtre est verrouillée, tous les clics passent au jeu, sauf sur le cadenas :
# une mini-fenêtre cliquable est posée exactement par-dessus le bouton.
$script:lockWin = $null
function Show-LockButton {
    if (-not $script:lockWin) {
        $lw = New-Object System.Windows.Window
        $lw.WindowStyle = 'None'; $lw.AllowsTransparency = $true; $lw.Background = [System.Windows.Media.Brushes]::Transparent
        $lw.Topmost = $true; $lw.ShowInTaskbar = $false; $lw.ResizeMode = 'NoResize'; $lw.ShowActivated = $false
        $lw.Owner = $win
        $lb = New-Object System.Windows.Controls.Button
        $lb.Style = $win.FindResource('WowButton')
        $lb.Margin = '0'; $lb.Background = Get-Brush '#3E9B2E'
        $lb.ToolTip = 'Déverrouiller (Ctrl+Alt+T)'
        $lb.Content = [Windows.Markup.XamlReader]::Parse(
            '<Canvas xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="10" Height="12">' +
            '<Path Data="M2,6 L2,3.5 A3,3 0 0 1 8,3.5 L8,6" Stroke="#FFD100" StrokeThickness="1.6"/>' +
            '<Rectangle Canvas.Left="0" Canvas.Top="5.5" Width="10" Height="6.5" Fill="#FFD100" RadiusX="1" RadiusY="1"/></Canvas>')
        $lb.Add_Click({ Set-ClickThrough $false })
        $lw.Content = $lb
        $script:lockWin = $lw
    }
    # Position du cadenas dans la fenêtre (en unités WPF), sans passer par l'écran
    $x = $win.ActualWidth - 54; $y = 23
    try {
        $btn = $win.FindName('BtnLock')
        $pt = $btn.TransformToAncestor($win).Transform((New-Object System.Windows.Point(0, 0)))
        $x = $pt.X; $y = $pt.Y
    } catch { }
    $script:lockWin.Width = 22; $script:lockWin.Height = 22
    $script:lockWin.Left = $win.Left + $x; $script:lockWin.Top = $win.Top + $y
    $script:lockWin.Show()
}

$script:hwnd = [IntPtr]::Zero
$script:locked = $false
function Set-ClickThrough([bool]$on) {
    $script:locked = $on
    if ($script:hwnd -ne [IntPtr]::Zero) {
        $ex = [OvNative]::GetWindowLong($script:hwnd, $GWL_EXSTYLE)
        if ($on) { $ex = $ex -bor $WS_EX_TRANSPARENT -bor $WS_EX_LAYERED }
        else     { $ex = $ex -band (-bnot $WS_EX_TRANSPARENT) }
        [void][OvNative]::SetWindowLong($script:hwnd, $GWL_EXSTYLE, $ex)
    }
    # Le cadre reste toujours affiché ; verrouillé = clics transmis au jeu, cadenas allumé
    $btnLock = $win.FindName('BtnLock')
    if ($on) { $win.ResizeMode = 'NoResize'; $btnLock.Background = Get-Brush '#3E9B2E'; $btnLock.ToolTip = 'Verrouillé : Ctrl+Alt+T pour déverrouiller' }
    else     { $win.ResizeMode = 'CanResizeWithGrip'; $btnLock.Background = $win.FindResource('OrangeBtn'); $btnLock.ToolTip = 'Clic à travers : la souris passe au jeu (Ctrl+Alt+T pour revenir)' }
    $inputBar.Opacity = if ($on) { 0.4 } else { 1.0 }
    try {
        if ($on -and $win.IsVisible) { Show-LockButton } elseif (-not $on -and $script:lockWin) { $script:lockWin.Hide() }
    } catch { Write-Log ("Cadenas : " + $_) }
    if ($script:trayLock) { $script:trayLock.Checked = $on }
}

$hook = [System.Windows.Interop.HwndSourceHook] {
    param([IntPtr]$h, [int]$msg, [IntPtr]$wParam, [IntPtr]$lParam, [ref]$handled)
    if ($msg -eq 0x0312 -and $wParam.ToInt32() -eq $HOTKEY_ID) {
        Set-ClickThrough (-not $script:locked)
        $handled.Value = $true
    }
    return [IntPtr]::Zero
}

$win.Add_SourceInitialized({
    $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    $ex = [OvNative]::GetWindowLong($script:hwnd, $GWL_EXSTYLE)
    [void][OvNative]::SetWindowLong($script:hwnd, $GWL_EXSTYLE, ($ex -bor $WS_EX_TOOLWINDOW))
    [System.Windows.Interop.HwndSource]::FromHwnd($script:hwnd).AddHook($hook)
    if (-not [OvNative]::RegisterHotKey($script:hwnd, $HOTKEY_ID, ($MOD_CONTROL -bor $MOD_ALT), $VK_T)) {
        Add-Sys "Raccourci Ctrl+Alt+T indisponible (déjà utilisé). Utilise le bouton de minimap de l'addon pour déverrouiller."
    }
})

# ---------------------------------------------------------------- Événements fenêtre
foreach ($el in @($header, $subHeader, $emblem)) { $el.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch {} }) }
$win.FindName('BtnClear').Add_Click({
    if ($cfg.Tab -eq 'tiktok') { $messagesTT.Children.Clear(); $script:unread.tiktok = $false }
    else { $messages.Children.Clear(); $msgIndex.Clear(); $heldIndex.Clear(); $script:unread.twitch = $false }
    Update-TabLabels
})
$win.FindName('BtnMinus').Add_Click({ $bgBrush.Opacity = [Math]::Max(0.0, [Math]::Round($bgBrush.Opacity - 0.1, 2)); $cfg.Opacity = $bgBrush.Opacity })
$win.FindName('BtnPlus').Add_Click({  $bgBrush.Opacity = [Math]::Min(1.0, [Math]::Round($bgBrush.Opacity + 0.1, 2)); $cfg.Opacity = $bgBrush.Opacity })
$win.FindName('BtnLock').Add_Click({ Set-ClickThrough $true })
function Close-ByUser {
    # Fermeture volontaire : le lanceur automatique ne rouvre pas le chat pendant cette partie
    try { $wp = Get-Process -Name 'Wow' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($wp) { Set-Content -Path (Join-Path $here 'ferme-par-moi.txt') -Value $wp.Id } } catch {}
    $win.Close()
}
# La croix masque seulement le chat : un clic sur le bouton de la minimap le réaffiche
$script:xHidden = $false
$win.FindName('BtnClose').Add_Click({ $script:xHidden = $true; Set-ChatVisible $false })

# ---------------------------------------------------------------- Icône de notification
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = [System.Drawing.SystemIcons]::Information
$tray.Text = "Chat Twitch (WoW)"
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:trayLock = New-Object System.Windows.Forms.ToolStripMenuItem("Clic à travers (Ctrl+Alt+T)")
$script:trayLock.Add_Click({ Set-ClickThrough (-not $script:locked) })
$miChan = New-Object System.Windows.Forms.ToolStripMenuItem("Changer de chaîne...")
$miChan.Add_Click({
    $c = Read-ChannelName $cfg.Channel
    if ($c -ne $cfg.Channel) {
        $cfg.Channel = $c; Save-Config
        $chanText.Text = if ($c) { 'Chat Twitch - ' + $c } else { 'Chat Twitch' }
        $messages.Children.Clear(); $msgIndex.Clear(); $heldIndex.Clear()
        $State.Channel = $c
        try { $State.Ws.Abort() } catch {}
    }
})
$miLogin = New-Object System.Windows.Forms.ToolStripMenuItem("Se connecter à Twitch")
$miLogin.Add_Click({ $State.Paused = $false; try { $State.Ws.Abort() } catch {} })
$miLogout = New-Object System.Windows.Forms.ToolStripMenuItem("Changer de compte Twitch")
$miLogout.Add_Click({
    $State.Access = $null; $State.Refresh = $null
    try { Remove-Item -Path $tokenPath -Force -ErrorAction SilentlyContinue } catch {}
    $State.Paused = $false
    $State.Channel = $State.Channel + ''   # force la reconnexion
    try { $State.Ws.Abort() } catch {}
})
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem("Afficher / masquer le chat")
$miShow.Add_Click({ Set-ChatVisible (-not $script:userVisible) })
$miReset = New-Object System.Windows.Forms.ToolStripMenuItem("Replacer la fenêtre au centre")
$miReset.Add_Click({ Set-ClickThrough $false; Set-DefaultPlacement })
function Start-TikTokStudio {
    try {
        $ttArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $here 'Lancer-TikTok-LIVE-Studio.ps1') + '"'))
        Start-Process -FilePath 'powershell.exe' -ArgumentList $ttArgs -WindowStyle Hidden
        Add-ChatItem @{ Kind = 'ttsys'; Text = 'Lancement de TikTok LIVE Studio... Ouvre ensuite la fenêtre du chat dans LIVE Studio.' }
        Set-Tab 'tiktok'
    } catch { Write-Log "Lancement TikTok impossible : $_" }
}
function Open-TwitchChannel {
    try {
        $ch = if ($State.Channel) { $State.Channel } elseif ($State.Login) { $State.Login } else { '' }
        Start-Process ('https://www.twitch.tv/' + $ch)
    } catch { Write-Log "Ouverture de la chaîne impossible : $_" }
}
function Start-OBS {
    try {
        if (Get-Process -Name 'obs64' -ErrorAction SilentlyContinue) { Add-Sys 'OBS est déjà ouvert.'; return }
        $obs = Find-OBSExe
        if (-not $obs) { Add-Sys "OBS Studio est introuvable sur ce PC."; return }
        # OBS doit être lancé depuis son propre dossier
        Start-Process -FilePath $obs -WorkingDirectory (Split-Path $obs)
        Add-Sys 'Lancement d''OBS Studio...'
        Set-Tab 'twitch'
    } catch { Write-Log "Lancement d'OBS impossible : $_" }
}
function Find-OBSExe {
        $obs = $null
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\Program Files', 'D:\Program Files', 'E:\Program Files')) {
            if (-not $base) { continue }
            $p = Join-Path $base 'obs-studio\bin\64bit\obs64.exe'
            if (Test-Path $p) { $obs = $p; break }
        }
        if (-not $obs) {
            try {
                $reg = Get-ItemProperty 'HKLM:\SOFTWARE\OBS Studio' -ErrorAction Stop
                $p = Join-Path ([string]$reg.'(default)') 'bin\64bit\obs64.exe'
                if (Test-Path $p) { $obs = $p }
            } catch {}
        }
        if (-not $obs) {
            # Raccourcis du menu Démarrer (installation ailleurs, par ex. sur un autre disque)
            try {
                $sh = New-Object -ComObject WScript.Shell
                $dirs = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), [Environment]::GetFolderPath('Desktop'))
                foreach ($lnk in @(Get-ChildItem -Path $dirs -Filter 'OBS Studio*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
                    $t = [string]$sh.CreateShortcut($lnk.FullName).TargetPath
                    if ($t -match 'obs64\.exe$' -and (Test-Path $t)) { $obs = $t; break }
                }
            } catch {}
        }
        return $obs
}
function Find-TikTokExe {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, 'D:\Program Files', 'E:\Program Files')) {
        if (-not $base) { continue }
        $e = Get-ChildItem -Path (Join-Path $base 'TikTok LIVE Studio') -Filter 'TikTok LIVE Studio.exe' -Recurse -ErrorAction SilentlyContinue |
            Sort-Object { try { [version]$_.Directory.Name } catch { [version]'0.0' } } -Descending | Select-Object -First 1
        if ($e) { return $e.FullName }
    }
    # Raccourcis du menu Démarrer / du bureau (installation ailleurs)
    try {
        $sh = New-Object -ComObject WScript.Shell
        $dirs = @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'), [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))
        foreach ($lnk in @(Get-ChildItem -Path $dirs -Filter 'TikTok LIVE Studio*.lnk' -Recurse -ErrorAction SilentlyContinue)) {
            $t = [string]$sh.CreateShortcut($lnk.FullName).TargetPath
            if ($t -match 'TikTok LIVE Studio\.exe$' -and (Test-Path $t)) { return $t }
        }
    } catch {}
    return $null
}
function Set-ExeIcon($img, $txt, [string]$exe) {
    if (-not $exe) { return }
    try {
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $img.Source = $src
        $txt.Visibility = 'Collapsed'
    } catch { Write-Log "Icône non chargée pour $exe : $_" }
}
# Icônes OBS / TikTok à droite des onglets
$btnOBS = $win.FindName('BtnOBS'); $btnTT = $win.FindName('BtnTT')
try { Set-ExeIcon $win.FindName('ImgOBS') $win.FindName('TxtOBS') (Find-OBSExe) } catch {}
try { Set-ExeIcon $win.FindName('ImgTT') $win.FindName('TxtTT') (Find-TikTokExe) } catch {}
foreach ($bx in @($btnOBS, $btnTT)) {
    $bx.Add_MouseEnter({ $this.BorderBrush = Get-Brush '#C9A55A'; $this.Background = Get-Brush '#4A3520' })
    $bx.Add_MouseLeave({ $this.BorderBrush = Get-Brush '#5A3C14'; $this.Background = Get-Brush '#1A120A' })
}
$btnOBS.Add_MouseLeftButtonUp({ Start-OBS })
$btnTT.Add_MouseLeftButtonUp({ Start-TikTokStudio })
$miChannel = New-Object System.Windows.Forms.ToolStripMenuItem("Ouvrir ma chaîne Twitch")
$miChannel.Add_Click({ Open-TwitchChannel })
$miOBS = New-Object System.Windows.Forms.ToolStripMenuItem("Lancer OBS (stream Twitch)")
$miOBS.Add_Click({ Start-OBS })
$miTikTok = New-Object System.Windows.Forms.ToolStripMenuItem("Lancer TikTok LIVE Studio")
$miTikTok.Add_Click({ Start-TikTokStudio })
$miRestart = New-Object System.Windows.Forms.ToolStripMenuItem("Relancer le chat")
function Restart-Chat {
    if ($script:restarting) { return }
    $script:restarting = $true
    $args2 = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"' + (Join-Path $here 'TwitchChatOverlay.ps1') + '"'), '-Restart')
    if ($WithGame) { $args2 += '-WithGame' }
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $args2
    $win.Close()
}
$miRestart.Add_Click({ Restart-Chat })
$miQuit = New-Object System.Windows.Forms.ToolStripMenuItem("Quitter")
$miQuit.Add_Click({ Close-ByUser })
foreach ($it in @($miShow, $script:trayLock, $miChan, $miLogin, $miLogout, $miReset, (New-Object System.Windows.Forms.ToolStripSeparator), $miChannel, $miOBS, $miTikTok, $miRestart, $miQuit)) {
    [void]$menu.Items.Add($it)
}
$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Set-ClickThrough (-not $script:locked) })
$tray.Visible = $false   # pas d'icône près de l'horloge (demande de Thomas) : le menu s'ouvre par clic droit sur la barre de titre
$header.Add_MouseRightButtonUp({ param($s, $e) $e.Handled = $true; $menu.Show([System.Windows.Forms.Cursor]::Position) })

$win.Add_Closing({
    if ($win.WindowState -eq 'Normal') {
        $cfg.Left = [int]$win.Left; $cfg.Top = [int]$win.Top
        $cfg.Width = [int]$win.ActualWidth; $cfg.Height = [int]$win.ActualHeight
    }
    Save-Config
})

# Lancé avec le jeu : se ferme tout seul quand WoW Forever est fermé
if ($WithGame) {
    $gameTimer = New-Object System.Windows.Threading.DispatcherTimer
    $gameTimer.Interval = [TimeSpan]::FromSeconds(5)
    $gameTimer.Add_Tick({ if (-not (Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)) { $win.Close() } })
    $gameTimer.Start()
}

# ----- Bouton de minimap (addon TwitchChatWoW) : lecture du pixel-signal en haut à gauche de l'écran
# Visible = demandé par toi (bouton minimap / icône) ET WoW est la fenêtre active
$script:userVisible = $true
$script:gameFocused = $true
$script:inGame = $false        # signal de l'addon vu récemment = personnage en jeu
$script:wowRunning = $false
$script:lastSignalAt = [DateTime]::MinValue
function Update-Visibility {
    $vis = $script:userVisible -and $script:gameFocused -and ($script:inGame -or -not $script:wowRunning)
    if ($vis) {
        if (-not $win.IsVisible) {
            $win.Show()
            if ($script:locked) { try { Show-LockButton } catch {} }
        }
    } elseif ($win.IsVisible) {
        if ($script:lockWin) { $script:lockWin.Hide() }
        $win.Hide()
    }
}
function Set-ChatVisible([bool]$vis) { $script:userVisible = $vis; Update-Visibility }

$script:pidNames = @{}
$focusTimer = New-Object System.Windows.Threading.DispatcherTimer
$focusTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$focusTimer.Add_Tick({
    try {
        $fpid = [uint32]0
        [void][OvNative]::GetWindowThreadProcessId([OvNative]::GetForegroundWindow(), [ref]$fpid)
        $focused = $true
        if ($fpid -ne 0 -and $fpid -ne $PID) {
            if (-not $script:pidNames.ContainsKey($fpid)) {
                $n = ''; try { $n = [System.Diagnostics.Process]::GetProcessById([int]$fpid).ProcessName } catch {}
                $script:pidNames[$fpid] = $n
            }
            if ($script:pidNames[$fpid] -ne 'Wow') {
                # Une autre application est au premier plan : on se cache, sauf si WoW n'est pas lancé du tout
                $focused = -not [bool](Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)
            }
        }
        if ($focused -ne $script:gameFocused) { $script:gameFocused = $focused; Update-Visibility }
    } catch { Write-Log ("Suivi de WoW : " + $_) }
})
$script:lastSignal = -1
$script:startedAt = [DateTime]::Now
# ----- « Passer derrière » les fenêtres du jeu : l'addon envoie leurs rectangles dans une bande de cases
# à côté du signal ; on découpe la partie de la fenêtre du chat qu'elles recouvrent.
$script:clipKey = ''
$script:chatRaised = $false   # le chat a été cliqué : il repasse devant les fenêtres du jeu
$script:panelRects = @()
$script:panelSet = @{}
$stripBmp = New-Object System.Drawing.Bitmap 208, 4
$stripGfx = [System.Drawing.Graphics]::FromImage($stripBmp)
function Read-PanelRects {
    $stripGfx.CopyFromScreen(0, 0, 0, 0, (New-Object System.Drawing.Size 208, 4))
    $bits = New-Object System.Collections.Generic.List[int]
    $cell = 0
    $readCell = {
        param($i)
        $c = $stripBmp.GetPixel(8 + $i * 4 + 2, 2)
        foreach ($v in @($c.R, $c.G, $c.B)) { $bits.Add($(if ($v -ge 128) { 1 } else { 0 })) }
    }
    & $readCell 0
    if ($bits[0] -ne 1) { return @() }
    $n = $bits[1] * 2 + $bits[2]
    $need = 3 + $n * 48
    while ($bits.Count -lt $need) { $cell++; & $readCell $cell }
    $rects = @()
    for ($k = 0; $k -lt $n; $k++) {
        $vals = @()
        for ($q = 0; $q -lt 4; $q++) {
            $v = 0
            for ($bi = 0; $bi -lt 12; $bi++) { $v = $v * 2 + $bits[3 + $k * 48 + $q * 12 + $bi] }
            $vals += $v
        }
        if ($vals[2] -gt $vals[0] -and $vals[3] -gt $vals[1]) { $rects += ,$vals }
    }
    return $rects
}
function Update-PanelClip {
    $root = $win.Content
    if (-not $root -or -not $win.IsVisible) { return }
    $rects = @(Read-PanelRects)
    $script:panelRects = $rects
    # Une nouvelle fenêtre du jeu s'ouvre : elle passe devant le chat
    $newSet = @{}
    foreach ($r in $rects) { $newSet[($r -join ',')] = 1 }
    foreach ($k in $newSet.Keys) { if (-not $script:panelSet.ContainsKey($k)) { $script:chatRaised = $false } }
    $script:panelSet = $newSet
    if ($script:chatRaised) { $rects = @() }
    $key = (($rects | ForEach-Object { $_ -join ',' }) -join ';') + '|' + [int]$win.Left + ',' + [int]$win.Top + ',' + [int]$win.ActualWidth + ',' + [int]$win.ActualHeight
    if ($key -eq $script:clipKey) { return }
    $script:clipKey = $key
    if ($rects.Count -eq 0) { $root.Clip = $null; return }
    $grp = New-Object System.Windows.Media.GeometryGroup
    $grp.FillRule = [System.Windows.Media.FillRule]::Nonzero   # des fenêtres qui se chevauchent restent toutes découpées
    foreach ($r in $rects) {
        $p1 = $root.PointFromScreen((New-Object System.Windows.Point ([double]$r[0]), ([double]$r[1])))
        $p2 = $root.PointFromScreen((New-Object System.Windows.Point ([double]$r[2]), ([double]$r[3])))
        $grp.Children.Add((New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect $p1, $p2)))
    }
    # zone large : le rond Twitch qui dépasse en haut à gauche ne doit pas être coupé
    $full = New-Object System.Windows.Media.RectangleGeometry (New-Object System.Windows.Rect -200, -200, ($root.ActualWidth + 400), ($root.ActualHeight + 400))
    $root.Clip = New-Object System.Windows.Media.CombinedGeometry ([System.Windows.Media.GeometryCombineMode]::Exclude), $full, $grp
}

# Clic sur le chat : il repasse devant. Clic sur une fenêtre du jeu (hors du chat) : elle repasse devant.
$win.Add_PreviewMouseDown({
    if (-not $script:chatRaised) { $script:chatRaised = $true; $script:clipKey = ''; try { $win.Content.Clip = $null } catch {} }
})
$clickTimer = New-Object System.Windows.Threading.DispatcherTimer
$clickTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$clickTimer.Add_Tick({
    try {
        $st = [OvMouse]::GetAsyncKeyState(0x01)
        if (($st -band 0x8000) -eq 0 -and ($st -band 0x1) -eq 0) { return }
        if (-not $script:chatRaised -or $script:panelRects.Count -eq 0 -or $win.IsMouseOver) { return }
        $pos = [System.Windows.Forms.Cursor]::Position
        foreach ($r in $script:panelRects) {
            if ($pos.X -ge $r[0] -and $pos.X -le $r[2] -and $pos.Y -ge $r[1] -and $pos.Y -le $r[3]) {
                $script:chatRaised = $false; $script:clipKey = ''
                try { Update-PanelClip } catch {}
                break
            }
        }
    } catch {}
})
$clickTimer.Start()
# Découpe rafraîchie en continu (environ 30 fois par seconde) pour suivre les fenêtres du jeu sans délai
$clipTimer = New-Object System.Windows.Threading.DispatcherTimer ([System.Windows.Threading.DispatcherPriority]::Render)
$clipTimer.Interval = [TimeSpan]::FromMilliseconds(10)
$clipTimer.Add_Tick({
    if ($script:lastSignal -lt 0) { return }
    try { Update-PanelClip }
    catch { $m = [string]$_; if ($m -ne $script:lastClipErr) { $script:lastClipErr = $m; Write-Log ("Découpe : " + $m) } }
})
$clipTimer.Start()

$script:restarting = $false
$signalTimer = New-Object System.Windows.Threading.DispatcherTimer
$signalTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$signalTimer.Add_Tick({
    try {
        $hdc = [OvNative]::GetDC([IntPtr]::Zero)
        $c = [OvNative]::GetPixel($hdc, 1, 1)
        [void][OvNative]::ReleaseDC([IntPtr]::Zero, $hdc)
        $r = $c -band 0xFF; $g = ($c -shr 8) -band 0xFF; $b = ($c -shr 16) -band 0xFF
        $sig = -1
        # Demande de relance depuis le menu de la minimap : couleur (255, 0, 128)
        if ($r -ge 240 -and $g -lt 40 -and $b -ge 90 -and $b -le 170) {
            if (([DateTime]::Now - $script:startedAt).TotalSeconds -gt 10) { Restart-Chat; return }
            $script:lastSignalAt = [DateTime]::Now   # juste relancé : on est bien en jeu, on garde l'état actuel
        }
        # Actions du menu de la minimap : couleur (255, 128, b) ; b = 0 TikTok, 64 chaîne Twitch, 128 OBS
        if ($r -ge 240 -and $g -ge 90 -and $g -le 170 -and $b -lt 200) {
            $script:lastSignalAt = [DateTime]::Now
            $act = if ($b -lt 32) { 'tiktok' } elseif ($b -lt 96) { 'twitch' } else { 'obs' }
            if ($script:lastAction -ne $act -or -not $script:actionAt -or ([DateTime]::Now - $script:actionAt).TotalSeconds -gt 5) {
                $script:lastAction = $act; $script:actionAt = [DateTime]::Now
                switch ($act) { 'tiktok' { Start-TikTokStudio } 'twitch' { Open-TwitchChannel } 'obs' { Start-OBS } }
            }
            return
        }
        if ($r -ge 240 -and $b -ge 240) {
            if ($g -lt 40) { $sig = 0 } elseif ($g -lt 128) { $sig = 1 } elseif ($g -lt 213) { $sig = 2 }
        }
        $script:wowRunning = [bool](Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)
        $coversCorner = $win.IsVisible -and $win.Left -le 4 -and $win.Top -le 4
        if ($sig -ge 0 -or $coversCorner) { $script:lastSignalAt = [DateTime]::Now }
        # Pas de signal depuis 1,5 s (écran de connexion, choix du personnage, chargement) = pas en jeu
        $nowInGame = (([DateTime]::Now - $script:lastSignalAt).TotalSeconds -lt 1.5)
        if ($nowInGame -ne $script:inGame) { $script:inGame = $nowInGame; Update-Visibility }
        if ($sig -lt 0) { Update-Visibility; return }
        if ($sig -eq $script:lastSignal) { return }
        $script:lastSignal = $sig
        if ($script:xHidden) {
            # masqué par la croix : le premier clic sur le bouton de la minimap le réaffiche
            $script:xHidden = $false
            Set-ChatVisible $true
            if ($sig -eq 1) { if (-not $script:locked) { Set-ClickThrough $true } } elseif ($script:locked) { Set-ClickThrough $false }
            return
        }
        switch ($sig) {
            0 { Set-ChatVisible $true;  if ($script:locked) { Set-ClickThrough $false } }
            1 { Set-ChatVisible $true;  if (-not $script:locked) { Set-ClickThrough $true } }
            2 { Set-ChatVisible $false }
        }
    } catch { Write-Log ("Signal minimap : " + $_) }
})

$win.Add_Closed({ $win.Dispatcher.InvokeShutdown() })
$timer.Start()
$signalTimer.Start()
$focusTimer.Start()
# Une erreur imprévue ne doit jamais fermer le chat : on la note et on continue
$win.Dispatcher.Add_UnhandledException({
    param($s, $ev)
    Write-Log ("Erreur imprévue : " + $ev.Exception.ToString())
    $ev.Handled = $true
})
[AppDomain]::CurrentDomain.Add_UnhandledException({ param($s, $ev) Write-Log ("Erreur fatale : " + $ev.ExceptionObject) })
try { Remove-Item -Path (Join-Path $here 'ferme-par-moi.txt') -ErrorAction SilentlyContinue } catch {}
Write-Log "Démarrage du chat"
$win.Show()
$script:wowRunning = [bool](Get-Process -Name 'Wow' -ErrorAction SilentlyContinue)
Update-Visibility
[System.Windows.Threading.Dispatcher]::Run()
Write-Log "Fin du chat"

# ---------------------------------------------------------------- Fermeture
$timer.Stop()
try { [void][OvNative]::UnregisterHotKey($script:hwnd, $HOTKEY_ID) } catch {}
$tray.Visible = $false; $tray.Dispose()
$State.Run = $false
try { $State.Ws.Abort() } catch {}

}
catch {
    Write-Log ("ERREUR : " + $_.Exception.ToString())
    [System.Windows.MessageBox]::Show("Erreur dans Chat Twitch :`n`n" + $_.Exception.Message + "`n`nDétails dans overlay.log", "Chat Twitch") | Out-Null
}
[Environment]::Exit(0)
