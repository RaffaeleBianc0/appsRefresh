<#
.SYNOPSIS
    Automatically installs or updates your apps, listed in a CSV file.

.DESCRIPTION
                      ___      __            _
    __ _ _ __ _ __ __| _ \___ / _|_ _ ___ __| |_
   / _` | '_ \ '_ (_-<   / -_)  _| '_/ -_|_-< '  \
   \__,_| .__/ .__/__/_|_\___|_| |_| \___/__/_||_|
        |_|  |_|

    appsRefresh reads an apps.csv file (required column: AppID) and, for each listed app, checks via winget whether it is already installed and which version is installed. Based on the outcome:
      - if the app is not installed, it installs it (winget install);
      - if it is installed but out of date, it updates it (winget upgrade);
      - if it is already up to date, it is skipped.

    The status check runs on multiple parallel workers, while the install/update setups are executed sequentially (one worker at a time) to avoid running multiple installers at once on the machine.
    Progress (check, download, install/update) is shown live on screen.

    The script requires Administrator privileges.

.NOTES
    AUTHOR:      Raffaele Bianco
    VERSION:     0.10 (2026-08-10)
    BLOG POST:   https://github.com/
    GITHUB REPO: https://github.com/
    TROUBLESHOOTING:
        - Error 0x8a15000f --> Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.Winget.Source_8wekyb3d8bbwe
    CHANGELOG:
        * v0.10 (2026-08-10):
            - Fixed check worker logic to prevent queueing installed apps when versions match or no upgrade is needed, avoiding false "Downloading" phases.
        * v0.09 (2026-08-10):
            - Fixed progress bar and timer for Install/Update task when 0 apps require action.
        * v0.08 (2026-08-10):
            - Handled "No newer package versions are available" (or exit code 0x8a150010) as "Up to date" instead of an error.
            - Deferred Install/Update timer start until the first action task is actively triggered.
        * v0.07 (2026-08-10):
            - Kept Figlet header always visible at the top during live rendering.
            - Prefixed winget output panel and logs with the target AppID.
            - Captured and logged detailed StandardError output to diagnose failed operations.
        * v0.06 (2026-08-10):
            - Implemented auto-elevation (restarts as Administrator if required).
            - Added CSV apps listing in pre-flight preview.
            - Added persistent logging to appsRefresh.log (in script directory or %TEMP%).
            - Live output panel for winget at the bottom of the console window.
            - Progress bar brackets '[' and ']' added.
            - Format EL/ETA to show only mm:ss, and hide ETA when progress reaches 100%.
            - Prevent screen clear at completion to preserve terminal history.
        * v0.05 (2026-08-10):
            - Replaced setup download with direct install/update via winget (install/upgrade) based on the detected status.
            - Added a mandatory Administrator privileges check at script start.
            - Check task (parallel, multiple workers) separated from the install/update task, now forced to a single worker at a time (setups run sequentially).
            - Added the printProgress function for centralized management of progress bars (%, elapsed, ETA, colors).
            - Added an overall progress bar for the whole job, in addition to the check and install/update bars.
            - On-screen distinction between "Download in progress" and "Installing" phases while processing each app.
            - Progress bars with left-aligned text (not centered), order %/EL/ETA, ETA with a leading "-" sign, and label colored green once it reaches 100%.
            - Added blank lines before and after the progress bar area.
            - Translated all comments, strings, and variable names to English for an international audience.
        * v0.02 - v0.04:
            - Not tracked. :-)
        * v0.01:
            - Initial version: parallel CSV analysis and setup download for outdated apps, with a live console dashboard and final report.
    TODO:
        - The "Downloading..." action happens even when no download is required. And the corresponding progressbar shows elapsed time when at 100%, even when no download has happened. Please fix this.
#>

[CmdletBinding()]
param(
    [string]$CsvPath       = '',
    [int]   $CheckWorkers  = 2,
    [int]   $ActionRetries = 2
)

# --- AUTO-ELEVATION / ADMINISTRATOR CHECK ----------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevating privileges to Administrator..." -ForegroundColor Yellow
    $scriptPath = $MyInvocation.MyCommand.Path
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        $scriptPath = $PSCommandPath
    }
    $argsList = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    if ($CsvPath) { $argsList += " -CsvPath `"$CsvPath`"" }
    $argsList += " -CheckWorkers $CheckWorkers -ActionRetries $ActionRetries"

    Start-Process powershell -Verb RunAs -ArgumentList $argsList
    return
}

# --- SCRIPT SETUP & LOGGING ------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir) -and $MyInvocation.MyCommand.Path) {
        $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    if ([string]::IsNullOrWhiteSpace($scriptDir)) {
        $scriptDir = (Get-Location).Path
    }
    $CsvPath = Join-Path $scriptDir 'apps.csv'
} else {
    $scriptDir = Split-Path -Parent $CsvPath
}

