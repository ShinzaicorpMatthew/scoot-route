# Scoot Route — Architecture technique et choix des fournisseurs

*Version MVP — octobre 2026 — périmètre : Lyon et sa métropole*

## 1. Vue d'ensemble

```
┌──────────────── iPhone (Swift / SwiftUI, iOS 17+) ────────────────┐
│ Saisie adresses ─ MapKit (autocomplétion, géocodage, carte)       │
│ Navigation ─ CoreLocation (GPS, arrière-plan) + AVSpeech (voix FR) │
│ Batterie, historique (SwiftData), profil : stockés sur l'iPhone    │
└───────────────┬────────────────────────────────────────────────────┘
                │ HTTPS  POST /v1/routes, /v1/reports
┌───────────────▼──────────── Serveur Scoot Route (Docker) ──────────┐
│ API Node.js (sans dépendance)                                      │
│  ├─ profils Rapide / Éco / Équilibré → modèles de coût             │
│  ├─ chantiers Métropole de Lyon (open data, rafraîchi toutes 6 h)  │
│  ├─ signalements livreurs + modération (SQLite)                    │
│  └─ analyse : altitude IGN, pentes, segments, fiabilité            │
│ GraphHopper 11 (auto-hébergé) ← OpenStreetMap (Geofabrik, 1×/jour) │
│                                ← SRTM (altitude du graphe)          │
└───────────────┬────────────────────────────────────────────────────┘
                └─ API altimétrie Géoplateforme IGN (RGE ALTI®, gratuite)
```

Pourquoi un serveur ? Les moteurs capables d'optimiser selon la pente ne tournent pas dans
MapKit, et le serveur garde la main sur les sources de données (chantiers, signalements validés)
sans exposer de clé dans l'application.

## 2. Comparaison des moteurs de routage

| Critère | GraphHopper | Valhalla | openrouteservice |
|---|---|---|---|
| Licence moteur | Apache 2.0 | MIT | GPL v3 |
| Coût de routage personnalisé | **Libre** : « custom models » (priorité et vitesse par tronçon, pente moyenne et maximale, surface, aménagements cyclables, zones GeoJSON) envoyés à chaque requête | Paramètres de coût prédéfinis (`use_hills`, `use_roads`, `avoid_bad_surfaces`, type de vélo) — fin mais pas libre | Profils figés (`cycling-electric`…) + quelques options (pente max, « steepness difficulty ») |
| Zones à éviter (chantiers) | Oui, polygones dans le modèle | Oui (`exclude_polygons`) | Oui (`avoid_polygons`) |
| Altitude | SRTM/CGIAR intégrés à l'import | Tuiles d'élévation | Intégrée |
| Hébergé (SaaS) | 500 crédits/jour gratuits, usage non commercial ; offres payantes ensuite | Via Stadia Maps : 200 000 crédits/mois gratuits (non commercial), à partir de 20 $/mois, 10 crédits par itinéraire | 2 000 itinéraires/jour gratuits (40/min) |
| Auto-hébergement | Simple (un .jar Java, quelques Go de RAM pour Lyon) | Plus lourd (construction des tuiles) | Lourd (Java + configuration Docker) |

**Choix : GraphHopper auto-hébergé.** C'est le seul des trois qui permet d'exprimer *directement*
la formule de coût multicritère du cahier des charges (temps + distance + pénalités de montée,
de pente, de surface, de sécurité, zones interdites), avec des poids modifiables à chaque requête.
L'auto-hébergement évite les quotas (trois profils + alternatives = 4 requêtes par calcul),
l'interdiction d'usage commercial des offres gratuites, et coûte quelques euros par mois.

Alternatives crédibles si l'hébergement devient une contrainte : Stadia Maps (Valhalla hébergé,
`use_hills` pour le profil Éco) ou l'API GraphHopper payante (mêmes custom models).

## 3. Données

