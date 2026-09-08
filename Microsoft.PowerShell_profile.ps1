### Chris Titus Tech's PowerShell profile

function Enable-Tls12 {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Verbose "Unable to enable TLS 1.2 explicitly: $_"
    }
}

Enable-Tls12

$script:ProfileRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Path $PROFILE.CurrentUserCurrentHost -Parent }
$script:CustomProfile = Join-Path -Path $script:ProfileRoot -ChildPath 'CTTcustom.ps1'

if (Test-Path -Path $script:CustomProfile -PathType Leaf) {
    . $script:CustomProfile
}

function Test-InteractiveShell {
    try {
        return $Host.Name -eq 'ConsoleHost' -and
            -not [Console]::IsInputRedirected -and
            -not [Console]::IsOutputRedirected
    } catch {
        return $false
    }
}

function Get-ProfileDir {
    switch ($PSVersionTable.PSEdition) {
        'Core' { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell'; break }
        'Desktop' { Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell'; break }
        default {
            throw "Unsupported PowerShell edition: $($PSVersionTable.PSEdition)"
        }
    }
}

function Test-Command {
    param([Parameter(Mandatory)][string]$Name)
    $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Save-UriToFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )

    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadFile($Uri, $OutFile)
    } finally {
        $client.Dispose()
    }
}

function Get-UriContent {
    param([Parameter(Mandatory)][string]$Uri)

    $client = New-Object System.Net.WebClient
    try {
        $client.DownloadString($Uri)
    } finally {
        $client.Dispose()
    }
}

function Format-Bytes {
    param([Parameter(Mandatory)][AllowNull()][Nullable[double]]$Bytes)

    if ($null -eq $Bytes) {
        return '0 B'
    }

    $units = 'B', 'KB', 'MB', 'GB', 'TB', 'PB'
    $index = 0
    $value = [double]$Bytes
    while ($value -ge 1024 -and $index -lt $units.Count - 1) {
        $value /= 1024
        $index++
    }

    '{0:N2} {1}' -f $value, $units[$index]
}

$isInteractiveShell = Test-InteractiveShell
$debug = if ($null -ne $debug_Override) { [bool]$debug_Override } else { $false }
$repo_root = if ($repo_root_Override) { $repo_root_Override } else { 'https://raw.githubusercontent.com/ItzSteveHuh' }
$profileDir = Get-ProfileDir
$timeFilePath = if ($timeFilePath_Override) { $timeFilePath_Override } else { Join-Path $profileDir 'LastExecutionTime.txt' }
$updateInterval = if ($null -ne $updateInterval_Override) { [int]$updateInterval_Override } else { 7 }
$showHelpOnLaunch = if ($null -ne $show_help_Override) { [bool]$show_help_Override } else { $false }

function Debug-Message {
    if (Get-Command -Name 'Debug-Message_Override' -ErrorAction SilentlyContinue) {
        Debug-Message_Override
        return
    }

    Write-Host '#######################################' -ForegroundColor Red
    Write-Host '#           Debug mode enabled        #' -ForegroundColor Red
    Write-Host '#          ONLY FOR DEVELOPMENT       #' -ForegroundColor Red
    Write-Host '#       Run Update-Profile to reset   #' -ForegroundColor Red
    Write-Host '#######################################' -ForegroundColor Red
}

if ($debug) {
    Debug-Message
}

function Test-ProfileUpdateDue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$IntervalDays
    )

    if ($IntervalDays -lt 0 -or -not (Test-Path -Path $Path -PathType Leaf)) {
        return $true
    }

    $rawDate = (Get-Content -Path $Path -Raw -ErrorAction SilentlyContinue).Trim()
    if ([string]::IsNullOrWhiteSpace($rawDate)) {
        return $true
    }

    $lastRun = [datetime]::MinValue
    if (-not [datetime]::TryParseExact(
            $rawDate,
            'yyyy-MM-dd',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None,
            [ref]$lastRun
        )) {
        return $true
    }

    return ((Get-Date).Date - $lastRun.Date).TotalDays -ge $IntervalDays
}

