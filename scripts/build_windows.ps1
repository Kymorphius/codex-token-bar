param([switch]$SkipBundledRssHub)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$projectFile = Join-Path $projectRoot "windows\CodexTokenBar.Windows\CodexTokenBar.Windows.csproj"
$publishDirectory = Join-Path $projectRoot "dist\windows-x64"
$generatedDirectory = Join-Path $projectRoot "windows\CodexTokenBar.Windows\Generated"
$bundleDirectory = Join-Path $projectRoot "dist\rsshub-runtime-win-x64"
$fullRuntimeDirectory = Join-Path $projectRoot "dist\rsshub-runtime-full-win-x64"
$bundleArchive = Join-Path $generatedDirectory "rsshub-runtime-win-x64.zip"

if (-not $SkipBundledRssHub) {
  $npm = Get-Command "npm.cmd" -ErrorAction Stop
  $node = Get-Command "node.exe" -ErrorAction Stop
  Remove-Item -LiteralPath $fullRuntimeDirectory -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $bundleDirectory -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Path $fullRuntimeDirectory -Force | Out-Null
  Push-Location $fullRuntimeDirectory
  try {
    & $npm.Source init -y | Out-Null
    & $npm.Source install --omit=dev --no-audit --no-fund "rsshub@1.0.0-master.8aeb46b"
  } finally {
    Pop-Location
  }
  $tracePath = Join-Path $fullRuntimeDirectory "rsshub-module-trace.txt"
  $traceOutputPath = Join-Path $fullRuntimeDirectory "rsshub-trace-output.txt"
  $runnerPath = Join-Path $projectRoot "Resources\rsshub-runner.mjs"
  $loaderPath = Join-Path $projectRoot "scripts\rsshub-trace-loader.mjs"
  $loaderUrl = ([System.Uri]::new($loaderPath)).AbsoluteUri
  $modulePath = Join-Path $fullRuntimeDirectory "node_modules\rsshub\dist-lib\pkg.mjs"
  $previousTracePath = $env:CODEX_RSSHUB_TRACE_FILE
  $env:CODEX_RSSHUB_TRACE_FILE = $tracePath
  '{"authToken":"invalid-build-trace-token"}' | & $node.Source `
    --no-warnings `
    --experimental-loader $loaderUrl `
    $runnerPath `
    $modulePath `
    '/twitter/user/thsottiaux/includeReplies=0&includeRts=0&readable=1' `
    1> $traceOutputPath
  $env:CODEX_RSSHUB_TRACE_FILE = $previousTracePath
  & $node.Source `
    (Join-Path $projectRoot "scripts\prune_rsshub_runtime.mjs") `
    $fullRuntimeDirectory `
    $bundleDirectory `
    $tracePath
  Copy-Item -LiteralPath (Join-Path $fullRuntimeDirectory "package.json") -Destination $bundleDirectory
  Copy-Item -LiteralPath (Join-Path $fullRuntimeDirectory "package-lock.json") -Destination $bundleDirectory
  Copy-Item -LiteralPath $node.Source -Destination (Join-Path $bundleDirectory "node.exe")
  Copy-Item -LiteralPath $runnerPath -Destination $bundleDirectory
  Set-Content -LiteralPath (Join-Path $bundleDirectory ".codex-tibo-slim-version") -Value "1.0.0-master.8aeb46b/slim-v1"
  New-Item -ItemType Directory -Path $generatedDirectory -Force | Out-Null
  Remove-Item -LiteralPath $bundleArchive -Force -ErrorAction SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory(
    $bundleDirectory,
    $bundleArchive,
    [System.IO.Compression.CompressionLevel]::Fastest,
    $false
  )
  Write-Host "Bundled RSSHub runtime: $bundleArchive"
}

dotnet publish $projectFile `
  --configuration Release `
  --runtime win-x64 `
  --self-contained true `
  -p:PublishSingleFile=true `
  -p:DebugType=None `
  -p:DebugSymbols=false `
  --output $publishDirectory

Write-Host "Windows build: $publishDirectory\CodexTokenBar.exe"

$innoCompiler = Get-Command "ISCC.exe" -ErrorAction SilentlyContinue
$innoCompilerPath = if ($null -ne $innoCompiler) {
  $innoCompiler.Source
} else {
  $standardInnoPath = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
  if (Test-Path -LiteralPath $standardInnoPath) { $standardInnoPath } else { $null }
}
if ($null -ne $innoCompilerPath) {
  & $innoCompilerPath (Join-Path $projectRoot "windows\installer.iss")
  Write-Host "Installer: $projectRoot\dist\CodexTokenBar-Windows-x64-Setup.exe"
} else {
  Write-Host "Inno Setup not found; skipped installer creation. The portable EXE is ready."
}
