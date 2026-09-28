param (
    [string]$ConfigPath = ".\config.json",
    [string]$OutputDir = ".\reports"
)

$ErrorActionPreference = 'Stop'

Write-Host '[1/6] Inicjalizacja i wczytywanie konfiguracji...' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$DefaultConfig = [PSCustomObject]@{
    PingTargets = @('1.1.1.1', '8.8.8.8', 'github.com')
    DiskWarningThresholdPercent = 20
}

if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Nie można wczytać konfiguracji '$ConfigPath': $($_.Exception.Message)"
    }
}
else {
    $Config = $DefaultConfig
}

if (-not $Config.PingTargets) {
    $Config | Add-Member -NotePropertyName PingTargets -NotePropertyValue $DefaultConfig.PingTargets -Force
}
if ($null -eq $Config.DiskWarningThresholdPercent) {
    $Config | Add-Member -NotePropertyName DiskWarningThresholdPercent -NotePropertyValue 20 -Force
}

# 1. Informacje o systemie i sprzęcie
Write-Host '[2/6] Pobieranie danych o systemie i zasobach (CIM)...' -ForegroundColor Cyan
$OS = Get-CimInstance -ClassName Win32_OperatingSystem
$ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
$BIOS = Get-CimInstance -ClassName Win32_BIOS
$CPU = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

$UptimeSpan = (Get-Date) - $OS.LastBootUpTime
$UptimeText = '{0}d {1}h {2}m' -f $UptimeSpan.Days, $UptimeSpan.Hours, $UptimeSpan.Minutes
$TotalRAM = [math]::Round($ComputerSystem.TotalPhysicalMemory / 1GB, 2)
$FreeRAM = [math]::Round($OS.FreePhysicalMemory / 1MB, 2)
$UsedRAMPercent = if ($TotalRAM -gt 0) {
    [math]::Round((($TotalRAM - $FreeRAM) / $TotalRAM) * 100, 1)
}
else {
    0
}

# 2. Diagnostyka dysków
Write-Host '[3/6] Analiza przestrzeni dyskowej...' -ForegroundColor Cyan
$Disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
    $SizeGB = [math]::Round($_.Size / 1GB, 2)
    $FreeGB = [math]::Round($_.FreeSpace / 1GB, 2)
    $FreePercent = if ($SizeGB -gt 0) {
        [math]::Round(($FreeGB / $SizeGB) * 100, 1)
    }
    else {
        0
    }

    [PSCustomObject]@{
        Drive       = $_.DeviceID
        VolumeName  = $_.VolumeName
        SizeGB      = $SizeGB
        FreeGB      = $FreeGB
        FreePercent = $FreePercent
        Status      = if ($FreePercent -lt [double]$Config.DiskWarningThresholdPercent) { 'WARNING' } else { 'HEALTHY' }
    }
})

# 3. Sieć i testy łączności
Write-Host '[4/6] Weryfikacja interfejsów sieciowych i DNS...' -ForegroundColor Cyan
try {
    $NetConfig = @(Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway } | ForEach-Object {
        [PSCustomObject]@{
            InterfaceAlias = $_.InterfaceAlias
            IPv4Address    = (@($_.IPv4Address | ForEach-Object { $_.IPAddress }) -join ', ')
            Gateway        = (@($_.IPv4DefaultGateway | ForEach-Object { $_.NextHop }) -join ', ')
            DNSServer      = (@($_.DNSServer.ServerAddresses) -join ', ')
        }
    })
}
catch {
    $NetConfig = @()
}

$NetTests = @(foreach ($Target in $Config.PingTargets) {
    $PingResult = $null
    try {
        $PingResult = Test-Connection -ComputerName $Target -Count 1 -ErrorAction Stop | Select-Object -First 1
    }
    catch {
        # Brak odpowiedzi oznacza host niedostępny; test pozostałych celów jest kontynuowany.
    }

    $Latency = '-'
    if ($null -ne $PingResult) {
        if ($PingResult.PSObject.Properties['ResponseTime']) {
            $Latency = $PingResult.ResponseTime
        }
        elseif ($PingResult.PSObject.Properties['Latency']) {
            $Latency = $PingResult.Latency
        }
    }

    [PSCustomObject]@{
        Target    = $Target
        Reachable = if ($null -ne $PingResult) { 'ONLINE' } else { 'OFFLINE' }
        LatencyMs = $Latency
    }
})