function Test-ProfileIsSymlink {
    $profileItem = Get-Item -LiteralPath $PROFILE.CurrentUserCurrentHost -Force -ErrorAction SilentlyContinue
    return $profileItem -and $profileItem.LinkType -eq 'SymbolicLink'
}

function Update-Profile {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param([switch]$Force)

    if (Get-Command -Name 'Update-Profile_Override' -ErrorAction SilentlyContinue) {
        Update-Profile_Override @PSBoundParameters
        return $true
    }

    $url = "$repo_root/powershell-profile/main/Microsoft.PowerShell_profile.ps1"
    $target = $PROFILE.CurrentUserCurrentHost
    $tempFile = Join-Path $env:TEMP 'Microsoft.PowerShell_profile.ps1'

    try {
        Save-UriToFile -Uri $url -OutFile $tempFile

        $targetExists = Test-Path -Path $target -PathType Leaf
        $oldHash = if ($targetExists) { (Get-FileHash -Path $target).Hash } else { $null }
        $newHash = (Get-FileHash -Path $tempFile).Hash

        if (-not $Force -and $targetExists -and $oldHash -eq $newHash) {
            if ($isInteractiveShell) {
                Write-Host 'Profile is up to date.' -ForegroundColor Green
            }
            return $true
        }

        if ($PSCmdlet.ShouldProcess($target, 'Update PowerShell profile')) {
            $targetDir = Split-Path -Path $target -Parent
            if (-not (Test-Path -Path $targetDir)) {
                New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
            }

            Copy-Item -Path $tempFile -Destination $target -Force
            Write-Host 'Profile has been updated. Restart your shell to use the new version.' -ForegroundColor Magenta
        }

        return $true
    } catch {
        Write-Warning "Unable to check for profile updates: $_"
        return $false
    } finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

function Invoke-ScheduledProfileUpdate {
    if ($debug -or
        -not $isInteractiveShell -or
        (Test-ProfileIsSymlink) -or
        -not (Test-ProfileUpdateDue -Path $timeFilePath -IntervalDays $updateInterval)) {
        return
    }

    if (Update-Profile) {
        $timeDir = Split-Path -Path $timeFilePath -Parent
        if (-not (Test-Path -Path $timeDir)) {
            New-Item -Path $timeDir -ItemType Directory -Force | Out-Null
        }
        Get-Date -Format 'yyyy-MM-dd' | Set-Content -Path $timeFilePath
    }
}

function Update-PowerShell {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (Get-Command -Name 'Update-PowerShell_Override' -ErrorAction SilentlyContinue) {
        Update-PowerShell_Override @PSBoundParameters
        return
    }

    if (-not (Test-Command winget)) {
        Write-Warning 'winget is required to update PowerShell automatically.'
        return
    }

    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -ErrorAction Stop
        $currentVersion = [version]$PSVersionTable.PSVersion
        $latestVersion = [version]($release.tag_name -replace '^v', '')

        if ($currentVersion -ge $latestVersion) {
            Write-Host "PowerShell $currentVersion is up to date." -ForegroundColor Green
            return
        }

        if ($PSCmdlet.ShouldProcess("PowerShell $currentVersion", "Upgrade to $latestVersion")) {
            winget upgrade --id Microsoft.PowerShell --exact --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Error "winget failed to update PowerShell. Exit code: $LASTEXITCODE"
                return
            }
            Write-Host 'PowerShell has been updated. Restart your shell to use the new version.' -ForegroundColor Magenta
        }
    } catch {
        Write-Error "Failed to update PowerShell. Error: $_"
    }
}

