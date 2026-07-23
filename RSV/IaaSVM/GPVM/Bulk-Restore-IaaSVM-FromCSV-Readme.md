# Bulk-Restore-IaaSVM-FromCSV.ps1 — README

## Description

Bulk restores multiple backed-up Azure IaaS VMs from a CSV file using the
Azure Backup REST API. Uses the same per-item flow as
`Restore-IaaSVM-RestAPI.ps1`, but non-interactively (each restore's options
come from CSV columns instead of prompts).

Per-item steps:

1. **Validate the CSV row** (strict — see philosophy below) and **pre-flight
   check the environment** — nothing is mutated if a precondition fails.
2. Verify the source VM is a protected item in the vault (resolves the real
   container / protected-item names, RG-safe matching).
3. Fetch recovery points and select one (latest, or a named recovery point).
4. Build the `IaasVMRestoreRequest` body and trigger the restore (POST).
5. Poll the async **trigger** operation until the restore **job is created**,
   then capture the Job ID.

> ### IMPORTANT — what TRIGGERED means
> **A row's end status is `TRIGGERED` when the restore JOB WAS CREATED
> (Job ID captured) — not when the restore finished.** VM restores run for a
> long time — a far-region (ROC) restore is ~2.5–3× slower than same-region,
> and large VMs can take 15–45 hours. The script deliberately does not wait.
> Track the `JobId` column from the results CSV in:
> **Azure Portal → Recovery Services Vault → Backup Jobs.**

## Supported restore paths (ROC support matrix)

All three restore paths from the official ROC support matrix are supported:

| Path | Tier used | Typical scenario |
|---|---|---|
| Source → source region | Snapshot tier | Fast recovery in the source region (snapshots live with the VM) |
| ROC vault → source region | Vault tier | "Restore to Primary Region" — recover in UAE North from the ROC vault |
| ROC vault → ROC region | Vault tier | DR into the ROC region (e.g. Sweden Central) |

When `RestoreRegion` ≠ `DatasourceRegion` the script automatically sets
`preferredRecoveryPointTier = HardenedRP` (vault tier) — snapshot-tier
recovery points cannot be used across regions.

**Not for Confidential VMs**: CVM restores need `securedVmDetails` — use
`RSV\IaaSVM\CVM\Restore-IaaSVM-CVM-RestAPI.ps1`. Note that CVM + CMK in Azure
Key Vault cannot cross-region restore (keys must be migrated to mHSM first).
ADE-encrypted VMs are not supported for ROC backup at all.

## Strict-CSV philosophy / automation switches

By default the script follows the CSV 100% and expects the target
environment to be ready. Any row that does not meet a precondition is
**SKIPPED and clearly reported** (console + `_Results.csv`) — the script
never guesses, because an empty cell or a missing resource may be a mistake:

| Precondition failure | Default behavior |
|---|---|
| Empty `TargetVMName` (AlternateLocation) | SKIPPED — or use `-UseSourceNameIfEmpty` |
| Target VM name already in use | SKIPPED (the restore **creates** the VM — name must be free) |
| Target resource group does not exist | SKIPPED — create it deliberately (`az group create` shown in report) |
| Target VNet / subnet does not exist | SKIPPED — network-team objects, never auto-created |
| Staging storage account missing / wrong region / ZRS | SKIPPED — must be LRS/GRS in the **vault's** region |
| `RestoreType=OriginalLocation` without the switch | SKIPPED — needs `-AllowOriginalLocation` |

### `-UseSourceNameIfEmpty` (opt-in)

AlternateLocation rows with an empty `TargetVMName` use the **source VM
name** as the new VM name instead of being skipped. Everything else stays
strict.

### `-AllowOriginalLocation` (opt-in, double-gated)

`OriginalLocation` **replaces the disks of the existing source VM in-place**
— the VM restarts and its current disk state is destroyed. Because that is
the most destructive operation in the toolkit, it requires a **double
opt-in**:

1. the `-AllowOriginalLocation` switch on the command line, **and**
2. the CSV row **explicitly** saying `OriginalLocation` (an empty
   `RestoreType` cell always defaults to `AlternateLocation`, never OLR).

A CSV mistake alone cannot trigger it; the switch alone cannot either.
OLR rows additionally require `RestoreRegion == DatasourceRegion` (in-place
restore cannot cross regions). Legitimate use case: mass rollback in the
source region after corruption/ransomware (snapshot tier for speed, or vault
tier from the ROC vault).

### Never auto-created

Resource groups and VNets are **governance objects** (tags, RBAC, policy,
address space) — the script validates them and reports the exact command or
action needed, but never creates them. This differs deliberately from the
AFS bulk restore script, which can auto-create file *shares* (data-plane
objects inside an already-governed storage account).

## Parallelism

- `-MaxParallel <n>` — maximum concurrent restore **triggers** (default 3;
  VM restores are heavy and each trigger spawns an hours-long server-side
  job). Requires PowerShell 7+; Windows PowerShell 5.1 falls back to
  sequential. Use 1 to force sequential.
- REST calls retry automatically with backoff on HTTP 429 (throttling).
- Per-item log lines are prefixed `[i/total]` so parallel output stays
  attributable.

## Where to run

- Windows PowerShell 5.1 or PowerShell 7+ (Windows, macOS, Linux).
- The script prompts once for confirmation before executing the batch.

## Dependencies

ONE of the following for authentication:

- **Azure PowerShell**: `Install-Module Az` + `Connect-AzAccount`
- **Azure CLI**: `az login`

No other modules required (pure REST via `Invoke-RestMethod`/`Invoke-WebRequest`).

## Required permissions (RBAC)

