param(
  [switch]$SkipPreviews
)

$ErrorActionPreference = "Stop"

$kitDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceDir = Join-Path $kitDir "sources"
$previewDir = Join-Path $kitDir "previews"

$chromeCandidates = @(
  "C:\Program Files\Google\Chrome\Application\chrome.exe",
  "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
  "C:\Program Files\Microsoft\Edge\Application\msedge.exe",
  "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"
)

$chrome = $chromeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $chrome) {
  throw "Chrome ou Edge est requis pour générer les PDF."
}

New-Item -ItemType Directory -Path $previewDir -Force | Out-Null

function Wait-ForGeneratedFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$TimeoutSeconds = 20
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  do {
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -gt 0) {
      return
    }
    Start-Sleep -Milliseconds 150
  } while ((Get-Date) -lt $deadline)

  throw "Le fichier attendu n'a pas été généré : $Path"
}

$documents = @(
  @{
    Source = "fiche-commerciale.html"
    Output = "SECOTO_Fiche_Commerciale_Pro.pdf"
    Prefix = "fiche"
    Pages = 2
  },
  @{
    Source = "dossier-solution.html"
    Output = "SECOTO_Dossier_Solution_Entreprises.pdf"
    Prefix = "dossier"
    Pages = 7
  },
  @{
    Source = "proposition-commerciale.html"
    Output = "SECOTO_Modele_Proposition_Commerciale.pdf"
    Prefix = "proposition"
    Pages = 5
  }
)

foreach ($document in $documents) {
  $sourcePath = Join-Path $sourceDir $document.Source
  $outputPath = Join-Path $kitDir $document.Output
  $sourceUri = [System.Uri]::new($sourcePath).AbsoluteUri
  if (Test-Path -LiteralPath $outputPath) {
    Remove-Item -LiteralPath $outputPath -Force
  }

  $printArgs = @(
    "--headless=new",
    "--disable-gpu",
    "--allow-file-access-from-files",
    "--no-pdf-header-footer",
    "--print-to-pdf=$outputPath",
    $sourceUri
  )

  & $chrome @printArgs
  Wait-ForGeneratedFile -Path $outputPath

  if (-not $SkipPreviews) {
    for ($page = 1; $page -le $document.Pages; $page++) {
      $previewPath = Join-Path $previewDir ("{0}-{1:00}.png" -f $document.Prefix, $page)
      $previewUri = "${sourceUri}?preview=$page"
      if (Test-Path -LiteralPath $previewPath) {
        Remove-Item -LiteralPath $previewPath -Force
      }
      $screenArgs = @(
        "--headless=new",
        "--disable-gpu",
        "--hide-scrollbars",
        "--allow-file-access-from-files",
        "--force-device-scale-factor=1",
        "--window-size=794,1123",
        "--screenshot=$previewPath",
        $previewUri
      )

      & $chrome @screenArgs
      Wait-ForGeneratedFile -Path $previewPath
    }
  }
}

Write-Host "PDF générés dans : $kitDir"
if (-not $SkipPreviews) {
  Write-Host "Prévisualisations générées dans : $previewDir"
}
