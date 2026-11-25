#Requires -Version 5.1
<#
    Démarrage automatique du chat Twitch avec WoW Forever.
    Lancé en arrière-plan à l'ouverture de session Windows (raccourci dans le dossier Démarrage).
    Toutes les 5 secondes : si Wow.exe tourne et que le chat n'est pas ouvert, l'ouvre (sauf si tu l'as fermé toi-même).
    La fenêtre de chat se ferme d'elle-même quand le jeu se ferme.
#>
$ErrorActionPreference = 'SilentlyContinue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$overlay = Join-Path $here 'TwitchChatOverlay.ps1'

$mutex = New-Object System.Threading.Mutex($false, 'Local\WoWTwitchChatWatcher2')
if (-not $mutex.WaitOne(0)) { exit }   # déjà en cours

$flag = Join-Path $here 'ferme-par-moi.txt'
function Test-OverlayRunning {
    $m = $null
    if ([System.Threading.Mutex]::TryOpenExisting('Local\WoWTwitchChatOverlay', [ref]$m)) { $m.Dispose(); return $true }
    return $false
}

$missing = 0
while ($true) {
    $wow = Get-Process -Name 'Wow' | Select-Object -First 1
    if ($wow) {
        # Le chat doit tourner pendant la partie ; s'il s'est arrêté tout seul, on le relance
        $closedByUser = (Test-Path $flag) -and ((Get-Content $flag -TotalCount 1) -eq [string]$wow.Id)
        if (-not $closedByUser -and -not (Test-OverlayRunning)) { $missing++ } else { $missing = 0 }
        if ($missing -ge 3) {   # absent depuis 15 s (laisse le temps à une relance en cours)
            $missing = 0
            Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
                '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', "`"$overlay`"", '-WithGame')
            Start-Sleep -Seconds 10
        }
    }
    Start-Sleep -Seconds 5
}
