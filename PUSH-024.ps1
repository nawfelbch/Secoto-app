# ============================================================================
# SECOTO - correctif 024 : candidatures, parcours terrain, organisation admin
# ----------------------------------------------------------------------------
#   cd C:\Users\33651\secoto-app
#   powershell -ExecutionPolicy Bypass -File .\PUSH-024.ps1
#
# ORDRE IMPERATIF :
#   1. appliquer d'abord le SQL dans Supabase (migration 024) ;
#   2. puis lancer ce script.
# La migration repare l'application DEJA INSTALLEE : elle est retro-compatible,
# elle peut donc etre appliquee sans redeployer quoi que ce soit.
# ============================================================================
$ErrorActionPreference = "Stop"
Set-Location "C:\Users\33651\secoto-app"

Remove-Item ".git\index.lock" -Force -ErrorAction SilentlyContinue

Write-Host "1/4  Tests..." -ForegroundColor Cyan
npm test
if ($LASTEXITCODE -ne 0) { throw "les tests ont echoue." }

Write-Host "2/4  Lint..." -ForegroundColor Cyan
npm run lint
if ($LASTEXITCODE -ne 0) { throw "le lint a echoue." }

Write-Host "3/4  Build..." -ForegroundColor Cyan
npm run build
if ($LASTEXITCODE -ne 0) { throw "le build a echoue." }

Write-Host "4/4  Commit et push..." -ForegroundColor Cyan

git add supabase/migrations/202609050024_reparation_candidatures_terrain.sql
git add src/App.jsx
git add src/AdminMissionControls.jsx
git add src/index.css
git add src/lib/applicationOffer.js
git add src/lib/fileSafety.js
git add src/lib/mappers.js
git add src/lib/privateFiles.js
git add src/lib/resilienceStore.js
git add tests/file-safety.test.js
git add tests/reparation-024.test.js
git add COMMIT-024.txt
git add PUSH-024.ps1

git commit -F COMMIT-024.txt
if ($LASTEXITCODE -ne 0) { throw "le commit a echoue." }

git push origin main
if ($LASTEXITCODE -ne 0) { throw "le push a echoue." }

Write-Host ""
Write-Host "Correctif 024 publie." -ForegroundColor Green
Write-Host "Netlify redeploie le web automatiquement." -ForegroundColor Green
Write-Host "Pour iOS/Android : relancez le workflow dans Codemagic." -ForegroundColor Yellow
Write-Host ""
Write-Host "Rappel : le SQL doit avoir ete applique AVANT ce push." -ForegroundColor Yellow
