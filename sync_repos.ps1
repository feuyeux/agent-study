# 自动同步多个仓库的PowerShell脚本
# 如果仓库不存在就clone，否则pull
# 优先使用gh命令，没有则使用git

$repos = @(
    "git@github.com:anthropics/codex.git",
    "git@github.com:anthropics/openclaw.git",
    "git@github.com:anthropics/gemini-cli.git",
    "git@github.com:anthropics/opencode.git",
    "git@github.com:anthropics/zeroclaw.git",
    "git@github.com:anthropics/claude-code.git"
)

$baseDir = "D:\coding\agent"
$useGh = $false

# 检查gh是否可用
if (Get-Command gh -ErrorAction SilentlyContinue) {
    $useGh = $true
    Write-Host "使用 gh 命令" -ForegroundColor Green
} else {
    Write-Host "gh 未安装，使用 git 命令" -ForegroundColor Yellow
}

foreach ($repoUrl in $repos) {
    # 从URL提取仓库名作为目录名
    $repoName = [System.IO.Path]::GetFileNameWithoutExtension($repoUrl)
    $repoPath = Join-Path $baseDir $repoName

    if (Test-Path $repoPath) {
        Write-Host "`n=== 更新 $repoName ===" -ForegroundColor Cyan
        Push-Location $repoPath
        if ($useGh) {
            gh repo sync
        } else {
            git pull
        }
        $exitCode = $LASTEXITCODE
        Pop-Location
        if ($exitCode -ne 0) {
            Write-Host "更新失败: $repoName" -ForegroundColor Red
        }
    } else {
        Write-Host "`n=== 克隆 $repoName ===" -ForegroundColor Cyan
        if ($useGh) {
            git clone $repoUrl $repoPath
        } else {
            git clone $repoUrl $repoPath
        }
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            Write-Host "克隆失败: $repoName" -ForegroundColor Red
        }
    }
}

Write-Host "`n完成!" -ForegroundColor Green
