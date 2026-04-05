#!/bin/bash
# =============================================================================
# STEP 3: Create the public OIDC S3 bucket and upload discovery documents.
#
# Run this from ANY machine that has AWS CLI configured with admin credentials.
# You need the keys.json generated in step 2 in the SAME directory.
#
# What this creates:
#   s3://<OIDC_BUCKET>/
#     .well-known/openid-configuration   ← OIDC discovery document
#     keys.json                          ← JWKS (public keys for token verification)
#
# Both objects are PUBLIC READ — AWS STS must be able to fetch them.
#
# Usage:
#   bash 03-setup-oidc-s3.sh
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# FILL THESE IN — must match values used in step 1
# ──────────────────────────────────────────────────────────────────────────────
OIDC_BUCKET_NAME="k8s-oidc-auth-service"   # Globally unique bucket name
AWS_REGION="us-east-1"
# ──────────────────────────────────────────────────────────────────────────────

ISSUER_URL="https://${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"
JWKS_URI="${ISSUER_URL}/keys.json"

echo "==> OIDC Issuer : ${ISSUER_URL}"
echo "==> JWKS URI    : ${JWKS_URI}"
echo ""

# ── Check for keys.json ───────────────────────────────────────────────────────
if [[ ! -f "keys.json" ]]; then
  echo "ERROR: keys.json not found in current directory."
  echo "       Copy it from the master node after running step 2."
  exit 1
fi

# ── 1. Create the S3 bucket ───────────────────────────────────────────────────
echo "==> Creating S3 bucket: ${OIDC_BUCKET_NAME} in ${AWS_REGION}"

if [[ "${AWS_REGION}" == "us-east-1" ]]; then
  # us-east-1 does NOT accept a LocationConstraint
  aws s3api create-bucket \
    --bucket "${OIDC_BUCKET_NAME}" \
    --region "${AWS_REGION}"
else
  aws s3api create-bucket \
    --bucket "${OIDC_BUCKET_NAME}" \
    --region "${AWS_REGION}" \
    --create-bucket-configuration LocationConstraint="${AWS_REGION}"
fi

echo "    Bucket created."

# ── 2. Block public access settings — unblock for Read (OIDC discovery needs it) ──
#    We only need s3:GetObject public access. We keep BlockPublicAcls=true so
#    no public ACLs can be added unintentionally, but allow bucket policies.
echo "==> Setting public access block (allow policy-based public read only)"
aws s3api put-public-access-block \
  --bucket "${OIDC_BUCKET_NAME}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# ── 3. Add a bucket policy that allows public GetObject ───────────────────────
echo "==> Applying bucket policy for public read on OIDC objects"
BUCKET_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowPublicReadForOIDCDiscovery",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": [
        "arn:aws:s3:::${OIDC_BUCKET_NAME}/.well-known/openid-configuration",
        "arn:aws:s3:::${OIDC_BUCKET_NAME}/keys.json"
      ]
    }
  ]
}
EOF
)

echo "${BUCKET_POLICY}" > /tmp/oidc-bucket-policy.json
aws s3api put-bucket-policy \
  --bucket "${OIDC_BUCKET_NAME}" \
  --policy file:///tmp/oidc-bucket-policy.json
echo "    Bucket policy applied."

# ── 4. Create the OIDC discovery document ────────────────────────────────────
echo "==> Creating OIDC discovery document"
DISCOVERY_DOC=$(cat <<EOF
{
  "issuer": "${ISSUER_URL}",
  "jwks_uri": "${JWKS_URI}",
  "authorization_endpoint": "urn:kubernetes:programmatic_authorization",
  "response_types_supported": ["id_token"],
  "subject_types_supported": ["public"],
  "id_token_signing_alg_values_supported": ["RS256"],
  "claims_supported": ["sub", "iss"]
}
EOF
)

echo "${DISCOVERY_DOC}" > /tmp/openid-configuration.json

# ── 5. Upload discovery document ─────────────────────────────────────────────
echo "==> Uploading .well-known/openid-configuration"
aws s3api put-object \
  --bucket "${OIDC_BUCKET_NAME}" \
  --key ".well-known/openid-configuration" \
  --body /tmp/openid-configuration.json \
  --content-type "application/json"

# ── 6. Upload JWKS ────────────────────────────────────────────────────────────
echo "==> Uploading keys.json"
aws s3api put-object \
  --bucket "${OIDC_BUCKET_NAME}" \
  --key "keys.json" \
  --body "keys.json" \
  --content-type "application/json"

# ── 7. Verify the public URLs are accessible ─────────────────────────────────
echo ""
echo "==> Verifying public access:"
curl -sf "${ISSUER_URL}/.well-known/openid-configuration" | python3 -m json.tool \
  && echo "    Discovery document OK" \
  || echo "    WARNING: Discovery document not accessible yet (may take a few seconds)."

curl -sf "${JWKS_URI}" | python3 -m json.tool \
  && echo "    JWKS OK" \
  || echo "    WARNING: JWKS not accessible yet."

echo ""
echo "==> OIDC S3 bucket ready."
echo "    Issuer URL to use everywhere:"
echo "    ${ISSUER_URL}"
echo ""
echo "==> Next step: run  bash 04-setup-aws-iam.sh"
