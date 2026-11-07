#!/bin/bash
# One local signing identity, restricted to codesign. No private material is kept in the repository.
set +x
set -euo pipefail
umask 077

TRUST_CODE_SIGNING=false
case "${1:-}" in
    '') ;;
    --trust-code-signing) TRUST_CODE_SIGNING=true ;;
    --help)
        printf 'Usage: %s [--trust-code-signing]\n' "$0"
        printf 'Creates/reuses a non-extractable identity in the login keychain and verifies it before saving local build settings.\n'
        printf 'The flag permits codeSign trust for /usr/bin/codesign in the current user domain only, if signing needs it.\n'
        exit 0 ;;
    *) printf 'Unknown option. Use --help.\n' >&2; exit 2 ;;
esac
if [[ $# -gt 1 || "$EUID" == 0 ]]; then
    printf 'Run as the logged-in user, without sudo, with at most one option.\n' >&2
    exit 2
fi

IDENTITY_NAME='InstagramPet Local Code Signing'
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CONFIG_DIR="$HOME/Library/Application Support/InstagramPet"
CONFIG_PATH="$CONFIG_DIR/signing.plist"
if [[ ! -f "$KEYCHAIN" ]]; then
    printf 'The login keychain is unavailable. Open Keychain Access before retrying.\n' >&2
    exit 1
fi
SCRATCH_DIR="$(mktemp -d /private/tmp/InstagramPet-signing.XXXXXXXX)"
cleanup() { rm -rf -- "$SCRATCH_DIR"; }
trap cleanup EXIT

# Include invalid identities so a certificate awaiting narrow trust is reused rather than duplicated.
EXISTING="$(security find-identity -p codesigning "$KEYCHAIN" | awk -v wanted="$IDENTITY_NAME" '
    /^[[:space:]]*[0-9]+\)/ { split($0, quoted, "\""); if (quoted[2] == wanted && length($2) == 40) print $2 }
' | sort -u)"
if [[ "$EXISTING" == *$'\n'* ]]; then
    printf 'More than one local signing identity exists. Review them in Keychain Access before continuing.\n' >&2
    exit 1
fi

# A failed earlier import may have left a certificate without its private key. Remove only
# exact-label certificates absent from *all* basic identities, including invalid ones.
BASIC_IDENTITIES="$(security find-identity -p basic "$KEYCHAIN" | awk '
    /^[[:space:]]*[0-9]+\)/ { if (length($2) == 40) print $2 }
' | sort -u)"
CERTIFICATE_RECORDS="$(security find-certificate -a -c "$IDENTITY_NAME" -Z "$KEYCHAIN" 2>/dev/null || true)"
CERTIFICATE_HASHES="$(printf '%s\n' "$CERTIFICATE_RECORDS" | awk -v wanted="$IDENTITY_NAME" '
    /^SHA-1 hash:/ { fingerprint=$3 }
    /"labl"/ { split($0, quoted, "\""); if (quoted[4] == wanted) print fingerprint }
')"
while IFS= read -r certificate_hash; do
    [[ -n "$certificate_hash" ]] || continue
    if ! printf '%s\n' "$BASIC_IDENTITIES" | grep -Fqx "$certificate_hash"; then
        printf 'Removing a previous incomplete local certificate import.\n'
        security delete-certificate -Z "$certificate_hash" "$KEYCHAIN"
    fi
done <<< "$CERTIFICATE_HASHES"

if [[ -n "$EXISTING" ]]; then
    FINGERPRINT="$EXISTING"
    security find-certificate -c "$IDENTITY_NAME" -p "$KEYCHAIN" > "$SCRATCH_DIR/certificate.pem"
    CERT_FINGERPRINT="$(openssl x509 -in "$SCRATCH_DIR/certificate.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    if [[ "$CERT_FINGERPRINT" != "$FINGERPRINT" ]]; then
        printf 'The local certificate name is ambiguous. Review it in Keychain Access before continuing.\n' >&2
        exit 1
    fi
else
    cat > "$SCRATCH_DIR/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = subject
