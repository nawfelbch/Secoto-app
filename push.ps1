<#
================================================================================
 SECOTO - Script de push (Windows PowerShell / PowerShell 7+)
--------------------------------------------------------------------------------
 Role : commit + push des modifications de l'app SECOTO sur la branche
        principale, ce qui declenche automatiquement le build Netlify
        (app.secoto-transport.fr).

 Usage :
     ./push.ps1                          # message de commit par defaut
     ./push.ps1 -RepoPath "C:\dev\Secoto-app"
     ./push.ps1 -Message "feat: bareme auto + frais reels + documents"
     ./push.ps1 -DryRun                  # simulation, aucun push

 Gestion d'erreur : arret propre (exit code != 0) a la moindre anomalie.
================================================================================
#>

[CmdletBinding()]
param(
    # Dossier local du repo. Par defaut : dossier du script.
    [string]$RepoPath = $PSScriptRoot,

    # Message de commit.
    [string]$Message = "feat(secoto): bareme tarifaire auto, module frais reels, generation documents + signature, RLS de cloisonnement, correctifs UI iOS",

    # Branche cible.
    [string]$Branch = "main",

    # Nom du remote.
    [string]$Remote = "origin",

    # Simulation : montre ce qui serait fait sans rien pousser.
    [switch]$DryRun
)

# Arret immediat sur erreur non geree.
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers d'affichage
# ---------------------------------------------------------------------------
function Write-Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "  [OK] $m"   -ForegroundColor Green }
function Write-Warn($m) { Write-Host "  [!]  $m"   -ForegroundColor Yellow }
function Fail($m) {
    Write-Host "`n[ECHEC] $m" -ForegroundColor Red
    exit 1
}

# Execute une commande git et echoue proprement si le code retour != 0.
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    Write-Host "  > git $($GitArgs -join ' ')" -ForegroundColor DarkGray
    # git ecrit ses messages d'info (progression, 'From ...') sur stderr : on
    # bascule temporairement en Continue pour que ces lignes ne soient PAS
    # traitees comme des erreurs fatales. Seul le code retour fait foi.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -ne 0) {
        $output | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
        Fail "La commande 'git $($GitArgs -join ' ')' a echoue (code $code)."
    }
    return $output
}

# ---------------------------------------------------------------------------
# 0. Verifications prealables
# ---------------------------------------------------------------------------
Write-Step "Verifications prealables"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git n'est pas installe ou introuvable dans le PATH."
}
Write-Ok "git detecte : $((git --version) -join '')"

if (-not (Test-Path -LiteralPath $RepoPath)) {
    Fail "Le dossier du repo est introuvable : $RepoPath"
}

# Se placer dans le repo.
try { Set-Location -LiteralPath $RepoPath }
catch { Fail "Impossible d'acceder au dossier : $RepoPath" }
Write-Ok "Dossier courant : $(Get-Location)"

# Verifier qu'on est bien dans un depot git.
& git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    Fail "$RepoPath n'est pas un depot git."
}

# ---------------------------------------------------------------------------
# 1. Etat du depot
# ---------------------------------------------------------------------------
Write-Step "git status"

# Verifier la branche courante.
$currentBranch = (Invoke-Git rev-parse --abbrev-ref HEAD).Trim()
Write-Ok "Branche courante : $currentBranch"
if ($currentBranch -ne $Branch) {
    Fail "Branche courante '$currentBranch' != branche cible '$Branch'. Basculez avec 'git checkout $Branch' avant de relancer."
}

# Interdire un etat inattendu (merge/rebase en cours).
if ((Test-Path (Join-Path $RepoPath ".git\MERGE_HEAD")) -or
    (Test-Path (Join-Path $RepoPath ".git\rebase-merge")) -or
    (Test-Path (Join-Path $RepoPath ".git\rebase-apply"))) {
    Fail "Un merge ou rebase est en cours. Terminez-le avant de pousser."
}

# Afficher l'etat lisible.
Invoke-Git status | ForEach-Object { Write-Host "    $_" }

# Y a-t-il quelque chose a committer ?
$porcelain = (& git status --porcelain) -join "`n"
if ([string]::IsNullOrWhiteSpace($porcelain)) {
    Write-Warn "Aucune modification a committer. Rien a pousser - arret propre."
    exit 0
}

# ---------------------------------------------------------------------------
# 2. Synchronisation avec le distant (evite un push rejete)
# ---------------------------------------------------------------------------
Write-Step "Synchronisation avec $Remote/$Branch"
Invoke-Git fetch $Remote $Branch | Out-Null
Write-Ok "Fetch effectue."

# ---------------------------------------------------------------------------
# 3. Ajout + commit
# ---------------------------------------------------------------------------
Write-Step "Ajout des fichiers modifies"
if ($DryRun) {
    Write-Warn "DryRun : 'git add -A' et 'git commit' non executes."
    & git status --short | ForEach-Object { Write-Host "    (serait ajoute) $_" }
} else {
    Invoke-Git add -A
    Write-Ok "Fichiers indexes."

    Write-Step "Commit"
    Invoke-Git commit -m $Message | ForEach-Object { Write-Host "    $_" }
    Write-Ok "Commit cree : $Message"
}

# ---------------------------------------------------------------------------
# 4. Push
# ---------------------------------------------------------------------------
Write-Step "Push vers $Remote/$Branch"
if ($DryRun) {
    Write-Warn "DryRun : 'git push' non execute."
} else {
    Invoke-Git push $Remote $Branch | ForEach-Object { Write-Host "    $_" }
    Write-Ok "Push effectue sur $Remote/$Branch."
}

# ---------------------------------------------------------------------------
# 5. Confirmation du build Netlify
# ---------------------------------------------------------------------------
Write-Step "Deploiement Netlify"
if ($DryRun) {
    Write-Warn "DryRun : aucun build declenche."
} else {
    $commitHash = (Invoke-Git rev-parse --short HEAD).Trim()
    Write-Ok "Le push du commit $commitHash declenche automatiquement le build Netlify."
    Write-Host "  -> Suivi du build : https://app.netlify.com  (site relie a app.secoto-transport.fr)" -ForegroundColor Cyan
    Write-Host "  -> Verification en ligne une fois le deploiement termine : https://app.secoto-transport.fr" -ForegroundColor Cyan
}

Write-Host "`nTermine avec succes." -ForegroundColor Green
exit 0
