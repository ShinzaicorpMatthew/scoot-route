# Version Windows (PowerShell) de prepare-osm.sh - necessite Docker Desktop demarre.
# Usage, depuis le dossier server :   powershell -ExecutionPolicy Bypass -File scripts\prepare-osm.ps1
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # telechargement beaucoup plus rapide sous PowerShell 5

$DataDir = Join-Path (Get-Location) "data"
$Region = Join-Path $DataDir "region.osm.pbf"
$Output = Join-Path $DataDir "lyon.osm.pbf"
$Bbox = "4.65,45.55,5.10,45.95"   # metropole de Lyon + marge
$Source = "https://download.geofabrik.de/europe/france/rhone-alpes-latest.osm.pbf"

New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# 1. Docker doit fonctionner avant de commencer
$dockerOk = $true
try { docker info *> $null; if ($LASTEXITCODE -ne 0) { $dockerOk = $false } } catch { $dockerOk = $false }
if (-not $dockerOk) {
    Write-Host "ERREUR : Docker Desktop n'est pas demarre. Ouvrez Docker Desktop, attendez le voyant vert, puis relancez ce script." -ForegroundColor Red
    exit 1
}

# 2. Telechargement (saute si deja fait)
if (-not (Test-Path $Region)) {
    Write-Host "-> Telechargement de la carte Rhone-Alpes (~500 Mo, quelques minutes)..."
    Invoke-WebRequest -Uri $Source -OutFile "$Region.tmp"
    Move-Item "$Region.tmp" $Region -Force
} else {
    Write-Host "-> Carte deja telechargee, on la reutilise."
}

# 3. Decoupage sur Lyon
Write-Host "-> Decoupage sur la metropole de Lyon..."
docker run --rm -v "${DataDir}:/data" debian:stable-slim sh -c `
  "apt-get update -qq && apt-get install -y -qq osmium-tool >/dev/null && osmium extract --bbox '$Bbox' --strategy complete_ways --overwrite -o /data/lyon.osm.pbf /data/region.osm.pbf"

if ($LASTEXITCODE -ne 0 -or -not (Test-Path $Output)) {
    Write-Host "ERREUR : le decoupage a echoue. Le fichier telecharge est conserve ; relancez le script quand Docker fonctionne." -ForegroundColor Red
    exit 1
}

Remove-Item $Region
Write-Host "OK : carte de Lyon prete dans data\lyon.osm.pbf" -ForegroundColor Green