# Configure log file path
$logFileName = "appsRefresh.log"
$primaryLog  = Join-Path $scriptDir $logFileName
$fallbackLog = Join-Path $env:TEMP $logFileName

$logPath = $primaryLog
try {
    "=== Session started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -FilePath $primaryLog -Append -ErrorAction Stop
} catch {
    $logPath = $fallbackLog
    "=== Session started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ===" | Out-File -FilePath $fallbackLog -Append -ErrorAction SilentlyContinue
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO ")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine   = "$timestamp $Level $Message"
    try {
        $logLine | Out-File -FilePath $logPath -Append -ErrorAction SilentlyContinue
    } catch { }
}

Write-Log "appsRefresh initialized. Log path: $logPath"

$csvPath        = $CsvPath
$CHECK_WORKERS  = $CheckWorkers
$ACTION_WORKERS = 1
$ACTION_RETRIES = $ActionRetries

# Header height and layout positions
$Script:HEADER_ROWS         = 7
$Script:ROW_ACTIVE          = $Script:HEADER_ROWS + 0
$Script:ROW_BLANK_1         = $Script:HEADER_ROWS + 1
$Script:ROW_CHECK           = $Script:HEADER_ROWS + 2
$Script:ROW_ACTION          = $Script:HEADER_ROWS + 3
$Script:ROW_GLOBAL          = $Script:HEADER_ROWS + 4
$Script:ROW_BLANK_2         = $Script:HEADER_ROWS + 5
$Script:TOP_RESERVED_ROWS   = $Script:HEADER_ROWS + 6
$Script:WINGET_PANEL_HEIGHT = 5

# --- PRE-CHECK AND PREVIEW -------------------------------------------------------
$figletHeader = @'
                   ___      __            _
 __ _ _ __ _ __ __| _ \___ / _|_ _ ___ __| |_
/ _` | '_ \ '_ (_-<   / -_)  _| '_/ -_|_-< .  \
\__,_| .__/ .__/__/_|_\___|_| |_| \___/__/_||_|
     |_|  |_|
'@

function Get-ConsoleHeader {
    $w = $Host.UI.RawUI.WindowSize.Width
    if ($w -lt 84) {
        $sep   = "==========="
        $title = "appsRefresh"
        return @("", $sep, $title, $sep, "", "") -join "`n"
    }
    return $figletHeader
}

Clear-Host
Write-Host (Get-ConsoleHeader) -ForegroundColor White
Write-Host ""

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    $errMsg = "winget not found in PATH. Install 'App Installer' from the Microsoft Store."
    Write-Error $errMsg
    Write-Log $errMsg "ERROR"
    Read-Host "`nPress ENTER to quit..."
    return
}

if (-not (Test-Path $csvPath)) {
    $errMsg = "apps.csv file not found: $csvPath"
    Write-Error $errMsg
    Write-Log $errMsg "ERROR"
    Read-Host "`nPress ENTER to quit..."
    return
}

$apps = Import-Csv -Path $csvPath

if ($apps.Count -eq 0) {
    $errMsg = "The apps.csv file contains no rows to process."
    Write-Error $errMsg
    Write-Log $errMsg "ERROR"
    Read-Host "`nPress ENTER to quit..."
    return
}

if ('AppID' -notin $apps[0].psobject.Properties.Name) {
    $errMsg = "Required column missing from CSV: AppID"
    Write-Error $errMsg
    Write-Log $errMsg "ERROR"
    Read-Host "`nPress ENTER to quit..."
    return
}

$totalApps = $apps.Count

# PRE-FLIGHT SUMMARY & CSV LISTING
Write-Host "Csv path:   " -ForegroundColor Yellow -NoNewline
Write-Host $csvPath
Write-Host "Total apps: " -ForegroundColor Cyan -NoNewline
Write-Host $totalApps
Write-Host "Check workers: $CHECK_WORKERS   Install/update: 1 at a time   Retries: $ACTION_RETRIES" -ForegroundColor DarkGray
Write-Host "`nLoaded Applications from CSV:"
Write-Host "----------------------------------------" -ForegroundColor DarkGray
foreach ($app in $apps) {
    Write-Host " - $($app.AppID)" -ForegroundColor White
}
Write-Host "----------------------------------------`n" -ForegroundColor DarkGray

Read-Host "Press ENTER to confirm and continue..."
Clear-Host

# --- INIT --------------------------------------------------------------------------
$startTime = Get-Date
$actionStartTime = $null

$script:checkEndTime    = $null
$script:lastDisplayTime = Get-Date
$script:lastWinWidth    = $null
$script:lastWinHeight   = $null

# Thread-safe queues
$CheckInputQueue = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
foreach ($row in $apps) { $CheckInputQueue.Enqueue($row) }

$ActionQueue = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))

