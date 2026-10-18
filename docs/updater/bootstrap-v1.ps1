param(
    [string]$JavaPath = $env:INST_JAVA,
    [string]$GameDirectory = $PSScriptRoot
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$game = [IO.Path]::GetFullPath($GameDirectory).TrimEnd('\')
$tools = Join-Path $game 'pack-update-tools'
$control = Join-Path $game '.pack-update'
$lock = $null
$engineLimit = 262144

function Assert-RegularPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if ((Test-Path -LiteralPath $cursor) -and
            ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Updater paths cannot contain links.'
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}
function Read-Json([string]$Path) {
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}
function File-Hash([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
function Write-State([string]$Path, $Value) {
    Assert-RegularPath $Path
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.new'
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path) {
        Assert-RegularPath ($Path + '.previous')
        [IO.File]::Replace($temporary, $Path, ($Path + '.previous'))
    }
    else { [IO.File]::Move($temporary, $Path) }
}
function Fetch-Bytes([Uri]$Uri, [int]$Limit) {
    $request = [Net.HttpWebRequest]::Create($Uri)
    $request.AllowAutoRedirect = $false
    $request.Timeout = 15000
    $request.ReadWriteTimeout = 15000
    $response = $null
    $memory = [IO.MemoryStream]::new()
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt $Limit) {
            throw 'Unexpected updater response or payload size.'
        }
        $stream = $response.GetResponseStream()
        $buffer = New-Object byte[] 8192
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($elapsed.ElapsedMilliseconds -gt 30000) { throw 'Updater transfer exceeded its time limit.' }
            if ($memory.Length + $count -gt $Limit) { throw 'Updater payload exceeds its limit.' }
            $memory.Write($buffer, 0, $count)
        }
        return ,$memory.ToArray()
    } finally {
        if ($response) { $response.Dispose() }
        $memory.Dispose()
    }
}
function Engine-Path([string]$Hash) {
    if ($Hash -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid updater engine hash.' }
    $path = Join-Path $tools ('engines\' + $Hash + '\Update-Pack.ps1')
    Assert-RegularPath $path
    return $path
}
function Run-Engine([string]$Path) {
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $shell -NoProfile -ExecutionPolicy Bypass -File $Path -JavaPath $JavaPath -GameDirectory $game
    if ($LASTEXITCODE -ne 0) { throw "Updater engine stopped launch (exit $LASTEXITCODE)." }
}

try {
    Assert-RegularPath $game
    Assert-RegularPath $tools
    Assert-RegularPath $control
    [IO.Directory]::CreateDirectory($control) | Out-Null
    $lock = [IO.File]::Open((Join-Path $control 'bootstrap.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    $configPath = Join-Path $tools 'bootstrap.json'
    Assert-RegularPath $configPath
    $config = Read-Json $configPath
    if ($config.format -ne 1 -or $config.baselineSha256 -cnotmatch '^[a-f0-9]{64}$') {
        throw 'Unsupported bootstrap configuration.'
    }
    $settingsPath = Join-Path $tools 'settings.json'
    Assert-RegularPath $settingsPath
    $settings = Read-Json $settingsPath
    if ($settings.mode -notin @('AUTO', 'PINNED', 'MANUAL')) { throw 'Unknown pack update mode.' }
    if ($settings.mode -ne 'AUTO') {
        $baseline = Engine-Path $config.baselineSha256
        if ((File-Hash $baseline) -ne $config.baselineSha256) { throw 'Bundled updater engine is corrupt.' }
        Run-Engine $baseline
        exit 0
    }

    $channel = [Uri]$config.channel
    if (-not $channel.IsAbsoluteUri -or $channel.UserInfo -or $channel.Query -or $channel.Fragment -or
        -not $channel.AbsolutePath.EndsWith('/manifest.json') -or
        ($channel.Scheme -ne 'https' -and -not ($channel.Scheme -eq 'http' -and $channel.IsLoopback))) {
        throw 'Updater channel must be an HTTPS manifest (HTTP is allowed only on loopback fixtures).'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $manifestBytes = Fetch-Bytes $channel 16384
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    if ($manifest.format -ne 1 -or $manifest.minimumBootstrap -ne 1 -or
        $manifest.sequence -isnot [ValueType] -or $manifest.sequence -is [bool] -or $manifest.sequence -le 0 -or
        [decimal]$manifest.sequence -ne [decimal][long]$manifest.sequence -or
        $manifest.bytes -isnot [ValueType] -or $manifest.bytes -is [bool] -or $manifest.bytes -le 0 -or $manifest.bytes -gt $engineLimit -or
        [decimal]$manifest.bytes -ne [decimal][int]$manifest.bytes -or
        $manifest.sha256 -isnot [string] -or $manifest.sha256 -cnotmatch '^[a-f0-9]{64}$' -or
        $manifest.version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw 'Unsupported updater manifest.'
    }
    $relative = 'engines/' + $manifest.sha256 + '/Update-Pack.ps1'
    if ($manifest.engine -cne $relative) { throw 'Engine path must match its content hash.' }
    $currentPath = Join-Path $control 'engine-current.json'
    Assert-RegularPath $currentPath
    $current = if (Test-Path -LiteralPath $currentPath) { Read-Json $currentPath } else { $null }
    if ($current -and ($manifest.sequence -lt $current.sequence -or
        ($manifest.sequence -eq $current.sequence -and $manifest.sha256 -cne $current.sha256))) {
        throw 'Updater rollback or reused sequence rejected.'
    }
    $engine = Engine-Path $manifest.sha256
    if ((File-Hash $engine) -ne $manifest.sha256) {
        $engineUri = [Uri]::new([Uri]::new($channel, '.'), $relative)
        $payload = Fetch-Bytes $engineUri $engineLimit
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $hash = [BitConverter]::ToString($sha.ComputeHash($payload)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if ($payload.Length -ne $manifest.bytes -or $hash -cne $manifest.sha256) {
            throw 'Updater engine size or SHA-256 differs from the manifest.'
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($engine)) | Out-Null
        Assert-RegularPath $engine
        $temporary = $engine + '.' + [Guid]::NewGuid().ToString('N') + '.new'
        [IO.File]::WriteAllBytes($temporary, $payload)
        if (Test-Path -LiteralPath $engine) {
            Assert-RegularPath ($engine + '.previous')
            [IO.File]::Replace($temporary, $engine, ($engine + '.previous'))
        }
        else { [IO.File]::Move($temporary, $engine) }
    }
    if ((Get-Item -LiteralPath $engine).Length -ne $manifest.bytes) { throw 'Cached engine size differs.' }
    Run-Engine $engine
    Write-State $currentPath @{sequence=[long]$manifest.sequence; sha256=$manifest.sha256; version=$manifest.version}
    exit 0
} catch {
    Write-Host "[Pack bootstrap] Launch stopped: $($_.Exception.Message)"
    Write-Host '[Pack bootstrap] The previous engine remains available. No automatic retry with another engine was made.'
    exit 1
} finally {
    if ($lock) { $lock.Dispose() }
}
