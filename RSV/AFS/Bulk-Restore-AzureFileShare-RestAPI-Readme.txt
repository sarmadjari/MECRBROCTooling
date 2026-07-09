================================================================================
  Bulk-Restore-AzureFileShare-RestAPI.ps1 - README
================================================================================

DESCRIPTION
-----------
Bulk restores multiple backed-up Azure File Shares from a CSV file using the
Azure Backup REST API. Uses the same per-item flow as
Restore-AzureFileShare-RestAPI.ps1, but non-interactively (each restore's
options come from CSV columns instead of prompts).

Per-item steps:
  1. Verifies the source file share is a protected item in the vault (and
     resolves the real container / protected-item names).
  2. Fetches recovery points and selects one (latest, or a named recovery point).
  3. Builds the AzureFileShareRestoreRequest body.
  4. Triggers the restore (POST) and tracks the async operation to completion.

Additional features:
  - Preview table of all restores before execution.
  - Single confirmation prompt before the batch runs.
  - Per-item duration tracking.
  - Summary table with SUCCESS / FAILED / PENDING / SKIPPED counts.
  - Captures the restore Job ID (when returned) for portal tracking.
  - Results exported to a _Results.csv file.


PARALLELISM
-----------
The script processes CSV rows concurrently, bounded by -MaxParallel:

  -MaxParallel <n>   Maximum restores to run at once. Default 5. Use 1 to force
                     sequential processing.

  - Parallel execution requires PowerShell 7+. On Windows PowerShell 5.1 the
    script automatically falls back to SEQUENTIAL (the -MaxParallel value is
    ignored, with a notice).
  - REST calls retry automatically with backoff on HTTP 429 (throttling).
  - The chosen mode (PARALLEL / SEQUENTIAL) is printed before the run starts.
  - In parallel mode, per-item log lines are prefixed with [i/total] so the
    interleaved output stays attributable to each restore.
  - Note: concurrent restores into the SAME target storage account may compete
    for storage throughput; spread heavy restores across target accounts or
    lower -MaxParallel if needed.

How -MaxParallel works (technically):
  - It maps directly to ForEach-Object -Parallel -ThrottleLimit <n> in
    PowerShell 7. Each item runs in its own runspace (an isolated PowerShell
    context on a thread from a pool, inside the SAME process - not a separate
    process).
  - It is a ROLLING cap, NOT a fixed batch: at most <n> items run at any instant,
    and as soon as one finishes the next queued item starts. It does NOT mean
    "run 5, wait for all 5 to finish, then start the next 5."
  - Runspaces are isolated; they share only the auth token/headers and a
    thread-safe results collection. Counts are tallied after all items complete.
  - Parallelism overlaps the WAITING (REST round-trips + status polling); it does
    not make Azure's server-side restore copy itself run faster.
  - Higher values mean more simultaneous REST calls and higher HTTP 429
    (throttling) risk, which is why the default is a conservative 5.


IMPORTANT — AFS Vaulted Policy Restore Support:
  1. Only ALR (Alternate Location) restore is released in production. ILR and
     OLR are not released yet for the vaulted policy.
  2. The target folder must be empty (restore to root).
  3. The Copy Option must be Overwrite only.
  Restore operations overwrite/modify target data and CANNOT be undone.


WHERE TO RUN
------------
- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, or Linux).
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- The script prompts once for confirmation before executing the batch.


DEPENDENCIES
------------
You need ONE of the following for authentication:

  Option A — Azure PowerShell Module (Az)
    Install-Module -Name Az -Scope CurrentUser -Force
    Connect-AzAccount

  Option B — Azure CLI
    https://learn.microsoft.com/en-us/cli/azure/install-azure-cli
    az login

No other modules or packages are required.


REQUIRED PERMISSIONS (RBAC)
---------------------------
- Backup Operator (or equivalent) on the Recovery Services Vault.
- Contributor on the target Storage Account (Alternate Location scenario).
- Reader on the source Storage Account.


