# MECRBROCTooling

This repo contains Azure cross-region backup and recovery tooling intended only for customers that are whitelisted for a specific service in UAE and Qatar. These scripts only work for those whitelisted customers in these regions with previously agreed target regions.

## Folder Overview

### ASR

Contains Azure Site Recovery scripts for VM disaster recovery replication.

- `Enable-ASRReplication.ps1`: enables Azure-to-Azure replication for Azure VMs.
- Used when the goal is disaster recovery replication rather than backup retention.

### DPP

Contains Backup Vault / Data Protection Platform scripts for newer backup workflows.

- Shared scripts in this folder handle operations such as stopping protection while retaining data and updating Backup Vault permissions.
- Workloads are split into subfolders based on the protected service.

#### DPP/AKS

Contains Azure Kubernetes Service backup scripts.

- `Configure Backup/`: scripts to configure AKS backup.
- `Restore/`: scripts to restore AKS backups.

#### DPP/PGFlex

Contains PostgreSQL Flexible Server backup scripts.

- Configure protection.
- Stop protection while retaining backup data.
- Restore PostgreSQL Flexible Server backups.
- Update Backup Vault permissions.

### RSV

Contains Recovery Services Vault scripts for workloads that use the Recovery Services Vault backup model.

#### RSV/AFS

Contains Azure Files backup scripts.

- Register or unregister storage accounts to or from a vault.
- Configure or stop protection.
- Run bulk protection and bulk stop-protection operations.
- Restore Azure file shares.

#### RSV/IaaSVM

Contains Azure IaaS VM backup scripts.

##### RSV/IaaSVM/GPVM

General-purpose VM backup operations.

- Register VMs to a vault.
- Stop VM protection.
- Restore VMs.
- Run bulk CSV-based register and stop-protection workflows.

##### RSV/IaaSVM/CVM

Backup and restore operations for specialized encrypted/confidential VM scenarios.

- Restore VMs through REST-based workflows.
- Restore encryption keys used by protected VMs.

#### RSV/SAPHana

Contains SAP HANA backup scripts.

- Register SAP HANA VMs to a vault.
- Restore SAP HANA to an alternate VM.
- Unregister SAP HANA VMs from a vault.

#### RSV/SQL

Contains SQL Server on Azure VM backup scripts.

- Register or unregister SQL IaaS VMs to or from a vault.
- Restore SQL backups.
- Enable auto-protection for SQL Availability Groups.
- Run bulk migration workflows between Recovery Services Vaults.
- Undelete soft-deleted SQL backup items when required during vault migration.

## Summary

At a high level:

- `ASR` is for disaster recovery replication.
- `DPP` is for Backup Vault / Data Protection workloads.
- `RSV` is for Recovery Services Vault workloads.