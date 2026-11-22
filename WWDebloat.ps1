<#
.SYNOPSIS
    WWDebloat: removes consumer bloatware and applies ad, AI and privacy tweaks to Windows 10/11
    workstations without weakening security controls.

.DESCRIPTION
    Built to run unattended from an RMM (NinjaOne) as SYSTEM in Windows PowerShell 5.1.

    What it does, in order:
      1. Creates a System Restore point.
      2. Removes a fixed list of consumer apps for all users, removes their provisioned copies
         (so new user profiles do not get them) and marks them deprovisioned (so feature
         updates do not bring them back).
      3. Applies tweaks: Consumer Features, Windows AI, Edge debloat, Widgets, WPBT,
         Logitech Download Assistant block, Start menu recommendations, Bing in Windows Search.
         Per-user settings are written to every existing profile and to the Default profile.
      4. Cleanup: Disk Cleanup (safe handlers only), component store cleanup, old temp files.
      5. Prints a read-only status of Microsoft Defender and BitLocker for the log.

    Every setting is checked before it is written. Settings that are already correct are left
    alone; anything that had to be changed is logged as a CHANGE line and counted as drift.
    Use -EnforceOnly for scheduled daily runs (see README).

    What it never touches: BitLocker, Microsoft Defender (any setting), Windows Firewall,
    Windows Update, Windows services, the diagnostic data (telemetry) level, SSH, RDP, or any
    other remote-access or listening service. It downloads nothing from the internet.

    Log: %ProgramData%\WWDebloat\Logs\WWDebloat_<timestamp>.log (last 20 kept).

    Exit codes: 0 = completed with no errors (and no drift, if -FailOnDrift is set),
                1 = completed with one or more errors (see log),
                2 = refused to run (preflight check failed),
                3 = completed with no errors but drift was found and corrected (-FailOnDrift only).

    The last line of output is always WWDEBLOAT_RESULT: errors=<n> drift=<n>, for NinjaOne
    output conditions.

.PARAMETER EnforceOnly
    Mode for scheduled daily runs. Re-applies app removals and tweaks only. Implies
    -SkipRestorePoint and -SkipCleanup, and never loads the registry of signed-out users or the
    Default profile (so a user signing in during the run can never get a temporary profile).
    Signed-out users are covered the next time a run happens while they are signed in.

.PARAMETER FailOnDrift
    Exit with code 3 when drift was found and corrected, so NinjaOne can alert on it.

.PARAMETER DriftCustomField
    Name of a NinjaOne custom field (text) to write a one-line drift summary to, for example
    wwdebloatStatus. The field must allow write access from automations.

.PARAMETER SkipRestorePoint
    Do not create a System Restore point before making changes.

.PARAMETER SkipAppRemoval
    Do not remove any apps.

.PARAMETER SkipTweaks
    Do not apply any tweaks.

.PARAMETER SkipCleanup
    Do not run Disk Cleanup, component store cleanup or temp file removal.

.PARAMETER HideStartRecommendedSection
    Opt-in. Hides the entire Recommended section of the Windows 11 Start menu. Windows only
    honors this on Education editions, so this also sets the IsEducationEnvironment flag.
    See README before enabling.

.PARAMETER ResetComponentBase
    Opt-in. Adds /ResetBase to the component store cleanup. Frees more space but makes every
    currently installed Windows update permanently uninstallable.

.PARAMETER TempFileAgeDays
    Only temp files older than this many days are deleted. Default 7.

.NOTES
    Every parameter can also be set with a NinjaOne script variable (environment variable) of
    the same name, for example a checkbox named SkipCleanup. Environment variables win.
#>
[CmdletBinding()]
param(
    [switch]$SkipRestorePoint,
    [switch]$SkipAppRemoval,
    [switch]$SkipTweaks,
    [switch]$SkipCleanup,
    [switch]$HideStartRecommendedSection,
    [switch]$ResetComponentBase,
    [ValidateRange(1, 365)]
    [int]$TempFileAgeDays = 7,
    [switch]$EnforceOnly,
    [switch]$FailOnDrift,
    [string]$DriftCustomField = ''
)

$ScriptVersion = '1.1.0'

# Errors are handled explicitly with -ErrorAction Stop inside try blocks. A global 'Stop' is
# avoided on purpose: in Windows PowerShell 5.1 it turns stderr from native tools into
# terminating errors.
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

#region Logging ---------------------------------------------------------------------------------

$script:ErrorCount = 0
$script:WarningCount = 0
$script:Changes = New-Object System.Collections.Generic.List[string]
$script:AlreadyCorrect = 0
$script:LoadOfflineHives = $true
$LogRoot = Join-Path $env:ProgramData 'WWDebloat\Logs'
if (-not (Test-Path -LiteralPath $LogRoot)) {
    New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
}
$LogFile = Join-Path $LogRoot ('WWDebloat_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'CHANGE', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    if ($Level -eq 'STEP') {
        $line = ''
        Write-Host $line
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
        $line = '==== {0} ====' -f $Message
    } else {
        $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    }
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    if ($Level -eq 'ERROR') { $script:ErrorCount++ }
    if ($Level -eq 'WARN') { $script:WarningCount++ }
}

function Add-Change {
    # Records something that was not in the desired state and had to be changed (drift).
    param([Parameter(Mandatory)][string]$Description)
    $script:Changes.Add($Description)
    Write-Log $Description 'CHANGE'
}

function Remove-OldLogs {
    Get-ChildItem -LiteralPath $LogRoot -Filter 'WWDebloat_*.log' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

#endregion

#region NinjaOne script variables -----------------------------------------------------------------

function Get-EnvFlag {
    param([string]$Name, [bool]$Current)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Current }
    return (@('1', 'true', 'yes', 'on') -contains $value.Trim().ToLowerInvariant())
}

