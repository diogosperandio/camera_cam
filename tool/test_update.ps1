$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $RepoRoot
try {
    $Bundle = 'build\windows\x64\runner\Release'
    $InstallDir = 'build\update-test\toshiba_flashair_wifi_viewer'
    $Helper = 'toshiba_flashair_wifi_viewer_updater.exe'

    flutter build windows --release `
        --dart-define=GITHUB_REPO=diogosperandio/camera_cam
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart pub get --directory tool/updater
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    dart compile exe tool/updater/bin/updater.dart -o "$Bundle\$Helper"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Set-Content -Path "$Bundle\portable.txt" -Encoding utf8 -Value `
        'Instalação portátil do Toshiba FlashAir WiFi Viewer. Não apague: permite a atualização automática.'

    if ($InstallDir -notlike 'build\update-test\*') {
        throw "Destino de teste inseguro: $InstallDir"
    }
    if (Test-Path $InstallDir) {
        Remove-Item -Recurse -Force $InstallDir
    }
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    Copy-Item -Recurse -Force "$Bundle\*" $InstallDir

    $env:TOSHIBA_FLASHAIR_WIFI_VIEWER_PRETEND_VERSION = '0.0.0'
    & "$InstallDir\toshiba_flashair_wifi_viewer.exe"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Remove-Item Env:TOSHIBA_FLASHAIR_WIFI_VIEWER_PRETEND_VERSION `
        -ErrorAction SilentlyContinue
    Pop-Location
}
