#!/bin/bash
# =============================================================================
# STEP 1 of 3: MASTER NODE — Setup aws-iam-authenticator for GitHub Actions CI/CD
#
# Run this script ON THE MASTER NODE (as root or with sudo).
#
# What it does:
#   1. Downloads and installs aws-iam-authenticator binary
#   2. Creates the IAM role mapping config file (MountedFile backend)
#   3. Creates systemd service — auto-generates TLS certs + webhook kubeconfig
#   4. Adds --authentication-token-webhook-config-file flag to kube-apiserver
#   5. Creates RBAC for the deployer identity
#   6. Starts aws-iam-authenticator and restarts kube-apiserver
#
# Key: aws-iam-authenticator AUTO-GENERATES its own TLS certs and webhook
# kubeconfig. No manual cert creation needed.
#
# Prerequisites:
#   - kube-apiserver runs via systemd (Kubernetes the Hard Way style)
#   - Unit file at /etc/systemd/system/kube-apiserver.service
#   - kubectl configured and working on the master node
#
# Usage:
#   sudo bash 01-master-node-setup.sh
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# FILL THESE IN before running
# ──────────────────────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID="177701659471"
AWS_REGION="us-east-1"
# The IAM role ARN that GitHub Actions will assume via OIDC.
# This role is created in step 02 (AWS side). Fill this in after running step 02,
# OR set a placeholder and update the ConfigMap later.
GITHUB_ACTIONS_ROLE_NAME="github-actions-k8s-deployer"
# The K8s username and group mapped to the GitHub Actions IAM role
K8S_USERNAME="github-deployer"
K8S_GROUP="system:deployers"
# Cluster ID — used by aws-iam-authenticator to scope tokens.
# Must match the value used in GitHub Actions workflow.
CLUSTER_ID="k8s-self-managed"
# ──────────────────────────────────────────────────────────────────────────────

AUTHENTICATOR_VERSION="0.6.26"
AUTHENTICATOR_BIN="/usr/local/bin/aws-iam-authenticator"
CONFIG_DIR="/etc/kubernetes/aws-iam-authenticator"
STATE_DIR="/var/aws-iam-authenticator"
AUTH_CONFIG="${CONFIG_DIR}/config.yaml"
GENERATED_WEBHOOK_KUBECONFIG="${CONFIG_DIR}/kubeconfig.yaml"
UNIT_FILE="/etc/systemd/system/kube-apiserver.service"
GITHUB_ACTIONS_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${GITHUB_ACTIONS_ROLE_NAME}"

echo "============================================================"
echo "  aws-iam-authenticator Setup — Master Node"
echo "============================================================"
echo ""
echo "  Cluster ID           : ${CLUSTER_ID}"
echo "  GitHub Actions Role  : ${GITHUB_ACTIONS_ROLE_ARN}"
echo "  K8s Username Mapping : ${K8S_USERNAME}"
echo "  K8s Group Mapping    : ${K8S_GROUP}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Install aws-iam-authenticator binary
# ──────────────────────────────────────────────────────────────────────────────
echo "==> Step 1: Installing aws-iam-authenticator v${AUTHENTICATOR_VERSION}"

if [[ -f "${AUTHENTICATOR_BIN}" ]]; then
  echo "    Binary already exists at ${AUTHENTICATOR_BIN}"
  ${AUTHENTICATOR_BIN} version || true
else
  curl -Lo /tmp/aws-iam-authenticator \
    "https://github.com/kubernetes-sigs/aws-iam-authenticator/releases/download/v${AUTHENTICATOR_VERSION}/aws-iam-authenticator_${AUTHENTICATOR_VERSION}_linux_amd64"
  chmod +x /tmp/aws-iam-authenticator
  mv /tmp/aws-iam-authenticator "${AUTHENTICATOR_BIN}"
  echo "    Installed successfully."
  ${AUTHENTICATOR_BIN} version
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Create directory structure
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Creating directories"
mkdir -p "${CONFIG_DIR}"
mkdir -p "${STATE_DIR}"
echo "    Config dir: ${CONFIG_DIR}"
echo "    State dir:  ${STATE_DIR} (auto-generated TLS certs stored here)"

