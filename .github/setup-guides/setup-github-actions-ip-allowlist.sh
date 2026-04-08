#!/bin/bash
# =============================================================================
# GitHub Actions IP Allowlist — AWS Security Group Setup
#
# Problem:
#   GitHub Actions runners use 2000+ IP ranges that change periodically.
#   AWS security groups have a 60-rule default limit (max 200 with quota increase).
#   You CANNOT add them as individual inbound rules.
#
# Solution:
#   Use AWS Managed Prefix Lists. A prefix list can hold up to 1000 entries,
#   and referencing a prefix list in a security group counts as ONE rule.
#   Since GitHub has ~2000+ CIDRs, we split across multiple prefix lists.
#
# What this script does:
#   1. Fetches the latest GitHub Actions IP ranges from api.github.com/meta
#   2. Creates (or updates) AWS managed prefix lists with those CIDRs
#   3. Adds inbound rules to your security group referencing the prefix lists
#
# Schedule:
#   GitHub updates IPs periodically. Run this script weekly via cron or
#   an EventBridge-triggered Lambda to stay current.
#
# Usage:
#   bash setup-github-actions-ip-allowlist.sh
#
# Prerequisites:
#   - AWS CLI configured with permissions for EC2 prefix lists and SGs
#   - curl, jq installed
# =============================================================================
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# FILL THESE IN
# ──────────────────────────────────────────────────────────────────────────────
AWS_REGION="us-east-1"
MASTER_INSTANCE_ID="i-xxxxxxxxxxxxxxxxx"      # Your master node's EC2 instance ID
K8S_API_PORT=6443                             # kube-apiserver port
PREFIX_LIST_NAME="github-actions-runners"     # Name prefix for managed prefix lists
MAX_ENTRIES_PER_LIST=1000                     # AWS limit per prefix list
GH_ACTIONS_SG_NAME="github-actions-k8s-access" # Dedicated SG for GitHub Actions
# ──────────────────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  GitHub Actions IP Allowlist Setup"
echo "============================================================"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Fetch GitHub Actions IP ranges
# ──────────────────────────────────────────────────────────────────────────────
echo "==> Step 1: Fetching GitHub Actions IP ranges"