function Clear-Cache {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (Get-Command -Name 'Clear-Cache_Override' -ErrorAction SilentlyContinue) {
        Clear-Cache_Override @PSBoundParameters
        return
    }

    $paths = @(
        "$env:SystemRoot\Prefetch\*",
        "$env:SystemRoot\Temp\*",
        "$env:TEMP\*",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache\*"
    )

    foreach ($path in $paths) {
        if ($PSCmdlet.ShouldProcess($path, 'Remove cached files')) {
            Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Initialize-OptionalModule {
    if (-not $isInteractiveShell) {
        return
    }

    if (Get-Module -ListAvailable -Name Terminal-Icons) {
        Import-Module -Name Terminal-Icons -ErrorAction SilentlyContinue
    } elseif ($isInteractiveShell) {
        Write-Warning 'Terminal-Icons module is not installed. Run setup.ps1 to install dependencies.'
    }

    $chocolateyProfile = if ($env:ChocolateyInstall) {
        Join-Path $env:ChocolateyInstall 'helpers\chocolateyProfile.psm1'
    } else {
        $null
    }

    if ($chocolateyProfile -and (Test-Path -Path $chocolateyProfile -PathType Leaf)) {
        Import-Module $chocolateyProfile -ErrorAction SilentlyContinue
    }
}

function Resolve-Editor {
    if ($EDITOR_Override) {
        return $EDITOR_Override
    }

    foreach ($candidate in 'nvim', 'pvim', 'vim', 'vi', 'code', 'codium', 'notepad++', 'sublime_text') {
        if (Test-Command $candidate) {
            return $candidate
        }
    }

    return 'notepad'
}

Initialize-OptionalModule

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$EDITOR = Resolve-Editor
Set-Alias -Name vim -Value $EDITOR -Force

if ($isInteractiveShell) {
    try {
        $adminSuffix = if ($isAdmin) { ' [ADMIN]' } else { '' }
        $Host.UI.RawUI.WindowTitle = "PowerShell $($PSVersionTable.PSVersion)$adminSuffix"
    } catch {
        Write-Verbose "Unable to set console title: $_"
    }
}

function prompt {
    $marker = if ($isAdmin) { '#' } else { '$' }
    "[$(Get-Location)] $marker "
}

function Edit-Profile {
    & $EDITOR $PROFILE.CurrentUserAllHosts
}
Set-Alias -Name ep -Value Edit-Profile -Force

function Invoke-Profile {
    . $PROFILE.CurrentUserCurrentHost
}

function touch {
    param([Parameter(Mandatory)][string]$File)

    if (Test-Path -Path $File) {
        (Get-Item -Path $File).LastWriteTime = Get-Date
    } else {
        New-Item -Path $File -ItemType File -Force | Out-Null
    }
}

function mkcd {
    param([Parameter(Mandatory)][string]$Path)
    New-Item -Path $Path -ItemType Directory -Force | Out-Null
    Set-Location -Path $Path
}

function ff {
    param([Parameter(Mandatory)][string]$Name)
    Get-ChildItem -Recurse -Filter "*$Name*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
}

function pubip {
    (Get-UriContent -Uri 'https://ifconfig.me/ip').Trim()
}

function admin {
    $cwd = (Get-Location).ProviderPath
    $shell = if (Test-Command pwsh) { 'pwsh.exe' } else { 'powershell.exe' }
    $shellArgs = if ($args.Count -gt 0) { @('-NoExit', '-Command', ($args -join ' ')) } else { @('-NoExit') }

    if (Test-Command wt) {
        Start-Process wt -Verb RunAs -ArgumentList (@('-d', $cwd, $shell) + $shellArgs)
    } else {
        Start-Process $shell -Verb RunAs -WorkingDirectory $cwd -ArgumentList $shellArgs
    }
}
Set-Alias -Name su -Value admin -Force

function uptime {
    $boot = if (Get-Command Get-Uptime -ErrorAction SilentlyContinue) {
        Get-Uptime -Since
    } else {
        (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
    }

    (Get-Date) - $boot | Select-Object Days, Hours, Minutes, Seconds
}

function unzip {
    param([Parameter(Mandatory)][string]$File)

    if (-not (Test-Path -Path $File -PathType Leaf)) {
        Write-Error "File not found: $File"
        return
    }

    Expand-Archive -Path $File -DestinationPath (Get-Location) -Force
}

function grep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Pattern,
        [Parameter(Position = 1)][string]$Path,
        [Parameter(ValueFromPipeline)][object]$InputObject
    )

    begin {
        $pipelineInput = [System.Collections.Generic.List[object]]::new()
    }

    process {
        if ($PSBoundParameters.ContainsKey('InputObject')) {
            $pipelineInput.Add($InputObject)
        }
    }

    end {
        if ($Path) {
            Get-ChildItem -Path $Path -Recurse -File -ErrorAction SilentlyContinue | Select-String -Pattern $Pattern
        } elseif ($pipelineInput.Count -gt 0) {
            $pipelineInput | Select-String -Pattern $Pattern
        } else {
            Write-Error 'Usage: grep <pattern> [path] or pipe input to grep'
        }
    }
}

function df { Get-Volume }

function sed {
    param(
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Find,
        [Parameter(Mandatory)][string]$Replace
    )

    (Get-Content -Path $File).Replace($Find, $Replace) | Set-Content -Path $File
}

function which {
    param([Parameter(Mandatory)][string]$Name)
    Get-Command -Name $Name | Select-Object -ExpandProperty Definition
}

function export {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    Set-Item -Path "env:$Name" -Value $Value -Force
}

function pkill {
    param([Parameter(Mandatory)][string]$Name)
    Get-Process -Name $Name -ErrorAction SilentlyContinue | Stop-Process -Force
}

function pgrep {
    param([Parameter(Mandatory)][string]$Name)
    Get-Process -Name $Name -ErrorAction SilentlyContinue
}

function head {
    param([Parameter(Mandatory)][string]$Path, [int]$n = 10)
    Get-Content -Path $Path -Head $n
}

function tail {
    param([Parameter(Mandatory)][string]$Path, [int]$n = 10, [switch]$f)
    Get-Content -Path $Path -Tail $n -Wait:$f
}

function nf {
    param([Parameter(Mandatory)][string]$Name)
    New-Item -ItemType File -Path . -Name $Name -Force | Out-Null
}

function trash {
    param([Parameter(Mandatory)][string]$Path)

    $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $resolvedPath) {
        Write-Error "Item not found: $Path"
        return
    }

    $fullPath = $resolvedPath.ProviderPath
    $item = Get-Item -LiteralPath $fullPath
    $parentPath = if ($item.PSIsContainer) {
        if ($item.Parent) { $item.Parent.FullName } else { Split-Path -Path $item.FullName -Parent }
    } else {
        $item.DirectoryName
    }

    if ([string]::IsNullOrWhiteSpace($parentPath)) {
        Write-Error "Cannot move root path to Recycle Bin: $fullPath"
        return
    }

    $shell = New-Object -ComObject 'Shell.Application'
    $shellFolder = $shell.NameSpace($parentPath)
    $shellItem = if ($shellFolder) { $shellFolder.ParseName($item.Name) } else { $null }

    if ($shellItem) {
        $shellItem.InvokeVerb('delete')
    } else {
        Write-Error "Could not move item to Recycle Bin: $fullPath"
    }
}

function docs {
    Set-Location -Path ([Environment]::GetFolderPath('MyDocuments'))
}

function dtop {
    Set-Location -Path ([Environment]::GetFolderPath('Desktop'))
}

function k9 { param([Parameter(Mandatory)][string]$Name) pkill $Name }
function la { Get-ChildItem | Format-Table -AutoSize }
function ll { Get-ChildItem -Force | Format-Table -AutoSize }
function gs { git status }
function ga { git add . }
function gc { git commit -m ($args -join ' ') }
function gpush { git push @args }
function gpull { git pull @args }
function gcl { git clone @args }

function g {
    if (Get-Command __zoxide_z -ErrorAction SilentlyContinue) {
        __zoxide_z github
    } elseif (Test-Path -Path "$HOME\github") {
        Set-Location "$HOME\github"
    }
}

function gcom {
    git add .
    git commit -m ($args -join ' ')
}

function lazyg {
    git add .
    git commit -m ($args -join ' ')
    git push
}

function sysinfo { Get-ComputerInfo }

function flushdns {
    Clear-DnsClientCache
    Write-Host 'DNS has been flushed'
}

function cpy { Set-Clipboard ($args -join ' ') }
function pst { Get-Clipboard }

# Navigation
function .. { Set-Location -Path '..' }
function ... { Set-Location -Path '../..' }
function .... { Set-Location -Path '../../..' }

# bash-style cd: `cd -` toggles to the previous directory, `cd` with no args goes home.
# (PowerShell's native `cd -` walks location history instead of toggling.)
$global:OLDPWD = $null

function Set-LocationBash {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Path)

    $target = if ($Path) { $Path } else { $HOME }
    $current = $PWD.Path

    if ($target -eq '-') {
        if (-not $global:OLDPWD) {
            Write-Warning 'cd: OLDPWD not set'
            return
        }
        $target = $global:OLDPWD
    }

    Set-Location -Path $target -ErrorAction Stop
    $global:OLDPWD = $current
}
Set-Alias -Name cd -Value Set-LocationBash -Option AllScope -Force

