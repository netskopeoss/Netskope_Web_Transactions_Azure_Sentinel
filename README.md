# Netskope Web Transactions for Microsoft Sentinel

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Azure Sentinel](https://img.shields.io/badge/Microsoft-Sentinel-0078D4?logo=microsoft-azure)](https://azure.microsoft.com/en-us/services/microsoft-sentinel/)
[![Netskope](https://img.shields.io/badge/Netskope-Web%20Transactions-00A1E0)](https://www.netskope.com/)

This repository contains the Microsoft Sentinel solution for ingesting and analyzing Netskope Web Transaction logs. It provides a data connector for streaming web transaction data from Netskope to Azure Log Analytics and includes pre-built workbooks for comprehensive visibility into your organization's web traffic.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Deployment](#deployment)
  - [Deploy the Data Connector](#deploy-the-data-connector)
  - [Deploy the Workbook](#deploy-the-workbook)
- [Configuration](#configuration)
- [Data Schema](#data-schema)
- [Workbook Visualizations](#workbook-visualizations)
- [Sample Queries](#sample-queries)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

## Overview

Netskope Web Transactions provide detailed visibility into all web traffic flowing through the Netskope Security Cloud. This integration enables security teams to:

- Monitor and analyze web traffic patterns in Microsoft Sentinel
- Correlate Netskope web transaction data with other security data sources
- Build custom detection rules and hunting queries
- Create comprehensive dashboards for security operations

## Features

- **Real-time Data Ingestion**: Stream Netskope web transaction logs to Microsoft Sentinel via Azure Blob Storage
- **Pre-built Workbook**: Comprehensive dashboard with 20+ visualizations covering:
  - User activity analysis
  - Application and category usage
  - Geographic traffic analysis
  - HTTP status and methods
  - Client information (OS, Browser, Device)
  - Security insights (SSL errors, policy actions)
  - Data quality metrics (duplicate detection)
- **Custom Log Table**: Data stored in `NetskopeWebTransactions_CL` for easy querying
- **Time-based Filtering**: All visualizations support dynamic time range selection

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    Netskope     │────▶│  Azure Blob     │────▶│   Event Grid   │────▶│  Microsoft      │
│  Security Cloud │     │    Storage      │     │  + Storage     │     │   Sentinel      │
│                 │     │                 │     │    Queue       │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘     └─────────────────┘
                                                                                 │
                                                                                 ▼
                                                                        ┌─────────────────┐
                                                                        │  Log Analytics  │
                                                                        │    Workspace    │
                                                                        │ (NetskopeWeb    │
                                                                        │ Transactions_CL)│
                                                                        └─────────────────┘
```

## Prerequisites

Before deploying this solution, ensure you have:

- **Microsoft Azure Subscription** with the following resources:
  - Microsoft Sentinel enabled on a Log Analytics workspace
  - Azure Storage Account for blob storage
  - Permissions to create Event Grid subscriptions and Storage Queues

- **Netskope Tenant** with:
  - Web Transaction logging enabled
  - Configured export to Azure Blob Storage
  - API access for log streaming

- **Required Permissions**:
  - `Microsoft.OperationalInsights/workspaces` - Read/Write
  - `Microsoft.Storage/storageAccounts` - Read/Write
  - `Microsoft.EventGrid/systemTopics` - Read/Write
  - `Microsoft.SecurityInsights/dataConnectors` - Read/Write

## Deployment

### Deploy the Data Connector

#### Option 1: Azure Portal (One-Click Deploy)

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fnetskopeoss%2FNetskope_Web_Transactions_Azure_Sentinel%2Fmain%2Fdata-connector%2Fazuredeploy.json)

#### Option 2: Azure CLI

```bash
# Clone the repository
git clone https://github.com/netskopeoss/Netskope_Web_Transactions_Azure_Sentinel.git
cd Netskope_Web_Transactions_Azure_Sentinel

# Deploy the ARM template
az deployment group create \
  --resource-group <your-resource-group> \
  --template-file data-connector/azuredeploy.json \
  --parameters workspace=<your-workspace-name>
```

#### Option 3: PowerShell

```powershell
# Deploy using PowerShell
New-AzResourceGroupDeployment `
  -ResourceGroupName "<your-resource-group>" `
  -TemplateFile "data-connector/azuredeploy.json" `
  -workspace "<your-workspace-name>"
```

### Deploy the Workbook

1. Navigate to **Microsoft Sentinel** → **Workbooks** → **Add workbook**
2. Click **Edit** in the top toolbar
3. Click the **Advanced Editor** (`</>`) button in the top toolbar
4. Delete all existing content
5. Paste the contents of [`workbook/NetskopeWebTx_Workbook.json`](workbook/NetskopeWebTx_Workbook.json)
6. Click **Apply**
7. Click **Done Editing** → **Save**
8. Provide a name and select the appropriate resource group

## Configuration

### Netskope Configuration

1. Log in to your Netskope tenant admin console
2. Navigate to **Settings** → **Tools** → **Event Streaming**
3. Configure Azure Blob Storage as the destination:
   - **Storage Account Name**: Your Azure storage account
   - **Container Name**: Container for web transaction logs
   - **SAS Token**: Generate with appropriate permissions
4. Enable **Web Transaction** log streaming

### Azure Storage Configuration

1. Create a blob container for Netskope logs
2. Configure lifecycle management (optional) for log retention
3. Note the container URL for the data connector configuration

### Data Connector Configuration

When configuring the data connector in Sentinel, provide:

| Parameter | Description |
|-----------|-------------|
| Blob Container URI | Full URL to your blob container |
| Blob Folder Name | Optional subfolder path |
| Storage Account Location | Azure region of storage account |
| Storage Account Resource Group | Resource group name |
| Storage Account Subscription | Subscription ID |
| Event Grid Topic Name | Existing topic name (leave empty to create new) |

## Data Schema

The `NetskopeWebTransactions_CL` table contains the following key fields:

### User & Session Information
| Column | Type | Description |
|--------|------|-------------|
| `CsUsername` | string | Username of the client |
| `CIp` | string | Client IP address |
| `XCsSessionId` | string | Session identifier |
| `XCsAccessMethod` | string | Access method (Client, API Connector, etc.) |

### Request Details
| Column | Type | Description |
|--------|------|-------------|
| `CsMethod` | string | HTTP method (GET, POST, etc.) |
| `CsHost` | string | Destination hostname |
| `CsUri` | string | Request URI |
| `CsUriScheme` | string | URI scheme (http/https) |
| `ScStatus` | int | HTTP response status code |

### Application & Category
| Column | Type | Description |
|--------|------|-------------|
| `XCsApp` | string | Application name |
| `XCategory` | string | Web category |
| `XCsAppCategory` | string | Application category |

### Geographic Data
| Column | Type | Description |
|--------|------|-------------|
| `XCCountry` | string | Client country |
| `XCLocation` | string | Client location |
| `XSCountry` | string | Server country |
| `XSLocation` | string | Server location |

### Client Information
| Column | Type | Description |
|--------|------|-------------|
| `XCOs` | string | Client operating system |
| `XCBrowser` | string | Client browser |
| `XCDevice` | string | Device type |

### Security & Policy
| Column | Type | Description |
|--------|------|-------------|
| `XPolicyAction` | string | Policy action taken |
| `XPolicyName` | string | Policy name |
| `XServerSslErr` | string | Server SSL error |
| `XClientSslErr` | string | Client SSL error |
| `XSslBypass` | string | SSL bypass indicator |
| `XSslBypassReason` | string | Reason for SSL bypass |

### Data Transfer
| Column | Type | Description |
|--------|------|-------------|
| `Bytes` | int | Total bytes transferred |
| `CsBytes` | int | Client to server bytes |
| `ScBytes` | int | Server to client bytes |

## Workbook Visualizations

The included workbook provides the following sections:

| Section | Visualizations |
|---------|----------------|
| **User Activity** | Top 20 Active Users, Top 10 Users (Pie Chart) |
| **Applications & Categories** | Top 20 Applications, Top 20 Web Categories, Distribution Charts |
| **Geographic Analysis** | Traffic by Source/Destination Country, Top Locations |
| **HTTP Status & Methods** | Status Codes, Methods Distribution, Errors Over Time |
| **Client Information** | OS, Browser, and Device Distribution |
| **Security Insights** | Traffic Types, Policy Actions |
| **Top Destinations** | Top 25 Hosts, Hosts by Data Volume |
| **Access Methods** | Access Methods, URI Schemes (HTTP vs HTTPS) |
| **Transaction Logs** | Detailed searchable log table (Last 500) |
| **SSL Errors & Bypass** | Server/Client SSL Errors, SSL Bypass Events |
| **Data Quality** | Duplicate Transaction Percentage Analysis |

## Sample Queries

### Top Users by Transaction Volume
```kusto
NetskopeWebTransactions_CL
| where TimeGenerated > ago(24h)
| where isnotempty(CsUsername) and CsUsername != "-"
| summarize Transactions = count() by User = CsUsername
| order by Transactions desc
| take 10
```

### Applications with Most Data Transfer
```kusto
NetskopeWebTransactions_CL
| where TimeGenerated > ago(24h)
| where isnotempty(XCsApp) and XCsApp != "-"
| summarize TotalBytes = sum(Bytes) by Application = XCsApp
| order by TotalBytes desc
| take 10
```

### HTTP Errors by Status Code
```kusto
NetskopeWebTransactions_CL
| where TimeGenerated > ago(24h)
| where ScStatus >= 400
| summarize Count = count() by StatusCode = ScStatus
| order by Count desc
```

### SSL Bypass Events
```kusto
NetskopeWebTransactions_CL
| where TimeGenerated > ago(7d)
| where XSslBypass == "yes"
| summarize Count = count() by BypassReason = XSslBypassReason, Host = CsHost
| order by Count desc
```

### Duplicate Transaction Analysis
```kusto
let filtered = NetskopeWebTransactions_CL 
| where TimeGenerated > ago(24h) 
| where isnotempty(XTransactionId);
let total_rows = filtered | summarize total = count();
let duplicate_rows = filtered 
| summarize c = count() by XTransactionId 
| where c > 1 
| summarize duplicates = sum(c - 1);
print 
    TotalRecords = toscalar(total_rows),
    DuplicateRecords = toscalar(duplicate_rows),
    DuplicatePercentage = round(100.0 * toscalar(duplicate_rows) / toscalar(total_rows), 2)
```

## Troubleshooting

### No Data in Log Analytics

1. **Verify Netskope Configuration**
   - Ensure web transaction logging is enabled
   - Confirm Azure Blob Storage export is configured correctly
   - Check SAS token permissions and expiration

2. **Check Azure Storage**
   - Verify blobs are being written to the container
   - Confirm Event Grid subscription is active
   - Check Storage Queue for messages

3. **Validate Data Connector**
   - Review connector status in Sentinel → Data Connectors
   - Check Data Collection Rule configuration
   - Verify service principal permissions

### Query Errors in Workbook

- Ensure the `NetskopeWebTransactions_CL` table exists
- Verify data is being ingested (run `NetskopeWebTransactions_CL | take 10`)
- Check time range filter - ensure data exists for selected period

### Missing Columns

If certain columns show no data:
- Some fields may be empty depending on Netskope configuration
- SSL-related fields only populate when SSL inspection is enabled
- Policy fields require Real-time Protection policies to be configured

## Contributing

We welcome contributions! Please follow these steps:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

Please ensure your PR:
- Follows existing code style
- Includes appropriate documentation updates
- Has been tested in a development environment

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- **Issues**: Please open a [GitHub Issue](https://github.com/netskopeoss/Netskope_Web_Transactions_Azure_Sentinel/issues) for bugs or feature requests
- **Netskope Documentation**: [Netskope Knowledge Portal](https://docs.netskope.com/)
- **Microsoft Sentinel Documentation**: [Microsoft Sentinel Docs](https://docs.microsoft.com/en-us/azure/sentinel/)

---

**Disclaimer**: This is an open-source project maintained by Netskope. It is not officially supported by Microsoft or Netskope support teams.
