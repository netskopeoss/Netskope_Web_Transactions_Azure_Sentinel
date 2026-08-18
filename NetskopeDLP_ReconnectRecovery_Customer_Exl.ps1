<#
    .SYNOPSIS
    Recovers a Netskope Alerts & Events (CCF) connector that fails to reconnect
    with "Invalid output table schema ... columns which exist in the current
    schema do not exist in the new schema", caused by custom columns added to
    NetskopeEventsDLP_CL (by DCRChangesEXL.ps1) that the packaged connector
    schema does not declare.

    The recovery is a three-phase runbook. Phases 1 and 3 are this script;
    phase 2 (reconnect) is manual in the Sentinel UI.

      Phase 1  (-Phase Revert)
        1a. Backs up the current NetskopeEventsDLP_CL table schema and any
            Netskope DCR pointing at the workspace to ./backup_<timestamp>/.
        1b. Reverts NetskopeEventsDLP_CL to the packaged 49-column schema
            (removes the 12 custom columns).
        1c. Deletes any leftover connector-created Netskope alerts/events DCR
            targeting this workspace (name pattern
            Microsoft-Sentinel-Netskope_DCR-<ws-guid-prefix>), after confirmation.

      Phase 2  (manual)
        Reconnect the "Netskope Alerts and Events" connector in the
        Microsoft Sentinel UI. The connector recreates its DCR and validates
        tables; with the packaged schema restored this succeeds.

      Phase 3  (-Phase Reapply)
        3a. Verifies the connector's DCR exists and data is landing.
        3b. Re-adds the 12 custom columns to the table.
        3c. Re-adds the 11 raw fields to the DCR's Custom-NetskopeEventsDLP
            stream declaration.
        3d. FIX over DCRChangesEXL.ps1: also patches transformKql to derive
            endpoint_policy_match_desired_action =
            tostring(endpoint_policy_match.desired_action), which the original
            script documented but never implemented.

    .EXAMPLE
    ./NetskopeDLP_ReconnectRecovery.ps1 -Phase Revert
    # ... reconnect connector in Sentinel UI, confirm data flows ...
    ./NetskopeDLP_ReconnectRecovery.ps1 -Phase Reapply

    .NOTES
    - Requires Azure CLI (az) logged in with rights on the workspace tables
      and the resource group's DCRs.
    - Table column removal does not delete ingested data, but removed columns
      are not queryable until re-added. Re-adding the same name/type in Phase 3
      is expected to restore access to previously ingested values; verify on a
      known record after Phase 3 (this behavior was not re-verified against
      current Azure docs).
    - IMPORTANT OPERATIONAL RULE captured by this incident: table- or
      DCR-level customizations on a CCF connector MUST be reverted (Phase 1)
      before any disconnect/reconnect, then re-applied (Phase 3) after.
#>

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Revert", "Reapply", "Status")]
    [string]$Phase,

    # If set, Phase Revert leaves the existing Netskope DCR in place (no delete).
    # Try this first if you want zero deletions: the reconnect may overwrite the
    # DCR on its own. If reconnect still fails after a table-only revert,
    # re-run Phase Revert WITHOUT this switch to also remove the DCR.
    [switch]$SkipDcrDelete
)

# --- CONFIGURATION (fill in the customer's values before running) ---
$subscriptionId    = ""   # customer subscription ID
$resourceGroupName = ""   # resource group containing the workspace and DCR
$workspaceName     = ""   # Log Analytics workspace name (NOT the GUID)
$tableName         = "NetskopeEventsDLP_CL"
$streamName        = "Custom-NetskopeEventsDLP"