function explore {
    param([string]$Path = '.')
    Invoke-Item -LiteralPath $Path
}
Set-Alias -Name open -Value explore -Force
Set-Alias -Name take -Value mkcd -Force
Set-Alias -Name reload -Value Invoke-Profile -Force

function edit {
    param([Parameter(Mandatory)][string]$Path)
    & $EDITOR $Path
}

function path {
    $env:PATH -split [System.IO.Path]::PathSeparator | Where-Object { $_ }
}

function env {
    Get-ChildItem -Path Env: | Sort-Object -Property Name
}

function now {
    param([switch]$u)
    if ($u) {
        [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    } else {
        Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

function hist {
    param([string]$Pattern)

    $historyPath = (Get-PSReadLineOption).HistorySavePath
    if (-not $historyPath -or -not (Test-Path -LiteralPath $historyPath)) {
        Get-History | Select-Object -ExpandProperty CommandLine
        return
    }

    $lines = Get-Content -LiteralPath $historyPath
    if ($Pattern) { $lines | Select-String -Pattern $Pattern } else { $lines }
}

function ports {
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Sort-Object -Property LocalPort |
        Select-Object LocalAddress, LocalPort,
            @{ Name = 'Process'; Expression = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } },
            @{ Name = 'PID'; Expression = { $_.OwningProcess } }
}

function killport {
    param([Parameter(Mandatory)][int]$Port)

    $owners = Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    if (-not $owners) {
        Write-Warning "No process is listening on port $Port."
        return
    }

    foreach ($processId in $owners) {
        $proc = Get-Process -Id $processId -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "Stopping $($proc.ProcessName) (PID $processId) on port $Port"
            Stop-Process -Id $processId -Force
        }
    }
}

function weather {
    param([string]$Location = '')
    (Get-UriContent -Uri "https://wttr.in/$Location`?format=3").Trim()
}

# Linux-style coreutils
function wc {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [switch]$l,
        [switch]$w,
        [switch]$c,
        [Parameter(ValueFromPipeline)][string]$InputObject
    )

    begin { $buffer = [System.Collections.Generic.List[string]]::new() }
    process { if ($PSBoundParameters.ContainsKey('InputObject')) { $buffer.Add($InputObject) } }
    end {
        $source = if ($Path) { Get-Content -LiteralPath $Path } else { $buffer }
        $measure = $source | Measure-Object -Line -Word -Character
        if ($l) { $measure.Lines }
        elseif ($w) { $measure.Words }
        elseif ($c) { $measure.Characters }
        else { '{0,8} {1,8} {2,8} {3}' -f $measure.Lines, $measure.Words, $measure.Characters, $Path }
    }
}