GITHUB_META=$(curl -s https://api.github.com/meta)

# Extract only the "actions" IP ranges (IPv4 only — SGs don't need IPv6 for most setups)
ACTIONS_IPS=$(echo "${GITHUB_META}" | jq -r '.actions[]' | grep -v ':')

TOTAL_IPS=$(echo "${ACTIONS_IPS}" | wc -l)
echo "    Found ${TOTAL_IPS} IPv4 CIDR ranges for GitHub Actions"

# ──────────────────────────────────────────────────────────────────────────────
# 2. Split CIDRs into chunks (prefix lists have a 1000-entry limit)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 2: Splitting into prefix list chunks (max ${MAX_ENTRIES_PER_LIST} per list)"

# Calculate number of prefix lists needed
NUM_LISTS=$(( (TOTAL_IPS + MAX_ENTRIES_PER_LIST - 1) / MAX_ENTRIES_PER_LIST ))
echo "    Need ${NUM_LISTS} prefix list(s)"

# Split into temp files
TMPDIR=$(mktemp -d)
echo "${ACTIONS_IPS}" | split -l ${MAX_ENTRIES_PER_LIST} - "${TMPDIR}/chunk_"

# ──────────────────────────────────────────────────────────────────────────────
# 3. Create or update managed prefix lists
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 3: Creating/updating managed prefix lists"

CHUNK_INDEX=0
PREFIX_LIST_IDS=()

for chunk_file in "${TMPDIR}"/chunk_*; do
  CHUNK_INDEX=$((CHUNK_INDEX + 1))
  LIST_NAME="${PREFIX_LIST_NAME}-${CHUNK_INDEX}"
  CHUNK_SIZE=$(wc -l < "${chunk_file}")

  echo ""
  echo "    Processing ${LIST_NAME} (${CHUNK_SIZE} CIDRs)..."

  # Check if prefix list already exists
  EXISTING_PL_ID=$(aws ec2 describe-managed-prefix-lists \
    --region "${AWS_REGION}" \
    --filters "Name=prefix-list-name,Values=${LIST_NAME}" \
    --query "PrefixLists[0].PrefixListId" \
    --output text 2>/dev/null || echo "None")

  if [[ "${EXISTING_PL_ID}" != "None" && -n "${EXISTING_PL_ID}" ]]; then
    echo "    Prefix list exists: ${EXISTING_PL_ID} - updating entries..."

    # Get current version (required for modification)
    CURRENT_VERSION=$(aws ec2 describe-managed-prefix-lists \
      --region "${AWS_REGION}" \
      --prefix-list-ids "${EXISTING_PL_ID}" \
      --query "PrefixLists[0].Version" \
      --output text)

    # Remove all existing entries in batches of 100
    EXISTING_ENTRIES=$(aws ec2 get-managed-prefix-list-entries \
      --region "${AWS_REGION}" \
      --prefix-list-id "${EXISTING_PL_ID}" \
      --query "Entries[].Cidr" \
      --output text 2>/dev/null || echo "")

    if [[ -n "${EXISTING_ENTRIES}" ]]; then
      echo "${EXISTING_ENTRIES}" | tr '\t' '\n' > "${TMPDIR}/existing_entries.txt"
      split -l 100 "${TMPDIR}/existing_entries.txt" "${TMPDIR}/remove_batch_"


      for batch_file in "${TMPDIR}"/remove_batch_*; do
        REMOVE_ENTRIES=""
        while IFS= read -r cidr; do
          REMOVE_ENTRIES="${REMOVE_ENTRIES} Cidr=${cidr}"
        done < "${batch_file}"

        CURRENT_VERSION=$(aws ec2 describe-managed-prefix-lists \
          --region "${AWS_REGION}" \
          --prefix-list-ids "${EXISTING_PL_ID}" \
          --query "PrefixLists[0].Version" \
          --output text)

        aws ec2 modify-managed-prefix-list \
          --region "${AWS_REGION}" \
          --prefix-list-id "${EXISTING_PL_ID}" \
          --current-version "${CURRENT_VERSION}" \
          --remove-entries ${REMOVE_ENTRIES}

        # Wait for prefix list to leave "modify-in-progress" state
        aws ec2 wait prefix-list-modified \
          --region "${AWS_REGION}" \
          --prefix-list-id "${EXISTING_PL_ID}" 2>/dev/null || sleep 3
      done
      rm -f "${TMPDIR}"/remove_batch_* "${TMPDIR}/existing_entries.txt"
    fi

    # Add new entries in batches of 100
    split -l 100 "${chunk_file}" "${TMPDIR}/add_batch_"
    BATCH_NUM=0
    TOTAL_BATCHES=$(ls "${TMPDIR}"/add_batch_* | wc -l)

    for batch_file in "${TMPDIR}"/add_batch_*; do
      BATCH_NUM=$((BATCH_NUM + 1))
      BATCH_SIZE=$(wc -l < "${batch_file}")
      echo "      Adding batch ${BATCH_NUM}/${TOTAL_BATCHES} (${BATCH_SIZE} entries)..."

      ADD_ENTRIES=""
      while IFS= read -r cidr; do
        ADD_ENTRIES="${ADD_ENTRIES} Cidr=${cidr},Description=github-actions"
      done < "${batch_file}"

      CURRENT_VERSION=$(aws ec2 describe-managed-prefix-lists \
        --region "${AWS_REGION}" \
        --prefix-list-ids "${EXISTING_PL_ID}" \
        --query "PrefixLists[0].Version" \
        --output text)

      aws ec2 modify-managed-prefix-list \
        --region "${AWS_REGION}" \
        --prefix-list-id "${EXISTING_PL_ID}" \
        --current-version "${CURRENT_VERSION}" \
        --add-entries ${ADD_ENTRIES}

      # Wait for prefix list to leave "modify-in-progress" state
      aws ec2 wait prefix-list-modified \
        --region "${AWS_REGION}" \
        --prefix-list-id "${EXISTING_PL_ID}" 2>/dev/null || sleep 3
    done
    rm -f "${TMPDIR}"/add_batch_*

    PREFIX_LIST_IDS+=("${EXISTING_PL_ID}")
    echo "    Updated: ${EXISTING_PL_ID}"
  else
    echo "    Creating new prefix list: ${LIST_NAME} (empty, then adding in batches)..."

    # Create the prefix list empty first (no entries)
    NEW_PL_ID=$(aws ec2 create-managed-prefix-list \
      --region "${AWS_REGION}" \
      --prefix-list-name "${LIST_NAME}" \
      --address-family "IPv4" \
      --max-entries "${MAX_ENTRIES_PER_LIST}" \
      --query "PrefixList.PrefixListId" \
      --output text)

    echo "    Created: ${NEW_PL_ID} — now adding entries in batches of 100..."

    # Wait for prefix list to be ready
    aws ec2 wait prefix-list-modified \
      --region "${AWS_REGION}" \
      --prefix-list-id "${NEW_PL_ID}" 2>/dev/null || sleep 3

    # Add entries in batches of 100
    split -l 100 "${chunk_file}" "${TMPDIR}/create_batch_"
    BATCH_NUM=0
    TOTAL_BATCHES=$(ls "${TMPDIR}"/create_batch_* | wc -l)

    for batch_file in "${TMPDIR}"/create_batch_*; do
      BATCH_NUM=$((BATCH_NUM + 1))
      BATCH_SIZE=$(wc -l < "${batch_file}")
      echo "      Adding batch ${BATCH_NUM}/${TOTAL_BATCHES} (${BATCH_SIZE} entries)..."

      ADD_ENTRIES=""
      while IFS= read -r cidr; do
        ADD_ENTRIES="${ADD_ENTRIES} Cidr=${cidr},Description=github-actions"
      done < "${batch_file}"

      CURRENT_VERSION=$(aws ec2 describe-managed-prefix-lists \
        --region "${AWS_REGION}" \
        --prefix-list-ids "${NEW_PL_ID}" \
        --query "PrefixLists[0].Version" \
        --output text)

      aws ec2 modify-managed-prefix-list \
        --region "${AWS_REGION}" \
        --prefix-list-id "${NEW_PL_ID}" \
        --current-version "${CURRENT_VERSION}" \
        --add-entries ${ADD_ENTRIES}

      # Wait for prefix list to leave "modify-in-progress" state
      aws ec2 wait prefix-list-modified \
        --region "${AWS_REGION}" \
        --prefix-list-id "${NEW_PL_ID}" 2>/dev/null || sleep 3
    done
    rm -f "${TMPDIR}"/create_batch_*

    PREFIX_LIST_IDS+=("${NEW_PL_ID}")
    echo "    Created: ${NEW_PL_ID}"
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 4. Create a DEDICATED security group for GitHub Actions access
#    Your existing SG has hit its rule limit. An EC2 instance can have up to
#    5 security groups attached. We create a separate SG with ONLY the
#    prefix list rules and attach it to the master node alongside the existing SG.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 4: Setting up dedicated security group"

# Get the VPC ID from the master node instance
VPC_ID=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${MASTER_INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].VpcId" \
  --output text)
echo "    VPC: ${VPC_ID}"

# Check if our dedicated SG already exists
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=${GH_ACTIONS_SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query "SecurityGroups[0].GroupId" \
  --output text 2>/dev/null || echo "None")

if [[ "${SECURITY_GROUP_ID}" == "None" || -z "${SECURITY_GROUP_ID}" ]]; then
  echo "    Creating dedicated security group: ${GH_ACTIONS_SG_NAME}..."
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --region "${AWS_REGION}" \
    --group-name "${GH_ACTIONS_SG_NAME}" \
    --description "GitHub Actions runners - K8s API access via prefix lists" \
    --vpc-id "${VPC_ID}" \
    --query "GroupId" \
    --output text)
  echo "    Created: ${SECURITY_GROUP_ID}"
