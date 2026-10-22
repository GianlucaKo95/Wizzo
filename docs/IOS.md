# iOS-App (nativ, SwiftUI)

Wizzo wird komplett nativ als SwiftUI-App neu gebaut (nicht als Web-Wrapper) – die PWA (`wizard/`) ist der Übergang, die native App soll sie langfristig ablösen. Dieses Dokument beschreibt Architektur, Setup und den aktuellen Stand.

## Warum nativ statt PWA-Wrapper

Kurz zusammengefasst aus der Diskussion, die zu dieser Entscheidung geführt hat: ein reiner Wrapper (z. B. Capacitor) hätte den bestehenden Web-Code 1:1 übernommen, aber eben auch dessen Grenzen – kein wirklich natives Gefühl (Scrollen/Übergänge/Gesten bleiben Web), Sprachchat bricht im Hintergrund ab, Web-Push ist auf iOS unzuverlässig. Da ein echtes natives Gefühl gewünscht war und die PWA ohnehin nicht weiterbetrieben werden soll, baut die App stattdessen die komplette UI in SwiftUI neu, gegen **dasselbe, unveränderte Supabase-Backend** (Postgres/RLS/Realtime/Edge-Function) wie die Web-App – siehe [`ARCHITECTURE.md`](ARCHITECTURE.md) und [`DATABASE.md`](DATABASE.md) für das Backend, das hier 1:1 weiterverwendet wird.

## Stand: erste Phase (Grundgerüst + Auth + Profil)

Was aktuell existiert und **echt gegen das Supabase-Projekt funktioniert**:

- Projekt-Grundgerüst (SwiftUI, iOS 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen)-verwaltet)
- Supabase-Anbindung über das offizielle [`supabase-swift`](https://github.com/supabase/supabase-swift)-SDK
- **Anmelden/Registrieren**: repliziert exakt die Logik aus `AuthScreen` in `wizard/frontend/src/App.tsx` – es gibt keine echte E-Mail, nur einen Namen; dahinter steht eine synthetische `<slug>@wizard.local`-Adresse mit einem abgeleiteten Standardpasswort, wenn keins gesetzt wird. **Das muss exakt übereinstimmen**, sonst können sich Web- und App-Nutzer nicht gegenseitig mit denselben Konten anmelden.
- **Profil-Tab**: lädt die eigene `profiles`-Zeile, zeigt Name + Mitglied-seit, funktionierendes Abmelden.
- Tab-Leiste (Home/Freunde/Statistik/Profil, siehe `TabKey` in `App.tsx`) – Home/Freunde/Statistik sind bewusst ehrliche "Kommt noch"-Platzhalter, keine Fake-Daten.

Was **noch nicht** existiert (jeweils eigene, größere Phasen):

- Der eigentliche Spieltisch (Räume erstellen/beitreten, Karten spielen, alle Sonderkarten-Interaktionen, Realtime-Sync)
- Zuschauer-Modus
- Freunde (Liste, Anfragen, Einladungen, Freundesprofile)
- Statistik ("Letzte Partien", Trefferquote)
- Digitaler Rechenblock
- Sprachchat (WebRTC) – inkl. Hintergrund-Audio, der Hauptgrund für den nativen Weg
- Echte Push-Benachrichtigungen (APNs)
- Avatar-Upload

Realistisch betrachtet ist das hier **Phase 1 von vielen** – Vollständigkeit ist kein Wochenend-, sondern ein Mehrmonatsprojekt für dieses Feature-Set. Jede weitere Phase sollte als eigener, in sich abgeschlossener Schritt kommen (gleiches Muster wie der Rest dieses Repos), nicht als ein einziger riesiger, ungeprüfter Umbau.

## Wichtige Einschränkung: hier nicht kompilierbar geprüft

Der gesamte Swift-Code in diesem Verzeichnis wurde **ohne Zugriff auf Xcode/einen Swift-Compiler** geschrieben (Linux-Dev-Umgebung – Apple erlaubt iOS-Builds grundsätzlich nur auf macOS, das ist keine Einschränkung dieses Setups). Die Methodensignaturen des `supabase-swift`-SDK (`signUp`, `signIn`, `.from().select().eq().single().execute().value`, …) wurden gezielt gegen die [offizielle UserManagement-Beispiel-App](https://github.com/supabase/supabase-swift/tree/main/Examples/UserManagement) und den SDK-Quellcode selbst abgeglichen, nicht aus dem Gedächtnis geraten – aber **der erste Build in Xcode ist trotzdem der erste echte Korrektheitstest.** Kleinere Abweichungen (z. B. ein verschobenes Argument-Label) sind nicht ausgeschlossen und sollten dort schnell auffallen (Xcode zeigt sie direkt als Fehler mit Vorschlag).

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
      Theme.swift               # Farbpalette, 1:1 aus App.tsx's `const C`
    Models/
      Profile.swift             # mirrors die `profiles`-Tabelle
    Services/
      SupabaseService.swift     # einziger SupabaseClient, URL/Key aus Info.plist
    Features/
      Auth/                      # Anmelden/Registrieren
      Home/                      # Tab-Leiste + Platzhalter-Screens
      Profile/                   # Profil-Tab (echte Daten)
    Resources/
      Assets.xcassets/          # App-Icon + Accent-Farbe, aus dem bestehenden Branding generiert
```

Jede weitere Phase bekommt ihren eigenen Ordner unter `Features/` (z. B. `Features/Game/`, `Features/Friends/`) nach demselben Schema: eine `*View.swift` (SwiftUI) + ein `*ViewModel.swift` (`ObservableObject`, hält den `async`-Zugriff auf `SupabaseService.client`).

## Nächste sinnvolle Phase

Vorschlag für die nächste in sich abgeschlossene Erweiterung: **Räume erstellen/beitreten + Lobby-Ansicht** (noch ohne den eigentlichen Spieltisch) – das bringt die `rooms`/`room_players`-Realtime-Anbindung ans Laufen (der komplexeste neue Baustein: Supabase Realtime-Channels in Swift, siehe `supabase.realtime`/`channel(...)` im SDK) und ist eine testbare, von Hand überprüfbare Einheit, bevor der eigentliche Kartentisch (bei weitem der größte Einzelbaustein, siehe `GameRoom` in `App.tsx`, ~1700 Zeilen) angegangen wird.
