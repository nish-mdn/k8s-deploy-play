#!/bin/bash
# =============================================================================
# STEP 1: Configure Kubernetes API Server for IRSA on a self-managed (hard-way)
#         cluster where kube-apiserver runs as a SYSTEMD SERVICE.
#
# Run this script ON THE MASTER NODE (as root or with sudo).
#
# What it does:
#   - Patches the kube-apiserver systemd unit file to add two flags:
#       --service-account-issuer   → the "iss" claim in projected SA tokens
#       --api-audiences            → accepted token audience; sts.amazonaws.com
#                                    is required for AWS STS verification
#   - Reloads systemd and restarts kube-apiserver
#
# Prerequisites:
#   - kube-apiserver runs via systemd (Kubernetes the Hard Way style)
#   - Unit file at /etc/systemd/system/kube-apiserver.service
#   - SA signing key + cert at /var/lib/kubernetes/
#
# Usage:
#   sudo bash 01-configure-apiserver.sh
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# FILL THESE IN before running
# ──────────────────────────────────────────────────────────────────────────────
OIDC_BUCKET_NAME="k8s-oidc-auth-service"   # S3 bucket that will host the OIDC docs
AWS_REGION="us-east-1"                      # Region where the OIDC bucket lives
# ──────────────────────────────────────────────────────────────────────────────

ISSUER_URL="https://${OIDC_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com"
UNIT_FILE="/etc/systemd/system/kube-apiserver.service"

echo "==> Patching systemd unit: ${UNIT_FILE}"
echo "    ISSUER_URL = ${ISSUER_URL}"

# ── Verify the unit file exists ───────────────────────────────────────────────
if [[ ! -f "${UNIT_FILE}" ]]; then
  echo "ERROR: ${UNIT_FILE} does not exist."
  echo "       Check your kube-apiserver systemd unit path."
  exit 1
fi

# ── Safety: back up the unit file ─────────────────────────────────────────────
cp "${UNIT_FILE}" "${UNIT_FILE}.bak.$(date +%Y%m%d%H%M%S)"
echo "    Backup created."

# ── Show current ExecStart (for reference) ────────────────────────────────────
echo ""
echo "==> Current ExecStart line(s):"
grep -n "ExecStart\|service-account-issuer\|api-audiences" "${UNIT_FILE}" || true
echo ""

# ── Add/update --service-account-issuer ───────────────────────────────────────
#    In a Hard Way unit file, ExecStart is a multi-line block using \ continuations.
#    We insert flags before the last line of the ExecStart block or update existing.
if grep -q "service-account-issuer" "${UNIT_FILE}"; then
  echo "    --service-account-issuer already present — updating value."
  sed -i "s|--service-account-issuer=[^ \\\\]*|--service-account-issuer=${ISSUER_URL}|" \
      "${UNIT_FILE}"
else
  echo "    Adding --service-account-issuer flag."
  # Insert after --service-account-key-file line (common in Hard Way configs)
  sed -i "/--service-account-key-file/a\\  --service-account-issuer=${ISSUER_URL} \\\\" \
      "${UNIT_FILE}"
fi

# ── Add/update --api-audiences ────────────────────────────────────────────────
if grep -q "api-audiences" "${UNIT_FILE}"; then
  echo "    --api-audiences already present — updating value."
  sed -i "s|--api-audiences=[^ \\\\]*|--api-audiences=sts.amazonaws.com|" \
      "${UNIT_FILE}"
else
  echo "    Adding --api-audiences flag."
  sed -i "/--service-account-issuer/a\\  --api-audiences=sts.amazonaws.com \\\\" \
      "${UNIT_FILE}"
fi

echo ""
echo "==> Updated ExecStart section (relevant lines):"
grep -n "service-account-issuer\|api-audiences\|service-account-key\|service-account-signing" \
     "${UNIT_FILE}" | head -20

# ── Reload systemd and restart the API server ────────────────────────────────
echo ""
echo "==> Reloading systemd daemon and restarting kube-apiserver..."
systemctl daemon-reload
systemctl restart kube-apiserver

echo "==> Waiting 10 seconds for API server to come back..."
sleep 10

# ── Verify ────────────────────────────────────────────────────────────────────
echo "==> Checking kube-apiserver status:"
systemctl is-active kube-apiserver && echo "    kube-apiserver is RUNNING." \
  || { echo "    ERROR: kube-apiserver failed to start. Check logs:"; \
       echo "    journalctl -u kube-apiserver --no-pager -n 30"; exit 1; }

echo ""
echo "==> Verifying the flags are active in the running process:"
ps aux | grep kube-apiserver | grep -o "service-account-issuer=[^ ]*" || true
ps aux | grep kube-apiserver | grep -o "api-audiences=[^ ]*" || true

# ── Check SA cert exists (needed for JWKS generation) ────────────────────────
echo ""
echo "==> Checking SA certificate at /var/lib/kubernetes/:"
if [[ -f "/var/lib/kubernetes/service-account.crt" ]]; then
  echo "    service-account.crt found — ready for JWKS generation."
  echo "    Extracting public key preview:"
  openssl x509 -in /var/lib/kubernetes/service-account.crt -pubkey -noout | head -3
else
  echo "    WARNING: service-account.crt not found at /var/lib/kubernetes/"
  echo "    Check the exact path used in --service-account-key-file flag."
fi

echo ""
echo "==> DONE. Next step:"
echo "    python3 02-generate-jwks.py   (on this master node)"
