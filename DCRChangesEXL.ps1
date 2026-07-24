<#
    .SYNOPSIS
    Adds the 12 new API fields to the NetskopeEventsDLP_CL Log Analytics table
    and to the matching Custom-NetskopeEventsDLP stream declaration on an
    already-deployed Netskope Alerts & Events Data Collection Rule (DCR).

    This is an ADD-ONLY schema update (no deletes, no renames). It follows the
    same overall structure/conventions as the CCP -> Alerts & Events migration
    script (config block, hashtable-driven schema operations, az rest calls,
    read-only DCR property stripping, colored console output), simplified for
    a single table/stream and add-only operations.

    .NOTES
    - Requires the Azure CLI (`az`) to be installed and already logged in
      (`az login`), and the Az PowerShell module for Select-AzSubscription.
    - Run this against a TEST workspace first. Field types marked "UNVERIFIED"
      below were inferred by convention (see the comments on each field) and
      were NOT confirmed against a live Netskope API payload. Verify them
      before running against production.
#>

# --- 1. CONFIGURATION ---
# Update these four values for your environment before running.
# $dcrName can be left blank ("") - if so, Step 0 below will try to auto-discover
# the DCR by finding which DCR in $resourceGroupName has a destination pointing at
# $workspaceName. If more than one DCR matches, auto-discovery will list the
# candidates and stop, and you must set $dcrName manually to the correct one.
$subscriptionId    = ""
$resourceGroupName = ""
$workspaceName     = ""
$dcrName           = ""

# --- 2. SCHEMA OPERATIONS ---
# "add"          -> fields added to BOTH the Log Analytics table AND the DCR
#                   stream declaration. These are raw fields that come
#                   straight through from the Netskope API payload and rely
#                   on DCR pass-through (no transformKql change needed).
# "addTableOnly" -> fields added to the TABLE ONLY. endpoint_policy_match_desired_action
#                   is not a raw input field - it is derived inside transformKql
#                   from endpoint_policy_match.desired_action, so it must not
#                   be added to the raw stream declaration.
#
# Type flags:
#   [VERIFIED]   - type confirmed against existing precedent in mainTemplate.json
#   [CONVENTION] - type inferred from a closely related existing field (e.g. site/page_site)
#   [UNVERIFIED] - no in-file precedent exists; type is a reasonable guess only.
#                  Confirm against a live Netskope API payload before production use.
$schemaOperations = @{
    "NetskopeEventsDLP_CL" = @{
        "add" = @(
            @{ Name = "shared_with";             Type = "string"  }  # [VERIFIED]   matches NetskopeAlerts_CL
            @{ Name = "object_id";                Type = "string"  }  # [VERIFIED]   matches NetskopeAlerts_CL
            @{ Name = "modified";                 Type = "int"     }  # [VERIFIED]   matches NetskopeAlerts_CL
            @{ Name = "created";                  Type = "int"     }  # [UNVERIFIED] guessed by analogy to 'modified'
            @{ Name = "record_type";               Type = "string"  }  # [UNVERIFIED] no precedent found, safe default
            @{ Name = "device";                   Type = "string"  }  # [VERIFIED]   matches NetskopeAlerts_CL / NetskopeEventsEndpoint_CL
            @{ Name = "usb_device";               Type = "string"  }  # [UNVERIFIED] guessed to match 'device' convention
            @{ Name = "justification";            Type = "string"  }  # [VERIFIED]   matches NetskopeEventsEndpoint_CL
            @{ Name = "destination_site";         Type = "string"  }  # [CONVENTION] inferred from site/page_site pattern
            @{ Name = "ext_labels";               Type = "dynamic" }  # [UNVERIFIED] guessed analogous to dlp_match_info
            @{ Name = "endpoint_policy_match";    Type = "dynamic" }  # per user confirmation - nested object
        )
        "addTableOnly" = @(
            @{ Name = "endpoint_policy_match_desired_action"; Type = "string" }  # derived via transformKql: tostring(endpoint_policy_match.desired_action)
        )
    }
}

Select-AzSubscription -SubscriptionId $subscriptionId

