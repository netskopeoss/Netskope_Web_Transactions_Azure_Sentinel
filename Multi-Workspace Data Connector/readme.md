# Netskope Web Transaction — Multi-Workspace Sentinel Data Connector

Deploys the Netskope WebTx data connector to one or more Microsoft Sentinel workspaces, enabling ingestion of Web Transaction logs from Azure Blob Storage into the `NetskopeWebTransactions_CL` custom log table.

---

## Files

| File | Description |
|------|-------------|
| `netskope_webtx_single_workspace.json` | ARM template — deploys the Sentinel solution, content templates, data connector definition, DCR, and custom table to a single workspace. |
| `deploy_multi_workspace.ps1` | PowerShell script — deploys the ARM template to multiple workspaces sequentially with a configurable delay between each. |
| `Netskope_WebTx_Deployment_Guide.docx` | Full documentation — prerequisites, RBAC roles, deployment steps, connection configuration, and troubleshooting. |

---

## Quick Start

### Prerequisites

- PowerShell 7+ with `Az` module (`Az.Accounts`, `Az.Resources`)
- Authenticated to Azure: `Connect-AzAccount`
- Required RBAC roles (see [Roles](#required-rbac-roles) below)

### Deploy to Multiple Workspaces

```powershell
.\deploy_multi_workspace.ps1
```

The script prompts for:

1. Number of workspaces (1–10)
2. For each workspace: **Name**, **Resource Group**, and **Region**

Deployments run sequentially with a 60-second delay (configurable via `-DelaySeconds`).

```powershell
# Example with 90-second delay
.\deploy_multi_workspace.ps1 -DelaySeconds 90
```

### Deploy to a Single Workspace (Manual)

```powershell
$params = @{
    "location"           = "eastus"
    "workspace-location" = "eastus"
    "subscription"       = "<subscription-id>"
    "resourceGroupName"  = "rg-sentinel-prod"
    "workspace"          = "sentinel-prod-eastus"
}

New-AzResourceGroupDeployment `
    -Name "NetskopeWebTx-Deploy" `
    -ResourceGroupName "rg-sentinel-prod" `
    -TemplateFile "./netskope_webtx_single_workspace.json" `
    -TemplateParameterObject $params
```

---

## Post-Deployment: Configure the Connection

After the ARM template deploys, configure each connector in the Sentinel UI:

1. **Azure Portal** → Microsoft Sentinel → *your workspace* → Data connectors
2. Search for **NetskopeWebTxConnector** → Open connector page
3. Fill in the storage account details (Blob Container URI, folder, location, resource group, subscription)
4. Click **Connect**

### ⚠️ CRITICAL: One Connection at a Time

> **Do NOT configure multiple workspace connections simultaneously.**
>
> Complete the full connection for one workspace, verify data is flowing in `NetskopeWebTransactions_CL`, then proceed to the next. Parallel connections to the same storage account will cause EventGrid and queue provisioning failures.

### EventGrid System Topic (Shared Storage)

When multiple workspaces share the same storage account:

- **First workspace**: Leave the EventGrid System Topic Name field **empty** (auto-creates a topic). Note the topic name from Storage Account → Events.
- **Subsequent workspaces**: Enter the **exact topic name** from the first workspace. The connector reuses the topic and adds its own event subscription.

---

## Required RBAC Roles

### ARM Template Deployment

| Role | Scope |
|------|-------|
| Microsoft Sentinel Contributor | Workspace Resource Group |
| Log Analytics Contributor | Log Analytics Workspace |
| Monitoring Contributor | Workspace Resource Group |

### Connector Connection (Sentinel UI)

| Role | Scope |
|------|-------|
| Storage Blob Data Contributor | Storage Account / Container |
| Storage Queue Data Contributor | Storage Account |
| EventGrid EventSubscription Contributor | Storage Account |
| User Access Administrator **or** Owner | Storage Account |

---

## Multi-Workspace Resource Isolation

Each workspace creates dedicated resources on the shared storage account — no collisions:

| Resource | Naming Pattern |
|----------|---------------|
| Notification Queue | `netskopewebtx-{workspace}-notification` |
| Dead Letter Queue | `netskopewebtx-{workspace}-dlq` |
| EventGrid Subscription | `netskopewebtx-{workspace}-blobcreatedevents` |
| Data Collection Rule | `NetskopeWebTx-{workspace}` |
| EventGrid System Topic | Shared (one per storage account) |

---

## Data Flow

```
Netskope Tenant
    │
    ▼
Azure Blob Storage (CSV, gzip)
    │
    ├─── EventGrid BlobCreated ──► Queue: netskopewebtx-ws1-notification ──► Sentinel (Workspace 1)
    │                                                                              │
    │                                                                              ▼
    │                                                                     NetskopeWebTransactions_CL
    │
    ├─── EventGrid BlobCreated ──► Queue: netskopewebtx-ws2-notification ──► Sentinel (Workspace 2)
    │                                                                              │
    │                                                                              ▼
    │                                                                     NetskopeWebTransactions_CL
    ...
```

---

## Validation

After connecting, verify data ingestion with KQL:

```kusto
NetskopeWebTransactions_CL
| where TimeGenerated > ago(1h)
| summarize Count = count() by bin(TimeGenerated, 5m)
| order by TimeGenerated desc
```

Allow 10–15 minutes after connecting for initial data to appear.

---

## Troubleshooting

| Issue | Resolution |
|-------|------------|
| `content template $teastdelay... not found` | The original template had swapped `contentId`/`version` fields in `contentPackages` dependencies. Use the provided fixed template. |
| `ResourceDeploymentFailure` on nested deployment | Sentinel content resources cannot be deployed through nested ARM deployments. Always deploy the template directly to the resource group. |
| Queue already exists / EventGrid conflict | Another workspace was connected in parallel. Delete conflicting queues and EventGrid subscriptions, then reconnect one at a time. |
| `AuthorizationFailed` on storage resources | Ensure the identity has Storage Blob Data Contributor, Storage Queue Data Contributor, and User Access Administrator on the storage account. |
| No data in `NetskopeWebTransactions_CL` | Verify Netskope is writing to the container, the notification queue has messages, the DLQ is empty, and the DCR is configured. Allow 10–15 min. |
| Duplicate parameter binding error | The script uses `-TemplateParameterObject`. Do not also pass template parameters as individual cmdlet arguments. |

---

## Template Modifications from Original

Three changes were made to the original Netskope-provided ARM template for multi-workspace support:

1. **DCR name**: `NetskopeWebTx` → `concat('NetskopeWebTx-', parameters('workspace'))` — prevents collision in shared resource groups.
2. **connectorName**: `netskopewebtx` → `concat('netskopewebtx-', parameters('workspaceName'))` — ensures unique queues, DLQ, and EventGrid subscriptions per workspace.
3. **nestedDeploymentName**: `CreateDataFlowResources` → `concat('CreateDataFlowResources-', parameters('workspaceName'))` — prevents deployment name collision on shared storage.

Additionally, a **bug fix** was applied: the `contentPackages` resource had `contentId` and `version` values swapped in `dependencies.criteria`, causing `content template not found` errors during deployment.