# --- PACKAGED SCHEMA (source of truth: Azure-Sentinel repo master,
#     Solutions/Netskopev2/Data Connectors/NetskopeAlertsEvents_RestAPI_CCP/
#     NetskopeEventsDLP_Table.json, 49 columns, verified 2026-08-18) ---
$packagedColumns = @(
    @{ name = "TimeGenerated";             type = "datetime" }
    @{ name = "title_s";                   type = "string"   }
    @{ name = "object";                    type = "string"   }
    @{ name = "app";                       type = "string"   }
    @{ name = "site";                      type = "string"   }
    @{ name = "status";                    type = "string"   }
    @{ name = "assignee";                  type = "string"   }
    @{ name = "severity";                  type = "string"   }
    @{ name = "instance_id";               type = "string"   }
    @{ name = "timestamp";                 type = "int"      }
    @{ name = "exposure";                  type = "string"   }
    @{ name = "acting_user";               type = "string"   }
    @{ name = "user";                      type = "string"   }
    @{ name = "file_path";                 type = "string"   }
    @{ name = "file_size";                 type = "int"      }
    @{ name = "file_type";                 type = "string"   }
    @{ name = "dlp_match_info";            type = "dynamic"  }
    @{ name = "inline_dlp_match_info";     type = "dynamic"  }
    @{ name = "access_method";             type = "string"   }
    @{ name = "activity";                  type = "string"   }
    @{ name = "instance";                  type = "string"   }
    @{ name = "url";                       type = "string"   }
    @{ name = "object_type";               type = "string"   }
    @{ name = "owner";                     type = "string"   }
    @{ name = "owner_pdl";                 type = "string"   }
    @{ name = "file_lang";                 type = "string"   }
    @{ name = "true_obj_category";         type = "string"   }
    @{ name = "true_obj_type";             type = "string"   }
    @{ name = "dlp_incidentid";            type = "string"   }
    @{ name = "latest_incidentid";         type = "string"   }
    @{ name = "dlp_parentid";              type = "string"   }
    @{ name = "from_user";                 type = "string"   }
    @{ name = "md5";                       type = "string"   }
    @{ name = "connectionid";              type = "string"   }
    @{ name = "app_sessionid";             type = "string"   }
    @{ name = "referer";                   type = "string"   }
    @{ name = "dst_location";              type = "string"   }
    @{ name = "src_location";              type = "string"   }
    @{ name = "channel";                   type = "string"   }
    @{ name = "to_user";                   type = "string"   }
    @{ name = "cc";                        type = "string"   }
    @{ name = "bcc";                       type = "string"   }
    @{ name = "classification";            type = "string"   }
    @{ name = "user_id";                   type = "string"   }
    @{ name = "destination_app";           type = "string"   }
    @{ name = "destination_instance_id";   type = "string"   }
    @{ name = "zip_file_id";               type = "string"   }
    @{ name = "original_file_snapshot_id"; type = "string"   }
    @{ name = "dlp_file";                  type = "string"   }
)

# --- CUSTOM FIELDS (same set as DCRChangesEXL.ps1) ---
# Added to BOTH table and DCR stream in Phase 3:
$customRawFields = @(
    @{ name = "shared_with";           type = "string"  }
    @{ name = "object_id";             type = "string"  }
    @{ name = "modified";              type = "int"     }
    @{ name = "created";               type = "int"     }
    @{ name = "record_type";           type = "string"  }
    @{ name = "device";                type = "string"  }
    @{ name = "usb_device";            type = "string"  }
    @{ name = "justification";         type = "string"  }
    @{ name = "destination_site";      type = "string"  }
    @{ name = "ext_labels";            type = "dynamic" }
    @{ name = "endpoint_policy_match"; type = "dynamic" }
)
# Added to the TABLE only; populated via transformKql (Phase 3d):
$customDerivedFields = @(
    @{ name = "endpoint_policy_match_desired_action"; type = "string" }
)
$allCustomNames = @($customRawFields + $customDerivedFields | ForEach-Object { $_.name })

# transformKql clause appended in Phase 3d (idempotent - checked before adding):
$derivedExtend = "extend endpoint_policy_match_desired_action = tostring(endpoint_policy_match.desired_action)"

# --- COMMON ---
$mgmt      = "https://management.azure.com"
$tableUrl  = "$mgmt/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/tables/$($tableName)?api-version=2022-10-01"
$dcrListUrl= "$mgmt/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Insights/dataCollectionRules?api-version=2022-06-01"
$wsResId   = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"

function Get-NetskopeDcrsForWorkspace {
    $all = (az rest --method get --url $dcrListUrl | ConvertFrom-Json).value
    @($all | Where-Object {
        ($_.name -like "Microsoft-Sentinel-Netskope_DCR-*") -and
        ($_.properties.destinations.logAnalytics.workspaceResourceId -ieq $wsResId)
    })
}

function Get-Table {
    $json = az rest --method get --url $tableUrl
    if (-not $json) { throw "Could not fetch table $tableName" }
    $json | ConvertFrom-Json
}

function Put-TableColumns([array]$columns) {
    $body = @{ properties = @{ schema = @{ name = $tableName; columns = $columns } } } |
        ConvertTo-Json -Depth 10 -Compress
    az rest --method put --url $tableUrl --body $body | Out-Null
}

