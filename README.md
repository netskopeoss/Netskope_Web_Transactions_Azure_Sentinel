# Netskope Web Transactions Integration for Microsoft Sentinel

[![Azure](https://img.shields.io/badge/Azure-Sentinel-0078D4?logo=microsoftazure)](https://azure.microsoft.com/services/microsoft-sentinel/)
[![Netskope](https://img.shields.io/badge/Netskope-Web%20Transactions-00A4EF)](https://www.netskope.com/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Stream Netskope Web Transaction logs into Microsoft Sentinel using the Codeless Connector Framework (CCF) for comprehensive cloud security visibility, threat detection, and incident response.

---

## 📋 Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Repository Contents](#repository-contents)
- [Deployment Guide](#deployment-guide)
  - [Step 1: Deploy the Data Connector](#step-1-deploy-the-data-connector)
  - [Step 2: Configure the Connector](#step-2-configure-the-connector)
  - [Step 3: Deploy the Workbook](#step-3-deploy-the-workbook)
  - [Step 4: Deploy Analytics Rules](#step-4-deploy-analytics-rules)
- [Configuration Parameters](#configuration-parameters)
- [Analytics Rules](#analytics-rules)
- [Workbook Features](#workbook-features)
- [Troubleshooting](#troubleshooting)
- [Minimum Required Permissions](#minimum-required-permissions)
- [Contributing](#contributing)
- [References](#references)

---

## Overview

This solution provides a native integration between Netskope and Microsoft Sentinel, enabling organizations to:

- **Stream Web Transaction logs** in near real-time to Log Analytics
- **Visualize traffic patterns** with pre-built workbooks
- **Detect threats** using 10 pre-configured analytics rules
- **Investigate incidents** with full context from Netskope data

The integration leverages Azure's Codeless Connector Platform (CCP), eliminating the need for custom code or additional infrastructure.

---

## Architecture

```
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│                 │     │    Azure Storage     │     │    Event Grid   │
│    Netskope     │────▶│   Blob Container     │────▶│   System Topic  │
│   Log Streaming │     │  (Web Transactions)  │     │                 │
└─────────────────┘     └──────────────────────┘     └────────┬────────┘
                                                              │
                                                              ▼
┌─────────────────┐     ┌──────────────────────┐     ┌─────────────────┐
│   Microsoft     │◀────│  Data Collection     │◀────│  Storage Queue  │
│   Sentinel      │     │  Rule (DCR)          │     │  (Notifications)│
│                 │     │                      │     │                 │
└─────────────────┘     └──────────────────────┘     └─────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    NetskopeWebTransactions_CL                        │
│                    (Log Analytics Custom Table)                      │
└─────────────────────────────────────────────────────────────────────┘
```

**Data Flow:**
1. Netskope pushes Web Transaction logs to your Azure Blob Container
2. Blob creation triggers an Event Grid notification
3. Event Grid sends the blob URI to a Storage Queue
4. Microsoft Sentinel's CCP connector (Scuba workers) polls the queue
5. Data is ingested via Data Collection Rules into Log Analytics
6. Logs appear in the `NetskopeWebTransactions_CL` table

---

## Prerequisites

Before deploying this solution, ensure you have:

| Requirement | Description |
|-------------|-------------|
| **Azure Subscription** | Active Azure subscription with appropriate permissions |
| **Microsoft Sentinel** | Sentinel-enabled Log Analytics workspace |
| **Netskope Tenant** | Active Netskope tenant with Log Streaming configured |
| **Azure Storage Account** | Blob container receiving Netskope logs |
| **Service Principal** | Enterprise Application with Storage permissions |
| **Azure Role** | Minimum: Contributor on Resource Group (see [Custom Role](#minimum-required-permissions)) |

### Netskope Configuration

Ensure your Netskope tenant is configured for Log Streaming to Azure Blob Storage:
1. Navigate to **Settings** → **Tools** → **Log Streaming**
2. Configure Azure Blob Storage as the destination
3. Enable **Web Transactions** (Transaction_1 folder)

---

## Repository Contents

```
├── README.md                                    # This file
├── netskope_webtx_log_streaming.json           # Data Connector ARM Template
├── NetskopeWebTx_Workbook_Updated.json         # Sentinel Workbook
├── Netskope_Analytics_Rules_Template_v4.json   # Analytics Rules (10 rules)
└── CustomRole.json                              # Minimum required Azure role
```

| File | Purpose |
|------|---------|
| `netskope_webtx_log_streaming.json` | Deploys the CCP-based data connector |
| `NetskopeWebTx_Workbook_Updated.json` | Visualization workbook for web traffic analysis |
| `Netskope_Analytics_Rules_Template_v4.json` | Pre-built detection rules for security monitoring |

---

## Deployment Guide

### Step 1: Deploy the Data Connector

1. Navigate to the [Azure Portal](https://portal.azure.com)

2. Go to **Deploy a custom template** → **Build your own template in the editor**

3. Paste the contents of `netskope_webtx_log_streaming.json`

4. Click **Save**, then fill in the required parameters:

   | Parameter | Description |
   |-----------|-------------|
   | **Subscription** | Your Azure subscription |
   | **Resource Group** | Resource group containing your Sentinel workspace |
   | **Workspace** | Name of your Log Analytics workspace |
   | **Workspace Location** | Region of your workspace |

5. Click **Review + Create** → **Create**

### Step 2: Configure the Connector

1. Navigate to **Microsoft Sentinel** → **Data Connectors**

2. Find and select **NetskopeWebTxConnector**

3. Click **Open connector page**

4. Fill in the configuration parameters:

   | Parameter | Description | How to Find |
   |-----------|-------------|-------------|
   | **Service Principal ID** | Object ID of your Enterprise Application | Azure AD → Enterprise Applications → Copy Object ID |
   | **Blob Container URL** | Full URL to your Netskope blob container | Storage Account → Containers → Properties |
   | **Folder Name** | `Transaction_1` (for Web Transactions) | Netskope log folder name |
   | **Storage Account Location** | Region of storage account | Storage Account → Overview |
   | **Resource Group Name** | Storage account's resource group | Storage Account → Overview |
   | **Subscription ID** | Storage account's subscription | Storage Account → Overview |
   | **Event Grid Topic Name** | System topic name (leave blank if none) | Storage Account → Events |

5. Click **Connect**

6. Data will begin flowing within **~20 minutes**

### Step 3: Deploy the Workbook

1. Navigate to **Microsoft Sentinel** → **Workbooks**

2. Click **+ Add workbook**

3. Click **Edit** → **Advanced Editor** (</> icon)

4. Replace the content with `NetskopeWebTx_Workbook_Updated.json`

5. Click **Apply** → **Done Editing** → **Save**

6. Name it: `Netskope Web Transactions Dashboard`

### Step 4: Deploy Analytics Rules

1. Navigate to **Deploy a custom template** in Azure Portal

2. Select **Build your own template in the editor**

3. Paste the contents of `Netskope_Analytics_Rules_Template_v4.json`

4. Fill in the parameters:

   | Parameter | Description |
   |-----------|-------------|
   | **Workspace Name** | Your Log Analytics workspace name |
   | **Location** | Region of your workspace |

5. Click **Review + Create** → **Create**

---

## Configuration Parameters

### Retrieving Configuration Values

#### Service Principal ID
```
Azure Portal → Azure Active Directory → Enterprise Applications 
→ Select your app → Overview → Copy "Object ID"
```

#### Blob Container URL
```
Azure Portal → Storage Account → Containers → [Your Container] 
→ Properties → Copy URL
Example: https://mystorageaccount.blob.core.windows.net/netskope
```

#### Event Grid System Topic
```
Azure Portal → Storage Account → Events 
→ Copy the System Topic name (if exists)
```

---

## Analytics Rules

This solution includes **10 pre-configured analytics rules**:

| Rule | Severity | Description | MITRE Tactics |
|------|----------|-------------|---------------|
| **Impossible Travel Detection** | High | User access from 2+ countries within 1 hour | Initial Access, Credential Access |
| **Excessive Downloads** | Medium | Download volume exceeds 3x baseline | Exfiltration, Collection |
| **Unsanctioned/Risky Apps** | Medium | Access to apps with poor CCL or "Unsanctioned" tag | Initial Access, Exfiltration |
| **New Risky App vs Baseline** | Medium | First-time access to risky apps | Initial Access, Discovery |
| **Large Data Upload (DLP)** | High | Uploads exceeding 100MB threshold | Exfiltration |
| **Policy Violations** | High | Repeated policy blocks or alerts | Defense Evasion, Exfiltration |
| **Anomalous User Behavior** | Medium | High volume from unmanaged devices | Exfiltration, Collection |
| **Personal Cloud Storage** | Medium | Heavy usage of personal cloud apps | Exfiltration, Collection |
| **Network Context Anomaly** | Medium | Suspicious IPs, ports, or geo locations | Command & Control, Exfiltration |
| **Data Movement Tracking** | Informational | Tracks upload/download patterns | Exfiltration, Collection |

---

## Workbook Features

The **Netskope Web Transactions Dashboard** provides:

### 📊 Visualizations

| Section | Metrics |
|---------|---------|
| **User Activity** | Top 20 users, transaction counts, unique apps/hosts |
| **Applications & Categories** | Top apps, web categories, distribution charts |
| **Geographic Analysis** | Traffic by source/destination country |
| **Traffic Trends** | Time-series analysis of transaction volume |
| **Security Insights** | Policy actions, blocked traffic, risk levels |
| **SSL Analysis** | SSL errors, bypass events, certificate issues |
| **Data Transfer** | Upload/download volumes, top hosts by data |
| **Data Quality** | Duplicate transaction analysis |

### ⏱️ Time Range Support
- 1 Hour, 4 Hours, 12 Hours, 24 Hours
- 2 Days, 7 Days, 30 Days
- Custom range

---

## Troubleshooting

### Pre-Deployment Checklist

- [ ] Create a "clean room" environment (new resource group with minimal resources)
- [ ] Enable diagnostic logs on the Sentinel workspace **before deployment**
- [ ] Deploy only ONE connector template per workspace

### Common Issues

| Issue | Solution |
|-------|----------|
| **No data flowing** | Wait 20 minutes; check Event Grid metrics for Published/Delivered events |
| **Connector shows disconnected** | Verify Service Principal has `Storage Queue Data Contributor` role |
| **Missing events** | Check blob folder name matches `Transaction_1` |
| **DCR errors** | Verify data format (CSV, space-delimited, gzipped) |

### Validation Steps

1. **Check Event Grid metrics:**
   ```
   Storage Account → Events → Metrics 
   → Look for "Published Events" and "Delivered Events"
   ```

2. **Check Storage Queue:**
   ```
   Storage Account → Queues → {connector-name}-notification
   → Messages should appear and disappear (picked up by connector)
   ```

3. **Check DCR metrics:**
   ```
   Data Collection Rule → Metrics → "Log Ingestion Requests per minute"
   ```

4. **Query the table:**
   ```kql
   NetskopeWebTransactions_CL
   | take 10
   ```

5. **Check Sentinel Health:**
   ```kql
   SentinelHealth
   | where TimeGenerated > ago(1h)
   | where SentinelResourceType == "Data connector"
   ```

---

## Minimum Required Permissions

Use the custom role definition in `CustomRole.json` for least-privilege deployment:

```json
{
  "Name": "Netskope Sentinel Connector Deployer",
  "Description": "Minimum permissions for Netskope Sentinel connector deployment",
  "Actions": [
    "Microsoft.OperationalInsights/workspaces/read",
    "Microsoft.OperationalInsights/workspaces/write",
    "Microsoft.SecurityInsights/*/read",
    "Microsoft.SecurityInsights/*/write",
    "Microsoft.Storage/storageAccounts/read",
    "Microsoft.Storage/storageAccounts/queueServices/queues/*",
    "Microsoft.EventGrid/systemTopics/*",
    "Microsoft.EventGrid/eventSubscriptions/*"
  ],
  "AssignableScopes": ["/subscriptions/{subscription-id}"]
}
```

### Service Principal Requirements

The Service Principal (Enterprise Application) needs:
- **Storage Queue Data Contributor** on the Storage Account queues

---

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/improvement`)
3. Commit changes (`git commit -am 'Add new feature'`)
4. Push to branch (`git push origin feature/improvement`)
5. Open a Pull Request

---

## References

- [Netskope Community - Integration Guide](https://community.netskope.com/discussions-37/integration-web-transactions-from-netskope-log-streaming-to-microsoft-sentinel-7646)
- [Microsoft Sentinel Documentation](https://docs.microsoft.com/azure/sentinel/)
- [Netskope Log Streaming Documentation](https://docs.netskope.com/)
- [Azure Codeless Connector Platform](https://docs.microsoft.com/azure/sentinel/create-codeless-connector)

---

## Support

| Resource | Link |
|----------|------|
| **Netskope Community** | [community.netskope.com](https://community.netskope.com) |
| **Microsoft Sentinel** | [Azure Support](https://azure.microsoft.com/support/) |
| **Issues** | [GitHub Issues](../../issues) |

---

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<p align="center">
  <b>Built for security teams by security teams</b><br>
  <sub>Netskope + Microsoft Sentinel Integration</sub>
</p>