$SharedState = [hashtable]::Synchronized(@{
    List             = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    Active           = 0
    Done             = 0
    Failed           = 0
    TotalToProcess   = 0
    CheckedCount     = 0
    CheckFinished    = $false
    CheckWorkersDone = 0
    StatUpToDate     = 0
    StatInstalled    = 0
    StatUpdated      = 0
    WingetOutput     = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    CounterLock      = New-Object System.Object
})

# --- HELPERS -------------------------------------------------------------------------
function Format-Cell {
    param([string]$s, [int]$len)
    if (-not $s) { $s = "" }
    $s = $s.PadRight($len)
    if ($s.Length -gt $len) { return $s.Substring(0, $len) }
    return $s
}

function Sync-ConsoleBuffer {
    try {
        $curW = [Console]::WindowWidth
        $curH = [Console]::WindowHeight
        if ([Console]::BufferWidth -lt $curW)  { [Console]::BufferWidth  = $curW }
        if ([Console]::BufferHeight -lt $curH) { [Console]::BufferHeight = $curH }
    } catch { }
}

function Sync-ConsoleLayout {
    Sync-ConsoleBuffer
    $curW = [Console]::WindowWidth
    $curH = [Console]::WindowHeight
    $resized = ($script:lastWinWidth -ne $curW) -or ($script:lastWinHeight -ne $curH)
    if ($resized) {
        try {
            $script:lastWinWidth  = $curW
            $script:lastWinHeight = $curH
        } catch { }
    }
    return $resized
}

function Write-LogThreadSafe {
    param([string]$Message, [string]$Level = "INFO ")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine   = "$timestamp $Level $Message"
    try {
        $logLine | Out-File -FilePath $script:logPath -Append -ErrorAction SilentlyContinue
    } catch { }
}

# +==============================================================================+
# |  printProgress - generic progress bar with %, EL (mm:ss), ETA (mm:ss)       |
# +==============================================================================+
function printProgress {
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][int]$ProgressWidth,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][double]$PercentComplete,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [System.ConsoleColor]$BarColor = [System.ConsoleColor]::Cyan
    )

    $pct = $PercentComplete
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }

    if ($null -ne $StartTime -and $StartTime -ne [datetime]::MinValue) {
        $refTime = if ($EndTime -and $EndTime -ne [datetime]::MinValue) { $EndTime } else { Get-Date }
        $elapsed = $refTime - $StartTime
        if ($elapsed.TotalSeconds -lt 0) { $elapsed = [TimeSpan]::Zero }
    } else {
        $elapsed = [TimeSpan]::Zero
    }
    
    # Show only minutes and seconds in EL (mm:ss)
    $elapsedStr = "{0:00}:{1:00}" -f [math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    $etaStr = ""
    # Hide ETA completely when at 100% or timer not started
    if ($pct -lt 100 -and $pct -gt 0 -and $null -ne $StartTime -and $StartTime -ne [datetime]::MinValue) {
        $totalEstSec = ($elapsed.TotalSeconds / $pct) * 100.0
        $remSec = $totalEstSec - $elapsed.TotalSeconds
        if ($remSec -lt 0) { $remSec = 0 }
        $etaSpan = [TimeSpan]::FromSeconds($remSec)
        # Show only minutes and seconds in ETA (mm:ss)
        $etaStr = "ETA:-{0:00}:{1:00}" -f [math]::Floor($etaSpan.TotalMinutes), $etaSpan.Seconds
    }

    $label = if ([string]::IsNullOrEmpty($TaskName)) { "" } else { Format-Cell "$TaskName " 24 }
    
    # Progress bar enclosed in brackets '[' and ']'
    $innerBarWidth = $ProgressWidth - $label.Length - 2
    if ($innerBarWidth -lt 6) { $innerBarWidth = 6 }

    $filled = [int][math]::Round(($pct / 100.0) * $innerBarWidth)
    if ($filled -gt $innerBarWidth) { $filled = $innerBarWidth }
    if ($filled -lt 0) { $filled = 0 }

    $pctText = " {0,3}%" -f [math]::Round($pct)
    $elText  = "EL:$elapsedStr"

    $infoText = $pctText
    if ($innerBarWidth -ge ($pctText.Length + 2 + $elText.Length)) {
        $infoText = "$pctText   $elText"
        if ($etaStr -ne "" -and $innerBarWidth -ge ($infoText.Length + 2 + $etaStr.Length)) {
            $infoText = "$infoText   $etaStr"
        }
    }
    if ($infoText.Length -gt $innerBarWidth) { $infoText = $infoText.Substring(0, $innerBarWidth) }
    $infoLine = $infoText.PadRight($innerBarWidth)

    $labelColor = if ($pct -ge 100) { [System.ConsoleColor]::Green } else { [System.ConsoleColor]::White }

    try {
        [Console]::SetCursorPosition($X, $Y)
        Write-Host $label -NoNewline -ForegroundColor $labelColor
        Write-Host "[" -NoNewline -ForegroundColor White

        for ($i = 0; $i -lt $innerBarWidth; $i++) {
            $ch = $infoLine[$i]
            if ($i -lt $filled) {
                Write-Host $ch -NoNewline -ForegroundColor Black -BackgroundColor $BarColor
            } else {
                Write-Host $ch -NoNewline -ForegroundColor $BarColor -BackgroundColor Black
            }
        }
        Write-Host "]" -NoNewline -ForegroundColor White
    } catch { }
}

