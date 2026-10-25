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
        $Relative -ne 'config/create_connected-common.toml' -and
        $Relative -ne 'resourcepacks/chronicle_client_fixes_ru_v1.zip' -and
        $Relative -ne 'shaderpacks/ComplementaryReimagined_r5.9.3.zip' -and
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
function Platform-Identity($Metadata) {
    # Cached display/dependency metadata is refreshed by the launcher during prelaunch.
    # Only component identities select the executable platform; never promote this file.
    $seen = @{}
    $components = @($Metadata.components | ForEach-Object {
        if ($_.uid -isnot [string] -or [string]::IsNullOrWhiteSpace($_.uid) -or
            $_.version -isnot [string] -or [string]::IsNullOrWhiteSpace($_.version) -or
            $seen.ContainsKey($_.uid)) { throw 'Invalid local platform component identity.' }
        $seen[$_.uid] = $true
        [ordered]@{uid=$_.uid; version=$_.version}
    } | Sort-Object { $_.uid })
    if ($components.Count -eq 0) { throw 'Missing local platform components.' }
    return (ConvertTo-Json -InputObject $components -Compress -Depth 4)
}
function Validate-Catalog($Catalog, [string]$Root, [bool]$CheckFiles = $false) {
    if ($Catalog.format -ne 1 -or $Catalog.platform.minecraft -ne '1.21.1' -or
        $Catalog.platform.neoforge -notin @('21.1.233', '21.1.256') -or $Catalog.platform.java -ne 21) {
        throw 'Unsupported platform: a separately validated manual release is required.'
    }
    $localMetadata = Read-Json (Join-Path ([IO.Path]::GetDirectoryName($Root)) 'mmc-pack.json')
    Platform-Identity $localMetadata | Out-Null
    $localMinecraft = @($localMetadata.components | Where-Object { $_.uid -eq 'net.minecraft' })
    $localNeoForge = @($localMetadata.components | Where-Object { $_.uid -eq 'net.neoforged' })
    if ($localMinecraft.Count -ne 1 -or $localNeoForge.Count -ne 1 -or
        $localMinecraft[0].version -cne $Catalog.platform.minecraft -or
        $localNeoForge[0].version -cne $Catalog.platform.neoforge) {
        throw 'Catalog platform differs from this instance. A manual migration is required.'
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
function Invoke-ClientKeyMigration([string]$GameDirectory, [switch]$InitializeMissing) {
    # Fixed, once-only repair of known default conflicts. No downloadable recipe.
    $root = [IO.Path]::GetFullPath($GameDirectory).TrimEnd('\')
    $stateDir = Join-Path $root '.pack-update'
    $optionsPath = Join-Path $root 'options.txt'
    $markerPath = Join-Path $stateDir 'key-conflicts-20261026-v2.json'
    $backupPath = Join-Path $stateDir 'key-conflicts-20261026-v2.options.before'
    $recipe = 'known-key-conflicts-20261026-v2'
    $rules = [ordered]@{
        'key_key.jade.config' = @('key.keyboard.keypad.0', 'key.keyboard.f12')
        'key_key.jade.show_overlay' = @('key.keyboard.keypad.1', 'key.keyboard.keypad.6')
        'key_key.jade.toggle_liquid' = @('key.keyboard.keypad.2', 'key.keyboard.keypad.decimal')
        'key_key.jade.show_recipes' = @('key.keyboard.keypad.3', 'key.keyboard.keypad.add')
        'key_key.jade.show_uses' = @('key.keyboard.keypad.4', 'key.keyboard.keypad.subtract')
        'key_key.jade.narrate' = @('key.keyboard.keypad.5', 'key.keyboard.pause')
        'key_placebo.toggleWings' = @('key.keyboard.keypad.8', 'key.keyboard.keypad.divide')
        'key_placebo.toggleTrails' = @('key.keyboard.keypad.9', 'key.keyboard.keypad.multiply')
    }
    function Assert-KeyPath([string]$Path) {
        $cursor = [IO.Path]::GetFullPath($Path)
        while ($cursor) {
            if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Client key repair paths cannot contain links.'
            }
            $cursor = [IO.Path]::GetDirectoryName($cursor)
        }
    }
    function Key-Hash([byte[]]$Bytes) {
        $algorithm = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($algorithm.ComputeHash($Bytes)).Replace('-','').ToLowerInvariant() }
        finally { $algorithm.Dispose() }
    }
    function Write-KeyBytes([string]$Path, [byte[]]$Bytes) {
        Assert-KeyPath $Path
        $temporary = Join-Path $stateDir ('key-write-' + [Guid]::NewGuid().ToString('N') + '.new')
        try {
            [IO.File]::WriteAllBytes($temporary, $Bytes)
            if (Test-Path -LiteralPath $Path) {
                [IO.File]::Replace($temporary, $Path, (Join-Path $stateDir ('key-previous-' + [Guid]::NewGuid().ToString('N'))))
            } else { [IO.File]::Move($temporary, $Path) }
        } finally {
            if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
        }
    }
    foreach ($path in @($optionsPath, $markerPath, $backupPath)) {
        Assert-KeyPath $path
        if (Test-Path -LiteralPath $path -PathType Container) { throw 'Expected a regular key repair file.' }
    }
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $marker = $null
    if (Test-Path -LiteralPath $markerPath) {
        $marker = [IO.File]::ReadAllText($markerPath, $utf8) | ConvertFrom-Json
        if ($marker.format -ne 1 -or $marker.id -cne $recipe -or $marker.phase -notin @('prepared','applied') -or
            $marker.beforeSha256 -cnotmatch '^[a-f0-9]{64}$' -or $marker.afterSha256 -cnotmatch '^[a-f0-9]{64}$' -or
            @($marker.changedKeys).Count -gt 8 -or @($marker.changedKeys | Where-Object { -not $rules.Contains($_) }).Count -gt 0) {
            throw 'Invalid client key repair state; keep its private backup.'
        }
        if ($marker.phase -eq 'applied') { return }
    }
    if (-not (Test-Path -LiteralPath $optionsPath -PathType Leaf)) {
        if ($marker) { throw 'Interrupted key repair is missing options.txt.' }
        return
    }
    $raw = [IO.File]::ReadAllBytes($optionsPath)
    $beforeHash = Key-Hash $raw
    if ($marker) {
        if (-not (Test-Path -LiteralPath $backupPath) -or (Key-Hash ([IO.File]::ReadAllBytes($backupPath))) -cne $marker.beforeSha256) {
            throw 'Interrupted client key repair backup is incomplete.'
        }
        if ($beforeHash -ceq $marker.afterSha256) {
            $marker.phase = 'applied'
            Write-KeyBytes $markerPath ($utf8.GetBytes(($marker | ConvertTo-Json -Depth 4)))
            return
        }
        if ($beforeHash -cne $marker.beforeSha256) { throw 'Options changed during an interrupted key repair; preserve the backup and review manually.' }
    }
    $text = $utf8.GetString($raw)
    $hasBom = $text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF
    if ($hasBom) { $text = $text.Substring(1) }
    $bindings = @{}
    foreach ($match in [Regex]::Matches($text, '(?m)^(key_[^:\r\n]+):([^\r\n]*)')) {
        $key = $match.Groups[1].Value
        if ($rules.Contains($key) -and $bindings.ContainsKey($key)) { throw 'Duplicate target key in options.txt.' }
        $bindings[$key] = $match.Groups[2].Value
    }
    # Only a positively qualified mod set may initialize implicit defaults.
    if (-not $InitializeMissing) {
        foreach ($key in $rules.Keys) { if (-not $bindings.ContainsKey($key)) { return } }
    }
    $lineEnd = [string][char]10
    if ($text.Contains(([string][char]13 + [char]10))) { $lineEnd = [string][char]13 + [char]10 }
    $changed = @()
    $occupied = @()
    foreach ($key in $rules.Keys) {
        $oldValue, $newValue = $rules[$key]
        $missing = -not $bindings.ContainsKey($key)
        if (-not $missing -and $bindings[$key] -cne $oldValue) { continue }
        $other = @($bindings.Keys | Where-Object { $_ -cne $key -and $bindings[$_].Split(':')[0] -ceq $newValue })
        if ($other.Count -gt 0) { $occupied += $key; continue }
        if ($missing) {
            if ($text.Length -gt 0 -and -not $text.EndsWith([string][char]10, [StringComparison]::Ordinal)) { $text += $lineEnd }
            $text += $key + ':' + $newValue + $lineEnd
        } else {
            $pattern = '(?m)^(?<prefix>' + [Regex]::Escape($key) + ':)' + [Regex]::Escape($oldValue) + '(?<end>\r?)$'
            $text = [Regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator]{
                param($match)
                return $match.Groups['prefix'].Value + $newValue + $match.Groups['end'].Value
            })
        }
        $bindings[$key] = $newValue
        $changed += $key
    }
    $next = $utf8.GetBytes($text)
    if ($hasBom) { $next = [byte[]](@(0xEF,0xBB,0xBF) + @($next)) }
    $afterHash = Key-Hash $next
    if ($marker -and $afterHash -cne $marker.afterSha256) { throw 'Interrupted key repair no longer matches its fixed recipe.' }
    Assert-KeyPath $stateDir
    [IO.Directory]::CreateDirectory($stateDir) | Out-Null
    $state = [ordered]@{format=1; id=$recipe; phase='applied'; beforeSha256=$beforeHash; afterSha256=$afterHash; changedKeys=@($changed); occupiedDestinations=@($occupied)}
    if ($changed.Count -gt 0) {
        if (Test-Path -LiteralPath $backupPath) {
            if ((Key-Hash ([IO.File]::ReadAllBytes($backupPath))) -cne $beforeHash) { throw 'An earlier key repair backup must be preserved.' }
        } else { Write-KeyBytes $backupPath $raw }
        if ((Key-Hash ([IO.File]::ReadAllBytes($optionsPath))) -cne $beforeHash) { throw 'Options changed before key repair commit.' }
        $state.phase = 'prepared'
        Write-KeyBytes $markerPath ($utf8.GetBytes(($state | ConvertTo-Json -Depth 4)))
        Write-KeyBytes $optionsPath $next
    }
    $state.phase = 'applied'
    Write-KeyBytes $markerPath ($utf8.GetBytes(($state | ConvertTo-Json -Depth 4)))
    Write-Host "[Pack] Client keys: fixed $($changed.Count) known default conflicts; personal bindings retained."
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
        @($platform.components | Where-Object { $_.uid -eq 'net.neoforged' })[0].version -notin @('21.1.233', '21.1.256')) {
        throw 'Local platform differs from the validated release.'
    }
    Copy-Item -LiteralPath $originalMmc -Destination (Join-Path $stage 'mmc-pack.json')
    $stagedPlatformHash = Hash (Join-Path $stage 'mmc-pack.json')
    $platformIdentity = Platform-Identity $platform
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
    if ($stagedPlatformHash -ne (Hash (Join-Path $stage 'mmc-pack.json')) -or
        $platformIdentity -cne (Platform-Identity (Read-Json $originalMmc))) {
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
    if ($settings.mode -eq 'AUTO' -and $desired.platform.neoforge -ceq '21.1.256' -and
        $desired.version -cmatch '^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}$' -and [version]$desired.version -ge [version]'1.1.4') {
        $keyRepairJade = @($desired.files | Where-Object { $_.path -imatch '^mods/Jade-[^/]+\.jar$' }).Count -gt 0
        $keyRepairPlacebo = @($desired.files | Where-Object { $_.path -imatch '^mods/Placebo-[^/]+\.jar$' }).Count -gt 0
        if ($keyRepairJade -and $keyRepairPlacebo) { Invoke-ClientKeyMigration $game -InitializeMissing }
    }
    # Verify the absolute staging target before recursive cleanup; never delete the game root.
    if ([IO.Path]::GetFullPath($stage).StartsWith($control + '\stage-', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stage -Recurse -Force
    }
    exit 0
} catch {
    $failure = $_.Exception.Message
    $rollbackNeedsAttention = $false
    if ($lock) {
        try { Recover-Transaction } catch {
            $rollbackNeedsAttention = $true
            $failure += ' Rollback needs attention: ' + $_.Exception.Message
        }
    }
    Write-Host "[Pack] Launch stopped: $failure"
    if ($rollbackNeedsAttention) {
        Write-Host '[Pack] Recovery is incomplete. Keep the transaction backups and contact the pack owner before launching.'
    } else {
        Write-Host '[Pack] Verified files and recovery backups were retained. Retry before launching.'
    }
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