# ──────────────────────────────────────────────────────────────────────────────
# 3. Create IAM role mapping config file (MountedFile backend)
#    aws-iam-authenticator reads this file to map IAM roles → K8s users.
#    This is the default backend (--backend-mode MountedFile).
#    NO ConfigMap or CRD needed — just a local YAML file.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Creating IAM role mapping config"

cat > "${AUTH_CONFIG}" <<EOF
# aws-iam-authenticator configuration (MountedFile backend)
# Maps IAM roles/users to Kubernetes usernames and groups
clusterID: ${CLUSTER_ID}
server:
  mapRoles:
    # GitHub Actions deployer role — assumed via OIDC
    - roleARN: ${GITHUB_ACTIONS_ROLE_ARN}
      username: ${K8S_USERNAME}
      groups:
        - ${K8S_GROUP}
EOF

chmod 600 "${AUTH_CONFIG}"
echo "    Config written to: ${AUTH_CONFIG}"
echo "    Contents:"
cat "${AUTH_CONFIG}"

# ──────────────────────────────────────────────────────────────────────────────
# 4. Create aws-iam-authenticator systemd service
#    Flags used:
#      --cluster-id    : scopes tokens to this cluster
#      --state-dir     : auto-generates TLS cert+key here for webhook HTTPS
#      --generate-kubeconfig : auto-generates webhook kubeconfig for kube-apiserver
#      -c              : path to the IAM role mapping config (MountedFile)
#
#    The authenticator listens on https://127.0.0.1:21362/authenticate
#    and validates tokens against AWS STS.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Creating aws-iam-authenticator systemd service"

cat > /etc/systemd/system/aws-iam-authenticator.service <<EOF
[Unit]
Description=AWS IAM Authenticator for Kubernetes
Documentation=https://github.com/kubernetes-sigs/aws-iam-authenticator
After=network.target

[Service]
Type=simple
ExecStart=${AUTHENTICATOR_BIN} server \\
  --cluster-id=${CLUSTER_ID} \\
  --state-dir=${STATE_DIR} \\
  --generate-kubeconfig=${GENERATED_WEBHOOK_KUBECONFIG} \\
  -c ${AUTH_CONFIG}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "    Service unit file created."
echo "    Webhook kubeconfig will be auto-generated at: ${GENERATED_WEBHOOK_KUBECONFIG}"
echo "    TLS certs will be auto-generated in: ${STATE_DIR}"

# ──────────────────────────────────────────────────────────────────────────────
# 5. Create RBAC for the deployer user/group
#    This gives the github-deployer identity permission to manage
#    deployments, services, configmaps, secrets, etc.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Creating RBAC for deployer"

cat > /tmp/deployer-rbac.yaml <<EOF
---
# ClusterRole with deploy permissions
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: github-deployer
rules:
  # Core resources needed for kubectl apply
  - apiGroups: [""]
    resources:
      - namespaces
      - configmaps
      - secrets
      - services
      - persistentvolumeclaims
      - serviceaccounts
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # Workload resources
  - apiGroups: ["apps"]
    resources:
      - deployments
      - statefulsets
      - replicasets
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # Storage
  - apiGroups: ["storage.k8s.io"]
    resources:
      - storageclasses
    verbs: ["get", "list", "watch"]
  # RBAC (to apply RBAC manifests)
  - apiGroups: ["rbac.authorization.k8s.io"]
    resources:
      - roles
      - rolebindings
      - clusterroles
      - clusterrolebindings
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  # PersistentVolumes (cluster-scoped)
  - apiGroups: [""]
    resources:
      - persistentvolumes
    verbs: ["get", "list", "watch", "create", "update", "patch"]
---
# Bind the ClusterRole to the deployer group
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: github-deployer-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: github-deployer
subjects:
  - kind: Group
    name: ${K8S_GROUP}
    apiGroup: rbac.authorization.k8s.io
EOF

kubectl apply -f /tmp/deployer-rbac.yaml
echo "    RBAC applied."

# ──────────────────────────────────────────────────────────────────────────────
# 6. Add --authentication-token-webhook-config-file to kube-apiserver
#    Points to the kubeconfig auto-generated by aws-iam-authenticator
#    at: /etc/kubernetes/aws-iam-authenticator/kubeconfig.yaml
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Patching kube-apiserver systemd unit"

if [[ ! -f "${UNIT_FILE}" ]]; then
  echo "ERROR: ${UNIT_FILE} does not exist."
  exit 1
