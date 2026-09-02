# install-tokens.ps1 — Hadoop Delegation Token Environment Setup

## 1. Description

`install-tokens.ps1` is the **one-time setup** script that configures a Windows
PowerShell environment for secure Hadoop/YARN/Spark delegation-token management
in multi-user (RDS) environments. It performs the following:

1. **Registry + directory setup** — creates the configuration key
   `HKCU:\Software\CASD\Hadoop` and the per-user token directory
   `$env:LOCALAPPDATA\CASD\tokens`, hardened with NTFS ACLs.
2. **PowerShell profile injection** — rewrites `$PROFILE.CurrentUserAllHosts`
   so that, on every new console:
   - a **fresh session token** is acquired on open,
   - the session token is **revoked on close** (like a Kerberos logout),
   - `spark-submit` is **wrapped** to inject an ephemeral, job-specific token,
     protecting the main session token from exposure/reuse by cluster nodes.
3. **Initial token generation** — calls `refresh-tokens.ps1` once to establish
   tokens immediately.

The script is **idempotent**: re-running it updates an existing injected block
rather than duplicating it.

## 2. Requirements

- A valid Kerberos TGT ticket in the user's logon session (SSO/SPNEGO)
- `refresh-tokens.ps1` located **next to** this script (same folder)
- A valid Kerberos TGT ticket and cluster reachability for token generation
- Optional (warnings only, not fatal): `HADOOP_HOME`, `HADOOP_CONF_DIR`, `SPARK_HOME`

> **Note:** The initial token-generation step requires `JAVA_HOME`/`JAVA_PATH`
> (Java 11+) and `HADOOP_HOME` to be correctly set, since it delegates to
> `refresh-tokens.ps1` and the `MakeCredsFile` Java helper.

## Parameters

All parameters are **optional** and each has a default.

| Parameter      | Type   | Default                                      | Description                                   |
|----------------|--------|----------------------------------------------|-----------------------------------------------|
| `-NameNodeWeb` | string | `https://deb13-spark1.casdds.casd:50470`     | WebHDFS URL of the NameNode.                  |
| `-RmWeb`       | string | `https://deb13-spark1.casdds.casd:8090`      | ResourceManager Web UI URL.                   |
| `-ServiceIp`   | string | `10.50.5.203`                                | IP address of the primary service node.       |
| `-ServiceFqdn` | string | `deb13-spark1.casdds.casd`                   | FQDN of the primary service node.             |
| `-Renewer`     | string | `hdfs`                                       | Principal authorized to renew tokens.         |
| `-HdfsRpcPort` | string | `9000`                                       | HDFS RPC port.                                |
| `-RmRpcPort`   | string | `8032`                                       | YARN ResourceManager RPC port.                |
| `-StagingDir`  | string | `hdfs://deb13-spark1.casdds.casd:9000/users` | HDFS staging directory for Spark jobs.        |
| `-DriverPort`  | int    | `20000`                                      | Spark driver port (stored as registry DWord). |

## Usage Examples

### 1. Basic setup (all defaults)

```powershell
.\install-tokens.ps1
```

### 2. Setup with verbose tracking

```powershell
.\install-tokens.ps1 -Verbose
```

### 3. Customize FQDN and HDFS RPC port

```powershell
.\install-tokens.ps1 -ServiceFqdn "custom-node.example.com" -HdfsRpcPort 8020
```

> **After running:** open a **new** PowerShell console for the profile changes
> to take effect, then verify with:
> ```powershell
> hdfs dfs -ls /
> yarn application -list
> spark-submit --deploy-mode cluster --master yarn my_job.py
> ```

## Workflow

