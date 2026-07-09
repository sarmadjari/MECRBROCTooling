<#
.SYNOPSIS
    Bulk registers multiple Azure Storage Accounts to a Recovery Services Vault using REST API.

.DESCRIPTION
    This script reads a CSV file and registers each storage account (containing Azure File
    Shares) to a Recovery Services Vault for backup protection using the Azure Backup REST API.
    It uses the same REST API flow as Register-StorageAccount-ToVault.ps1, per item.

    Per-item steps:
    1. Check current registration status (skips if already Registered).
    2. Register the storage account to the vault (PUT).
    3. Poll/verify registration status (SUCCESS, PENDING, or FAILED).

    Container discovery is refreshed ONCE per unique vault up front (before the item loop).

    PARALLELISM:
    - Items are processed in parallel using PowerShell 7's ForEach-Object -Parallel,
      bounded by -MaxParallel (default 5, matching the AFS "5 at a time" guidance).
    - On Windows PowerShell 5.1 (no -Parallel support) the script automatically
      falls back to SEQUENTIAL processing.
    - Set -MaxParallel 1 to force sequential processing on any version.
    - REST calls include automatic retry/backoff on HTTP 429 (throttling).

    CSV Format (Bulk-Register-StorageAccount-ToVault_Input.csv):
      Header row required. Columns:
        VaultSubscriptionId              - Subscription ID of the Recovery Services Vault
        VaultResourceGroup               - Resource group of the vault
        VaultName                        - Name of the vault
        StorageAccountSubscriptionId     - Subscription ID of the storage account (leave empty to use vault subscription)
        StorageAccountResourceGroup      - Resource group of the storage account
        StorageAccountName               - Name of the storage account

    Metrics tracked:
    - Total items processed
    - Success / Failed / Skipped / Pending counts
    - Per-item duration
    - Total elapsed time
    - Summary table at the end
    - Results exported to _Results.csv

    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Appropriate RBAC permissions on both Storage Account(s) and Recovery Services Vault

.PARAMETER CsvPath
    Path to the input CSV file. If not provided, the script looks for
    Bulk-Register-StorageAccount-ToVault_Input.csv in the same directory,
    or prompts interactively.

.PARAMETER MaxParallel
    Maximum number of storage accounts to register concurrently (default 5).
    Requires PowerShell 7+; on Windows PowerShell 5.1 the script runs sequentially.
    Use 1 to force sequential processing.

.EXAMPLE
    .\Bulk-Register-StorageAccount-ToVault.ps1 -CsvPath "C:\inputs\storageaccounts.csv"
    Runs bulk registration using the specified CSV file (up to 5 concurrent).

.EXAMPLE
    .\Bulk-Register-StorageAccount-ToVault.ps1 -MaxParallel 1
    Runs bulk registration one storage account at a time (sequential).

.NOTES
    Author: AFS Backup Expert
    Date: July 9, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api
    Reference: https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request (Bearer token auth header)
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath,

    [Parameter(Mandatory=$false)]
    [int]$MaxParallel = 5
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2025-08-01"  # Azure Backup REST API version

if ($MaxParallel -lt 1) { $MaxParallel = 1 }

# ============================================================================
# RUNTIME INPUT
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Register Storage Accounts to Recovery Services Vault" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# CSV file path — use param, else prompt
$defaultCsvPath = Join-Path $PSScriptRoot "Bulk-Register-StorageAccount-ToVault_Input.csv"

if ([string]::IsNullOrWhiteSpace($CsvPath)) {
    Write-Host "CSV Input File Path (press Enter for default):" -ForegroundColor Cyan
    Write-Host "  Default: $defaultCsvPath" -ForegroundColor Gray
    $CsvPath = Read-Host "  Enter path"
    if ([string]::IsNullOrWhiteSpace($CsvPath)) {
        $CsvPath = $defaultCsvPath
    }
} else {
    Write-Host "CSV Input File: $CsvPath" -ForegroundColor Gray
}

if (-not (Test-Path $CsvPath)) {
    Write-Host "ERROR: CSV file not found: $CsvPath" -ForegroundColor Red
    exit 1
}

