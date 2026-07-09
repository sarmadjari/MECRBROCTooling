================================================================================
  Bulk-Register-StorageAccount-ToVault.ps1 - README
================================================================================

DESCRIPTION
-----------
Bulk registers multiple Azure Storage Accounts (containing Azure File Shares) to
a Recovery Services Vault from a CSV file using the Azure Backup REST API. Uses
the same per-item flow as Register-StorageAccount-ToVault.ps1.

Registration is the FIRST step before configuring file share backup protection.
Once a storage account is registered, its file shares can be protected with
Configure-FileShare-Protection.ps1 (single) or
Bulk-Configure-FileShare-Protection.ps1 (bulk).

Per-item steps:
  1. Refreshes container discovery for the vault (done once per unique vault).
  2. Checks current registration status (skips if already Registered).
  3. Registers the storage account to the vault (PUT).
  4. Polls/verifies registration status (SUCCESS, PENDING, or FAILED).

Additional features:
  - Preview table of all items before execution.
  - Idempotent: storage accounts already registered are SKIPPED, not re-registered.
  - Discovery refresh runs only once per unique vault (efficient for large CSVs).
  - Per-item duration tracking.
  - Summary table with SUCCESS / FAILED / PENDING / SKIPPED counts.
  - Results exported to a _Results.csv file.


PARALLELISM
-----------
The script processes CSV rows concurrently, bounded by -MaxParallel:

  -MaxParallel <n>   Maximum storage accounts to register at once. Default 5.
                     Use 1 to force sequential processing.

  - Parallel execution requires PowerShell 7+. On Windows PowerShell 5.1 the
    script automatically falls back to SEQUENTIAL (the -MaxParallel value is
    ignored, with a notice).
  - Container discovery is refreshed ONCE per unique vault up front (before the
    parallel loop), so concurrent workers do not repeat it.
  - REST calls retry automatically with backoff on HTTP 429 (throttling).
  - The chosen mode (PARALLEL / SEQUENTIAL) is printed before the run starts.
  - In parallel mode, per-item log lines are prefixed with [i/total] so the
    interleaved output stays attributable to each storage account.

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
    not make Azure's server-side registration itself run faster.
  - Higher values mean more simultaneous REST calls and higher HTTP 429
    (throttling) risk, which is why the default is a conservative 5.


WHERE TO RUN
------------
- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, or Linux).
- Run from any terminal: PowerShell console, Windows Terminal, VS Code terminal,
  or Azure Cloud Shell.
- The script prompts for confirmation before executing.


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
- Backup Contributor (or equivalent) on the Recovery Services Vault.
- Reader (or equivalent) on the Storage Account(s).
- For cross-subscription registration, the above on the respective subscriptions.


CSV FORMAT
----------
File: Bulk-Register-StorageAccount-ToVault_Input.csv

  Header row required. Columns:
    VaultSubscriptionId              Subscription ID of the Recovery Services Vault
    VaultResourceGroup               Resource group of the vault
    VaultName                        Name of the vault
    StorageAccountSubscriptionId     Subscription ID of the storage account
                                     (leave empty to use vault subscription)
    StorageAccountResourceGroup      Resource group of the storage account
    StorageAccountName               Name of the storage account

  Example:
    VaultSubscriptionId,VaultResourceGroup,VaultName,StorageAccountSubscriptionId,StorageAccountResourceGroup,StorageAccountName
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-prod,rsv-prod-eastus,,rg-storage-prod,stgfileshare01
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-prod,rsv-prod-eastus,,rg-storage-prod,stgfileshare02


HOW TO RUN
----------
  With parameter:
    .\Bulk-Register-StorageAccount-ToVault.ps1 -CsvPath "C:\inputs\storageaccounts.csv"

  With parallelism control (default 5):
    .\Bulk-Register-StorageAccount-ToVault.ps1 -CsvPath ".\storageaccounts.csv" -MaxParallel 5

  Sequential (one at a time):
    .\Bulk-Register-StorageAccount-ToVault.ps1 -CsvPath ".\storageaccounts.csv" -MaxParallel 1

  Without parameter (prompts or uses default):
    .\Bulk-Register-StorageAccount-ToVault.ps1

  The default CSV path is Bulk-Register-StorageAccount-ToVault_Input.csv in the
  same directory as the script.


