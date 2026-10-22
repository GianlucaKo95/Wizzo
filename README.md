# Wizzo 🧙

Wizzo ist eine Online-Multiplayer-Umsetzung des Stichkartenspiels **Wizard** für 2–6 Spieler, verpackt als [Home Assistant Add-on](https://www.home-assistant.io/addons/). Es läuft als eigener Webserver in deinem Heimnetz (kein Cloud-Hosting nötig für die App selbst), spricht für Konten/Echtzeit-Sync/Datenhaltung mit einem [Supabase](https://supabase.com/)-Projekt und bringt optional einen selbst gehosteten Sprachchat mit.

Das Karten-Artwork und die Sonderkarten sind Harry-Potter-thematisiert (Häuser, Zauberer-/Narr-Charaktere, Sonderkarten wie "Bellatrix" für die Hexe). Das ist ein privates Fan-Projekt für den Eigengebrauch – nicht offiziell, nicht kommerziell, keine Verbindung zu Rechteinhabern.

> **iOS-App in Arbeit**: Wizzo wird aktuell zusätzlich als eigenständige, komplett native SwiftUI-App neu gebaut (kein Web-Wrapper) – sie soll die PWA/Home-Assistant-Weboberfläche langfristig ablösen. Stand, Architektur und Setup: [`docs/IOS.md`](docs/IOS.md). Bis dahin ist die hier beschriebene Web-App/PWA weiterhin der produktive Stand.

## Inhalt

- [Features](#features)
- [Architektur auf einen Blick](#architektur-auf-einen-blick)
- [Repository-Struktur](#repository-struktur)
- [Installation als Home Assistant Add-on](#installation-als-home-assistant-add-on)
- [Lokale Entwicklung](#lokale-entwicklung)
- [Tests](#tests)
- [CI/CD](#cicd)
- [Weiterführende Dokumentation](#weiterführende-dokumentation)
- [Status & Lizenz](#status--lizenz)

## Features

**Spiel**
- Online-Räume für 2–6 Spieler mit Beitrittscode, restliche Plätze werden mit KI-Gegnern aufgefüllt
- Zwei Editionen: **Classic** (klassisches 60-Karten-Deck) und **"30 Jahre"-Jubiläumsedition** (69 Karten, 9 Sonderkarten: Drache, Fee, Hexe, Werwolf, Vampir, Bombe, Jongleur 7½, Gleis 9¾, Zauberer-oder-Narr)
- Serverautoritatives Spiel – die komplette Regellogik (Stich-/Rundenauflösung, KI-Züge, Sonderkarten-Effekte) läuft in der Edge Function, der Client zeigt nur an und schickt Aktionen
- Server-truth-basiertes Reconnect (kein `localStorage`) – ein abgebrochenes Spiel lässt sich von jedem Gerät aus fortsetzen

**Zuschauen & Zusammen spielen**
- **Zuschauer-Modus**: Freunde können einer laufenden Partie beitreten, ohne je eine Hand zu sehen (weder die eigene noch fremde) – nur Tischkarten und Punktestand
- **Sprachchat** (WebRTC-Mesh) mit vollem Beitritt für Zuschauer, self-hosted TURN/STUN-Relay als zweites Add-on
- **Textchat** pro Raum
- Pro-Spieler-Stummschaltung für Text- und Sprachchat (rein lokal/sitzungsbezogen, betrifft niemand anderen)

**Freunde & Statistik**
- Freundschaftsanfragen, Online-Status, Raum-Einladungen
- Freundesprofile (read-only): Mitgliedschaft seit, Spiele/Siege/Ø Punkte/Ø Platz, Trefferquote der Ansagen
- Aufklappbare "Letzte Partien"-Liste (eigenes Profil und Freundesprofile) mit vollständiger Rangliste pro Partie

**Digitaler Rechenblock**
- Ersatz für den Papier-Punktezettel bei Partien am Tisch: Namen (Gast oder verknüpfter Account), Ansage/Stiche pro Runde eintragen, laufende Summe, Sieger-Hervorhebung
- Jederzeit fortsetzbar, einzelne Runden nachträglich editierbar, Sicherheitsabfrage vor dem (endgültigen) Abschließen mit sehr wenigen Runden

**Drumherum**
- Installierbare PWA (Manifest, Service Worker, "Zum Homescreen hinzufügen"-Banner)
- Web-Push-Benachrichtigungen ("Du bist dran")
- Profil mit Avatar-Upload
- DSGVO-taugliches Lösch-Skript für Nutzerkonten (`scripts/delete_user.sql`)

## Architektur auf einen Blick

```
┌─────────────────────────┐        ┌──────────────────────────────────────┐
│  React/Vite PWA          │◄──────►│  Supabase Projekt                     │
│  (wizard/frontend)        │  REST/  │  ├─ Postgres (RLS, Realtime)          │
│  – als HA-Add-on           │ Realtime│  ├─ Auth (E-Mail/Passwort)            │
│    "Wizzo" ausgeliefert   │  WS     │  ├─ Storage (Avatare)                  │
└──────────────┬───────────┘        │  └─ Edge Function "game-action"        │
               │ WebRTC (Voice)      │     (Deno – gesamte Spielregel-Logik)  │
               ▼                    └──────────────────┬─────────────────────┘
┌─────────────────────────┐                            │ Web Push (VAPID)
│  coturn TURN/STUN-Relay  │                            ▼
│  – als HA-Add-on           │                  Browser-Benachrichtigung
│    "Wizzo Sprachchat"     │
└─────────────────────────┘
```

Der Client enthält **keine** vertrauenswürdige Spiellogik – jede Aktion (Karte spielen, bieten, Sonderkarte einsetzen, …) geht als Request an die Edge Function `game-action`, die den Zustand in Postgres liest/validiert/schreibt. Row Level Security sorgt dafür, dass z. B. die Handkarten anderer Spieler serverseitig gar nicht erst ausgeliefert werden (`room_players_view`).

Details: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Repository-Struktur

```
├── repository.yaml              # Home-Assistant-Add-on-Repo-Deskriptor
├── wizard/                      # Add-on #1: die eigentliche Wizzo-App
│   ├── config.yaml              #   HA-Add-on-Manifest (Version, Ports, Arch)
│   ├── Dockerfile                #   nginx, serviert den Vite-Build
│   ├── nginx.conf
│   └── frontend/                #   React/TypeScript/Vite SPA
│       └── src/
│           ├── App.tsx           #     alle Screens/Komponenten (bewusst eine Datei)
│           ├── supabase.ts       #     Supabase-Client + callGameAction()
│           ├── cards.ts, types.ts, CardArt.tsx, CardView.tsx
│           └── ...
├── turn/                        # Add-on #2: optionaler Sprachchat-Relay
│   ├── config.yaml
│   ├── Dockerfile                #   Alpine + coturn
│   └── run.sh                    #   liest Add-on-Optionen, startet turnserver
├── ios/                         # native SwiftUI-App (in Arbeit, siehe docs/IOS.md)
│   ├── project.yml               #   XcodeGen-Manifest statt eingecheckter .xcodeproj
│   ├── Config/Secrets.example.xcconfig
│   └── Wizzo/                     #   App/, Models/, Services/, Features/
├── supabase/
│   ├── config.toml               # lokale Supabase-CLI-Konfiguration
│   ├── migrations/               # 000…022, fortlaufend, siehe docs/DATABASE.md
│   └── functions/game-action/
│       ├── index.ts              #   HTTP-Handler + alle Spiel-Aktionen (Dispatch)
│       ├── logic.ts              #   reine, testbare Regel-Funktionen
│       └── logic_test.ts         #   Unit-Tests (Deno test / tsx)
├── scripts/delete_user.sql       # manuelles DSGVO-Lösch-Skript
├── .github/workflows/            # CI: Build & Push (Docker), Supabase-Deploy
└── docs/                         # vertiefende Dokumentation (siehe unten)
```

## Installation als Home Assistant Add-on

1. In Home Assistant unter **Einstellungen → Add-ons → Add-on Store → ⋮ → Repositories** die URL dieses Repos hinzufügen: `https://github.com/GianlucaKo95/Wizard_Game`
2. Zwei Add-ons stehen danach zur Verfügung:
   - **Wizzo** – die Spiele-App selbst. Standardmäßig unter Port `3043` erreichbar (`http://<home-assistant-host>:3043`, kein Ingress).
   - **Wizzo Sprachchat (TURN)** – optional, nur nötig für den In-Game-Sprachchat. Läuft mit `host_network: true` und erwartet ein `shared_secret` in den Add-on-Optionen, das mit dem `TURN_SHARED_SECRET`-Secret der Supabase Edge Function übereinstimmen muss (siehe [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md#umgebungsvariablen--secrets)).
3. Beide Add-ons installieren und starten. Die App selbst braucht kein eigenes Backend im Add-on – Konten, Räume und Echtzeit-Sync laufen komplett über das konfigurierte Supabase-Projekt (die Zugangsdaten sind zur Build-Zeit fest in das Docker-Image einkompiliert, siehe CI unten).

> Diese beiden Add-ons werden über GitHub Actions automatisch als Multi-Arch-Images (`amd64`, `aarch64`) nach GHCR gebaut und mit der Version aus `wizard/config.yaml` bzw. `turn/config.yaml` getaggt – siehe [CI/CD](#cicd).

## Lokale Entwicklung

Kurzfassung (ausführlich in [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)):

```bash
cd wizard/frontend
npm install
cp .env.example .env   # falls vorhanden – sonst VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY selbst setzen
npm run dev             # Vite Dev-Server
```

Für Änderungen an der Spiellogik/Edge Function:

```bash
cd supabase/functions/game-action
npx tsx logic_test.ts   # Unit-Tests der reinen Regel-Funktionen
```

Datenbankschema-Änderungen laufen über nummerierte SQL-Dateien unter `supabase/migrations/` (siehe [`docs/DATABASE.md`](docs/DATABASE.md)).

## Tests

| Was | Womit | Wo |
|---|---|---|
| Spielregeln (Deck-Aufbau, Stichgewinner, Sonderkarten, KI-Heuristiken) | `npx tsx logic_test.ts` (oder `deno test`) | `supabase/functions/game-action/` |
| Frontend-Build/Typecheck | `npm run build` | `wizard/frontend/` |

Beide laufen auch in CI (siehe unten), bevor irgendetwas gebaut oder deployt wird.

## CI/CD

Zwei GitHub-Actions-Workflows unter `.github/workflows/`:

- **`build-push.yml`** (bei Push auf `main`, oder manuell): führt zuerst `logic_test.ts` aus, baut dann das Frontend (mit den `VITE_*`-Secrets aus den Repo-Settings) und baut/pusht die Multi-Arch-Docker-Images beider Add-ons (`wizard-addon`, `wizard-turn-addon`) nach `ghcr.io/gianlucako95/…`, getaggt mit `latest`, der jeweiligen `config.yaml`-Version und dem Kurz-Commit-SHA.
- **`supabase-deploy.yml`** (bei Push auf `main` mit Änderungen unter `supabase/functions/**`/`supabase/config.toml`): führt ebenfalls erst die Tests aus und deployt danach die Edge Function `game-action` per Supabase CLI auf das produktive Projekt.

Datenbank-Migrationen werden **nicht** automatisch über CI ausgerollt – die werden bewusst manuell (per Supabase CLI/MCP) gegen das Projekt angewendet, siehe [`docs/DATABASE.md`](docs/DATABASE.md).

## Weiterführende Dokumentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) – Systemarchitektur im Detail: Frontend-Aufbau, Edge-Function-Aktionen, Realtime-Modell, Sprachchat/TURN, Push, PWA
- [`docs/DATABASE.md`](docs/DATABASE.md) – Tabellen, Views, RLS-Modell, vollständige Migrationshistorie
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) – Setup, Umgebungsvariablen/Secrets, lokaler Supabase-Stack, Konventionen
- [`docs/IOS.md`](docs/IOS.md) – die native SwiftUI-App: Stand, Architektur, Setup auf dem Mac, Phasen-Roadmap

## Status & Lizenz

Privates Hobby-/Familienprojekt, entwickelt für den Eigenbetrieb als Home-Assistant-Add-on. Es gibt aktuell keine explizite Lizenzdatei – ohne eine solche gilt der urheberrechtliche Standardfall ("alle Rechte vorbehalten"); wer den Code weiterverwenden möchte, sollte vorher beim Repo-Inhaber nachfragen. Die Harry-Potter-Themenwelt (Namen, Häuser, Charaktere) ist rein kosmetisch und nicht offiziell lizenziert.