# +==============================================================================+
# |  LIVE RENDERING                                                              |
# +==============================================================================+
function Update-CombinedDisplay {
    param(
        [datetime]$StartTime,
        $ActionStartTime,
        [int]$TotalAppsCount,
        [switch]$ForceComplete
    )

    try {
        [void](Sync-ConsoleLayout)

        $wH = [Console]::WindowHeight
        $cW = [Console]::WindowWidth - 1
        if ($cW -lt 50) { $cW = 50 }

        # --- DRAW PERSISTENT FIGLET HEADER ---
        [Console]::SetCursorPosition(0, 0)
        $headerLines = (Get-ConsoleHeader) -split "`n"
        for ($h = 0; $h -lt [math]::Min($headerLines.Count, $Script:HEADER_ROWS); $h++) {
            [Console]::SetCursorPosition(0, $h)
            Write-Host (Format-Cell $headerLines[$h] $cW) -ForegroundColor White -NoNewline
        }

        $wingetPanelHeight = $Script:WINGET_PANEL_HEIGHT
        $topReservedRows    = $Script:TOP_RESERVED_ROWS
        $listAreaRows       = $wH - $topReservedRows - $wingetPanelHeight
        if ($listAreaRows -lt 1) { $listAreaRows = 1 }

        $localList = @($SharedState.List)

        # --- CHECK bar -----------------------------------------------------------
        $checkDone = $SharedState.CheckFinished -or $ForceComplete
        $checked   = if ($checkDone) { $TotalAppsCount } else { $SharedState.CheckedCount }
        $checkPct  = if ($TotalAppsCount -gt 0) { ($checked / [double]$TotalAppsCount) * 100.0 } else { 100.0 }
        $checkEnd  = if ($checkDone -and $script:checkEndTime) { $script:checkEndTime } else { [datetime]::MinValue }

        printProgress -X 0 -Y $Script:ROW_CHECK -ProgressWidth $cW -TaskName "Check [$checked/$TotalAppsCount]" `
            -PercentComplete $checkPct -StartTime $StartTime -EndTime $checkEnd -BarColor Cyan

        # --- INSTALL/UPDATE bar ---------------------------------------------------
        $totalProc = $SharedState.TotalToProcess
        $procDone  = $SharedState.Done + $SharedState.Failed
        
        $actionStartToPass = $ActionStartTime
        $actionEndToPass   = [datetime]::MinValue

        if ($ForceComplete) {
            $procPct = 100.0
        } elseif ($totalProc -gt 0) {
            $procPct = ($procDone / [double]$totalProc) * 100.0
        } else {
            if ($SharedState.CheckFinished) {
                $procPct = 100.0
                $actionStartToPass = [datetime]::MinValue
            } else {
                $procPct = 0.0
                $actionStartToPass = [datetime]::MinValue
            }
        }

        printProgress -X 0 -Y $Script:ROW_ACTION -ProgressWidth $cW -TaskName "Install/Update [$procDone/$totalProc]" `
            -PercentComplete $procPct -StartTime $actionStartToPass -EndTime $actionEndToPass -BarColor Yellow

        # --- OVERALL bar -----------------------------------------------------------
        $globalUnitsTotal = $TotalAppsCount + [math]::Max($totalProc, $procDone)
        $globalUnitsDone  = $checked + $procDone
        $globalPct = if ($ForceComplete) { 100.0 }
                     elseif ($globalUnitsTotal -gt 0) { ($globalUnitsDone / [double]$globalUnitsTotal) * 100.0 }
                     else { 0.0 }

        printProgress -X 0 -Y $Script:ROW_GLOBAL -ProgressWidth $cW -TaskName "TOTAL" `
            -PercentComplete $globalPct -StartTime $StartTime -BarColor Green

        [Console]::SetCursorPosition(0, $Script:ROW_ACTIVE)
        $activeStr = "Check: $($CHECK_WORKERS - $SharedState.CheckWorkersDone)/$CHECK_WORKERS workers   Install/Update: $($SharedState.Active)/$ACTION_WORKERS slot"
        Write-Host (Format-Cell $activeStr $cW) -ForegroundColor DarkGray -NoNewline

        # Blank lines before and after progress bar area
        [Console]::SetCursorPosition(0, $Script:ROW_BLANK_1)
        Write-Host (' ' * $cW) -NoNewline
        [Console]::SetCursorPosition(0, $Script:ROW_BLANK_2)
        Write-Host (' ' * $cW) -NoNewline

        # --- APP LIST -------------------------------------------------------------
        $statusOrder = @{ "Running" = 0; "Checking" = 1; "Queued" = 2; "Failed" = 3; "Installed" = 4; "Updated" = 4; "Up to date" = 5 }
        $sorted      = @($localList | Sort-Object { $statusOrder[$_.Status] })
        $startIdx    = [math]::Max(0, $sorted.Count - $listAreaRows)
        $displayList = if ($sorted.Count -gt 0) { $sorted[$startIdx..($sorted.Count - 1)] } else { @() }

        $rowIdx = $topReservedRows
        foreach ($item in $displayList) {
            $dispStatus = if ($ForceComplete -and $item.Status -eq "Running") { "Completed" } else { $item.Status }
            $retryTag   = if ($item.Retries -gt 0) { " [retry $($item.Retries)/$ACTION_RETRIES]" } else { "" }

            $line = switch ($dispStatus) {
                "Installed"  { "[OK] $(Format-Cell $item.AppID 40) - Installed$retryTag" }
                "Updated"    { "[OK] $(Format-Cell $item.AppID 40) - Updated ($($item.OldVersion) -> $($item.NewVersion))$retryTag" }
                "Up to date" { "[==] $(Format-Cell $item.AppID 40) - Up to date" }
                "Running"    {
                    $phaseLabel = if ($item.Phase -eq "Installing") { "Installing" } else { "Downloading" }
                    "[..] $(Format-Cell $item.AppID 40) - $phaseLabel...$retryTag"
                }
                "Queued"     { "[qu] $(Format-Cell $item.AppID 40) - Queued ($($item.Action))$retryTag" }
                "Checking"   { "[?.] $(Format-Cell $item.AppID 40) - Checking installation status..." }
                "Failed"     { "[!!] $(Format-Cell $item.AppID 40) - $($item.Action) failed$retryTag" }
                default      { "[??] $(Format-Cell $item.AppID 40) - $dispStatus" }
            }
            $color = switch ($dispStatus) {
                "Installed"  { "Green"    }
                "Updated"    { "Green"    }
                "Up to date" { "DarkGray" }
                "Running"    { if ($item.Phase -eq "Installing") { "Magenta" } else { "Yellow" } }
                "Queued"     { "White"    }
                "Checking"   { "Cyan"     }
                "Failed"     { "Red"      }
                default      { "Gray"     }
            }

            [Console]::SetCursorPosition(0, $rowIdx)
            Write-Host (Format-Cell $line $cW) -ForegroundColor $color -NoNewline
            $rowIdx++
        }

        while ($rowIdx -lt ($wH - $wingetPanelHeight)) {
            [Console]::SetCursorPosition(0, $rowIdx)
            Write-Host (' ' * $cW) -NoNewline
            $rowIdx++
        }

        # --- LOWER CONSOLE: LIVE WINGET OUTPUT PANEL -----------------------------
        $panelStartRow = $wH - $wingetPanelHeight
        [Console]::SetCursorPosition(0, $panelStartRow)
        Write-Host (Format-Cell "--- Winget Output Stream ---" $cW) -ForegroundColor DarkGray -NoNewline

        $wingetLogs = @($SharedState.WingetOutput)
        $startLogIdx = [math]::Max(0, $wingetLogs.Count - ($wingetPanelHeight - 1))
        
        for ($p = 0; $p -lt ($wingetPanelHeight - 1); $p++) {
            $currRow = $panelStartRow + 1 + $p
            $logIdx  = $startLogIdx + $p
            $logText = if ($logIdx -lt $wingetLogs.Count) { $wingetLogs[$logIdx] } else { "" }
            [Console]::SetCursorPosition(0, $currRow)
            Write-Host (Format-Cell " > $logText" $cW) -ForegroundColor Gray -NoNewline
        }

    } catch { }
}

# +==============================================================================+
# |  FINAL REPORT                                                               |
# +==============================================================================+
function Show-FinalReport {
    param(
        [datetime]$StartTime,
        [int]$TotalApps,
        $SharedState,
        [string]$DurationString,
        $CheckEndTime
    )

    $failColor = if ($SharedState.Failed -gt 0) { "Red" } else { "DarkGray" }

    $reportLines = @(
        @{ T = "-" * 48;                                                    C = "DarkGray" }
        @{ T = "Total apps evaluated  :  $TotalApps";                       C = "White"    }
        @{ T = "Already up to date    :  $($SharedState.StatUpToDate)";     C = "DarkGray" }
        @{ T = "Newly installed       :  $($SharedState.StatInstalled)";    C = "Green"    }
        @{ T = "Updated               :  $($SharedState.StatUpdated)";      C = "Green"    }
        @{ T = "Failed operations     :  $($SharedState.Failed)";           C = $failColor }
        @{ T = "-" * 48;                                                    C = "DarkGray" }
    )

    $cW = [Console]::WindowWidth - 1
    if ($cW -lt 50) { $cW = 50 }

    try {
        Sync-ConsoleBuffer
        [Console]::CursorVisible = $false

        $wH = [Console]::WindowHeight
        $topReservedRows = $Script:TOP_RESERVED_ROWS
        $listAreaRows    = [Math]::Max(1, $wH - $topReservedRows - $Script:WINGET_PANEL_HEIGHT)
        $itemCount       = $SharedState.List.Count
        $visibleItems    = [Math]::Min($itemCount, $listAreaRows)
        $lastRow         = $topReservedRows + $visibleItems

        $requiredBufferHeight = $lastRow + $reportLines.Count + $Script:WINGET_PANEL_HEIGHT + 2
        if ([Console]::BufferHeight -lt $requiredBufferHeight) {
            [Console]::BufferHeight = $requiredBufferHeight
        }

        [Console]::SetCursorPosition(0, $lastRow)
        Write-Host "`n"
        foreach ($line in $reportLines) {
            Write-Host (Format-Cell "$($line.T)" $cW) -ForegroundColor $line.C
        }
    } catch {
        foreach ($line in $reportLines) {
            Write-Host $line.T -ForegroundColor $line.C
        }
    }

    [Console]::CursorVisible = $true
}