$SkipRestorePoint            = Get-EnvFlag 'SkipRestorePoint' $SkipRestorePoint.IsPresent
$SkipAppRemoval              = Get-EnvFlag 'SkipAppRemoval' $SkipAppRemoval.IsPresent
$SkipTweaks                  = Get-EnvFlag 'SkipTweaks' $SkipTweaks.IsPresent
$SkipCleanup                 = Get-EnvFlag 'SkipCleanup' $SkipCleanup.IsPresent
$HideStartRecommendedSection = Get-EnvFlag 'HideStartRecommendedSection' $HideStartRecommendedSection.IsPresent
$ResetComponentBase          = Get-EnvFlag 'ResetComponentBase' $ResetComponentBase.IsPresent
$EnforceOnly                 = Get-EnvFlag 'EnforceOnly' $EnforceOnly.IsPresent
$FailOnDrift                 = Get-EnvFlag 'FailOnDrift' $FailOnDrift.IsPresent

$envField = [Environment]::GetEnvironmentVariable('DriftCustomField')
if (-not [string]::IsNullOrWhiteSpace($envField)) { $DriftCustomField = $envField.Trim() }

if ($EnforceOnly) {
    $SkipRestorePoint = $true
    $SkipCleanup = $true
    $script:LoadOfflineHives = $false
}

$envAge = [Environment]::GetEnvironmentVariable('TempFileAgeDays')
if (-not [string]::IsNullOrWhiteSpace($envAge)) {
    $parsedAge = 0
    if ([int]::TryParse($envAge.Trim(), [ref]$parsedAge) -and $parsedAge -ge 1 -and $parsedAge -le 365) {
        $TempFileAgeDays = $parsedAge
    }
}

#endregion

#region Preflight ---------------------------------------------------------------------------------

# A 32-bit PowerShell on 64-bit Windows writes HKLM\SOFTWARE values into WOW6432Node, where
# Windows ignores them. Relaunch in 64-bit PowerShell if that happens.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $ps64 = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if ($PSCommandPath -and (Test-Path -LiteralPath $ps64)) {
        Write-Host 'Relaunching in 64-bit Windows PowerShell.'
        $relaunchArgs = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
        if ($SkipRestorePoint) { $relaunchArgs += '-SkipRestorePoint' }
        if ($SkipAppRemoval) { $relaunchArgs += '-SkipAppRemoval' }
        if ($SkipTweaks) { $relaunchArgs += '-SkipTweaks' }
        if ($SkipCleanup) { $relaunchArgs += '-SkipCleanup' }
        if ($HideStartRecommendedSection) { $relaunchArgs += '-HideStartRecommendedSection' }
        if ($ResetComponentBase) { $relaunchArgs += '-ResetComponentBase' }
        if ($EnforceOnly) { $relaunchArgs += '-EnforceOnly' }
        if ($FailOnDrift) { $relaunchArgs += '-FailOnDrift' }
        if ($DriftCustomField) { $relaunchArgs += @('-DriftCustomField', $DriftCustomField) }
        $relaunchArgs += @('-TempFileAgeDays', $TempFileAgeDays)
        & $ps64 @relaunchArgs
        exit $LASTEXITCODE
    }
    Write-Host 'ERROR: Running as a 32-bit process and cannot relaunch as 64-bit. Set the script architecture to 64-bit in NinjaOne.'
    exit 2
}

function Test-Preflight {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        Write-Log 'This script must run in Windows PowerShell 5.1 (Checkpoint-Computer and the Appx cmdlets are not reliable in PowerShell 7).' 'ERROR'
        return $false
    }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log 'This script must run elevated (NinjaOne: Run As System).' 'ERROR'
        return $false
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ($os.ProductType -ne 1) {
        Write-Log ('Refusing to run: this is not a workstation OS ({0}). WWDebloat is for client PCs only.' -f $os.Caption) 'ERROR'
        return $false
    }

    Write-Log ('OS: {0} build {1}' -f $os.Caption, $os.BuildNumber)
    Write-Log ('Running as: {0}' -f [Security.Principal.WindowsIdentity]::GetCurrent().Name)
    return $true
}

#endregion

#region Registry helpers ----------------------------------------------------------------------------

function Set-RegValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'String', 'ExpandString', 'QWord')][string]$Type = 'DWord',
        [string]$Context = ''
    )
    $where = if ($Context) { ' [{0}]' -f $Context } else { '' }
    try {
        $keyExists = Test-Path -LiteralPath $Path
        $before = '(not set)'
        if ($keyExists) {
            $key = Get-Item -LiteralPath $Path -ErrorAction Stop
            try {
                if ($key.GetValueNames() -contains $Name) {
                    $current = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
                    $kind = $key.GetValueKind($Name).ToString()
                    if ($kind -eq $Type -and [string]$current -eq [string]$Value) {
                        $script:AlreadyCorrect++
                        return
                    }
                    $before = '{0} ({1})' -f $current, $kind
                }
            } finally {
                $key.Close()
            }
        } else {
            # Only create the key when missing. New-Item -Force on an existing registry key
            # would wipe every value already stored under it.
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
        Add-Change ('{0}\{1}: {2} -> {3}{4}' -f $Path, $Name, $before, $Value, $where)
    } catch {
        Write-Log ('Failed to set {0}\{1}{2}: {3}' -f $Path, $Name, $where, $_.Exception.Message) 'ERROR'
    }
}

function New-RegKey {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path) {
            $script:AlreadyCorrect++
        } else {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
            Add-Change ('Created key {0}' -f $Path)
        }
    } catch {
        Write-Log ('Failed to create key {0}: {1}' -f $Path, $_.Exception.Message) 'ERROR'
    }
}

