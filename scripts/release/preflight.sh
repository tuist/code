#!/usr/bin/env bash
set -euo pipefail

required_items=(
  "Developer ID Application Certificate"
  "Developer ID Certificate Password"
  "App Specific Password"
  "Tuist App Private Sparkle Key"
  "Tuist Code Ad Hoc"
  "Distribution Certificate"
  "Distribution Certificate Password"
  "Google Play release.keystore"
  "Google Play release.keystore binary"
)

for item in "${required_items[@]}"; do
  op item get "$item" --vault "Tuist Code" --format json >/dev/null
done

profile="$RUNNER_TEMP/Tuist_Code_Ad_Hoc.mobileprovision"
profile_plist="$RUNNER_TEMP/Tuist_Code_Ad_Hoc.plist"
op document get "Tuist Code Ad Hoc" --vault "Tuist Code" --out-file "$profile"
security cms -D -i "$profile" > "$profile_plist"

application_identifier=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist")
if [[ "$application_identifier" != "U6LC622NKF.dev.tuist.code.ios" ]]; then
  printf 'The iOS profile is for %s, expected U6LC622NKF.dev.tuist.code.ios\n' "$application_identifier" >&2
  exit 1
fi

expiration=$(plutil -extract ExpirationDate raw "$profile_plist")
if [[ $(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$expiration" '+%s') -le $(date '+%s') ]]; then
  printf 'The iOS provisioning profile expired at %s\n' "$expiration" >&2
  exit 1
fi

private_key="$RUNNER_TEMP/sparkle-private-key"
op read "op://Tuist Code/Tuist App Private Sparkle Key/credential" | /usr/bin/base64 -D > "$private_key"
derived_public_key=$(swift -e 'import CryptoKit; import Foundation; let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))); print(key.publicKey.rawRepresentation.base64EncodedString())' "$private_key")
configured_public_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' apps/desktop/Info.plist)

if [[ "$derived_public_key" != "$configured_public_key" ]]; then
  printf 'The configured Sparkle public key does not match the private release key\n' >&2
  exit 1
fi

printf 'Release credentials, provisioning profile, and Sparkle key pair are valid\n'