| Donnée | Source | Fraîcheur | Licence |
|---|---|---|---|
| Voirie, pistes et bandes cyclables, sens uniques, accès, surfaces | OpenStreetMap via Geofabrik (extrait Rhône-Alpes découpé sur la métropole) | Extrait publié chaque jour ; graphe reconstruit chaque nuit (`scripts/update-map.sh`) | ODbL (attribution « © contributeurs OpenStreetMap ») |
| Altitude utilisée pour le **routage** | SRTM (via GraphHopper) | Statique | Domaine public |
| Altitude **affichée** (D+, D−, pentes) | API altimétrie Géoplateforme IGN, ressource RGE ALTI® | Statique | Licence Ouverte, sans clé, 5 req/s par IP |
| Chantiers perturbants | Métropole de Lyon (data.gouv.fr, GeoJSON) | Relu toutes les 6 h ; mise à jour à la discrétion de la Métropole | Licence Ouverte 2.0 |
| Signalements livreurs | Base Scoot Route | Immédiat après validation par un modérateur | — |

Aucune de ces sources n'est en temps réel. L'application l'affiche explicitement (« Carte OSM du …
· non temps réel », « Chantiers Métropole relevés le … ») et ne présente jamais un chemin comme
« ouvert à cet instant ». Aucune API de trafic temps réel gratuite et exploitable pour ce
cas d'usage n'a été identifiée sur Lyon ; c'est une évolution possible (voir §9).

**Ponts et tunnels** : un modèle de terrain donne l'altitude du sol (la Saône sous la passerelle).
L'API interpole l'altitude entre les deux extrémités de chaque pont ou tunnel avant de calculer
dénivelés et pentes.

## 4. Règles trottinette (EDPM) encodées

Modèle de base `server/graphhopper/custom_models/scooter.json` :

- **Exclus** : autoroutes et voies express, escaliers, accès privé ou interdit aux vélos, sens
  interdit (pas de contresens hors double-sens cyclable balisé), chemins VTT techniques, ferries.
- **Quasi exclus (×0,05) et signalés** : routes à plus de 50 km/h sans piste ni bande cyclable —
  en agglomération la chaussée n'est autorisée que jusqu'à 50 km/h, et hors agglomération seules
  les pistes et voies vertes le sont. OSM ne dit pas toujours où commence « l'agglomération » au
  sens légal ; d'où une pénalité forte plutôt qu'une exclusion, et un avertissement « accès incertain ».
- **Fortement pénalisés (×0,15) et signalés** : trottoirs et zones piétonnes (`get_off_bike`).
- **Vitesse** : plafonnée à 25 km/h (et à la vitesse de croisière du livreur), réduite sur pavés et
  sols non revêtus, en montée, et **limitée en descente** (20 puis 15 km/h) — une descente ne fait
  jamais gagner de temps ni de priorité.

## 5. Coût multicritère

Pour chaque tronçon, GraphHopper calcule `poids = durée / priorité + distance × distance_influence`.
`server/api/src/profiles.js` traduit les six poids utilisateur (0 à 1) ainsi :

| Critère | Traduction |
|---|---|
| Temps | durée du tronçon ; amortit aussi les autres pénalités (`× (1 − 0,6·w_temps)`) |
| Distance | `distance_influence = 10 + 140·w_distance` secondes par km |
| Montée | priorité `× (1 − w·k)` selon la pente moyenne : >2 % k=0,25 ; >4 % 0,5 ; >6 % 0,72 ; >9 % 0,9 |
| Pente raide | pente max du tronçon >10 % : k=0,75 ; >15 % : 0,95 |
| Surface | non revêtu k=0,85 ; pavés 0,6 ; revêtement dégradé 0,5 |
| Sécurité | grand axe sans aménagement k=0,6 ; route secondaire/tertiaire 0,3 |
| Restrictions | fermeture validée ×0 ; chantier ×0,2 ; règles EDPM ci-dessus |

