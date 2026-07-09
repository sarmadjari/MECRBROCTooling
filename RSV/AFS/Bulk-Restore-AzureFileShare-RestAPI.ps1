<#
.SYNOPSIS
    Bulk restores backed-up Azure File Shares from a CSV file using REST API.

.DESCRIPTION
    This script reads a CSV file and triggers a restore for each backed-up Azure File Share
    listed. It uses the same REST API flow as Restore-AzureFileShare-RestAPI.ps1, per item.

    Per-item steps:
    1. Verify the source file share is a protected item in the vault (resolve real names).
    2. Fetch recovery points and select one (latest, or an explicit recovery point name).
    3. Build the AzureFileShareRestoreRequest body.
    4. Trigger the restore (POST) and track the async operation to completion.

    Supported per row:
    - RestoreType : FullShareRestore (default) | ItemLevelRestore
    - RecoveryType: AlternateLocation (default) | OriginalLocation
    - CopyOptions : Overwrite (default) | Skip | FailOnConflict
    - RecoveryPoint: latest (default) | <specific recovery point name>

    PARALLELISM:
    - Items are processed in parallel using PowerShell 7's ForEach-Object -Parallel,
      bounded by -MaxParallel (default 5).
    - On Windows PowerShell 5.1 (no -Parallel support) the script automatically
      falls back to SEQUENTIAL processing.
    - Set -MaxParallel 1 to force sequential processing on any version.
    - REST calls include automatic retry/backoff on HTTP 429 (throttling).

    Important Support Notes (AFS Vaulted Policy):
    1. Only ALR (Alternate Location) restore is released in production. ILR and OLR are not.
    2. The target folder name during restore has to be empty (restore to root).
    3. The Copy Option has to be Overwrite only.

    CSV Format (Bulk-Restore-AzureFileShare-RestAPI_Input.csv):
      Header row required. Columns:
        VaultSubscriptionId                  - Subscription ID of the Recovery Services Vault
        VaultResourceGroup                   - Resource group of the vault
        VaultName                            - Name of the vault
        SourceStorageAccountSubscriptionId   - Subscription ID of the SOURCE storage account (empty = vault subscription)
        SourceStorageAccountResourceGroup    - Resource group of the source storage account
        SourceStorageAccountName             - Name of the source (backed-up) storage account
        SourceFileShareName                  - Name of the source (backed-up) file share
        RestoreType                          - FullShareRestore | ItemLevelRestore (empty = FullShareRestore)
        RecoveryType                         - AlternateLocation | OriginalLocation (empty = AlternateLocation)
        CopyOptions                          - Overwrite | Skip | FailOnConflict (empty = Overwrite)
        RecoveryPoint                        - latest | <recovery point name> (empty = latest)
        TargetStorageAccountSubscriptionId   - Subscription ID of the TARGET storage account (empty = source subscription) [ALR only]
        TargetStorageAccountResourceGroup    - Resource group of the target storage account [ALR only]
        TargetStorageAccountName             - Name of the target storage account [ALR only]
        TargetFileShareName                  - Name of the target file share [ALR only]
        TargetFolderPath                     - Optional target folder (empty = root) [ALR only]
        ItemPaths                            - Semicolon-separated paths for ItemLevelRestore,
                                               each "File:path" or "Folder:path" (e.g. "File:reports/q4.xlsx;Folder:logs/")

    Metrics tracked:
    - Total items processed
    - Success / Failed / Skipped / Pending counts
    - Per-item duration
    - Total elapsed time
    - Summary table at the end
    - Results exported to _Results.csv

    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login) authentication
    - Source file shares must be backed up (protected) in the vault
    - Appropriate RBAC permissions (Backup Operator on the vault, Contributor on the
      target storage account for ALR, Reader on the source storage account)

.PARAMETER CsvPath
    Path to the input CSV file. If not provided, the script looks for
    Bulk-Restore-AzureFileShare-RestAPI_Input.csv in the same directory,
    or prompts interactively.

.PARAMETER MaxParallel
    Maximum number of restores to run concurrently (default 5). Requires PowerShell 7+;
    on Windows PowerShell 5.1 the script runs sequentially. Use 1 to force sequential.

.EXAMPLE
    .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -CsvPath "C:\inputs\restores.csv"
    Runs bulk restore using the specified CSV file (up to 5 concurrent).

.EXAMPLE
    .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -MaxParallel 1
    Runs bulk restore one item at a time (sequential).

.NOTES
    Author: AFS Backup Expert
    Date: July 9, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/restore-azure-file-share-rest-api
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

