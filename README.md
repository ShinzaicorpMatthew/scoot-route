# Scoot Route

Application iPhone native (Swift/SwiftUI) qui calcule pour les livreurs en trottinette électrique
trois itinéraires comparables — **Rapide**, **Éco** (moins de montée) et **Équilibré** — avec
dénivelé, pentes, pistes cyclables, chantiers connus et batterie estimée, puis guide en GPS avec
voix française et recalcul automatique. Zone couverte par le MVP : **Lyon et sa métropole**.

Les itinéraires sont réels : moteur GraphHopper sur données OpenStreetMap, altitude IGN,
chantiers de la Métropole de Lyon. Rien n'est simulé dans l'application.

→ Choix techniques, comparaison des fournisseurs, formule de coût : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## Contenu

```
scoot-route/
├── server/                     Serveur de routage (Docker)
│   ├── graphhopper/            Moteur + règles trottinette (custom_models/scooter.json)
│   ├── api/                    API Scoot Route (Node.js 22, sans dépendance) + 26 tests
│   ├── scripts/                Téléchargement/découpage OSM, mise à jour nocturne
│   ├── docker-compose.yml
│   └── .env.example
├── ios/                        Application iPhone
│   ├── project.yml             Projet Xcode (XcodeGen)
│   ├── Config/                 URL du serveur, identifiants (xcconfig)
│   ├── ScootRoute/             Code source SwiftUI
│   └── ScootRouteTests/        Tests unitaires
├── .github/workflows/ci.yml    Tests + build iPhone dans le cloud (GitHub Actions)
└── codemagic.yaml              Build + TestFlight dans le cloud (Codemagic)
```

---

## 1. Lancer le serveur (Windows, macOS ou Linux)

Prérequis : **Docker Desktop** (sous Windows, avec le moteur WSL 2) et ~4 Go de RAM libres.

```powershell
cd server
copy .env.example .env          # puis éditez .env : ADMIN_TOKEN au minimum
powershell -ExecutionPolicy Bypass -File scripts\prepare-osm.ps1    # Windows
# ./scripts/prepare-osm.sh                                         # macOS / Linux
docker compose up -d --build
```

Le premier démarrage construit le graphe (téléchargement SRTM + import OSM) : comptez 5 à
15 minutes. Suivez-le avec `docker compose logs -f graphhopper`. Vérification :

```powershell
curl.exe http://localhost:8080/health
curl.exe http://localhost:8080/v1/meta
curl.exe -X POST http://localhost:8080/v1/routes -H "content-type: application/json" `
  -d '{\"from\":{\"lat\":45.7578,\"lon\":4.8320},\"to\":{\"lat\":45.7745,\"lon\":4.8325}}'
```

(Le dernier exemple : place Bellecour → plateau de la Croix-Rousse ; le profil Éco doit
proposer moins de dénivelé que le profil Rapide.)

Tests de l'API : `cd server/api && npm test` (Node ≥ 22.13).

**Mise à jour de la carte** : `scripts/update-map.sh` re-télécharge OSM et reconstruit le graphe
(à planifier chaque nuit sur un serveur Linux via cron).

### Rendre le serveur accessible à l'iPhone (HTTPS)

iOS exige HTTPS hors réseau local. Deux options :

- **Pour tester (gratuit, immédiat)** : [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/)
  `cloudflared tunnel --url http://localhost:8080` affiche une adresse `https://…trycloudflare.com`
  (elle change à chaque lancement ; votre PC doit rester allumé).
- **Pour rouler au quotidien** : un petit VPS Linux (4 Go de RAM) avec Docker, le même
  `docker compose up -d`, et un reverse-proxy HTTPS (Caddy : deux lignes de configuration, certificat
  automatique).

### Modérer les signalements

```bash
curl -H "Authorization: Bearer $ADMIN_TOKEN" http://localhost:8080/admin/reports
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" http://localhost:8080/admin/reports/12/validate
curl -X POST -H "Authorization: Bearer $ADMIN_TOKEN" http://localhost:8080/admin/reports/12/reject
```

Une fermeture validée (« chemin fermé », « accès impossible ») est évitée par tous les calculs
pendant 14 jours (`{"ttl_days": 30}` pour changer la durée).

