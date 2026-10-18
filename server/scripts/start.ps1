# Demarrage complet de Scoot Route sous Windows (double-cliquez sur "Demarrer Scoot Route.cmd").
# - lance Docker Desktop si besoin
# - cree le fichier .env au premier lancement
# - telecharge la carte de Lyon si elle manque
# - demarre serveur + tunnel, puis ouvre la page du code de liaison
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

function Test-Docker {
    try { docker info *> $null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

if (-not (Test-Docker)) {
    Write-Host "-> Demarrage de Docker Desktop..."
    $exe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
    if (Test-Path $exe) { Start-Process $exe }
    $deadline = (Get-Date).AddMinutes(4)
    while (-not (Test-Docker)) {
        if ((Get-Date) -gt $deadline) {
            Write-Host "ERREUR : Docker Desktop ne demarre pas. Ouvrez-le a la main puis relancez." -ForegroundColor Red
            Read-Host "Appuyez sur Entree pour fermer"; exit 1
        }
        Start-Sleep -Seconds 5
    }
}

if (-not (Test-Path ".env")) {
    Write-Host "-> Creation du fichier .env"
    $token = -join ((48..57) + (97..122) | Get-Random -Count 32 | ForEach-Object { [char]$_ })
    (Get-Content ".env.example") -replace '^ADMIN_TOKEN=.*', "ADMIN_TOKEN=$token" | Set-Content ".env" -Encoding ascii
}

if (-not (Test-Path "data\lyon.osm.pbf")) {
    & powershell -ExecutionPolicy Bypass -File "scripts\prepare-osm.ps1"
    if ($LASTEXITCODE -ne 0) { Read-Host "Appuyez sur Entree pour fermer"; exit 1 }
}

Write-Host "-> Demarrage du serveur et du tunnel (la premiere fois : 10 a 15 minutes)..."
docker compose up -d --build
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERREUR au demarrage. Envoyez la sortie de : docker compose logs --tail 40" -ForegroundColor Red
    Read-Host "Appuyez sur Entree pour fermer"; exit 1
}

Write-Host "-> Attente de l'adresse publique..."
$deadline = (Get-Date).AddMinutes(5)
do {
    Start-Sleep -Seconds 5
    try { $meta = Invoke-RestMethod -Uri "http://localhost:8080/v1/meta" -TimeoutSec 5 } catch { $meta = $null }
} until (($meta -and $meta.public_url) -or (Get-Date) -gt $deadline)

if ($meta -and $meta.public_url) {
    Write-Host ("OK : serveur joignable sur " + $meta.public_url) -ForegroundColor Green
} else {
    Write-Host "Le tunnel n'est pas encore pret : la page de liaison se mettra a jour toute seule." -ForegroundColor Yellow
}
Start-Process "http://localhost:8080/liaison"
Write-Host "Tout redemarrera automatiquement avec Docker Desktop. Vous pouvez fermer cette fenetre."
Start-Sleep -Seconds 8