# Load System.Web for URL encoding (required in PowerShell 7)
Add-Type -AssemblyName System.Web

# ============================================================================
# RUNTIME INPUT
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Restore Azure File Shares (REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# CSV file path — use param, else prompt
$defaultCsvPath = Join-Path $PSScriptRoot "Bulk-Restore-AzureFileShare-RestAPI_Input.csv"

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
Write-Host "Restores to perform:" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-5} {1,-28} {2,-18} {3,-28} {4,-10}" -f "#", "Source (SA/Share)", "Recovery Type", "Target (SA/Share)", "Rec.Point") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-28} {2,-18} {3,-28} {4,-10}" -f ("-" * 5), ("-" * 28), ("-" * 18), ("-" * 28), ("-" * 10)) -ForegroundColor Gray

$itemNum = 1
foreach ($row in $csvData) {
    $src = "$($row.SourceStorageAccountName)/$($row.SourceFileShareName)"
    $recType = if ([string]::IsNullOrWhiteSpace($row.RecoveryType)) { "AlternateLocation" } else { $row.RecoveryType }
    $tgt = if ($recType -eq "AlternateLocation") { "$($row.TargetStorageAccountName)/$($row.TargetFileShareName)" } else { "(original)" }
    $rp = if ([string]::IsNullOrWhiteSpace($row.RecoveryPoint)) { "latest" } else { $row.RecoveryPoint }
    Write-Host ("{0,-5} {1,-28} {2,-18} {3,-28} {4,-10}" -f $itemNum, $src, $recType, $tgt, $rp) -ForegroundColor White
    $itemNum++
}

Write-Host ""

# Caution: AFS vaulted-policy restore support notes
Write-Host "IMPORTANT (AFS Vaulted Policy):" -ForegroundColor DarkYellow
Write-Host "  - Only ALR (Alternate Location) restore is released in production. ILR/OLR are not." -ForegroundColor DarkYellow
Write-Host "  - The target folder must be empty (restore to root)." -ForegroundColor DarkYellow
Write-Host "  - The Copy Option must be Overwrite only." -ForegroundColor DarkYellow
Write-Host ""
Write-Host "WARNING: Restore operations overwrite/modify target data and cannot be undone." -ForegroundColor Yellow
Write-Host ""

Write-Host "Continue with bulk restore? (yes/no):" -ForegroundColor Cyan
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
# PER-ITEM WORKER
# ============================================================================
# Defined as text so the SAME logic runs both in the main runspace (PS 5.1
# sequential) and inside ForEach-Object -Parallel runspaces (PS7). Everything
# it needs is passed in as parameters (no reliance on $using: inside the body).

$workerText = @'
param($row, $itemIndex, $totalItems, $headers, $apiVersion)

Add-Type -AssemblyName System.Web

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

# --- Parse row with defaults ---
$vaultSubscriptionId = $row.VaultSubscriptionId.Trim()
$vaultResourceGroup = $row.VaultResourceGroup.Trim()
$vaultName = $row.VaultName.Trim()
$sourceSubscriptionId = if ([string]::IsNullOrWhiteSpace($row.SourceStorageAccountSubscriptionId)) { $vaultSubscriptionId } else { $row.SourceStorageAccountSubscriptionId.Trim() }
$sourceResourceGroup = $row.SourceStorageAccountResourceGroup.Trim()
$sourceStorageAccount = $row.SourceStorageAccountName.Trim()
$sourceFileShare = $row.SourceFileShareName.Trim()
$restoreRequestType = if ([string]::IsNullOrWhiteSpace($row.RestoreType)) { "FullShareRestore" } else { $row.RestoreType.Trim() }
$recoveryType = if ([string]::IsNullOrWhiteSpace($row.RecoveryType)) { "AlternateLocation" } else { $row.RecoveryType.Trim() }
$copyOptions = if ([string]::IsNullOrWhiteSpace($row.CopyOptions)) { "Overwrite" } else { $row.CopyOptions.Trim() }
$recoveryPointChoice = if ([string]::IsNullOrWhiteSpace($row.RecoveryPoint)) { "latest" } else { $row.RecoveryPoint.Trim() }
$targetSubscriptionId = if ([string]::IsNullOrWhiteSpace($row.TargetStorageAccountSubscriptionId)) { $sourceSubscriptionId } else { $row.TargetStorageAccountSubscriptionId.Trim() }
$targetResourceGroup = if ($null -ne $row.TargetStorageAccountResourceGroup) { $row.TargetStorageAccountResourceGroup.Trim() } else { "" }
$targetStorageAccount = if ($null -ne $row.TargetStorageAccountName) { $row.TargetStorageAccountName.Trim() } else { "" }
$targetFileShare = if ($null -ne $row.TargetFileShareName) { $row.TargetFileShareName.Trim() } else { "" }
$targetFolderPath = if ($null -ne $row.TargetFolderPath -and -not [string]::IsNullOrWhiteSpace($row.TargetFolderPath)) { $row.TargetFolderPath.Trim() } else { $null }
$itemPathsRaw = if ($null -ne $row.ItemPaths) { $row.ItemPaths.Trim() } else { "" }

