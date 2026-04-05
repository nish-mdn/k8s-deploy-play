#!/bin/bash
# =============================================================================
# STEP 4: Create AWS IAM resources for IRSA
#
# Run this from ANY machine with AWS CLI configured (admin or IAM-write access).
#
# Creates:
#   1. IAM OIDC Identity Provider  — lets AWS trust tokens from your K8s cluster
#   2. IAM Policy                  — S3 permissions (upload/download/list/delete)
#   3. IAM Role                    — assumed only by the auth-service service account
#                                    in the auth-service namespace
#   4. Attach policy to role
#
# Usage:
#   bash 04-setup-aws-iam.sh
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# FILL THESE IN
# ──────────────────────────────────────────────────────────────────────────────
OIDC_BUCKET_NAME="k8s-oidc-auth-service"   # Must match steps 1 & 3
AWS_REGION="us-east-1"
S3_APP_BUCKET="mdn-labs-auth-service"  # The private S3 bucket rails-auth-service will use
IAM_ROLE_NAME="auth-service-s3-role"
IAM_POLICY_NAME="auth-service-s3-policy"
K8S_NAMESPACE="auth-service"
K8S_SERVICE_ACCOUNT="auth-service"
# ──────────────────────────────────────────────────────────────────────────────

ISSUER_URL="https://${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> AWS Account  : ${AWS_ACCOUNT_ID}"
echo "==> OIDC Issuer  : ${ISSUER_URL}"
echo "==> App S3 Bucket: ${S3_APP_BUCKET}"
echo "==> IAM Role     : ${IAM_ROLE_NAME}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Get OIDC thumbprint for the issuer URL
#    AWS requires the SHA-1 fingerprint of the root CA of the TLS certificate
#    served by the OIDC endpoint.
# ──────────────────────────────────────────────────────────────────────────────
echo "==> Fetching OIDC TLS thumbprint for ${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"

# Download the full certificate chain, extract the LAST (root CA) cert,
# then compute its SHA-1 fingerprint — must be exactly 40 hex chars.
CERTS_PEM=$(openssl s_client \
  -connect "${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com:443" \
  -servername "${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com" \
  -showcerts </dev/null 2>/dev/null)

# Extract the last certificate in the chain (root CA)
ROOT_CERT=$(echo "${CERTS_PEM}" \
  | awk 'BEGIN{cert=""} /-----BEGIN CERTIFICATE-----/{cert=""} {cert=cert "\n" $0} /-----END CERTIFICATE-----/{last=cert} END{print last}')

THUMBPRINT=$(echo "${ROOT_CERT}" \
  | openssl x509 -fingerprint -sha1 -noout 2>/dev/null \
  | sed 's/.*=//' \
  | tr -d ':' \
  | tr '[:upper:]' '[:lower:]')

# Validate: must be exactly 40 hex characters
if [[ ! "${THUMBPRINT}" =~ ^[a-f0-9]{40}$ ]]; then
  echo "ERROR: Thumbprint is invalid (got '${THUMBPRINT}', expected 40 hex chars)." >&2
  echo "       Debug: try running manually:" >&2
  echo "       openssl s_client -connect ${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com:443 -showcerts </dev/null 2>/dev/null" >&2
  exit 1
fi

echo "    Thumbprint: ${THUMBPRINT} (${#THUMBPRINT} chars — OK)"

# ──────────────────────────────────────────────────────────────────────────────
# 2. Create IAM OIDC Identity Provider
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Creating IAM OIDC Identity Provider"

# Check if it already exists
EXISTING_PROVIDERS=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[*].Arn" --output text 2>/dev/null || true)

PROVIDER_ARN=""
for arn in $EXISTING_PROVIDERS; do
  url=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$arn" \
        --query "Url" --output text 2>/dev/null || true)
  if [[ "$url" == "${ISSUER_URL#https://}" ]]; then
    PROVIDER_ARN="$arn"
    echo "    OIDC provider already exists: ${PROVIDER_ARN}"
    break
  fi
done

if [[ -z "${PROVIDER_ARN}" ]]; then
  PROVIDER_ARN=$(aws iam create-open-id-connect-provider \
    --url "${ISSUER_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${THUMBPRINT}" \
    --query "OpenIDConnectProviderArn" \
    --output text)
  echo "    Created OIDC provider: ${PROVIDER_ARN}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Create the IAM trust policy
