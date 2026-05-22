#!/usr/bin/env bash
#
# create-netskope-webtx-sp.sh
# ---------------------------
# Creates the Microsoft Sentinel "Scuba" connector Service Principal for the
# Netskope WebTx CCF connector in your Entra tenant, and (optionally) assigns
# the two storage roles the connector requires.
#
# App ID (fixed, from the connector template):
#     7d0820ba-0cff-4e11-98d0-952dcbed1fe1
#
# Target cloud: Azure US Government (login.microsoftonline.us / *.usgovcloudapi.net).
# For commercial Azure, change AZURE_CLOUD to "AzureCloud".
#
# Requires: Azure CLI. Sign-in account must hold Application Administrator,
# Cloud Application Administrator, or Global Administrator in Entra ID; and
# Owner / User Access Administrator on the storage account if you let this
# script do the role assignments.
#
# Usage (create SP only):
#   ./create-netskope-webtx-sp.sh --tenant-id <tenant-guid>
#
# Usage (create SP and assign storage roles):
#   ./create-netskope-webtx-sp.sh \
#       --tenant-id        <tenant-guid> \
#       --subscription     <subscription-id> \
#       --storage-account  <storage-account-name> \
#       --resource-group   <storage-account-rg> \
#       --container        <blob-container-name>
#
set -euo pipefail

APP_ID="7d0820ba-0cff-4e11-98d0-952dcbed1fe1"
AZURE_CLOUD="AzureUSGovernment"     # commercial: "AzureCloud"

TENANT_ID=""
SUBSCRIPTION=""
STORAGE_ACCOUNT=""
RESOURCE_GROUP=""
CONTAINER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id)        TENANT_ID="$2";       shift 2 ;;
    --subscription)     SUBSCRIPTION="$2";    shift 2 ;;
    --storage-account)  STORAGE_ACCOUNT="$2"; shift 2 ;;
    --resource-group)   RESOURCE_GROUP="$2";  shift 2 ;;
    --container)        CONTAINER="$2";       shift 2 ;;
    -h|--help)          sed -n '2,33p' "$0";  exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$TENANT_ID" ]]; then
  echo "ERROR: --tenant-id is required. Run with --help for usage." >&2
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }

echo "==> Cloud:  $AZURE_CLOUD"
echo "==> Tenant: $TENANT_ID"
echo "==> App ID: $APP_ID"
echo

# ---- ensure CLI is on the right cloud ----
CURRENT_CLOUD=$(az cloud show --query name -o tsv 2>/dev/null || echo "")
if [[ "$CURRENT_CLOUD" != "$AZURE_CLOUD" ]]; then
  echo "==> Switching CLI cloud to $AZURE_CLOUD"
  az cloud set --name "$AZURE_CLOUD"
fi

# ---- ensure signed in to the right tenant ----
CURRENT_TENANT=$(az account show --query tenantId -o tsv 2>/dev/null || echo "")
if [[ "$CURRENT_TENANT" != "$TENANT_ID" ]]; then
  echo "==> Signing in to tenant $TENANT_ID"
  az login --tenant "$TENANT_ID" >/dev/null
fi

# ---- [1/2] create the Service Principal (idempotent) ----
echo
echo "==> [1/2] Ensuring Service Principal for app $APP_ID exists..."
SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)

if [[ -z "$SP_OBJECT_ID" ]]; then
  echo "    Not found in tenant. Creating it..."
  az ad sp create --id "$APP_ID" >/dev/null
  for i in 1 2 3 4 5 6; do
    sleep 5
    SP_OBJECT_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null || true)
    [[ -n "$SP_OBJECT_ID" ]] && break
  done
else
  echo "    Already exists."
fi

if [[ -z "$SP_OBJECT_ID" ]]; then
  echo "ERROR: SP did not appear after creation. Check that your account has Application Administrator." >&2
  exit 1
fi
echo "    Service Principal Object ID: $SP_OBJECT_ID"

# ---- [2/2] optional role assignment ----
if [[ -n "$SUBSCRIPTION" && -n "$STORAGE_ACCOUNT" && -n "$RESOURCE_GROUP" && -n "$CONTAINER" ]]; then
  az account set --subscription "$SUBSCRIPTION"
  SA_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"
  CONTAINER_SCOPE="${SA_ID}/blobServices/default/containers/${CONTAINER}"

  assign () {
    local role="$1" scope="$2"
    echo
    echo "==> Assigning '$role'"
    echo "    scope: $scope"
    if az role assignment list --assignee "$SP_OBJECT_ID" --scope "$scope" --role "$role" \
         --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
      echo "    Already assigned."
    else
      az role assignment create --assignee-object-id "$SP_OBJECT_ID" \
        --assignee-principal-type ServicePrincipal --role "$role" --scope "$scope" >/dev/null
      echo "    Done."
    fi
  }

  echo
  echo "==> [2/2] Assigning storage roles..."
  assign "Storage Blob Data Contributor"  "$CONTAINER_SCOPE"
  assign "Storage Queue Data Contributor" "$SA_ID"
else
  echo
  echo "==> [2/2] Skipping role assignment (storage args not supplied)."
  echo "    Assign these two roles to Object ID $SP_OBJECT_ID before clicking Connect:"
  echo "      - Storage Blob Data Contributor  (on the blob container)"
  echo "      - Storage Queue Data Contributor (on the storage account)"
fi

echo
echo "===================================================================="
echo "On the NetskopeWebTxConnector page, the Service Principal ID field"
echo "should show: $SP_OBJECT_ID"
echo "===================================================================="