function Show-Status {
    Write-Host "`n--- STATUS ---" -ForegroundColor Cyan
    $t = Get-Table
    $cols = @($t.properties.schema.columns)
    $customPresent = @($cols | Where-Object { $allCustomNames -contains $_.name })
    Write-Host "Table $tableName : $($cols.Count) custom-schema columns; $($customPresent.Count) of $($allCustomNames.Count) custom fields present."
    $dcrs = Get-NetskopeDcrsForWorkspace
    if ($dcrs.Count -eq 0) {
        Write-Host "Netskope alerts/events DCR for $workspaceName : NONE (expected before reconnect)."
    } else {
        foreach ($d in $dcrs) {
            $streamCols = @($d.properties.streamDeclarations.$streamName.columns)
            Write-Host "DCR $($d.name) : $streamName has $($streamCols.Count) columns."
        }
    }
    if ($customPresent.Count -eq 0 -and $dcrs.Count -eq 0) {
        Write-Host "State = CLEAN. Ready for Phase 2 (reconnect in Sentinel UI)." -ForegroundColor Green
    } elseif ($customPresent.Count -eq 0 -and $dcrs.Count -ge 1) {
        Write-Host "State = RECONNECTED (stock schema). Verify data flows, then run -Phase Reapply." -ForegroundColor Green
    } elseif ($customPresent.Count -eq $allCustomNames.Count -and $dcrs.Count -ge 1) {
        Write-Host "State = CUSTOMIZED (post-Phase-3). Revert before any future disconnect." -ForegroundColor Green
    } else {
        Write-Host "State = MIXED. Run -Phase Revert (before reconnect) or -Phase Reapply (after)." -ForegroundColor Yellow
    }
}

