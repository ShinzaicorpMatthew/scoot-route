#!/usr/bin/env bash
# Télécharge l'extrait OpenStreetMap Rhône-Alpes (Geofabrik, mis à jour quotidiennement)
# et le découpe sur la métropole de Lyon avec osmium.
#
# Usage : ./scripts/prepare-osm.sh            (depuis le dossier server/)
# Prérequis : curl, osmium-tool (brew install osmium-tool / apt install osmium-tool)
#             ou Docker (le script utilise l'image osmium si la commande est absente)
set -euo pipefail

DATA_DIR="${DATA_DIR:-./data}"
# Emprise : métropole de Lyon + marge (minLon,minLat,maxLon,maxLat)
BBOX="${BBOX:-4.65,45.55,5.10,45.95}"
SOURCE_URL="${SOURCE_URL:-https://download.geofabrik.de/europe/france/rhone-alpes-latest.osm.pbf}"

mkdir -p "$DATA_DIR"
echo "→ Téléchargement de $SOURCE_URL"
curl -fL --retry 3 -o "$DATA_DIR/region.osm.pbf.tmp" "$SOURCE_URL"
mv "$DATA_DIR/region.osm.pbf.tmp" "$DATA_DIR/region.osm.pbf"

echo "→ Découpage sur l'emprise $BBOX"
if command -v osmium >/dev/null 2>&1; then
  osmium extract --bbox "$BBOX" --strategy complete_ways --overwrite \
    -o "$DATA_DIR/lyon.osm.pbf" "$DATA_DIR/region.osm.pbf"
else
  docker run --rm -v "$(cd "$DATA_DIR" && pwd)":/data debian:stable-slim sh -c \
    "apt-get update -qq && apt-get install -y -qq osmium-tool >/dev/null && \
     osmium extract --bbox '$BBOX' --strategy complete_ways --overwrite \
       -o /data/lyon.osm.pbf /data/region.osm.pbf"
fi

rm -f "$DATA_DIR/region.osm.pbf"
echo "✓ Extrait prêt : $DATA_DIR/lyon.osm.pbf"