function du {
    param([string]$Path = '.', [switch]$s)

    if ($s) {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{ Size = Format-Bytes $bytes; Path = (Resolve-Path -LiteralPath $Path).Path }
        return
    }

    Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $bytes = (Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        [PSCustomObject]@{ Size = Format-Bytes $bytes; Name = $_.Name }
    }
}

function free {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    [PSCustomObject]@{
        Total = Format-Bytes ($os.TotalVisibleMemorySize * 1KB)
        Used  = Format-Bytes (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1KB)
        Free  = Format-Bytes ($os.FreePhysicalMemory * 1KB)
    }
}

function watch {
    param(
        [Parameter(Mandatory, Position = 0, ValueFromRemainingArguments)][string[]]$Command,
        [Alias('n')][double]$Interval = 2
    )

    $script = $Command -join ' '
    while ($true) {
        Clear-Host
        Write-Host ('Every {0}s: {1}    {2}' -f $Interval, $script, (Get-Date)) -ForegroundColor Cyan
        Invoke-Expression -Command $script
        Start-Sleep -Seconds $Interval
    }
}

function nl {
    param([Parameter(Mandatory)][string]$Path)
    $number = 0
    Get-Content -LiteralPath $Path | ForEach-Object {
        $number++
        '{0,6}  {1}' -f $number, $_
    }
}

