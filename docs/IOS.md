# iOS-App (nativ, SwiftUI)

Wizzo wird komplett nativ als SwiftUI-App neu gebaut (nicht als Web-Wrapper) – die PWA (`wizard/`) ist der Übergang, die native App soll sie langfristig ablösen. Dieses Dokument beschreibt Architektur, Setup und den aktuellen Stand.

## Warum nativ statt PWA-Wrapper

Kurz zusammengefasst aus der Diskussion, die zu dieser Entscheidung geführt hat: ein reiner Wrapper (z. B. Capacitor) hätte den bestehenden Web-Code 1:1 übernommen, aber eben auch dessen Grenzen – kein wirklich natives Gefühl (Scrollen/Übergänge/Gesten bleiben Web), Sprachchat bricht im Hintergrund ab, Web-Push ist auf iOS unzuverlässig. Da ein echtes natives Gefühl gewünscht war und die PWA ohnehin nicht weiterbetrieben werden soll, baut die App stattdessen die komplette UI in SwiftUI neu, gegen **dasselbe, unveränderte Supabase-Backend** (Postgres/RLS/Realtime/Edge-Function) wie die Web-App – siehe [`ARCHITECTURE.md`](ARCHITECTURE.md) und [`DATABASE.md`](DATABASE.md) für das Backend, das hier 1:1 weiterverwendet wird.

## Stand: Phase 1-12 (Grundgerüst, Auth, Profil, Räume/Lobby, Spieltisch inkl. aller 9 Sonderkarten, Spielblatt & Log, Indianer Poker, Reconnect, Freunde komplett, Zuschauer-Modus, Statistik)

Was aktuell existiert und **echt gegen das Supabase-Projekt funktioniert**:

- Projekt-Grundgerüst (SwiftUI, iOS 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)-verwaltet)
- Supabase-Anbindung über das offizielle [`supabase-swift`](https://github.com/supabase/supabase-swift)-SDK (Auth, Postgrest, Realtime)
- **Anmelden/Registrieren**: repliziert exakt die Logik aus `AuthScreen` in `wizard/frontend/src/App.tsx` – es gibt keine echte E-Mail, nur einen Namen; dahinter steht eine synthetische `<slug>@wizard.local`-Adresse mit einem abgeleiteten Standardpasswort, wenn keins gesetzt wird. **Das muss exakt übereinstimmen**, sonst können sich Web- und App-Nutzer nicht gegenseitig mit denselben Konten anmelden.
- **Profil-Tab**: lädt die eigene `profiles`-Zeile, zeigt Name + Mitglied-seit, funktionierendes Abmelden.
- **Home-Tab**: Raum erstellen (Edition wählbar – Classic oder "30 Jahre") oder per Code beitreten – ruft dieselben `createRoom`/`joinRoom`-Edge-Function-Aktionen auf wie die Web-App. Beim Öffnen prüft `checkReconnect()` (Phase 8, mirrors `checkReconnect()` in `App.tsx`), ob der eigene `room_players`-Eintrag noch in einem nicht beendeten Raum steckt – falls ja, zeigt ein goldenes Banner den Raumcode mit "FORTSETZEN" (ruft einfach `joinRoom` mit dem bekannten Code erneut auf – die Edge Function lässt ein bestehendes Mitglied in jeder Phase wieder rein) und, nur wenn alle anderen Sitzplätze KI sind, zusätzlich "VERWERFEN" (ruft `leaveRoom` auf, das den Solo-Raum dann komplett löscht statt abzulehnen). Reconnect-Zustand lebt serverseitig (`room_players`-Mitgliedschaft), nicht lokal – maßgeblich für jedes Gerät.
- **Lobby**: Live-Spielerliste (Supabase-Realtime-Channel auf `rooms`/`room_players`, plus 5s-Poll-Fallback wie im Web-Pendant), Host-Kennzeichnung, "Spiel starten" (ruft `startGame` auf, inkl. derselben KI-Auffüll-Logik bis 3 Sitzplätze), Verlassen.
- **Spieltisch**: Trumpf wählen (wenn der Dealer einen Zauberer aufdeckt), bieten, Karten ausspielen, Stichanzeige, Rundenende mit Punktestand, "Nächste Runde"/"Nochmal spielen" (Host), KI-Züge (client-getriebenes `triggerAI` nach 2s Verzögerung, genau wie im Web-Pendant) und automatisches `clearTrick` nach 5s. Kartenanzeige ist bewusst nur textbasiert (Wert/Farbsymbol, kein Karten-Artwork) – eine eigene Asset-Pipeline ist nicht Teil dieser Phase.
- **Alle 9 "30 Jahre"-Sonderkarten**:
  - Drache/Seidenschnabel, Fee, Bombe/Elderstab, Vampir/Quirrell (Phase 4) brauchen client-seitig keine eigene Interaktion – sie laufen über das normale `playCard`, der Server behandelt ihre Sonderregeln (Schlagen/Verlieren/Stich-Annullierung/Trumpf-Kopie) selbst; die App zeigt sie nur korrekt an (Kurzlabel + Farbe, mirror von `specialConfigs` in `CardView.tsx`).
  - Werwolf/Lupin (Phase 4) löst eine eigene Phase `choosingWerewolf` aus (wer die Karte zieht, bestimmt die Stichfarbe für die ganze Runde – eigener Picker, analog zum Trumpf-Picker).
  - Zauberer-oder-Narr/Ron Weasley (Phase 4) zeigt beim Antippen einen Zauberer/Narr-Dialog und spielt die Karte über `playSpecial` statt `playCard`.
  - Jongleur/George Weasley (`rainbow7`) und Gleis 9¾ (`rainbow9`) (Phase 5) zeigen beim Antippen einen Farb-Dialog (die Farbe, mit der die Karte "kämpft") und spielen dann über `playCard` mit `suit`. Danach läuft serverseitig ein Nachlauf während `phase === "trickEnd"`: Jongleur verlangt von JEDEM Spieler eine Karte zum Weitergeben an den linken Nachbarn (`passCard`, eigener Picker über die ganze Hand); Gleis 9¾ verlangt vom Stichgewinner eine Anpassung seiner Vorhersage um ±1 (`rainbow9Adjust`, mit derselben "−1 nur wenn noch nicht im Ziel"-Einschränkung wie die Web-App). Sind beide im selben Stich, löst der Server Jongleur zuerst auf und Gleis 9¾ erst danach (`pending_rainbow9_deferred`) – rein serverseitig, die App muss das nicht selbst nachbilden.
  - Hexe/Bellatrix (`witch`) (Phase 5) läuft normal über `playCard`; nach Stichgewinn zeigt die App einen zweistufigen Dialog (erst eine Karte aus dem Stich nehmen, dann eine eigene Handkarte dafür abgeben, über `playSpecial`), gefolgt von einer kurzen `witchReveal`-Phase, die das Tausch-Ergebnis anzeigt (client-getriebenes `witchRevealDone` nach 4s, wie im Web-Pendant).
  - Alle drei pending-Zustände (Jongleur/Hexe/Gleis 9¾) existieren serverseitig ausschließlich während `phase === "trickEnd"` – die App zeigt während dieser Zeit statt des normalen "Stich gewinnt …"-Banners den jeweils zuständigen Dialog für die betroffene Person bzw. einen kurzen Warte-Hinweis für alle anderen.
- **Spielblatt & Spiel-Log** (Phase 6): zwei Sheets, über zwei Icon-Buttons im Spieltisch-Header erreichbar. Das Spielblatt zeigt die `round_history`-Tabelle rundenweise (laufende Summe + Ansage pro Spieler, berechnet wie `computeRunningTotals` in `App.tsx`) plus eine Live-Zeile für die aktuell laufende Runde; wird on-demand beim Öffnen geladen, nicht fortlaufend gepollt (die Tabelle wächst nur einmal pro Runde). Das Log zeigt `rooms.log` (dieselben Einträge wie im Web-Pendant) als einfache Liste.
- **Runde-1-Sonderregel "Indianer Poker"** (Phase 7): im Scoreboard zeigt jeder Mitspieler-Eintrag jetzt einen Hand-Indikator – in Runde 1 die echte(n) Karte(n) (über `visible_hand`, das `room_players_view` nur in Runde 1 für fremde Zeilen befüllt, siehe `000_full_reset.sql`), sonst nur eine verdeckte Zählung ("🂠 ×N"). Die eigene Hand wird in Runde 1 umgekehrt verdeckt angezeigt (`CardChipView(faceDown:)`, mirrors `faceDown={room.round === 1}` in `App.tsx`) – Tippen/Ausspielen funktioniert unverändert positionsbasiert, nur die Kartenseite ist anders.
- **Freunde-Tab** (Phase 9, Grundgerüst): per Username suchen und eine Anfrage senden (`sendFriendRequest`-Edge-Action, dieselbe Anti-Enumeration wie bei der Web-App – jede Antwort sieht gleich aus, egal ob der Name existiert, schon befreundet ist oder man sich selbst sucht), offene eingehende Anfragen annehmen/ablehnen, bestehende Freundschaften entfernen, ausstehende eigene Anfragen zurückziehen. Annehmen/Entfernen/Zurückziehen sind – wie im Web-Pendant – direkte, RLS-geschützte Schreibzugriffe auf `friends` (kein Edge-Function-Aufwand nötig), nicht nur bei `sendFriendRequest`.
- **Freunde, Rest** (Phase 12): Online-Status, Raum-Einladungen aus der Lobby, Freundesprofile.
  - **Online-Status**: `AppState` trackt einen globalen Supabase-Realtime-Presence-Channel ("online-users", Presence-Key = eigene User-ID, mirrors App.tsx), lebt sessionweit (nicht pro Tab) genau wie dort begründet ("LobbyScreen stays mounted for the whole session"). Die Swift-SDK-API ist AsyncStream-basiert (`presenceChange()` liefert `joins`/`leaves`-Diffs, kein `presenceState()`-Vollabzug wie im JS-Client) – ein leeres Set plus fortlaufendes Anwenden jedes Diffs konvergiert aber zum selben Ergebnis, da Phoenix Presence den initialen Stand beim Verbinden als `joins` liefert.
  - **Raum-Einladungen aus der Lobby**: in `LobbyView` (Warteraum-Phase) zeigt eine neue "Freunde einladen"-Liste alle bestätigten Freunde, die noch nicht am Tisch sitzen, mit einem EINLADEN-Button – schreibt direkt (RLS-geschützt, kein Edge-Function-Aufwand) eine Zeile in `room_invites`, genau wie `inviteFriend()` in `App.tsx`. Eingehend: `AppState` hält zusätzlich den zuletzt empfangenen offenen Invite als globales Banner (sichtbar unabhängig vom aktiven Tab, wie in `App.tsx`) mit "Beitreten"/"Ablehnen". "Beitreten" wechselt auf den Home-Tab und übergibt den Raumcode an `HomeView`, die den eigentlichen Join übernimmt (`HomeView` ist die einzige Stelle hier, die den Begriff "aktiver Raum" überhaupt kennt) – eine kleine Vereinfachung gegenüber dem Web, wo `roomId` den ganzen Bildschirm unabhängig vom aktiven Tab ersetzt. Die Web-App abonniert `room_invites`-INSERT/DELETE per Realtime; die native App pollt stattdessen alle 10s (dieselbe Begründung/Kadenz wie bei `friends_active_rooms`).
  - **Freundesprofile**: Antippen eines bestätigten Freundes öffnet `FriendProfileView` – Avatar-Initiale, Name, "Seit MONAT JAHR · N Partien", dieselbe Statistik-Ansicht wie der eigene Statistik-Tab (`StatsSummaryView`, aus Phase 11 extrahiert und für eine beliebige `userId` parametrisiert wiederverwendet – `user_stats`/`game_stats` sind für jede User-ID lesbar, nicht nur die eigene).
- **Zuschauer-Modus** (Phase 10): im Freunde-Tab zeigt jeder Freund, der gerade in einem laufenden Raum sitzt ("Spielt gerade · Runde X", über `friends_active_rooms`, alle 10s neu geladen wie im Web-Pendant), einen ZUSCHAUEN-Button. Der ruft `spectateRoom` auf (serverseitig geprüft: nur mit einem bestätigten Freund im Zielraum erlaubt) und öffnet dann `SpectatorView` – einen bewusst eigenständigen, rein lesenden Spieltisch (kein `GameView` mit einem `isSpectator`-Flag, aus demselben Grund wie beim Web-Pendant `SpectatorRoom`/`GameRoom`, siehe `docs/ARCHITECTURE.md`: zu viele Verzweigungen würden sonst implizit einen echten Sitzplatz voraussetzen). "ZUSCHAUEN BEENDEN" ruft `leaveSpectating` auf. Da Zuschauer keine eigene `room_players`-Zeile haben, gibt es (wie im Web-Pendant) keinen Realtime-Stream auf dieser Tabelle – nur ein `rooms`-UPDATE-Watch plus 5s-Poll-Fallback.
- **Statistik-Tab** (Phase 11): vier Kennzahlen-Kacheln (Spiele/Siege/Ø Punkte/Ø Platz, aus der `user_stats`-View) plus Trefferquote-Balken, darunter "Letzte Partien" (bis zu 20, aus `game_stats`) – antippen klappt die Mitspieler-Platzierungen der jeweiligen Partie auf. Mirrors `usePastGames()`/`StatsScreen` in `App.tsx` mit einer bewussten Vereinfachung: die client-seitige Heuristik, die dort sehr alte, verwaiste Partien (vor `022_game_session_id.sql`, deren `room_id` durch die Aufräum-Routine schon auf `null` gesetzt wurde) anhand der Zeitnähe (`played_at`) zu rekonstruieren versucht, wird hier nicht nachgebaut – jede Partie seit dieser Migration trägt immer eine `game_session_id`, trifft also nur eine schrumpfende Menge historischer Altdaten. Diese wenigen Fälle zeigen stattdessen einfach "Mitspieler-Daten nicht mehr verfügbar", wie jeder andere `roomDataAvailable: false`-Fall auch. Manuelle (Rechenblock-)Partien werden korrekt aus `manual_game_rounds.results` rekonstruiert (dieselbe `RoundResult`-Form wie `round_history`), obwohl der digitale Rechenblock selbst noch keine eigene Phase hat.
- Tab-Leiste (Home/Freunde/Statistik/Profil, siehe `TabKey` in `App.tsx`) – alle vier Tabs zeigen jetzt echte Daten.

### Warum Freunde vor Zuschauer-Modus kam

Der ursprüngliche Vorschlag hatte den Zuschauer-Modus vor Freunde eingeplant. Beim genaueren Hinsehen stellte sich das als nicht umsetzbar heraus: `spectateRoom` (index.ts) setzt serverseitig zwingend voraus, dass der Zuschauer mit mindestens einem Spieler im Zielraum bereits befreundet ist (`hasFriendInRoom`-Check), und die einzige Entdeckungsmöglichkeit dafür – welcher Freund spielt gerade wo – ist `friends_active_rooms`, das wiederum eine bestehende Freundesliste voraussetzt. Ohne irgendeine Freunde-UI gäbe es in der App keinen Weg, überhaupt an einen Raumcode zum Zuschauen zu kommen. Deshalb kam das Freunde-Grundgerüst zuerst; Zuschauer-Modus ist jetzt der nächste sinnvolle Schritt (siehe unten).

### Beim Reconnect-Abgleich entdeckt: `room_players`-RLS liefert bei der Web-App immer `dismissible: true`

`checkReconnect()`'s zweite Abfrage (wer sitzt sonst noch am Tisch) läuft in `App.tsx` gegen die rohe `room_players`-Tabelle. Deren RLS-Policy `rp_select_own` (`000_full_reset.sql`) erlaubt aber **nur** `auth.uid() = user_id` – jede Zeile außer der eigenen wird dort serverseitig stillschweigend herausgefiltert, egal welcher Filter im Query steht. Dadurch ist `others` in der Web-App praktisch immer leer und `dismissible` praktisch immer `true`, unabhängig davon, ob wirklich noch ein Mensch am Tisch sitzt – `leaveRoom` selbst prüft das serverseitig aber ohnehin korrekt nochmal (`hasOtherHuman` in `index.ts`), insofern blieb das bisher folgenlos. Die native App fragt für diese eine Abfrage stattdessen `room_players_view` ab (dieselbe Quelle, die überall sonst für Mitspieler-Daten genutzt wird) und berechnet `dismissible` damit tatsächlich korrekt.

Was **noch nicht** existiert (jeweils eigene, größere Phasen oder gezielte Nacharbeiten):
- Kein client-seitiges Hervorheben spielbarer/unspielbarer Karten (der Server validiert ohnehin jeden Zug serverseitig und lehnt ungültige mit einer Fehlermeldung ab – das ist bewusst die einzige Fehlerquelle für Phase 3, um die KI-/Sonderkarten-Regellogik nicht ein zweites Mal im Client nachbauen zu müssen)
- Zuschauer-Modus: Sprachchat für Zuschauer (braucht die noch nicht gebaute Sprachchat-Phase insgesamt) – die eigentliche Zuschauer-Funktion (Entdecken, Beitreten, rein lesender Spieltisch) gibt es seit Phase 10
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
      AppState.swift           # Session-Zustand + sessionweite Presence/Invite-Beobachtung (ObservableObject)
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
      Friends/                   # Freunde-Tab: suchen/anfragen/annehmen/entfernen, Zuschauer-Entdeckung, Freundesprofile
      Spectator/                 # Zuschauer-Modus: rein lesender SpectatorView/SpectatorViewModel
      Stats/                     # Statistik-Tab: Kennzahlen + Letzte Partien
      Profile/                   # Profil-Tab (echte Daten)
    Resources/
      Assets.xcassets/          # App-Icon + Accent-Farbe, aus dem bestehenden Branding generiert
```

Jede weitere Phase bekommt ihren eigenen Ordner unter `Features/` nach demselben Schema: eine `*View.swift` (SwiftUI) + ein `*ViewModel.swift` (`ObservableObject`, hält den `async`-Zugriff auf `SupabaseService.client`).

## Nächste sinnvolle Phase

Mit Phase 5 sind alle neun Sonderkarten und damit die komplette "30 Jahre"-Edition vollständig spielbar; Phase 6 hat Spielblatt und Log nachgerüstet, Phase 7 die Indianer-Poker-Anzeige, Phase 8 das Reconnect, Phase 9+12 die Freunde komplett, Phase 10 den Zuschauer-Modus, Phase 11 die Statistik. Der Spieltisch samt Lobby/Reconnect/Zuschauen/Freunde hat damit funktional Web-Parität erreicht (abgesehen vom noch fehlenden Sprachchat für Zuschauer, der ohnehin erst mit der Sprachchat-Phase insgesamt Sinn ergibt). Was jetzt noch fehlt, sind die großen, eigenständigen Feature-Blöcke – jeder vermutlich mindestens eine eigene Phase, grob nach Aufwand sortiert:

- **Digitaler Rechenblock** (eigenständiges Feature für offline/physische Partien, nicht zu verwechseln mit dem Spielblatt aus Phase 6 – siehe `ManualScoreboardScreen` in `docs/ARCHITECTURE.md`)
- **Sprachchat** (WebRTC, inkl. Hintergrund-Audio) – der ursprüngliche Hauptgrund für den nativen Weg, vermutlich der aufwändigste Block
- **Echte Push-Benachrichtigungen** (APNs)
- **Avatar-Upload**