function Get-UserHiveTargets {
    # Every real user profile (local, domain and Entra ID accounts) plus the Default profile,
    # so new users created after this run get the same settings.
    $targets = New-Object System.Collections.Generic.List[object]
    $profileListPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

    foreach ($key in Get-ChildItem -LiteralPath $profileListPath -ErrorAction SilentlyContinue) {
        $sid = $key.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-') { continue }
        $imagePath = (Get-ItemProperty -LiteralPath $key.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not $imagePath) { continue }
        $imagePath = [Environment]::ExpandEnvironmentVariables($imagePath)
        $targets.Add([pscustomobject]@{
            Label = $imagePath
            Sid   = $sid
            Hive  = Join-Path $imagePath 'NTUSER.DAT'
        })
    }

    $defaultRoot = (Get-ItemProperty -LiteralPath $profileListPath -Name Default -ErrorAction SilentlyContinue).Default
    if ($defaultRoot) {
        $defaultRoot = [Environment]::ExpandEnvironmentVariables($defaultRoot)
        $targets.Add([pscustomobject]@{
            Label = 'Default user profile'
            Sid   = $null
            Hive  = Join-Path $defaultRoot 'NTUSER.DAT'
        })
    }
    return $targets
}

function Invoke-ForEachUserHive {
    <#
        Runs $Action once per user hive. $Action receives the hive root as a provider path such
        as 'Registry::HKEY_USERS\S-1-5-21-...'. Hives of signed-out users are loaded and
        unloaded around the call.
    #>
    param([Parameter(Mandatory)][scriptblock]$Action)

    foreach ($target in $script:UserHiveTargets) {
        $mountName = $null
        if ($target.Sid -and (Test-Path -LiteralPath ('Registry::HKEY_USERS\{0}' -f $target.Sid))) {
            $root = 'Registry::HKEY_USERS\{0}' -f $target.Sid
        } elseif (-not $script:LoadOfflineHives) {
            # EnforceOnly: never load a hive Windows is not already using.
            continue
        } else {
            if (-not (Test-Path -LiteralPath $target.Hive)) {
                Write-Log ('No NTUSER.DAT for {0}, skipping.' -f $target.Label)
                continue
            }
            $mountName = 'WWD_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $loadOutput = & reg.exe load ('HKU\{0}' -f $mountName) $target.Hive 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                Write-Log ('Could not load the registry hive for {0}: {1}' -f $target.Label, $loadOutput.Trim()) 'WARN'
                continue
            }
            $root = 'Registry::HKEY_USERS\{0}' -f $mountName
        }

        try {
            & $Action $root $target.Label
        } catch {
            Write-Log ('Per-user change failed for {0}: {1}' -f $target.Label, $_.Exception.Message) 'ERROR'
        } finally {
            if ($mountName) {
                # Release handles PowerShell holds on the hive before unloading it.
                [gc]::Collect()
                [gc]::WaitForPendingFinalizers()
                $unloaded = $false
                for ($attempt = 1; $attempt -le 3 -and -not $unloaded; $attempt++) {
                    Start-Sleep -Milliseconds (500 * $attempt)
                    $null = & reg.exe unload ('HKU\{0}' -f $mountName) 2>&1
                    $unloaded = ($LASTEXITCODE -eq 0)
                }
                if (-not $unloaded) {
                    Write-Log ('Could not unload the hive for {0} (HKU\{1}); Windows releases it at the next restart.' -f $target.Label, $mountName) 'WARN'
                }
            }
        }
    }
}

#endregion

#region Restore point -----------------------------------------------------------------------------

