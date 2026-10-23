# iOS-App (nativ, SwiftUI)

Wizzo wird komplett nativ als SwiftUI-App neu gebaut (nicht als Web-Wrapper) – die PWA (`wizard/`) ist der Übergang, die native App soll sie langfristig ablösen. Dieses Dokument beschreibt Architektur, Setup und den aktuellen Stand.

## Warum nativ statt PWA-Wrapper

Kurz zusammengefasst aus der Diskussion, die zu dieser Entscheidung geführt hat: ein reiner Wrapper (z. B. Capacitor) hätte den bestehenden Web-Code 1:1 übernommen, aber eben auch dessen Grenzen – kein wirklich natives Gefühl (Scrollen/Übergänge/Gesten bleiben Web), Sprachchat bricht im Hintergrund ab, Web-Push ist auf iOS unzuverlässig. Da ein echtes natives Gefühl gewünscht war und die PWA ohnehin nicht weiterbetrieben werden soll, baut die App stattdessen die komplette UI in SwiftUI neu, gegen **dasselbe, unveränderte Supabase-Backend** (Postgres/RLS/Realtime/Edge-Function) wie die Web-App – siehe [`ARCHITECTURE.md`](ARCHITECTURE.md) und [`DATABASE.md`](DATABASE.md) für das Backend, das hier 1:1 weiterverwendet wird.

## Stand: Phase 1-16 (Grundgerüst, Auth, Profil, Räume/Lobby, Spieltisch inkl. aller 9 Sonderkarten, Spielblatt & Log, Indianer Poker, Reconnect, Freunde komplett, Zuschauer-Modus, Statistik, Digitaler Rechenblock, Avatar-Upload, echte Push-Benachrichtigungen, Sprachchat)

Was aktuell existiert und **echt gegen das Supabase-Projekt funktioniert**:

