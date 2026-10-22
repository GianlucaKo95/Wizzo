#!/bin/bash
# Baut Wizzo als Release, signiert mit frisch über die App-Store-Connect-API
# erzeugtem Zertifikat/Profil und lädt es zu TestFlight hoch. Läuft mit dem
# Arbeitsverzeichnis "ios" (siehe .github/workflows/testflight.yml).
# Benötigte Umgebungsvariablen (GitHub-Secrets, siehe docs/IOS.md):
#   APPLE_TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8 (Inhalt der .p8-Datei),
#   SUPABASE_URL, SUPABASE_ANON_KEY

# Bewusst kein "set -e": jeder riskante Befehl unten (asc.py purge/create,
# xcodebuild archive/-exportArchive, altool) hat schon seine eigene manuelle
# RES=$?-Prüfung mit eigenem Log/Exit-Code - "set -e" würde das Skript beim
# ersten Fehlschlag sofort an genau dieser Stelle beenden, BEVOR die eigene
# Prüfung (und damit die eigentliche Fehlermeldung, z.B. aus upload.log)
# überhaupt erreicht wird. Genau das ist hier real passiert: der altool-
# Upload schlug fehl, "set -e" killte das Skript augenblicklich, und im
# Report stand danach nur noch die Überschrift, kein einziges Fehlerdetail.
REPORT="${REPORT:-report.txt}"
: > "$REPORT"
log() { echo "$@" | tee -a "$REPORT"; }

for v in APPLE_TEAM_ID ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8 SUPABASE_URL SUPABASE_ANON_KEY; do
  [ -n "${!v}" ] || { log "!! Secret $v fehlt"; exit 20; }
done

brew list xcodegen >/dev/null 2>&1 || brew install xcodegen 2>&1 | tail -3 | tee -a "$REPORT"

# Secrets.xcconfig behandelt "//" als Kommentarbeginn, auch innerhalb eines
# Werts (siehe Config/Secrets.example.xcconfig) - das leere "$()"-Macro muss
# dafür ZWISCHEN den beiden Schrägstrichen stehen, nicht davor: "https:$()//"
# hat die beiden rohen "/" immer noch direkt nebeneinander im Dateitext (der
# Kommentar-Scanner arbeitet auf dem rohen Text, vor der Macro-Auflösung),
# wird also trotzdem ab dort abgeschnitten. Echte Ursache des ersten
# TestFlight-Absturzes (siehe docs/IOS.md): SUPABASE_URL landete dadurch nur
# als "https:" in der Info.plist, URL(string:) lieferte nil, und
# SupabaseService.swift's fatalError() traf genau das sofort beim Start.
SUPABASE_URL_ESCAPED=$(printf '%s' "$SUPABASE_URL" | sed 's#^https://#https:/$()/#')
cat > Config/Secrets.xcconfig <<XC
SUPABASE_URL = ${SUPABASE_URL_ESCAPED}
SUPABASE_ANON_KEY = ${SUPABASE_ANON_KEY}
XC

# Build-Nummer = fortlaufende Workflow-Nummer (TestFlight verlangt je Upload eine neue)
sed -i '' "s#CURRENT_PROJECT_VERSION: \"1\"#CURRENT_PROJECT_VERSION: \"${GITHUB_RUN_NUMBER:-1}\"#" project.yml

KEYDIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$KEYDIR"
printf "%s\n" "$ASC_KEY_P8" > "$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"
export ASC_KEY_PATH="$KEYDIR/AuthKey_${ASC_KEY_ID}.p8"

mkdir -p build
WORK="$PWD/build/signing"
PROFILE_NAME="Wizzo CI ${GITHUB_RUN_NUMBER:-0}-$(date +%s)"
KC="$PWD/build/ci.keychain-db"
# Zertifikat und Profil bleiben nach dem Upload bewusst bestehen, bis Apple
# den Build verarbeitet hat (siehe asc.py:purge) - nur die lokale Wegwerf-
# Keychain wird am Ende dieses Laufs wieder entfernt.
cleanup() {
  security delete-keychain "$KC" >/dev/null 2>&1
}
trap cleanup EXIT