function mktemp {
    param([switch]$d)

    if ($d) {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        (New-Item -ItemType Directory -Path $dir).FullName
    } else {
        [System.IO.Path]::GetTempFileName()
    }
}

function uniq {
    [CmdletBinding()]
    param(
        [switch]$c,
        [Parameter(ValueFromPipeline)][string]$InputObject
    )

    begin {
        $previous = $null
        $havePrevious = $false
        $count = 0
    }
    process {
        if ($havePrevious -and $InputObject -eq $previous) {
            $count++
        } else {
            if ($havePrevious) {
                if ($c) { '{0,7} {1}' -f $count, $previous } else { $previous }
            }
            $previous = $InputObject
            $havePrevious = $true
            $count = 1
        }
    }
    end {
        if ($havePrevious) {
            if ($c) { '{0,7} {1}' -f $count, $previous } else { $previous }
        }
    }
}

function basename {
    param([Parameter(Mandatory)][string]$Path, [string]$Suffix)

    $leaf = Split-Path -Path $Path -Leaf
    if ($Suffix -and $leaf.EndsWith($Suffix) -and $leaf -ne $Suffix) {
        $leaf.Substring(0, $leaf.Length - $Suffix.Length)
    } else {
        $leaf
    }
}

function dirname {
    param([Parameter(Mandatory)][string]$Path)
    $parent = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrEmpty($parent)) { '.' } else { $parent }
}

function realpath {
    param([Parameter(Mandatory)][string]$Path)
    (Resolve-Path -LiteralPath $Path).ProviderPath
}

function ln {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Target,
        [Parameter(Mandatory, Position = 1)][string]$Link,
        [switch]$s
    )
    $type = if ($s) { 'SymbolicLink' } else { 'HardLink' }
    New-Item -ItemType $type -Path $Link -Target $Target
}

function dig {
    param([Parameter(Mandatory)][string]$Name, [string]$Type = 'A')
    Resolve-DnsName -Name $Name -Type $Type
}

function ifconfig { Get-NetIPConfiguration }

function sha256sum {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path)
    $Path | ForEach-Object { Get-FileHash -Algorithm SHA256 -LiteralPath $_ | Select-Object Hash, Path }
}

function md5sum {
    param([Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Path)
    $Path | ForEach-Object { Get-FileHash -Algorithm MD5 -LiteralPath $_ | Select-Object Hash, Path }
}

# GitHub CLI
function ghpr { gh pr create @args }
function ghprs { gh pr status @args }
function ghprv { gh pr view --web @args }
function ghco { gh pr checkout @args }
function ghrv { gh repo view --web @args }
function ghrun { gh run watch @args }
function ghis { gh issue list @args }

function Set-PSReadLineOptionsCompat {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][hashtable]$Options)

    $safeOptions = $Options.Clone()
    if ($PSVersionTable.PSEdition -ne 'Core') {
        $safeOptions.Remove('PredictionSource')
        $safeOptions.Remove('PredictionViewStyle')
    }

    if ($PSCmdlet.ShouldProcess('PSReadLine', 'Set PSReadLine options')) {
        Set-PSReadLineOption @safeOptions
    }
}

function Set-PredictionSource {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (Get-Command -Name 'Set-PredictionSource_Override' -ErrorAction SilentlyContinue) {
        Set-PredictionSource_Override
        return
    }

    if ($PSCmdlet.ShouldProcess('PSReadLine', 'Set prediction source')) {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            Set-PSReadLineOption -PredictionSource HistoryAndPlugin
        }

        Set-PSReadLineOption -MaximumHistoryCount 10000
    }
}

