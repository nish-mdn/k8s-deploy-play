#!/bin/bash
# =============================================================================
# STEP 1 of 3: MASTER NODE — Setup aws-iam-authenticator for GitHub Actions CI/CD
#
# Run this script ON THE MASTER NODE (as root or with sudo).
#
# What it does:
#   1. Downloads and installs aws-iam-authenticator binary
#   2. Creates the webhook token authentication config file
#   3. Creates the aws-iam-authenticator ConfigMap (IAM → K8s user mapping)
#   4. Adds --authentication-token-webhook-config-file flag to kube-apiserver
#   5. Restarts kube-apiserver
#
# After this, any IAM identity mapped in the ConfigMap can authenticate
# to the K8s API server using short-lived STS tokens — no static K8s
# credentials needed.
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
WEBHOOK_CONFIG="/etc/kubernetes/aws-iam-authenticator/webhook-config.yaml"
AUTHENTICATOR_KUBECONFIG="/etc/kubernetes/aws-iam-authenticator/authenticator-kubeconfig.yaml"
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
echo "==> Step 2: Creating config directory"
mkdir -p /etc/kubernetes/aws-iam-authenticator
echo "    Directory created: /etc/kubernetes/aws-iam-authenticator"

# ──────────────────────────────────────────────────────────────────────────────
# 3. Generate signing keypair for aws-iam-authenticator
#    The authenticator uses this to sign/verify its own internal state.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Generating signing keypair"

CERT_DIR="/etc/kubernetes/aws-iam-authenticator"
if [[ -f "${CERT_DIR}/aws-iam-authenticator.crt" && -f "${CERT_DIR}/aws-iam-authenticator.key" ]]; then
  echo "    Keypair already exists — skipping."
else
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${CERT_DIR}/aws-iam-authenticator.key" \
    -out "${CERT_DIR}/aws-iam-authenticator.crt" \
    -days 3650 -nodes \
    -subj "/CN=aws-iam-authenticator"
  chmod 600 "${CERT_DIR}/aws-iam-authenticator.key"
  echo "    Keypair generated."
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. Create the webhook token authentication config
#    This tells kube-apiserver how to reach aws-iam-authenticator for
#    token validation. The authenticator runs on localhost:21362.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Creating webhook config"

cat > "${WEBHOOK_CONFIG}" <<EOF
# Webhook Token Authentication Config for aws-iam-authenticator
# kube-apiserver sends bearer tokens here for validation
apiVersion: v1
kind: Config
clusters:
  - name: aws-iam-authenticator
    cluster:
      server: https://127.0.0.1:21362/authenticate
      certificate-authority: ${CERT_DIR}/aws-iam-authenticator.crt
users:
  - name: apiserver
    user:
      client-certificate: ${CERT_DIR}/aws-iam-authenticator.crt
      client-key: ${CERT_DIR}/aws-iam-authenticator.key
current-context: webhook
contexts:
  - name: webhook
    context:
      cluster: aws-iam-authenticator
      user: apiserver
EOF

chmod 600 "${WEBHOOK_CONFIG}"
echo "    Webhook config written to: ${WEBHOOK_CONFIG}"

# ──────────────────────────────────────────────────────────────────────────────
# 5. Create aws-iam-authenticator systemd service
#    This runs the authenticator as a daemon that listens on localhost:21362
#    and validates tokens against AWS STS.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Creating aws-iam-authenticator systemd service"

cat > /etc/systemd/system/aws-iam-authenticator.service <<EOF
[Unit]
Description=AWS IAM Authenticator for Kubernetes
Documentation=https://github.com/kubernetes-sigs/aws-iam-authenticator
After=network.target

[Service]
Type=simple
ExecStart=${AUTHENTICATOR_BIN} server \\
  --cluster-id=${CLUSTER_ID} \\
  --state-dir=/var/aws-iam-authenticator \\
  --kubeconfig=${AUTHENTICATOR_KUBECONFIG} \\
  --tls-cert-file=${CERT_DIR}/aws-iam-authenticator.crt \\
  --tls-private-key-file=${CERT_DIR}/aws-iam-authenticator.key
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

echo "    Service unit file created."

# Create state directory
mkdir -p /var/aws-iam-authenticator

# ──────────────────────────────────────────────────────────────────────────────
# 6. Create kubeconfig for aws-iam-authenticator to talk to kube-apiserver
#    The authenticator needs this to read its ConfigMap from the cluster.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Creating authenticator kubeconfig"

