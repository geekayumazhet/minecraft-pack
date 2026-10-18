param(
    [string]$JavaPath = $env:INST_JAVA,
    [string]$PackUrl,
    [string]$GameDirectory = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Standard packwiz installs into staging. Only verified managed files are promoted.
$game = [IO.Path]::GetFullPath($GameDirectory).TrimEnd('\')
$control = Join-Path $game '.pack-update'
$toolsDir = Join-Path $game 'pack-update-tools'
$lock = $null
$process = $null
$transaction = Join-Path $control 'transaction'

function Assert-NoLinks([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'A managed path contains a junction or symbolic link.'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}
function Managed-Path([string]$Root, [string]$Relative) {
    if ($Relative -notmatch '^mods/[^/\\:<>,"|?*]+\.jar$' -and
        $Relative -ne 'config/ras/display/overlay.json' -and
        $Relative -ne 'config/server-address.txt' -and
        $Relative -ne 'resourcepacks/ru_translation_pack_ae2_atm10.zip') {
        throw "Unapproved managed path: $Relative"
    }
    if ($Relative.Contains('..') -or $Relative.EndsWith('.') -or $Relative.EndsWith(' ')) {
        throw 'Invalid managed path.'
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $full.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path outside managed root.' }
    Assert-NoLinks $full
    return $full
}
function Read-Json([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function Write-Json([string]$Path, $Value) {
    $temporary = $Path + '.new'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 16), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, ($Path + '.previous')) }
    else { [IO.File]::Move($temporary, $Path) }
}
function Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($algorithm.ComputeHash($stream)).Replace('-','').ToLowerInvariant() }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}
function Validate-Catalog($Catalog, [string]$Root, [bool]$CheckFiles = $false) {
    if ($Catalog.format -ne 1 -or $Catalog.platform.minecraft -ne '1.21.1' -or
        $Catalog.platform.neoforge -ne '21.1.233' -or $Catalog.platform.java -ne 21) {
        throw 'Platform changes require a manual release: Minecraft 1.21.1 / NeoForge 21.1.233 / Java 21.'
    }
    $seen = @{}
    foreach ($file in $Catalog.files) {
        $target = Managed-Path $Root $file.path
        if ($seen.ContainsKey($file.path) -or $file.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $file.side -notin @('client', 'both')) { throw 'Invalid managed catalog.' }
        $seen[$file.path] = $true
        if ($CheckFiles -and (Hash $target) -ne $file.sha256) { throw "Managed file is missing or corrupt: $($file.path)" }
    }
    if ($seen.Count -lt 1 -or $seen.Count -gt 400) { throw 'Unexpected managed file count.' }
}
function Ensure-Parent([string]$Path) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
}
function Run-Java([string[]]$Arguments) {
    if (-not (Test-Path -LiteralPath $JavaPath -PathType Leaf)) { throw 'Launcher did not provide a valid Java executable.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $JavaPath
    $start.Arguments = (($Arguments | ForEach-Object {
        if ($_.Contains('"')) { throw 'Invalid Java argument.' }
        '"' + $_ + '"'
    }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = $game
    $script:process = [Diagnostics.Process]::new()
    $script:process.StartInfo = $start
    $script:process.Start() | Out-Null
    $outTask = $script:process.StandardOutput.ReadToEndAsync()
    $errTask = $script:process.StandardError.ReadToEndAsync()
    if (-not $script:process.WaitForExit(180000)) {
        $script:process.Kill()
        throw 'Update timed out. Existing pack has been preserved.'
    }
    $stdout = $outTask.GetAwaiter().GetResult()
    $stderr = $errTask.GetAwaiter().GetResult()
    $code = $script:process.ExitCode
    if ($Arguments -contains '-version') {
        if ($code -ne 0 -or ($stdout + $stderr) -notmatch 'version "21[\.\"]') { throw 'Java 21 is required.' }
    } else {
        [IO.File]::WriteAllText((Join-Path $control 'last-packwiz.log'), $stdout + $stderr)
        if ($code -ne 0) { throw "packwiz failed (exit $code). See .pack-update/last-packwiz.log." }
    }
}
function Recover-Transaction {
    $journalPath = Join-Path $transaction 'journal.json'
    if (-not (Test-Path -LiteralPath $journalPath)) { return }
    $journal = Read-Json $journalPath
    foreach ($entry in $journal.entries) {
        $destination = Managed-Path $game $entry.path
        if ($entry.existed) {
            $backup = Managed-Path (Join-Path $transaction 'backup') $entry.path
            if (-not (Test-Path -LiteralPath $backup)) { throw 'Recovery backup is incomplete. Do not launch.' }
            Ensure-Parent $destination
            Copy-Item -LiteralPath $backup -Destination $destination -Force
        } elseif (Test-Path -LiteralPath $destination) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    $statePath = Join-Path $control 'current.json'
    if ($journal.stateExisted) {
        Copy-Item -LiteralPath (Join-Path $transaction 'previous.json') -Destination $statePath -Force
    } elseif (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath -Force }
    Remove-Item -LiteralPath $journalPath -Force
    Write-Host '[Pack] Interrupted update rolled back.'
}

try {
    Assert-NoLinks $game
    Assert-NoLinks $control
    Assert-NoLinks $toolsDir
    [IO.Directory]::CreateDirectory($control) | Out-Null
    $lock = [IO.File]::Open((Join-Path $control 'update.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    Recover-Transaction
    $settings = Read-Json (Join-Path $toolsDir 'settings.json')
    $currentPath = Join-Path $control 'current.json'
    $previous = if (Test-Path -LiteralPath $currentPath) { Read-Json $currentPath }
                else { Read-Json (Join-Path $toolsDir 'seed.json') }
    Validate-Catalog $previous $game
    if ($settings.mode -notin @('AUTO','PINNED','MANUAL')) { throw 'Unknown update mode.' }
    if ($settings.mode -ne 'AUTO' -and -not $PackUrl) {
        Validate-Catalog $previous $game $true
        Write-Host "[Pack] $($settings.mode): installed pack verified; updates require manual approval."
        exit 0
    }
    if (-not $PackUrl) { $PackUrl = $settings.packUrl }
    $uri = [Uri]$PackUrl
    if ($uri.Scheme -ne 'https' -and -not ($uri.Scheme -eq 'http' -and $uri.IsLoopback)) {
        throw 'The update source must use HTTPS.'
    }
    Run-Java -Arguments @('-version')
    foreach ($tool in @(
        @('packwiz-installer-bootstrap.jar','a8fbb24dc604278e97f4688e82d3d91a318b98efc08d5dbfcbcbcab6443d116c'),
        @('packwiz-installer.jar','c9f646908d340d84773948a9a7d98bc1dae250d35e1016dc6e2b8459760b5598'))) {
        if ((Hash (Join-Path $toolsDir $tool[0])) -ne $tool[1]) { throw 'Pinned updater tool is missing or corrupt.' }
    }
    $stage = Join-Path $control ('stage-' + [Guid]::NewGuid().ToString('N'))
    $stageGame = Join-Path $stage 'minecraft'
    [IO.Directory]::CreateDirectory($stageGame) | Out-Null
    $originalMmc = Join-Path ([IO.Path]::GetDirectoryName($game)) 'mmc-pack.json'
    if (-not (Test-Path -LiteralPath $originalMmc)) { throw 'mmc-pack.json is missing.' }
    $platform = Read-Json $originalMmc
    if (@($platform.components | Where-Object { $_.uid -eq 'net.minecraft' })[0].version -ne '1.21.1' -or
        @($platform.components | Where-Object { $_.uid -eq 'net.neoforged' })[0].version -ne '21.1.233') {
        throw 'Local platform differs from the validated release.'
    }
    Copy-Item -LiteralPath $originalMmc -Destination (Join-Path $stage 'mmc-pack.json')
    foreach ($file in $previous.files) {
        $source = Managed-Path $game $file.path
        $target = Managed-Path $stageGame $file.path
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Ensure-Parent $target
            Copy-Item -LiteralPath $source -Destination $target
        }
    }
    # No cached manifest: standard installer checks actual file contents every run.
    Run-Java -Arguments @('-jar', (Join-Path $toolsDir 'packwiz-installer-bootstrap.jar'),
        '--bootstrap-no-update', '--bootstrap-main-jar', (Join-Path $toolsDir 'packwiz-installer.jar'),
        '-g', '-s', 'client', '--pack-folder', $stageGame, '--multimc-folder', $stage,
        '--meta-file', 'packwiz.json', $PackUrl)
    if ((Hash $originalMmc) -ne (Hash (Join-Path $stage 'mmc-pack.json'))) {
        throw 'Remote release tried to change Minecraft or loader. Manual upgrade required.'
    }
    $desired = Read-Json (Join-Path $stageGame 'pack-release.json')
    Validate-Catalog $desired $stageGame $true
    Validate-Catalog $desired $game
    $oldMap = @{}; $newMap = @{}; $changes = @()
    foreach ($file in $previous.files) { $oldMap[$file.path] = $file }
    foreach ($file in $desired.files) {
        $newMap[$file.path] = $file
        $target = Managed-Path $game $file.path
        if (-not $oldMap.ContainsKey($file.path) -and (Test-Path -LiteralPath $target) -and (Hash $target) -ne $file.sha256) {
            throw "New managed file conflicts with a personal file: $($file.path)"
        }
        if ((Hash $target) -ne $file.sha256) { $changes += $file.path }
    }
    foreach ($file in $previous.files) {
        if (-not $newMap.ContainsKey($file.path) -and (Test-Path -LiteralPath (Managed-Path $game $file.path))) {
            $changes += $file.path
        }
    }
    if ($changes.Count -eq 0) {
        Write-Json $currentPath $desired
        Write-Host "[Pack] $($desired.version): verified, no changes."
    } else {
        [IO.Directory]::CreateDirectory($transaction) | Out-Null
        Assert-NoLinks $transaction
        $entries = @()
        foreach ($relative in $changes) {
            $target = Managed-Path $game $relative
            $existed = Test-Path -LiteralPath $target -PathType Leaf
            $entries += @{path=$relative; existed=[bool]$existed}
            if ($existed) {
                $backup = Managed-Path (Join-Path $transaction 'backup') $relative
                Ensure-Parent $backup
                Copy-Item -LiteralPath $target -Destination $backup -Force
            }
        }
        $stateExisted = Test-Path -LiteralPath $currentPath
        if ($stateExisted) { Copy-Item -LiteralPath $currentPath -Destination (Join-Path $transaction 'previous.json') -Force }
        Write-Json (Join-Path $transaction 'journal.json') @{entries=$entries; stateExisted=[bool]$stateExisted}
        foreach ($relative in $changes) {
            $destination = Managed-Path $game $relative
            if ($newMap.ContainsKey($relative)) {
                Ensure-Parent $destination
                Copy-Item -LiteralPath (Managed-Path $stageGame $relative) -Destination $destination -Force
            } else { Remove-Item -LiteralPath $destination -Force }
        }
        Validate-Catalog $desired $game $true
        Write-Json $currentPath $desired
        Remove-Item -LiteralPath (Join-Path $transaction 'journal.json') -Force
        Write-Host "[Pack] $($desired.version): updated $($changes.Count) managed files."
    }
    # Verify the absolute staging target before recursive cleanup; never delete the game root.
    if ([IO.Path]::GetFullPath($stage).StartsWith($control + '\stage-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    exit 0
} catch {
    $failure = $_.Exception.Message
    if ($lock) {
        try { Recover-Transaction } catch { $failure += ' Rollback needs attention: ' + $_.Exception.Message }
    }
    Write-Host "[Pack] Launch stopped: $failure"
    Write-Host '[Pack] Existing files were preserved or rolled back. Retry when the source is available.'
    exit 1
} finally {
    if (Get-Variable stage -ErrorAction SilentlyContinue) {
        if ([IO.Path]::GetFullPath($stage).StartsWith($control + '\stage-', [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $stage)) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($process) { $process.Dispose() }
    if ($lock) { $lock.Dispose() }
}
