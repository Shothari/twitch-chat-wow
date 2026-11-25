#Requires -Version 5.1
# Installation en un clic du Chat Twitch pour WoW (à lancer une seule fois).
param([switch]$Uninstall)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName PresentationFramework
$prog = Split-Path -Parent $MyInvocation.MyCommand.Path

# 1) Arrêter les anciennes versions éventuellement en cours
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'Demarrage-Auto\.ps1|TwitchChatOverlay\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

$startup = [Environment]::GetFolderPath('Startup')
$vbs = Join-Path $startup 'Chat Twitch WoW.vbs'
if ($Uninstall) {
    Remove-Item -Path $vbs -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path ([Environment]::GetFolderPath('Desktop')) 'TikTok LIVE Studio (Chat WoW).lnk') -Force -ErrorAction SilentlyContinue
    [System.Windows.MessageBox]::Show("Chat Twitch est désinstallé. Tu peux supprimer le dossier « Twitch Chat WoW ».", "Chat Twitch pour WoW") | Out-Null
    exit
}

# 2) Lancement automatique à l'ouverture de Windows (surveille WoW, ouvre le chat avec le jeu)
$watch = Join-Path $prog 'Demarrage-Auto.ps1'
$line = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & "' + $watch + '" & """", 0, False'
Set-Content -Path $vbs -Value $line -Encoding Default

# 3) Raccourci sur le bureau pour lancer TikTok LIVE Studio avec la lecture du chat activée
try {
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
    $ttPath = Find-TikTokExe
    $ttExe = if ($ttPath) { Get-Item $ttPath } else { $null }
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'TikTok LIVE Studio (Chat WoW).lnk'))
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $prog 'Lancer-TikTok-LIVE-Studio.ps1') + '"'
    $lnk.WindowStyle = 7
    if ($ttExe) { $lnk.IconLocation = $ttExe.FullName + ',0' }
    $lnk.Description = 'TikTok LIVE Studio avec le chat affiché dans WoW'
    $lnk.Save()
} catch {}

# 4) Démarrer tout de suite
Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"')

[System.Windows.MessageBox]::Show(
    "Chat Twitch est installé !`n`n" +
    "La fenêtre du chat s'ouvrira toute seule quand tu seras en jeu avec ton personnage.`n" +
    "Pour le chat TikTok, lance TikTok LIVE Studio avec le nouveau raccourci « TikTok LIVE Studio (Chat WoW) » sur ton bureau.`n" +
    "Au premier lancement, Twitch te demandera d'autoriser l'accès à ton compte.`n`n" +
    "Tu n'as plus besoin de relancer cet installateur.",
    "Chat Twitch pour WoW") | Out-Null