---

## 2. Configurer l'application

Copiez `ios/Config/Local.xcconfig.example` en `ios/Config/Local.xcconfig` :

| Clé | Rôle | Exemple |
|---|---|---|
| `SCOOT_API_BASE_URL` | Adresse HTTPS du serveur. **Écrire `https:/$()/` au lieu de `https://`** (dans un .xcconfig, `//` commence un commentaire) | `https:/$()/abc.trycloudflare.com` |
| `SCOOT_CLIENT_TOKEN` | Identique à `CLIENT_TOKEN` du serveur (facultatif, anti-abus, pas un secret) | |
| `DEVELOPMENT_TEAM` | Identifiant d'équipe Apple | `ABCDE12345` |
| `PRODUCT_BUNDLE_IDENTIFIER` | Identifiant unique de l'app | `fr.votrenom.scootroute` |

L'adresse du serveur peut aussi être changée **dans l'app** (Réglages > Adresse du serveur),
sans recompiler : pratique avec le tunnel Cloudflare gratuit, dont l'adresse change à chaque lancement.

Côté serveur (`server/.env`) : `ADMIN_TOKEN` (obligatoire, `openssl rand -hex 32`),
`CLIENT_TOKEN`, `WORKS_GEOJSON_URL`, `IGN_ELEVATION`, `COVERAGE_BBOX`, `RATE_LIMIT_PER_MIN`.
**Aucune clé d'API payante n'est nécessaire** : MapKit, l'IGN, la Métropole et OSM sont
utilisés sans clé.

---

## 3. Compiler et installer sur un vrai iPhone

Une app iOS native se compile **uniquement avec Xcode sur macOS**. Depuis un PC Windows, trois voies :