fi

# Backup
cp "${UNIT_FILE}" "${UNIT_FILE}.bak.$(date +%Y%m%d%H%M%S)"
echo "    Backup created."

if grep -q "authentication-token-webhook-config-file" "${UNIT_FILE}"; then
  echo "    --authentication-token-webhook-config-file already present — updating."
  sed -i "s|--authentication-token-webhook-config-file=[^ \\\\]*|--authentication-token-webhook-config-file=${GENERATED_WEBHOOK_KUBECONFIG}|" \
      "${UNIT_FILE}"
else
  echo "    Adding --authentication-token-webhook-config-file flag."
  # Insert after --authorization-mode line (common in Hard Way configs)
  sed -i "s|--authorization-mode=\([^ ]*\)|--authorization-mode=\1 --authentication-token-webhook-config-file=${GENERATED_WEBHOOK_KUBECONFIG}|" \
      "${UNIT_FILE}"
fi

echo ""
echo "==> Updated kube-apiserver unit (relevant flags):"
grep -n "authentication-token-webhook\|authorization-mode" "${UNIT_FILE}" | head -10

# ──────────────────────────────────────────────────────────────────────────────
# 7. Start aws-iam-authenticator and restart kube-apiserver
#    aws-iam-authenticator must start FIRST because:
#    - It generates the TLS cert+key in state-dir on first run
#    - It generates the webhook kubeconfig that kube-apiserver needs
#    Then kube-apiserver can start and use the generated webhook kubeconfig.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 7: Starting services"

systemctl daemon-reload

# Start aws-iam-authenticator first (kube-apiserver depends on it)
systemctl enable aws-iam-authenticator
systemctl start aws-iam-authenticator

echo "    Waiting 5 seconds for authenticator to initialize..."
sleep 5

if systemctl is-active --quiet aws-iam-authenticator; then
  echo "    aws-iam-authenticator is RUNNING."
else
  echo "    ERROR: aws-iam-authenticator failed to start."
  echo "    Check logs: journalctl -u aws-iam-authenticator --no-pager -n 30"
  exit 1
fi

# Verify the webhook kubeconfig was auto-generated
if [[ -f "${GENERATED_WEBHOOK_KUBECONFIG}" ]]; then
  echo "    Webhook kubeconfig generated at: ${GENERATED_WEBHOOK_KUBECONFIG}"
else
  echo "    WARNING: Webhook kubeconfig not yet generated. Waiting 5 more seconds..."
  sleep 5
  if [[ -f "${GENERATED_WEBHOOK_KUBECONFIG}" ]]; then
    echo "    Webhook kubeconfig now generated."
  else
    echo "    ERROR: Webhook kubeconfig was not generated."
    echo "    Check logs: journalctl -u aws-iam-authenticator --no-pager -n 30"
    exit 1
  fi
fi

# Restart kube-apiserver
echo "    Restarting kube-apiserver..."
systemctl restart kube-apiserver

echo "    Waiting 10 seconds for API server to come back..."
sleep 10

if systemctl is-active --quiet kube-apiserver; then
  echo "    kube-apiserver is RUNNING."
else
  echo "    ERROR: kube-apiserver failed to start."
  echo "    Check logs: journalctl -u kube-apiserver --no-pager -n 30"
  exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  Master Node Setup Complete!"
echo "============================================================"
echo ""
echo "  What was configured:"
echo "    1. aws-iam-authenticator binary installed"
echo "    2. IAM role mapping config at: ${AUTH_CONFIG}"
echo "    3. aws-iam-authenticator running as systemd service"
echo "    4. Webhook kubeconfig auto-generated at: ${GENERATED_WEBHOOK_KUBECONFIG}"
echo "    5. TLS certs auto-generated in: ${STATE_DIR}"
echo "    6. RBAC ClusterRole + ClusterRoleBinding created"
echo "    7. kube-apiserver patched with webhook auth flag"
echo ""
echo "  Next step:"
echo "    Run 02-aws-iam-setup.sh to create the GitHub OIDC"
echo "    provider and IAM role in AWS."
echo ""
echo "  To verify later (after AWS + GitHub setup):"
echo "    aws-iam-authenticator token -i ${CLUSTER_ID}"
echo "============================================================"