function New-PreChangeRestorePoint {
    Write-Log 'Restore point' 'STEP'
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $freqName = 'SystemRestorePointCreationFrequency'
    $original = (Get-ItemProperty -LiteralPath $srKey -Name $freqName -ErrorAction SilentlyContinue).$freqName

    try {
        Enable-ComputerRestore -Drive ('{0}\' -f $env:SystemDrive) -ErrorAction Stop
        Write-Log ('System Protection is on for {0}.' -f $env:SystemDrive) 'OK'

        # Windows silently skips a restore point if another was created in the last 24 hours.
        # Lift that limit for this one checkpoint only, then put the original value back.
        New-ItemProperty -LiteralPath $srKey -Name $freqName -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Checkpoint-Computer -Description ('WWDebloat {0} pre-change' -f $ScriptVersion) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Restore point created.' 'OK'
    } catch {
        Write-Log ('Restore point could not be created: {0}. Continuing without one.' -f $_.Exception.Message) 'WARN'
    } finally {
        if ($null -eq $original) {
            Remove-ItemProperty -LiteralPath $srKey -Name $freqName -ErrorAction SilentlyContinue
        } else {
            New-ItemProperty -LiteralPath $srKey -Name $freqName -Value $original -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
}

#endregion

#region App removal -------------------------------------------------------------------------------

# Exact package names (no wildcards) and their package family names. Legacy Windows 10 names
# are included so the same list covers both versions.
$script:BloatApps = @(
    @{ Label = 'Xbox App';                    Name = 'Microsoft.GamingApp';                     Pfn = 'Microsoft.GamingApp_8wekyb3d8bbwe' }
    @{ Label = 'Xbox Console Companion (W10)'; Name = 'Microsoft.XboxApp';                       Pfn = 'Microsoft.XboxApp_8wekyb3d8bbwe' }
    @{ Label = 'Xbox Game Bar';               Name = 'Microsoft.XboxGamingOverlay';             Pfn = 'Microsoft.XboxGamingOverlay_8wekyb3d8bbwe' }
    @{ Label = 'Xbox Game Bar Plugin (W10)';  Name = 'Microsoft.XboxGameOverlay';               Pfn = 'Microsoft.XboxGameOverlay_8wekyb3d8bbwe' }
    @{ Label = 'Xbox Speech To Text Overlay'; Name = 'Microsoft.XboxSpeechToTextOverlay';       Pfn = 'Microsoft.XboxSpeechToTextOverlay_8wekyb3d8bbwe' }
    @{ Label = 'Xbox TCUI';                   Name = 'Microsoft.Xbox.TCUI';                     Pfn = 'Microsoft.Xbox.TCUI_8wekyb3d8bbwe' }
    @{ Label = 'Solitaire Collection';        Name = 'Microsoft.MicrosoftSolitaireCollection';  Pfn = 'Microsoft.MicrosoftSolitaireCollection_8wekyb3d8bbwe' }
    @{ Label = 'News';                        Name = 'Microsoft.BingNews';                      Pfn = 'Microsoft.BingNews_8wekyb3d8bbwe' }
    @{ Label = 'Weather';                     Name = 'Microsoft.BingWeather';                   Pfn = 'Microsoft.BingWeather_8wekyb3d8bbwe' }
    @{ Label = 'Bing Search';                 Name = 'Microsoft.BingSearch';                    Pfn = 'Microsoft.BingSearch_8wekyb3d8bbwe' }
    @{ Label = 'Start Experiences App';       Name = 'Microsoft.StartExperiencesApp';           Pfn = 'Microsoft.StartExperiencesApp_8wekyb3d8bbwe' }
    @{ Label = 'Clipchamp';                   Name = 'Clipchamp.Clipchamp';                     Pfn = 'Clipchamp.Clipchamp_yxz26nhyzhsrt' }
    @{ Label = 'Media Player';                Name = 'Microsoft.ZuneMusic';                     Pfn = 'Microsoft.ZuneMusic_8wekyb3d8bbwe' }
    @{ Label = 'Movies & TV';                 Name = 'Microsoft.ZuneVideo';                     Pfn = 'Microsoft.ZuneVideo_8wekyb3d8bbwe' }
    @{ Label = 'Sound Recorder';              Name = 'Microsoft.WindowsSoundRecorder';          Pfn = 'Microsoft.WindowsSoundRecorder_8wekyb3d8bbwe' }
    @{ Label = 'Feedback Hub';                Name = 'Microsoft.WindowsFeedbackHub';            Pfn = 'Microsoft.WindowsFeedbackHub_8wekyb3d8bbwe' }
    @{ Label = 'Dev Home';                    Name = 'Microsoft.Windows.DevHome';               Pfn = 'Microsoft.Windows.DevHome_8wekyb3d8bbwe' }
    @{ Label = 'Power Automate';              Name = 'Microsoft.PowerAutomateDesktop';          Pfn = 'Microsoft.PowerAutomateDesktop_8wekyb3d8bbwe' }
    @{ Label = 'Quick Assist';                Name = 'MicrosoftCorporationII.QuickAssist';      Pfn = 'MicrosoftCorporationII.QuickAssist_8wekyb3d8bbwe' }
    @{ Label = 'Phone Link';                  Name = 'Microsoft.YourPhone';                     Pfn = 'Microsoft.YourPhone_8wekyb3d8bbwe' }
    @{ Label = 'Mobile Devices';              Name = 'MicrosoftWindows.CrossDevice';            Pfn = 'MicrosoftWindows.CrossDevice_cw5n1h2txyewy' }
)

# Removed by the Windows AI and Widgets tweaks.
$script:AiApps = @(
    @{ Label = 'Copilot';                     Name = 'Microsoft.Copilot';                       Pfn = 'Microsoft.Copilot_8wekyb3d8bbwe' }
    @{ Label = 'Copilot (legacy provider)';   Name = 'Microsoft.Windows.Ai.Copilot.Provider';   Pfn = 'Microsoft.Windows.Ai.Copilot.Provider_8wekyb3d8bbwe' }
    @{ Label = 'Microsoft 365 Copilot app';   Name = 'Microsoft.MicrosoftOfficeHub';            Pfn = 'Microsoft.MicrosoftOfficeHub_8wekyb3d8bbwe' }
)
$script:WidgetApps = @(
    @{ Label = 'Widgets (Web Experience)';    Name = 'MicrosoftWindows.Client.WebExperience';   Pfn = 'MicrosoftWindows.Client.WebExperience_cw5n1h2txyewy' }
    @{ Label = 'Widgets Platform Runtime';    Name = 'Microsoft.WidgetsPlatformRuntime';        Pfn = 'Microsoft.WidgetsPlatformRuntime_8wekyb3d8bbwe' }
)

# Processes to stop before removing a package, so removal does not fail on locked files.
# Only stopped when the package is actually found.
$script:AppProcesses = @{
    'Microsoft.XboxGamingOverlay'           = @('GameBar', 'GameBarFTServer')
    'Microsoft.YourPhone'                   = @('PhoneExperienceHost')
    'MicrosoftWindows.CrossDevice'          = @('CrossDeviceService')
    'MicrosoftCorporationII.QuickAssist'    = @('QuickAssist')
    'Clipchamp.Clipchamp'                   = @('Clipchamp')
    'MicrosoftWindows.Client.WebExperience' = @('Widgets', 'WidgetService')
}

$script:ProvisionedPackages = $null

function Get-ProvisionedPackageCache {
    if ($null -eq $script:ProvisionedPackages) {
        try {
            $script:ProvisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction Stop)
        } catch {
            Write-Log ('Could not read provisioned packages: {0}' -f $_.Exception.Message) 'ERROR'
            $script:ProvisionedPackages = @()
        }
    }
    return $script:ProvisionedPackages
}

function Remove-AppEverywhere {
    param([Parameter(Mandatory)][hashtable]$App)

    $found = $false
    $provisioned = @(Get-ProvisionedPackageCache | Where-Object { $_.DisplayName -eq $App.Name })
    $installed = @(Get-AppxPackage -AllUsers -Name $App.Name -ErrorAction SilentlyContinue |
        Sort-Object -Property PackageFullName -Unique)

    if (($provisioned.Count + $installed.Count) -gt 0 -and $script:AppProcesses.ContainsKey($App.Name)) {
        foreach ($procName in $script:AppProcesses[$App.Name]) {
            Get-Process -Name $procName -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    # 1. Provisioned copy: stops the app being installed into new user profiles.
    foreach ($prov in $provisioned) {
        $found = $true
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            Add-Change ('{0}: removed provisioned package {1}' -f $App.Label, $prov.PackageName)
        } catch {
            Write-Log ('{0}: failed to remove provisioned package {1}: {2}' -f $App.Label, $prov.PackageName, $_.Exception.Message) 'ERROR'
        }
    }

    # 2. Installed copies, for every user.
    foreach ($pkg in $installed) {
        $found = $true
        if ($pkg.PSObject.Properties['NonRemovable'] -and $pkg.NonRemovable) {
            Write-Log ('{0}: {1} is marked non-removable by Windows, skipped.' -f $App.Label, $pkg.PackageFullName) 'WARN'
            continue
        }
        try {
            Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            Add-Change ('{0}: removed {1} for all users' -f $App.Label, $pkg.PackageFullName)
        } catch {
            # Some builds refuse -AllUsers for per-user installs when run as SYSTEM. Fall back to
            # removing it user by user.
            $allUsersError = $_.Exception.Message
            $userFailures = 0
            $userInfo = @($pkg.PackageUserInformation)
            foreach ($info in $userInfo) {
                $sid = $info.UserSecurityId.Sid
                if (-not $sid) { continue }
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -User $sid -ErrorAction Stop
                } catch {
                    $userFailures++
                }
            }
            if ($userInfo.Count -gt 0 -and $userFailures -eq 0) {
                Add-Change ('{0}: removed {1} user by user' -f $App.Label, $pkg.PackageFullName)
            } else {
                Write-Log ('{0}: failed to remove {1}: {2}' -f $App.Label, $pkg.PackageFullName, $allUsersError) 'ERROR'
            }
        }
    }

    # 3. Deprovisioned marker: Microsoft's documented way to stop feature updates reinstalling
    #    an app. Delete this key to allow the app to come back.
    New-RegKey -Path ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned\{0}' -f $App.Pfn)

    if (-not $found) { $script:AlreadyCorrect++ }
}

function Invoke-AppRemoval {
    Write-Log 'App removal' 'STEP'

    foreach ($app in $script:BloatApps) {
        Remove-AppEverywhere -App $app
    }

    # Quick Assist on older Windows 10 builds is a Windows capability, not a Store app.
    try {
        foreach ($cap in @(Get-WindowsCapability -Online -Name 'App.Support.QuickAssist*' -ErrorAction Stop | Where-Object { $_.State -eq 'Installed' })) {
            Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            Add-Change ('Quick Assist: removed Windows capability {0}' -f $cap.Name)
        }
    } catch {
        Write-Log ('Quick Assist: could not check or remove the legacy capability: {0}' -f $_.Exception.Message) 'WARN'
    }

    # With Game Bar removed, launching a game shows an "ms-gamebar" popup. Turning off Game DVR
    # by policy prevents it.
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0
}

#endregion

#region Tweaks ------------------------------------------------------------------------------------

function Set-ConsumerFeatures {
    Write-Log 'Tweak: Disable Windows Consumer Features' 'STEP'
    # Policy. Fully honored on Enterprise and Education editions.
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1

    # Per-user equivalents, which Pro editions do honor: no silent sponsored app installs and
    # no app suggestions in Start.
    Invoke-ForEachUserHive -Action {
        param($root, $label)
        $cdm = '{0}\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -f $root
        foreach ($name in @('SilentInstalledAppsEnabled', 'PreInstalledAppsEnabled', 'OemPreInstalledAppsEnabled', 'SystemPaneSuggestionsEnabled', 'SubscribedContent-338388Enabled')) {
            Set-RegValue -Path $cdm -Name $name -Value 0 -Context $label
        }
    }
}

function Set-WindowsAI {
    Write-Log 'Tweak: Remove Windows AI' 'STEP'

    foreach ($app in $script:AiApps) {
        Remove-AppEverywhere -App $app
    }

    # Machine policies.
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableAIDataAnalysis' -Value 1   # Recall: no snapshots
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'AllowRecallEnablement' -Value 0   # Recall: cannot be enabled
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableClickToDo' -Value 1        # Click to Do
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -Name 'DisableSettingsAgent' -Value 1    # AI agent in Settings
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\WindowsNotepad' -Name 'DisableAIFeatures' -Value 1                    # Notepad AI
    $paintPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'
    foreach ($name in @('DisableCocreator', 'DisableGenerativeFill', 'DisableImageCreator')) {
        Set-RegValue -Path $paintPolicy -Name $name -Value 1                                                         # Paint AI
    }

    # Per-user: Copilot policy and taskbar button.
    Invoke-ForEachUserHive -Action {
        param($root, $label)
        Set-RegValue -Path ('{0}\Software\Policies\Microsoft\Windows\WindowsCopilot' -f $root) -Name 'TurnOffWindowsCopilot' -Value 1 -Context $label
        Set-RegValue -Path ('{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -f $root) -Name 'ShowCopilotButton' -Value 0 -Context $label
    }

    # Recall as an optional feature (Copilot+ PCs only). Disabled, not deleted, so it can be
    # restored with Enable-WindowsOptionalFeature.
    try {
        $recall = Get-WindowsOptionalFeature -Online -FeatureName 'Recall' -ErrorAction Stop
        if ($recall -and $recall.State -eq 'Enabled') {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -NoRestart -ErrorAction Stop | Out-Null
            Add-Change 'Recall optional feature disabled (takes effect after restart)'
        } else {
            $script:AlreadyCorrect++
        }
    } catch {
        # Not a Copilot+ PC: the Recall feature does not exist here.
        $script:AlreadyCorrect++
    }
}

function Set-EdgeDebloat {
    Write-Log 'Tweak: Debloat Microsoft Edge' 'STEP'
    # None of these touch SmartScreen, Defender, password or security settings.
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'CreateDesktopShortcutDefault' -Value 0
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $edgePolicies = [ordered]@{
        'HideFirstRunExperience'                = 1
        'ShowRecommendationsEnabled'            = 0
        'PersonalizationReportingEnabled'       = 0
        'UserFeedbackAllowed'                   = 0
        'DiagnosticData'                        = 0
        'ConfigureDoNotTrack'                   = 1
        'AlternateErrorPagesEnabled'            = 0
        'EdgeCollectionsEnabled'                = 0
        'EdgeShoppingAssistantEnabled'          = 0
        'MicrosoftEdgeInsiderPromotionEnabled'  = 0
        'ShowMicrosoftRewards'                  = 0
        'WebWidgetAllowed'                      = 0
        'WalletDonationEnabled'                 = 0
        'DefaultBrowserSettingsCampaignEnabled' = 0
    }
    foreach ($entry in $edgePolicies.GetEnumerator()) {
        Set-RegValue -Path $edge -Name $entry.Key -Value $entry.Value
    }
}

function Set-RemoveWidgets {
    Write-Log 'Tweak: Remove Widgets' 'STEP'
    foreach ($app in $script:WidgetApps) {
        Remove-AppEverywhere -App $app
    }
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0            # Windows 11 Widgets
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' -Name 'EnableFeeds' -Value 0    # Windows 10 News and Interests
}

function Set-Wpbt {
    Write-Log 'Tweak: Disable WPBT (firmware-injected programs at boot)' 'STEP'
    Set-RegValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'DisableWpbtExecution' -Value 1
}

function Set-LogitechBlock {
    Write-Log 'Tweak: Block Logitech Download Assistant' 'STEP'
    $logiProcs = @(Get-Process -Name 'logi_download_assistant' -ErrorAction SilentlyContinue)
    if ($logiProcs.Count -gt 0) {
        $logiProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Add-Change 'Stopped running Logitech Download Assistant'
    }

    foreach ($runKey in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run')) {
        $runValues = Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue
        if ($runValues -and $runValues.PSObject.Properties['Logitech Download Assistant']) {
            Remove-ItemProperty -LiteralPath $runKey -Name 'Logitech Download Assistant' -ErrorAction SilentlyContinue
            Add-Change ('Removed Logitech Download Assistant startup entry from {0}' -f $runKey)
        }
    }

    $programFiles64 = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $logiPath = Join-Path $programFiles64 'LogiDownloadAssistant'
    try {
        if (Test-Path -LiteralPath $logiPath) {
            $contents = @(Get-ChildItem -LiteralPath $logiPath -Force -ErrorAction SilentlyContinue)
            if ($contents.Count -gt 0) {
                $contents | Remove-Item -Recurse -Force -ErrorAction Stop
                Add-Change ('Emptied {0} ({1} items)' -f $logiPath, $contents.Count)
            }
        } else {
            New-Item -ItemType Directory -Path $logiPath -Force -ErrorAction Stop | Out-Null
        }

        # Deny write to Everyone so Windows Update driver packages cannot reinstall it.
        $everyone = 'S-1-1-0'
        $hasDeny = $false
        $acl = Get-Acl -LiteralPath $logiPath -ErrorAction Stop
        foreach ($rule in $acl.GetAccessRules($true, $false, [Security.Principal.SecurityIdentifier])) {
            if ($rule.AccessControlType -eq 'Deny' -and $rule.IdentityReference.Value -eq $everyone -and
                ($rule.FileSystemRights -band [Security.AccessControl.FileSystemRights]::WriteData)) {
                $hasDeny = $true
            }
        }
        if ($hasDeny) {
            $script:AlreadyCorrect++
        } else {
            $icaclsOutput = & icacls.exe $logiPath /deny ('*{0}:(W)' -f $everyone) 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                Add-Change ('Denied write access on {0}' -f $logiPath)
            } else {
                Write-Log ('icacls failed on {0}: {1}' -f $logiPath, $icaclsOutput.Trim()) 'ERROR'
            }
        }
    } catch {
        Write-Log ('Logitech block failed: {0}' -f $_.Exception.Message) 'ERROR'
    }
}

function Set-StartMenuRecommendations {
    Write-Log 'Tweak: Start menu recommendations' 'STEP'
    # Removes promoted content from Recommended. Recent files, recent apps and jump lists stay,
    # because people rely on them.
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'HideRecommendedPersonalizedSites' -Value 1
    Invoke-ForEachUserHive -Action {
        param($root, $label)
        $adv = '{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -f $root
        Set-RegValue -Path $adv -Name 'Start_IrisRecommendations' -Value 0 -Context $label   # tips, shortcuts, new apps
        Set-RegValue -Path $adv -Name 'Start_AccountNotifications' -Value 0 -Context $label  # account and backup nags
    }

    if ($HideStartRecommendedSection) {
        Write-Log 'Opt-in: hiding the entire Recommended section (sets IsEducationEnvironment).'
        Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'HideRecommendedSection' -Value 1
        Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'HideRecommendedSection' -Value 1
        Set-RegValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education' -Name 'IsEducationEnvironment' -Value 1
    }
}

function Set-BingSearch {
    Write-Log 'Tweak: Remove Bing web results from Windows Search' 'STEP'
    # Search highlights (daily web content in the search box).
    Set-RegValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'EnableDynamicContentInWSB' -Value 0
    Invoke-ForEachUserHive -Action {
        param($root, $label)
        Set-RegValue -Path ('{0}\Software\Microsoft\Windows\CurrentVersion\Search' -f $root) -Name 'BingSearchEnabled' -Value 0 -Context $label
        Set-RegValue -Path ('{0}\Software\Policies\Microsoft\Windows\Explorer' -f $root) -Name 'DisableSearchBoxSuggestions' -Value 1 -Context $label
    }
}

#endregion

#region Cleanup -----------------------------------------------------------------------------------

function Invoke-DiskCleanup {
    Write-Log 'Cleanup: Disk Cleanup (safe handlers only)' 'STEP'
    $cleanmgr = Join-Path $env:WINDIR 'System32\cleanmgr.exe'
    if (-not (Test-Path -LiteralPath $cleanmgr)) {
        Write-Log 'cleanmgr.exe is not present on this PC, skipped.' 'WARN'
        return
    }

    # Handlers that are safe on a client PC. Deliberately excluded: Downloads, Recycle Bin,
    # Internet Cache (holds Outlook's copies of opened attachments), memory dumps and Windows
    # Error Reporting files (needed for incident investigation), Previous Installations and
    # driver packages (needed for rollback), Windows ESD files (needed for Reset this PC).
    $safeHandlers = @(
        'Active Setup Temp Folders'
        'D3D Shader Cache'
        'Delivery Optimization Files'
        'Diagnostic Data Viewer database files'
        'Downloaded Program Files'
        'Old ChkDsk Files'
        'Setup Log Files'
        'Temporary Files'
        'Temporary Setup Files'
        'Thumbnail Cache'
        'Update Cleanup'
        'Windows Upgrade Log Files'
    )
    $profileNumber = 4729
    $flagName = 'StateFlags{0:D4}' -f $profileNumber
    $cachesRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches'

    $selected = 0
    foreach ($handler in Get-ChildItem -LiteralPath $cachesRoot -ErrorAction SilentlyContinue) {
        # 2 = run this handler for our profile, 0 = do not. Every handler is set explicitly so a
        # leftover setting can never pull in Downloads or the Recycle Bin.
        $value = if ($safeHandlers -contains $handler.PSChildName) { 2 } else { 0 }
        if ($value -eq 2) { $selected++ }
        New-ItemProperty -LiteralPath $handler.PSPath -Name $flagName -Value $value -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log ('Disk Cleanup profile {0}: {1} safe handlers selected.' -f $profileNumber, $selected)

    try {
        $proc = Start-Process -FilePath $cleanmgr -ArgumentList ('/sagerun:{0}' -f $profileNumber) -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($proc.WaitForExit(45 * 60 * 1000)) {
            Write-Log 'Disk Cleanup finished.' 'OK'
        } else {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Log 'Disk Cleanup did not finish within 45 minutes and was stopped.' 'WARN'
        }
    } catch {
        Write-Log ('Disk Cleanup failed to start: {0}' -f $_.Exception.Message) 'ERROR'
    }
}

function Invoke-ComponentCleanup {
    Write-Log 'Cleanup: Windows component store (WinSxS)' 'STEP'
    $dismArgs = '/Online /Cleanup-Image /StartComponentCleanup'
    if ($ResetComponentBase) {
        $dismArgs += ' /ResetBase'
        Write-Log 'Opt-in /ResetBase: installed updates will no longer be uninstallable.' 'WARN'
    }
    try {
        # Not given a timeout: interrupting DISM mid-servicing can damage the component store.
        $proc = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\Dism.exe') -ArgumentList $dismArgs -PassThru -Wait -WindowStyle Hidden -ErrorAction Stop
        if ($proc.ExitCode -eq 0) {
            Write-Log 'Component store cleanup finished.' 'OK'
        } else {
            Write-Log ('DISM exited with code {0}. Common when a restart is pending; it will clean up on a later run.' -f $proc.ExitCode) 'WARN'
        }
    } catch {
        Write-Log ('DISM failed to start: {0}' -f $_.Exception.Message) 'ERROR'
    }
}

function Remove-OldFilesSafely {
    <#
        Deletes files older than the cutoff under $Root. Never follows junctions or symbolic
        links: this runs as SYSTEM in folders users can write to, and following a planted link
        would let a user aim the deletion at any file on the PC.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][datetime]$Cutoff
    )
    $stats = @{ Files = 0; Bytes = 0L; Skipped = 0 }
    $reparse = [IO.FileAttributes]::ReparsePoint

    $rootInfo = New-Object IO.DirectoryInfo($Root)
    if (-not $rootInfo.Exists -or ($rootInfo.Attributes -band $reparse)) { return $stats }

    $stack = New-Object System.Collections.Generic.Stack[IO.DirectoryInfo]
    $stack.Push($rootInfo)
    $visited = New-Object System.Collections.Generic.List[IO.DirectoryInfo]

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $visited.Add($dir)
        try {
            $entries = $dir.GetFileSystemInfos()
        } catch {
            continue
        }
        foreach ($entry in $entries) {
            if ($entry.Attributes -band $reparse) { continue }
            if ($entry -is [IO.DirectoryInfo]) {
                $stack.Push($entry)
            } elseif ($entry.LastWriteTime -lt $Cutoff -and $entry.LastAccessTime -lt $Cutoff) {
                try {
                    $size = $entry.Length
                    if ($entry.Attributes -band [IO.FileAttributes]::ReadOnly) {
                        $entry.Attributes = $entry.Attributes -bxor [IO.FileAttributes]::ReadOnly
                    }
                    $entry.Delete()
                    $stats.Files++
                    $stats.Bytes += $size
                } catch {
                    $stats.Skipped++   # in use or access denied
                }
            }
        }
    }

    # Remove folders left empty, deepest first. The root itself is kept.
    for ($i = $visited.Count - 1; $i -ge 1; $i--) {
        $dir = $visited[$i]
        try {
            $dir.Refresh()
            if ($dir.Exists -and $dir.LastWriteTime -lt $Cutoff -and -not ($dir.EnumerateFileSystemInfos() | Select-Object -First 1)) {
                $dir.Delete()
            }
        } catch { }
    }
    return $stats
}

