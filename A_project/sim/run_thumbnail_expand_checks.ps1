param([string]$OutputDirectory, [switch]$FullRaster)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $env:TEMP ('a_thumbnail_expand_tests_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$runtime = Join-Path $OutputDirectory 'runtime'
New-Item -ItemType Directory -Path $runtime, (Join-Path $OutputDirectory 'doc/validation') -Force | Out-Null
function Invoke-Simulation([string]$Binary, [string]$Log) {
    Push-Location -LiteralPath $runtime
    try {
        & vvp -i $Binary | Tee-Object -FilePath $Log
        if ($LASTEXITCODE -ne 0) { throw "Simulation failed: $Binary" }
    } finally { Pop-Location }
}
$tests = @('tb_zoom_filter', 'tb_thumbnail_expand', 'tb_thumbnail', 'tb_transition_switch',
    'tb_multi_transition', 'tb_directory_flow', 'tb_directory_animation', 'tb_ui_controls',
    'tb_audio_selection', 'tb_alarm_glow', 'tb_boot_overlay', 'tb_no_signal')
$sources = @('src/user_source/hdl_source/extension/player_control.v',
    'src/user_source/hdl_source/extension/thumbnail_video.v',
    'src/user_source/hdl_source/SD/frame_read_write.v', 'sim/eg_bram32k_model.v',
    'src/user_source/hdl_source/IP/afifo_32_16_256.v',
    'src/user_source/hdl_source/IP/afifo_16_32_256.v')
Push-Location -LiteralPath $projectRoot
try {
    foreach ($test in $tests) {
        $binary = Join-Path $OutputDirectory ($test + '.vvp')
        $compileLog = Join-Path $OutputDirectory ($test + '.compile.log')
        & iverilog -g2012 -s $test -y src/user_source/hdl_source/extension -y src/user_source/hdl_source/SD -o $binary ('sim/' + $test + '.v') @sources *> $compileLog
        if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath $compileLog; throw "$test compile failed" }
        Invoke-Simulation $binary (Join-Path $OutputDirectory ($test + '.log'))
    }
    if ($FullRaster) {
        $binary = Join-Path $OutputDirectory 'tb_zoom_frame.vvp'
        & iverilog -g2012 -s tb_zoom_frame -y src/user_source/hdl_source/extension -y src/user_source/hdl_source/SD -o $binary sim/tb_zoom_frame.v @sources
        if ($LASTEXITCODE -ne 0) { throw 'tb_zoom_frame compile failed' }
        Invoke-Simulation $binary (Join-Path $OutputDirectory 'tb_zoom_frame.log')
    }
} finally { Pop-Location }