# +==============================================================================+
# |  SCRIPTBLOCKS                                                               |
# +==============================================================================+
$checkWorkerScript = {
    param($CheckInputQueue, $ActionQueue, $SharedState, $LogPath)

    function Write-LogWorker {
        param([string]$Message, [string]$Level = "INFO ")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logLine   = "$timestamp $Level $Message"
        try {
            $logLine | Out-File -FilePath $LogPath -Append -ErrorAction SilentlyContinue
        } catch { }
    }

    while ($true) {
        $row = $null
        [System.Threading.Monitor]::Enter($CheckInputQueue.SyncRoot)
        try {
            if ($CheckInputQueue.Count -gt 0) { $row = $CheckInputQueue.Dequeue() }
        } finally {
            [System.Threading.Monitor]::Exit($CheckInputQueue.SyncRoot)
        }
        if ($null -eq $row) { break }

        $appId = $row.AppID

        $pkg = [PSCustomObject]@{
            AppID       = $appId
            Status      = "Checking"
            Action      = ""
            Phase       = ""
            OldVersion  = ""
            NewVersion  = ""
            Retries     = 0
        }
        $null = $SharedState.List.Add($pkg)

        # Installed version check
        $listText = winget list --id $appId -e --accept-source-agreements 2>&1 | Out-String
        $isInstalled = ($listText -match [regex]::Escape($appId))
        $installedVersion = "Unknown"
        if ($isInstalled) {
            foreach ($line in ($listText -split "`r?`n")) {
                if ($line -match [regex]::Escape($appId)) {
                    $cols = ($line -split '\s{2,}')
                    if ($cols.Count -ge 3) { $installedVersion = $cols[2].Trim() }
                }
            }
        }

        # Available version check
        $showText = winget show --id $appId --accept-source-agreements -e 2>&1 | Out-String
        $availableVersion = "Unknown"
        if ($showText -match '(?:Version):\s*([^\s\r\n]+)') { $availableVersion = $Matches[1].Trim() }

        # Check explicit upgrade availability via winget upgrade dry-run
        $hasUpgrade = $false
        if ($isInstalled) {
            $upgradeText = winget upgrade --id $appId --accept-source-agreements -e 2>&1 | Out-String
            if ($upgradeText -match [regex]::Escape($appId) -and $upgradeText -notmatch 'No newer package versions are available|Nessun pacchetto pi. recente disponibile|No applicable update found') {
                $hasUpgrade = $true
            }
        }

        [System.Threading.Monitor]::Enter($SharedState.CounterLock)
        try {
            if (-not $isInstalled) {
                $pkg.Action     = "Install"
                $pkg.OldVersion = ""
                $pkg.NewVersion = $availableVersion
                $pkg.Status     = "Queued"
                $SharedState.TotalToProcess++
                $null = $ActionQueue.Add($pkg)
            } elseif ($hasUpgrade -or ($availableVersion -ne "Unknown" -and $installedVersion -ne "Unknown" -and $installedVersion -ne $availableVersion)) {
                $pkg.Action     = "Update"
                $pkg.OldVersion = $installedVersion
                $pkg.NewVersion = $availableVersion
                $pkg.Status     = "Queued"
                $SharedState.TotalToProcess++
                $null = $ActionQueue.Add($pkg)
            } else {
                $pkg.OldVersion = $installedVersion
                $pkg.Status     = "Up to date"
                $SharedState.StatUpToDate++
            }
            $SharedState.CheckedCount++
        } finally {
            [System.Threading.Monitor]::Exit($SharedState.CounterLock)
        }
    }

    [System.Threading.Monitor]::Enter($SharedState.CounterLock)
    try { $SharedState.CheckWorkersDone++ }
    finally { [System.Threading.Monitor]::Exit($SharedState.CounterLock) }
}