$csvData = Import-Csv -Path $CsvPath
$totalItems = $csvData.Count

if ($totalItems -eq 0) {
    Write-Host "ERROR: CSV file is empty." -ForegroundColor Red
    exit 1
}

Write-Host "  Loaded $totalItems item(s) from CSV" -ForegroundColor Green

# Determine execution mode
$isPS7 = $PSVersionTable.PSVersion.Major -ge 7
$useParallel = ($MaxParallel -gt 1) -and $isPS7
if ($useParallel) {
    Write-Host "  Execution mode: PARALLEL (up to $MaxParallel concurrent)" -ForegroundColor Green
} elseif ($MaxParallel -gt 1 -and -not $isPS7) {
    Write-Host "  Execution mode: SEQUENTIAL (PowerShell $($PSVersionTable.PSVersion) - parallel requires PS7)" -ForegroundColor Yellow
} else {
    Write-Host "  Execution mode: SEQUENTIAL (-MaxParallel 1)" -ForegroundColor Gray
}
Write-Host ""

# Preview
Write-Host "Storage accounts to register:" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-5} {1,-30} {2,-25} {3,-25}" -f "#", "Storage Account", "Resource Group", "Vault") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-30} {2,-25} {3,-25}" -f ("-" * 5), ("-" * 30), ("-" * 25), ("-" * 25)) -ForegroundColor Gray

$itemNum = 1
foreach ($row in $csvData) {
    Write-Host ("{0,-5} {1,-30} {2,-25} {3,-25}" -f $itemNum, $row.StorageAccountName, $row.StorageAccountResourceGroup, $row.VaultName) -ForegroundColor White
    $itemNum++
}

Write-Host ""

Write-Host "Continue with bulk registration? (yes/no):" -ForegroundColor Cyan
$confirm = Read-Host "  Enter choice"
if ($confirm -ne "yes" -and $confirm -ne "YES" -and $confirm -ne "y" -and $confirm -ne "Y") {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# ============================================================================
# AUTHENTICATION
# ============================================================================

Write-Host ""
Write-Host "Authenticating to Azure..." -ForegroundColor Cyan

$token = $null

try {
    $tokenResponse = Get-AzAccessToken -ResourceUrl "https://management.azure.com"
    if ($tokenResponse.Token -is [System.Security.SecureString]) {
        $token = $tokenResponse.Token | ConvertFrom-SecureString -AsPlainText
    } else {
        $token = $tokenResponse.Token
    }
    if ([string]::IsNullOrWhiteSpace($token) -or $token.Length -lt 100) {
        throw "Token appears invalid (length: $($token.Length))"
    }
    Write-Host "  Authentication successful (Azure PowerShell)" -ForegroundColor Green
} catch {
    Write-Host "  Azure PowerShell not available, trying Azure CLI..." -ForegroundColor Yellow
    try {
        $azTokenOutput = az account get-access-token --resource https://management.azure.com 2>&1
        if ($LASTEXITCODE -eq 0) {
            $token = ($azTokenOutput | ConvertFrom-Json).accessToken
            Write-Host "  Authentication successful (Azure CLI)" -ForegroundColor Green
        } else { throw "CLI auth failed" }
    } catch {
        Write-Host "ERROR: Failed to authenticate. Run Connect-AzAccount or az login." -ForegroundColor Red
        exit 1
    }
}

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type" = "application/json"
}

# ============================================================================
# PRE-STEP: REFRESH CONTAINER DISCOVERY (once per unique vault)
# ============================================================================
# Done up front (sequentially) so the parallel worker does not need shared state.

Write-Host ""
Write-Host "Refreshing container discovery for target vault(s)..." -ForegroundColor Cyan

$uniqueVaults = $csvData |
    ForEach-Object { [pscustomobject]@{ Sub = $_.VaultSubscriptionId.Trim(); Rg = $_.VaultResourceGroup.Trim(); Name = $_.VaultName.Trim() } } |
    Where-Object { $_.Sub -and $_.Rg -and $_.Name } |
    Sort-Object Sub, Rg, Name -Unique