CSV FORMAT
----------
File: Bulk-Restore-AzureFileShare-RestAPI_Input.csv

  Header row required. Columns:
    VaultSubscriptionId                  Subscription ID of the Recovery Services Vault
    VaultResourceGroup                   Resource group of the vault
    VaultName                            Name of the vault
    SourceStorageAccountSubscriptionId   Subscription ID of the SOURCE storage account
                                         (leave empty to use vault subscription)
    SourceStorageAccountResourceGroup    Resource group of the source storage account
    SourceStorageAccountName             Name of the source (backed-up) storage account
    SourceFileShareName                  Name of the source (backed-up) file share
    RestoreType                          FullShareRestore | ItemLevelRestore
                                         (empty = FullShareRestore)
    RecoveryType                         AlternateLocation | OriginalLocation
                                         (empty = AlternateLocation)
    CopyOptions                          Overwrite | Skip | FailOnConflict
                                         (empty = Overwrite)
    RecoveryPoint                        latest | <recovery point name>
                                         (empty = latest)
    TargetStorageAccountSubscriptionId   Subscription ID of the TARGET storage account
                                         (empty = source subscription) [ALR only]
    TargetStorageAccountResourceGroup    Resource group of the target storage account [ALR only]
    TargetStorageAccountName             Name of the target storage account [ALR only]
    TargetFileShareName                  Name of the target file share [ALR only]
    TargetFolderPath                     Optional target folder (empty = root) [ALR only]
    ItemPaths                            Semicolon-separated paths for ItemLevelRestore,
                                         each "File:path" or "Folder:path"
                                         (e.g. "File:reports/q4.xlsx;Folder:logs/")

  Notes:
    - For AlternateLocation restores, the Target* columns are required.
    - For OriginalLocation restores, the Target* columns are ignored.
    - For ItemLevelRestore, ItemPaths is required.
    - An entry in ItemPaths with no "File:"/"Folder:" prefix is treated as a File.

  Example (cross-region full-share ALR to latest recovery point):
    VaultSubscriptionId,VaultResourceGroup,VaultName,SourceStorageAccountSubscriptionId,SourceStorageAccountResourceGroup,SourceStorageAccountName,SourceFileShareName,RestoreType,RecoveryType,CopyOptions,RecoveryPoint,TargetStorageAccountSubscriptionId,TargetStorageAccountResourceGroup,TargetStorageAccountName,TargetFileShareName,TargetFolderPath,ItemPaths
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-swedencentral,rsv-dr-swedencentral,,rg-storage-uaenorth,stgfilesuaenorth01,finance-data,FullShareRestore,AlternateLocation,Overwrite,latest,,rg-storage-swedencentral,stgrestoreswe01,finance-data-restored,,


HOW TO RUN
----------
  With parameter:
    .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -CsvPath "C:\inputs\restores.csv"

  With parallelism control (default 5):
    .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -CsvPath ".\restores.csv" -MaxParallel 5

  Sequential (one at a time):
    .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -CsvPath ".\restores.csv" -MaxParallel 1

  Without parameter (prompts or uses default):
    .\Bulk-Restore-AzureFileShare-RestAPI.ps1

  The default CSV path is Bulk-Restore-AzureFileShare-RestAPI_Input.csv in the
  same directory as the script.


API VERSION USED
----------------
  - 2025-08-01   All operations (protected items, recovery points, restore)


RESULT STATUSES
---------------
  SUCCESS  — Restore triggered and the async operation reported 'Succeeded'.
  PENDING  — Restore accepted (202) but tracking timed out (or no async header).
             The restore is likely running; verify on Azure Portal.
  FAILED   — An error occurred (source not protected, recovery point not found,
             invalid target, unsupported option, or the async op reported
             'Failed'). The Detail column shows the specific error.
  SKIPPED  — Missing required source/vault fields, or missing target fields for
             an AlternateLocation restore.


EXAMPLES
--------

Example 1 — Bulk cross-region full-share restore (UAE North -> Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -CsvPath ".\my-restores.csv"

  Each row restores the latest recovery point of a source share (backed up in
  the ROC vault) to a target storage account in the target region.


Example 2 — Use default CSV file
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Restore-AzureFileShare-RestAPI.ps1

  Prompts for CSV path. Press Enter to use the default
  Bulk-Restore-AzureFileShare-RestAPI_Input.csv in the script directory.


Example 3 — Item Level Restore of specific files/folders
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  Set RestoreType = ItemLevelRestore and provide ItemPaths, e.g.:
    File:reports/q4.xlsx;Folder:logs/

  (ILR is not released for the AFS vaulted policy; use for snapshot-tier only.)


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Bulk-Restore-AzureFileShare-RestAPI.ps1 -CsvPath ".\my-restores.csv"

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
Console output:
  - Preview table of all restores
  - Per-item step-by-step progress (Steps A through D)
  - Color-coded results: Green (SUCCESS), Red (FAILED), Yellow (PENDING/SKIPPED)
  - Summary metrics: total, succeeded, failed, pending, skipped, total duration
  - Results table

Results CSV:
  - Exported to {InputFileName}_Results.csv
  - Columns: Item, Target, RecoveryType, Status, JobId, Detail, Duration


ERROR HANDLING
--------------
Per-item errors are caught and logged — they do not stop the script.
The script continues to the next CSV row after any failure.


PUBLIC DOCUMENTATION
--------------------
  Restore Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/restore-azure-file-share-rest-api

  Backup Restores REST API Reference:
    https://learn.microsoft.com/en-us/rest/api/backup/restores

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

================================================================================
