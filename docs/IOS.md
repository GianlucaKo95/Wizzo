# iOS-App (nativ, SwiftUI)

Wizzo wird komplett nativ als SwiftUI-App neu gebaut (nicht als Web-Wrapper) – die PWA (`wizard/`) ist der Übergang, die native App soll sie langfristig ablösen. Dieses Dokument beschreibt Architektur, Setup und den aktuellen Stand.

## Warum nativ statt PWA-Wrapper

Kurz zusammengefasst aus der Diskussion, die zu dieser Entscheidung geführt hat: ein reiner Wrapper (z. B. Capacitor) hätte den bestehenden Web-Code 1:1 übernommen, aber eben auch dessen Grenzen – kein wirklich natives Gefühl (Scrollen/Übergänge/Gesten bleiben Web), Sprachchat bricht im Hintergrund ab, Web-Push ist auf iOS unzuverlässig. Da ein echtes natives Gefühl gewünscht war und die PWA ohnehin nicht weiterbetrieben werden soll, baut die App stattdessen die komplette UI in SwiftUI neu, gegen **dasselbe, unveränderte Supabase-Backend** (Postgres/RLS/Realtime/Edge-Function) wie die Web-App – siehe [`ARCHITECTURE.md`](ARCHITECTURE.md) und [`DATABASE.md`](DATABASE.md) für das Backend, das hier 1:1 weiterverwendet wird.

## Stand: Phase 1-4 (Grundgerüst, Auth, Profil, Räume/Lobby, Spieltisch inkl. 6 von 9 Sonderkarten)

Was aktuell existiert und **echt gegen das Supabase-Projekt funktioniert**:

