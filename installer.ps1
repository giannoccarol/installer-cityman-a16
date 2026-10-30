<#
.SYNOPSIS
    Installs LineageOS 23.2 (Android 16) on the Lumia 950 XL (cityman).

.DESCRIPTION
    Full    Phone still on Windows (10 Mobile or WOA), unlocked with WPInternals.
            Runs the steps of the official Android4Lumia950 installer (Developer
            Menu, boot shim and LK on EFIESP; Android partitions; backup of the
            provisioning partitions; recovery and modem; provisioning), then boots
            the Android 16 TWRP, formats data and sideloads the ROM.
    Clean   Phone that already has LK and the Android partitions (for example
            LineageOS 18.1 from the official installer). Boots the Android 16 TWRP,
            formats data and sideloads the ROM.
    Update  Phone already on this LineageOS 23.2 port. Boots the Android 16 TWRP
            and sideloads the ROM. Data is kept.

    Every file is checked (SHA-256) before it is written, and the installer stops
    with a message at the first error.

.EXAMPLE
    .\installer.ps1
.EXAMPLE
    .\installer.ps1 -Mode Update -Rom D:\lineage-23.2-20261030-UNOFFICIAL-cityman.zip
#>
[CmdletBinding()]
param(
    [ValidateSet('', 'Full', 'Clean', 'Update')]
    [string]$Mode = '',
    # ROM zip. Default: the only lineage-23.2-*-cityman.zip in the 'rom' folder.
    [string]$Rom = '',
    # Expected SHA-256 of the ROM zip. Default: SHA256SUMS (or <zip>.sha256) next to the zip.
    [string]$RomSha256 = '',
    # Android 16 TWRP image. Default: twrp\twrp-cityman-a16.img.
    [string]$Twrp = '',
    # EFIESP folder of the phone in mass storage mode (Full mode). Default: folder dialog.
    [string]$EfiEsp = '',
    # Folder with the official Android4Lumia950 installer (Full mode). Default: 'official'.
    [string]$OfficialDir = '',
    [string]$AdbPath = '',
    [string]$FastbootPath = '',
    # Full mode, resume after an interruption, with the phone in LK:
    #   Partition = EFIESP already prepared (phone boots into LK)
    #   Modem     = Android partitions already created
    [ValidateSet('', 'Partition', 'Modem')]
    [string]$Resume = '',
    # Do not ask for administrator rights in Full mode.
    [switch]$NoElevate,
    # Wait for Enter before closing (used by the elevated window).
    [switch]$PauseAtEnd
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Root = $PSScriptRoot
$OfficialCommit = '5c215fda5daf73866a93dfad3b6473253552dfe5'
$OfficialZipUrl = "https://github.com/Android4Lumia950/installer/archive/$OfficialCommit.zip"
$OfficialRepoUrl = 'https://github.com/Android4Lumia950/installer'
$TwrpReleaseUrl = 'https://github.com/giannoccarol/android_device_msft_cityman/releases'
$PlatformToolsUrl = 'https://developer.android.com/tools/releases/platform-tools'
$UsbDriverUrl = 'https://developer.android.com/studio/run/win-usb'
$RemoteHelper = '/tmp/cityman-a16-helper.sh'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$Provisioned = @('APDP', 'DBI', 'DDR', 'DPO', 'DPP', 'LIMITS', 'MODEM_FS1', 'MODEM_FS2',
    'MODEM_FSC', 'MODEM_FSG', 'MSADP', 'SEC', 'SSD', 'UEFI_BS_NV', 'UEFI_RT_NV')
$OfficialFiles = @('DATA/BCD', 'DATA/bootshim.efi', 'DATA/Stage2.efi', 'DATA/developermenu.efi',
    'DATA/emmc_appsboot.mbn', 'DATA/modem.img', 'DATA/twrp.img',
    'ui/boot.ums.connected.bmpx', 'ui/boot.ums.disconnected.bmpx', 'ui/boot.ums.waiting.bmpx')
# Upstream partition.sh finds the partition it just created with a substring grep:
# creating "boot" also matches "aboot", and mke2fs then formats aboot (where LK
# lives). The fix matches the exact name at the end of the line.
$PartitionFixOld = 'grep "${androidPartitions[i]}" | awk ''{print $1}'')'
$PartitionFixNew = 'grep -E "[[:space:]]${androidPartitions[i]}\$" | awk ''{print $1}'')'

$script:Adb = $null
$script:Fastboot = $null
$script:Pinned = $null
$script:OfficialRoot = $null
$script:WorkDir = $null
$script:BackupDir = $null
$script:TwrpPath = $null
$script:RomPath = $null
$script:BootSha = $null
$script:BootSize = 0
$script:LogFile = $null

# ---------------------------------------------------------------------------
# Output and questions
# ---------------------------------------------------------------------------

function Write-Step([string]$Text) {
    Write-Host ''
    Write-Host "==> $Text" -ForegroundColor Cyan
}
function Write-Info([string]$Text) { Write-Host "    $Text" }
function Write-Ok([string]$Text) { Write-Host "    OK: $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "    WARNING: $Text" -ForegroundColor Yellow }

# Stops the installer with a message for the user (caught at the bottom).
function Stop-Install([string]$Text) { throw "INSTALLER: $Text" }

function Read-Answer([string]$Prompt) {
    $a = Read-Host $Prompt
    if ($null -eq $a) { return '' }
    return $a.Trim()
}
function Confirm-Word([string]$Text, [string]$Word, [string]$StopText) {
    Write-Host ''
    Write-Host "    $Text" -ForegroundColor Yellow
    $a = Read-Answer "    Type $Word to continue (anything else stops)"
    if ($a -cne $Word) { Stop-Install $StopText }
}
function Confirm-YesNo([string]$Prompt) {
    $a = Read-Answer "    $Prompt [y/N]"
    return ($a -match '^(y|yes)$')
}
function Wait-Enter([string]$Text) {
    [void](Read-Host "    $Text Press Enter when ready")
}

# ---------------------------------------------------------------------------
# Files and hashes
# ---------------------------------------------------------------------------

function Join-Parts([string[]]$Parts) { return [System.IO.Path]::Combine($Parts) }

function Get-FullPath([string]$Path) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-Sha256Bytes([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}
function Get-Sha256Stream([System.IO.Stream]$Stream) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (($sha.ComputeHash($Stream) | ForEach-Object { $_.ToString('x2') }) -join '') }
    finally { $sha.Dispose() }
}
function Get-Sha256File([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Text file with LF line endings, as the phone's shell needs it.
function Get-LfText([string]$Path) { return ([System.IO.File]::ReadAllText($Path) -replace "`r", '') }
function Get-Utf8Bytes([string]$Text) { return (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text) }
function Save-LfText([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllBytes($Path, (Get-Utf8Bytes $Text))
}

function Read-Pinned {
    $file = Join-Parts @($Root, 'checksums.sha256')
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        Stop-Install "checksums.sha256 is missing next to installer.ps1. Download the installer again."
    }
    $map = @{}
    foreach ($line in Get-Content -LiteralPath $file) {
        $l = $line.Trim()
        if ($l -eq '' -or $l.StartsWith('#')) { continue }
        if ($l -notmatch '^([0-9a-fA-F]{64})\s+\*?(.+)$') { Stop-Install "Bad line in checksums.sha256: $l" }
        $key = $Matches[2].Trim()
        if (-not $map.ContainsKey($key)) { $map[$key] = @() }
        $map[$key] += $Matches[1].ToLowerInvariant()
    }
    return $map
}
function Assert-Pinned([string]$Key, [string]$Hash, [string]$What, [string]$Hint) {
    if (-not $script:Pinned.ContainsKey($Key)) { Stop-Install "checksums.sha256 has no entry for $Key." }
    if (@($script:Pinned[$Key]) -notcontains $Hash) {
        Stop-Install "$What has SHA-256 $Hash, which is not the expected file. $Hint"
    }
}

# ---------------------------------------------------------------------------
# Running adb and fastboot
# ---------------------------------------------------------------------------

# Quotes arguments for a Windows command line (CommandLineToArgvW rules).
function ConvertTo-ArgString([string[]]$Arguments) {
    $quoted = foreach ($a in $Arguments) {
        if ($a -eq '') { '""' }
        elseif ($a -notmatch '[\s"]') { $a }
        else {
            $s = $a -replace '(\\*)"', '$1$1\"'
            $s = $s -replace '(\\+)$', '$1$1'
            '"' + $s + '"'
        }
    }
    return ($quoted -join ' ')
}

function New-ToolProcess([string]$Exe, [string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = ConvertTo-ArgString $Arguments
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    Write-Verbose ("run: {0} {1}" -f $Exe, $psi.Arguments)
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    return $p
}

# Runs a tool with captured output and a timeout.
function Invoke-Tool([string]$Exe, [string[]]$Arguments, [int]$TimeoutSec = 60) {
    $p = New-ToolProcess $Exe $Arguments
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $p.Kill() } catch { }
        [void]$p.WaitForExit(5000)
    }
    $out = ''
    $err = ''
    if ($outTask.Wait(5000)) { $out = $outTask.Result }
    if ($errTask.Wait(5000)) { $err = $errTask.Result }
    $code = -1
    if (-not $timedOut) { $code = $p.ExitCode }
    $p.Dispose()
    return [pscustomobject]@{ ExitCode = $code; Out = $out; Err = $err; TimedOut = $timedOut }
}

# Runs a tool on the console (the user sees its output and progress). Waits for
# the process only, not for children such as an adb server it may start.
function Invoke-Console([string]$Exe, [string[]]$Arguments) {
    $argString = ConvertTo-ArgString $Arguments
    Write-Verbose ("run: {0} {1}" -f $Exe, $argString)
    $p = Start-Process -FilePath $Exe -ArgumentList $argString -NoNewWindow -PassThru
    $null = $p.Handle  # keeps ExitCode readable after exit (Windows PowerShell 5.1)
    $p.WaitForExit()
    return $p.ExitCode
}

function Get-Lines([string]$Text) {
    return @(($Text -replace "`r", '') -split "`n" | Where-Object { $_.Trim() -ne '' })
}

function Resolve-Tool([string]$Name, [string]$Override, [string]$FallbackDir) {
    if ($Override) {
        if (-not (Test-Path -LiteralPath $Override -PathType Leaf)) { Stop-Install "$Name not found at $Override." }
        return (Get-FullPath $Override)
    }
    $cmd = @(Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) { return $cmd[0].Path }
    if ($FallbackDir) {
        $p = Join-Parts @($FallbackDir, 'bin', "$Name.exe")
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            Write-Warn "$Name is not on PATH: using the copy from the official installer ($p)."
            return $p
        }
    }
    Stop-Install "$Name was not found. Install the Android SDK Platform Tools and add their folder to PATH: $PlatformToolsUrl"
}

function Initialize-Tools([string]$FallbackDir) {
    $script:Adb = Resolve-Tool 'adb' $AdbPath $FallbackDir
    $script:Fastboot = Resolve-Tool 'fastboot' $FastbootPath $FallbackDir
    $v = Invoke-Tool $script:Adb @('version') 30
    $first = @(Get-Lines $v.Out)
    if ($v.ExitCode -ne 0 -or $first.Count -eq 0) { Stop-Install "adb does not run ($($script:Adb)): $($v.Err.Trim())" }
    Write-Info "adb: $($script:Adb) ($($first[0]))"
    Write-Info "fastboot: $($script:Fastboot)"
    # Start the adb server outside our redirected pipes, so it does not hold them open.
    $p = Start-Process -FilePath $script:Adb -ArgumentList 'start-server' -NoNewWindow -PassThru
    [void]$p.WaitForExit(60000)
}

function Get-AdbDevices {
    $r = Invoke-Tool $script:Adb @('devices') 30
    $list = @()
    foreach ($line in Get-Lines $r.Out) {
        if ($line -match '^(\S+)\s+(device|recovery|sideload|unauthorized|offline|bootloader|rescue|no permissions.*)\s*$') {
            $list += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    return $list
}
function Get-FastbootDevices {
    $r = Invoke-Tool $script:Fastboot @('devices') 30
    $list = @()
    foreach ($line in Get-Lines $r.Out) {
        if ($line -match '^(\S+)\s+fastboot\s*$') { $list += $Matches[1] }
    }
    return $list
}

function Wait-AdbState([string[]]$States, [int]$TimeoutSec, [string]$Hint) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $nextHint = (Get-Date).AddSeconds(45)
    $authHint = $false
    while ((Get-Date) -lt $deadline) {
        $d = @(Get-AdbDevices)
        if ($d.Count -gt 1) {
            Stop-Install 'More than one Android device is connected to adb. Disconnect the others and run the installer again.'
        }
        if ($d.Count -eq 1) {
            if ($States -contains $d[0].State) { return $d[0].State }
            if ($d[0].State -eq 'unauthorized' -and -not $authHint) {
                Write-Info 'Allow USB debugging on the phone screen (tick "Always allow").'
                $authHint = $true
            }
        }
        if ($Hint -and (Get-Date) -gt $nextHint) {
            Write-Info $Hint
            $nextHint = (Get-Date).AddSeconds(45)
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Wait-Fastboot([int]$TimeoutSec, [string]$Hint) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $nextHint = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        $d = @(Get-FastbootDevices)
        if ($d.Count -gt 1) {
            Stop-Install 'More than one device is in fastboot mode. Disconnect the others and run the installer again.'
        }
        if ($d.Count -eq 1) { return $true }
        if ($Hint -and (Get-Date) -gt $nextHint) {
            Write-Info $Hint
            $nextHint = (Get-Date).AddSeconds(45)
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Invoke-Fastboot([string[]]$Arguments, [int]$TimeoutSec) {
    Write-Info ('fastboot ' + ($Arguments -join ' '))
    $r = Invoke-Tool $script:Fastboot $Arguments $TimeoutSec
    foreach ($l in (Get-Lines ($r.Out + "`n" + $r.Err))) { Write-Info "  $l" }
    if ($r.TimedOut) { Stop-Install "fastboot $($Arguments[0]) did not finish within $TimeoutSec s." }
    if ($r.ExitCode -ne 0) { Stop-Install "fastboot $($Arguments[0]) failed (exit code $($r.ExitCode))." }
}

function Send-File([string]$Local, [string]$Remote) {
    $r = Invoke-Tool $script:Adb @('push', $Local, $Remote) 300
    if ($r.TimedOut -or $r.ExitCode -ne 0) {
        Stop-Install "Could not copy $Local to the phone: $(($r.Out + ' ' + $r.Err).Trim())"
    }
}

# Pushes the helper script (LF line endings) to TWRP's /tmp.
function Send-Helper {
    $src = Join-Parts @($Root, 'device', 'cityman-a16-helper.sh')
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Stop-Install "Missing file: $src" }
    $dst = Join-Parts @($script:WorkDir, 'cityman-a16-helper.sh')
    Save-LfText $dst (Get-LfText $src)
    Send-File $dst $RemoteHelper
}

# Runs one helper command in TWRP. Returns { Ok; Message; Lines }.
function Invoke-Helper([string]$Arguments, [int]$TimeoutSec = 120, [switch]$AllowFail, [switch]$Quiet) {
    $r = Invoke-Tool $script:Adb @('shell', "bash $RemoteHelper $Arguments") $TimeoutSec
    if ($r.TimedOut) { Stop-Install "The phone did not answer within $TimeoutSec s ($Arguments)." }
    $lines = @(Get-Lines $r.Out)
    $results = @($lines | Where-Object { $_ -match '^RESULT=' })
    $other = @($lines | Where-Object { $_ -notmatch '^RESULT=' })
    if (-not $Quiet) { foreach ($l in $other) { Write-Info "  $l" } }
    if ($results.Count -eq 0) {
        Stop-Install "No answer from the phone for '$Arguments'. adb said: $(($r.Out + ' ' + $r.Err).Trim())"
    }
    $last = $results[$results.Count - 1]
    if ($last -match '^RESULT=OK(:(.*))?$') {
        return [pscustomobject]@{ Ok = $true; Message = ("" + $Matches[2]).Trim(); Lines = $other }
    }
    $msg = ($last -replace '^RESULT=FAIL:?', '').Trim()
    if ($AllowFail) { return [pscustomobject]@{ Ok = $false; Message = $msg; Lines = $other } }
    Stop-Install "On the phone: $msg."
}

# Waits for TWRP: adb in recovery state, a working shell, and (with -NeedOrs)
# the 'twrp' command interface. TWRP is not ready right after boot.
function Wait-Twrp([switch]$NeedOrs) {
    Write-Info 'Waiting for TWRP (up to 4 minutes)...'
    $state = Wait-AdbState @('recovery') 240 'Still waiting for TWRP. If the phone shows TWRP but nothing happens here, check the Android USB driver in Device Manager.'
    if (-not $state) {
        Stop-Install "TWRP did not appear on adb within 4 minutes. Check the cable and the Android USB driver ($UsbDriverUrl), then run the installer again."
    }
    $deadline = (Get-Date).AddSeconds(120)
    $shellOk = $false
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Tool $script:Adb @('shell', 'echo cityman-shell-ok') 15
        if (-not $r.TimedOut -and $r.Out -match 'cityman-shell-ok') { $shellOk = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $shellOk) { Stop-Install 'TWRP is on adb but its shell does not answer. Reboot the phone to the bootloader and run the installer again.' }
    Send-Helper
    if ($NeedOrs) {
        $deadline = (Get-Date).AddSeconds(180)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            # Blocks while the TWRP interface is not up; returns once TWRP reads commands.
            $r = Invoke-Tool $script:Adb @('shell', 'twrp print cityman-twrp-ready') 20
            if (-not $r.TimedOut -and $r.ExitCode -eq 0 -and ($r.Out + $r.Err) -notmatch 'does not appear to be running') {
                $ready = $true
                break
            }
            if ($r.TimedOut) { [void](Invoke-Tool $script:Adb @('shell', "pkill -f 'twrp [p]rint'") 15) }
            Start-Sleep -Seconds 5
        }
        if (-not $ready) { Stop-Install 'The TWRP command interface did not start within 3 minutes. Reboot the phone to the bootloader and run the installer again.' }
    }
    Write-Ok 'TWRP is ready.'
}

# Runs a TWRP command ('twrp format data', 'twrp wipe cache', ...).
function Invoke-Twrp([string]$Command, [int]$TimeoutSec) {
    Write-Info "twrp $Command"
    $r = Invoke-Tool $script:Adb @('shell', "twrp $Command") $TimeoutSec
    $text = ($r.Out + "`n" + $r.Err) -replace "`r", ''
    foreach ($l in (Get-Lines $text)) { Write-Info "  $l" }
    if ($r.TimedOut) { Stop-Install "TWRP did not finish '$Command' within $TimeoutSec s." }
    if ($text -match '(?im)^.*(unable to (wipe|format)|failed to (wipe|format)|format_data_err|wipe_err|does not appear to be running).*$') {
        Stop-Install "TWRP reported an error during '$Command': $($Matches[0].Trim())"
    }
    if ($text -notmatch 'Done processing') { Write-Warn "TWRP did not confirm '$Command'; the result is checked below." }
}

# ---------------------------------------------------------------------------
# Inputs: ROM, TWRP, official installer
# ---------------------------------------------------------------------------

function Find-RomChecksum([string]$Path) {
    $dir = Split-Path -Parent $Path
    $name = Split-Path -Leaf $Path
    $candidates = @("$Path.sha256", "$Path.sha256sum", (Join-Parts @($dir, 'SHA256SUMS')),
        (Join-Parts @($dir, 'SHA256SUMS.txt')), (Join-Parts @($dir, 'sha256sums.txt')))
    foreach ($c in $candidates) {
        if (-not (Test-Path -LiteralPath $c -PathType Leaf)) { continue }
        $perFile = $c.EndsWith('.sha256') -or $c.EndsWith('.sha256sum')
        foreach ($line in Get-Content -LiteralPath $c) {
            if ($line -notmatch '^\s*([0-9a-fA-F]{64})(\s+\*?(.+?))?\s*$') { continue }
            $hash = $Matches[1].ToLowerInvariant()
            $file = '' + $Matches[3]
            if ($file -ne '') { $file = ($file -split '[\\/]')[-1] }
            if ($file -ieq $name -or ($perFile -and $file -eq '')) {
                return @($hash, $c)
            }
        }
    }
    Stop-Install "No SHA-256 found for $name. Put the SHA256SUMS file from the download page next to the zip, or pass -RomSha256 <hash>."
}

function Resolve-Rom {
    Write-Step 'Checking the ROM'
    $path = $Rom
    if (-not $path) {
        $dir = Join-Parts @($Root, 'rom')
        $zips = @(Get-ChildItem -LiteralPath $dir -Filter 'lineage-23.2-*-cityman.zip' -File -ErrorAction SilentlyContinue)
        if ($zips.Count -eq 0) {
            Stop-Install "No ROM found. Put lineage-23.2-...-UNOFFICIAL-cityman.zip and its SHA256SUMS in $dir, or pass -Rom <path>."
        }
        if ($zips.Count -gt 1) {
            Stop-Install "More than one ROM zip in $dir ($(($zips | ForEach-Object { $_.Name }) -join ', ')). Keep one, or pass -Rom <path>."
        }
        $path = $zips[0].FullName
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Install "ROM not found: $path" }
    $path = Get-FullPath $path
    $name = Split-Path -Leaf $path

    if ($RomSha256) {
        $expected = $RomSha256.Trim().ToLowerInvariant()
        $source = '-RomSha256'
    } else {
        $found = Find-RomChecksum $path
        $expected = $found[0]
        $source = $found[1]
    }
    if ($expected -notmatch '^[0-9a-f]{64}$') { Stop-Install "The expected SHA-256 '$expected' is not a valid hash." }
    Write-Info "$name"
    Write-Info 'Computing SHA-256 (about a minute)...'
    $actual = Get-Sha256File $path
    if ($actual -ne $expected) {
        Stop-Install "The ROM zip does not match its checksum (zip $actual, expected $expected from $source). The download is damaged or it is another file: download it again."
    }
    Write-Ok "SHA-256 matches ($source)."

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($path) }
    catch { Stop-Install "$name is not a valid zip file: $($_.Exception.Message)" }
    try {
        $boot = $zip.GetEntry('boot.img')
        $binary = $zip.GetEntry('META-INF/com/google/android/update-binary')
        if ($null -eq $boot -or $null -eq $binary) { Stop-Install "$name is not a flashable ROM zip (no boot.img or update-binary)." }
        $meta = $zip.GetEntry('META-INF/com/android/metadata')
        if ($null -ne $meta) {
            $reader = New-Object System.IO.StreamReader($meta.Open())
            try { $metaText = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $devices = ''
            $sdk = ''
            foreach ($l in Get-Lines $metaText) {
                if ($l -match '^pre-device=(.*)$') { $devices = $Matches[1].Trim() }
                if ($l -match '^post-sdk-level=(\d+)') { $sdk = $Matches[1] }
            }
            if ($devices -and (($devices -split ',') -notcontains 'cityman')) {
                Stop-Install "$name is for '$devices', not for the Lumia 950 XL (cityman)."
            }
            if ($sdk -and [int]$sdk -lt 36) {
                Stop-Install "$name is an Android SDK $sdk build. This installer and its TWRP are for LineageOS 23.2 (Android 16, SDK 36)."
            }
        } else {
            Write-Warn 'The zip has no OTA metadata; device and Android version not checked.'
        }
        $script:BootSize = [long]$boot.Length
        $s = $boot.Open()
        try { $script:BootSha = Get-Sha256Stream $s } finally { $s.Dispose() }
    } finally {
        $zip.Dispose()
    }
    $script:RomPath = $path
    Write-Ok "Flashable zip for cityman; boot.img $($script:BootSize) bytes."
}

function Resolve-Twrp {
    Write-Step 'Checking the Android 16 TWRP'
    $path = $Twrp
    if (-not $path) { $path = Join-Parts @($Root, 'twrp', 'twrp-cityman-a16.img') }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Stop-Install "Android 16 TWRP not found at $path. Download twrp-cityman-a16.img from $TwrpReleaseUrl into the 'twrp' folder, or pass -Twrp <path>."
    }
    $path = Get-FullPath $path
    Assert-Pinned 'twrp-cityman-a16.img' (Get-Sha256File $path) "The TWRP image $path" 'Download twrp-cityman-a16.img again from the release page (or update checksums.sha256 if you use a newer TWRP release).'
    $script:TwrpPath = $path
    Write-Ok "$path"
}

function Get-OfficialFile([string]$Rel) {
    return (Join-Parts (@($script:OfficialRoot) + $Rel.Split('/')))
}

function Get-OfficialInstaller([string]$Dest) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $dl = Join-Parts @($Root, 'downloads')
    New-Item -ItemType Directory -Force -Path $dl | Out-Null
    $zip = Join-Parts @($dl, "installer-$OfficialCommit.zip")
    Write-Info "Downloading $OfficialZipUrl ..."
    try { Invoke-WebRequest -Uri $OfficialZipUrl -OutFile $zip -UseBasicParsing }
    catch { Stop-Install "Download failed: $($_.Exception.Message)" }
    $tmp = Join-Parts @($dl, "installer-$OfficialCommit")
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
    Write-Info 'Extracting...'
    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
    $inner = @(Get-ChildItem -LiteralPath $tmp -Directory)
    if ($inner.Count -ne 1) { Stop-Install "Unexpected content in $zip." }
    Move-Item -LiteralPath $inner[0].FullName -Destination $Dest
    Remove-Item -LiteralPath $tmp -Recurse -Force
}

function Resolve-Official {
    Write-Step 'Checking the official Android4Lumia950 installer files'
    $dir = $OfficialDir
    if (-not $dir) { $dir = Join-Parts @($Root, 'official') }
    $dir = Get-FullPath $dir
    if (-not (Test-Path -LiteralPath (Join-Parts @($dir, 'DATA', 'emmc_appsboot.mbn')) -PathType Leaf)) {
        if ($OfficialDir) { Stop-Install "No official installer files (DATA\emmc_appsboot.mbn) in $dir." }
        if (Test-Path -LiteralPath $dir) { Stop-Install "$dir exists but does not contain the official installer. Remove it and run the installer again." }
        Write-Info "The official installer (branch cityman-temp, commit $($OfficialCommit.Substring(0, 7))) is not in $dir."
        if (-not (Confirm-YesNo 'Download it now from GitHub (about 110 MB)?')) {
            Stop-Install "The official installer is needed for the full install. Download $OfficialZipUrl and extract it to $dir (or pass -OfficialDir)."
        }
        Get-OfficialInstaller $dir
    }
    $script:OfficialRoot = $dir
    $mismatch = "It differs from the official installer at commit $($OfficialCommit.Substring(0, 7)), the version this installer was checked with. Delete the folder $dir and let the installer download that commit."
    foreach ($rel in $OfficialFiles) {
        $p = Get-OfficialFile $rel
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Stop-Install "Missing official file $p." }
        Assert-Pinned "official/$rel" (Get-Sha256File $p) "Official file $rel" $mismatch
    }
    $part = Get-LfText (Get-OfficialFile 'partition.sh')
    Assert-Pinned 'official/partition.sh' (Get-Sha256Bytes (Get-Utf8Bytes $part)) 'Official file partition.sh' $mismatch
    $prov = Get-LfText (Get-OfficialFile 'provision.sh')
    Assert-Pinned 'official/provision.sh' (Get-Sha256Bytes (Get-Utf8Bytes $prov)) 'Official file provision.sh' $mismatch

    $count = ([regex]::Matches($part, [regex]::Escape($PartitionFixOld))).Count
    if ($count -ne 1) { Stop-Install "partition.sh: the line to fix was found $count times instead of once." }
    $part = $part.Replace($PartitionFixOld, $PartitionFixNew)
    Assert-Pinned 'official/partition.sh+exact-name-fix' (Get-Sha256Bytes (Get-Utf8Bytes $part)) 'Fixed partition.sh' 'Internal error: the fix did not give the expected script.'
    Save-LfText (Join-Parts @($script:WorkDir, 'partition.sh')) $part
    Save-LfText (Join-Parts @($script:WorkDir, 'provision.sh')) $prov
    Write-Ok "All files match commit $($OfficialCommit.Substring(0, 7)) ($dir)."
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

function Test-IsWindows { return ($env:OS -eq 'Windows_NT') }
function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Select-Mode {
    Write-Host ''
    Write-Host '  1) Full install   - phone still on Windows, unlocked with WPInternals.'
    Write-Host '                      Erases Windows. Installs LK, creates the Android partitions.'
    Write-Host '  2) Clean install  - phone already has LK and Android partitions'
    Write-Host '                      (for example LineageOS 18.1). Erases all data.'
    Write-Host '  3) Update         - phone already runs this LineageOS 23.2 port. Keeps data.'
    Write-Host ''
    switch (Read-Answer '  Choose 1, 2 or 3') {
        '1' { return 'Full' }
        '2' { return 'Clean' }
        '3' { return 'Update' }
        default { Stop-Install 'No mode chosen.' }
    }
}

function Select-EfiEsp {
    if ($EfiEsp) { return $EfiEsp }
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.BrowseForFolder(0, 'Select the EFIESP drive of the phone (mass storage mode).', 0, 0)
        if ($null -ne $folder) { return $folder.Self.Path }
    } catch { }
    return (Read-Answer '    Path of the phone''s EFIESP drive (for example E:\)')
}

function Install-Efiesp {
    Write-Step 'Developer Menu, boot shim and LK on EFIESP (official installer step)'
    Write-Info 'In WPInternals, switch the phone to mass storage mode. Windows shows the phone''s'
    Write-Info 'partitions as drives. A full backup with Win32DiskImager is recommended now.'
    Wait-Enter 'Phone in mass storage mode?'
    $efi = Select-EfiEsp
    if (-not $efi) { Stop-Install 'No EFIESP folder selected.' }
    if (-not (Test-Path -LiteralPath $efi -PathType Container)) { Stop-Install "Folder not found: $efi" }
    $efi = Get-FullPath $efi
    $bcd = Join-Parts @($efi, 'EFI', 'Microsoft', 'BOOT', 'BCD')
    $bootDir = Join-Parts @($efi, 'Windows', 'System32', 'BOOT')
    if (-not (Test-Path -LiteralPath $bcd -PathType Leaf)) {
        Stop-Install "BCD file not found at $bcd. Select the phone's EFIESP drive (it may also be mounted inside MainOS)."
    }
    if (-not (Test-Path -LiteralPath $bootDir -PathType Container)) {
        Stop-Install "$bootDir not found. This does not look like the phone's EFIESP."
    }
    if (Test-IsWindows) {
        try {
            $rootPath = [System.IO.Path]::GetPathRoot($efi)
            if ($rootPath -match '^([A-Za-z]):\\$' -and $efi.TrimEnd('\') -eq $rootPath.TrimEnd('\')) {
                $label = (Get-Volume -DriveLetter $Matches[1]).FileSystemLabel
                if ($label -and $label -ne 'EFIESP') { Write-Warn "The drive label is '$label', not EFIESP." }
            }
        } catch { }
    }

    $copies = @(
        @{ Src = 'DATA/BCD'; Dst = $bcd },
        @{ Src = 'DATA/bootshim.efi'; Dst = (Join-Parts @($bootDir, 'bootshim.efi')) },
        @{ Src = 'DATA/Stage2.efi'; Dst = (Join-Parts @($efi, 'Stage2.efi')) },
        @{ Src = 'DATA/developermenu.efi'; Dst = (Join-Parts @($bootDir, 'developermenu.efi')) },
        @{ Src = 'ui/boot.ums.connected.bmpx'; Dst = (Join-Parts @($bootDir, 'ui', 'boot.ums.connected.bmpx')) },
        @{ Src = 'ui/boot.ums.disconnected.bmpx'; Dst = (Join-Parts @($bootDir, 'ui', 'boot.ums.disconnected.bmpx')) },
        @{ Src = 'ui/boot.ums.waiting.bmpx'; Dst = (Join-Parts @($bootDir, 'ui', 'boot.ums.waiting.bmpx')) },
        @{ Src = 'DATA/emmc_appsboot.mbn'; Dst = (Join-Parts @($efi, 'emmc_appsboot.mbn')) }
    )
    Confirm-Word "EFIESP: $efi. The BCD is replaced and the Developer Menu, boot shim, Stage2 and LK are copied there (the files they replace are backed up first)." 'YES' 'Stopped before changing EFIESP. Nothing was written.'

    $bk = Join-Parts @($script:BackupDir, 'EFIESP')
    foreach ($c in $copies) {
        if (Test-Path -LiteralPath $c.Dst -PathType Leaf) {
            $rel = $c.Dst.Substring($efi.Length).TrimStart('\', '/')
            $target = Join-Parts @($bk, $rel)
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $c.Dst -Destination $target -Force
        }
    }
    Write-Info "Original EFIESP files saved in $bk"
    New-Item -ItemType Directory -Force -Path (Join-Parts @($bootDir, 'ui')) | Out-Null
    foreach ($c in $copies) {
        $src = Get-OfficialFile $c.Src
        Copy-Item -LiteralPath $src -Destination $c.Dst -Force
        if ((Get-Sha256File $c.Dst) -ne (Get-Sha256File $src)) {
            Stop-Install "Copy to $($c.Dst) failed (the file on EFIESP differs). Originals are in $bk."
        }
    }
    Write-Ok 'EFIESP prepared.'

    Write-Step 'Reboot the phone into LK'
    Write-Info '1. Eject the phone''s drives in Windows (Safely Remove Hardware).'
    Write-Info '2. Hold the power key until the phone restarts (about 10 seconds).'
    Write-Info '3. The phone prints some text, then the screen goes black: that is LK (fastboot).'
    Write-Info "   If Device Manager shows an unknown 'Android' device, install the Android USB driver: $UsbDriverUrl"
    if (-not (Wait-Fastboot 900 'Waiting for the phone in fastboot (LK)...')) {
        Stop-Install 'The phone did not appear in fastboot within 15 minutes. EFIESP is prepared: once the phone is in LK, run: installer.bat -Mode Full -Resume Partition'
    }
    Write-Ok 'Phone in LK (fastboot).'
}

function Backup-Provisioned {
    Write-Info 'Backing up the provisioning partitions (IMEI, MAC addresses, calibration)...'
    $dir = Join-Parts @($script:BackupDir, 'provisioned')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $r = Invoke-Helper 'backup /tmp/cityman-backup' 600 -Quiet
    $sums = @{}
    foreach ($l in $r.Lines) {
        if ($l -match '^SHA ([0-9a-f]{64}) (\S+)$') { $sums[$Matches[2]] = $Matches[1] }
    }
    $sumLines = @()
    foreach ($p in $Provisioned) {
        $name = "$p.bin"
        if (-not $sums.ContainsKey($name)) { Stop-Install "The phone did not back up $p. Nothing was erased." }
        $local = Join-Parts @($dir, $name)
        $pull = Invoke-Tool $script:Adb @('pull', "/tmp/cityman-backup/$name", $local) 300
        if ($pull.TimedOut -or $pull.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $local)) {
            Stop-Install "Could not copy the backup of $p to the PC: $(($pull.Out + ' ' + $pull.Err).Trim()). Nothing was erased."
        }
        if ((Get-Sha256File $local) -ne $sums[$name]) { Stop-Install "The PC copy of $p differs from the phone. Nothing was erased." }
        $sumLines += "$($sums[$name])  $name"
    }
    Set-Content -LiteralPath (Join-Parts @($dir, 'SHA256SUMS')) -Value $sumLines -Encoding Ascii
    Write-Ok "15 partitions saved and verified in $dir"
}

function Save-PartitionTable([string]$Name) {
    $r = Invoke-Tool $script:Adb @('shell', 'parted /dev/block/mmcblk0 unit s print') 60
    Set-Content -LiteralPath (Join-Parts @($script:BackupDir, $Name)) -Value ($r.Out -replace "`r", '') -Encoding Ascii
}

function Invoke-Partitioning {
    Write-Step 'Android partitions (official installer step, in the official TWRP)'
    Invoke-Fastboot @('boot', (Get-OfficialFile 'DATA/twrp.img')) 180
    Wait-Twrp
    $found = (Invoke-Helper 'check-windows').Message
    Save-PartitionTable 'partition-table-before.txt'
    Backup-Provisioned

    Confirm-Word "These Windows partitions will be DELETED: $found. Windows will no longer start. The Android partitions are created in their place." 'ERASE' "Stopped before partitioning. Nothing was erased. Backups: $($script:BackupDir)"
    Send-File (Join-Parts @($script:WorkDir, 'partition.sh')) '/tmp/partition.sh'
    Write-Info 'Running partition.sh (official, with the exact-name fix). This takes a few minutes.'
    # partition.sh asks "... not found, proceed?" for each missing Windows partition;
    # the list was confirmed above, so the answers are 'y'.
    [void](Invoke-Console $script:Adb @('shell', 'cd / && yes y | bash /tmp/partition.sh'))

    $lkSha = Get-Sha256File (Get-OfficialFile 'DATA/emmc_appsboot.mbn')
    $chk = Invoke-Helper "check-android $lkSha" 120 -AllowFail
    if (-not $chk.Ok) {
        if ($chk.Message -notmatch '^LK:') {
            Stop-Install "Partitioning did not complete: $($chk.Message). Do not reboot the phone. Backups: $($script:BackupDir)"
        }
        Write-Warn 'LK is not in the aboot partition: copying it again.'
        Send-File (Get-OfficialFile 'DATA/emmc_appsboot.mbn') '/tmp/emmc_appsboot.mbn'
        $fix = Invoke-Helper "put-lk /tmp/emmc_appsboot.mbn $lkSha" 120 -AllowFail
        if (-not $fix.Ok) { Stop-Install "LK could not be written to aboot: $($fix.Message). Do not reboot the phone; ask for help. Backups: $($script:BackupDir)" }
    }
    Save-PartitionTable 'partition-table-after.txt'
    Write-Ok 'Android partitions created, LK in aboot.'
}

function Invoke-RecoveryAndModem {
    Write-Step 'Recovery and modem images (official installer step)'
    Write-Info 'Rebooting to the bootloader...'
    [void](Invoke-Tool $script:Adb @('reboot', 'bootloader') 30)
    if (-not (Wait-Fastboot 300 'Waiting for LK (fastboot). If the phone stays on a black screen without fastboot, hold the power key to restart it.')) {
        Stop-Install 'The phone did not come back in fastboot. Restart it (hold power); once it is in LK, run: installer.bat -Mode Full -Resume Modem'
    }
    # The official installer flashes its TWRP here; the Android 16 one is flashed
    # instead (LK on this phone does not start the recovery partition anyway).
    Invoke-Fastboot @('flash', 'recovery', $script:TwrpPath) 180
    Invoke-Fastboot @('flash', 'modem', (Get-OfficialFile 'DATA/modem.img')) 600
    Write-Ok 'recovery and modem written.'
}

function Start-A16Twrp {
    Write-Step 'Booting the Android 16 TWRP (fastboot boot, nothing is written)'
    Invoke-Fastboot @('boot', $script:TwrpPath) 180
    Wait-Twrp -NeedOrs
}

function Invoke-Provisioning {
    Write-Step 'Provisioning (official installer step): MAC addresses and modem data'
    [void](Invoke-Helper 'pre-provision')
    Send-File (Join-Parts @($script:WorkDir, 'provision.sh')) '/tmp/provision.sh'
    $r = Invoke-Tool $script:Adb @('shell', 'cd / && bash /tmp/provision.sh') 300
    foreach ($l in (Get-Lines ($r.Out + "`n" + $r.Err))) { Write-Info "  $l" }
    if ($r.TimedOut) { Stop-Install 'provision.sh did not finish within 5 minutes.' }
    $chk = Invoke-Helper 'check-provision' 180 -AllowFail
    if ($chk.Ok) {
        Write-Ok 'Wi-Fi/Bluetooth MAC addresses and modem data copied.'
    } else {
        Write-Warn "Provisioning check failed: $($chk.Message)"
        Write-Warn "The originals are in $($script:BackupDir)\provisioned. Without them Wi-Fi/Bluetooth may use random MAC addresses or the modem may lack its data."
        Confirm-Word 'Install the ROM anyway?' 'CONTINUE' 'Stopped after provisioning. The phone is partitioned: to provision again run installer.bat -Mode Full -Resume Modem (or Clean mode to install the ROM without provisioning).'
    }
}

function Invoke-Wipe {
    Write-Step 'Format data, wipe cache and Dalvik'
    Invoke-Twrp 'format data' 900
    Invoke-Twrp 'wipe cache' 300
    Invoke-Twrp 'wipe dalvik' 300
    $r = Invoke-Helper 'data-check'
    if ($r.Message -eq 'not-mounted') { Write-Warn '/data could not be mounted to check the format (normal right after a format on some TWRP builds).' }
    Write-Ok 'Data formatted, cache and Dalvik wiped.'
}

function Enter-SideloadMode {
    for ($t = 1; $t -le 6; $t++) {
        if ($t -gt 1) {
            Write-Info "TWRP is not in sideload mode yet, retrying ($t/6)..."
            Start-Sleep -Seconds 10
        }
        $p = New-ToolProcess $script:Adb @('shell', 'twrp sideload')
        [void]$p.StandardOutput.ReadToEndAsync()
        [void]$p.StandardError.ReadToEndAsync()
        $deadline = (Get-Date).AddSeconds(25)
        $entered = $false
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            $d = @(Get-AdbDevices)
            if ($d.Count -eq 1 -and $d[0].State -eq 'sideload') { $entered = $true; break }
        }
        try { if (-not $p.HasExited) { $p.Kill() } } catch { }
        $p.Dispose()
        if ($entered) { return }
    }
    Stop-Install "TWRP did not enter ADB sideload mode. On the phone choose Advanced > ADB Sideload and swipe, then run: adb sideload `"$($script:RomPath)`""
}

function Invoke-Sideload {
    Write-Step 'Installing the ROM (adb sideload)'
    Enter-SideloadMode
    Write-Info 'Sending the ROM. TWRP installs it while it arrives: about 4-5 minutes.'
    $rc = Invoke-Console $script:Adb @('sideload', $script:RomPath)
    if ($rc -ne 0) {
        Write-Info "adb sideload ended with code $rc. TWRP often reports a transfer error at the end even when the install worked: checking the TWRP log."
    }
    $state = Wait-AdbState @('recovery') 900 'Waiting for TWRP to finish the installation...'
    if (-not $state) { Stop-Install 'TWRP did not come back after the sideload. Look at the phone screen; run the installer again in Update or Clean mode.' }
    Wait-Twrp
    [void](Invoke-Helper 'sideload-result')
    Write-Ok 'TWRP reports a successful installation.'
}

function Test-BootPartition {
    Write-Step 'Checking the boot partition'
    $r = Invoke-Helper "boot-sha $($script:BootSize)" 180 -Quiet
    $h = $r.Message.ToLowerInvariant()
    if ($h -ne $script:BootSha) {
        Stop-Install "The boot partition does not match boot.img from the zip (phone $h, zip $($script:BootSha)). The installation is incomplete: run the installer again."
    }
    Write-Ok 'boot partition = boot.img of the zip.'
}

function Test-InstalledSystem {
    Write-Step 'Checking the installed system'
    $r = Invoke-Helper 'installed-version' 120 -AllowFail
    $sdk = ''
    $los = ''
    $dev = ''
    if ($r.Ok) {
        foreach ($kv in ($r.Message -split ' ')) {
            if ($kv -match '^sdk=(.*)$') { $sdk = $Matches[1] }
            if ($kv -match '^lineage=(.*)$') { $los = $Matches[1] }
            if ($kv -match '^device=(.*)$') { $dev = $Matches[1] }
        }
        Write-Info "Installed: LineageOS '$los', Android SDK '$sdk', device '$dev'."
        if ($sdk -match '^\d+$' -and [int]$sdk -ge 36 -and $los -like '23*' -and $dev -eq 'cityman') {
            Write-Ok 'The phone runs LineageOS 23.x for cityman: data is kept.'
            return
        }
        Write-Warn 'This is not the LineageOS 23.2 cityman build. Updating over another system without formatting data usually ends in a boot loop; use the Clean mode for that.'
    } else {
        Write-Warn "Could not read the installed system: $($r.Message)."
    }
    Confirm-Word 'Update anyway, keeping data?' 'UPDATE' 'Stopped before installing. Nothing was written; the phone is in TWRP (run the installer in Clean mode for a clean install).'
}

function Enter-Fastboot {
    Write-Step 'Looking for the phone'
    $fb = @(Get-FastbootDevices)
    if ($fb.Count -gt 1) { Stop-Install 'More than one device is in fastboot mode. Disconnect the others.' }
    if ($fb.Count -eq 1) { Write-Ok 'Phone in LK (fastboot).'; return }
    $d = @(Get-AdbDevices)
    if ($d.Count -gt 1) { Stop-Install 'More than one Android device is connected to adb. Disconnect the others.' }
    if ($d.Count -eq 1 -and $d[0].State -eq 'unauthorized') {
        Write-Info 'Allow USB debugging on the phone screen (tick "Always allow").'
        $st = Wait-AdbState @('device') 180 ''
        if ($st) { $d = @(Get-AdbDevices) }
    }
    if ($d.Count -eq 1 -and @('device', 'recovery', 'sideload') -contains $d[0].State) {
        Write-Info "Phone found ($($d[0].State)): rebooting it to the bootloader."
        [void](Invoke-Tool $script:Adb @('reboot', 'bootloader') 30)
    } else {
        Write-Info 'Phone not found. Connect it and either start Android with USB debugging enabled,'
        Write-Info 'or put it in the LK bootloader (fastboot).'
    }
    if (-not (Wait-Fastboot 600 'Waiting for the phone in fastboot (LK)...')) {
        Stop-Install 'The phone did not appear in fastboot within 10 minutes.'
    }
    Write-Ok 'Phone in LK (fastboot).'
}

function Restart-Phone {
    Write-Step 'Rebooting to Android'
    [void](Invoke-Tool $script:Adb @('reboot') 30)
    Write-Ok 'Done. The first boot takes several minutes (longer after a clean install).'
}

function Invoke-Main {
    Write-Host ''
    Write-Host 'LineageOS 23.2 (Android 16) installer for the Lumia 950 XL (cityman)' -ForegroundColor White
    Write-Host 'Unofficial, experimental. Your warranty is void; you do this at your own risk.'

    $mode = $Mode
    if (-not $mode) { $mode = Select-Mode }
    if ($Resume -and $mode -ne 'Full') { Stop-Install '-Resume is only for the Full mode.' }

    if ($mode -eq 'Full' -and (Test-IsWindows) -and -not $NoElevate -and -not (Test-IsAdmin)) {
        Write-Info 'The full install writes to the phone''s EFIESP: asking for administrator rights.'
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-Mode', 'Full', '-PauseAtEnd')
        if ($Resume) { $list += '-Resume'; $list += $Resume }
        foreach ($n in @('Rom', 'Twrp', 'EfiEsp', 'OfficialDir', 'AdbPath', 'FastbootPath')) {
            $v = Get-Variable -Name $n -ValueOnly
            if ($v) { $list += "-$n"; $list += (Get-FullPath $v) }
        }
        if ($RomSha256) { $list += '-RomSha256'; $list += $RomSha256 }
        try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList (ConvertTo-ArgString $list) }
        catch { Stop-Install 'Administrator rights are needed for the full install (as in the official installer).' }
        Write-Info 'The installer continues in the administrator window.'
        return
    }

    $script:Pinned = Read-Pinned
    $script:WorkDir = Join-Parts @($Root, 'work')
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
    Write-Info "Mode: $mode. Log: $($script:LogFile)"

    if ($mode -eq 'Full') {
        $script:BackupDir = Join-Parts @($Root, 'backups', "cityman-$Stamp")
        New-Item -ItemType Directory -Force -Path $script:BackupDir | Out-Null
        Resolve-Official
        Write-Step 'Checking adb and fastboot'
        Initialize-Tools $script:OfficialRoot
    } else {
        Write-Step 'Checking adb and fastboot'
        Initialize-Tools ''
    }
    Resolve-Twrp
    Resolve-Rom

    switch ($mode) {
        'Full' {
            Write-Info ''
            Write-Info 'Requirements: phone unlocked with WPInternals, battery above 50%, Android USB driver installed.'
            if ($Resume -eq '') {
                Install-Efiesp
            } else {
                Write-Info "Resuming the full install at: $Resume."
                Enter-Fastboot
            }
            if ($Resume -ne 'Modem') { Invoke-Partitioning }
            Invoke-RecoveryAndModem
            Start-A16Twrp
            Invoke-Provisioning
            Invoke-Wipe
        }
        'Clean' {
            Enter-Fastboot
            Start-A16Twrp
            [void](Invoke-Helper 'check-android')
            Confirm-Word 'Clean install: ALL data on the phone is erased, internal storage included.' 'ERASE' 'Stopped before erasing. Nothing was written; the phone is in TWRP.'
            Invoke-Wipe
        }
        'Update' {
            Enter-Fastboot
            Start-A16Twrp
            [void](Invoke-Helper 'check-android')
            Test-InstalledSystem
        }
    }
    Invoke-Sideload
    Test-BootPartition
    Restart-Phone
    if ($script:BackupDir) { Write-Info "Keep the backups in $($script:BackupDir): they are the only copy of this phone's provisioning data." }
}

# ---------------------------------------------------------------------------

$exitCode = 0
try {
    $logDir = Join-Parts @($Root, 'logs')
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $script:LogFile = Join-Parts @($logDir, "installer-$Stamp.log")
    try { Start-Transcript -Path $script:LogFile | Out-Null } catch { $script:LogFile = '(none)' }
    Invoke-Main
} catch {
    $msg = $_.Exception.Message
    Write-Host ''
    if ($msg.StartsWith('INSTALLER: ')) {
        Write-Host ('ERROR: ' + $msg.Substring(11)) -ForegroundColor Red
    } else {
        Write-Host "UNEXPECTED ERROR: $msg" -ForegroundColor Red
        Write-Host $_.ScriptStackTrace
    }
    Write-Host "The installer stopped. Log: $($script:LogFile)"
    $exitCode = 1
} finally {
    try { Stop-Transcript | Out-Null } catch { }
}
if ($PauseAtEnd) { [void](Read-Host 'Press Enter to close') }
exit $exitCode