$actionWorkerScript = {
    param($Item, $SharedState, $LogPath)

    function Write-LogWorker {
        param([string]$Message, [string]$Level = "INFO ")
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logLine   = "$timestamp $Level $Message"
        try {
            $logLine | Out-File -FilePath $LogPath -Append -ErrorAction SilentlyContinue
        } catch { }
    }

    $Item.Status = "Running"
    $Item.Phase  = "Downloading"

    $verb = if ($Item.Action -eq "Install") { "install" } else { "upgrade" }
    $success = $false
    $isAlreadyUpToDate = $false

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = "winget"
        $psi.Arguments              = "$verb --id $($Item.AppID) -e --accept-source-agreements --accept-package-agreements --silent"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.UseShellExecute        = $false
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)

        while (-not $proc.HasExited) {
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    $cleanLine = "[$($Item.AppID)] " + $line.Trim()
                    $null = $SharedState.WingetOutput.Add($cleanLine)
                    Write-LogWorker $cleanLine "WINGET"
                    if ($line -match 'No newer package versions are available|Nessun pacchetto pi. recente disponibile|No applicable update found') {
                        $isAlreadyUpToDate = $true
                    }
                    if ($line -match 'Install|Installing') {
                        $Item.Phase = "Installing"
                    } elseif ($line -match 'Download|Downloading') {
                        $Item.Phase = "Downloading"
                    }
                }
            }
            while (-not $proc.StandardError.EndOfStream) {
                $errLine = $proc.StandardError.ReadLine()
                if (-not [string]::IsNullOrWhiteSpace($errLine)) {
                    $cleanErr = "[$($Item.AppID)] ERROR: " + $errLine.Trim()
                    $null = $SharedState.WingetOutput.Add($cleanErr)
                    Write-LogWorker $cleanErr "ERROR "
                    if ($errLine -match 'No newer package versions are available|Nessun pacchetto pi. recente disponibile|No applicable update found') {
                        $isAlreadyUpToDate = $true
                    }
                }
            }
            Start-Sleep -Milliseconds 150
        }

        while (-not $proc.StandardOutput.EndOfStream) {
            $line = $proc.StandardOutput.ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $cleanLine = "[$($Item.AppID)] " + $line.Trim()
                $null = $SharedState.WingetOutput.Add($cleanLine)
                Write-LogWorker $cleanLine "WINGET"
                if ($line -match 'No newer package versions are available|Nessun pacchetto pi. recente disponibile|No applicable update found') {
                    $isAlreadyUpToDate = $true
                }
            }
        }
        while (-not $proc.StandardError.EndOfStream) {
            $errLine = $proc.StandardError.ReadLine()
            if (-not [string]::IsNullOrWhiteSpace($errLine)) {
                $cleanErr = "[$($Item.AppID)] ERROR: " + $errLine.Trim()
                $null = $SharedState.WingetOutput.Add($cleanErr)
                Write-LogWorker $cleanErr "ERROR "
                if ($errLine -match 'No newer package versions are available|Nessun pacchetto pi. recente disponibile|No applicable update found') {
                    $isAlreadyUpToDate = $true
                }
            }
        }

        $proc.WaitForExit()

        # Handle exit codes (0x8a150010 / -1978335216 corresponds to APPINSTALLER_CLI_ERROR_NO_APPLICABLE_UPDATE)
        if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq -1978335216 -or $proc.ExitCode -eq 0x8a150010) {
            if ($proc.ExitCode -eq -1978335216 -or $proc.ExitCode -eq 0x8a150010) {
                $isAlreadyUpToDate = $true
            }
            $success = $true
        } else {
            $success = $false
        }

        if (-not $success -and -not $isAlreadyUpToDate) {
            $exitMsg = "[$($Item.AppID)] Winget process exited with failure code: $($proc.ExitCode)"
            $null = $SharedState.WingetOutput.Add($exitMsg)
            Write-LogWorker $exitMsg "ERROR "
        }
    } catch {
        $exMsg = "[$($Item.AppID)] Exception executing winget: $($_.Exception.Message)"
        $null = $SharedState.WingetOutput.Add($exMsg)
        Write-LogWorker $exMsg "ERROR "
        $success = $false
    }

    [System.Threading.Monitor]::Enter($SharedState.CounterLock)
    try {
        $SharedState.Active--
        if ($isAlreadyUpToDate) {
            $Item.Status = "Up to date"
            $SharedState.TotalToProcess--
            $SharedState.StatUpToDate++
        } elseif ($success) {
            $Item.Status = if ($Item.Action -eq "Install") { "Installed" } else { "Updated" }
            $SharedState.Done++
            if ($Item.Action -eq "Install") { $SharedState.StatInstalled++ } else { $SharedState.StatUpdated++ }
        } else {
            $Item.Status = "Failed"
            $SharedState.Failed++
        }
    } finally {
        [System.Threading.Monitor]::Exit($SharedState.CounterLock)
    }
}