### Option A — Avec un Mac (le plus simple si vous y avez accès)
1. Installez Xcode (App Store) et XcodeGen : `brew install xcodegen`.
2. `cd ios && xcodegen generate && open ScootRoute.xcodeproj`
3. Branchez l'iPhone, activez **Réglages > Confidentialité et sécurité > Mode développeur**.
4. Dans Xcode : *Signing & Capabilities* → votre compte Apple (un identifiant gratuit suffit pour
   tester ; l'app expire alors après 7 jours), choisissez l'iPhone, ▶︎.
5. Tests unitaires : ⌘U.

Un Mac loué à l'heure dans le cloud (MacinCloud, AWS EC2 Mac…) convient aussi.

### Option B — Depuis Windows, via Codemagic + TestFlight (recommandé pour un usage réel)
Prérequis : compte **Apple Developer Program** (99 €/an).
1. Poussez ce dossier sur un dépôt GitHub/GitLab (privé si vous voulez).
2. Sur [App Store Connect](https://appstoreconnect.apple.com) : créez l'app avec votre identifiant
   de bundle, et une **clé API** (Utilisateurs et accès > Intégrations).
3. Sur [Codemagic](https://codemagic.io) : connectez le dépôt, ajoutez la clé API sous le nom
   `ScootRouteASC`, puis adaptez `codemagic.yaml` (bundle id, URL du serveur).
4. Lancez le workflow **Scoot Route → TestFlight** : compilation, tests, signature et envoi
   automatiques (plan gratuit : 500 minutes macOS par mois, un build ≈ 10 min).
5. Sur l'iPhone, installez **TestFlight** et acceptez l'invitation : l'app s'installe et se met à jour.

### Option C — Depuis Windows, sans abonnement Apple (dépannage)
Le workflow GitHub Actions (`.github/workflows/ci.yml`) compile et teste l'app à chaque push et
publie un **.ipa non signé** (onglet *Actions > Artifacts*). Il faut ensuite le signer avec votre
identifiant Apple gratuit à l'aide d'un outil tiers de « sideloading » pour Windows : l'app
expire après 7 jours, et ces outils ne sont ni d'Apple ni de nous — à n'utiliser qu'en
connaissance de cause. Sur un dépôt public, GitHub Actions est gratuit.

---

## 4. Tester sur le terrain (étape 7 du plan)

Avant de rouler : Profil → modèle, capacité batterie (Wh), % restant, vitesse de croisière.
Réglages → vérifiez que « Sources des données » affiche bien la date de la carte et des chantiers.

| Scénario | Ce qu'on vérifie |
|---|---|
| Bellecour → Croix-Rousse (montée de la Grande-Côte) | Éco < Rapide en D+ ; pentes max cohérentes avec le terrain ; zones piétonnes signalées |
| Vieux-Lyon → Fourvière | Rampe raide signalée en orange ; batterie estimée en hausse nette |
| Traversée Rhône/Saône par un pont | Pas de faux dénivelé sur le pont |
| Itinéraire longeant un chantier listé par la Métropole | Bandeau rouge et alerte vocale ~250 m avant |
| Quitter volontairement le tracé | Recalcul après ~3 positions, annonce « Nouvel itinéraire » |
| Écran verrouillé pendant le trajet | Le guidage vocal continue |
| Mode avion en cours de route | Bandeau « Hors ligne », guidage maintenu |
| Fin de trajet | Saisir la batterie réelle → le facteur d'ajustement apparaît dans Profil |
| Coller un texte d'adresse / un lien Apple Plans ou Google Maps | Destination reconnue, point d'accès à valider |

Notez chaque écart (chemin impraticable, accès interdit non détecté, pente mal estimée) via
l'onglet **Signaler** : ce sont les données qui permettront d'ajuster les coefficients.

### Envoyer une adresse depuis une autre app
L'app expose l'action **« Itinéraire Scoot Route »** dans l'app Raccourcis. Créez un raccourci
qui l'utilise et activez *Afficher dans la feuille de partage* (entrée : texte, URL) : vous pouvez
alors partager une adresse ou un lien de carte vers Scoot Route. Les liens
`scootroute://go?q=<adresse>` ouvrent aussi l'app. L'app ne lit jamais les données d'Uber Eats :
pas d'API publique pour les adresses des courses, et ni scraping ni automatisation.

---

## 4 bis. Savoir si une offre Uber Eats est rentable

### Peut-on lire l'offre directement, sans image ? Non (vérifié en octobre 2026)

| Piste | Verdict | Pourquoi |
|---|---|---|
| API Driver d'Uber | Impossible | Profil, gains et historique des courses **terminées** seulement ; accès sur demande, fermé. Aucune offre en attente. |
| API Uber Eats (Marketplace) | Impossible | Réservée aux restaurants (menus, commandes, magasins). Rien pour les livreurs. |
| Uber Direct | Impossible | Pour les commerçants qui commandent des livraisons. |
| Lire l'écran, les notifications ou la mémoire d'Uber Driver | Impossible | iOS isole chaque app ; pas d'équivalent aux services d'accessibilité d'Android. |
| Partage, presse-papiers, lien, raccourci exposé par Uber Driver | Impossible | Uber Driver ne propose rien de tel pour les offres. |
| **Diffusion d'écran ReplayKit** (extension « Broadcast Upload ») | **Faisable** | API publique d'Apple. Le livreur la lance une fois ; l'extension reçoit les images de l'écran. C'est de la **lecture d'écran**, pas un accès aux données. |
| Capture + raccourci « toucher le dos » | Faisable | Déjà en place : un geste par offre. |

### Utilisation

1. **Veille des offres** (recommandé) : onglet **Offre › Démarrer ou arrêter la veille › Commencer la diffusion**,
   au début du service. Chaque offre qui s'affiche dans Uber Driver est lue sur l'iPhone (Vision, ~1 image / 1,5 s,
   rien n'est enregistré ni envoyé) et la décision arrive en **notification** en 1 à 2 s. Si le serveur répond, la
   notification est mise à jour avec le vrai trajet trottinette (relief compris).
2. **Raccourci** « Prendre une capture d'écran » → « Analyser une offre de course », lancé par
   **Toucher le dos** (Réglages › Accessibilité › Toucher).
3. **Capture** choisie dans Photos depuis l'onglet Offre.

### Décision

- Données vérifiées d'abord : montant, distance, durée et vitesse moyenne plausible. Sinon : **⚠️ Analyse incomplète**.
- **✅ ACCEPTER** si le gain horaire et le gain au km atteignent vos seuils d'acceptation ;
  **❌ REFUSER** sous l'un des seuils de refus (ou batterie insuffisante) ; **🟠 À ÉVALUER** entre les deux.
- Seuils, attente au restaurant, remise, **frais variables / km** et **taux de cotisations** sont réglables dans
  l'onglet Offre. Les frais et cotisations ne sont comptés que si vous les renseignez. Les montants « après frais » et
  « après cotisations » sont des estimations, ni un bénéfice comptable, ni un revenu après impôt.
- Champs lus avec peu de confiance (restaurant réduit à une rue, montant flou…) : signalés **À vérifier**.

### Prérequis de la veille

- Notifications autorisées pour Scoot Route.
- Groupe d'apps `group.fr.scootroute.ScootRoute` (déclaré dans les droits de l'app et de l'extension) pour partager
  réglages, adresse du serveur et dernière position. Sans lui, la veille marche quand même, avec les seuils par défaut
  et la distance de l'offre (l'app l'indique).
- Compte Apple gratuit : l'extension compte comme un identifiant d'app de plus (limite de 10 par semaine).

## 5. Coûts estimés

| Poste | Coût |
|---|---|
| Routage GraphHopper auto-hébergé | 0 € (logiciel libre) |
| Données OSM, altitude IGN, chantiers Métropole | 0 € (licences ouvertes ; attribution affichée) |
| Recherche d'adresses et carte (MapKit) | 0 € (inclus dans iOS) |
| Hébergement serveur | 0 € sur votre PC (tests) · ≈ 4–7 €/mois pour un VPS 4 Go (ex. Hetzner CX23, tarifs revus en 2026) |
| Apple Developer Program (TestFlight, App Store) | 99 €/an — inutile pour un test de 7 jours avec un Mac |
| Build dans le cloud | Codemagic : 500 min macOS/mois gratuites, puis 0,095 $/min · GitHub Actions : gratuit sur dépôt public |
| **Total pour rouler au quotidien** | **≈ 13–16 €/mois** (VPS + abonnement Apple lissé) |

Si vous préférez une API hébergée plutôt qu'un serveur : Stadia Maps (Valhalla) dès 20 $/mois
pour un usage commercial, ou l'API GraphHopper (offres payantes, la formule gratuite est limitée
à 500 crédits/jour et à un usage non commercial) — il faudrait alors adapter
`server/api/src/graphhopper.js`.

---

## 6. Limites connues et solutions

| Limite | Conséquence | Solution proposée |
|---|---|---|
| Aucune source temps réel des fermetures de rues à Lyon accessible gratuitement | Une rue fermée ce matin n'est pas connue du calcul | Signalements livreurs modérés ; chantiers Métropole relus toutes les 6 h ; recalcul en roulant |
| Champs du jeu de données « chantiers perturbants » détectés automatiquement (dates de début/fin) | Si la Métropole change le format, les chantiers pourraient être tous inclus ou ignorés | Le serveur journalise les champs détectés au démarrage ; vérifier `GET /v1/meta` → `works` |
| « Agglomération » au sens légal absente d'OSM | Routes > 50 km/h seulement pénalisées, pas exclues | Avertissement « accès incertain » sur la fiche et en navigation |
| Altitude du routage en SRTM (~30–90 m de maille) | Choix d'itinéraire parfois imparfait sur de courtes rampes | Affichage recalculé en RGE ALTI (1–5 m) ; graphe en RGE ALTI possible plus tard (import de tuiles IGN) |
| Pas de cartes hors ligne | Pas de recalcul sans réseau | Le tracé déjà calculé reste suivi hors ligne |
| Batterie : modèle théorique au départ | Écart possible de ±30 % | Apprentissage à partir des relevés de fin de trajet |
| Code iOS non compilé dans l'environnement où il a été écrit (pas de Mac disponible) | De petites erreurs de compilation restent possibles au premier build | Le workflow CI compile et teste à chaque push ; corrigez sur la base de ses messages |

Données : © contributeurs OpenStreetMap (ODbL) · Métropole de Lyon (Licence Ouverte 2.0) ·
IGN RGE ALTI® (Licence Ouverte) · moteur GraphHopper (Apache 2.0).
