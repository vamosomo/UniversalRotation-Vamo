# sync-from-game.ps1
# Copies all .lua files from the in-game test folder into the git repo,
# then shows what changed so you can commit before shutting down.

$gameDir = "C:\diablo_qqt\scripts\UniversalRotation-1.0.25"
$repoDir = "C:\CodingApps\UniversalRotation-Vamo"

Write-Host ""
Write-Host "Syncing from game folder to repo..." -ForegroundColor Cyan
Write-Host "  From: $gameDir"
Write-Host "  To:   $repoDir"
Write-Host ""

$copied = 0
$unchanged = 0

Get-ChildItem -Path $gameDir -Recurse -Filter "*.lua" | ForEach-Object {
    $relativePath = $_.FullName.Substring($gameDir.Length + 1)
    $dest = Join-Path $repoDir $relativePath

    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir | Out-Null
    }

    $sourceHash = (Get-FileHash $_.FullName -Algorithm MD5).Hash
    $destHash   = if (Test-Path $dest) { (Get-FileHash $dest -Algorithm MD5).Hash } else { "" }

    if ($sourceHash -ne $destHash) {
        Copy-Item $_.FullName $dest -Force
        Write-Host "  UPDATED  $relativePath" -ForegroundColor Yellow
        $copied++
    } else {
        Write-Host "  unchanged $relativePath" -ForegroundColor DarkGray
        $unchanged++
    }
}

Write-Host ""
Write-Host "$copied file(s) updated, $unchanged unchanged." -ForegroundColor Cyan
Write-Host ""

Set-Location $repoDir
$status = git status --short
if ($status) {
    Write-Host "Git status (files ready to commit):" -ForegroundColor Green
    $status | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Next step: tell Claude to commit and push, or run:" -ForegroundColor White
    Write-Host '  git add -A; git commit -m "your message here"; git push origin main' -ForegroundColor DarkCyan
} else {
    Write-Host "Git status: nothing to commit - repo already matches game folder." -ForegroundColor Green
}
Write-Host ""
