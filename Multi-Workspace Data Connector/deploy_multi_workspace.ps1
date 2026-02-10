<#
.SYNOPSIS
    Deploys Netskope WebTx Connector to multiple Log Analytics Workspaces.

.EXAMPLE
    .\deploy_multi_workspace.ps1
    # Follow the interactive prompts to enter workspace details.

    .\deploy_multi_workspace.ps1 -DelaySeconds 90
    # Same but with 90 second delay between deployments.
#>

param(
    [int]$DelaySeconds = 60,
    [string]$TemplatePath = "./netskope_webtx_single_workspace.json"
)

# ============================================================
# INTERACTIVE INPUT
# ============================================================

$numberOfWorkspaces = Read-Host "Enter number of workspaces (1-10)"
$numberOfWorkspaces = [int]$numberOfWorkspaces

if ($numberOfWorkspaces -lt 1 -or $numberOfWorkspaces -gt 10) {
    Write-Host "Invalid number. Must be between 1 and 10." -ForegroundColor Red
    exit 1
}

$workspaces = @()
for ($i = 1; $i -le $numberOfWorkspaces; $i++) {
    Write-Host "`n--- Workspace $i of $numberOfWorkspaces ---" -ForegroundColor Cyan
    $wsName = Read-Host "  Workspace Name"
    $rgName = Read-Host "  Resource Group Name"
    $wsLoc  = Read-Host "  Region (e.g. eastus, westus2)"

    $workspaces += @{
        WorkspaceName     = $wsName
        ResourceGroupName = $rgName
        Location          = $wsLoc
    }
}

# ============================================================
# DEPLOYMENT
# ============================================================

$currentSub = (Get-AzContext).Subscription.Id

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Netskope WebTx Multi-Workspace Deployment" -ForegroundColor Green
Write-Host " Subscription: $currentSub" -ForegroundColor Green
Write-Host " Workspaces:   $($workspaces.Count)" -ForegroundColor Green
Write-Host " Delay:        $DelaySeconds seconds between deployments" -ForegroundColor Green
Write-Host "========================================`n" -ForegroundColor Green

$results = @()
$total = $workspaces.Count

for ($i = 0; $i -lt $total; $i++) {
    $ws = $workspaces[$i]
    $wsName   = $ws.WorkspaceName
    $rgName   = $ws.ResourceGroupName
    $wsLoc    = $ws.Location
    $deployName = "NetskopeWebTx-$wsName-$(Get-Date -Format 'yyyyMMddHHmmss')"

    Write-Host "[$($i+1)/$total] Deploying to workspace: $wsName" -ForegroundColor Yellow
    Write-Host "  Resource Group : $rgName" -ForegroundColor Gray
    Write-Host "  Location       : $wsLoc" -ForegroundColor Gray
    Write-Host "  Deployment     : $deployName" -ForegroundColor Gray

    try {
        $params = @{
            "location"           = $wsLoc
            "workspace-location" = $wsLoc
            "subscription"       = $currentSub
            "resourceGroupName"  = $rgName
            "workspace"          = $wsName
        }

        $deployment = New-AzResourceGroupDeployment `
            -Name $deployName `
            -ResourceGroupName $rgName `
            -TemplateFile $TemplatePath `
            -TemplateParameterObject $params `
            -ErrorAction Stop

        Write-Host "  Status: SUCCEEDED" -ForegroundColor Green
        $results += @{ Workspace=$wsName; RG=$rgName; Status="Succeeded"; Error=$null }
    }
    catch {
        $errMsg = $_.Exception.Message
        Write-Host "  Status: FAILED" -ForegroundColor Red
        Write-Host "  Error : $errMsg" -ForegroundColor Red

        try {
            $ops = Get-AzResourceGroupDeploymentOperation -ResourceGroupName $rgName -DeploymentName $deployName -ErrorAction SilentlyContinue
            $failedOps = $ops | Where-Object { $_.Properties.ProvisioningState -eq 'Failed' }
            foreach ($op in $failedOps) {
                $detail = $op.Properties.StatusMessage | ConvertTo-Json -Depth 5
                Write-Host "  Inner Error:" -ForegroundColor Red
                Write-Host "  $detail" -ForegroundColor Red
            }
        } catch { }

        $results += @{ Workspace=$wsName; RG=$rgName; Status="Failed"; Error=$errMsg }
    }

    if ($i -lt ($total - 1)) {
        Write-Host "`n  Waiting $DelaySeconds seconds...`n" -ForegroundColor Cyan
        Start-Sleep -Seconds $DelaySeconds
    }
}

# ============================================================
# SUMMARY
# ============================================================

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " DEPLOYMENT SUMMARY" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

$ok   = ($results | Where-Object { $_.Status -eq "Succeeded" }).Count
$fail = ($results | Where-Object { $_.Status -eq "Failed" }).Count

foreach ($r in $results) {
    $c = if ($r.Status -eq "Succeeded") { "Green" } else { "Red" }
    Write-Host "  $($r.Workspace) ($($r.RG)): $($r.Status)" -ForegroundColor $c
}

Write-Host "`n  $ok succeeded, $fail failed out of $total`n" -ForegroundColor $(if ($fail -eq 0) {"Green"} else {"Yellow"})
