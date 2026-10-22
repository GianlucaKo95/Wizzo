# Lokale Entwicklung

Setup, Umgebungsvariablen, Tests und Konventionen. Für den großen Überblick siehe [`ARCHITECTURE.md`](ARCHITECTURE.md), für Schema/Migrationen [`DATABASE.md`](DATABASE.md).

## Voraussetzungen

- Node.js 20+ (siehe `.github/workflows/*.yml` – dieselbe Version läuft auch in CI)
- [Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started) – für lokale Migrationen/Edge-Function-Entwicklung
- Docker – nur nötig, wenn du die Add-on-Images selbst bauen willst (siehe unten)
- Ein Supabase-Projekt (gehostet oder lokal via `supabase start`) mit den unter [`DATABASE.md`](DATABASE.md) beschriebenen Migrationen angewendet

## Frontend (`wizard/frontend`)

```bash
cd wizard/frontend
npm install
cp .env.example .env     # dann VITE_SUPABASE_URL/VITE_SUPABASE_ANON_KEY eintragen
npm run dev               # Vite Dev-Server, Standard-Port 5173
npm run build              # Produktions-Build nach dist/ (das, was CI auch macht)
```

`npm run build` ist gleichzeitig der Typecheck – es gibt aktuell kein separates `tsc --noEmit`-Skript, Vite/esbuild bricht den Build bei TS-Fehlern ab. Der Build wirft eine Warnung wegen Chunk-Größe (>500 kB) – das ist bekannt (eine große `App.tsx`, siehe [`ARCHITECTURE.md`](ARCHITECTURE.md#frontend-wizardfrontendsrc)) und aktuell kein Ziel, das aufzuteilen.

## Edge Function (`supabase/functions/game-action`)

```bash
# Lokal gegen den Supabase-Local-Stack laufen lassen:
supabase start
supabase functions serve game-action --env-file supabase/functions/game-action/.env.local

# Deploy auf das echte Projekt (macht sonst der supabase-deploy.yml-Workflow):
supabase functions deploy game-action --project-ref <project-ref>
```

Die Funktion braucht zur Laufzeit die in [Umgebungsvariablen & Secrets](#umgebungsvariablen--secrets) gelisteten `Deno.env`-Werte. `SUPABASE_URL`/`SUPABASE_ANON_KEY`/`SUPABASE_SERVICE_ROLE_KEY` sind bei jeder Supabase-Edge-Function automatisch gesetzt, alle anderen (VAPID, TURN) müssen als Function-Secrets hinterlegt werden:

```bash
supabase secrets set VAPID_PUBLIC_KEY=... VAPID_PRIVATE_KEY=... VAPID_SUBJECT="mailto:you@example.com" TURN_SHARED_SECRET=... TURN_HOST=turn.example.com --project-ref <project-ref>
```

## Datenbank / Migrationen

```bash
# Migrationen gegen den lokalen Stack anwenden (frisch, inkl. Seed):
supabase db reset

# Eine neue Migration anlegen:
supabase migration new beschreibender_name   # -> supabase/migrations/023_beschreibender_name.sql

# Gegen das gehostete Projekt ausrollen:
supabase db push --project-ref <project-ref>
```

Reihenfolge/Namenskonvention: fortlaufende dreistellige Nummer + kurze Beschreibung (`023_...`), siehe die vollständige Liste in [`DATABASE.md`](DATABASE.md#migrationshistorie). Migrationen werden **manuell** angewendet, nicht über GitHub Actions – Schemaänderungen an einer produktiven Datenbank sollen ein bewusster, einzelner Schritt sein, kein Nebeneffekt eines Merges.

Wichtige Stolperfalle: `CREATE OR REPLACE VIEW` erlaubt es nicht, eine Spalte mitten in die bestehende `SELECT`-Liste einzufügen (Postgres deutet das als Versuch, eine spätere Spalte "umzubenennen", und lehnt ab) – neue Spalten müssen ans Ende.

## Tests

| Befehl | Prüft | Wo |
|---|---|---|
| `npx tsx logic_test.ts` (oder `deno test`) | Spielregeln: Deck-Aufbau pro Edition, Stichgewinner (inkl. aller Sonderkarten), Punkteberechnung, Dealer-Regel, KI-Bid-/Zug-Heuristiken | `supabase/functions/game-action/` |
| `npm run build` | TypeScript-Typecheck + Produktions-Build | `wizard/frontend/` |

Beide Befehle laufen 1:1 auch in CI (`.github/workflows/build-push.yml`, `.github/workflows/supabase-deploy.yml`) – vor jedem Push, der Add-on-Images baut oder die Edge Function deployt, sollten sie lokal grün sein.

## Docker-Images lokal bauen

Spiegelt, was `build-push.yml` in CI macht:

```bash
# Wizzo (Frontend muss vorher gebaut sein, siehe oben)
mkdir -p wizard/dist && cp -r wizard/frontend/dist/. wizard/dist/
docker build -t wizard-addon -f wizard/Dockerfile wizard

# TURN-Relay
docker build -t wizard-turn-addon -f turn/Dockerfile turn
```

## Umgebungsvariablen & Secrets

**Frontend (Build-Zeit, `wizard/frontend/.env` bzw. GitHub-Actions-Secrets):**

| Variable | Pflicht | Zweck |
|---|---|---|
| `VITE_SUPABASE_URL` | ja | Supabase-Projekt-URL |
| `VITE_SUPABASE_ANON_KEY` | ja | Öffentlicher `anon`-Key (RLS schützt die Daten) |
| `VITE_VAPID_PUBLIC_KEY` | nein | Aktiviert die Push-Opt-in-Option im Profil; ohne sie bleibt sie einfach ausgeblendet |

**Edge Function (`supabase secrets set`, Projekt `game-action`):**

| Variable | Pflicht | Zweck |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | automatisch gesetzt | Von Supabase selbst bereitgestellt, kein manuelles Secret nötig |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, `VAPID_SUBJECT` | für Push nötig | Signieren der Web-Push-Nachrichten; `VAPID_PUBLIC_KEY` muss mit `VITE_VAPID_PUBLIC_KEY` im Frontend übereinstimmen |
| `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_AUTH_KEY` | für Push an die native App nötig | Apple-Developer-Portal → Keys → ein Auth Key (.p8) für "Apple Push Notifications service (APNs)"; `APNS_AUTH_KEY` ist der **rohe Inhalt** der `.p8`-Datei (inkl. `-----BEGIN/END PRIVATE KEY-----`-Zeilen, echte Zeilenumbrüche erhalten, z. B. `supabase secrets set APNS_AUTH_KEY="$(cat AuthKey_XXXX.p8)"`). Ohne diese drei Secrets wird das native Push-Senden (`sendApnsPush` in `index.ts`) einfach übersprungen, wie bei fehlender VAPID-Konfiguration. Die Bundle-ID ist nicht geheim und steht direkt im Code (`de.koeven.wizzo`) |
| `APNS_ENV` | optional | `"production"` für TestFlight-extern/App-Store-Builds; alles andere (auch ungesetzt) nutzt den Sandbox-Host, passend zu Debug-Builds direkt aus Xcode |
| `TURN_SHARED_SECRET` | für Sprachchat nötig | Muss exakt dem `shared_secret` des `wizard_turn`-Add-ons entsprechen – damit signiert die Funktion zeitlich begrenzte ICE-Credentials |
| `TURN_HOST` | für Sprachchat nötig | Hostname/IP, unter der das TURN-Add-on erreichbar ist |
| `WIZARD_DEBUG` | optional | `"1"` aktiviert zusätzliches Server-Logging (`dbg(...)`-Aufrufe in `index.ts`) |

**Home-Assistant-Add-on-Optionen** (`turn/config.yaml`, in der Add-on-UI gesetzt, nicht als Datei im Repo): `shared_secret`, `relay_min_port`/`relay_max_port` (Standard 49160–49300) – siehe `turn/run.sh`.

## Konventionen

Diese gelten für beide Codebasen (Frontend, Edge Function) und sind bewusst so, nicht zufällig gewachsen:

- **Kommentare erklären das WARUM, nicht das WAS.** Ein Kommentar, der nur beschreibt, was der nächste, gut benannte Ausdruck ohnehin zeigt, gehört nicht rein. Ein Kommentar zu einer nicht offensichtlichen Invariante, einem Workaround für ein konkretes Verhalten, oder einer Entscheidung, die sonst überrascht, schon.
- **Keine vorzeitige Abstraktion.** Lieber drei ähnliche Zeilen als eine Abstraktion für einen hypothetischen Zukunftsfall.
- **`App.tsx` bleibt eine Datei.** Das ist eine getroffene Entscheidung (siehe [`ARCHITECTURE.md`](ARCHITECTURE.md#frontend-wizardfrontendsrc)), keine Altlast, die "irgendwann" aufgeteilt werden soll.
- **Migrationen sind additiv und werden nie nachträglich verändert**, sobald sie gegen das Projekt angewendet wurden – eine Korrektur ist immer eine neue Migration mit höherer Nummer, siehe die Historie in [`DATABASE.md`](DATABASE.md#migrationshistorie).
- **Sicherheitslogik gehört in RLS-Policies oder in die Edge Function, nie ins Frontend.** Der Client darf falsch/böswillig sein, ohne dass dadurch etwas kaputtgeht.
