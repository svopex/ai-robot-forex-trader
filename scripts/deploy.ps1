# Nasazeni experta AiRobotForexTrader do MetaTraderu 5.
#
# Skript zkopiruje zdrojove soubory z repozitare do datoveho adresare
# terminalu a expert zkompiluje pres MetaEditor. Po uspesne kompilaci staci
# v terminalu v Navigatoru (Experts -> AiRobotForexTrader) experta pretahnout
# na libovolny graf - pri bezicim terminalu se novy .ex5 objevi v Navigatoru
# sam, pripadne po pravem kliku -> Obnovit.
#
# Pouziti:
#   powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1 -All
#   powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1 -Broker "IC Markets"
#   powershell -ExecutionPolicy Bypass -File scripts\deploy.ps1 -NoCompile

param(
    # Cast nazvu instalacniho adresare terminalu (rozlisuje brokera)
    [string]$Broker = "RoboForex",
    # Nasadit do vsech nainstalovanych terminalu MT5 (parametr -Broker se ignoruje)
    [switch]$All,
    # Preskocit kompilaci a jen zkopirovat soubory
    [switch]$NoCompile
)

$ErrorActionPreference = "Stop"

# Nazev experta - soubor .mq5 / .ex5 i slozka, do ktere se nasazuje
$expertName = "AiRobotForexTrader"
$repoRoot   = Split-Path -Parent $PSScriptRoot
$srcExperts = Join-Path $repoRoot "MQL5\Experts\$expertName"

# Vsechny terminaly MT5 se znamym datovym adresarem. Datovy adresar se pozna
# podle souboru origin.txt, ktery obsahuje cestu k instalaci (soubor je
# v UTF-16 s BOM). Bere se jen instalace s MetaEditorem - bez nej nejde
# kompilovat (napr. odinstalovany terminal, po kterem zustala data).
# Kazdy nalezeny terminal se rovnou vypise do vystupu funkce.
function Get-Terminals {
    foreach ($dir in Get-ChildItem "$env:APPDATA\MetaQuotes\Terminal" -Directory) {
        $originFile = Join-Path $dir.FullName "origin.txt"
        if (-not (Test-Path $originFile)) { continue }
        $origin = (Get-Content $originFile -Raw -Encoding Unicode).Trim([char]0xFEFF, ' ', "`r", "`n", "`0")
        if (-not (Test-Path (Join-Path $origin "MetaEditor64.exe"))) { continue }
        [pscustomobject]@{ Install = $origin; Data = $dir.FullName }
    }
}

# Vypisy jdou pres Write-Host: Write-Output by ve funkci skoncil
# v jeji navratove hodnote misto na konzoli.
#
# Nasadi a zkompiluje experta v jednom terminalu.
#   $installPath - instalacni adresar terminalu (MetaEditor64.exe)
#   $termRoot    - datovy adresar terminalu (MQL5\...)
# Vraci $true pri uspechu; chyby vypise a vrati $false, aby se pri -All
# pokracovalo dalsim terminalem.
function Deploy-Terminal([string]$installPath, [string]$termRoot) {
    Write-Host ""
    Write-Host "Terminal:  $installPath"
    Write-Host "Data:      $termRoot"

    # Kopie zdrojovych souboru do datoveho adresare terminalu
    $dstExperts = Join-Path $termRoot "MQL5\Experts\$expertName"
    New-Item -ItemType Directory -Force -Path $dstExperts | Out-Null
    Copy-Item (Join-Path $srcExperts "*.mq5") $dstExperts -Force
    Write-Host "Zkopirovano do $dstExperts"

    if ($NoCompile) { return $true }

    # Kompilace pres MetaEditor - vysledek se cte z logu (log je v UTF-16)
    $editor = Join-Path $installPath "MetaEditor64.exe"
    $source = Join-Path $dstExperts "$expertName.mq5"
    $ex5    = Join-Path $dstExperts "$expertName.ex5"
    # Log se pred kompilaci smaze, aby byl vzdy jen z tohoto behu
    $log    = Join-Path $env:TEMP "$expertName`_compile.log"
    if (Test-Path $log) { Remove-Item $log -Force }

    $proc = Start-Process -FilePath $editor `
                          -ArgumentList "/compile:`"$source`"", "/log:`"$log`"" `
                          -Wait -NoNewWindow -PassThru

    # Z logu se vypisou jen chyby, varovani a souhrnny radek
    $lines = @()
    if (Test-Path $log) {
        $lines = @(Get-Content $log -Encoding Unicode)
        $lines | Where-Object { $_ -match "error|warning|Result" } | ForEach-Object { Write-Host $_ }
    } else {
        Write-Host "Log kompilace nebyl vytvoren."
    }

    # Uspech = log tohoto behu hlasi "Result: 0 errors" a binarka existuje.
    # Navratovy kod MetaEditoru se pouzit neda - vraci 1 i po prekladu bez chyb.
    $compiled = (@($lines -match "Result: 0 errors").Count -gt 0) -and (Test-Path $ex5)
    if (-not $compiled) {
        Write-Host "CHYBA: kompilace selhala (MetaEditor skoncil s kodem $($proc.ExitCode)). Podrobnosti v $log."
        return $false
    }
    Write-Host "Hotovo: $ex5"

    # Bezici terminal experta po kompilaci obvykle sam znovu nacte, ale ne vzdy.
    # Kontrola: v Expert logu se ma objevit radek "ARFT: AiRobotForexTrader vX.YY,
    # build <cas kompilace>".
    $running = Get-Process -Name "terminal64" -ErrorAction SilentlyContinue |
               Where-Object { $_.Path -like "$installPath*" }
    if ($null -ne $running) {
        Write-Host "POZOR: terminal bezi. Pokud se v Expert logu neobjevi 'ARFT: ... build $(Get-Date -Format 'yyyy.MM.dd HH:mm')',"
        Write-Host "       odeber experta z grafu a pridej ho znovu (nebo restartuj terminal)."
    }
    return $true
}

# Vyber terminalu: vsechny (-All), nebo prvni, jehoz instalace v nazvu
# obsahuje jmeno brokera
$terminals = @(Get-Terminals)
if (-not $All) {
    $terminals = @($terminals | Where-Object { (Split-Path -Leaf $_.Install) -like "*$Broker*" } |
                   Select-Object -First 1)
}
if ($terminals.Count -eq 0) {
    if ($All) { throw "Nebyl nalezen zadny terminal MT5 s MetaEditorem (terminal jeste nebyl spusten?)." }
    throw "Terminal pro brokera '$Broker' nebyl nalezen (instalace s MetaEditorem a datovym adresarem)."
}

# Nasazeni do vybranych terminalu; neuspech jednoho nezastavi ostatni
$failed = @()
foreach ($t in $terminals) {
    if (-not (Deploy-Terminal $t.Install $t.Data)) { $failed += $t.Install }
}

Write-Host ""
if ($failed.Count -gt 0) {
    throw "Nasazeni selhalo v $($failed.Count) z $($terminals.Count) terminalu: $($failed -join ', ')"
}
Write-Host "Nasazeno do $($terminals.Count) terminalu."