# 4. Procesy
Write-Host '[5/6] Sprawdzanie procesów...' -ForegroundColor Cyan
$TopProcesses = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object {
    [PSCustomObject]@{
        Name     = $_.ProcessName
        Id       = $_.Id
        MemoryMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
    }
})

# 5. Ostatnie błędy z dziennika System (ostatnie 24 godziny)
Write-Host '[6/6] Pobieranie ostatnich błędów z dziennika zdarzeń...' -ForegroundColor Cyan
$StartTime = (Get-Date).AddHours(-24)
try {
    $RecentErrors = @(Get-WinEvent -FilterHashtable @{
        LogName   = 'System'
        Level     = @(1, 2)
        StartTime = $StartTime
    } -MaxEvents 5 -ErrorAction Stop | Select-Object TimeCreated, Id, ProviderName, Message)
}
catch {
    $RecentErrors = @()
}

# Eksport danych do JSON
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$Hostname = $env:COMPUTERNAME
$ReportBaseName = "DiagReport_${Hostname}_${Timestamp}"
$GeneratedAt = Get-Date

$JsonData = [PSCustomObject]@{
    GeneratedAt = $GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')
    System      = [PSCustomObject]@{
        Hostname = $Hostname
        OS       = $OS.Caption
        Build    = $OS.BuildNumber
        Uptime   = $UptimeText
        Serial   = $BIOS.SerialNumber
    }
    Hardware    = [PSCustomObject]@{
        CPU             = $CPU.Name
        TotalRAM_GB     = $TotalRAM
        UsedRAM_Percent = $UsedRAMPercent
    }
    Disks            = $Disks
    NetworkInterfaces = $NetConfig
    NetworkTests      = $NetTests
    TopProcesses      = $TopProcesses
    RecentErrors      = $RecentErrors
}

$JsonPath = Join-Path -Path $OutputDir -ChildPath "$ReportBaseName.json"
$JsonData | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8