foreach ($v in $uniqueVaults) {
    $refreshUri = "https://management.azure.com/subscriptions/$($v.Sub)/resourceGroups/$($v.Rg)/providers/Microsoft.RecoveryServices/vaults/$($v.Name)/backupFabrics/Azure/refreshContainers?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"
    try {
        Invoke-RestMethod -Uri $refreshUri -Method POST -Headers $headers | Out-Null
        Write-Host "  Refresh initiated for '$($v.Name)'" -ForegroundColor Green
    } catch {
        $rc = $null; try { $rc = $_.Exception.Response.StatusCode.value__ } catch { }
        if ($rc -eq 202 -or $rc -eq 204) {
            Write-Host "  Refresh accepted for '$($v.Name)' ($rc)" -ForegroundColor Green
        } else {
            Write-Host "  WARNING: Refresh for '$($v.Name)' returned: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}
Write-Host "  Waiting for discovery to settle..." -ForegroundColor Gray
Start-Sleep -Seconds 10

# ============================================================================
# PER-ITEM WORKER
# ============================================================================
# Defined as text so the SAME logic runs both in the main runspace (PS 5.1
# sequential) and inside ForEach-Object -Parallel runspaces (PS7). Everything
# it needs is passed in as parameters (no reliance on $using: inside the body).

$workerText = @'
param($row, $itemIndex, $totalItems, $headers, $apiVersion)

$tag = "[$itemIndex/$totalItems]"
function Say([string]$m, $c = "Gray") { Write-Host ("{0} {1}" -f $tag, $m) -ForegroundColor $c }

# Invoke-RestMethod with automatic retry/backoff on HTTP 429 (throttling).
function Invoke-RestRetry($Uri, $Method, $Hdrs, $Body = $null) {
    for ($a = 1; $a -le 5; $a++) {
        try {
            if ($null -ne $Body) { return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Hdrs -Body $Body }
            return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Hdrs
        } catch {
            $sc = $null; try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
            if ($sc -eq 429 -and $a -lt 5) { Start-Sleep -Seconds ([math]::Min(60, 2 * [math]::Pow(2, $a))); continue }
            throw
        }
    }
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Emit($res) {
    $sw.Stop()
    $res.Duration = "$([math]::Round($sw.Elapsed.TotalSeconds, 1))s"
    $c = switch ($res.Status) { "SUCCESS" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Say ("=> {0} ({1})" -f $res.Status, $res.Duration) $c
    return [PSCustomObject]$res
}

$vaultSubscriptionId = $row.VaultSubscriptionId.Trim()
$vaultResourceGroup = $row.VaultResourceGroup.Trim()
$vaultName = $row.VaultName.Trim()
$storageSubscriptionId = if ([string]::IsNullOrWhiteSpace($row.StorageAccountSubscriptionId)) { $vaultSubscriptionId } else { $row.StorageAccountSubscriptionId.Trim() }
$storageResourceGroup = $row.StorageAccountResourceGroup.Trim()
$storageAccountName = $row.StorageAccountName.Trim()

$itemResult = @{
    Index = $itemIndex
    Item = $storageAccountName
    ResourceGroup = $storageResourceGroup
    Vault = $vaultName
    Status = "Unknown"
    RegistrationStatus = ""
    Detail = ""
    Duration = ""
}

Say "$storageAccountName (RG: $storageResourceGroup | Vault: $vaultName)" Cyan

# Validate required fields
if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId) -or [string]::IsNullOrWhiteSpace($vaultResourceGroup) -or
    [string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($storageResourceGroup) -or
    [string]::IsNullOrWhiteSpace($storageAccountName)) {
    Say "  SKIPPED: Missing required fields in CSV row" Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "Missing required CSV fields"
    return (Emit $itemResult)
}

$storageAccountResourceId = "/subscriptions/$storageSubscriptionId/resourceGroups/$storageResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
$containerName = "StorageContainer;Storage;$storageResourceGroup;$storageAccountName"
$containerUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName`?api-version=$apiVersion"

# Step A: Check current registration status (skip if already Registered)
Say "  Step A: Checking current registration status..." Cyan
$alreadyRegistered = $false
try {
    $existing = Invoke-RestRetry $containerUri "GET" $headers
    if ($existing.properties.registrationStatus -eq "Registered") {
        $alreadyRegistered = $true
        Say "    Already registered (Health: $($existing.properties.healthStatus))" Yellow
    } else {
        Say "    Current status: $($existing.properties.registrationStatus)" Gray
    }
} catch {
    Say "    Not yet registered - will register" Gray
}

if ($alreadyRegistered) {
    $itemResult.Status = "SKIPPED"
    $itemResult.RegistrationStatus = "Registered"
    $itemResult.Detail = "Already registered to vault"
    return (Emit $itemResult)
}

# Step B: Register storage account (PUT)
Say "  Step B: Registering storage account..." Cyan
$registrationBody = @{
    properties = @{
        containerType = "StorageContainer"
        sourceResourceId = $storageAccountResourceId
        resourceGroup = $storageResourceGroup
        friendlyName = $storageAccountName
        backupManagementType = "AzureStorage"
    }
} | ConvertTo-Json -Depth 10

$registrationSucceeded = $false
try {
    Invoke-RestMethod -Uri $containerUri -Method PUT -Headers $headers -Body $registrationBody | Out-Null
    Say "    Registration request submitted (200)" Green
    $registrationSucceeded = $true
} catch {
    $putStatusCode = $_.Exception.Response.StatusCode.value__
    if ($putStatusCode -eq 202) {
        Say "    Registration request accepted (202)" Green
        $registrationSucceeded = $true
    } else {
        $errorMsg = $_.Exception.Message
        try {
            $errorStream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($errorStream)
            $errorJson = $reader.ReadToEnd() | ConvertFrom-Json
            $errorMsg = "$($errorJson.error.code): $($errorJson.error.message)"
        } catch { }
        Say "    FAILED: HTTP $putStatusCode - $errorMsg" Red
        $itemResult.Status = "FAILED"
        $itemResult.Detail = "HTTP $putStatusCode - $errorMsg"
        return (Emit $itemResult)
    }
}

# Step C: Verify registration status (poll)
if ($registrationSucceeded) {
    Say "  Step C: Verifying registration status..." Cyan
    $maxRetries = 20
    $retryCount = 0
    $verified = $false
    $finalStatus = "Unknown"

    while (-not $verified -and $retryCount -lt $maxRetries) {
        Start-Sleep -Seconds 6
        try {
            $statusCheck = Invoke-RestRetry $containerUri "GET" $headers
            $finalStatus = $statusCheck.properties.registrationStatus
            if ($finalStatus -eq "Registered") {
                $verified = $true
                Say "    Registration Status: $finalStatus (Health: $($statusCheck.properties.healthStatus))" Green
            } else {
                $retryCount++
                Say "    Waiting... ($retryCount/$maxRetries) [Status: $finalStatus]" Yellow
            }
        } catch {
            $retryCount++
            Say "    Polling... ($retryCount/$maxRetries)" Yellow
        }
    }

    if (-not $verified) {
        $itemResult.Status = "PENDING"
        $itemResult.RegistrationStatus = $finalStatus
        $itemResult.Detail = "Registration accepted, verification timed out. Verify on portal."
    } else {
        $itemResult.Status = "SUCCESS"
        $itemResult.RegistrationStatus = $finalStatus
        $itemResult.Detail = "Registered to vault '$vaultName'"
    }
}

return (Emit $itemResult)
'@

# ============================================================================
# BULK PROCESSING
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  Starting Bulk Storage Account Registration" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if ($useParallel) {
    $indexed = for ($i = 0; $i -lt $csvData.Count; $i++) { [pscustomobject]@{ Row = $csvData[$i]; Index = $i + 1 } }
    $indexed | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        $pi = $_
        try {
            $sb = [scriptblock]::Create($using:workerText)
            $r = & $sb $pi.Row $pi.Index $using:totalItems $using:headers $using:apiVersion
        } catch {
            $r = [pscustomobject]@{ Index = $pi.Index; Item = "(row $($pi.Index))"; Status = "FAILED"; Detail = "Unhandled error: $($_.Exception.Message)"; Duration = "0s" }
        }
        ($using:results).Add($r)
    }
} else {
    $sb = [scriptblock]::Create($workerText)
    $i = 0
    foreach ($row in $csvData) {
        $i++
        try {
            $r = & $sb $row $i $totalItems $headers $apiVersion
        } catch {
            $r = [pscustomobject]@{ Index = $i; Item = "(row $i)"; Status = "FAILED"; Detail = "Unhandled error: $($_.Exception.Message)"; Duration = "0s" }
        }
        $results.Add($r)
    }
}

$totalStopwatch.Stop()

# ============================================================================
# SUMMARY
# ============================================================================

$resArr = @($results.ToArray()) | Sort-Object Index
$successCount = @($resArr | Where-Object { $_.Status -eq "SUCCESS" }).Count
$failedCount  = @($resArr | Where-Object { $_.Status -eq "FAILED" }).Count
$skippedCount = @($resArr | Where-Object { $_.Status -eq "SKIPPED" }).Count
$pendingCount = @($resArr | Where-Object { $_.Status -eq "PENDING" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Storage Account Registration - Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Metrics:" -ForegroundColor Yellow
Write-Host "  Total Items:    $totalItems" -ForegroundColor White
Write-Host "  Succeeded:      $successCount" -ForegroundColor Green
Write-Host "  Failed:         $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
Write-Host "  Pending:        $pendingCount" -ForegroundColor $(if ($pendingCount -gt 0) { "Yellow" } else { "White" })
Write-Host "  Skipped:        $skippedCount" -ForegroundColor $(if ($skippedCount -gt 0) { "Yellow" } else { "White" })
Write-Host "  Total Duration: $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 1))s ($([math]::Round($totalStopwatch.Elapsed.TotalMinutes, 1)) min)" -ForegroundColor White
Write-Host ""

# Results table
Write-Host "Results:" -ForegroundColor Yellow
Write-Host ""
Write-Host ("{0,-5} {1,-30} {2,-10} {3,-18} {4,-10} {5}" -f "#", "Storage Account", "Status", "Reg. Status", "Duration", "Detail") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-30} {2,-10} {3,-18} {4,-10} {5}" -f ("-" * 5), ("-" * 30), ("-" * 10), ("-" * 18), ("-" * 10), ("-" * 35)) -ForegroundColor Gray

$rowNum = 1
foreach ($r in $resArr) {
    $statusColor = switch ($r.Status) { "SUCCESS" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Write-Host ("{0,-5} {1,-30} {2,-10} {3,-18} {4,-10} {5}" -f $rowNum, $r.Item, $r.Status, $r.RegistrationStatus, $r.Duration, $r.Detail) -ForegroundColor $statusColor
    $rowNum++
}

Write-Host ""

# Export results to CSV
$outputCsvPath = $CsvPath -replace '\.csv$', '_Results.csv'
$resArr | Select-Object Item, ResourceGroup, Vault, Status, RegistrationStatus, Detail, Duration | Export-Csv -Path $outputCsvPath -NoTypeInformation -Force
Write-Host "Results exported to: $outputCsvPath" -ForegroundColor Gray
Write-Host ""

if ($failedCount -gt 0) {
    Write-Host "WARNING: $failedCount item(s) failed. Check the results above for details." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  1. Storage account is already registered to another vault" -ForegroundColor White
    Write-Host "  2. Insufficient permissions on storage account or vault" -ForegroundColor White
    Write-Host "  3. Storage account doesn't exist or resource ID is incorrect" -ForegroundColor White
    Write-Host "  4. Cross-subscription registration not permitted by policy" -ForegroundColor White
    Write-Host ""
}

Write-Host "Next Steps:" -ForegroundColor Yellow
Write-Host "  1. Configure backup protection for the file shares in these storage accounts" -ForegroundColor White
Write-Host "  2. Use Configure-FileShare-Protection.ps1 (single) or" -ForegroundColor White
Write-Host "     Bulk-Configure-FileShare-Protection.ps1 (bulk) with a Vault-Standard policy" -ForegroundColor White
Write-Host ""

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Registration Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