function Initialize-PSReadLine {
    if (-not $isInteractiveShell -or -not (Get-Module -ListAvailable -Name PSReadLine)) {
        return
    }

    $options = @{
        EditMode                    = 'Windows'
        HistoryNoDuplicates        = $true
        HistorySearchCursorMovesToEnd = $true
        PredictionSource           = 'History'
        PredictionViewStyle        = 'ListView'
        BellStyle                  = 'None'
        Colors                     = @{
            Command   = '#87CEEB'
            Parameter = '#98FB98'
            Operator  = '#FFB6C1'
            Variable  = '#DDA0DD'
            String    = '#FFDAB9'
            Number    = '#B0E0E6'
            Type      = '#F0E68C'
            Comment   = '#D3D3D3'
            Keyword   = '#8367c7'
            Error     = '#FF6347'
        }
    }

    Set-PSReadLineOptionsCompat -Options $options
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete
    Set-PSReadLineKeyHandler -Chord 'Ctrl+d' -Function DeleteChar
    Set-PSReadLineKeyHandler -Chord 'Ctrl+w' -Function BackwardDeleteWord
    Set-PSReadLineKeyHandler -Chord 'Alt+d' -Function DeleteWord
    Set-PSReadLineKeyHandler -Chord 'Ctrl+LeftArrow' -Function BackwardWord
    Set-PSReadLineKeyHandler -Chord 'Ctrl+RightArrow' -Function ForwardWord
    Set-PSReadLineKeyHandler -Chord 'Ctrl+z' -Function Undo
    Set-PSReadLineKeyHandler -Chord 'Ctrl+y' -Function Redo

    Set-PSReadLineOption -AddToHistoryHandler {
        param([string]$line)
        $line -notmatch '(?i)(password|secret|token|apikey|connectionstring)'
    }

    Set-PredictionSource
}

function Register-CustomCompletion {
    if (-not $isInteractiveShell) {
        return
    }

    $completionMap = @{
        git  = @('status', 'add', 'commit', 'push', 'pull', 'clone', 'checkout')
        npm  = @('install', 'start', 'run', 'test', 'build')
        deno = @('run', 'compile', 'bundle', 'test', 'lint', 'fmt', 'cache', 'info', 'doc', 'upgrade')
    }

    Register-ArgumentCompleter -Native -CommandName git, npm, deno -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)
        $null = $cursorPosition
        $completionWord = $wordToComplete
        $map = $completionMap
        $command = $commandAst.CommandElements[0].Value
        if ($map.ContainsKey($command)) {
            $map[$command] |
                Where-Object { $_ -like "$completionWord*" } |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        }
    }.GetNewClosure()

    if (Test-Command dotnet) {
        Register-ArgumentCompleter -Native -CommandName dotnet -ScriptBlock {
            param($wordToComplete, $commandAst, $cursorPosition)
            $null = $wordToComplete
            dotnet complete --position $cursorPosition $commandAst.ToString() |
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
        }
    }
}

function Resolve-OhMyPoshTheme {
    $candidates = @(
        $env:POSH_THEME,
        (Join-Path $profileDir 'cobalt2.omp.json'),
        (Join-Path $HOME 'cobalt2.omp.json')
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -Path $candidate -PathType Leaf) {
            return $candidate
        }
    }

    return $null
}

function Initialize-PromptTool {
    if (-not $isInteractiveShell) {
        return
    }

    if (Get-Command -Name 'Get-Theme_Override' -ErrorAction SilentlyContinue) {
        Get-Theme_Override
    } elseif (Test-Command oh-my-posh) {
        $theme = Resolve-OhMyPoshTheme
        if ($theme) {
            oh-my-posh init pwsh --config $theme | Invoke-Expression
        } elseif ($isInteractiveShell) {
            Write-Warning 'Oh My Posh theme not found. Run setup.ps1 to install cobalt2.omp.json.'
        }
    } elseif ($isInteractiveShell) {
        Write-Warning 'oh-my-posh is not installed. Run setup.ps1 to install dependencies.'
    }

    if (Test-Command zoxide) {
        Invoke-Expression (& { (zoxide init --cmd z powershell | Out-String) })
    } elseif ($isInteractiveShell) {
        Write-Warning 'zoxide is not installed. Run setup.ps1 to install dependencies.'
    }
}