- Projekt-Grundgerüst (SwiftUI, iOS 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)-verwaltet)
- Supabase-Anbindung über das offizielle [`supabase-swift`](https://github.com/supabase/supabase-swift)-SDK (Auth, Postgrest, Realtime)
- **Anmelden/Registrieren**: repliziert exakt die Logik aus `AuthScreen` in `wizard/frontend/src/App.tsx` – es gibt keine echte E-Mail, nur einen Namen; dahinter steht eine synthetische `<slug>@wizard.local`-Adresse mit einem abgeleiteten Standardpasswort, wenn keins gesetzt wird. **Das muss exakt übereinstimmen**, sonst können sich Web- und App-Nutzer nicht gegenseitig mit denselben Konten anmelden.
- **Profil-Tab**: lädt die eigene `profiles`-Zeile, zeigt Name + Mitglied-seit, funktionierendes Abmelden.
- **Home-Tab**: Raum erstellen (Edition wählbar – Classic oder "30 Jahre") oder per Code beitreten – ruft dieselben `createRoom`/`joinRoom`-Edge-Function-Aktionen auf wie die Web-App. Beim Öffnen prüft `checkReconnect()` (Phase 8, mirrors `checkReconnect()` in `App.tsx`), ob der eigene `room_players`-Eintrag noch in einem nicht beendeten Raum steckt – falls ja, zeigt ein goldenes Banner den Raumcode mit "FORTSETZEN" (ruft einfach `joinRoom` mit dem bekannten Code erneut auf – die Edge Function lässt ein bestehendes Mitglied in jeder Phase wieder rein) und, nur wenn alle anderen Sitzplätze KI sind, zusätzlich "VERWERFEN" (ruft `leaveRoom` auf, das den Solo-Raum dann komplett löscht statt abzulehnen). Reconnect-Zustand lebt serverseitig (`room_players`-Mitgliedschaft), nicht lokal – maßgeblich für jedes Gerät.
- **Lobby**: Live-Spielerliste (Supabase-Realtime-Channel auf `rooms`/`room_players`, plus 5s-Poll-Fallback wie im Web-Pendant), Host-Kennzeichnung, "Spiel starten" (ruft `startGame` auf, inkl. derselben KI-Auffüll-Logik bis 3 Sitzplätze), Verlassen.
- **Spieltisch**: Trumpf wählen (wenn der Dealer einen Zauberer aufdeckt), bieten, Karten ausspielen, Stichanzeige, Rundenende mit Punktestand, "Nächste Runde"/"Nochmal spielen" (Host), KI-Züge (client-getriebenes `triggerAI` nach 2s Verzögerung, genau wie im Web-Pendant) und automatisches `clearTrick` nach 5s.
- **Kartenbilder & Tisch-Theming** (nachträglich, nach dem ersten echten Geräte-Test über TestFlight – erst da fiel auf, wie groß der optische Unterschied zur PWA tatsächlich war): `CardChipView` zeigt jetzt dieselben WebP-Illustrationen wie die Web-App (`wizard/frontend/public/cards/`, 1:1 nach `ios/Wizzo/Resources/Cards/` kopiert, als `type: folder`-Quelle in `project.yml` – wichtig, sonst flacht XcodeGen die Unterordnerstruktur beim Bündeln ab und `Card.artImageName`s `Bundle`-Lookup mit `subdirectory: "Cards"` liefe ins Leere). `Card+Art.swift` bildet dieselbe Dateinamens-Logik wie `CardView.tsx` nach (Haus-Ordner pro Farbe, `Wizard_1-4`/`Fool_1-4` nach Karten-id, feste Namen pro Sonderkarte), mit In-Memory-Cache (`CardArtCache`) und Text-Fallback falls ein Bild fehlt. iOS dekodiert WebP nativ seit iOS 14, keine zusätzliche Bibliothek nötig. `GameView` bekam dazu einen dem Web nachempfundenen Tisch-Hintergrund (Radial-Gradient statt flacher Fläche), ein "WIZZO"-Branding im Header und Spieler-Badges mit Gold-Glow bei aktivem Spieler. Die kreisförmige Sitzanordnung um den Tisch wurde nachgezogen (dem Nutzer wichtig, initial als separater Scope zurückgestellt): `GameView.seatEntries(room:)` bildet `getSeatPositions()` aus `App.tsx` 1:1 nach (gleiche Offset→Position-Zuordnung je Spieleranzahl 2–6, relativ zur eigenen Sitzposition), `seatAnchor(for:)` die prozentualen `seatPos()`-Koordinaten als `UnitPoint`-Brüche für ein `GeometryReader`. Die eigene Sitz-Badge (`mySeatBadge`) sitzt dabei bewusst im normalen Layout-Fluss direkt über der Hand statt wie im Web mit einem per Pixel geschätzten festen Abstand – robuster gegenüber unterschiedlicher Handbereich-Höhe je Phase, optisch aber gleichwertig. Weiterhin bewusst **nicht** nachgebaut: das Cinzel-Schriftbild (Web lädt es per Google-Fonts-`<link>`, native nutzt `.serif`-Systemschrift als Näherung statt eine eigene Font-Datei zu bündeln).
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
- **Statistik-Tab** (Phase 11): vier Kennzahlen-Kacheln (Spiele/Siege/Ø Punkte/Ø Platz, aus der `user_stats`-View) plus Trefferquote-Balken, darunter "Letzte Partien" (bis zu 20, aus `game_stats`) – antippen klappt die Mitspieler-Platzierungen der jeweiligen Partie auf. Mirrors `usePastGames()`/`StatsScreen` in `App.tsx` mit einer bewussten Vereinfachung: die client-seitige Heuristik, die dort sehr alte, verwaiste Partien (vor `022_game_session_id.sql`, deren `room_id` durch die Aufräum-Routine schon auf `null` gesetzt wurde) anhand der Zeitnähe (`played_at`) zu rekonstruieren versucht, wird hier nicht nachgebaut – jede Partie seit dieser Migration trägt immer eine `game_session_id`, trifft also nur eine schrumpfende Menge historischer Altdaten. Diese wenigen Fälle zeigen stattdessen einfach "Mitspieler-Daten nicht mehr verfügbar", wie jeder andere `roomDataAvailable: false`-Fall auch. Manuelle (Rechenblock-)Partien werden korrekt aus `manual_game_rounds.results` rekonstruiert (dieselbe `RoundResult`-Form wie `round_history`).
- **Digitaler Rechenblock** (Phase 13): über einen neuen "RECHENBLOCK"-Button auf dem Home-Tab erreichbar (gleiche Platzierung wie der Button auf `LobbyScreen` im Web), mirrors `ManualScoreboardScreen`/`ManualGameSetup`/`ManualGamePlay`/`ManualFinishedGameView` in `App.tsx` komplett: Mitspieler erfassen (registrierte Nutzer per Live-Username-Suche, `.ilike` mit 250ms Debounce über SwiftUIs `.task(id:)` – kein manuelles Timer-Bookkeeping nötig, anders als im Web – oder einfach ein Gast-Name), Sitzreihenfolge festlegen, dann rundenweise Ansage/Stiche erfassen (eine Person zur Zeit, in echter Bietreihenfolge, inkl. Stichzwang-Warnung für den Geber), Runden nachträglich korrigieren, Wolke/9¾-Vorhersage-Anpassung, Spiel abschließen (`finishManualGame`-Edge-Action, wie beim Web nötig weil `game_stats`' Insert-Policy service-role-only ist) oder verwerfen. Schreibzugriff auf `manual_games`/`manual_game_players`/`manual_game_rounds` läuft komplett direkt vom Client (RLS: nur der Host, siehe `010_manual_games.sql`) – wie im Web gibt es dafür keine eigene Realtime/Poll-Überwachung, da es pro Partie nur einen Schreiber (den Host selbst) gibt und auch die Web-App mitspielenden, nicht-Host-Accounts keine eigene Ansichts-UI gibt, obwohl deren Lese-RLS das erlauben würde. Eine Vereinfachung gegenüber dem Web: die Sitzreihenfolge wird über SwiftUIs eingebautes `List`-Drag-and-Drop (`.onMove`, dauerhaft im Edit-Modus) statt der Web-eigenen Pointer-Events-Drag-Implementierung sortiert.
  - **Nebenbei gefundener und gefixter Bug aus Phase 11**: `RoundResult.totalScore` war non-optional, aber `manual_game_rounds.results` schreibt dieses Feld nie (`saveRound()` in `App.tsx` setzt nur playerIndex/name/bid/got/delta) – das Decoding von `ManualGameRoundRow` in `StatsViewModel` warf deshalb für jede Partie mit mindestens einer manuellen Runde eine Exception, die den äußeren `catch` auslöste und die komplette "Letzte Partien"-Liste leer zeigte, nicht nur die betroffene manuelle Partie. `totalScore` ist jetzt optional (und wird ohnehin nirgends gelesen – auch das Spielblatt in `GameView` berechnet seine laufenden Summen selbst, nicht über dieses Feld).
- **Avatar-Upload** (Phase 14): Profil-Tab bekommt einen Stift-Button über dem eigenen Avatar (`PhotosPicker`, iOS-16-API), der ein Bild auswählt, client-seitig auf max. 512pt verkleinert/als JPEG komprimiert (`UIGraphicsImageRenderer`, mirrors `processAvatarImage()`s Canvas-Resize in `App.tsx`) und in den öffentlichen `avatars`-Storage-Bucket unter `<user_id>/avatar.jpg` hochlädt (upsert, RLS beschränkt Schreibzugriff bereits auf den eigenen Pfad, siehe `003_avatars.sql` – kein Edge-Function-Aufwand nötig). Die resultierende, cache-gebustete Public-URL geht direkt in `profiles.avatar_url`. Ein neuer gemeinsamer `AvatarView`-Baustein (zeigt das Bild, sonst einen farbigen Kreis mit Namens-Initiale) ersetzt die bisherigen reinen Initialen-Kreise überall dort, wo eine Person angezeigt wird und das Nachladen von `avatar_url` ohnehin günstig war: Profil, Freunde-Liste, Freundesprofil, Lobby (Sitzplätze + Freunde-einladen-Liste). `room_players_view` trägt `avatar_url` nicht selbst – die Lobby lädt sie wie die Web-App über eine separate, gebündelte `profiles`-Abfrage nach User-IDs.
- **Echte Push-Benachrichtigungen** (Phase 15): Profil-Tab bekommt eine "Benachrichtigungen"-Sektion mit genau demselben "„Du bist dran"/AN-AUS"-Umschalter wie die Web-App (`togglePush()` in `App.tsx`) – bewusst nur Opt-in, nie automatisch beim Start angefragt. Mirrors das bestehende Web-Push-System (`push_subscriptions`, 008_push_subscriptions.sql, von der Edge Function in `sendTurnPush()` bei "du bist dran"/Trumpf wählen/Werwolf-Stichfarbe/Jongleur-Weitergabe/Wolke-Anpassung/Hexe-Tausch ausgelöst) 1:1 für native APNs statt Web Push:
  - Neue Tabelle `apns_device_tokens` (023_apns_device_tokens.sql, gleiche RLS-Form wie `push_subscriptions` – nur eigene Zeilen, direkter Client-Schreibzugriff) speichert das APNs-Gerätetoken; `unique` auf `device_token` allein (nicht `(user_id, device_token)` wie bei `push_subscriptions`), weil ein Token physisch an ein Gerät/Install gebunden ist, nicht an einen Account – meldet sich ein anderer Nutzer auf demselben Gerät an, bekommt dieselbe Zeile per Upsert einfach einen neuen Besitzer.
  - `sendTurnPush()` in `index.ts` fragt jetzt zusätzlich `apns_device_tokens` ab und sendet über eine neue `sendApnsPush()` – ein POST an `https://api(.sandbox).push.apple.com/3/device/<token>` mit einem ES256-JWT (`npm:jose@5`, Apple-Dok fordert, nicht pro Push ein neues Token zu signieren – deshalb modulweiter Cache mit ~50-Minuten-TTL, gleiches "mutabler State über warme Invocations hinweg"-Muster wie `rateMap`/`friendFailMap` oben in derselben Datei). Fehlt `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_AUTH_KEY`, wird das Senden stillschweigend übersprungen, exakt wie bei fehlender VAPID-Konfiguration – diese drei Secrets müssen vom Projektinhaber selbst über `supabase secrets set` hinterlegt werden (siehe `docs/DEVELOPMENT.md`), da sie aus dem eigenen Apple-Developer-Account stammen und hier nirgends simulierbar sind.
  - iOS-seitig: `PushNotificationManager` überbrückt die beiden `UIApplicationDelegate`-Callbacks, die `registerForRemoteNotifications()` erfordert (kein async/await-Äquivalent dafür), über eine `CheckedContinuation` in ein einziges `await`; "AN" entspricht einer existierenden Zeile in `apns_device_tokens` für den eigenen Account (serverseitig geprüft, nicht nur lokaler Berechtigungsstatus – dieselbe Begründung wie beim Web, das `pushManager.getSubscription()` statt nur `Notification.permission` liest).
  - Neues `aps-environment`-Entitlement (`ios/project.yml`, Wert `development` – Xcode schreibt das beim Archivieren für TestFlight-extern/App-Store-Builds automatisch auf `production` um, dafür gibt es auch das `APNS_ENV`-Secret serverseitig).
  - **Einzige neue Backend-Tabelle in der gesamten iOS-Portierung bisher** – jede frühere Phase hat ausschließlich bereits bestehendes Schema wiederverwendet; hier gibt es auf der Web-Seite kein Gerätetoken-Äquivalent (Web Push braucht keins), also war eine neue, eigenständige Tabelle nötig statt nur eines weiteren Lesezugriffs auf etwas Bestehendes.
- **Sprachchat** (Phase 16): opt-in P2P-WebRTC-Mesh zwischen den Mitspielern eines Raums (und Zuschauern - `getIceServers` erlaubt serverseitig beide schon, siehe `index.ts`), signalisiert über einen Supabase-Realtime-Broadcast-Channel `voice:<roomId>` (kein eigener Signaling-Server), ICE-Server über die bereits bestehende `getIceServers`-Edge-Action (STUN + selbst gehostetes TURN). Mirrors `useVoiceChat` in `App.tsx` 1:1 im Signaling-Protokoll (dieselben `{type, from, to, sdp, candidate}`-Nachrichtenformen über denselben Channel-Namen und Event-Namen `"signal"` – ein nativer und ein Web-Client landen im selben Raum potenziell im selben Mesh und müssen sich gegenseitig verstehen, ebenso die "kleinere User-ID bietet an"-Glare-Vermeidung).
  - **WebRTC-Framework**: kein offizielles SPM-Paket – Google hat die eigene mobile Binärverteilung seit M80 eingestellt. Verwendet [`stasel/WebRTC`](https://github.com/stasel/WebRTC) (community-gepflegte, unveränderte Kompilate von Googles eigenem WebRTC-Quellcode, als XCFramework per SPM). Jede verwendete Methode/Property (`RTCPeerConnectionFactory`, `RTCConfiguration`, `RTCIceServer`, `RTCMediaConstraints`, `RTCPeerConnection.offer/answer/setLocalDescription/setRemoteDescription/addIceCandidate/transceivers`, `RTCAudioSession.setCategory/setMode`, …) wurde einzeln gegen die tatsächlich im XCFramework der gepinnten Version 155.0.0 enthaltenen Objective-C-Header geprüft (heruntergeladen und entpackt, nicht aus dem Gedächtnis) – zusätzlich gegen [`stasel/WebRTC-iOS`](https://github.com/stasel/WebRTC-iOS), eine Demo-App desselben Autors, mit einer wichtigen Korrektur: deren `WebRTCClient.swift` ruft `RTCAudioSession.setCategory(_:)` einarmig auf, was es in den aktuellen (M155-)Headern nicht mehr gibt (nur noch die 2-/3-armigen `setCategory(_:mode:options:)`/`setCategory(_:withOptions:)`-Overloads) – die Demo ist offensichtlich gegen eine ältere WebRTC-Version geschrieben. Native App nutzt die tatsächlich im Header vorhandene `setCategory(_:mode:options:)`-Variante.
  - **Audio-only**: wie die Web-App gibt es keinen Video-Track – bei WebRTC-Audio spielt die Gegenseite automatisch über die konfigurierte `AVAudioSession`-Route, ohne dass die App selbst einen "Renderer" anhängen muss (anders als bei Video); entsprechend gibt es auch keinen `ontrack`-Handler-Ersatz, `participantIds` wird stattdessen über `RTCPeerConnectionDelegate`s Connection-State-Change (`.connected`/`.completed`) befüllt.
  - **Bewusst nicht nachgebaut**: der Web-eigene Sprechende-Indikator (Web-Audio-Analyser → grüner/grauer Punkt) – dessen eigener Kommentar im Web-Code nennt ihn ausdrücklich "nur Kosmetik, Verbindung funktioniert auch ohne". Hätte client-seitiges Audio-Pegel-Polling (WebRTC-Stats oder ein Audio-Tap) ohne jeden Verhaltensunterschied bedeutet. `participantIds` (wer verbunden ist) bleibt erhalten, da das UI-Mikrofonsymbol an einem Sitzplatz strukturell davon abhängt, nicht nur kosmetisch.
  - **Lebenszyklus**: `VoiceChatManager` wird einmal pro Raumbesuch erzeugt und muss die Lobby→Spiel-Phasenumschaltung überleben – `LobbyView` besitzt die Instanz (genau wie `App.tsx`s `useVoiceChat` bewusst in `LobbyScreen` lebt statt in `GameRoom`, siehe dessen eigener Kommentar) und reicht sie als Parameter an `GameView` weiter; `SpectatorView` besitzt ihre eigene Instanz, da Zuschauen nie über `LobbyView` läuft.
  - **UI**: große "Sprachchat aktivieren"-Karte mit Teilnehmerliste (Name + Stummschalt-Button pro Person) im Warteraum (`LobbyView`), kompaktes Mikrofon-/Verlassen-Icon-Paar im Header während des laufenden Spiels (`GameView`) bzw. beim Zuschauen (`SpectatorView`) plus ein kleines Mikrofon-Symbol pro Sitzplatz im Scoreboard, wenn diese Person verbunden ist – spiegelt exakt, wo und wie `App.tsx` dieselben Steuerelemente in `GameRoom`/`SpectatorRoom` zeigt.
  - Neues `UIBackgroundModes: [audio]` in `project.yml`, damit ein laufender Sprachchat im Hintergrund weiterläuft – der eigentliche, ursprüngliche Grund für den gesamten nativen Weg (siehe "Warum nativ statt PWA-Wrapper" oben).
- Tab-Leiste (Home/Freunde/Statistik/Profil, siehe `TabKey` in `App.tsx`) – alle vier Tabs zeigen jetzt echte Daten.

### Warum Freunde vor Zuschauer-Modus kam

Der ursprüngliche Vorschlag hatte den Zuschauer-Modus vor Freunde eingeplant. Beim genaueren Hinsehen stellte sich das als nicht umsetzbar heraus: `spectateRoom` (index.ts) setzt serverseitig zwingend voraus, dass der Zuschauer mit mindestens einem Spieler im Zielraum bereits befreundet ist (`hasFriendInRoom`-Check), und die einzige Entdeckungsmöglichkeit dafür – welcher Freund spielt gerade wo – ist `friends_active_rooms`, das wiederum eine bestehende Freundesliste voraussetzt. Ohne irgendeine Freunde-UI gäbe es in der App keinen Weg, überhaupt an einen Raumcode zum Zuschauen zu kommen. Deshalb kam das Freunde-Grundgerüst zuerst; Zuschauer-Modus ist jetzt der nächste sinnvolle Schritt (siehe unten).

### Beim Reconnect-Abgleich entdeckt: `room_players`-RLS liefert bei der Web-App immer `dismissible: true`

`checkReconnect()`'s zweite Abfrage (wer sitzt sonst noch am Tisch) läuft in `App.tsx` gegen die rohe `room_players`-Tabelle. Deren RLS-Policy `rp_select_own` (`000_full_reset.sql`) erlaubt aber **nur** `auth.uid() = user_id` – jede Zeile außer der eigenen wird dort serverseitig stillschweigend herausgefiltert, egal welcher Filter im Query steht. Dadurch ist `others` in der Web-App praktisch immer leer und `dismissible` praktisch immer `true`, unabhängig davon, ob wirklich noch ein Mensch am Tisch sitzt – `leaveRoom` selbst prüft das serverseitig aber ohnehin korrekt nochmal (`hasOtherHuman` in `index.ts`), insofern blieb das bisher folgenlos. Die native App fragt für diese eine Abfrage stattdessen `room_players_view` ab (dieselbe Quelle, die überall sonst für Mitspieler-Daten genutzt wird) und berechnet `dismissible` damit tatsächlich korrekt.

Was **noch nicht** existiert (jeweils eigene, größere Phasen oder gezielte Nacharbeiten):
- Kein client-seitiges Hervorheben spielbarer/unspielbarer Karten (der Server validiert ohnehin jeden Zug serverseitig und lehnt ungültige mit einer Fehlermeldung ab – das ist bewusst die einzige Fehlerquelle für Phase 3, um die KI-/Sonderkarten-Regellogik nicht ein zweites Mal im Client nachbauen zu müssen)
- Push-Benachrichtigungen jenseits von "du bist dran" (z. B. neue Freundschaftsanfrage, Raum-Einladung) – Phase 15 deckt nur dieselben Trigger ab, die die Web-App schon hat
- Sprechende-Indikator im Sprachchat (bewusste Vereinfachung, siehe Phase 16 oben – die Web-App selbst nennt das "nur Kosmetik")
- ICE-Restart/Reconnect-Logik im Sprachchat bei einer "disconnected"/"failed"-Verbindung (wird wie im Web-Pendant einfach als Verbindungsabbruch behandelt, kein automatischer Wiederaufbau)

Realistisch betrachtet ist das hier erst ein Anfang unter vielen Phasen – Vollständigkeit ist kein Wochenend-, sondern ein Mehrmonatsprojekt für dieses Feature-Set. Jede weitere Phase sollte als eigener, in sich abgeschlossener Schritt kommen (gleiches Muster wie der Rest dieses Repos), nicht als ein einziger riesiger, ungeprüfter Umbau.

## Wichtige Einschränkung: hier nicht kompilierbar geprüft

Der gesamte Swift-Code in diesem Verzeichnis wurde **ohne Zugriff auf Xcode/einen Swift-Compiler** geschrieben (Linux-Dev-Umgebung – Apple erlaubt iOS-Builds grundsätzlich nur auf macOS, das ist keine Einschränkung dieses Setups). Die Methodensignaturen des `supabase-swift`-SDK (`signUp`, `signIn`, `.from().select().eq().single().execute().value`, die Realtime-API `channel(...).postgresChange(...)`/`.subscribe()`/`.unsubscribe()`, …) wurden gezielt gegen die offiziellen Beispiel-Apps ([UserManagement](https://github.com/supabase/supabase-swift/tree/main/Examples/UserManagement), [SlackClone](https://github.com/supabase/supabase-swift/tree/main/Examples/SlackClone)) und den SDK-Quellcode selbst abgeglichen (konkret auch die exakten `eq(_:value:)`/`select(_:)`-Parameter-Label, siehe den Bugfix-Absatz unten), nicht aus dem Gedächtnis geraten.

**Seit `.github/workflows/ios-build.yml` gibt es jetzt trotzdem einen echten Korrektheitstest**, ganz ohne lokalen Mac: ein GitHub-Actions-Workflow auf einem echten macOS-Runner generiert das Xcode-Projekt (XcodeGen) und compiliert es ungesigniert für den iOS-Simulator – bei jedem Push/PR, der `ios/**` berührt. Der erste echte Durchlauf (nach Phase 16) fand fünf reale, bis dahin nie aufgefallene Fehler, alle aus früheren Phasen, nicht aus einer einzelnen – jeweils einzeln gefixt und dokumentiert in den Commit-Messages dieser Historie:
1. `PhotosPickerItem` (PhotosUI) ist in einer Nicht-View-Datei erst sichtbar, wenn dort zusätzlich `import SwiftUI` steht, nicht nur `import PhotosUI`.
2. `RealtimeChannel` ist **nicht** `RealtimeChannelV2` – das ist die separate, alte, deprecated V1-Klasse des SDKs. `channel(...)` gibt `RealtimeChannelV2` zurück; jede `private var channel: RealtimeChannel?`-Deklaration war ein Typfehler.
3. Die echte Methode heißt `postgresChange` (Singular), nicht `postgresChanges`.
4. `guard let x = x ?? (try? await ...)` funktioniert nicht zuverlässig – `??`s Autoclosure unterstützt kein `await` in ihrem rechten Operanden; stattdessen zwei getrennte Anweisungen (erst auflösen, dann guarden).
5. Ein Closure-Parameter, der in ein `ForEach` (dessen `content`-Closure `@escaping` ist) hineingereicht wird, muss selbst `@escaping` sein.

Alle fünf sind jetzt gefixt, der Workflow ist grün. Das bestätigt: die "gegen echten SDK-Quellcode abgeglichen, nicht geraten"-Methodik dieses ganzen Ports war im Großen und Ganzen richtig – die verbliebenen Fehler waren alle kleine, lokale Verwechslungen (Typname, Methodenname, eine Sprachfeinheit), keine grundsätzlichen Architekturfehler, und wurden jetzt durch einen echten Compiler statt durch weiteres manuelles Nachlesen gefunden.

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
2. **Bundle Identifier** prüfen: `de.koeven.wizzo` (in `project.yml` gesetzt) – muss mit einer App-ID in [App Store Connect](https://appstoreconnect.apple.com/) übereinstimmen.
3. Simulator oder eigenes Gerät wählen, ▶️.

Nach jeder Änderung an `project.yml` (neues Target-Setting, neue Dependency, …): `xcodegen generate` erneut ausführen. Neue `.swift`-Dateien im `Wizzo/`-Ordner werden von XcodeGen automatisch erkannt (keine manuelle "Add to target"-Pflege).

## TestFlight ohne Mac

Der Workflow `TestFlight` (GitHub → Actions → „TestFlight" → Run workflow) baut Wizzo als Release, signiert automatisch und lädt es zu TestFlight hoch – kein lokaler Mac nötig. Gleiches Muster wie beim Meeterz-Projekt: `ios/ci/asc.py` erzeugt pro Lauf über die App-Store-Connect-API ein frisches Distribution-Zertifikat + App-Store-Profil (statt eines fest hinterlegten P12-Exports) und löscht beides nach ~2 Stunden wieder (`purge`). Dafür einmalig:

### 1. Developer-Account
1. https://developer.apple.com/programs/enroll/ → als Privatperson anmelden (99 €/Jahr).
2. Nach der Freigabe: **Team-ID** notieren (developer.apple.com → Account → Mitgliedschaft → „Team-ID", 10 Zeichen).

### 2. App-ID anlegen (developer.apple.com → Certificates, IDs & Profiles → Identifiers → +)
- Typ **App IDs → App**, Bundle ID **explizit** `de.koeven.wizzo`
- Capability anhaken: **Push Notifications**

### 3. App in App Store Connect anlegen (appstoreconnect.apple.com → Apps → + → Neue App)
- Plattform iOS, Name „Wizzo" (falls vergeben, anderen Namen wählen – er kann später geändert werden), Primärsprache Deutsch
- Bundle ID `de.koeven.wizzo`, SKU frei wählbar (z. B. `wizzo-001`)

### 4. API-Schlüssel erzeugen (App Store Connect → Benutzer und Zugriff → Integrationen → App Store Connect API → +)
- Name „GitHub CI", Zugriff **Admin** (nötig, damit die CI selbst Zertifikate und Profile anlegen darf – „App Manager" reicht dafür *nicht*)
- Notieren: **Issuer-ID** (oben auf der Seite) und **Schlüssel-ID**
- Die `.p8`-Datei **einmalig** herunterladen (sie ist später nicht mehr abrufbar)

### 5. GitHub-Secrets (Repo → Settings → Secrets and variables → Actions → New repository secret)
| Name | Inhalt |
|---|---|
| `APPLE_TEAM_ID` | Team-ID aus Schritt 1 |
| `ASC_KEY_ID` | Schlüssel-ID aus Schritt 4 |
| `ASC_ISSUER_ID` | Issuer-ID aus Schritt 4 |
| `ASC_KEY_P8` | kompletter Inhalt der `.p8`-Datei inkl. `-----BEGIN PRIVATE KEY-----` |
| `SUPABASE_URL` | wie in `Config/Secrets.xcconfig` lokal |
| `SUPABASE_ANON_KEY` | wie in `Config/Secrets.xcconfig` lokal |

### 6. Hochladen
Actions → **TestFlight** → Run workflow. Das Ergebnis steht danach auf dem Branch `testflight-report` (Datei `report.txt`). Nach ca. 10–30 Minuten erscheint der Build in App Store Connect → TestFlight (Verarbeitung durch Apple).

### 7. Tester einladen
App Store Connect → TestFlight → Interne Tester (bis zu 100 Personen mit Rolle im Team, ohne Prüfung durch Apple) oder Externe Tester (Link, erfordert kurze Beta-Prüfung).

**Hinweise:**
- Jeder Lauf bekommt automatisch eine neue Build-Nummer (Workflow-Laufnummer, `CURRENT_PROJECT_VERSION`); die Version (`MARKETING_VERSION`, aktuell `1.0.0`) bleibt stehen, bis bewusst eine neue veröffentlicht wird.
- `aps-environment: development` in `project.yml` wird von Xcode beim Export mit `method: app-store-connect` automatisch auf `production` umgeschrieben – kein manueller Schritt im Skript nötig.
- Läuft auf dem GitHub-gehosteten `macos-latest`-Runner (anders als bei Meeterz, das einen eigenen selbst gehosteten Mac mit mehrfachen Xcode-Versionen nutzt) – für ein öffentliches Repo kostenlos, kein eigener Mac-Runner nötig.

## Projektstruktur

```
ios/
  project.yml                 # XcodeGen-Manifest (Target, Settings, SPM-Dependencies)
  Config/
    Secrets.example.xcconfig  # Vorlage, getrackt
    Secrets.xcconfig          # echte Werte, gitignored
  ci/
    asc.py                    # App-Store-Connect-API-Helfer (Zertifikat/Profil pro CI-Lauf, kein P12-Export)
    testflight.sh             # Release-Build + Signierung + TestFlight-Upload, von .github/workflows/testflight.yml aufgerufen
  Wizzo/
    App/
      WizzoApp.swift           # @main - entscheidet Auth- vs. Root-Screen
      AppState.swift           # Session-Zustand + sessionweite Presence/Invite-Beobachtung (ObservableObject)
      Theme.swift               # Farbpalette, 1:1 aus App.tsx's `const C`, plus Kartenfarben-Helfer
      FlatFieldStyle.swift      # gemeinsames Textfeld-Styling (Auth, Lobby-Beitritt, ...)
      AvatarView.swift           # gemeinsamer Avatar-Baustein (Bild oder Initiale), mirrors Avatar in App.tsx
    Models/
      Profile.swift             # mirrors die `profiles`-Tabelle
      Room.swift                 # mirrors `rooms` (nur die lesbar freigegebenen Spalten)
      RoomPlayer.swift           # mirrors `room_players_view`
      Card.swift                  # mirrors Card in types.ts
      TrickEntry.swift            # mirrors ein {card, playerIndex}-Eintrag in current_trick/last_trick_cards
      RoundHistoryEntry.swift     # mirrors `round_history` + RoundResult (auch von manual_game_rounds genutzt)
      ManualGame.swift             # mirrors `manual_games`/`manual_game_players`/`manual_game_rounds`
      VoiceSignal.swift            # mirrors das {type, from, to, sdp, candidate}-Signaling-Payload aus App.tsx
      Card+Art.swift                # Kartenbild-Dateinamen-Logik + In-Memory-Cache, mirrors CardView.tsx
    Services/
      SupabaseService.swift     # einziger SupabaseClient, URL/Key aus Info.plist
      GameActionClient.swift     # Swift-Äquivalent zu callGameAction() aus supabase.ts
      PushNotificationManager.swift  # APNs-Registrierung/-Status, mirrors subscribeToPush()/unsubscribeFromPush()
      VoiceChatManager.swift     # WebRTC-Mesh + Broadcast-Signaling, mirrors useVoiceChat() aus App.tsx
    Features/
      Auth/                      # Anmelden/Registrieren
      Home/                      # Tab-Leiste, Raum erstellen/beitreten, Lobby
      Game/                       # Spieltisch (Classic + "30 Jahre"): GameView/GameViewModel, CardChipView
      Friends/                   # Freunde-Tab: suchen/anfragen/annehmen/entfernen, Zuschauer-Entdeckung, Freundesprofile
      Spectator/                 # Zuschauer-Modus: rein lesender SpectatorView/SpectatorViewModel
      Stats/                     # Statistik-Tab: Kennzahlen + Letzte Partien
      Rechenblock/                # Digitaler Rechenblock: Setup/Play/Finished-Views + ViewModels
      Profile/                   # Profil-Tab (echte Daten)
    Resources/
      Assets.xcassets/          # App-Icon + Accent-Farbe, aus dem bestehenden Branding generiert
      Cards/                     # WebP-Kartenbilder, 1:1 aus wizard/frontend/public/cards/ kopiert (als type: folder-Quelle in project.yml)
```

Jede weitere Phase bekommt ihren eigenen Ordner unter `Features/` nach demselben Schema: eine `*View.swift` (SwiftUI) + ein `*ViewModel.swift` (`ObservableObject`, hält den `async`-Zugriff auf `SupabaseService.client`).

## Nächste sinnvolle Phase

Mit Phase 16 ist der letzte der großen, eigenständigen Feature-Blöcke aus der ursprünglichen Roadmap umgesetzt (Phase 5: alle neun Sonderkarten/komplette "30 Jahre"-Edition; Phase 6: Spielblatt & Log; Phase 7: Indianer-Poker-Anzeige; Phase 8: Reconnect; Phase 9+12: Freunde komplett; Phase 10: Zuschauer-Modus; Phase 11: Statistik; Phase 13: digitaler Rechenblock; Phase 14: Avatar-Upload; Phase 15: echte Push-Benachrichtigungen; Phase 16: Sprachchat). Der native Spieltisch samt Lobby/Reconnect/Zuschauen/Freunde/Rechenblock/Sprachchat hat damit funktional Web-Parität erreicht.

Was realistisch bleibt, ist kein neuer großer Block mehr, sondern Politur und echte Verifikation:

- **Der erste echte Build in Xcode** – siehe "Wichtige Einschränkung" oben. Nichts hier wurde je kompiliert; das ist der eigentliche nächste Schritt, nicht eine weitere Phase.
- Die bewusst zurückgestellten Kleinigkeiten aus der "noch nicht existiert"-Liste oben (Sprechende-Indikator, ICE-Restart, Push jenseits von "du bist dran").
- Gebündelte Cinzel-Schriftdatei statt `.serif`-Systemschrift-Näherung, für pixelgenaues Branding.
- App-Store-Einreichung selbst (Screenshots, Datenschutzerklärung, Review-Antworten zur Mikrofon-/Benachrichtigungsnutzung) – organisatorisch, nicht Code.