Profils : **Rapide** (temps 1, montée 0,1), **Éco** (montée 1, pente 1, temps 0,2), **Équilibré**
(réglable par l'utilisateur). Si deux profils donnent le même tracé, ils sont fusionnés et le
serveur demande au moteur de vraies alternatives pour proposer au moins trois itinéraires.

Après calcul, chaque segment reçoit aussi un **coût explicite normalisé**
(1 unité = 1 minute = 250 m = 8 m de D+) :

```
coût = w_temps·min + w_distance·(m/250) + w_montée·(D+/8)
     + w_pente·pénalité_pente + w_surface·pénalité_surface + w_sécurité·pénalité_sécurité
     + pénalités de restriction
```

Ce coût, calculé avec les poids de l'utilisateur, désigne l'itinéraire « recommandé » ★.

## 6. Batterie

Modèle physique (`BatteryEstimator.swift`) : résistance au roulement (Crr 0,012) + traînée
aérodynamique (CdA 0,55 m²) × 1,25 (arrêts/redémarrages) × mode de conduite, plus
`m·g·D+` pour les montées, divisé par un rendement de 75 %. La récupération en descente n'est
comptée (10 % de l'énergie potentielle) que si la trottinette a un freinage régénératif.
Ordre de grandeur obtenu : ~10 Wh/km sur le plat à 20 km/h pour 96 kg.

Apprentissage : en fin de trajet, le livreur peut saisir le pourcentage affiché ; le rapport
consommation réelle / estimée alimente une moyenne mobile (bornée entre ×0,5 et ×2).

## 7. Navigation

- Projection de la position sur le tracé (fenêtre glissante, puis recherche globale).
- Sortie d'itinéraire : > max(30 m, 1,5 × précision GPS) sur 3 positions fiables consécutives
  (précision ≤ 50 m) → recalcul automatique avec le même profil et le cap actuel (8 s minimum
  entre deux tentatives).
- Annonces vocales françaises à ~150 m et ~30 m de chaque manœuvre ; alerte vocale et bandeau
  rouge 250 m avant un chantier ou un accès incertain.
- GPS perdu > 10 s : bandeau « signal faible », guidage conservé. Réseau perdu : guidage
  conservé, recalcul impossible signalé.
- Arrière-plan : `UIBackgroundModes location + audio`, `CLBackgroundActivitySession` (indicateur
  bleu iOS), écran maintenu allumé pendant la navigation.
- Sécurité : interface lisible d'un coup d'œil, guidage vocal, actions (signaler, réessayer)
  désactivées au-dessus de 6 km/h.

## 8. Sécurité et confidentialité

- Aucune clé secrète dans l'app. Le jeton `X-Client-Token` est un simple filtre anti-abus.
  Évolution recommandée avant publication : **App Attest** (DeviceCheck) côté serveur.
- Le serveur ne journalise pas les coordonnées des trajets. Historique et profil restent sur l'iPhone.
- Signalements : identifiant d'appareil anonyme, 20 par heure maximum, modération obligatoire
  (`ADMIN_TOKEN`) avant tout effet sur le routage, expiration automatique après 14 jours.
- Limitation de débit par IP sur l'API ; GraphHopper n'est pas exposé publiquement.

## 9. Évolutions prévues (étapes 7–8 du plan)

1. Campagne de tests terrain (voir README) et ajustement des coefficients sur ~50 trajets réels.
2. Contribution des signalements validés à OpenStreetMap (avec l'accord des livreurs).
3. Arrêtés de circulation temporaires de la Métropole s'ils sont publiés en open data géolocalisé.
4. App Attest, HTTPS de production (Caddy/Traefik), sauvegarde de la base des signalements.
5. Live Activity sur l'écran verrouillé, CarPlay non pertinent ; cartes hors ligne via tuiles
   vectorielles + petit moteur embarqué (chantier conséquent, hors MVP).
