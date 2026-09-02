# casd_spark.py — PySpark + Hadoop Delegation Token Adapter

## Description

`casd_spark.py` is a Python wrapper around **PySpark** that automatically manages
Hadoop delegation tokens so PySpark jobs can authenticate against a YARN/HDFS
cluster on Windows **without native Kerberos tickets** (same as the rest of the
`win_hdp_token_manager` toolchain).

It reads the CASD configuration from the Windows Registry, generates a fresh,
job-scoped delegation token via the script `refresh-tokens.ps1`, points
`HADOOP_TOKEN_FILE_LOCATION` at it, and builds a `SparkSession` with YARN-safe
settings. It guarantees cleanup of the temp token file and restoration of the
environment on exit.

## Requirements

- **Windows** (uses `winreg` and PowerShell)
- `install-tokens.ps1` run once (writes `HKCU:\Software\CASD\Hadoop`)
- Java 11+ (`JAVA_HOME`/`JAVA_PATH`) and `HADOOP_HOME` available to `refresh-tokens.ps1`
- **PySpark** installed (imported lazily, only when needed)
- Python 3.8+ (uses `unlink(missing_ok=True)`)

> On non-Windows platforms the module degrades gracefully: registry reads return
> empty (or raise when `required=True`).

## Configuration source

Read from `HKCU:\Software\CASD\Hadoop` (see `get_registry_config`). Values used:

| Registry key    | Purpose                                                |
|-----------------|--------------------------------------------------------|
| `ToolsPath`     | Folder containing `refresh-tokens.ps1`                 |
| `SparkHome`     | Sets `SPARK_HOME` if present                           |
| `HadoopConf`    | Sets `HADOOP_CONF_DIR` if present                      |
| `StagingDir`    | YARN staging root (defaults to `/tmp`)                 |
| `DriverPort`    | Default Spark driver port                              |
| `PowerShellExe` | Optional: explicit path to `powershell.exe`/`pwsh.exe` |

## Public API

### `HadoopTokenManager(config=None, timeout=120.0)`

Manages a disposable token's lifecycle.

| Method / Property              | Description                                                                                                  |
|--------------------------------|--------------------------------------------------------------------------------------------------------------|
| `generate_token(timeout=None)` | Runs `refresh-tokens.ps1 -Out <tmp>.dt -Quiet`, sets `HADOOP_TOKEN_FILE_LOCATION`, returns the token `Path`. |
| `cleanup()`                    | Removes the temp directory and restores/unsets the original env var.                                         |
| `active` (property)            | `True` if a token file currently exists.                                                                     |
| `__enter__` / `__exit__`       | Context-manager support (generates on enter, cleans on exit).                                                |

### `get_spark(...)` → `SparkSession`

Builds and returns a `SparkSession`. Creates its own `HadoopTokenManager` for
`master="yarn"` if none is supplied, and registers an `atexit` cleanup for
callers that bypass the context manager.

### `spark_session(...)` → context manager

**Preferred entry point.** Yields a `SparkSession` and guarantees in `finally`:
1. `SparkSession.stop()` is attempted (before token deletion, to avoid
   file-not-found shutdown errors).
2. The `HadoopTokenManager` is cleaned up (temp file removed, env var restored).

### `get_registry_config(sub_key=..., required=True)` → `dict`

Reads the CASD registry values into a dictionary. `required=False` returns `{}`
on missing keys instead of raising.

## Parameters

Both `get_spark()` and `spark_session()` accept the same arguments:

| Parameter       | Type                 | Default    | Description                                                             |
|-----------------|----------------------|------------|-------------------------------------------------------------------------|
| `conf`          | `dict`               | `None`     | Extra Spark config; applied **after** base settings so user values win. |
| `master`        | `str`                | `"yarn"`   | Spark master URL. Token management only happens for `"yarn"`.           |
| `app_name`      | `str`                | `"python"` | Spark application name.                                                 |
| `driver_port`   | `int`                | `None`     | Override driver port (falls back to config → registry).                 |
| `token_manager` | `HadoopTokenManager` | `None`     | Reuse an existing token manager (`get_spark` only).                     |
| `config`        | `dict`               | `None`     | Pre-loaded registry config (avoids re-reading the registry).            |
| `token_timeout` | `float`              | `None`     | Timeout (sec) for the token-generation PowerShell call.                 |