log ""
log "== Alte CI-Zertifikate aufräumen =="
python3 ci/asc.py purge 2>&1 | tee -a "$REPORT"
log ""
log "== Zertifikat und Profil erzeugen =="
python3 ci/asc.py create "$WORK" de.koeven.wizzo "$PROFILE_NAME" 2>&1 | tee -a "$REPORT"
[ -f "$WORK/ids.json" ] || { log "!! Zertifikat/Profil konnten nicht erzeugt werden"; exit 33; }
PROFILE_UUID=$(python3 -c "import json;print(json.load(open('$WORK/ids.json'))['uuid'])")

openssl x509 -inform DER -in "$WORK/cert.der" -out "$WORK/cert.pem"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/sign.p12" -passout pass:ci -legacy >/dev/null 2>&1 \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/sign.p12" -passout pass:ci
security create-keychain -p ci "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p ci "$KC"
for url in https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer; do
  curl -sfL "$url" -o "$WORK/ca.cer" && security import "$WORK/ca.cer" -k "$KC" -T /usr/bin/codesign >/dev/null 2>&1
done
security import "$WORK/sign.p12" -k "$KC" -P ci -T /usr/bin/codesign -T /usr/bin/security 2>&1 | tee -a "$REPORT"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ci "$KC" >/dev/null 2>&1
security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')
security find-identity -v -p codesigning "$KC" 2>&1 | tee -a "$REPORT"

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
cp "$WORK/profile.mobileprovision" "$HOME/Library/MobileDevice/Provisioning Profiles/$PROFILE_UUID.mobileprovision"

# App-Target auf manuelle Signierung mit dem gerade erzeugten Profil stellen
python3 - "$PROFILE_NAME" <<'PY'
import sys
s = open("project.yml").read()
assert "CODE_SIGN_STYLE: Automatic" in s
s = s.replace("CODE_SIGN_STYLE: Automatic",
              f'CODE_SIGN_STYLE: Manual\n        CODE_SIGN_IDENTITY: "Apple Distribution"\n        PROVISIONING_PROFILE_SPECIFIER: "{sys.argv[1]}"', 1)
open("project.yml", "w").write(s)
PY
xcodegen generate 2>&1 | tee -a "$REPORT"

log ""
log "== Archivieren =="
xcodebuild archive \
  -project Wizzo.xcodeproj -scheme Wizzo -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/Wizzo.xcarchive \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" > archive.log 2>&1
RES=$?
grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" archive.log | sort -u | head -30 | tee -a "$REPORT"
[ $RES -eq 0 ] || { tail -40 archive.log | tee -a "$REPORT"; log "!! Archivieren fehlgeschlagen ($RES)"; exit 30; }

# method app-store-connect lässt Xcode beim Export auch das aps-environment-
# Entitlement automatisch development -> production umschreiben (Standard-
# Verhalten, siehe Kommentar in project.yml) - kein manueller Schritt nötig.
cat > ExportOptions.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>de.koeven.wizzo</key><string>${PROFILE_NAME}</string></dict>
  <key>uploadSymbols</key><false/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PL

log ""
log "== Exportieren (lokal, Verteilungs-Signatur) =="
xcodebuild -exportArchive \
  -archivePath build/Wizzo.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export > export.log 2>&1
RES=$?
grep -iE "error|warning: |sign|certificate|profile|EXPORT" export.log | sort -u | head -40 | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Export fehlgeschlagen ($RES)"; exit 31; }
IPA=$(ls build/export/*.ipa | head -1)
log "IPA: $IPA"

log ""
log "== Hochladen zu TestFlight (altool) =="
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" > upload.log 2>&1
RES=$?
tail -30 upload.log | tee -a "$REPORT"
[ $RES -eq 0 ] || { log "!! Upload fehlgeschlagen ($RES)"; exit 32; }
log "Hochgeladen: Version $(grep MARKETING_VERSION project.yml | head -1 | sed 's/.*: *//; s/\"//g') Build ${GITHUB_RUN_NUMBER:-1}"
