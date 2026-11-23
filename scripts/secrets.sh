# Secrets from 1Password, vault "Mini-only". Copied from dwkns/lifts: Mill House uses the same Apple developer account,
# so it reads the same App Store Connect key ("Lift - Apple", "Lift - Apple ASC key"). Source this; nothing prints a value.
#
#   secret "Lift - Apple/TEAM_ID"                      a field's value, for a variable: X=$(secret ...)
#   secret_file KEY "Lift - Apple ASC key" AuthKey.p8  a document saved to a private temp file, its path in $KEY
#   apple_env                                          TEAM_ID, ASC_KEY_ID, ASC_ISSUER_ID, PHONE_NAME, and ASC_KEY (the .p8)
#
# op signs in with the service account token in ~/.op-service-token (see ~/Developer/lifts/docs/SETUP.md). Temp files go when the
# script exits.
OP_VAULT="Mini-only"
if [ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] && [ -r "$HOME/.op-service-token" ]; then
  OP_SERVICE_ACCOUNT_TOKEN="$(cat "$HOME/.op-service-token")"
  export OP_SERVICE_ACCOUNT_TOKEN
fi
command -v op >/dev/null || { echo "no 1Password CLI: brew install 1password-cli" >&2; exit 1; }
[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ] || { echo "no ~/.op-service-token: see ~/Developer/lifts/docs/SETUP.md" >&2; exit 1; }

secret() { op read -n "op://$OP_VAULT/$1"; }

# Made here, not inside a function: a $(...) subshell would delete it on its own exit.
SECRETS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/millhouse-secrets.XXXXXX")
chmod 700 "$SECRETS_DIR"
trap 'rm -rf "$SECRETS_DIR"' EXIT

secret_file() {
  (umask 077 && op document get "$2" --vault "$OP_VAULT" --out-file "$SECRETS_DIR/$3" --force >/dev/null) || {
    echo "could not get \"$2\" from 1Password" >&2; exit 1; }
  printf -v "$1" '%s' "$SECRETS_DIR/$3"
}

apple_env() {
  TEAM_ID=$(secret "Lift - Apple/TEAM_ID")
  ASC_KEY_ID=$(secret "Lift - Apple/ASC_KEY_ID")
  ASC_ISSUER_ID=$(secret "Lift - Apple/ASC_ISSUER_ID")
  PHONE_NAME=$(secret "Lift - Apple/PHONE_NAME")
  : "${TEAM_ID:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}"
  export TEAM_ID ASC_KEY_ID ASC_ISSUER_ID PHONE_NAME
  secret_file ASC_KEY "Lift - Apple ASC key" "AuthKey_$ASC_KEY_ID.p8"
}
