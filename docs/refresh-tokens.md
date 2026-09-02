# refresh-tokens.ps1 — Hadoop Delegation Token Manager

## Description

`refresh-tokens.ps1` automates the full lifecycle of Hadoop delegation tokens
for Windows Server / multi-user (RDS) environments. Because Windows lacks
native Kerberos tickets support for Hadoop clients, this script:

- Retrieves **HDFS** and **YARN Resource Manager** delegation tokens over the
  cluster's REST APIs using `Windows Integrated Authentication (SPNEGO/Kerberos SSO)`.
- Converts the raw base64 token strings into a binary Hadoop credentials file
  (`.dt`) via the `MakeCredsFile` Java helper.
- Stores, tracks, and revokes tokens, isolating them per **Process ID (PID)** and
  securing them with explicit **NTFS permissions** for multi-user safety.

The produced token file is consumed by all Hadoop clients — `hdfs`, `yarn`,
`spark-submit`, PySpark, and sparklyr — through the `HADOOP_TOKEN_FILE_LOCATION`
environment variable.

## Requirements

- Windows with a valid Kerberos TGT ticket (SSO/SPNEGO)
- **Java 11+** located via `JAVA_HOME` (or `JAVA_PATH`) environment variable
- `HADOOP_HOME` set so the script can resolve `hdfs.cmd classpath`
- `install-tokens.ps1` run **once** beforehand (writes registry config)
- The `make-creds-file-1.0.0-SNAPSHOT.jar` present in the registry `ToolsPath`
- Cluster CA certificate in the Windows Trusted Root Store

> **Note:** The runtime Java referenced by `JAVA_HOME` must be **11 or newer**.
> An older Java causes `java.lang.UnsupportedClassVersionError` because the
> JAR is compiled for Java 11 bytecode.

## Parameters

| Parameter | Type   | Default  | Description                                                                                                                                          |
|-----------|--------|----------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| `-Out`    | string | *(none)* | Generates a single token file at the given path and **terminates** without creating a session. Used for background jobs and Spark/R/Python adapters. |
| `-Cancel` | switch | `$false` | Revokes and cleans up all active cluster tokens associated with the current Process ID (`$PID`).                                                     |
| `-Quiet`  | switch | `$false` | Suppresses non-essential terminal console output (INFO/WARNING/ERROR lines). Verbose stream is still emitted.                                        |

## Configuration (Registry)

The script reads its configuration from `HKCU:\Software\CASD\Hadoop`, written by
`install-tokens.ps1`. Key values used:

| Value                      | Purpose                                                       |
|----------------------------|---------------------------------------------------------------|
| `ToolsPath`                | Folder containing `refresh-tokens.ps1` and the Java JAR       |
| `TokenDir`                 | Directory for per-PID session token files (`hadoop-<PID>.dt`) |
| `NameNodeWeb`              | WebHDFS NameNode URL (e.g. `https://host:50470`)              |
| `RmWeb`                    | Resource Manager Web UI URL                                   |
| `ServiceIp`, `ServiceFqdn` | Cluster service addresses for token binding                   |
| `Renewer`                  | Principal authorized to renew tokens (default `hdfs`)         |
| `HdfsRpcPort`, `RmRpcPort` | Software RPC ports for HDFS/YARN tokens                       |

`Session` records are tracked under `HKCU:\Software\CASD\Hadoop\Sessions\<PID>`.

## Usage Examples

### 1. Start a new interactive session (default)

Run this when a console opens to acquire a fresh session token set:

```powershell
.\refresh-tokens.ps1
```

This is normally invoked automatically from your PowerShell profile (injected by
`install-tokens.ps1`). The token file is written to
`$env:LOCALAPPDATA\CASD\tokens\hadoop-<PID>.dt` and
`HADOOP_TOKEN_FILE_LOCATION` is exported for all child processes.

### 2. Generate a one-off token file (background job / Spark)

```powershell
.\refresh-tokens.ps1 -Out C:\temp\job-token.dt
```