function Remove-TempFiles {
    Write-Log ('Cleanup: temp files older than {0} days' -f $TempFileAgeDays) 'STEP'
    $cutoff = (Get-Date).AddDays(-$TempFileAgeDays)

    $roots = New-Object System.Collections.Generic.List[string]
    $roots.Add((Join-Path $env:WINDIR 'Temp'))
    foreach ($target in $script:UserHiveTargets) {
        if ($target.Sid) {
            $roots.Add((Join-Path $target.Label 'AppData\Local\Temp'))
        }
    }

    $totalFiles = 0
    $totalBytes = 0L
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $result = Remove-OldFilesSafely -Root $root -Cutoff $cutoff
        $totalFiles += $result.Files
        $totalBytes += $result.Bytes
        Write-Log ('{0}: removed {1} files ({2:N1} MB), {3} in use or locked' -f $root, $result.Files, ($result.Bytes / 1MB), $result.Skipped)
    }
    Write-Log ('Temp cleanup total: {0} files, {1:N1} MB' -f $totalFiles, ($totalBytes / 1MB)) 'OK'
}

#endregion

#region Security status (read-only) -----------------------------------------------------------------

function Write-SecurityStatus {
    Write-Log 'Security status (read-only, nothing changed)' 'STEP'
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        Write-Log ('Defender: antivirus enabled={0}, real-time protection={1}, tamper protection={2}' -f $mp.AntivirusEnabled, $mp.RealTimeProtectionEnabled, $mp.IsTamperProtected)
    } catch {
        Write-Log 'Defender status unavailable (a third-party antivirus may be active).'
    }
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        Write-Log ('BitLocker {0}: protection={1}, status={2}' -f $env:SystemDrive, $bl.ProtectionStatus, $bl.VolumeStatus)
    } catch {
        Write-Log 'BitLocker status unavailable on this edition.'
    }
}

