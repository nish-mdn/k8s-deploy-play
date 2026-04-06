#!/bin/bash
# =============================================================================
# STEP 2 of 3: AWS — Create IAM Role for GitHub Actions (reuse existing OIDC provider)
#
# Run this from ANY machine with AWS CLI configured (admin or IAM-write access).
#
# What it does:
#   1. Reuses your EXISTING GitHub OIDC Identity Provider
#      (token.actions.githubusercontent.com) — you only need ONE per account
#   2. Creates a NEW IAM role for this repo with a trust policy scoped
#      to this specific repo
#
# If you have multiple repos that need to deploy:
#   - They ALL share the same OIDC provider (step 1 is skipped if it exists)
#   - Each repo gets its OWN IAM role with its OWN trust policy
#   - OR you can add multiple repos to ONE role by adding more Statement
#     entries to the trust policy (shown below)
#
# IMPORTANT: This is SEPARATE from your existing K8s OIDC provider
# (k8s-oidc-auth-service.s3.us-east-1.amazonaws.com) which is for IRSA.
# This one is for GitHub → AWS authentication.
#
# Usage:
#   bash 02-aws-iam-setup.sh
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# FILL THESE IN
# ──────────────────────────────────────────────────────────────────────────────
AWS_REGION="us-east-1"
GITHUB_ORG="nish-mdn"                  # GitHub org or username
IAM_ROLE_NAME="github-actions-k8s-deployer"   # IAM role name

# ──────────────────────────────────────────────────────────────────────────────
# REPOS: List ALL GitHub repos that should be allowed to assume this role.
# Add your existing repo and this new repo here.
# Format: "org/repo:branch" — use "*" as branch to allow any branch.
# ──────────────────────────────────────────────────────────────────────────────
REPOS=(
  "${GITHUB_ORG}/k8s-deploy-play:main"
  "${GITHUB_ORG}/terraform-play:main"
)
# ──────────────────────────────────────────────────────────────────────────────

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GITHUB_OIDC_URL="https://token.actions.githubusercontent.com"
GITHUB_OIDC_PROVIDER="token.actions.githubusercontent.com"
GITHUB_OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

echo "============================================================"
echo "  AWS IAM Setup for GitHub Actions OIDC"
echo "============================================================"
echo ""
echo "  AWS Account    : ${AWS_ACCOUNT_ID}"
echo "  GitHub Repos   : ${REPOS[@]}"
echo "  IAM Role       : ${IAM_ROLE_NAME}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Create GitHub OIDC Identity Provider in IAM
#    This lets AWS trust JWT tokens issued by GitHub Actions.
#    You only need ONE provider per AWS account — it can be shared
#    across multiple repos and roles.
# ──────────────────────────────────────────────────────────────────────────────
echo "==> Step 1: Creating GitHub OIDC Identity Provider"

EXISTING_PROVIDERS=$(aws iam list-open-id-connect-providers \
  --query "OpenIDConnectProviderList[*].Arn" --output text 2>/dev/null || true)