Useful for `spark-submit`, PySpark, and sparklyr where a fresh token is required
per job. The token is **not** registered in the session registry and is not
auto-revoked by `-Cancel`; it expires on the cluster (e.g. 7 days) or must be
cleaned up by the calling adapter.

### 3. Revoke the current session's tokens

```powershell
.\refresh-tokens.ps1 -Cancel
```

Revokes HDFS and RM tokens on the cluster, deletes the local `.dt` and `.crc`
files, and removes the PID session registry entry. Normally wired to the
console-close event by the profile.

### 4. Suppress console output (automation)

```powershell
.\refresh-tokens.ps1 -Out C:\temp\job-token.dt -Quiet
```

## Workflow

```
                 ┌──────────────────────────────────────────────┐
                 │            refresh-tokens.ps1                │
                 └──────────────────────────────────────────────┘
                                   │
              Reads registry config (HKCU:\Software\CASD\Hadoop)
                                   │
        ┌──────────────────────────┴──────────────────────────┐
        │                                                     │
   -Cancel switch?                                        -Out path?
        │  yes                                          │   │  yes
        ▼                                                ▼
   Revoke session PID:                          Generate one-off token:
   • Revoke HDFS token (cluster)                • New-HdfsToken
   • Revoke RM token (cluster)                  • New-RmToken
   • Delete .dt + .crc files                    • Write-CredsFile to -Out
   • Remove registry PID entry                  • exit 0 (no session)
        │                                                     │
        │              ┌──────────────────────────────────────┘
        │              ▼  (default — interactive session)
        │         Clear-OrphanSessions  (purge dead PIDs, detect PID reuse)
        │         Remove-Session $PID
        │         Ensure TokenDir exists
        │         TokenFile = TokenDir\hadoop-<PID>.dt
        │         Fetch HDFS + RM tokens (New-HdfsToken / New-RmToken)
        │         Write-CredsFile  (invokes Java MakeCredsFile)
        │              • resolve Java via JAVA_HOME\bin\java.exe
        │              • resolve hadoop classpath via HADOOP_HOME\bin\hdfs.cmd
        │              • convert base64 tokens -> binary .dt file
        │              • harden NTFS ACLs (current user + SYSTEM only)
        │         Write PID session state to registry
        │         Export HADOOP_TOKEN_FILE_LOCATION (Process scope)
        ▼
   Done
```

### Core internal functions

| Function               | Responsibility                                                                            |
|------------------------|-------------------------------------------------------------------------------------------|
| `New-HdfsToken`        | Requests a WebHDFS delegation token from the NameNode.                                    |
| `New-RmToken`          | Requests a YARN delegation token from the Resource Manager.                               |
| `Revoke-HdfsToken`     | Cancels an HDFS token on the cluster (best-effort).                                       |
| `Revoke-RmToken`       | Cancels a YARN token on the cluster (best-effort).                                        |
| `Write-CredsFile`      | Locates Java/Hadoop classpath and invokes `MakeCredsFile` to write the binary `.dt` file. |
| `Protect-TokenFile`    | Restricts NTFS permissions on the token file to the current user + SYSTEM.                |
| `Clear-OrphanSessions` | Removes registry entries for dead PIDs, guarding against PID reuse.                       |
| `Remove-Session`       | Full cleanup of a session (revoke + delete files + purge registry).                       |
| `Invoke-Sso`           | Executes HTTP(S) calls with Windows Integrated Authentication (Kerberos/SPNEGO).          |

## Security notes

- Token files are written with NTFS ACLs hardened to the **current user and
  SYSTEM only** (protected, no inheritance) for multi-user / RDS safety.
- The script sets `HADOOP_TOKEN_FILE_LOCATION` at **Process** scope (not User)
  to prevent stale paths surviving a reboot.
- Server certificate validation is currently **disabled** (`TrustAllCerts`) —
  see the `TODO` at the top of the script. Prefer deploying the cluster CA to
  the Windows Trusted Root Store and removing this block in production.