#    The condition pins the role assumption to:
#      - Specific namespace (auth-service)
#      - Specific service account (auth-service)
#    Any pod NOT using this exact service account CANNOT assume the role.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Building IAM trust policy"

# Strip the "https://" prefix — IAM condition key is the bare host+path
OIDC_PROVIDER_ID="${ISSUER_URL#https://}"

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER_ID}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER_ID}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER_ID}:sub": "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SERVICE_ACCOUNT}"
        }
      }
    }
  ]
}
EOF
)

echo "${TRUST_POLICY}" > /tmp/trust-policy.json
echo "    Trust policy written to /tmp/trust-policy.json"

# ──────────────────────────────────────────────────────────────────────────────
# 4. Create IAM role  (or update trust policy if it already exists)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Creating IAM role: ${IAM_ROLE_NAME}"

if aws iam get-role --role-name "${IAM_ROLE_NAME}" &>/dev/null; then
  echo "    Role already exists — updating trust policy."
  aws iam update-assume-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-document file:///tmp/trust-policy.json
else
  aws iam create-role \
    --role-name "${IAM_ROLE_NAME}" \
    --assume-role-policy-document file:///tmp/trust-policy.json \
    --description "IRSA role for rails-auth-service pods - S3 access only" \
    --tags Key=Project,Value=rails-auth-service Key=ManagedBy,Value=irsa
  echo "    Role created."
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"
echo "    Role ARN: ${ROLE_ARN}"

# ──────────────────────────────────────────────────────────────────────────────
# 5. Create or update S3 IAM policy
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Creating IAM policy: ${IAM_POLICY_NAME}"

S3_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowS3BucketList",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": "arn:aws:s3:::${S3_APP_BUCKET}"
    },
    {
      "Sid": "AllowS3ObjectOperations",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObjectVersion",
        "s3:DeleteObjectVersion"
      ],
      "Resource": "arn:aws:s3:::${S3_APP_BUCKET}/*"
    }
  ]
}
EOF
)

# If policy already exists, create a new version
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"
if aws iam get-policy --policy-arn "${POLICY_ARN}" &>/dev/null; then
  echo "    Policy already exists — creating new policy version."
  echo "${S3_POLICY}" > /tmp/s3-policy.json
  aws iam create-policy-version \
    --policy-arn "${POLICY_ARN}" \
    --policy-document file:///tmp/s3-policy.json \
    --set-as-default
else
  echo "${S3_POLICY}" > /tmp/s3-policy.json
  POLICY_ARN=$(aws iam create-policy \
    --policy-name "${IAM_POLICY_NAME}" \
    --policy-document file:///tmp/s3-policy.json \
    --description "S3 access for rails-auth-service IRSA" \
    --tags Key=Project,Value=rails-auth-service Key=ManagedBy,Value=irsa \
    --query "Policy.Arn" \
    --output text)
  echo "    Policy created: ${POLICY_ARN}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 6. Attach policy to role
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Attaching policy to role"
aws iam attach-role-policy \
  --role-name "${IAM_ROLE_NAME}" \
  --policy-arn "${POLICY_ARN}"
echo "    Policy attached."

# ──────────────────────────────────────────────────────────────────────────────
# 7. Print summary for next steps
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "=========================================================="
echo " AWS IAM SETUP COMPLETE"
echo "=========================================================="
echo ""
echo " ROLE_ARN  = ${ROLE_ARN}"
echo " POLICY_ARN= ${POLICY_ARN}"
echo " OIDC_PROVIDER_ARN = ${PROVIDER_ARN}"
echo ""
echo " Copy the ROLE_ARN above and paste it into:"
echo "   k8s/09-rbac.yaml  → ServiceAccount annotation"
echo "   k8s/06-application.yaml → AWS_ROLE_ARN env var"
echo ""
echo " Then apply the K8s manifests:"
echo "   kubectl apply -f k8s/09-rbac.yaml"
echo "   kubectl apply -f k8s/02-configmap.yaml"
echo "   kubectl apply -f k8s/06-application.yaml"
echo "=========================================================="