### Driver/block-manager port resolution (YARN)

`driver.port` precedence: explicit `driver_port` → `conf["spark.driver.port"]` →
registry `DriverPort`. The block-manager port is set to `driver_port + 200`
unless it exceeds 65535 (which raises).

### Always-applied base Spark config (YARN)

Spark's built-in credential providers are disabled because token management is
handled externally via `HADOOP_TOKEN_FILE_LOCATION`:

```python
spark.security.credentials.hadoopfs.enabled = false
spark.security.credentials.hive.enabled     = false
spark.security.credentials.hbase.enabled    = false
spark.yarn.stagingDir                       = <StagingDir>/<safe_username>
```

## Usage Examples

### 1. Recommended — `spark_session()` context manager (main session)

```python
from casd_spark import spark_session

with spark_session(app_name="my-job") as spark:
    df = spark.read.parquet("hdfs:///user/data")
    print(df.count())
# Token file deleted + env var restored + Spark stopped automatically on exit
```

### 2. Passing explicit Spark config

```python
from casd_spark import spark_session

conf = {
    "spark.executor.memory": "4g",
    "spark.driver.memory": "2g",
}
with spark_session(app_name="tuned-job", conf=conf) as spark:
    spark.sql("SELECT 1").show()
```

### 3. Override the driver port

```python
with spark_session(app_name="fixed-port", driver_port=7077) as spark:
    ...
```

### 4. Low-level — manual `HadoopTokenManager` (raw token management)

```python
from casd_spark import HadoopTokenManager

mgr = HadoopTokenManager()
mgr.generate_token()
# ... token file is now active at mgr.token_path ...
mgr.cleanup()
```

### 5. Low-level — `get_spark()` without a context manager

```python
from casd_spark import get_spark

spark = get_spark(app_name="adhoc")
# atexit registers cleanup automatically
```

## Workflow

```
                 ┌──────────────────────────────────────────┐
                 │          spark_session(...)              │
                 └──────────────────────────────────────────┘
                                   │
                  1. Read registry config (get_registry_config)
                     HKCU:\Software\CASD\Hadoop
                                   │
                  2. (master=yarn) Create HadoopTokenManager
                                   │
                  3. token manager .generate_token()
                     • locate PowerShell (config → PATH → default)
                     • locate refresh-tokens.ps1 (ToolsPath)
                     • run `refresh-tokens.ps1 -Out <tmp>.dt -Quiet`
                       (fresh per-job token; NOT registered in session registry)
                     • set HADOOP_TOKEN_FILE_LOCATION = <tmp>.dt
                     • chmod 0o600 (best-effort)
                                   │
                  4. get_spark(...)
                     • late-import pyspark.sql.SparkSession
                     • set SPARK_HOME / HADOOP_CONF_DIR from registry
                     • apply base YARN conf (disable credential providers,
                       set staging dir, resolve driver/block-manager ports)
                     • apply user conf (overrides)
                     • builder.getOrCreate()
                                   │
                  5. yield spark  →  user code runs
                                   │
                  6. finally:
                     • spark.stop()  (BEFORE token cleanup)
                     • token manager .cleanup()
                         - delete temp token dir (.dt + .crc)
                         - restore/unset HADOOP_TOKEN_FILE_LOCATION
                                   ▼
                                 Done
```

### Token lifecycle notes

- Uses `refresh-tokens.ps1 -Out`, so the token is **not** in the PS session
  registry and is **not** auto-revoked by `-Cancel`. It is deleted locally on
  clean-up and otherwise expires on the cluster (e.g. 7-day max lifetime).
- On failure (`generate_token`/`get_spark`), the token manager is cleaned up so
  no orphan files or stale env vars remain.
- Direct calls to `get_spark()` (no context manager) get an `atexit`-registered
  cleanup as a safety net.