```
                   ┌────────────────────────────────┐
                   │      install-tokens.ps1        │
                   └────────────────────────────────┘
                                    │
                     0. Pre-flight checks
                        • refresh-tokens.ps1 present next to this script?
                        • warn if HADOOP_HOME / HADOOP_CONF_DIR / SPARK_HOME missing
                                    │
                     1. Registry + Directory setup
                        • Create $env:LOCALAPPDATA\CASD\tokens (if missing)
                        • Harden token dir ACLs (current user + SYSTEM only,
                          inheritance disabled) via Set-Acl
                                    │
                     2. Registry configuration
                        • Create HKCU:\Software\CASD\Hadoop
                        • Write per-property values (ToolsPath, TokenDir,
                          NameNodeWeb, RmWeb, ServiceIp/Fqdn, Renewer, ports,
                          StagingDir, SparkHome, HadoopHome, HadoopConf)
                        • DriverPort stored as DWord
                                    │
                     3. PowerShell profile injection
                        • Ensure profile dir/file exists
                        • Build the CASD block (here-string, escaped vars)
                        • BEGIN/END markers delimit the block
                        • Replace existing block OR append if absent (idempotent)
                        • Writes block that on console open:
                            - calls refresh-tokens.ps1 -Quiet  (acquire session)
                            - Register-EngineEvent PowerShell.Exiting
                              → refresh-tokens.ps1 -Cancel (revoke on close)
                            - defines global:spark-submit wrapper
                                    │
                     4. Initial token generation
                        • Run refresh-tokens.ps1 -Quiet (errors reported,
                          not fatal — setup continues)
                                    │
                     5. Completion message
                        • Prompt user to open a NEW PowerShell console
                        • Suggest verification commands
                                    ▼
                               Done
```

### What gets injected into the PowerShell profile

The generated block (between `# === HDFS/YARN/Spark delegation tokens BEGIN ===`
and `# === ... END ===`) contains three behaviors:

| Behavior                                      | Purpose                                                                                                                                                                                         |
|-----------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `& refresh-tokens.ps1 -Quiet`                 | Acquire a fresh session token each console open.                                                                                                                                                |
| `Register-EngineEvent ... PowerShell.Exiting` | Revoke tokens + cleanup when the console closes (best-effort, non-blocking).                                                                                                                    |
| `function global:spark-submit`                | Generates a GUID-named temp token per job, sets `HADOOP_TOKEN_FILE_LOCATION` to it, runs the real `spark-submit`, then restores the previous env var and deletes the temp `.dt` + `.crc` files. |

## Registry keys written

All under `HKCU:\Software\CASD\Hadoop`:

| Name          | Type   | Source                                                     |
|---------------|--------|------------------------------------------------------------|
| `ToolsPath`   | String | script folder (`$PSScriptRoot`)                            |
| `TokenDir`    | String | `$env:LOCALAPPDATA\CASD\tokens`                            |
| `NameNodeWeb` | String | `-NameNodeWeb`                                             |
| `RmWeb`       | String | `-RmWeb`                                                   |
| `ServiceIp`   | String | `-ServiceIp`                                               |
| `ServiceFqdn` | String | `-ServiceFqdn`                                             |
| `Renewer`     | String | `-Renewer`                                                 |
| `HdfsRpcPort` | String | `-HdfsRpcPort`                                             |
| `RmRpcPort`   | String | `-RmRpcPort`                                               |
| `StagingDir`  | String | `-StagingDir`                                              |
| `SparkHome`   | String | `$env:SPARK_HOME` (may be empty)                           |
| `HadoopHome`  | String | `$env:HADOOP_HOME` (may be empty)                          |
| `HadoopConf`  | String | `$env:HADOOP_CONF_DIR`, else `$env:HADOOP_HOME\etc\hadoop` |
| `DriverPort`  | DWord  | `-DriverPort`                                              |

## Notes

- Must be run **once** before any adapter (PySpark, sparklyr, refresh) works,
  because those all read from the registry key this script creates.
- Requires `refresh-tokens.ps1` beside it — a missing file aborts the installation.
- NTFS hardening of the token directory may require Administrator rights; if the
  `Set-Acl` fails, a warning is raised but the script continues.