$targetLabel = if ($recoveryType -eq "AlternateLocation") { "$targetStorageAccount/$targetFileShare" } else { "(original)" }

$itemResult = @{
    Index = $itemIndex
    Item = "$sourceStorageAccount/$sourceFileShare"
    Target = $targetLabel
    RecoveryType = $recoveryType
    Status = "Unknown"
    JobId = ""
    Detail = ""
    Duration = ""
}

Say "$sourceStorageAccount/$sourceFileShare -> $recoveryType (Type: $restoreRequestType | Copy: $copyOptions | RP: $recoveryPointChoice)" Cyan

# --- Validate required fields ---
if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId) -or [string]::IsNullOrWhiteSpace($vaultResourceGroup) -or
    [string]::IsNullOrWhiteSpace($vaultName) -or [string]::IsNullOrWhiteSpace($sourceResourceGroup) -or
    [string]::IsNullOrWhiteSpace($sourceStorageAccount) -or [string]::IsNullOrWhiteSpace($sourceFileShare)) {
    Say "  SKIPPED: Missing required source/vault fields in CSV row" Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "Missing required CSV fields"
    return (Emit $itemResult)
}

# --- Validate ALR target fields ---
if ($recoveryType -eq "AlternateLocation" -and (
    [string]::IsNullOrWhiteSpace($targetResourceGroup) -or [string]::IsNullOrWhiteSpace($targetStorageAccount) -or
    [string]::IsNullOrWhiteSpace($targetFileShare))) {
    Say "  SKIPPED: AlternateLocation restore requires Target storage account/resource group/file share" Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "Missing target fields for AlternateLocation restore"
    return (Emit $itemResult)
}

# --- Construct source identifiers ---
$sourceResourceId = "/subscriptions/$sourceSubscriptionId/resourceGroups/$sourceResourceGroup/providers/Microsoft.Storage/storageAccounts/$sourceStorageAccount"
$containerName = "StorageContainer;storage;$sourceResourceGroup;$sourceStorageAccount"
$protectedItemName = "AzureFileShare;$sourceFileShare"
$containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
$protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)

# STEP A: Verify protected item exists (resolve real names)
Say "  Step A: Verifying source file share is protected..." Cyan
$listProtectedItemsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureStorage'"
$itemVerified = $false
try {
    $protectedItemsResponse = Invoke-RestRetry $listProtectedItemsUri "GET" $headers
    $protectedItems = @($protectedItemsResponse.value)
    $matchingItem = $protectedItems | Where-Object {
        $_.properties.friendlyName -eq $sourceFileShare -and
        $_.properties.sourceResourceId -eq $sourceResourceId
    } | Select-Object -First 1
    if ($matchingItem -and $matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
        $containerName = $matches[1]
        $protectedItemName = $matches[2]
        $containerNameEncoded = [System.Web.HttpUtility]::UrlEncode($containerName)
        $protectedItemNameEncoded = [System.Web.HttpUtility]::UrlEncode($protectedItemName)
        $itemVerified = $true
        Say "    Protected item verified" Green
    } else {
        Say "    FAILED: File share '$sourceFileShare' not protected in vault (storage '$sourceStorageAccount')" Red
    }
} catch {
    Say "    FAILED: Could not list protected items - $($_.Exception.Message)" Red
}

if (-not $itemVerified) {
    $itemResult.Status = "FAILED"
    $itemResult.Detail = "Source file share not found as a protected item in the vault"
    return (Emit $itemResult)
}

