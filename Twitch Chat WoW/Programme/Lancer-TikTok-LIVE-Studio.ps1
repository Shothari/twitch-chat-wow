#Requires -Version 5.1
# Lance TikTok LIVE Studio avec l'accès local qui permet à la fenêtre Chat Twitch / TikTok de lire le chat du live.
Add-Type -AssemblyName PresentationFramework
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
$exePath = Find-TikTokExe
$exe = if ($exePath) { Get-Item $exePath } else { $null }
if (-not $exe) {
    [System.Windows.MessageBox]::Show("TikTok LIVE Studio est introuvable sur ce PC. Installe-le, ou lance-le une fois depuis son raccourci habituel.", "Chat TikTok pour WoW") | Out-Null
    exit
}
$portOk = $false
try { [void](Invoke-RestMethod -UseBasicParsing -Uri 'http://127.0.0.1:9222/json/version' -TimeoutSec 2); $portOk = $true } catch {}
if (-not $portOk -and (Get-Process -Name 'TikTok LIVE Studio' -ErrorAction SilentlyContinue)) {
    [System.Windows.MessageBox]::Show("TikTok LIVE Studio est déjà ouvert normalement.`n`nQuitte-le complètement (icône près de l'horloge > Quitter), puis relance ce raccourci.", "Chat TikTok pour WoW") | Out-Null
    exit
}
if (-not $portOk) {
    Start-Process -FilePath $exe.FullName -ArgumentList '--remote-debugging-port=9222'
}
