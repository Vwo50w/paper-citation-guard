<#
.SYNOPSIS
    把本仓库安装为 DSH 技能（用户级或项目级）。
.EXAMPLE
    pwsh -File install.ps1
    安装到 %USERPROFILE%\.dsh\skills\paper-citation-guard
.EXAMPLE
    pwsh -File install.ps1 -DshHome "D:\myproject\.dsh"
    安装到项目级目录
#>
param(
    [string]$DshHome = "$env:USERPROFILE\.dsh",
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$dst = Join-Path $DshHome 'skills\paper-citation-guard'

Write-Host ''
Write-Host '安装 paper-citation-guard' -ForegroundColor Cyan
Write-Host "  源目录：$src"
Write-Host "  目标：  $dst"
Write-Host ''

if (Test-Path $dst) {
    if (-not $Force) {
        Write-Host "目标已存在。加 -Force 覆盖（会保留已有的 config.json）" -ForegroundColor Yellow
        exit 1
    }
    $backup = "$dst.bak-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -Recurse -Force $dst $backup
    Write-Host "  已备份到 $backup" -ForegroundColor DarkGray
}

[void][System.IO.Directory]::CreateDirectory($dst)

# 复制时跳过运行时产物
$skip = @('cache', 'config.json', '.git')
Get-ChildItem -Path $src -Force | Where-Object { $_.Name -notin $skip } | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination $dst -Recurse -Force
}

# 保留原有配置
$cfgDst = Join-Path $dst 'config.json'
if (-not (Test-Path $cfgDst) -and (Test-Path (Join-Path $src 'config.json'))) {
    Copy-Item (Join-Path $src 'config.json') $cfgDst
}

Write-Host '安装完成。下一步：' -ForegroundColor Green
Write-Host "  pwsh -File `"$dst\scripts\refcheck.ps1`" doctor -InitConfig"
Write-Host ''
Write-Host '如果是新会话，需要在 DSH 里重开会话才会加载这个技能。' -ForegroundColor DarkGray