# STEP B: Select recovery point
Say "  Step B: Selecting recovery point ($recoveryPointChoice)..." Cyan
$recoveryPointsUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded/recoveryPoints?api-version=$apiVersion"
$recoveryPointId = $null
try {
    $rpResponse = Invoke-RestRetry $recoveryPointsUri "GET" $headers
    $recoveryPoints = @($rpResponse.value)
    if ($recoveryPoints.Count -eq 0) {
        Say "    FAILED: No recovery points found" Red
    } elseif ($recoveryPointChoice -eq "latest") {
        $selectedRp = $recoveryPoints | Sort-Object { [datetime]$_.properties.recoveryPointTime } -Descending | Select-Object -First 1
        $recoveryPointId = $selectedRp.name
        Say "    Latest recovery point: $recoveryPointId ($($selectedRp.properties.recoveryPointTime))" Green
    } else {
        $selectedRp = $recoveryPoints | Where-Object { $_.name -eq $recoveryPointChoice } | Select-Object -First 1
        if ($selectedRp) {
            $recoveryPointId = $selectedRp.name
            Say "    Recovery point found: $recoveryPointId ($($selectedRp.properties.recoveryPointTime))" Green
        } else {
            Say "    FAILED: Recovery point '$recoveryPointChoice' not found ($($recoveryPoints.Count) available)" Red
        }
    }
} catch {
    Say "    FAILED: Could not fetch recovery points - $($_.Exception.Message)" Red
}

if ([string]::IsNullOrWhiteSpace($recoveryPointId)) {
    $itemResult.Status = "FAILED"
    $itemResult.Detail = "Recovery point not resolved ('$recoveryPointChoice')"
    return (Emit $itemResult)
}

# STEP C: Build restore request body
Say "  Step C: Building restore request..." Cyan
$requestProperties = @{
    objectType = "AzureFileShareRestoreRequest"
    recoveryType = $recoveryType
    sourceResourceId = $sourceResourceId
    copyOptions = $copyOptions
    restoreRequestType = $restoreRequestType
}

if ($restoreRequestType -eq "ItemLevelRestore") {
    $restoreFileSpecs = @()
    foreach ($entry in ($itemPathsRaw -split ';')) {
        $trimmed = $entry.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match '^(File|Folder)\s*:\s*(.+)$') {
            $specType = $matches[1]
            $specPath = $matches[2].Trim()
        } else {
            $specType = "File"
            $specPath = $trimmed
        }
        $fileSpec = @{ fileSpecType = $specType; path = $specPath }
        if ($recoveryType -eq "AlternateLocation" -and -not [string]::IsNullOrWhiteSpace($targetFolderPath)) {
            $fileSpec.targetFolderPath = $targetFolderPath
        }
        $restoreFileSpecs += $fileSpec
    }
    if ($restoreFileSpecs.Count -eq 0) {
        Say "    FAILED: ItemLevelRestore requires ItemPaths (none provided)" Red
        $itemResult.Status = "FAILED"
        $itemResult.Detail = "ItemLevelRestore with no ItemPaths"
        return (Emit $itemResult)
    }
    $requestProperties.restoreFileSpecs = $restoreFileSpecs
} elseif ($recoveryType -eq "AlternateLocation" -and -not [string]::IsNullOrWhiteSpace($targetFolderPath)) {
    $requestProperties.restoreFileSpecs = @( @{ targetFolderPath = $targetFolderPath } )
}

if ($recoveryType -eq "AlternateLocation") {
    $targetResourceId = "/subscriptions/$targetSubscriptionId/resourceGroups/$targetResourceGroup/providers/Microsoft.Storage/storageAccounts/$targetStorageAccount"
    $requestProperties.targetDetails = @{
        name = $targetFileShare
        targetResourceId = $targetResourceId
    }
}

$requestBody = @{ properties = $requestProperties } | ConvertTo-Json -Depth 10

