#!/usr/bin/env bash
set -euo pipefail

# Generate a release keystore for GitHub Actions CI signing.
#
# Usage:
#   ./tool/generate_keystore.sh
#
# The script prints the Base64-encoded keystore and the exact `gh secret set`
# commands needed to configure the repository. Pass `--upload` to attempt
# setting the secrets automatically when `gh` is authenticated:
#   ./tool/generate_keystore.sh --upload
#
# To sign OpenWatch with the SAME key you already use for another app
# (e.g. jaeger_flutter), skip this script and instead copy that repo's four
# KEYSTORE_* secrets to this repository — the build reads the identical env vars.

UPLOAD=false
if [ "${1:-}" = "--upload" ]; then
  UPLOAD=true
fi

APP_NAME="openwatch"
KEYSTORE_FILE="$(mktemp -t "${APP_NAME}-keystore-XXXXXX.jks")"
STORE_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/')"
KEY_PASSWORD="$(openssl rand -base64 24 | tr -d '=+/')"
KEY_ALIAS="${APP_NAME}_release"
VALIDITY_DAYS=10000

# Ensure the keystore file is removed on exit, even if the script fails.
trap 'rm -f "$KEYSTORE_FILE"' EXIT

# mktemp creates an empty file; keytool -genkey refuses to overwrite an empty
# file, so remove it and let keytool create the keystore.
rm -f "$KEYSTORE_FILE"

echo "Generating release keystore..."
keytool -genkey \
  -v \
  -keystore "$KEYSTORE_FILE" \
  -alias "$KEY_ALIAS" \
  -keyalg RSA \
  -keysize 2048 \
  -validity "$VALIDITY_DAYS" \
  -storepass "$STORE_PASSWORD" \
  -keypass "$KEY_PASSWORD" \
  -storetype JKS \
  -dname "CN=OpenWatch, OU=Mobile, O=OpenWatch, L=Unknown, ST=Unknown, C=US"

KEYSTORE_BASE64="$(base64 -w 0 "$KEYSTORE_FILE")"

echo ""
echo "=== Keystore generated ==="
echo "Key alias:     $KEY_ALIAS"
echo "Store pass:    $STORE_PASSWORD"
echo "Key pass:      $KEY_PASSWORD"
echo "Keystore file: $KEYSTORE_FILE (temporary, will be deleted on exit)"
echo ""
echo "=== Base64 keystore ==="
echo "$KEYSTORE_BASE64"
echo ""
echo "=== GitHub Actions secrets ==="
echo "Run the following commands to configure the repository secrets:"
echo ""
echo "  gh secret set KEYSTORE_BASE64 --body '$KEYSTORE_BASE64'"
echo "  gh secret set KEYSTORE_STORE_PASSWORD --body '$STORE_PASSWORD'"
echo "  gh secret set KEYSTORE_KEY_PASSWORD --body '$KEY_PASSWORD'"
echo "  gh secret set KEYSTORE_KEY_ALIAS --body '$KEY_ALIAS'"
echo ""

if [ "$UPLOAD" = true ]; then
  echo "Uploading secrets to GitHub Actions..."
  if ! command -v gh >/dev/null 2>&1; then
    echo "Error: 'gh' CLI is not installed. Install it or run the commands above manually." >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "Error: 'gh' is not authenticated. Run 'gh auth login' or use the commands above manually." >&2
    exit 1
  fi
  printf '%s' "$KEYSTORE_BASE64" | gh secret set KEYSTORE_BASE64
  printf '%s' "$STORE_PASSWORD" | gh secret set KEYSTORE_STORE_PASSWORD
  printf '%s' "$KEY_PASSWORD" | gh secret set KEYSTORE_KEY_PASSWORD
  printf '%s' "$KEY_ALIAS" | gh secret set KEYSTORE_KEY_ALIAS
  echo "Secrets uploaded successfully."
fi