# --- 2.5. STEP 0: (OPTIONAL) AUTO-DISCOVER THE DCR FROM THE WORKSPACE ---
# There is no direct ARM API to "get the DCR for this workspace" - a DCR only
# references its destination workspace(s) inside properties.destinations.logAnalytics.
# So this lists every DCR in $resourceGroupName and matches on workspaceResourceId.
# Only runs if you left $dcrName blank above.
if ([string]::IsNullOrWhiteSpace($dcrName)) {
    Write-Host "`n=== STEP 0: Discovering DCR for workspace '$workspaceName' ===" -ForegroundColor Cyan

    $workspaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName"
    $dcrListUrl          = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Insights/dataCollectionRules?api-version=2022-06-01"
    $dcrListJson         = az rest --method get --url $dcrListUrl

    if (-not $dcrListJson) {
        Write-Host "[!] Could not list DCRs in resource group '$resourceGroupName'. Set `$dcrName manually and re-run." -ForegroundColor Red
        return
    }

    $allDcrs = ($dcrListJson | ConvertFrom-Json).value
    if (-not $allDcrs -or $allDcrs.Count -eq 0) {
        Write-Host "[!] No Data Collection Rules found at all in resource group '$resourceGroupName'." -ForegroundColor Red
        Write-Host "    Check that `$resourceGroupName / `$subscriptionId are correct for where the connector was deployed." -ForegroundColor Red
        return
    }

    $candidates = @($allDcrs | Where-Object {
        $_.properties.destinations.logAnalytics |
            Where-Object { $_.workspaceResourceId -ieq $workspaceResourceId }
    })

    if ($candidates.Count -eq 0) {
        Write-Host "[!] None of the $($allDcrs.Count) DCR(s) in resource group '$resourceGroupName' have a destination pointing at workspace '$workspaceName'." -ForegroundColor Red
        Write-Host "    All DCR names found in this resource group (for reference):" -ForegroundColor Red
        foreach ($d in $allDcrs) { Write-Host "      - $($d.name)" -ForegroundColor Red }
        Write-Host "    The DCR you need may live in a different resource group than '$resourceGroupName'. Verify in the Azure Portal." -ForegroundColor Red
        return
    }
    elseif ($candidates.Count -eq 1) {
        $dcrName = $candidates[0].name
        Write-Host "  [OK] Found exactly one DCR pointing at this workspace: $dcrName" -ForegroundColor Green
    }
    else {
        Write-Host "  [!] Found $($candidates.Count) DCRs pointing at workspace '$workspaceName'. Set `$dcrName manually to the correct one:" -ForegroundColor Yellow
        foreach ($c in $candidates) {
            $hasDlpStream = @($c.properties.streamDeclarations.PSObject.Properties.Name) -match "Custom-NetskopeEventsDLP$"
            $flag = if ($hasDlpStream) { "  <-- has a stream matching Custom-NetskopeEventsDLP" } else { "" }
            Write-Host "      - $($c.name)$flag" -ForegroundColor Yellow
        }
        return
    }
}

# --- 3. STEP 1: UPDATE THE LOG ANALYTICS TABLE SCHEMA ---
Write-Host "`n=== STEP 1: Updating Log Analytics table schema(s) ===" -ForegroundColor Cyan

foreach ($tableName in $schemaOperations.Keys) {

    $ops         = $schemaOperations[$tableName]
    $fieldsToAdd = @()
    if ($ops.ContainsKey("add"))          { $fieldsToAdd += $ops["add"] }
    if ($ops.ContainsKey("addTableOnly")) { $fieldsToAdd += $ops["addTableOnly"] }

    Write-Host "`nTable: $tableName" -ForegroundColor Yellow

    $tableUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.OperationalInsights/workspaces/$workspaceName/tables/$($tableName)?api-version=2022-10-01"

    $existingTableJson = az rest --method get --url $tableUrl
    if (-not $existingTableJson) {
        Write-Host "[!] Could not fetch table '$tableName'. Skipping." -ForegroundColor Red
        continue
    }
    $existingTable = $existingTableJson | ConvertFrom-Json

    $existingColumns   = @($existingTable.properties.schema.columns)
    $existingNames     = $existingColumns | ForEach-Object { $_.name }
    $newColumns        = @()
    $addedCount        = 0

    foreach ($field in $fieldsToAdd) {
        if ($existingNames -contains $field.Name) {
            Write-Host "  [=] '$($field.Name)' already exists. Skipping." -ForegroundColor DarkGray
        }
        else {
            Write-Host "  [+] Adding column '$($field.Name)' (type: $($field.Type))" -ForegroundColor Green
            $newColumns += [PSCustomObject]@{ name = $field.Name; type = $field.Type }
            $addedCount++
        }
    }

    if ($addedCount -eq 0) {
        Write-Host "  [i] No changes required for '$tableName'." -ForegroundColor Magenta
        continue
    }

    $finalColumns = @($existingColumns) + $newColumns

    $body = @{
        properties = @{
            schema = @{
                name    = $tableName
                columns = $finalColumns
            }
        }
    } | ConvertTo-Json -Depth 10 -Compress

    az rest --method put --url $tableUrl --body $body | Out-Null
    Write-Host "  [OK] Table '$tableName' updated with $addedCount new column(s)." -ForegroundColor Green
}

