#!/usr/bin/env bash
# Build Catcher.app with a stable signature. Ad-hoc ("Sign to Run Locally")
# puts Signature=adhoc on the bundle and TCC binds the grant to that build's
# cdhash, so the next rebuild silently loses it.
#
# Order:
#   1. CATCHER_DEVELOPMENT_TEAM set → Apple Development (team id + bundle id).
#   2. Otherwise a local "Catcher Development" code-signing cert, created once
#      in the login keychain and reused. The designated requirement is the
#      certificate plus com.catcher.app, not the cdhash.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "build-app.sh signs a Mac app and must run on macOS." >&2
  exit 2
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required. Install it, then re-run." >&2
  exit 2
fi
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "xcodebuild is required." >&2
  exit 2
fi

login_keychain() {
  local db="$HOME/Library/Keychains/login.keychain-db"
  if [[ -f "$db" ]]; then
    echo "$db"
    return
  fi
  echo "$HOME/Library/Keychains/login.keychain"
}

identity_installed() {
  security find-identity -v -p codesigning 2>/dev/null | grep -F "\"$1\"" >/dev/null
}

ensure_local_identity() {
  local name="$1"
  if identity_installed "$name"; then
    return
  fi
  local work keychain
  work="$(mktemp -d)"
  keychain="$(login_keychain)"
  cat > "$work/codesign.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = codesign_ext
prompt = no
[ req_distinguished_name ]
CN = ${name}
O = Catcher
[ codesign_ext ]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:false
EOF
  openssl req -x509 -newkey rsa:2048 -keyout "$work/key.pem" -out "$work/cert.pem" \
    -days 3650 -nodes -config "$work/codesign.cnf" -extensions codesign_ext >/dev/null 2>&1
  openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/catcher.p12" -passout pass:catcher -name "$name"
  security import "$work/catcher.p12" -k "$keychain" -P catcher -A
  rm -rf "$work"
  if ! identity_installed "$name"; then
    echo "Imported \"$name\" but codesigning identities still do not list it." >&2
    echo "Unlock the login keychain and re-run. The certificate must have the codeSigning extended key usage." >&2
    exit 1
  fi
}

IDENTITY="${CATCHER_CODESIGN_IDENTITY:-}"
SIGN_ARGS=()
ENTITLEMENTS="Sources/CatcherApp/Catcher.entitlements"
if [[ -n "${CATCHER_DEVELOPMENT_TEAM:-}" ]]; then
  IDENTITY="${IDENTITY:-Apple Development}"
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Automatic
    "DEVELOPMENT_TEAM=${CATCHER_DEVELOPMENT_TEAM}"
    "CODE_SIGN_IDENTITY=${IDENTITY}"
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES
    ENABLE_HARDENED_RUNTIME=YES
    "CODE_SIGN_ENTITLEMENTS=${ENTITLEMENTS}"
  )
else
  IDENTITY="${IDENTITY:-Catcher Development}"
  ensure_local_identity "$IDENTITY"
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=${IDENTITY}"
    CODE_SIGNING_REQUIRED=YES
    CODE_SIGNING_ALLOWED=YES
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    ENABLE_HARDENED_RUNTIME=YES
    "CODE_SIGN_ENTITLEMENTS=${ENTITLEMENTS}"
    OTHER_CODE_SIGN_FLAGS=--timestamp=none
  )
fi

xcodegen generate
xcodebuild -project CatcherApp.xcodeproj -scheme CatcherApp \
  -destination 'platform=macOS' -derivedDataPath build \
  "${SIGN_ARGS[@]}" \
  build

APP="$PWD/build/Build/Products/Debug/Catcher.app"
if [[ ! -d "$APP" ]]; then
  echo "Build finished without $APP" >&2
  exit 1
fi
INFO="$(codesign -dv "$APP" 2>&1 || true)"
if grep -q "Signature=adhoc" <<<"$INFO"; then
  echo "Build produced an ad-hoc signature. Refusing to leave a cdhash-keyed bundle on disk." >&2
  echo "$INFO" | grep -E "Signature=|TeamIdentifier=|CDHash=" >&2 || true
  exit 1
fi
codesign --verify --verbose=2 "$APP"
# A hardened-runtime binary without the audio-input entitlement gets no TCC
# microphone case at all: no Allow dialog and no row in the Microphone pane.
if grep -q "flags=.*runtime" <<<"$INFO"; then
  ENTS="$(codesign -d --entitlements :- "$APP" 2>/dev/null || true)"
  if ! grep -q "com.apple.security.device.audio-input" <<<"$ENTS"; then
    echo "Catcher.app is hardened (flags=runtime) but com.apple.security.device.audio-input is not in its entitlements." >&2
    echo "macOS will never show the microphone Allow dialog for this build. Check CODE_SIGN_ENTITLEMENTS=$ENTITLEMENTS." >&2
    exit 1
  fi
fi
echo "Signed $APP"
echo "$INFO" | grep -E "Authority=|Signature=|TeamIdentifier=|Identifier=|CDHash=|flags=" || true
codesign -d --entitlements :- "$APP" 2>/dev/null | grep -E "audio-input" || true
echo "Export CATCHER_APP=\"$APP\""
echo "Start it with: open -n \"$APP\"  (a direct exec from a shell bills TCC to the shell's app, not to com.catcher.app)"
