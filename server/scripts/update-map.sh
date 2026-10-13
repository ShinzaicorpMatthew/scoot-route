#!/usr/bin/env bash
# Mise à jour périodique des données cartographiques (à lancer chaque nuit via cron).
# Exemple de crontab :  15 3 * * *  cd /opt/scoot-route/server && ./scripts/update-map.sh >> update.log 2>&1
#
# OpenStreetMap n'est PAS une source temps réel : ce script rafraîchit la carte au mieux
# une fois par jour (rythme de publication de Geofabrik).
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/prepare-osm.sh
# Le graphe doit être reconstruit pour prendre en compte le nouvel extrait
docker compose stop graphhopper
rm -rf ./data/graph-cache
docker compose up -d graphhopper
echo "✓ Graphe en cours de reconstruction ($(date -Iseconds))"