else
  echo "    Dedicated SG already exists: ${SECURITY_GROUP_ID}"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. Add inbound rules to the dedicated security group
#    Each prefix list = 1 SG rule, regardless of how many CIDRs it contains
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 5: Adding inbound rules to ${SECURITY_GROUP_ID}"

for pl_id in "${PREFIX_LIST_IDS[@]}"; do
  # Check if rule already exists
  EXISTING_RULE=$(aws ec2 describe-security-group-rules \
    --region "${AWS_REGION}" \
    --filters "Name=group-id,Values=${SECURITY_GROUP_ID}" \
    --query "SecurityGroupRules[?PrefixListId=='${pl_id}' && FromPort==\`${K8S_API_PORT}\`].SecurityGroupRuleId" \
    --output text 2>/dev/null || echo "")

  if [[ -n "${EXISTING_RULE}" ]]; then
    echo "    Rule for ${pl_id} already exists - skipping."
  else
    aws ec2 authorize-security-group-ingress \
      --region "${AWS_REGION}" \
      --group-id "${SECURITY_GROUP_ID}" \
      --ip-permissions "IpProtocol=tcp,FromPort=${K8S_API_PORT},ToPort=${K8S_API_PORT},PrefixListIds=[{PrefixListId=${pl_id},Description=github-actions-runners}]"
    echo "    Added rule: allow TCP ${K8S_API_PORT} from ${pl_id}"
  fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 6. Attach the dedicated SG to the master node (alongside existing SGs)