- Backup Operator (or equivalent) on the Recovery Services Vault.
- Contributor on the target resource group / VNet scope (AlternateLocation).
- Reader + join permissions as applicable on the staging storage account.

## CSV format

File: `Bulk-Restore-IaaSVM-FromCSV_Input.csv` (header row required)

| Column | Description |
|---|---|
| `VaultSubscriptionId` | Subscription of the Recovery Services Vault |
| `VaultResourceGroup` | Resource group of the vault |
| `VaultName` | Name of the vault |
| `SourceVMName` | Name of the source (backed-up) VM |
| `SourceVMResourceGroup` | Resource group of the source VM |
| `SourceVMSubscriptionId` | Subscription of the source VM (empty = vault subscription) |
| `RestoreType` | `RestoreDisks` \| `AlternateLocation` \| `OriginalLocation` (empty = AlternateLocation) |
| `RecoveryPoint` | `latest` \| recovery point name (empty = latest) |
| `DatasourceRegion` | Region of the SOURCE VM, e.g. `uaenorth` — **required** |
| `RestoreRegion` | Region to restore INTO, e.g. `swedencentral` — **required** |
| `StagingStorageAccountSubscriptionId` | Empty = vault subscription |
| `StagingStorageAccountResourceGroup` | RG of the staging storage account — **required** |
| `StagingStorageAccountName` | Staging account (must be in the **vault's** region, not ZRS) — **required** |
| `TargetVMName` | New VM name [ALR — **required**; empty ⇒ SKIPPED unless `-UseSourceNameIfEmpty`] |
| `TargetResourceGroup` | RG for the new VM [ALR — **required**; must already exist] |
| `TargetSubscriptionId` | Empty = vault subscription |
| `TargetVNetName` | Target virtual network [ALR — **required**; must already exist] |
| `TargetVNetResourceGroup` | Empty = `TargetResourceGroup` |
| `TargetSubnetName` | Target subnet [ALR — **required**; must already exist] |
| `TargetDiskResourceGroup` | Optional RG for restored managed disks [RestoreDisks only] |

Example (cross-region ALR + a RestoreDisks row):

```csv
VaultSubscriptionId,VaultResourceGroup,VaultName,SourceVMName,SourceVMResourceGroup,SourceVMSubscriptionId,RestoreType,RecoveryPoint,DatasourceRegion,RestoreRegion,StagingStorageAccountSubscriptionId,StagingStorageAccountResourceGroup,StagingStorageAccountName,TargetVMName,TargetResourceGroup,TargetSubscriptionId,TargetVNetName,TargetVNetResourceGroup,TargetSubnetName,TargetDiskResourceGroup
aaaa...,rg-backup-swedencentral,rsv-dr-swedencentral,app-vm-01,rg-app-uaenorth,,AlternateLocation,latest,uaenorth,swedencentral,,rg-staging-swedencentral,stgstagingswe01,app-vm-01-dr,rg-dr-swedencentral,,vnet-dr-swedencentral,rg-network-swedencentral,snet-workloads,
aaaa...,rg-backup-swedencentral,rsv-dr-swedencentral,db-vm-02,rg-db-uaenorth,,RestoreDisks,latest,uaenorth,swedencentral,,rg-staging-swedencentral,stgstagingswe01,,,,,,,rg-restoreddisks-swedencentral
```

## How to run

```powershell
# Strict mode (default): unmet preconditions are skipped and reported
.\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath ".\vm-restores.csv"

# Empty TargetVMName cells use the source VM name
.\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath ".\vm-restores.csv" -UseSourceNameIfEmpty

# Enable explicit in-place (replace disks) rows - deliberate opt-in
.\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath ".\rollback.csv" -AllowOriginalLocation

# Sequential, one restore trigger at a time
.\Bulk-Restore-IaaSVM-FromCSV.ps1 -CsvPath ".\vm-restores.csv" -MaxParallel 1

# No parameters: prompts for CSV path (default: Bulk-Restore-IaaSVM-FromCSV_Input.csv)
.\Bulk-Restore-IaaSVM-FromCSV.ps1
```

## Result statuses

| Status | Meaning |
|---|---|
| `TRIGGERED` | Restore **job created**; `JobId` captured — track it in Backup Jobs. The restore itself may run for hours. |
| `PENDING` | Restore accepted (202) but trigger tracking timed out — the job is likely created; check Backup Jobs. |
| `FAILED` | Azure rejected an attempted operation (VM not protected, RP not found, trigger failed…). `Detail` has the error. |
| `SKIPPED` | A precondition was not met — **nothing was attempted**. `Detail` names the exact field/resource and the fix. |

## Output

- Console: preview table, Automation options block, per-item Steps A–E
  progress, color-coded results, summary metrics, skip/fail guidance.
- Results CSV: `{InputFileName}_Results.csv` with columns
  `Item, Target, RestoreType, Status, JobId, Detail, Duration`.

## Performance expectations (from the ROC program documentation)

- Far-region (ROC) restores are ~2.5–3× slower than same-region.
- Large VMs (tens of TB): initial restore can take 15–45 hours.
- A job showing `InProgress` for many hours in Backup Jobs is **normal**.

## Error handling

Per-item errors are caught and logged — they do not stop the batch. When
re-running after fixes, keep **only the skipped/failed rows** in the CSV:
re-running the full file would trigger the successful restores again.

## Public documentation

- Restore Azure VMs with REST API:
  <https://learn.microsoft.com/en-us/azure/backup/backup-azure-arm-userestapi-restoreazurevms>
- Backup Restores REST API reference:
  <https://learn.microsoft.com/en-us/rest/api/backup/restores>
- Azure REST API authentication (Bearer token):
  <https://learn.microsoft.com/en-us/rest/api/azure/#create-the-request>
