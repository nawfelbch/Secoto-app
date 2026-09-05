# ============================================================================
# SECOTO - correctif 025 : publication iOS en 1.5 (le train 1.4 est ferme)
# ----------------------------------------------------------------------------
#   cd C:\Users\33651\secoto-app
#   powershell -ExecutionPolicy Bypass -File .\PUSH-025.ps1
#
# Puis relancer le workflow iOS dans Codemagic.
# ============================================================================
$ErrorActionPreference = "Stop"
Set-Location "C:\Users\33651\secoto-app"

Remove-Item ".git\index.lock" -Force -ErrorAction SilentlyContinue

Write-Host "Verification des versions..." -ForegroundColor Cyan
node --test tests/ci-native-config.test.js
if ($LASTEXITCODE -ne 0) { throw "les versions declarees ne concordent pas." }

git add codemagic.yaml
git add ios/App/App/Info.plist
git add ios/App/App.xcodeproj/project.pbxproj
git add COMMIT-025.txt
git add PUSH-025.ps1

git commit -F COMMIT-025.txt
if ($LASTEXITCODE -ne 0) { throw "le commit a echoue." }

git push origin main
if ($LASTEXITCODE -ne 0) { throw "le push a echoue." }

Write-Host ""
Write-Host "Version 1.5 poussee. Relancez maintenant le workflow iOS dans Codemagic." -ForegroundColor Green