- Projekt-Grundgerüst (SwiftUI, iOS 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)-verwaltet)
- Supabase-Anbindung über das offizielle [`supabase-swift`](https://github.com/supabase/supabase-swift)-SDK (Auth, Postgrest, Realtime)
- **Anmelden/Registrieren**: repliziert exakt die Logik aus `AuthScreen` in `wizard/frontend/src/App.tsx` – es gibt keine echte E-Mail, nur einen Namen; dahinter steht eine synthetische `<slug>@wizard.local`-Adresse mit einem abgeleiteten Standardpasswort, wenn keins gesetzt wird. **Das muss exakt übereinstimmen**, sonst können sich Web- und App-Nutzer nicht gegenseitig mit denselben Konten anmelden.
- **Profil-Tab**: lädt die eigene `profiles`-Zeile, zeigt Name + Mitglied-seit, funktionierendes Abmelden.
- **Home-Tab**: Raum erstellen oder per Code beitreten – ruft dieselben `createRoom`/`joinRoom`-Edge-Function-Aktionen auf wie die Web-App. Die Edition-Wahl beim Erstellen ist aktuell auf Classic fest verdrahtet (siehe Begründung unten).
- **Lobby**: Live-Spielerliste (Supabase-Realtime-Channel auf `rooms`/`room_players`, plus 5s-Poll-Fallback wie im Web-Pendant), Host-Kennzeichnung, "Spiel starten" (ruft `startGame` auf, inkl. derselben KI-Auffüll-Logik bis 3 Sitzplätze), Verlassen.
- **Spieltisch**: Trumpf wählen (wenn der Dealer einen Zauberer aufdeckt), bieten, Karten ausspielen, Stichanzeige, Rundenende mit Punktestand, "Nächste Runde"/"Nochmal spielen" (Host), KI-Züge (client-getriebenes `triggerAI` nach 2s Verzögerung, genau wie im Web-Pendant) und automatisches `clearTrick` nach 5s. Kartenanzeige ist bewusst nur textbasiert (Wert/Farbsymbol, kein Karten-Artwork) – eine eigene Asset-Pipeline ist nicht Teil dieser Phase.
- **6 der 9 "30 Jahre"-Sonderkarten** (Phase 4): Drache/Seidenschnabel, Fee, Bombe/Elderstab, Vampir/Quirrell, Werwolf/Lupin, Zauberer-oder-Narr/Ron Weasley. Drache/Fee/Bombe/Vampir brauchen client-seitig keine eigene Interaktion – sie laufen über das normale `playCard`, der Server behandelt ihre Sonderregeln (Schlagen/Verlieren/Stich-Annullierung/Trumpf-Kopie) selbst; die App zeigt sie nur korrekt an (Kurzlabel + Farbe, mirror von `specialConfigs` in `CardView.tsx`). Werwolf löst eine eigene Phase `choosingWerewolf` aus (wer die Karte zieht, bestimmt die Stichfarbe für die ganze Runde – eigener Picker, analog zum Trumpf-Picker). Ron Weasley/Zauberer-oder-Narr zeigt beim Antippen einen Zauberer/Narr-Dialog und spielt die Karte über `playSpecial` statt `playCard`.
- Tab-Leiste (Home/Freunde/Statistik/Profil, siehe `TabKey` in `App.tsx`) – Freunde/Statistik sind weiterhin ehrliche "Kommt noch"-Platzhalter, keine Fake-Daten.

### Warum die "30 Jahre"-Edition beim Raum-Erstellen vorerst ausgeblendet ist

Die restlichen 3 Sonderkarten – Jongleur/George Weasley (`rainbow7`), Gleis 9¾ (`rainbow9`), Hexe/Bellatrix (`witch`) – brauchen jeweils einen mehrstufigen, zustandsbehafteten Dialog (Farbwahl + Karte weiterreichen bei den beiden Jongleur-Karten, Karten-Tausch nach Stichgewinn bei der Hexe via `pending_witch`/`witchReveal`), den die App noch nicht hat. Da in der Jubiläumsedition alle neun Sonderkarten immer gemeinsam im Deck sind, würde ein Spiel garantiert stecken bleiben, sobald eine der drei fehlenden Karten gezogen und gespielt wird – die App hätte keine UI, um den dadurch entstehenden Server-Zustand aufzulösen. Deshalb ist die Edition-Wahl beim Raum-Erstellen in `HomeView` vorerst auf Classic fest verdrahtet, bis diese drei Karten in einer eigenen Phase nachgezogen sind.

**Bekannte Restlücke**: Das Erstellen eines neuen "30 Jahre"-Raums ist dadurch blockiert, das *Beitreten* per Code zu einem bereits existierenden Jubiläums-Raum (z. B. von der Web-App erstellt) aber nicht – `joinRoom` prüft die Edition nicht. Ein App-Nutzer, der einem solchen Raum beitritt, kann also trotzdem auf eine der drei fehlenden Karten treffen. Das ist eine bewusst in Kauf genommene, dokumentierte Lücke, kein Bug.

Was **noch nicht** existiert (jeweils eigene, größere Phasen oder gezielte Nacharbeiten):

- Die restlichen drei Sonderkarten der "30 Jahre"-Jubiläumsedition (Jongleur/`rainbow7`, Gleis 9¾/`rainbow9`, Hexe/`witch`) – siehe Begründung oben
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
      Game/                       # Spieltisch (Classic-Edition): GameView/GameViewModel, CardChipView
      Profile/                   # Profil-Tab (echte Daten)
    Resources/
      Assets.xcassets/          # App-Icon + Accent-Farbe, aus dem bestehenden Branding generiert
```

Jede weitere Phase bekommt ihren eigenen Ordner unter `Features/` (z. B. `Features/Friends/`) nach demselben Schema: eine `*View.swift` (SwiftUI) + ein `*ViewModel.swift` (`ObservableObject`, hält den `async`-Zugriff auf `SupabaseService.client`).

## Nächste sinnvolle Phase

Vorschlag ("Phase 5"): die restlichen drei Sonderkarten der "30 Jahre"-Edition nachrüsten – Jongleur/George Weasley (`rainbow7`: Farbe frei wählen + Karte an einen Mitspieler weitergeben via `passCard`), Gleis 9¾ (`rainbow9`: Farbe frei wählen + Gewinner passt sein Gebot per `rainbow9Adjust` an, inkl. der Sonderfälle wenn Jongleur und Gleis 9¾ im selben Stich liegen), Hexe/Bellatrix (`witch`: normal ausspielen, nach Stichgewinn Karten-Tausch via `playSpecial`/`pending_witch`, dann `phase: "witchReveal"` mit client-getriebenem `witchRevealDone`-Timer analog zum bestehenden `clearTrick`-Muster). Jede braucht ihre eigene mehrstufige UI (Auswahl-Dialoge, siehe `index.ts`). Sobald alle drei stehen, kann die Edition-Sperre in `HomeView` (siehe oben) wieder aufgehoben werden.