# --- CONSOLE SETUP AND EXECUTION -----------------------------------------------
Sync-ConsoleBuffer
$script:lastWinWidth  = [Console]::WindowWidth
$script:lastWinHeight = [Console]::WindowHeight
[Console]::CursorVisible = $false

# --- START CHECK WORKERS ---------------------------------------------------------
$checkPowerShells = New-Object System.Collections.Generic.List[object]
for ($w = 0; $w -lt $CHECK_WORKERS; $w++) {
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript($checkWorkerScript).AddArgument($CheckInputQueue).AddArgument($ActionQueue).AddArgument($SharedState).AddArgument($logPath)
    $null = $checkPowerShells.Add([PSCustomObject]@{ PowerShell = $ps; AsyncResult = $ps.BeginInvoke() })
}

$actionJobs = New-Object System.Collections.Generic.List[object]

# +==============================================================================+
# |  MAIN ORCHESTRATION LOOP                                                     |
# +==============================================================================+
while (-not $SharedState.CheckFinished -or $ActionQueue.Count -gt 0 -or $SharedState.Active -gt 0) {
    $updated = $false

    if (-not $SharedState.CheckFinished -and $SharedState.CheckWorkersDone -ge $CHECK_WORKERS) {
        $SharedState.CheckFinished = $true
        $script:checkEndTime = Get-Date
        $updated = $true
    }

    while ($SharedState.Active -lt $ACTION_WORKERS -and $ActionQueue.Count -gt 0) {
        if ($null -eq $actionStartTime) {
            $actionStartTime = Get-Date
        }

        $nextItem = $ActionQueue[0]
        $ActionQueue.RemoveAt(0)
        $nextItem.Status = "Running"
        $SharedState.Active++
        $updated = $true

        Write-Log "Starting $($nextItem.Action) for $($nextItem.AppID)"

        $ps = [PowerShell]::Create()
        $null = $ps.AddScript($actionWorkerScript).AddArgument($nextItem).AddArgument($SharedState).AddArgument($logPath)
        $null = $actionJobs.Add([PSCustomObject]@{ PowerShell = $ps; AsyncResult = $ps.BeginInvoke(); Item = $nextItem })
    }

    for ($i = $actionJobs.Count - 1; $i -ge 0; $i--) {
        if (-not $actionJobs[$i].AsyncResult.IsCompleted) { continue }

        $null = $actionJobs[$i].PowerShell.EndInvoke($actionJobs[$i].AsyncResult)
        $actionJobs[$i].PowerShell.Dispose()
        $doneItem = $actionJobs[$i].Item
        $actionJobs.RemoveAt($i)
        $updated = $true

        Write-Log "Task finished for $($doneItem.AppID). Status: $($doneItem.Status)"

        if ($doneItem.Status -eq "Failed") {
            Write-Log "Operation failed on app $($doneItem.AppID) (Retry $($doneItem.Retries)/$ACTION_RETRIES)" "WARN "
            if ($doneItem.Retries -lt $ACTION_RETRIES) {
                $doneItem.Retries++
                $doneItem.Status = "Queued"
                [System.Threading.Monitor]::Enter($SharedState.CounterLock)
                try { $SharedState.Failed-- }
                finally { [System.Threading.Monitor]::Exit($SharedState.CounterLock) }
                $null = $ActionQueue.Add($doneItem)
            }
        }
    }

    $currentTime = Get-Date
    if ($updated -or ($currentTime - $script:lastDisplayTime).TotalMilliseconds -ge 1000) {
        $script:lastDisplayTime = $currentTime
        Update-CombinedDisplay -StartTime $startTime -ActionStartTime $actionStartTime -TotalAppsCount $totalApps
    }

    Start-Sleep -Milliseconds 100
}

# --- CHECK WORKERS CLEANUP -------------------------------------------------------
foreach ($w in $checkPowerShells) {
    $null = $w.PowerShell.EndInvoke($w.AsyncResult)
    $w.PowerShell.Dispose()
}

# --- FINAL SNAPSHOT ----------------------------------------------------------------
Update-CombinedDisplay -StartTime $startTime -ActionStartTime $actionStartTime -TotalAppsCount $totalApps -ForceComplete

# --- FINAL REPORT --------------------------------------------------------------------
$endTime        = Get-Date
$totalDuration  = $endTime - $startTime
$durationString = "{0}m {1:00}s" -f [math]::Floor($totalDuration.TotalMinutes), $totalDuration.Seconds

Write-Log "Execution completed. Duration: $durationString. Failed: $($SharedState.Failed)"

Show-FinalReport `
    -StartTime      $startTime `
    -TotalApps      $totalApps `
    -SharedState    $SharedState `
    -DurationString $durationString `
    -CheckEndTime   $script:checkEndTime

Read-Host "`nDone. Press ENTER to quit..."