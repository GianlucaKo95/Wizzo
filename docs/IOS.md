# iOS-App (nativ, SwiftUI)

Wizzo wird komplett nativ als SwiftUI-App neu gebaut (nicht als Web-Wrapper) – die PWA (`wizard/`) ist der Übergang, die native App soll sie langfristig ablösen. Dieses Dokument beschreibt Architektur, Setup und den aktuellen Stand.

## Warum nativ statt PWA-Wrapper

Kurz zusammengefasst aus der Diskussion, die zu dieser Entscheidung geführt hat: ein reiner Wrapper (z. B. Capacitor) hätte den bestehenden Web-Code 1:1 übernommen, aber eben auch dessen Grenzen – kein wirklich natives Gefühl (Scrollen/Übergänge/Gesten bleiben Web), Sprachchat bricht im Hintergrund ab, Web-Push ist auf iOS unzuverlässig. Da ein echtes natives Gefühl gewünscht war und die PWA ohnehin nicht weiterbetrieben werden soll, baut die App stattdessen die komplette UI in SwiftUI neu, gegen **dasselbe, unveränderte Supabase-Backend** (Postgres/RLS/Realtime/Edge-Function) wie die Web-App – siehe [`ARCHITECTURE.md`](ARCHITECTURE.md) und [`DATABASE.md`](DATABASE.md) für das Backend, das hier 1:1 weiterverwendet wird.

## Stand: Phase 1-5 (Grundgerüst, Auth, Profil, Räume/Lobby, Spieltisch inkl. aller 9 Sonderkarten)

Was aktuell existiert und **echt gegen das Supabase-Projekt funktioniert**:

- Projekt-Grundgerüst (SwiftUI, iOS 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)-verwaltet)
- Supabase-Anbindung über das offizielle [`supabase-swift`](https://github.com/supabase/supabase-swift)-SDK (Auth, Postgrest, Realtime)
- **Anmelden/Registrieren**: repliziert exakt die Logik aus `AuthScreen` in `wizard/frontend/src/App.tsx` – es gibt keine echte E-Mail, nur einen Namen; dahinter steht eine synthetische `<slug>@wizard.local`-Adresse mit einem abgeleiteten Standardpasswort, wenn keins gesetzt wird. **Das muss exakt übereinstimmen**, sonst können sich Web- und App-Nutzer nicht gegenseitig mit denselben Konten anmelden.
- **Profil-Tab**: lädt die eigene `profiles`-Zeile, zeigt Name + Mitglied-seit, funktionierendes Abmelden.
- **Home-Tab**: Raum erstellen (Edition wählbar – Classic oder "30 Jahre") oder per Code beitreten – ruft dieselben `createRoom`/`joinRoom`-Edge-Function-Aktionen auf wie die Web-App.
- **Lobby**: Live-Spielerliste (Supabase-Realtime-Channel auf `rooms`/`room_players`, plus 5s-Poll-Fallback wie im Web-Pendant), Host-Kennzeichnung, "Spiel starten" (ruft `startGame` auf, inkl. derselben KI-Auffüll-Logik bis 3 Sitzplätze), Verlassen.
- **Spieltisch**: Trumpf wählen (wenn der Dealer einen Zauberer aufdeckt), bieten, Karten ausspielen, Stichanzeige, Rundenende mit Punktestand, "Nächste Runde"/"Nochmal spielen" (Host), KI-Züge (client-getriebenes `triggerAI` nach 2s Verzögerung, genau wie im Web-Pendant) und automatisches `clearTrick` nach 5s. Kartenanzeige ist bewusst nur textbasiert (Wert/Farbsymbol, kein Karten-Artwork) – eine eigene Asset-Pipeline ist nicht Teil dieser Phase.
- **Alle 9 "30 Jahre"-Sonderkarten**:
  - Drache/Seidenschnabel, Fee, Bombe/Elderstab, Vampir/Quirrell (Phase 4) brauchen client-seitig keine eigene Interaktion – sie laufen über das normale `playCard`, der Server behandelt ihre Sonderregeln (Schlagen/Verlieren/Stich-Annullierung/Trumpf-Kopie) selbst; die App zeigt sie nur korrekt an (Kurzlabel + Farbe, mirror von `specialConfigs` in `CardView.tsx`).
  - Werwolf/Lupin (Phase 4) löst eine eigene Phase `choosingWerewolf` aus (wer die Karte zieht, bestimmt die Stichfarbe für die ganze Runde – eigener Picker, analog zum Trumpf-Picker).
  - Zauberer-oder-Narr/Ron Weasley (Phase 4) zeigt beim Antippen einen Zauberer/Narr-Dialog und spielt die Karte über `playSpecial` statt `playCard`.
  - Jongleur/George Weasley (`rainbow7`) und Gleis 9¾ (`rainbow9`) (Phase 5) zeigen beim Antippen einen Farb-Dialog (die Farbe, mit der die Karte "kämpft") und spielen dann über `playCard` mit `suit`. Danach läuft serverseitig ein Nachlauf während `phase === "trickEnd"`: Jongleur verlangt von JEDEM Spieler eine Karte zum Weitergeben an den linken Nachbarn (`passCard`, eigener Picker über die ganze Hand); Gleis 9¾ verlangt vom Stichgewinner eine Anpassung seiner Vorhersage um ±1 (`rainbow9Adjust`, mit derselben "−1 nur wenn noch nicht im Ziel"-Einschränkung wie die Web-App). Sind beide im selben Stich, löst der Server Jongleur zuerst auf und Gleis 9¾ erst danach (`pending_rainbow9_deferred`) – rein serverseitig, die App muss das nicht selbst nachbilden.
  - Hexe/Bellatrix (`witch`) (Phase 5) läuft normal über `playCard`; nach Stichgewinn zeigt die App einen zweistufigen Dialog (erst eine Karte aus dem Stich nehmen, dann eine eigene Handkarte dafür abgeben, über `playSpecial`), gefolgt von einer kurzen `witchReveal`-Phase, die das Tausch-Ergebnis anzeigt (client-getriebenes `witchRevealDone` nach 4s, wie im Web-Pendant).
  - Alle drei pending-Zustände (Jongleur/Hexe/Gleis 9¾) existieren serverseitig ausschließlich während `phase === "trickEnd"` – die App zeigt während dieser Zeit statt des normalen "Stich gewinnt …"-Banners den jeweils zuständigen Dialog für die betroffene Person bzw. einen kurzen Warte-Hinweis für alle anderen.
- Tab-Leiste (Home/Freunde/Statistik/Profil, siehe `TabKey` in `App.tsx`) – Freunde/Statistik sind weiterhin ehrliche "Kommt noch"-Platzhalter, keine Fake-Daten.

Was **noch nicht** existiert (jeweils eigene, größere Phasen oder gezielte Nacharbeiten):

- Rundenhistorie-Ansicht, Spiel-Log
- Runde-1-Sonderregel "Indianer Poker" wird serverseitig korrekt erzwungen, aber die App zeigt die dabei eigentlich sichtbaren fremden Handkarten (`visible_hand` in `room_players_view`) noch nicht an – rein visuelle Lücke, keine Regelverletzung
- Kein client-seitiges Hervorheben spielbarer/unspielbarer Karten (der Server validiert ohnehin jeden Zug serverseitig und lehnt ungültige mit einer Fehlermeldung ab – das ist bewusst die einzige Fehlerquelle für Phase 3, um die KI-/Sonderkarten-Regellogik nicht ein zweites Mal im Client nachbauen zu müssen)
- Automatisches Reconnect in ein bereits laufendes Spiel beim App-Start (die Web-App hat das, siehe `checkReconnect` in `App.tsx` - hier bewusst noch nicht repliziert, um die Phasen klein zu halten)
- Zuschauer-Modus
- Freunde (Liste, Anfragen, Einladungen, Freundesprofile, Raum-Einladungen aus der Lobby)
- Statistik ("Letzte Partien", Trefferquote)
- Digitaler Rechenblock
- Sprachchat (WebRTC) – inkl. Hintergrund-Audio, der Hauptgrund für den nativen Weg
- Echte Push-Benachrichtigungen (APNs)
- Avatar-Upload

Realistisch betrachtet ist das hier erst ein Anfang unter vielen Phasen – Vollständigkeit ist kein Wochenend-, sondern ein Mehrmonatsprojekt für dieses Feature-Set. Jede weitere Phase sollte als eigener, in sich abgeschlossener Schritt kommen (gleiches Muster wie der Rest dieses Repos), nicht als ein einziger riesiger, ungeprüfter Umbau.

## Wichtige Einschränkung: hier nicht kompilierbar geprüft

Der gesamte Swift-Code in diesem Verzeichnis wurde **ohne Zugriff auf Xcode/einen Swift-Compiler** geschrieben (Linux-Dev-Umgebung – Apple erlaubt iOS-Builds grundsätzlich nur auf macOS, das ist keine Einschränkung dieses Setups). Die Methodensignaturen des `supabase-swift`-SDK (`signUp`, `signIn`, `.from().select().eq().single().execute().value`, die Realtime-API `channel(...).postgresChanges(...)`/`.subscribe()`/`.unsubscribe()`, …) wurden gezielt gegen die offiziellen Beispiel-Apps ([UserManagement](https://github.com/supabase/supabase-swift/tree/main/Examples/UserManagement), [SlackClone](https://github.com/supabase/supabase-swift/tree/main/Examples/SlackClone)) und den SDK-Quellcode selbst abgeglichen (konkret auch die exakten `eq(_:value:)`/`select(_:)`-Parameter-Label, siehe den Bugfix-Absatz unten), nicht aus dem Gedächtnis geraten – aber **der erste Build in Xcode ist trotzdem der erste echte Korrektheitstest.** Kleinere Abweichungen sind nicht ausgeschlossen und sollten dort schnell auffallen (Xcode zeigt sie direkt als Fehler mit Vorschlag).

Ein konkretes Beispiel, warum dieser Abgleich wichtig war: `rooms` hat **spaltenbeschränkten** Lesezugriff (`revoke select ... / grant select (id, code, phase, ...)` in `000_full_reset.sql`) – `host_id` ist absichtlich **nicht** in der Freigabeliste. Ein naives `.from("rooms").select()` (alle Spalten) hätte deshalb serverseitig mit einem Berechtigungsfehler abgelehnt werden müssen; die App fragt stattdessen wie die Web-App explizit nur die freigegebenen Spalten ab und ermittelt den Host über `room_players.player_index == 0`, nicht über `host_id` (siehe `docs/DATABASE.md`).

## Setup auf dem Mac

Voraussetzung: Xcode (aktuelle Version aus dem App Store) und [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
cd ios
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
# Secrets.xcconfig öffnen, SUPABASE_URL/SUPABASE_ANON_KEY eintragen
# (dieselben Werte wie wizard/frontend/.env.example - Supabase-Projekteinstellungen -> API)

xcodegen generate     # erzeugt Wizzo.xcodeproj aus project.yml (gitignored, lokal regenerierbar)
open Wizzo.xcodeproj
```

In Xcode:
1. Target **Wizzo** → **Signing & Capabilities** → dein Apple-Developer-Team wählen.
2. **Bundle Identifier** prüfen: `com.gianlucako95.wizzo` (in `project.yml` gesetzt) – muss mit einer App-ID in [App Store Connect](https://appstoreconnect.apple.com/) übereinstimmen.
3. Simulator oder eigenes Gerät wählen, ▶️.

Nach jeder Änderung an `project.yml` (neues Target-Setting, neue Dependency, …): `xcodegen generate` erneut ausführen. Neue `.swift`-Dateien im `Wizzo/`-Ordner werden von XcodeGen automatisch erkannt (keine manuelle "Add to target"-Pflege).

## Projektstruktur

```
ios/
  project.yml                 # XcodeGen-Manifest (Target, Settings, SPM-Dependencies)
  Config/
    Secrets.example.xcconfig  # Vorlage, getrackt
    Secrets.xcconfig          # echte Werte, gitignored
  Wizzo/
    App/
      WizzoApp.swift           # @main - entscheidet Auth- vs. Root-Screen
      AppState.swift           # Session-Zustand (ObservableObject)
      Theme.swift               # Farbpalette, 1:1 aus App.tsx's `const C`, plus Kartenfarben-Helfer
      FlatFieldStyle.swift      # gemeinsames Textfeld-Styling (Auth, Lobby-Beitritt, ...)
    Models/
      Profile.swift             # mirrors die `profiles`-Tabelle
      Room.swift                 # mirrors `rooms` (nur die lesbar freigegebenen Spalten)
      RoomPlayer.swift           # mirrors `room_players_view`
      Card.swift                  # mirrors Card in types.ts
      TrickEntry.swift            # mirrors ein {card, playerIndex}-Eintrag in current_trick/last_trick_cards
    Services/
      SupabaseService.swift     # einziger SupabaseClient, URL/Key aus Info.plist
      GameActionClient.swift     # Swift-Äquivalent zu callGameAction() aus supabase.ts
    Features/
      Auth/                      # Anmelden/Registrieren
      Home/                      # Tab-Leiste, Raum erstellen/beitreten, Lobby
      Game/                       # Spieltisch (Classic + "30 Jahre"): GameView/GameViewModel, CardChipView
      Profile/                   # Profil-Tab (echte Daten)
    Resources/
      Assets.xcassets/          # App-Icon + Accent-Farbe, aus dem bestehenden Branding generiert
```

Jede weitere Phase bekommt ihren eigenen Ordner unter `Features/` (z. B. `Features/Friends/`) nach demselben Schema: eine `*View.swift` (SwiftUI) + ein `*ViewModel.swift` (`ObservableObject`, hält den `async`-Zugriff auf `SupabaseService.client`).

## Nächste sinnvolle Phase

Mit Phase 5 sind alle neun Sonderkarten und damit die komplette "30 Jahre"-Edition vollständig spielbar – der Spieltisch selbst hat damit funktional Web-Parität erreicht (mit Ausnahme der rein kosmetischen Lücken unten). Sinnvolle nächste Schritte, grob nach Aufwand sortiert:

- **Rundenhistorie-Ansicht, Spiel-Log** – beides existiert serverseitig bereits (`round_history`-Tabelle, `rooms.log`), fehlt der App aber komplett als UI.
- **Runde-1 "Indianer Poker"** – die fremden Handkarten (`visible_hand` in `room_players_view`) anzeigen; rein kosmetisch, der Server erzwingt die Regel bereits korrekt ohne Client-Mithilfe.
- **Automatisches Reconnect** in ein bereits laufendes Spiel beim App-Start (`checkReconnect`-Äquivalent).
- Danach die größeren, eigenständigen Features: Zuschauer-Modus, Freunde, Statistik, digitaler Rechenblock, Sprachchat (WebRTC), echte Push-Benachrichtigungen (APNs), Avatar-Upload.