function Show-Help {
    @'
PowerShell Profile Help
=======================

Profile:
  Edit-Profile      Open the current user's all-hosts profile for editing.
  Invoke-Profile    Reload this profile in the current session.
  Update-Profile    Check for profile updates.
  Update-PowerShell Check for the latest PowerShell release and update with winget.

Git:
  g                 Go to the GitHub directory with zoxide fallback.
  ga                git add .
  gc <message>      git commit -m <message>
  gcl <repo>        git clone <repo>
  gcom <message>    git add .; git commit -m <message>
  gp/gpush          git push
  gpull             git pull
  gs                git status
  lazyg <message>   git add .; git commit -m <message>; git push

GitHub CLI:
  ghco <pr>        gh pr checkout <pr>
  ghis             gh issue list
  ghpr [args]      gh pr create
  ghprs            gh pr status
  ghprv            gh pr view --web
  ghrun            gh run watch
  ghrv             gh repo view --web

Shortcuts:
  .. / ... / ....  Go up one/two/three directories.
  cd -             Toggle to the previous directory (bash-style).
  admin/su [cmd]   Start an elevated shell (optionally running a command).
  basename <p>     Print the file name portion of a path.
  cpy <text>        Copy text to the clipboard.
  df                Show volume information.
  dig <host>       Resolve DNS records for a host.
  dirname <p>      Print the directory portion of a path.
  docs/dtop         Go to Documents/Desktop.
  du [-s] [path]   Show directory sizes (-s for a single total).
  edit <file>      Open a file in the resolved editor.
  env              List environment variables.
  export <n> <v>   Set an environment variable.
  ff <name>         Find files recursively by name.
  flushdns          Clear the DNS cache.
  free             Show physical memory usage.
  grep <regex> [p]  Search files or piped input.
  head/tail         Show the first or last lines of a file.
  hist [regex]     Search command history.
  ifconfig         Show network configuration.
  k9/pkill <name>   Kill processes by name.
  killport <port>  Stop whatever process is listening on a port.
  la/ll             List visible/all files.
  ln [-s] t l      Create a hard (or symbolic) link.
  md5sum <file>    Print the MD5 hash of files.
  mkcd/take <dir>   Create and enter a directory.
  mktemp [-d]      Create a temp file (or directory) and print its path.
  nf/touch <file>   Create a file.
  nl <file>        Print a file with numbered lines.
  now [-u]         Print the current time (-u for Unix epoch).
  open/explore [p] Open a path in Explorer / its default app.
  path             Print PATH entries one per line.
  pgrep <name>      Find processes by name.
  ports            List listening TCP ports and their owners.
  pst               Paste clipboard text.
  pubip            Show the public IP address.
  realpath <p>     Resolve a path to its full form.
  reload           Reload this profile in the current session.
  sed <f> <a> <b>   Replace text in a file.
  sha256sum <f>    Print the SHA-256 hash of files.
  sysinfo           Show system information.
  trash <path>     Move an item to the Recycle Bin.
  uniq [-c]        Collapse adjacent duplicate lines (-c to count).
  unzip <file>      Extract a zip file here.
  uptime            Show system uptime.
  watch [-n s] cmd Re-run a command every s seconds.
  wc [-l|-w|-c] f  Count lines, words, and characters.
  weather [city]   Show a short weather report.
  which <name>      Show command path.
'@ | Write-Host
}

Set-Alias -Name gp -Value gpush -Force

Initialize-PSReadLine
Register-CustomCompletion
Initialize-PromptTool
Invoke-ScheduledProfileUpdate

if ($showHelpOnLaunch) {
    Show-Help
} elseif ($isInteractiveShell) {
    Write-Host "Use 'Show-Help' to display help" -ForegroundColor Yellow
}