GITHUB_PROVIDER_ARN=""
for arn in $EXISTING_PROVIDERS; do
  url=$(aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$arn" \
    --query "Url" --output text 2>/dev/null || true)
  if [[ "$url" == "${GITHUB_OIDC_PROVIDER}" || "$url" == "${GITHUB_OIDC_URL}" ]]; then
    GITHUB_PROVIDER_ARN="$arn"
    echo "    GitHub OIDC provider already exists: ${GITHUB_PROVIDER_ARN}"
    break
  fi
done

if [[ -z "${GITHUB_PROVIDER_ARN}" ]]; then
  GITHUB_PROVIDER_ARN=$(aws iam create-open-id-connect-provider \
    --url "${GITHUB_OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list "${GITHUB_OIDC_THUMBPRINT}" \
    --query "OpenIDConnectProviderArn" \
    --output text)
  echo "    Created GitHub OIDC provider: ${GITHUB_PROVIDER_ARN}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Build IAM trust policy with support for MULTIPLE repos
#    Each repo gets its own Statement entry in the trust policy.
#    The OIDC provider is shared — you NEVER need a second one.
#
#    The "sub" claim format from GitHub is:
#      repo:<org>/<repo>:ref:refs/heads/<branch>
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Building IAM trust policy for ${#REPOS[@]} repo(s)"

# Build the Statement array dynamically — one entry per repo
STATEMENTS=""
for entry in "${REPOS[@]}"; do
  REPO_SPEC="${entry%%:*}"   # e.g. org/repo
  BRANCH="${entry##*:}"      # e.g. main or *

  if [[ "${BRANCH}" == "*" ]]; then
    SUB_OPERATOR="StringLike"
    SUB_VALUE="repo:${REPO_SPEC}:*"
  else
    SUB_OPERATOR="StringEquals"
    SUB_VALUE="repo:${REPO_SPEC}:ref:refs/heads/${BRANCH}"
  fi

  echo "    Adding: ${REPO_SPEC} (branch: ${BRANCH})"

  # Append comma separator if not the first statement
  if [[ -n "${STATEMENTS}" ]]; then
    STATEMENTS="${STATEMENTS},"
  fi

  STATEMENTS="${STATEMENTS}
    {
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${GITHUB_OIDC_PROVIDER}\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"${GITHUB_OIDC_PROVIDER}:aud\": \"sts.amazonaws.com\"
        },
        \"${SUB_OPERATOR}\": {
          \"${GITHUB_OIDC_PROVIDER}:sub\": \"${SUB_VALUE}\"
        }
      }
    }"
done

TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [${STATEMENTS}
  ]
}
EOF
)

echo "${TRUST_POLICY}" > /tmp/github-trust-policy.json
echo ""
echo "    Trust policy:"
cat /tmp/github-trust-policy.json
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 3. Create the IAM Role
#    This role has NO AWS permission policies attached.
#    It exists solely to provide an identity that aws-iam-authenticator
#    can map to a K8s user via the aws-auth ConfigMap.
# ──────────────────────────────────────────────────────────────────────────────
echo "==> Step 3: Creating IAM role: ${IAM_ROLE_NAME}"

if aws iam get-role --role-name "${IAM_ROLE_NAME}" &>/dev/null; then
  echo "    Role already exists — updating trust policy."
  aws iam update-assume-role-policy \
    --role-name "${IAM_ROLE_NAME}" \
    --policy-document file:///tmp/github-trust-policy.json
else
  aws iam create-role \
    --role-name "${IAM_ROLE_NAME}" \
    --assume-role-policy-document file:///tmp/github-trust-policy.json \
    --description "GitHub Actions OIDC role for K8s deployments — no AWS perms, only K8s auth" \
    --tags Key=Project,Value=k8s-ci-cd Key=ManagedBy,Value=github-actions
  echo "    Role created."
fi

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${IAM_ROLE_NAME}"
echo "    Role ARN: ${ROLE_ARN}"

# ──────────────────────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  AWS IAM Setup Complete!"
echo "============================================================"
echo ""
echo "  What was created/updated:"
echo "    1. GitHub OIDC Identity Provider in IAM (reused if existing)"
echo "       (token.actions.githubusercontent.com)"
echo "    2. IAM Role: ${IAM_ROLE_NAME}"
echo "       ARN: ${ROLE_ARN}"
echo "       - Trust policy: ${#REPOS[@]} repo(s) can assume this role"
echo "       - NO AWS permission policies attached (K8s auth only)"
echo ""
echo "  Repos allowed to assume this role:"
for entry in "${REPOS[@]}"; do
  echo "       - ${entry}"
done
echo ""
echo "  Next step:"
echo "    Run 03-github-setup.sh for the GitHub secrets to configure."
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  SAVE THIS — you'll need it for GitHub secrets:        │"
echo "  │                                                         │"
echo "  │  AWS_ROLE_ARN = ${ROLE_ARN}                             │"
echo "  └─────────────────────────────────────────────────────────┘"
echo "============================================================"