# STEP D: Trigger restore and track operation
Say "  Step D: Triggering restore..." Cyan
$restoreUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerNameEncoded/protectedItems/$protectedItemNameEncoded/recoveryPoints/$recoveryPointId/restore?api-version=$apiVersion"
try {
    $restoreResponse = Invoke-WebRequest -Uri $restoreUri -Method POST -Headers $headers -Body $requestBody -UseBasicParsing
    if ($restoreResponse.StatusCode -eq 202) {
        Say "    Restore accepted (202)" Green
        $azureAsyncHeader = $restoreResponse.Headers["Azure-AsyncOperation"] | Select-Object -First 1
        if ($azureAsyncHeader) {
            $operationComplete = $false
            $maxRetries = 30
            $retryCount = 0
            $finalStatus = "InProgress"
            while (-not $operationComplete -and $retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 10
                try {
                    $statusResponse = Invoke-RestMethod -Uri $azureAsyncHeader -Method GET -Headers $headers
                    $finalStatus = $statusResponse.status
                    if ($finalStatus -eq "Succeeded") {
                        $operationComplete = $true
                        if ($statusResponse.properties.jobId) { $itemResult.JobId = $statusResponse.properties.jobId }
                        Say "    Restore Succeeded" Green
                    } elseif ($finalStatus -eq "Failed") {
                        $operationComplete = $true
                        $errDetail = if ($statusResponse.error) { ($statusResponse.error | ConvertTo-Json -Depth 5 -Compress) } else { "Unknown error" }
                        Say "    Restore Failed: $errDetail" Red
                        $itemResult.Detail = "Restore failed: $errDetail"
                    } else {
                        $retryCount++
                        Say "    Status: $finalStatus ($retryCount/$maxRetries)" Yellow
                    }
                } catch {
                    $retryCount++
                    Say "    Polling... ($retryCount/$maxRetries)" Yellow
                }
            }
            if ($finalStatus -eq "Succeeded") {
                $itemResult.Status = "SUCCESS"
                if ([string]::IsNullOrWhiteSpace($itemResult.Detail)) { $itemResult.Detail = "Restore completed" }
            } elseif ($finalStatus -eq "Failed") {
                $itemResult.Status = "FAILED"
            } else {
                Say "    Restore still in progress (tracking timed out). Check Azure Portal." Yellow
                $itemResult.Status = "PENDING"
                $itemResult.Detail = "Restore triggered; tracking timed out. Verify on portal."
            }
        } else {
            $itemResult.Status = "PENDING"
            $itemResult.Detail = "Restore accepted (202); no async tracking header. Verify on portal."
            Say "    Restore initiated (no tracking header). Check Azure Portal." Yellow
        }
    } else {
        Say "    FAILED: Unexpected response code $($restoreResponse.StatusCode)" Red
        $itemResult.Status = "FAILED"
        $itemResult.Detail = "Unexpected HTTP $($restoreResponse.StatusCode)"
    }
} catch {
    $errMsg = $_.Exception.Message
    try {
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $reader.BaseStream.Position = 0
            $errorJson = $reader.ReadToEnd() | ConvertFrom-Json
            $errMsg = "$($errorJson.error.code): $($errorJson.error.message)"
        }
    } catch { }
    Say "    FAILED: $errMsg" Red
    $itemResult.Status = "FAILED"
    $itemResult.Detail = $errMsg
}

return (Emit $itemResult)
'@

# ============================================================================
# BULK PROCESSING
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host "  Starting Bulk Restore" -ForegroundColor Yellow
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
Write-Host "  Bulk Restore - Summary" -ForegroundColor Cyan
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
Write-Host ("{0,-5} {1,-28} {2,-28} {3,-10} {4,-10} {5}" -f "#", "Source", "Target", "Status", "Duration", "Detail") -ForegroundColor Cyan
Write-Host ("{0,-5} {1,-28} {2,-28} {3,-10} {4,-10} {5}" -f ("-" * 5), ("-" * 28), ("-" * 28), ("-" * 10), ("-" * 10), ("-" * 30)) -ForegroundColor Gray

$rowNum = 1
foreach ($r in $resArr) {
    $statusColor = switch ($r.Status) { "SUCCESS" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Write-Host ("{0,-5} {1,-28} {2,-28} {3,-10} {4,-10} {5}" -f $rowNum, $r.Item, $r.Target, $r.Status, $r.Duration, $r.Detail) -ForegroundColor $statusColor
    $rowNum++
}

Write-Host ""

# Export results to CSV
$outputCsvPath = $CsvPath -replace '\.csv$', '_Results.csv'
$resArr | Select-Object Item, Target, RecoveryType, Status, JobId, Detail, Duration | Export-Csv -Path $outputCsvPath -NoTypeInformation -Force
Write-Host "Results exported to: $outputCsvPath" -ForegroundColor Gray
Write-Host ""

if ($failedCount -gt 0) {
    Write-Host "WARNING: $failedCount item(s) failed. Check the results above for details." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  1. Source file share not backed up (protected) in the vault" -ForegroundColor White
    Write-Host "  2. Recovery point name not found / no recovery points available" -ForegroundColor White
    Write-Host "  3. Target storage account/file share invalid or insufficient permissions" -ForegroundColor White
    Write-Host "  4. Unsupported restore option for AFS vaulted policy (ILR/OLR, non-Overwrite)" -ForegroundColor White
    Write-Host ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Restore Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
