<#
.SYNOPSIS
    Bulk restores backed-up Azure IaaS VMs from a CSV file using REST API.

.DESCRIPTION
    This script reads a CSV file and triggers a restore for each backed-up
    Azure VM listed. It uses the same REST API flow as
    Restore-IaaSVM-RestAPI.ps1, per item.

    Per-item steps:
    1. Validate the CSV row (strict - see philosophy below) and pre-flight
       check the target environment (fail early, nothing mutated).
    2. Verify the source VM is a protected item in the vault (resolve real
       container / protected-item names).
    3. Fetch recovery points and select one (latest, or an explicit name).
    4. Build the IaasVMRestoreRequest body and trigger the restore (POST).
    5. Poll the async trigger operation until the restore JOB is created,
       then capture the Job ID.

    IMPORTANT - result status is TRIGGERED, not "restore finished":
    A row ends in TRIGGERED when the restore JOB was successfully created
    (Job ID captured). VM restores can then run for many hours (a
    far-region/ROC restore is ~2.5-3x slower than same-region; large VMs can
    take 15-45 hours). This script intentionally does NOT wait for the
    restore data copy. Track the Job IDs from the results in
    Azure Portal -> Recovery Services Vault -> Backup Jobs.

    Supported RestoreType per row (ROC support matrix - all three paths):
    - RestoreDisks       : restore managed disks + VM config to the staging
                           storage account (you build the VM afterwards).
    - AlternateLocation  : create a NEW VM in a target RG/VNet/subnet
                           (default when RestoreType is empty).
    - OriginalLocation   : REPLACE the disks of the existing source VM
                           in-place (VM restarts). Destructive - requires the
                           -AllowOriginalLocation switch AND an explicit
                           'OriginalLocation' value in the CSV row (double
                           opt-in). Restore region must equal the datasource
                           region.

    STRICT-CSV PHILOSOPHY / AUTOMATION SWITCHES:
    By default the script follows the CSV 100% and expects the target
    environment to be ready. Rows that do not meet a precondition are SKIPPED
    and clearly reported - the script never guesses:
      * Empty TargetVMName (AlternateLocation)      -> row SKIPPED
      * Target VM name already in use               -> row SKIPPED
      * Target resource group does not exist        -> row SKIPPED
      * Target VNet/subnet does not exist           -> row SKIPPED
      * Staging storage account missing/wrong region-> row SKIPPED
      * RecoveryType=OriginalLocation without the
        -AllowOriginalLocation switch               -> row SKIPPED
    Opt-in switches:
      * -UseSourceNameIfEmpty  : empty TargetVMName cells use the SOURCE VM
                                 name as the new VM name
      * -AllowOriginalLocation : allows rows that EXPLICITLY request
                                 OriginalLocation to run (never a default)
    Governance objects (resource groups, VNets) are NEVER auto-created -
    the skip report includes the exact command / action needed.

    PARALLELISM:
    - Items are processed in parallel using PowerShell 7's ForEach-Object
      -Parallel, bounded by -MaxParallel (default 3 - VM restores are heavy).
    - On Windows PowerShell 5.1 the script falls back to SEQUENTIAL.
    - REST calls include automatic retry/backoff on HTTP 429 (throttling).

    CSV Format (Bulk-Restore-IaaSVM-FromCSV_Input.csv):
      Header row required. Columns:
        VaultSubscriptionId                 - Subscription ID of the Recovery Services Vault
        VaultResourceGroup                  - Resource group of the vault
        VaultName                           - Name of the vault
        SourceVMName                        - Name of the source (backed-up) VM
        SourceVMResourceGroup               - Resource group of the source VM
        SourceVMSubscriptionId              - Subscription of the source VM (empty = vault subscription)
        RestoreType                         - RestoreDisks | AlternateLocation | OriginalLocation
                                              (empty = AlternateLocation)
        RecoveryPoint                       - latest | <recovery point name> (empty = latest)
        DatasourceRegion                    - Region of the SOURCE VM (e.g. uaenorth) - REQUIRED
        RestoreRegion                       - Region to restore INTO (e.g. swedencentral) - REQUIRED
        StagingStorageAccountSubscriptionId - Subscription of staging account (empty = vault subscription)
        StagingStorageAccountResourceGroup  - Resource group of the staging storage account - REQUIRED
        StagingStorageAccountName           - Staging storage account (VAULT's region, not ZRS) - REQUIRED
        TargetVMName                        - New VM name [AlternateLocation - REQUIRED; empty rows are
                                              SKIPPED unless -UseSourceNameIfEmpty]
        TargetResourceGroup                 - Resource group for the new VM [AlternateLocation - REQUIRED;
                                              must already exist - never auto-created]
        TargetSubscriptionId                - Subscription for the new VM (empty = vault subscription)
        TargetVNetName                      - Target virtual network [AlternateLocation - REQUIRED]
        TargetVNetResourceGroup             - VNet resource group (empty = TargetResourceGroup)
        TargetSubnetName                    - Target subnet [AlternateLocation - REQUIRED]
        TargetDiskResourceGroup             - Optional RG for restored managed disks [RestoreDisks only]

    Cross-region rule (from the single script / ROC support matrix):
    - When RestoreRegion differs from DatasourceRegion, snapshot/Instant
      recovery-point tier cannot be used - the script automatically sets
      preferredRecoveryPointTier = HardenedRP (vault tier).
    - OriginalLocation requires RestoreRegion == DatasourceRegion.

    NOTE - Confidential VMs: this script targets General Purpose VMs. For
    CVM restores (securedVmDetails / disk encryption sets) use
    RSV\IaaSVM\CVM\Restore-IaaSVM-CVM-RestAPI.ps1. CVM + CMK in Azure Key
    Vault cannot cross-region restore (keys must be migrated to mHSM first).

    Prerequisites:
    - Azure PowerShell (Connect-AzAccount) OR Azure CLI (az login)
    - Source VMs must be protected in the vault
    - Staging storage account in the vault's region (per row)
    - RBAC: Backup Operator on the vault, Contributor on target RG/VNet scope

.PARAMETER CsvPath
    Path to the input CSV file. If not provided, the script looks for
    Bulk-Restore-IaaSVM-FromCSV_Input.csv in the same directory, or prompts.

.PARAMETER MaxParallel
    Maximum number of restore triggers to run concurrently (default 3).
    Requires PowerShell 7+; on Windows PowerShell 5.1 the script runs
    sequentially. Use 1 to force sequential.

.PARAMETER UseSourceNameIfEmpty
    Opt-in. AlternateLocation rows with an empty TargetVMName use the SOURCE
    VM name as the new VM name. Without this switch such rows are SKIPPED
    and reported (an empty cell may be a CSV mistake).

.PARAMETER AllowOriginalLocation
    Opt-in. Allows rows that EXPLICITLY set RestoreType=OriginalLocation to
    run (in-place disk replacement - the VM restarts and its current disks
    are replaced). Without this switch such rows are SKIPPED and reported.
    An empty RestoreType cell NEVER defaults to OriginalLocation.

.EXAMPLE
    .\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath "C:\inputs\vm-restores.csv"
    Strict mode: rows with missing names/preconditions are skipped and reported.

.EXAMPLE
    .\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath ".\vm-restores.csv" -UseSourceNameIfEmpty
    Empty TargetVMName cells use the source VM name for the restored VM.

.EXAMPLE
    .\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath ".\rollback.csv" -AllowOriginalLocation
    Enables in-place (replace disks) rows that explicitly request
    OriginalLocation - e.g. mass rollback after corruption in the source region.

.NOTES
    Author: Azure Backup Script Generator
    Date: July 23, 2026
    Reference: https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-restoreazurevms
    Reference: https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request (Bearer token auth header)
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$CsvPath,

    [Parameter(Mandatory=$false)]
    [int]$MaxParallel = 3,

    [Parameter(Mandatory=$false)]
    [switch]$UseSourceNameIfEmpty,

    [Parameter(Mandatory=$false)]
    [switch]$AllowOriginalLocation
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$apiVersion = "2019-05-13"  # Azure Backup REST API version (matches Restore-IaaSVM-RestAPI.ps1)

if ($MaxParallel -lt 1) { $MaxParallel = 1 }

# ============================================================================
# RUNTIME INPUT
# ============================================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk Restore Azure IaaS VMs (REST API)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

# CSV file path - use param, else prompt
$defaultCsvPath = Join-Path $PSScriptRoot "Bulk-Restore-IaaSVM-FromCSV_Input.csv"

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

$csvData = @(Import-Csv -Path $CsvPath)
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

# Automation options (strict-CSV philosophy: deviations are opt-in switches)
Write-Host "  Automation options:" -ForegroundColor Cyan
if ($UseSourceNameIfEmpty) {
    Write-Host "    -UseSourceNameIfEmpty   ON  : empty TargetVMName cells use the SOURCE VM name" -ForegroundColor DarkYellow
} else {
    Write-Host "    -UseSourceNameIfEmpty   off : rows with an empty TargetVMName are SKIPPED" -ForegroundColor Gray
}
if ($AllowOriginalLocation) {
    Write-Host "    -AllowOriginalLocation  ON  : rows EXPLICITLY set to OriginalLocation will REPLACE DISKS IN-PLACE" -ForegroundColor Red
} else {
    Write-Host "    -AllowOriginalLocation  off : OriginalLocation rows are SKIPPED (in-place restore needs this switch)" -ForegroundColor Gray
}
Write-Host ""

# Preview
Write-Host "Restores to perform:" -ForegroundColor Cyan
Write-Host ""
Write-Host ("{0,-4} {1,-20} {2,-18} {3,-30} {4,-9} {5}" -f "#", "Source VM", "Restore Type", "Target", "RP", "Restore Region") -ForegroundColor Cyan
Write-Host ("{0,-4} {1,-20} {2,-18} {3,-30} {4,-9} {5}" -f ("-" * 4), ("-" * 20), ("-" * 18), ("-" * 30), ("-" * 9), ("-" * 14)) -ForegroundColor Gray

$itemNum = 1
foreach ($row in $csvData) {
    $rType = if ([string]::IsNullOrWhiteSpace($row.RestoreType)) { "AlternateLocation" } else { $row.RestoreType.Trim() }
    $rp = if ([string]::IsNullOrWhiteSpace($row.RecoveryPoint)) { "latest" } else { $row.RecoveryPoint }
    $tgt = switch ($rType) {
        "AlternateLocation" {
            $tgtVm = if ([string]::IsNullOrWhiteSpace($row.TargetVMName)) {
                if ($UseSourceNameIfEmpty) { "$($row.SourceVMName)*" } else { "<MISSING!>" }
            } else { $row.TargetVMName }
            "$($row.TargetResourceGroup)/$tgtVm"
        }
        "RestoreDisks"     { "(disks -> staging SA)" }
        "OriginalLocation" { if ($AllowOriginalLocation) { "(IN-PLACE disk replace!)" } else { "(in-place - will SKIP)" } }
        default            { "(unknown type!)" }
    }
    Write-Host ("{0,-4} {1,-20} {2,-18} {3,-30} {4,-9} {5}" -f $itemNum, $row.SourceVMName, $rType, $tgt, $rp, $row.RestoreRegion) -ForegroundColor White
    $itemNum++
}

Write-Host ""

# Notes about defaulted / problematic rows, shown before confirmation
$rowsWithEmptyTargetVm = @($csvData | Where-Object {
    ([string]::IsNullOrWhiteSpace($_.RestoreType) -or $_.RestoreType.Trim() -eq "AlternateLocation") -and
    [string]::IsNullOrWhiteSpace($_.TargetVMName)
})
if ($rowsWithEmptyTargetVm.Count -gt 0) {
    if ($UseSourceNameIfEmpty) {
        Write-Host "  * = TargetVMName was empty in the CSV; the SOURCE VM name will be used (-UseSourceNameIfEmpty)." -ForegroundColor DarkYellow
    } else {
        Write-Host "  NOTE: $($rowsWithEmptyTargetVm.Count) row(s) show <MISSING!> (empty TargetVMName) and will be SKIPPED." -ForegroundColor DarkYellow
        Write-Host "        Fix the CSV, or re-run with -UseSourceNameIfEmpty to use the source VM name for those rows." -ForegroundColor DarkYellow
    }
    Write-Host ""
}

$olrRows = @($csvData | Where-Object { -not [string]::IsNullOrWhiteSpace($_.RestoreType) -and $_.RestoreType.Trim() -ieq "OriginalLocation" })
if ($olrRows.Count -gt 0) {
    if ($AllowOriginalLocation) {
        Write-Host "  WARNING: $($olrRows.Count) row(s) will REPLACE THE DISKS of live VMs IN-PLACE (-AllowOriginalLocation)." -ForegroundColor Red
        Write-Host "           Those VMs restart and their current disk state is replaced. This cannot be undone." -ForegroundColor Red
    } else {
        Write-Host "  NOTE: $($olrRows.Count) row(s) request OriginalLocation (in-place) and will be SKIPPED." -ForegroundColor DarkYellow
        Write-Host "        In-place disk replacement requires the -AllowOriginalLocation switch (deliberate opt-in)." -ForegroundColor DarkYellow
    }
    Write-Host ""
}

Write-Host "IMPORTANT:" -ForegroundColor DarkYellow
Write-Host "  - Result status TRIGGERED means the restore JOB WAS CREATED (Job ID captured)." -ForegroundColor DarkYellow
Write-Host "    The restore itself can run for hours (far-region restores are ~2.5-3x slower)." -ForegroundColor DarkYellow
Write-Host "    Track jobs in Azure Portal -> Recovery Services Vault -> Backup Jobs." -ForegroundColor DarkYellow
Write-Host "  - Cross-region rows (RestoreRegion != DatasourceRegion) automatically use the" -ForegroundColor DarkYellow
Write-Host "    vault tier (preferredRecoveryPointTier = HardenedRP)." -ForegroundColor DarkYellow
Write-Host ""
Write-Host "WARNING: Restore operations modify target resources and cannot be undone." -ForegroundColor Yellow
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
param($row, $itemIndex, $totalItems, $headers, $apiVersion, $useSourceNameIfEmpty, $allowOriginalLocation)

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
    $c = switch ($res.Status) { "TRIGGERED" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Say ("=> {0} ({1})" -f $res.Status, $res.Duration) $c
    return [PSCustomObject]$res
}

# --- Parse row with defaults (only non-destructive defaults) ---
$vaultSubscriptionId = if ($null -ne $row.VaultSubscriptionId) { $row.VaultSubscriptionId.Trim() } else { "" }
$vaultResourceGroup  = if ($null -ne $row.VaultResourceGroup)  { $row.VaultResourceGroup.Trim() }  else { "" }
$vaultName           = if ($null -ne $row.VaultName)           { $row.VaultName.Trim() }           else { "" }
$sourceVMName        = if ($null -ne $row.SourceVMName)        { $row.SourceVMName.Trim() }        else { "" }
$sourceVMRG          = if ($null -ne $row.SourceVMResourceGroup) { $row.SourceVMResourceGroup.Trim() } else { "" }
$sourceVMSub         = if ([string]::IsNullOrWhiteSpace($row.SourceVMSubscriptionId)) { $vaultSubscriptionId } else { $row.SourceVMSubscriptionId.Trim() }
$restoreType         = if ([string]::IsNullOrWhiteSpace($row.RestoreType)) { "AlternateLocation" } else { $row.RestoreType.Trim() }
$recoveryPointChoice = if ([string]::IsNullOrWhiteSpace($row.RecoveryPoint)) { "latest" } else { $row.RecoveryPoint.Trim() }
$datasourceRegion    = if ($null -ne $row.DatasourceRegion)    { $row.DatasourceRegion.Trim() }    else { "" }
$restoreRegion       = if ($null -ne $row.RestoreRegion)       { $row.RestoreRegion.Trim() }       else { "" }
$stagingSub          = if ([string]::IsNullOrWhiteSpace($row.StagingStorageAccountSubscriptionId)) { $vaultSubscriptionId } else { $row.StagingStorageAccountSubscriptionId.Trim() }
$stagingRG           = if ($null -ne $row.StagingStorageAccountResourceGroup) { $row.StagingStorageAccountResourceGroup.Trim() } else { "" }
$stagingSA           = if ($null -ne $row.StagingStorageAccountName) { $row.StagingStorageAccountName.Trim() } else { "" }
$targetVMName        = if ($null -ne $row.TargetVMName)        { $row.TargetVMName.Trim() }        else { "" }
$targetRG            = if ($null -ne $row.TargetResourceGroup) { $row.TargetResourceGroup.Trim() } else { "" }
$targetSub           = if ([string]::IsNullOrWhiteSpace($row.TargetSubscriptionId)) { $vaultSubscriptionId } else { $row.TargetSubscriptionId.Trim() }
$targetVNetName      = if ($null -ne $row.TargetVNetName)      { $row.TargetVNetName.Trim() }      else { "" }
$targetVNetRG        = if ([string]::IsNullOrWhiteSpace($row.TargetVNetResourceGroup)) { $targetRG } else { $row.TargetVNetResourceGroup.Trim() }
$targetSubnetName    = if ($null -ne $row.TargetSubnetName)    { $row.TargetSubnetName.Trim() }    else { "" }
$targetDiskRG        = if ($null -ne $row.TargetDiskResourceGroup) { $row.TargetDiskResourceGroup.Trim() } else { "" }

# -UseSourceNameIfEmpty (opt-in): fall back to the SOURCE VM name when the
# CSV leaves TargetVMName empty. Default (switch absent) is strict: the
# validation below skips such rows.
if ($useSourceNameIfEmpty -and $restoreType -ieq "AlternateLocation" -and [string]::IsNullOrWhiteSpace($targetVMName)) {
    $targetVMName = $sourceVMName
    Say "  NOTE: TargetVMName empty in CSV - using source VM name '$sourceVMName' (-UseSourceNameIfEmpty)" DarkYellow
}

$targetLabel = switch ($restoreType) {
    "AlternateLocation" { "$targetRG/$targetVMName" }
    "RestoreDisks"      { "(disks -> $stagingSA)" }
    "OriginalLocation"  { "(in-place: $sourceVMName)" }
    default             { "(?)" }
}

$itemResult = @{
    Index = $itemIndex
    Item = "$sourceVMRG/$sourceVMName"
    Target = $targetLabel
    RestoreType = $restoreType
    Status = "Unknown"
    JobId = ""
    Detail = ""
    Duration = ""
}

Say "$sourceVMName -> $restoreType (RP: $recoveryPointChoice | Region: $restoreRegion)" Cyan

# --- Validate RestoreType value ---
if ($restoreType -notin @("RestoreDisks", "AlternateLocation", "OriginalLocation")) {
    Say "  SKIPPED: Unknown RestoreType '$restoreType' (valid: RestoreDisks | AlternateLocation | OriginalLocation)" Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "Unknown RestoreType '$restoreType'"
    return (Emit $itemResult)
}

# --- OriginalLocation double opt-in gate ---
if ($restoreType -ieq "OriginalLocation" -and -not $allowOriginalLocation) {
    Say "  SKIPPED: OriginalLocation (replace disks in-place) requires the -AllowOriginalLocation switch." Yellow
    Say "           This is a deliberate double opt-in: the switch AND an explicit CSV value are both required." Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "OriginalLocation requires -AllowOriginalLocation (in-place restore is destructive)"
    return (Emit $itemResult)
}

# --- Validate required common fields (strict: every field must be in the CSV) ---
$missingFields = @()
if ([string]::IsNullOrWhiteSpace($vaultSubscriptionId)) { $missingFields += "VaultSubscriptionId" }
if ([string]::IsNullOrWhiteSpace($vaultResourceGroup))  { $missingFields += "VaultResourceGroup" }
if ([string]::IsNullOrWhiteSpace($vaultName))           { $missingFields += "VaultName" }
if ([string]::IsNullOrWhiteSpace($sourceVMName))        { $missingFields += "SourceVMName" }
if ([string]::IsNullOrWhiteSpace($sourceVMRG))          { $missingFields += "SourceVMResourceGroup" }
if ([string]::IsNullOrWhiteSpace($datasourceRegion))    { $missingFields += "DatasourceRegion" }
if ([string]::IsNullOrWhiteSpace($restoreRegion))       { $missingFields += "RestoreRegion" }
if ([string]::IsNullOrWhiteSpace($stagingRG))           { $missingFields += "StagingStorageAccountResourceGroup" }
if ([string]::IsNullOrWhiteSpace($stagingSA))           { $missingFields += "StagingStorageAccountName" }

# --- Validate AlternateLocation target fields ---
if ($restoreType -ieq "AlternateLocation") {
    if ([string]::IsNullOrWhiteSpace($targetVMName))     { $missingFields += "TargetVMName" }
    if ([string]::IsNullOrWhiteSpace($targetRG))         { $missingFields += "TargetResourceGroup" }
    if ([string]::IsNullOrWhiteSpace($targetVNetName))   { $missingFields += "TargetVNetName" }
    if ([string]::IsNullOrWhiteSpace($targetSubnetName)) { $missingFields += "TargetSubnetName" }
}

if ($missingFields.Count -gt 0) {
    Say "  SKIPPED: Missing $($missingFields -join ', ') in CSV row. Fix the CSV and re-run." Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "Missing CSV field(s): $($missingFields -join ', ')"
    return (Emit $itemResult)
}

# --- OriginalLocation region rule: restore region must equal datasource region ---
if ($restoreType -ieq "OriginalLocation" -and ($restoreRegion.ToLower() -ne $datasourceRegion.ToLower())) {
    Say "  SKIPPED: OriginalLocation requires RestoreRegion ('$restoreRegion') == DatasourceRegion ('$datasourceRegion')." Yellow
    Say "           In-place disk replacement cannot cross regions." Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "OriginalLocation region mismatch: RestoreRegion '$restoreRegion' != DatasourceRegion '$datasourceRegion'"
    return (Emit $itemResult)
}

# --- Construct identifiers ---
$sourceResourceId = "/subscriptions/$sourceVMSub/resourceGroups/$sourceVMRG/providers/Microsoft.Compute/virtualMachines/$sourceVMName"
$storageAccountId = "/subscriptions/$stagingSub/resourceGroups/$stagingRG/providers/Microsoft.Storage/storageAccounts/$stagingSA"

# ============================================================
# STEP A: Pre-flight environment checks (fail early, no mutation)
# ============================================================
Say "  Step A: Pre-flight checks..." Cyan

# Staging storage account must exist (and should be in the vault's region, not ZRS)
$stagingObj = $null
try {
    $stagingObj = Invoke-RestRetry "https://management.azure.com$storageAccountId`?api-version=2023-05-01" "GET" $headers
    Say "    Staging SA exists (Location: $($stagingObj.location) | SKU: $($stagingObj.sku.name))" Gray
} catch {
    $sc = $null; try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
    if ($sc -eq 404) {
        Say "    SKIPPED: Staging storage account '$stagingSA' not found in RG '$stagingRG'." Yellow
        Say "             Create it in the VAULT's region: az storage account create --name $stagingSA --resource-group $stagingRG --location <vault-region> --sku Standard_LRS" Yellow
        $itemResult.Status = "SKIPPED"
        $itemResult.Detail = "Staging storage account '$stagingSA' does not exist (create it in the vault's region first)"
        return (Emit $itemResult)
    } else {
        Say "    WARNING: Could not verify staging SA (HTTP $sc) - continuing" Yellow
    }
}
if ($stagingObj -and $stagingObj.sku.name -match "ZRS") {
    Say "    SKIPPED: Staging SA '$stagingSA' is zone-redundant ($($stagingObj.sku.name)) - not supported for VM restore." Yellow
    $itemResult.Status = "SKIPPED"
    $itemResult.Detail = "Staging storage account is ZRS ($($stagingObj.sku.name)) - use an LRS/GRS account in the vault's region"
    return (Emit $itemResult)
}
if ($stagingObj) {
    try {
        $vaultRes = Invoke-RestRetry "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName`?api-version=2023-04-01" "GET" $headers
        if ($vaultRes.location -and ($stagingObj.location -ne $vaultRes.location)) {
            Say "    SKIPPED: Staging SA region '$($stagingObj.location)' != vault region '$($vaultRes.location)'." Yellow
            $itemResult.Status = "SKIPPED"
            $itemResult.Detail = "Staging SA region '$($stagingObj.location)' does not match vault region '$($vaultRes.location)'"
            return (Emit $itemResult)
        }
    } catch {
        Say "    NOTE: Could not read vault region for cross-check - continuing" Yellow
    }
}

if ($restoreType -ieq "AlternateLocation") {
    $targetResourceGroupId = "/subscriptions/$targetSub/resourceGroups/$targetRG"
    $targetVirtualMachineId = "$targetResourceGroupId/providers/Microsoft.Compute/virtualMachines/$targetVMName"
    $targetVNetId = "/subscriptions/$targetSub/resourceGroups/$targetVNetRG/providers/Microsoft.Network/virtualNetworks/$targetVNetName"
    $targetSubnetId = "$targetVNetId/subnets/$targetSubnetName"

    # Target RG must exist (governance object: never auto-created)
    try {
        Invoke-RestRetry "https://management.azure.com$targetResourceGroupId`?api-version=2021-04-01" "GET" $headers | Out-Null
        Say "    Target RG '$targetRG' exists" Gray
    } catch {
        $sc = $null; try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
        if ($sc -eq 404) {
            Say "    SKIPPED: Target resource group '$targetRG' does not exist (never auto-created - governance object)." Yellow
            Say "             Create it deliberately: az group create --name $targetRG --location $restoreRegion" Yellow
            $itemResult.Status = "SKIPPED"
            $itemResult.Detail = "Target RG '$targetRG' does not exist (az group create --name $targetRG --location $restoreRegion)"
            return (Emit $itemResult)
        } else {
            Say "    WARNING: Could not verify target RG (HTTP $sc) - continuing" Yellow
        }
    }

    # Target VM name must be FREE (the restore creates the VM)
    $vmNameTaken = $false
    try {
        Invoke-RestRetry "https://management.azure.com$targetVirtualMachineId`?api-version=2023-07-01" "GET" $headers | Out-Null
        $vmNameTaken = $true
    } catch {
        $sc = $null; try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
        if ($sc -eq 404) {
            Say "    Target VM name '$targetVMName' is available" Gray
        } else {
            Say "    WARNING: Could not verify target VM name (HTTP $sc) - continuing" Yellow
        }
    }
    if ($vmNameTaken) {
        Say "    SKIPPED: A VM named '$targetVMName' already exists in RG '$targetRG' - the restore CREATES the VM." Yellow
        $itemResult.Status = "SKIPPED"
        $itemResult.Detail = "Target VM name '$targetVMName' already in use in RG '$targetRG' - choose a free name"
        return (Emit $itemResult)
    }

    # Target VNet + subnet must exist (network objects: never auto-created)
    try {
        Invoke-RestRetry "https://management.azure.com$targetSubnetId`?api-version=2023-04-01" "GET" $headers | Out-Null
        Say "    Target VNet/subnet '$targetVNetName/$targetSubnetName' exists" Gray
    } catch {
        $sc = $null; try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
        if ($sc -eq 404) {
            Say "    SKIPPED: VNet '$targetVNetName' or subnet '$targetSubnetName' not found (VNet RG: '$targetVNetRG')." Yellow
            Say "             VNets are network-team objects - verify the names or have them provisioned, then re-run." Yellow
            $itemResult.Status = "SKIPPED"
            $itemResult.Detail = "VNet/subnet '$targetVNetName/$targetSubnetName' not found in RG '$targetVNetRG'"
            return (Emit $itemResult)
        } else {
            Say "    WARNING: Could not verify VNet/subnet (HTTP $sc) - continuing" Yellow
        }
    }
}

if ($restoreType -ieq "RestoreDisks" -and -not [string]::IsNullOrWhiteSpace($targetDiskRG)) {
    $targetDiskRGId = "/subscriptions/$targetSub/resourceGroups/$targetDiskRG"
    try {
        Invoke-RestRetry "https://management.azure.com$targetDiskRGId`?api-version=2021-04-01" "GET" $headers | Out-Null
        Say "    Disk target RG '$targetDiskRG' exists" Gray
    } catch {
        $sc = $null; try { $sc = $_.Exception.Response.StatusCode.value__ } catch { }
        if ($sc -eq 404) {
            Say "    SKIPPED: Disk target RG '$targetDiskRG' does not exist (az group create --name $targetDiskRG --location $restoreRegion)." Yellow
            $itemResult.Status = "SKIPPED"
            $itemResult.Detail = "Disk target RG '$targetDiskRG' does not exist"
            return (Emit $itemResult)
        } else {
            Say "    WARNING: Could not verify disk target RG (HTTP $sc) - continuing" Yellow
        }
    }
}

# ============================================================
# STEP B: Verify protected VM in vault (resolve real names)
# ============================================================
Say "  Step B: Verifying source VM is protected..." Cyan
$containerName = "iaasvmcontainer;iaasvmcontainerv2;$sourceVMRG;$sourceVMName"
$protectedItemName = "vm;iaasvmcontainerv2;$sourceVMRG;$sourceVMName"
$itemVerified = $false
try {
    $listUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupProtectedItems?api-version=$apiVersion&`$filter=backupManagementType eq 'AzureIaasVM'"
    $protectedItemsResponse = Invoke-RestRetry $listUri "GET" $headers
    $protectedItems = @($protectedItemsResponse.value)

    # Priority 1: exact sourceResourceId match (RG-safe)
    $matchingItem = $protectedItems | Where-Object {
        $_.properties.sourceResourceId -ieq $sourceResourceId
    } | Select-Object -First 1

    # Priority 2: friendlyName + RG in container name
    if (-not $matchingItem) {
        $matchingItem = $protectedItems | Where-Object {
            $_.properties.friendlyName -ieq $sourceVMName -and
            $_.id -imatch ";$([regex]::Escape($sourceVMRG.ToLower()));"
        } | Select-Object -First 1
    }

    # Priority 3: friendlyName only (warn - could be a same-named VM in another RG)
    if (-not $matchingItem) {
        $nameMatches = @($protectedItems | Where-Object { $_.properties.friendlyName -ieq $sourceVMName })
        if ($nameMatches.Count -eq 1) {
            $matchingItem = $nameMatches[0]
            Say "    WARNING: Matched by VM name only (RG not confirmed) - verify the result" Yellow
        }
    }

    if ($matchingItem -and $matchingItem.id -match '/protectionContainers/([^/]+)/protectedItems/([^/]+)$') {
        $containerName = $matches[1]
        $protectedItemName = $matches[2]
        if ($matchingItem.properties.sourceResourceId) { $sourceResourceId = $matchingItem.properties.sourceResourceId }
        $itemVerified = $true
        Say "    Protected VM verified (State: $($matchingItem.properties.protectionState) | Last backup: $($matchingItem.properties.lastBackupStatus))" Green
    } else {
        Say "    FAILED: VM '$sourceVMName' (RG: $sourceVMRG) not found as a protected item in vault '$vaultName'" Red
    }
} catch {
    Say "    FAILED: Could not list protected items - $($_.Exception.Message)" Red
}

if (-not $itemVerified) {
    $itemResult.Status = "FAILED"
    $itemResult.Detail = "Source VM not found as a protected item in the vault"
    return (Emit $itemResult)
}

# ============================================================
# STEP C: Select recovery point
# ============================================================
Say "  Step C: Selecting recovery point ($recoveryPointChoice)..." Cyan
$recoveryPointId = $null
$isCrossRegion = ($restoreRegion.ToLower() -ne $datasourceRegion.ToLower())
try {
    $rpUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName/recoveryPoints?api-version=$apiVersion"
    $rpResponse = Invoke-RestRetry $rpUri "GET" $headers
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

# ============================================================
# STEP D: Build restore request body
# ============================================================
Say "  Step D: Building restore request..." Cyan
$requestProperties = @{
    objectType                   = "IaasVMRestoreRequest"
    recoveryPointId              = $recoveryPointId
    recoveryType                 = $restoreType
    sourceResourceId             = $sourceResourceId
    storageAccountId             = $storageAccountId
    region                       = $restoreRegion
    createNewCloudService        = $false
    originalStorageAccountOption = $false
    encryptionDetails            = @{ encryptionEnabled = $false }
}

switch ($restoreType) {
    "RestoreDisks" {
        if (-not [string]::IsNullOrWhiteSpace($targetDiskRG)) {
            $requestProperties.targetResourceGroupId = "/subscriptions/$targetSub/resourceGroups/$targetDiskRG"
        }
        if ($isCrossRegion) {
            Say "    Cross-region restore: preferredRecoveryPointTier = HardenedRP (vault tier)" Yellow
            $requestProperties.preferredRecoveryPointTier = "HardenedRP"
        }
    }
    "OriginalLocation" {
        $requestProperties.targetDomainNameId = $null
        $requestProperties.targetResourceGroupId = $null
        $requestProperties.targetVirtualMachineId = $null
        $requestProperties.virtualNetworkId = $null
        $requestProperties.subnetId = $null
        $requestProperties.diskEncryptionSetId = $null
        $requestProperties.affinityGroup = ""
    }
    "AlternateLocation" {
        $requestProperties.targetVirtualMachineId = $targetVirtualMachineId
        $requestProperties.targetResourceGroupId = $targetResourceGroupId
        $requestProperties.virtualNetworkId = $targetVNetId
        $requestProperties.subnetId = $targetSubnetId
        if ($isCrossRegion) {
            Say "    Cross-region restore: preferredRecoveryPointTier = HardenedRP (vault tier)" Yellow
            $requestProperties.preferredRecoveryPointTier = "HardenedRP"
        }
    }
}

$requestBody = @{ properties = $requestProperties } | ConvertTo-Json -Depth 10

# ============================================================
# STEP E: Trigger restore, poll until the JOB is created
# ============================================================
Say "  Step E: Triggering restore..." Cyan
$restoreUri = "https://management.azure.com/subscriptions/$vaultSubscriptionId/resourceGroups/$vaultResourceGroup/providers/Microsoft.RecoveryServices/vaults/$vaultName/backupFabrics/Azure/protectionContainers/$containerName/protectedItems/$protectedItemName/recoveryPoints/$recoveryPointId/restore?api-version=$apiVersion"
try {
    $restoreResponse = Invoke-WebRequest -Uri $restoreUri -Method POST -Headers $headers -Body $requestBody -UseBasicParsing
    if ($restoreResponse.StatusCode -eq 202) {
        Say "    Restore accepted (202)" Green
        $azureAsyncHeader = $restoreResponse.Headers["Azure-AsyncOperation"] | Select-Object -First 1
        if (-not $azureAsyncHeader) { $azureAsyncHeader = $restoreResponse.Headers["Location"] | Select-Object -First 1 }
        if ($azureAsyncHeader) {
            # Poll the TRIGGER operation only (completes in ~1-2 min when the
            # restore job is created). The restore itself runs for hours -
            # deliberately NOT tracked here (see IMPORTANT note in header).
            $maxRetries = 20
            $retryCount = 0
            $finalStatus = "InProgress"
            while ($retryCount -lt $maxRetries) {
                Start-Sleep -Seconds 15
                try {
                    $statusResponse = Invoke-RestMethod -Uri $azureAsyncHeader -Method GET -Headers $headers
                    $finalStatus = $statusResponse.status
                    if ($finalStatus -eq "Succeeded") {
                        if ($statusResponse.properties.jobId) { $itemResult.JobId = $statusResponse.properties.jobId }
                        break
                    } elseif ($finalStatus -eq "Failed") {
                        $errDetail = if ($statusResponse.error) { ($statusResponse.error | ConvertTo-Json -Depth 5 -Compress) } else { "Unknown error" }
                        $itemResult.Detail = "Restore trigger failed: $errDetail"
                        break
                    } else {
                        $retryCount++
                        Say "    Trigger status: $finalStatus ($retryCount/$maxRetries)" Yellow
                    }
                } catch {
                    $retryCount++
                    Say "    Polling trigger... ($retryCount/$maxRetries)" Yellow
                }
            }
            if ($finalStatus -eq "Succeeded") {
                $itemResult.Status = "TRIGGERED"
                $itemResult.Detail = "Restore JOB TRIGGERED - track JobId in Portal (restore itself may run for hours)"
                Say "    Restore job triggered (JobId: $($itemResult.JobId))" Green
            } elseif ($finalStatus -eq "Failed") {
                $itemResult.Status = "FAILED"
                Say "    Restore trigger FAILED: $($itemResult.Detail)" Red
            } else {
                $itemResult.Status = "PENDING"
                $itemResult.Detail = "Restore accepted; trigger tracking timed out. Check Backup Jobs in portal."
                Say "    Trigger still in progress - check Azure Portal (Backup Jobs)" Yellow
            }
        } else {
            $itemResult.Status = "PENDING"
            $itemResult.Detail = "Restore accepted (202); no tracking header. Check Backup Jobs in portal."
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
Write-Host "  Starting Bulk VM Restore" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

$results = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
$totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$useSourceNameFlag = [bool]$UseSourceNameIfEmpty
$allowOlrFlag = [bool]$AllowOriginalLocation

if ($useParallel) {
    $indexed = for ($i = 0; $i -lt $csvData.Count; $i++) { [pscustomobject]@{ Row = $csvData[$i]; Index = $i + 1 } }
    $indexed | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        $pi = $_
        try {
            $sb = [scriptblock]::Create($using:workerText)
            $r = & $sb $pi.Row $pi.Index $using:totalItems $using:headers $using:apiVersion $using:useSourceNameFlag $using:allowOlrFlag
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
            $r = & $sb $row $i $totalItems $headers $apiVersion $useSourceNameFlag $allowOlrFlag
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
$triggeredCount = @($resArr | Where-Object { $_.Status -eq "TRIGGERED" }).Count
$failedCount  = @($resArr | Where-Object { $_.Status -eq "FAILED" }).Count
$skippedCount = @($resArr | Where-Object { $_.Status -eq "SKIPPED" }).Count
$pendingCount = @($resArr | Where-Object { $_.Status -eq "PENDING" }).Count

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk VM Restore - Summary" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Metrics:" -ForegroundColor Yellow
Write-Host "  Total Items:      $totalItems" -ForegroundColor White
Write-Host "  Jobs Triggered:   $triggeredCount" -ForegroundColor Green
Write-Host "  Failed:           $failedCount" -ForegroundColor $(if ($failedCount -gt 0) { "Red" } else { "White" })
Write-Host "  Pending:          $pendingCount" -ForegroundColor $(if ($pendingCount -gt 0) { "Yellow" } else { "White" })
Write-Host "  Skipped:          $skippedCount" -ForegroundColor $(if ($skippedCount -gt 0) { "Yellow" } else { "White" })
Write-Host "  Total Duration:   $([math]::Round($totalStopwatch.Elapsed.TotalSeconds, 1))s ($([math]::Round($totalStopwatch.Elapsed.TotalMinutes, 1)) min)" -ForegroundColor White
Write-Host ""

# Results table
Write-Host "Results:" -ForegroundColor Yellow
Write-Host ""
Write-Host ("{0,-4} {1,-24} {2,-28} {3,-9} {4,-9} {5}" -f "#", "Source VM", "Target", "Status", "Duration", "Detail") -ForegroundColor Cyan
Write-Host ("{0,-4} {1,-24} {2,-28} {3,-9} {4,-9} {5}" -f ("-" * 4), ("-" * 24), ("-" * 28), ("-" * 9), ("-" * 9), ("-" * 30)) -ForegroundColor Gray

$rowNum = 1
foreach ($r in $resArr) {
    $statusColor = switch ($r.Status) { "TRIGGERED" { "Green" } "FAILED" { "Red" } "SKIPPED" { "Yellow" } "PENDING" { "Yellow" } default { "White" } }
    Write-Host ("{0,-4} {1,-24} {2,-28} {3,-9} {4,-9} {5}" -f $rowNum, $r.Item, $r.Target, $r.Status, $r.Duration, $r.Detail) -ForegroundColor $statusColor
    $rowNum++
}

Write-Host ""

# Export results to CSV
$outputCsvPath = $CsvPath -replace '\.csv$', '_Results.csv'
$resArr | Select-Object Item, Target, RestoreType, Status, JobId, Detail, Duration | Export-Csv -Path $outputCsvPath -NoTypeInformation -Force
Write-Host "Results exported to: $outputCsvPath" -ForegroundColor Gray
Write-Host ""

if ($triggeredCount -gt 0) {
    Write-Host "NOTE: TRIGGERED = restore JOB CREATED. The restores themselves are now running and can" -ForegroundColor Yellow
    Write-Host "      take hours (far-region restores ~2.5-3x slower; large VMs 15-45 hrs)." -ForegroundColor Yellow
    Write-Host "      Track the JobId column in: Azure Portal -> Recovery Services Vault -> Backup Jobs." -ForegroundColor Yellow
    Write-Host ""
}

if ($failedCount -gt 0) {
    Write-Host "WARNING: $failedCount item(s) failed. Check the results above for details." -ForegroundColor Yellow
    Write-Host "Possible causes:" -ForegroundColor Yellow
    Write-Host "  1. Source VM not backed up (protected) in the vault" -ForegroundColor White
    Write-Host "  2. Recovery point name not found / no recovery points available" -ForegroundColor White
    Write-Host "  3. Insufficient RBAC permissions on vault / target resources" -ForegroundColor White
    Write-Host "  4. Encrypted VM (ADE) - not supported for ROC backup/restore" -ForegroundColor White
    Write-Host ""
}

if ($skippedCount -gt 0) {
    Write-Host "NOTE: $skippedCount item(s) were SKIPPED because the CSV is followed strictly." -ForegroundColor Yellow
    Write-Host "Check the Detail column above (and in the _Results.csv). Common reasons and fixes:" -ForegroundColor Yellow
    Write-Host "  - Empty TargetVMName              -> fill it in the CSV, or re-run with -UseSourceNameIfEmpty" -ForegroundColor White
    Write-Host "  - Target VM name already in use   -> pick a free name (the restore CREATES the VM)" -ForegroundColor White
    Write-Host "  - Target RG / VNet does not exist -> create them deliberately (governance objects), then re-run" -ForegroundColor White
    Write-Host "  - Staging SA missing/wrong region -> create an LRS account in the VAULT's region" -ForegroundColor White
    Write-Host "  - OriginalLocation row            -> requires the -AllowOriginalLocation switch (deliberate opt-in)" -ForegroundColor White
    Write-Host "  TIP: When re-running, keep only the skipped rows in the CSV - re-running the full" -ForegroundColor Gray
    Write-Host "       file would trigger the successful restores again." -ForegroundColor Gray
    Write-Host ""
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Bulk VM Restore Script Execution Completed" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