x509_extensions = signing
prompt = no
[subject]
CN = InstagramPet Local Code Signing
[signing]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CONFIG
    # OpenSSL's key material goes only into this mode-700 temporary directory, never tool output.
    openssl req -new -x509 -newkey rsa:3072 -nodes -sha256 -days 3650 \
        -config "$SCRATCH_DIR/openssl.cnf" -keyout "$SCRATCH_DIR/key.pem" -out "$SCRATCH_DIR/certificate.pem" \
        > "$SCRATCH_DIR/generation.log" 2>&1
    FINGERPRINT="$(openssl x509 -in "$SCRATCH_DIR/certificate.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g')"
    # Use a single, explicit identity container: security's OpenSSL PEM importer does not
    # accept every PKCS#8 encoding emitted by openssl req. A temporary random wrapping
    # passphrase avoids the platform importer's empty-password incompatibility.
    openssl rand -hex 32 > "$SCRATCH_DIR/wrapping-passphrase"
    openssl pkcs12 -export -inkey "$SCRATCH_DIR/key.pem" -in "$SCRATCH_DIR/certificate.pem" \
        -out "$SCRATCH_DIR/identity.p12" -passout "file:$SCRATCH_DIR/wrapping-passphrase" > "$SCRATCH_DIR/packaging.log" 2>&1
    printf 'Importing the restricted local signing identity into the login keychain.\n'
    PACKAGING_PASSPHRASE="$(cat "$SCRATCH_DIR/wrapping-passphrase")"
    security import "$SCRATCH_DIR/identity.p12" -t agg -f pkcs12 -P "$PACKAGING_PASSPHRASE" -x -k "$KEYCHAIN" -T /usr/bin/codesign >/dev/null
    unset PACKAGING_PASSPHRASE
fi

# Work on a disposable copy. The running app and its current privacy approvals are untouched.
cp /usr/bin/true "$SCRATCH_DIR/probe"
if ! codesign --force --timestamp=none --identifier com.instagrampet.signing-probe --keychain "$KEYCHAIN" --sign "$FINGERPRINT" "$SCRATCH_DIR/probe" \
    > "$SCRATCH_DIR/signing.log" 2>&1; then
    if [[ "$TRUST_CODE_SIGNING" != true ]]; then
        printf 'The identity is installed but signing needs trust or keychain approval. No build settings were saved.\n' >&2
        printf 'To permit narrowly scoped code-signing trust, rerun: %s --trust-code-signing\n' "$0" >&2
        exit 1
    fi
    # No admin/system trust, SSL trust, allow-all key ACL, or key partition-list changes.
    security add-trusted-cert -r trustRoot -p codeSign -a /usr/bin/codesign \
        -k "$KEYCHAIN" "$SCRATCH_DIR/certificate.pem"
    codesign --force --timestamp=none --identifier com.instagrampet.signing-probe --keychain "$KEYCHAIN" --sign "$FINGERPRINT" "$SCRATCH_DIR/probe"
fi
codesign --verify --strict "$SCRATCH_DIR/probe"
REQUIREMENT="$(codesign --display --requirements - "$SCRATCH_DIR/probe" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "$REQUIREMENT" || "$REQUIREMENT" == cdhash* ]]; then
    printf 'The signing identity did not produce a stable certificate requirement. No build settings were saved.\n' >&2
    exit 1
fi
cp /usr/bin/false "$SCRATCH_DIR/probe-next"
codesign --force --timestamp=none --identifier com.instagrampet.signing-probe --keychain "$KEYCHAIN" \
    --sign "$FINGERPRINT" "$SCRATCH_DIR/probe-next"
codesign --verify --strict -R="$REQUIREMENT" "$SCRATCH_DIR/probe-next"
printf 'Verified the same certificate requirement across different executable code.\n'

mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"
CONFIG_TEMP="$(mktemp "$CONFIG_DIR/.signing.XXXXXXXX")"
plutil -create xml1 "$CONFIG_TEMP"
plutil -insert identity -string "$FINGERPRINT" "$CONFIG_TEMP"
plutil -insert keychain -string "$KEYCHAIN" "$CONFIG_TEMP"
chmod 600 "$CONFIG_TEMP"
mv -f "$CONFIG_TEMP" "$CONFIG_PATH"
printf 'Local signing identity is ready. Build settings: %s\n' "$CONFIG_PATH"
printf 'The first certificate-signed installation needs one new privacy approval.\n'