# --- 4. STEP 2: UPDATE THE DATA COLLECTION RULE (DCR) STREAM DECLARATIONS ---
Write-Host "`n=== STEP 2: Updating DCR stream declaration(s) ===" -ForegroundColor Cyan

$dcrUrl     = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$($dcrName)?api-version=2022-06-01"
$dcrJson    = az rest --method get --url $dcrUrl
if (-not $dcrJson) {
    Write-Host "[!] Could not fetch DCR '$dcrName'. Aborting Step 2." -ForegroundColor Red
    return
}
$dcr = $dcrJson | ConvertFrom-Json

$dcrChanged = $false

foreach ($tableName in $schemaOperations.Keys) {

    $ops = $schemaOperations[$tableName]
    if (-not $ops.ContainsKey("add")) {
        continue  # nothing to push into the raw stream for this table
    }
    $fieldsToAdd = $ops["add"]

    # Table name minus "_CL" suffix, used to match the corresponding stream, e.g.
    # "NetskopeEventsDLP_CL" -> "NetskopeEventsDLP" -> "Custom-NetskopeEventsDLP"
    $baseName    = $tableName -replace "_CL$", ""
    $allStreams  = @($dcr.properties.streamDeclarations.PSObject.Properties.Name)
    $streamName  = $allStreams | Where-Object { $_ -match "Custom-$baseName$" } | Select-Object -First 1

    if (-not $streamName) {
        Write-Host "`n[!] No matching stream declaration found for table '$tableName' (looked for pattern 'Custom-$baseName$')." -ForegroundColor Red
        Write-Host "    DCR '$dcrName' actually contains $($allStreams.Count) stream declaration(s):" -ForegroundColor Red
        if ($allStreams.Count -eq 0) {
            Write-Host "      (none - streamDeclarations is empty or missing on this DCR object)" -ForegroundColor Red
        } else {
            foreach ($s in $allStreams) { Write-Host "      - $s" -ForegroundColor Red }
        }
        Write-Host "    Verify `$dcrName / `$resourceGroupName / `$workspaceName point at the DCR that actually" -ForegroundColor Red
        Write-Host "    backs the Netskope Alerts & Events connector, and that its stream name matches this pattern." -ForegroundColor Red
        Write-Host "    Skipping." -ForegroundColor Red
        continue
    }

    Write-Host "`nStream: $streamName" -ForegroundColor Yellow

    $stream          = $dcr.properties.streamDeclarations.$streamName
    $existingColumns = @($stream.columns)
    $existingNames   = $existingColumns | ForEach-Object { $_.name }
    $newColumns      = @()
    $addedCount      = 0

    foreach ($field in $fieldsToAdd) {
        if ($existingNames -contains $field.Name) {
            Write-Host "  [=] '$($field.Name)' already exists. Skipping." -ForegroundColor DarkGray
        }
        else {
            Write-Host "  [+] Adding column '$($field.Name)' (type: $($field.Type))" -ForegroundColor Green
            $newColumns += [PSCustomObject]@{ name = $field.Name; type = $field.Type }
            $addedCount++
        }
    }

    if ($addedCount -eq 0) {
        Write-Host "  [i] No changes required for stream '$streamName'." -ForegroundColor Magenta
        continue
    }

    $stream.columns = @($existingColumns) + $newColumns
    $dcrChanged      = $true
    Write-Host "  [OK] Stream '$streamName' will be updated with $addedCount new column(s)." -ForegroundColor Green
}

if (-not $dcrChanged) {
    Write-Host "`n[i] No DCR stream changes required. Skipping DCR update." -ForegroundColor Magenta
}
else {
    # Strip read-only properties that the API rejects on PUT.
    $dcr.PSObject.Properties.Remove("immutableId")
    $dcr.PSObject.Properties.Remove("id")
    $dcr.PSObject.Properties.Remove("etag")
    $dcr.PSObject.Properties.Remove("systemData")

    $dcrBody = $dcr | ConvertTo-Json -Depth 20 -Compress
    az rest --method put --url $dcrUrl --body $dcrBody | Out-Null
    Write-Host "`n[OK] DCR '$dcrName' updated successfully." -ForegroundColor Green
}

Write-Host "`n=== Done ===" -ForegroundColor Cyan