# Use the same CA and certs that kube-apiserver uses
K8S_CA="/var/lib/kubernetes/ca.crt"
# Use admin certs for the authenticator to read ConfigMaps
ADMIN_CERT="/var/lib/kubernetes/admin.crt"
ADMIN_KEY="/var/lib/kubernetes/admin.key"

# Detect the API server address
APISERVER_ADDR="https://127.0.0.1:6443"

cat > "${AUTHENTICATOR_KUBECONFIG}" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: local
    cluster:
      server: ${APISERVER_ADDR}
      certificate-authority: ${K8S_CA}
users:
  - name: aws-iam-authenticator
    user:
      client-certificate: ${ADMIN_CERT}
      client-key: ${ADMIN_KEY}
current-context: local
contexts:
  - name: local
    context:
      cluster: local
      user: aws-iam-authenticator
EOF

chmod 600 "${AUTHENTICATOR_KUBECONFIG}"
echo "    Authenticator kubeconfig written to: ${AUTHENTICATOR_KUBECONFIG}"

# ──────────────────────────────────────────────────────────────────────────────
# 7. Create the aws-auth ConfigMap in kube-system namespace
#    This is where IAM role → K8s user/group mappings are defined.
#    Any IAM role listed here can authenticate to the cluster.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 7: Creating aws-auth ConfigMap"

cat > /tmp/aws-auth-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-iam-authenticator
  namespace: kube-system
data:
  config.yaml: |
    clusterID: ${CLUSTER_ID}
    server:
      mapRoles:
        # GitHub Actions deployer role — mapped to a K8s user and group
        - roleARN: ${GITHUB_ACTIONS_ROLE_ARN}
          username: ${K8S_USERNAME}
          groups:
            - ${K8S_GROUP}
EOF

echo "    ConfigMap manifest:"
cat /tmp/aws-auth-configmap.yaml
echo ""
kubectl apply -f /tmp/aws-auth-configmap.yaml
echo "    ConfigMap applied."

# ──────────────────────────────────────────────────────────────────────────────
# 8. Create RBAC for the deployer user/group
#    This gives the github-deployer identity permission to manage
#    deployments, services, configmaps, secrets, etc.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 8: Creating RBAC for deployer"

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
# 9. Add --authentication-token-webhook-config-file to kube-apiserver
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 9: Patching kube-apiserver systemd unit"

if [[ ! -f "${UNIT_FILE}" ]]; then
  echo "ERROR: ${UNIT_FILE} does not exist."
  exit 1
fi

# Backup
cp "${UNIT_FILE}" "${UNIT_FILE}.bak.$(date +%Y%m%d%H%M%S)"
echo "    Backup created."

if grep -q "authentication-token-webhook-config-file" "${UNIT_FILE}"; then
  echo "    --authentication-token-webhook-config-file already present — updating."
  sed -i "s|--authentication-token-webhook-config-file=[^ \\\\]*|--authentication-token-webhook-config-file=${WEBHOOK_CONFIG}|" \
      "${UNIT_FILE}"
else
  echo "    Adding --authentication-token-webhook-config-file flag."
  # Insert after --authorization-mode line (common in Hard Way configs)
  sed -i "/--authorization-mode/a\\  --authentication-token-webhook-config-file=${WEBHOOK_CONFIG} \\\\" \
      "${UNIT_FILE}"
fi

echo ""
echo "==> Updated kube-apiserver unit (relevant flags):"
grep -n "authentication-token-webhook\|authorization-mode" "${UNIT_FILE}" | head -10

# ──────────────────────────────────────────────────────────────────────────────
# 10. Start aws-iam-authenticator and restart kube-apiserver
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 10: Starting services"

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
echo "    2. Webhook config created at: ${WEBHOOK_CONFIG}"
echo "    3. aws-iam-authenticator running as systemd service"
echo "    4. aws-auth ConfigMap created in kube-system namespace"
echo "    5. RBAC ClusterRole + ClusterRoleBinding created"
echo "    6. kube-apiserver patched with webhook auth flag"
echo ""
echo "  Next step:"
echo "    Run 02-aws-iam-setup.sh to create the GitHub OIDC"
echo "    provider and IAM role in AWS."
echo ""
echo "  To verify later (after AWS + GitHub setup):"
echo "    aws-iam-authenticator token -i ${CLUSTER_ID}"
echo "============================================================"