switch ($Phase) {

"Status" { Show-Status }

"Revert" {
    Write-Host "`n=== PHASE 1: REVERT TO PACKAGED SCHEMA ===" -ForegroundColor Cyan

    # 1a. Backup
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $bk = "./backup_$stamp"
    New-Item -ItemType Directory -Path $bk | Out-Null
    $table = Get-Table
    $table | ConvertTo-Json -Depth 20 | Out-File "$bk/$tableName.json"
    Write-Host "  [OK] Table schema backed up to $bk/$tableName.json" -ForegroundColor Green

    $dcrs = Get-NetskopeDcrsForWorkspace
    foreach ($d in $dcrs) {
        az rest --method get --url "$mgmt$($d.id)?api-version=2022-06-01" | Out-File "$bk/$($d.name).json"
        Write-Host "  [OK] DCR backed up: $bk/$($d.name).json" -ForegroundColor Green
    }

    # 1b. Revert table: keep ONLY packaged column names (drop customs and any
    # other stragglers), preserving the live table's own column objects.
    $cols = @($table.properties.schema.columns)
    $packagedNames = $packagedColumns | ForEach-Object { $_.name }
    $keep   = @($cols | Where-Object { $packagedNames -contains $_.name })
    $remove = @($cols | Where-Object { $packagedNames -notcontains $_.name })

    if ($remove.Count -eq 0) {
        Write-Host "  [i] Table already matches packaged schema. No table change." -ForegroundColor Magenta
    } else {
        Write-Host "  Removing $($remove.Count) column(s):" -ForegroundColor Yellow
        $remove | ForEach-Object { Write-Host "    - $($_.name) ($($_.type))" }
        $unexpected = @($remove | Where-Object { $allCustomNames -notcontains $_.name })
        if ($unexpected.Count -gt 0) {
            Write-Host "  [!] $($unexpected.Count) column(s) above are NOT in the known custom list." -ForegroundColor Red
            Write-Host "      Review before proceeding - they will also be removed." -ForegroundColor Red
        }
        $confirm = Read-Host "  Proceed with table revert? (y/n)"
        if ($confirm -ne "y") { Write-Host "  Aborted."; return }
        Put-TableColumns $keep
        Write-Host "  [OK] Table reverted. Custom-schema column count now $($keep.Count)." -ForegroundColor Green
    }

    # 1c. Delete leftover connector DCR(s) - unless -SkipDcrDelete was passed
    if ($SkipDcrDelete) {
        Write-Host "  [i] -SkipDcrDelete set: leaving existing DCR(s) untouched." -ForegroundColor Magenta
        Write-Host "      If reconnect still fails, re-run Phase Revert without this switch." -ForegroundColor Magenta
    }
    elseif ($dcrs.Count -eq 0) {
        Write-Host "  [i] No connector-created Netskope DCR found for this workspace. Nothing to delete." -ForegroundColor Magenta
    } else {
        foreach ($d in $dcrs) {
            $confirm = Read-Host "  Delete DCR '$($d.name)'? (y/n)"
            if ($confirm -eq "y") {
                az rest --method delete --url "$mgmt$($d.id)?api-version=2022-06-01"
                Write-Host "  [OK] Deleted $($d.name)." -ForegroundColor Green
            } else {
                Write-Host "  [!] Skipped $($d.name) - reconnect may fail if its streams differ from the package." -ForegroundColor Yellow
            }
        }
    }

    Write-Host "`n=== PHASE 1 COMPLETE ===" -ForegroundColor Cyan
    Write-Host "Next: PHASE 2 (manual) - reconnect 'Netskope Alerts and Events' in the Sentinel UI."
    Write-Host "Verify data lands in $tableName, then run:  ./NetskopeDLP_ReconnectRecovery.ps1 -Phase Reapply"
}

"Reapply" {
    Write-Host "`n=== PHASE 3: RE-APPLY CUSTOM FIELDS ===" -ForegroundColor Cyan

    # 3a. Preconditions: connector DCR must exist (i.e., reconnect succeeded)
    $dcrs = Get-NetskopeDcrsForWorkspace
    if ($dcrs.Count -eq 0) {
        Write-Host "  [!] No connector-created Netskope DCR targets $workspaceName." -ForegroundColor Red
        Write-Host "      Complete Phase 2 (reconnect in Sentinel UI) first. Aborting." -ForegroundColor Red
        return
    }
    if ($dcrs.Count -gt 1) {
        Write-Host "  [!] Multiple Netskope DCRs target this workspace - unexpected:" -ForegroundColor Red
        $dcrs | ForEach-Object { Write-Host "      - $($_.name)" -ForegroundColor Red }
        Write-Host "      Resolve manually, then re-run. Aborting." -ForegroundColor Red
        return
    }
    $dcrName = $dcrs[0].name
    $dcrUrl  = "$mgmt$($dcrs[0].id)?api-version=2022-06-01"
    Write-Host "  [OK] Connector DCR found: $dcrName" -ForegroundColor Green

    # 3b. Add custom columns to the table (idempotent)
    $table = Get-Table
    $cols = @($table.properties.schema.columns)
    $names = $cols | ForEach-Object { $_.name }
    $toAdd = @($customRawFields + $customDerivedFields | Where-Object { $names -notcontains $_.name } |
        ForEach-Object { [PSCustomObject]@{ name = $_.name; type = $_.type } })
    if ($toAdd.Count -eq 0) {
        Write-Host "  [i] Table already has all custom columns." -ForegroundColor Magenta
    } else {
        Put-TableColumns (@($cols) + $toAdd)
        Write-Host "  [OK] Added $($toAdd.Count) column(s) to $tableName." -ForegroundColor Green
    }

    # 3c + 3d. Update DCR: stream columns + transformKql derived field
    $dcr = (az rest --method get --url $dcrUrl) | ConvertFrom-Json
    $changed = $false

    $stream = $dcr.properties.streamDeclarations.$streamName
    if (-not $stream) {
        Write-Host "  [!] Stream $streamName not found on $dcrName. Aborting DCR update." -ForegroundColor Red
        return
    }
    $sNames = @($stream.columns | ForEach-Object { $_.name })
    $sAdd = @($customRawFields | Where-Object { $sNames -notcontains $_.name } |
        ForEach-Object { [PSCustomObject]@{ name = $_.name; type = $_.type } })
    if ($sAdd.Count -gt 0) {
        $stream.columns = @($stream.columns) + $sAdd
        $changed = $true
        Write-Host "  [OK] Will add $($sAdd.Count) column(s) to stream $streamName." -ForegroundColor Green
    } else {
        Write-Host "  [i] Stream already has all custom raw fields." -ForegroundColor Magenta
    }

    # transformKql fix (defect in DCRChangesEXL.ps1: documented but never implemented)
    $flow = $dcr.properties.dataFlows | Where-Object { $_.outputStream -eq "Custom-$tableName" } | Select-Object -First 1
    if (-not $flow) { $flow = $dcr.properties.dataFlows | Where-Object { $_.streams -contains $streamName } | Select-Object -First 1 }
    if (-not $flow) {
        Write-Host "  [!] Could not locate dataFlow for $streamName. Skipping transformKql patch." -ForegroundColor Red
    } elseif ($flow.transformKql -match "endpoint_policy_match_desired_action") {
        Write-Host "  [i] transformKql already derives endpoint_policy_match_desired_action." -ForegroundColor Magenta
    } else {
        $flow.transformKql = "$($flow.transformKql.TrimEnd()) | $derivedExtend"
        $changed = $true
        Write-Host "  [OK] Will append derived-field extend to transformKql." -ForegroundColor Green
    }

    if ($changed) {
        $dcr.PSObject.Properties.Remove("immutableId")
        $dcr.PSObject.Properties.Remove("id")
        $dcr.PSObject.Properties.Remove("etag")
        $dcr.PSObject.Properties.Remove("systemData")
        $body = $dcr | ConvertTo-Json -Depth 30 -Compress
        az rest --method put --url $dcrUrl --body $body | Out-Null
        Write-Host "  [OK] DCR $dcrName updated." -ForegroundColor Green
    }

    Write-Host "`n=== PHASE 3 COMPLETE ===" -ForegroundColor Cyan
    Write-Host "Verify with:  $tableName | where isnotempty(shared_with) | take 5"
    Write-Host "REMINDER: before any future disconnect/reconnect, run -Phase Revert first."
}
}
