#!/bin/bash
# =============================================================================
# STEP 2: Generate JWKS (JSON Web Key Set) from the Kubernetes Service Account
#         certificate using ONLY openssl + standard shell tools (no Python deps).
#
# Reads:  /var/lib/kubernetes/service-account.crt  (or pass a path as $1)
# Writes: keys.json  in the current directory
#
# Run ON THE MASTER NODE after step 1.
#
# Usage:
#   bash 02-generate-jwks.sh
#   bash 02-generate-jwks.sh /var/lib/kubernetes/service-account.crt
#   bash 02-generate-jwks.sh /path/to/sa.pub
# =============================================================================
set -euo pipefail

CERT_FILE="${1:-/var/lib/kubernetes/service-account.crt}"

echo "==> Input file: ${CERT_FILE}"

if [[ ! -f "${CERT_FILE}" ]]; then
  echo "ERROR: File not found: ${CERT_FILE}" >&2
  exit 1
fi

# ── 1. Extract the public key in PEM then DER form ──────────────────────────
#    Handles both .crt (certificate) and .pub (raw public key) files.
if grep -q "BEGIN CERTIFICATE" "${CERT_FILE}"; then
  echo "    Detected X.509 certificate — extracting public key..."
  PUB_PEM=$(openssl x509 -in "${CERT_FILE}" -pubkey -noout)
else
  echo "    Detected raw PEM public key."
  PUB_PEM=$(cat "${CERT_FILE}")
fi

# Convert PEM public key to DER (binary)
PUB_DER=$(echo "${PUB_PEM}" | openssl pkey -pubin -outform DER 2>/dev/null)

# ── 2. Generate KID = base64url(SHA-256(DER SubjectPublicKeyInfo)) ───────────
KID=$(echo "${PUB_PEM}" \
  | openssl pkey -pubin -outform DER 2>/dev/null \
  | openssl dgst -sha256 -binary \
  | openssl base64 -A \
  | tr '+/' '-_' \
  | tr -d '=')

echo "    KID: ${KID}"

# ── 3. Extract modulus (n) and exponent (e) in base64url ─────────────────────
#    openssl rsa -text prints modulus as hex and exponent as decimal.

# Modulus — extract hex, strip colons and whitespace, convert to binary, base64url
MODULUS_HEX=$(echo "${PUB_PEM}" \
  | openssl rsa -pubin -modulus -noout 2>/dev/null \
  | sed 's/Modulus=//')

# Convert hex to binary then base64url (strip leading 00 padding if present)
N=$(echo "${MODULUS_HEX}" \
  | sed 's/^00//' \
  | xxd -r -p \
  | openssl base64 -A \
  | tr '+/' '-_' \
  | tr -d '=')

# Exponent — almost always 65537 = AQAB in base64url
E_DEC=$(echo "${PUB_PEM}" \
  | openssl rsa -pubin -text -noout 2>/dev/null \
  | grep "Exponent:" \
  | grep -oP '\d+(?= )' \
  | head -1)

# Convert decimal exponent to base64url
E_HEX=$(printf '%x' "${E_DEC}")
# Ensure even number of hex digits
if (( ${#E_HEX} % 2 != 0 )); then
  E_HEX="0${E_HEX}"
fi
E=$(echo "${E_HEX}" | xxd -r -p | openssl base64 -A | tr '+/' '-_' | tr -d '=')

echo "    Exponent: ${E_DEC} (${E})"
echo "    Modulus length: ${#MODULUS_HEX} hex chars"

# ── 4. Build keys.json ───────────────────────────────────────────────────────
cat > keys.json <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "alg": "RS256",
      "use": "sig",
      "kid": "${KID}",
      "n": "${N}",
      "e": "${E}"
    }
  ]
}
EOF

echo ""
echo "==> keys.json written successfully."
echo ""
cat keys.json
echo ""
echo "==> Next step: copy keys.json to where you'll run 03-setup-oidc-s3.sh,"
echo "    then run:  bash 03-setup-oidc-s3.sh"
