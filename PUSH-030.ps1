# ============================================================================
# SECOTO - 030 : transport a la demande, abonnement professionnel, suivi
# ----------------------------------------------------------------------------
#   cd C:\Users\33651\secoto-app
#   powershell -ExecutionPolicy Bypass -File .\PUSH-030.ps1
#
# Pousse la BRANCHE feature/secoto-030-transport-abonnement-suivi (jamais main).
# Rien n'est active en production : les cinq interrupteurs de
# public.secoto_feature_flags valent false tant que vous ne les ouvrez pas.
# ============================================================================
$ErrorActionPreference = "Stop"
Set-Location "C:\Users\33651\secoto-app"

Remove-Item ".git\index.lock" -Force -ErrorAction SilentlyContinue

$branche = "feature/secoto-030-transport-abonnement-suivi"
$courante = (git rev-parse --abbrev-ref HEAD).Trim()
if ($courante -ne $branche) { throw "branche courante '$courante' : placez-vous sur $branche (git checkout $branche)." }

Write-Host "1/3 Tests..." -ForegroundColor Cyan
npm test
if ($LASTEXITCODE -ne 0) { throw "des tests echouent : rien n'est pousse." }

Write-Host "2/3 Lint..." -ForegroundColor Cyan
npm run lint
if ($LASTEXITCODE -ne 0) { throw "le lint echoue : rien n'est pousse." }

Write-Host "3/3 Build..." -ForegroundColor Cyan
npm run build
if ($LASTEXITCODE -ne 0) { throw "le build echoue : rien n'est pousse." }

git add COMMIT-030.txt PUSH-030.ps1 deliverables/SECOTO-030-a-coller-dans-Supabase.sql
git commit -m "chore(030): script de publication et SQL a coller" --allow-empty
git push -u origin $branche
if ($LASTEXITCODE -ne 0) { throw "le push a echoue." }

Write-Host ""
Write-Host "Branche poussee. Suite :" -ForegroundColor Green
Write-Host "  1. Sauvegarde PITR Supabase, puis coller deliverables\SECOTO-030-a-coller-dans-Supabase.sql" -ForegroundColor Gray
Write-Host "  2. Verifier : select key, enabled from public.secoto_feature_flags;  (tout doit etre false)" -ForegroundColor Gray
Write-Host "  3. Netlify : deploiement de previsualisation de la branche + variables (voir le fichier deliverables\secoto-030-transport-abonnement-suivi.md)" -ForegroundColor Gray
Write-Host "  4. Activer les interrupteurs un par un depuis l'espace admin, ecran 'A la demande'" -ForegroundColor Gray
Write-Host ""
Write-Host "Aucune fusion vers main n'est faite par ce script." -ForegroundColor Yellow
