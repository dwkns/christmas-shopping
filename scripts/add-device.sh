#!/usr/bin/env bash
# Register a new iPhone with Apple, refresh the on-device provisioning, and (by default) ship an OTA
# build so the phone can install Mill House. Adapted from dwkns/lifts. The app is development-signed and installed directly — no
# TestFlight — so every new phone has to be known to Apple before a build will run on it.
#   scripts/add-device.sh "<Name>" <UDID>               register, refresh profile, build, release
#   scripts/add-device.sh "<Name>" <UDID> --no-release   register + refresh profile only
#   scripts/add-device.sh --list                         list devices already registered (read-only)
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD

source scripts/secrets.sh
apple_env
KEY=$ASC_KEY

API="https://api.appstoreconnect.apple.com/v1"

# A JWT for the App Store Connect API, ES256-signed with the .p8. Prefers PyJWT + cryptography from
# backend/.venv when both are installed there; otherwise falls back to `openssl dgst -sign` for the raw
# signature plus a pure-stdlib DER-to-JWS conversion, since neither package needs to be added just for this.
make_jwt() {
  local PYBIN="$ROOT/backend/.venv/bin/python3"
  [ -x "$PYBIN" ] && "$PYBIN" -c 'import jwt, cryptography' 2>/dev/null || PYBIN=""
  if [ -n "$PYBIN" ]; then
    "$PYBIN" - "$ASC_ISSUER_ID" "$ASC_KEY_ID" "$KEY" <<'PY'
import sys, time, jwt
issuer, key_id, key_path = sys.argv[1:4]
private_key = open(key_path).read()
now = int(time.time())
token = jwt.encode(
    {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
    private_key, algorithm="ES256", headers={"kid": key_id, "typ": "JWT"},
)
print(token)
PY
  else
    python3 - "$ASC_ISSUER_ID" "$ASC_KEY_ID" "$KEY" <<'PY'
import base64, json, subprocess, sys, time

issuer, key_id, key_path = sys.argv[1:4]


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=")


now = int(time.time())
header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
payload = {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"}
signing_input = (
    b64url(json.dumps(header, separators=(",", ":")).encode())
    + b"."
    + b64url(json.dumps(payload, separators=(",", ":")).encode())
)

# openssl signs the ES256 input as a DER-encoded ECDSA signature (SEQUENCE of two INTEGERs); JWS wants
# the raw, fixed-width r||s form instead, so unpack the DER by hand rather than pull in a dependency.
der = subprocess.run(
    ["openssl", "dgst", "-sha256", "-sign", key_path],
    input=signing_input, capture_output=True, check=True,
).stdout


def read_len(buf, i):
    n = buf[i]
    if n & 0x80:
        k = n & 0x7F
        return int.from_bytes(buf[i + 1 : i + 1 + k], "big"), i + 1 + k
    return n, i + 1


i = 1  # skip the outer SEQUENCE tag
_, i = read_len(der, i)
i += 1  # skip the INTEGER tag for r
rlen, i = read_len(der, i)
r = int.from_bytes(der[i : i + rlen], "big")
i += rlen
i += 1  # skip the INTEGER tag for s
slen, i = read_len(der, i)
s = int.from_bytes(der[i : i + slen], "big")

raw_sig = r.to_bytes(32, "big") + s.to_bytes(32, "big")
print((signing_input + b"." + b64url(raw_sig)).decode())
PY
  fi
}

api() {  # api METHOD PATH [JSON-BODY]
  local method=$1 path=$2 body=${3:-} jwt
  jwt=$(make_jwt)
  if [ -n "$body" ]; then
    curl -sSg -X "$method" "$API$path" -H "Authorization: Bearer $jwt" -H 'Content-Type: application/json' -d "$body"
  else
    curl -sSg -X "$method" "$API$path" -H "Authorization: Bearer $jwt"
  fi
}

LIST_SCRIPT='
import json, sys
data = json.load(sys.stdin)
if "errors" in data:
    print("Apple API error:", data["errors"]); sys.exit(1)
rows = data.get("data", [])
if not rows:
    print("no devices registered"); sys.exit(0)
for d in rows:
    a = d["attributes"]
    print("%-8s %-10s %s  %s" % (a["status"], a.get("deviceClass") or "", a["udid"], a["name"]))
'

list_devices() {
  # -c (not a heredoc) so stdin stays free for the piped JSON.
  api GET "/devices?limit=200&fields[devices]=name,udid,status,deviceClass,addedDate" | python3 -c "$LIST_SCRIPT"
}

if [ "${1:-}" = "--list" ]; then
  list_devices
  exit 0
fi

NAME=${1:-}
UDID=${2:-}
[ -n "$NAME" ] && [ -n "$UDID" ] || {
  echo "usage: scripts/add-device.sh \"<Name>\" <UDID> [--no-release]" >&2
  echo "       scripts/add-device.sh --list" >&2
  exit 1
}
NO_RELEASE=0
[ "${3:-}" = "--no-release" ] && NO_RELEASE=1

# Two UDID shapes are in the wild: the 40-char hex ECID from pre-A11 devices, and the newer
# 8-hex/16-hex form (e.g. 00008101-000A4D8A3403001E) everything since has used.
if ! [[ "$UDID" =~ ^[0-9A-Fa-f]{40}$ || "$UDID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}$ ]]; then
  echo "not a UDID: $UDID (expect 40 hex characters, or XXXXXXXX-XXXXXXXXXXXXXXXX)" >&2
  exit 1
fi

echo "== registering $NAME ($UDID) with Apple"
EXISTING=$(api GET "/devices?filter[udid]=$UDID" | python3 -c 'import json, sys; print(len(json.load(sys.stdin).get("data", [])))')
if [ "$EXISTING" != "0" ]; then
  echo "already registered; continuing"
else
  BODY=$(python3 -c '
import json, sys
name, udid = sys.argv[1:3]
print(json.dumps({"data": {"type": "devices", "attributes": {"name": name, "platform": "IOS", "udid": udid}}}))
' "$NAME" "$UDID")
  RESP=$(api POST "/devices" "$BODY")
  if echo "$RESP" | python3 -c 'import json, sys; sys.exit(1 if "errors" in json.load(sys.stdin) else 0)'; then
    echo "registered"
  else
    echo "Apple rejected the device:" >&2
    echo "$RESP" | python3 -c 'import json, sys; [print("-", e.get("detail", e)) for e in json.load(sys.stdin)["errors"]]' >&2
    exit 1
  fi
fi

echo "== refreshing the development provisioning profile"
# Xcode reuses a cached profile even after a device is added, so the build would leave the new device out (the app's
# own, the widgets', and the wildcard one; 2026-10-05). Move aside each of Lift's cached profiles (com.dwkns.lift*, or
# the team's wildcard) that lacks this device: the build then fetches fresh ones that include it. Other apps' profiles
# are left where they are. Kept in ~/Backups, in a folder of this run's own (date and time, so a second add never
# overwrites the first), and moved back if the build or the release below fails, so the next release can still sign.
ASIDE="$HOME/Backups/old-profiles-$(date +%Y-%m-%d-%H%M%S)"
MOVED=()
put_profiles_back() {
  for entry in "${MOVED[@]:-}"; do
    [ -n "$entry" ] || continue
    mv "$ASIDE/$(basename "${entry}")" "$entry" 2>/dev/null && echo "put back $(basename "$entry")" >&2
  done
}
trap 'rc=$?; [ $rc = 0 ] || put_profiles_back; rm -rf "$SECRETS_DIR"; exit $rc' EXIT
for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
  [ -d "$dir" ] || continue
  for f in "$dir"/*.mobileprovision; do
    [ -e "$f" ] || continue
    PROFILE=$(security cms -D -i "$f" 2>/dev/null || true)
    grep -qE "<string>$TEAM_ID\.(com\.dwkns\.millhouse[^<]*|\*)</string>" <<<"$PROFILE" || continue
    if ! grep -q "$UDID" <<<"$PROFILE"; then
      mkdir -p "$ASIDE" && mv "$f" "$ASIDE/" && MOVED+=("$f") && echo "moved aside a cached profile without $NAME: $(basename "$f")"
    fi
  done
done
(cd ios && xcodegen generate >/dev/null)
AUTH=(-allowProvisioningUpdates -allowProvisioningDeviceRegistration
      -authenticationKeyPath "$KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
(cd ios && xcodebuild build -project MillHouse.xcodeproj -scheme MillHouse -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/ios/build/device" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  "${AUTH[@]}" -quiet)

if [ "$NO_RELEASE" = "1" ]; then
  echo "profile refreshed; skipping the release (--no-release)"
else
  scripts/release-ios.sh
fi

echo "== $NAME is registered and the profile includes it. Install with: PHONE=$UDID scripts/ship-ios.sh"