API VERSION USED
----------------
  - 2025-08-01   All operations (refresh discovery, container status, registration)


RESULT STATUSES
---------------
  SUCCESS  — Registration PUT accepted and verification confirmed status
             'Registered'.
  PENDING  — Registration PUT accepted but verification timed out. The
             registration is likely complete; verify on Azure Portal.
  FAILED   — An error occurred (storage account already registered to another
             vault, insufficient permissions, invalid resource ID, etc.). The
             Detail column shows the specific error.
  SKIPPED  — Storage account is already registered to the vault, OR the CSV row
             is missing required fields.


EXAMPLES
--------

Example 1 — Bulk register multiple storage accounts (same region)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Register-StorageAccount-ToVault.ps1 -CsvPath ".\my-storageaccounts.csv"

  The script loads the CSV, previews all items in a table, asks for
  confirmation, then processes each item sequentially.


Example 2 — Use default CSV file
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> .\Bulk-Register-StorageAccount-ToVault.ps1

  Prompts for CSV path. Press Enter to use the default
  Bulk-Register-StorageAccount-ToVault_Input.csv in the script directory.


Example 3 — Cross-region (storage in UAE North, vault in Sweden Central)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  CSV rows can reference storage accounts in different regions/subscriptions
  than the vault (the Region-of-Choice scenario).

  Example CSV row:
    aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee,rg-backup-swedencentral,rsv-dr-swedencentral,,rg-storage-uaenorth,stgfilesuaenorth01

  The storage account is in UAE North (uaenorth) while the vault is in
  Sweden Central (swedencentral).


Example 4 — Using Azure CLI for authentication
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  PS> az login
  PS> .\Bulk-Register-StorageAccount-ToVault.ps1 -CsvPath ".\my-storageaccounts.csv"

  If Azure PowerShell (Az module) is not installed, the script
  automatically falls back to Azure CLI for token acquisition.


OUTPUT
------
Console output:
  - Preview table of all items
  - Per-item step-by-step progress (Steps A through D)
  - Color-coded results: Green (SUCCESS), Red (FAILED), Yellow (PENDING/SKIPPED)
  - Summary metrics: total, succeeded, failed, pending, skipped, total duration
  - Results table

Results CSV:
  - Exported to {InputFileName}_Results.csv
  - Columns: Item, ResourceGroup, Vault, Status, RegistrationStatus, Detail, Duration


ERROR HANDLING
--------------
Per-item errors are caught and logged — they do not stop the script.

Common per-item failures:
  - Storage account already registered to a DIFFERENT vault (a storage account
    can only be registered to one vault at a time)
  - Insufficient permissions on storage account or vault
  - Storage account does not exist or the resource ID is incorrect
  - Cross-subscription registration blocked by policy

The script continues to the next CSV row after any failure.


WORKFLOW CONTEXT
----------------
Registration is step 1 of the Azure Files backup workflow:

  1. Bulk-Register-StorageAccount-ToVault.ps1   <-- (this script)
  2. Bulk-Configure-FileShare-Protection.ps1    (protect the file shares)

  For Cross-Region Backup (ROC), configure protection with a 'Vault-Standard'
  policy and protect file shares in batches of 5 at a time.


PUBLIC DOCUMENTATION
--------------------
  Back up Azure File Shares with REST API:
    https://learn.microsoft.com/en-us/azure/backup/backup-azure-file-share-rest-api

  Protection Containers - Register (REST API reference):
    https://learn.microsoft.com/en-us/rest/api/backup/protection-containers/register

  Azure REST API Authentication (Bearer token):
    https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request

================================================================================