# 6. Budowanie raportu HTML
function ConvertTo-HtmlSafe {
    param([AllowNull()][object]$Value)
    [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

$DiskRows = foreach ($Disk in $Disks) {
    $StatusClass = if ($Disk.Status -eq 'HEALTHY') { 'ok' } else { 'warn' }
    '<tr><td>{0}</td><td>{1}</td><td>{2:N2} GB</td><td>{3:N2} GB ({4:N1}%)</td><td><span class="badge {5}">{6}</span></td></tr>' -f `
        (ConvertTo-HtmlSafe $Disk.Drive), (ConvertTo-HtmlSafe $Disk.VolumeName), $Disk.SizeGB, $Disk.FreeGB, $Disk.FreePercent, $StatusClass, $Disk.Status
}
if (-not $DiskRows) { $DiskRows = '<tr><td colspan="5">Brak danych o dyskach.</td></tr>' }

$NetworkRows = foreach ($Test in $NetTests) {
    $StatusClass = if ($Test.Reachable -eq 'ONLINE') { 'ok' } else { 'warn' }
    '<tr><td>{0}</td><td><span class="badge {1}">{2}</span></td><td>{3}</td></tr>' -f `
        (ConvertTo-HtmlSafe $Test.Target), $StatusClass, $Test.Reachable, (ConvertTo-HtmlSafe $Test.LatencyMs)
}
if (-not $NetworkRows) { $NetworkRows = '<tr><td colspan="3">Brak skonfigurowanych celów testowych.</td></tr>' }

$ProcessRows = foreach ($Process in $TopProcesses) {
    '<tr><td>{0}</td><td>{1}</td><td>{2:N1} MB</td></tr>' -f (ConvertTo-HtmlSafe $Process.Name), $Process.Id, $Process.MemoryMB
}
if (-not $ProcessRows) { $ProcessRows = '<tr><td colspan="3">Brak danych o procesach.</td></tr>' }

$ErrorRows = foreach ($Event in $RecentErrors) {
    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td></tr>' -f `
        (ConvertTo-HtmlSafe $Event.TimeCreated), $Event.Id, (ConvertTo-HtmlSafe $Event.ProviderName), (ConvertTo-HtmlSafe $Event.Message)
}
if (-not $ErrorRows) { $ErrorRows = '<tr><td colspan="4">Brak błędów w dzienniku z ostatnich 24 godzin.</td></tr>' }

$InterfaceSummary = if ($NetConfig.Count -gt 0) {
    ($NetConfig | ForEach-Object {
        '{0} — IPv4: {1}; brama: {2}; DNS: {3}' -f `
            (ConvertTo-HtmlSafe $_.InterfaceAlias), (ConvertTo-HtmlSafe $_.IPv4Address), `
            (ConvertTo-HtmlSafe $_.Gateway), (ConvertTo-HtmlSafe $_.DNSServer)
    }) -join '<br>'
}
else {
    'Nie wykryto aktywnego interfejsu z bramą IPv4.'
}

$HtmlPath = Join-Path -Path $OutputDir -ChildPath "$ReportBaseName.html"
$Html = @"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Raport diagnostyczny — $(ConvertTo-HtmlSafe $Hostname)</title>
    <style>
        body{font-family:Segoe UI,Arial,sans-serif;background:#f3f6fa;color:#1f2937;margin:0;padding:28px}
        main{max-width:1100px;margin:auto}h1{margin-bottom:4px}h2{font-size:18px;margin:0 0 14px}
        .muted{color:#64748b}.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:14px;margin:24px 0}
        .card,section{background:#fff;border:1px solid #e2e8f0;border-radius:10px;padding:18px}
        .value{font-size:22px;font-weight:600;margin-top:8px}.section{margin:16px 0}
        table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #e2e8f0;vertical-align:top}
        th{color:#475569;background:#f8fafc}.badge{padding:3px 9px;border-radius:999px;font-size:12px;font-weight:600}
        .ok{background:#dcfce7;color:#166534}.warn{background:#fef3c7;color:#92400e}
        .message{max-width:600px;white-space:pre-wrap;overflow-wrap:anywhere}
    </style>
</head>
<body>
<main>
    <h1>Raport diagnostyczny IT</h1>
    <div class="muted">Komputer: $(ConvertTo-HtmlSafe $Hostname) · Wygenerowano: $(ConvertTo-HtmlSafe $GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss'))</div>
    <div class="cards">
        <div class="card"><div class="muted">System</div><div class="value">$(ConvertTo-HtmlSafe $OS.Caption)</div><div>Build $(ConvertTo-HtmlSafe $OS.BuildNumber)</div></div>
        <div class="card"><div class="muted">Procesor</div><div class="value">$(ConvertTo-HtmlSafe $CPU.Name)</div></div>
        <div class="card"><div class="muted">Pamięć RAM</div><div class="value">$TotalRAM GB</div><div>Użycie: $UsedRAMPercent%</div></div>
        <div class="card"><div class="muted">Czas pracy</div><div class="value">$(ConvertTo-HtmlSafe $UptimeText)</div></div>
    </div>
    <section class="section"><h2>Dyski</h2><table><thead><tr><th>Dysk</th><th>Wolumin</th><th>Rozmiar</th><th>Wolne miejsce</th><th>Status</th></tr></thead><tbody>$($DiskRows -join "`n")</tbody></table></section>
    <section class="section"><h2>Sieć</h2><p>$InterfaceSummary</p><table><thead><tr><th>Cel</th><th>Status</th><th>Opóźnienie (ms)</th></tr></thead><tbody>$($NetworkRows -join "`n")</tbody></table></section>
    <section class="section"><h2>Procesy o największym użyciu pamięci</h2><table><thead><tr><th>Proces</th><th>PID</th><th>Pamięć</th></tr></thead><tbody>$($ProcessRows -join "`n")</tbody></table></section>
    <section class="section"><h2>Ostatnie błędy systemowe</h2><table><thead><tr><th>Czas</th><th>ID</th><th>Źródło</th><th>Komunikat</th></tr></thead><tbody>$($ErrorRows -join "`n")</tbody></table></section>
</main>
</body>
</html>
"@

$Html | Set-Content -LiteralPath $HtmlPath -Encoding UTF8
Write-Host "Raport JSON: $JsonPath" -ForegroundColor Green
Write-Host "Raport HTML: $HtmlPath" -ForegroundColor Green