#endregion

#region Main --------------------------------------------------------------------------------------

function Set-NinjaDriftField {
    param([string]$FieldName, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($FieldName)) { return }
    try {
        if (Get-Command -Name 'Ninja-Property-Set' -ErrorAction SilentlyContinue) {
            Ninja-Property-Set $FieldName $Value | Out-Null
        } else {
            $cli = Join-Path $env:ProgramData 'NinjaRMMAgent\ninjarmm-cli.exe'
            if (-not (Test-Path -LiteralPath $cli)) {
                Write-Log ('NinjaOne agent not found; custom field {0} not updated.' -f $FieldName) 'WARN'
                return
            }
            $cliOutput = & $cli set $FieldName $Value 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw $cliOutput.Trim() }
        }
        Write-Log ('NinjaOne custom field {0} = {1}' -f $FieldName, $Value)
    } catch {
        Write-Log ('Could not update NinjaOne custom field {0}: {1}' -f $FieldName, $_.Exception.Message) 'WARN'
    }
}

$mode = if ($EnforceOnly) { 'EnforceOnly' } else { 'Full' }
Write-Log ('WWDebloat {0} starting ({1} mode)' -f $ScriptVersion, $mode) 'STEP'
Write-Log ('Options: SkipRestorePoint={0} SkipAppRemoval={1} SkipTweaks={2} SkipCleanup={3} HideStartRecommendedSection={4} ResetComponentBase={5} TempFileAgeDays={6} FailOnDrift={7} DriftCustomField={8}' -f `
    $SkipRestorePoint, $SkipAppRemoval, $SkipTweaks, $SkipCleanup, $HideStartRecommendedSection, $ResetComponentBase, $TempFileAgeDays, $FailOnDrift, $DriftCustomField)
Write-Log ('Log file: {0}' -f $LogFile)

if (-not (Test-Preflight)) {
    Write-Log 'Preflight failed. No changes were made.' 'ERROR'
    Write-Host ('WWDEBLOAT_RESULT: errors={0} drift=0' -f $script:ErrorCount)
    exit 2
}

$script:UserHiveTargets = Get-UserHiveTargets
$realProfiles = @($script:UserHiveTargets | Where-Object { $_.Sid })
if ($script:LoadOfflineHives) {
    Write-Log ('User profiles found: {0} (plus Default profile)' -f $realProfiles.Count)
} else {
    $signedIn = @($realProfiles | Where-Object { Test-Path -LiteralPath ('Registry::HKEY_USERS\{0}' -f $_.Sid) })
    Write-Log ('User profiles found: {0}. EnforceOnly: checking the {1} signed-in profile(s); signed-out profiles and the Default profile are left for the next run.' -f $realProfiles.Count, $signedIn.Count)
}

if (-not $SkipRestorePoint) { New-PreChangeRestorePoint }

if (-not $SkipAppRemoval) { Invoke-AppRemoval }

if (-not $SkipTweaks) {
    Set-ConsumerFeatures
    Set-WindowsAI
    Set-EdgeDebloat
    Set-RemoveWidgets
    Set-Wpbt
    Set-LogitechBlock
    Set-StartMenuRecommendations
    Set-BingSearch
}

if (-not $SkipCleanup) {
    Invoke-DiskCleanup
    Invoke-ComponentCleanup
    Remove-TempFiles
}

Write-SecurityStatus
Remove-OldLogs

$driftCount = $script:Changes.Count
Write-Log 'Summary' 'STEP'
Write-Log ('Already correct: {0} item(s). Changed (drift corrected): {1} item(s).' -f $script:AlreadyCorrect, $driftCount)
foreach ($change in $script:Changes) {
    Write-Log ('  - {0}' -f $change)
}
Write-Log ('Finished with {0} error(s) and {1} warning(s).' -f $script:ErrorCount, $script:WarningCount)
if ($driftCount -gt 0) {
    Write-Log 'A restart (or sign out and back in) is needed for Start menu, taskbar and search changes to appear. This script does not restart the PC.'
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
if ($script:ErrorCount -gt 0) {
    $fieldValue = '{0} | ERRORS | {1} error(s), {2} drift item(s) corrected ({3})' -f $stamp, $script:ErrorCount, $driftCount, $mode
} elseif ($driftCount -gt 0) {
    $fieldValue = '{0} | DRIFT | {1} item(s) corrected ({2})' -f $stamp, $driftCount, $mode
} else {
    $fieldValue = '{0} | OK | no drift ({1})' -f $stamp, $mode
}
Set-NinjaDriftField -FieldName $DriftCustomField -Value $fieldValue

Write-Host ('WWDEBLOAT_RESULT: errors={0} drift={1}' -f $script:ErrorCount, $driftCount)

if ($script:ErrorCount -gt 0) { exit 1 }
if ($FailOnDrift -and $driftCount -gt 0) { exit 3 }
exit 0

#endregion