#    An EC2 instance can have up to 5 SGs. We ADD this one without removing
#    the existing ones.
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "==> Step 6: Attaching security group to master node ${MASTER_INSTANCE_ID}"

# Get all current security groups on the instance
CURRENT_SGS=$(aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${MASTER_INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].SecurityGroups[*].GroupId" \
  --output text)

echo "    Current SGs: ${CURRENT_SGS}"

# Check if already attached
if echo "${CURRENT_SGS}" | grep -q "${SECURITY_GROUP_ID}"; then
  echo "    ${SECURITY_GROUP_ID} is already attached - skipping."
else
  # Append our SG to the existing list
  ALL_SGS="${CURRENT_SGS} ${SECURITY_GROUP_ID}"
  aws ec2 modify-instance-attribute \
    --region "${AWS_REGION}" \
    --instance-id "${MASTER_INSTANCE_ID}" \
    --groups ${ALL_SGS}
  echo "    Attached ${SECURITY_GROUP_ID} to instance."
  echo "    Updated SGs: ${ALL_SGS}"
fi

# Cleanup
rm -rf "${TMPDIR}"

# ──────────────────────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "============================================================"
echo "  GitHub Actions IP Allowlist Setup Complete!"
echo "============================================================"
echo ""
echo "  Summary:"
echo "    - ${TOTAL_IPS} GitHub Actions IPv4 CIDRs fetched"
echo "    - ${#PREFIX_LIST_IDS[@]} managed prefix list(s) created/updated"
echo "    - Dedicated security group: ${SECURITY_GROUP_ID} (${GH_ACTIONS_SG_NAME})"
echo "    - Attached to master node: ${MASTER_INSTANCE_ID}"
echo ""
echo "  Prefix lists:"
for pl_id in "${PREFIX_LIST_IDS[@]}"; do
  echo "    - ${pl_id}"
done
echo ""
echo "  How it works:"
echo "    - Each prefix list holds up to ${MAX_ENTRIES_PER_LIST} CIDRs"
echo "    - Each prefix list = 1 security group rule"
echo "    - Dedicated SG avoids hitting rule limits on your main SG"
echo "    - EC2 instances can have up to 5 SGs attached simultaneously"
echo ""
echo "  ┌─────────────────────────────────────────────────────────┐"
echo "  │  IMPORTANT: GitHub updates IPs periodically.           │"
echo "  │  Re-run this script weekly to stay current.            │"
echo "  │                                                         │"
echo "  │  Automate with:                                         │"
echo "  │    - Cron job on any machine with AWS CLI               │"
echo "  │    - EventBridge + Lambda (serverless)                   │"
echo "  │    - GitHub Actions scheduled workflow (meta!)           │"
echo "  └─────────────────────────────────────────────────────────┘"
echo "============================================================"
