# casd_spark.R — sparklyr + Hadoop Delegation Token Adapter

## Description

`casd_spark.R` is an **R / sparklyr** wrapper that automatically manages Hadoop
delegation tokens so R applications can connect to a YARN/HDFS cluster on
Windows **without native Kerberos tickets** (the R counterpart of
`casd_spark.py`).

It reads the CASD configuration from the Windows Registry, generates a fresh,
job-scoped delegation token via `refresh-tokens.ps1`, points
`HADOOP_TOKEN_FILE_LOCATION` at it, and connects to Spark through sparklyr.
On disconnect, it stops Spark, deletes the token file (and its CRC file), and
restores/unsets the environment variable.

The helper keeps all mutable state in a hidden `.casd_state` environment to
avoid polluting the R global namespace. A finalizer performs best-effort file
cleanup when the R session exits normally.

> A **lightweight variant** (`casd_spark_light.R`) ships identical public API
> with roxygen comments stripped. Both files behave the same.

## Requirements

- **Windows only** (uses `utils::readRegistry` and PowerShell)
- `install-tokens.ps1` run once (writes `HKCU:\Software\CASD\Hadoop`)
- Java 11+ (`JAVA_HOME`/`JAVA_PATH`) and `HADOOP_HOME` available to `refresh-tokens.ps1`
- R with the **sparklyr** package installed
- For YARN connections: `refresh-tokens.ps1` present in the registry `ToolsPath`

## User configuration constants

Editable at the top of the file:

| Constant | Default | Description |
|----------|---------|-------------|
| `CASD_REGISTRY_PATH` | `Software\CASD\Hadoop` | Registry key path. |
| `CASD_TOKEN_SCRIPT_NAME` | `refresh-tokens.ps1` | Token-generation PowerShell script. |
| `CASD_TOKEN_PREFIX` / `CASD_TOKEN_EXT` | `hadoop-r-` / `.dt` | Temp token file naming. |
| `CASD_DEFAULT_TIMEOUT` | `60L` | PS script timeout (seconds); `0` = no timeout. |
| `CASD_DEFAULT_MASTER` | `"yarn"` | Default Spark master. |
| `CASD_DEFAULT_APP_NAME` | `"rstudio"` | Default application name. |
| `CASD_DEFAULT_DRIVER_PORT` | `7077L` | Default driver port. |
| `CASD_BLOCK_MANAGER_OFFSET` | `200L` | Block-manager port = driver port + offset. |
| `CASD_DISABLED_CREDENTIALS` | `c(spark.security.credentials.hadoopfs/hive/hbase.enabled)` | Spark credential providers disabled because tokens are managed externally. |

## Public API

### `casd_spark_connect(config = NULL, master = "yarn", app_name = "rstudio", driver_port = NULL, ...)` → connection

Connects to Spark with a managed token:

1. Verifies `sparklyr` is installed and that `master` is a valid string.
2. Reads CASD config from the registry; sets `SPARK_HOME` / `HADOOP_CONF_DIR`
   **only if blank**.
3. Starts sparklyr config, disables the credential providers, and resolves the
   driver/block-manager ports.
4. For `master` = `yarn`: generates a delegation token (and schedules cleanup
   via `on.exit` if the connection fails).
5. Calls `sparklyr::spark_connect()` and attaches the token path as the
   `casd_token_path` attribute for later cleanup.

### `casd_spark_disconnect(sc = NULL)`

Disconnects Spark and cleans up the matching token:

- If `sc` carries a `casd_token_path` attribute, uses it (preferred).
- Fallback: if only one token is tracked, assumes it belongs to `sc`
  (conservative — does not guess when multiple tokens exist).
- With `sc = NULL`, cleans the most recently generated token without
  disconnecting.
- Deletes the `.dt` and `.crc` files and restores/unsets
  `HADOOP_TOKEN_FILE_LOCATION`.

### `casd_cleanup_tokens(all = TRUE)`

Manually cleans tracked token files. `all = TRUE` cleans every tracked token;
`all = FALSE` cleans only the most recent. Useful when you bypassed the helper
(e.g. used `sparklyr::spark_disconnect()` directly).

## Parameters (`casd_spark_connect`)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `config` | `list`/`NULL` | `NULL` | sparklyr config; defaults to `sparklyr::spark_config()`. |
| `master` | `character` | `"yarn"` | Spark master. Token generation happens for `yarn`. |
| `app_name` | `character` | `"rstudio"` | Spark application name. |
| `driver_port` | `integer` | `NULL` | Force driver port (see resolution below). |
| `...` | … | — | Extra arguments forwarded to `sparklyr::spark_connect()` (e.g. `spark_home`). |

### Driver-port resolution

Precedence: explicit `driver_port` → config `spark.driver.port` → registry
`DriverPort` → `CASD_DEFAULT_DRIVER_PORT`. Block-manager port is set to
`driver.port + 200` unless it exceeds 65535 (then a warning is emitted and it is
left unset).

### Disabled Spark credential providers

```r
spark.security.credentials.hadoopfs.enabled = "false"
spark.security.credentials.hive.enabled     = "false"
spark.security.credentials.hbase.enabled    = "false"
```

## Usage Examples

Source the file, then connect:

```r
source("casd_spark.R")

sc <- casd_spark_connect(app_name = "my-r-job")
df <- sparklyr::sdf_read_parquet(sc, "hdfs:///user/data")
sparklyr::sdf_dim(df)
casd_spark_disconnect(sc)
```

### Custom config and driver port

```r
source("casd_spark.R")

cfg <- sparklyr::spark_config()
cfg$spark.executor.memory <- "4g"

sc <- casd_spark_connect(config = cfg, driver_port = 7077L, app_name = "tuned")
# ... work ...
casd_spark_disconnect(sc)
```

### Connect without a connection argument (clean latest token)

```r
sc <- casd_spark_connect()
# ... work ...
casd_spark_disconnect()   # cleans the most recent token
```

### Force-cleanup all tracked tokens

```r
casd_cleanup_tokens(all = TRUE)
```

## Workflow

```
                 ┌──────────────────────────────────────────────┐
                 │         casd_spark_connect(...)              │
                 └──────────────────────────────────────────────┘
                                   │
                  1. Verify sparklyr installed; validate `master`
                                   │
                  2. Read registry config (get_casd_conf)
                     HKCU:\Software\CASD\Hadoop
                     • set SPARK_HOME / HADOOP_CONF_DIR if blank
                                   │
                  3. Build sparklyr config
                     • start from config or spark_config()
                     • disable built-in credential providers
                     • resolve driver/block-manager ports
                                   │
                  4. (master=yarn) generate_casd_token()
                     • find refresh-tokens.ps1 in ToolsPath
                     • run `refresh-tokens.ps1 -Out <temp>.dt -Quiet`
                     • set HADOOP_TOKEN_FILE_LOCATION = <temp>.dt
                     • save token path in .casd_state
                     • on.exit: cleanup if connect later fails
                                   │
                  5. sparklyr::spark_connect(...)
                     • attach casd_token_path attribute to connection
                                   ▼
                             [ user code runs ]
                                   │
                 ┌──────────────────────────────────────────────┐
                 │         casd_spark_disconnect(sc)            │
                 └──────────────────────────────────────────────┘
                                   │
                  6. resolve token for this connection
                  7. sparklyr::spark_disconnect(sc) (if open)
                  8. .casd_cleanup_token():
                     • delete <temp>.dt and .<temp>.dt.crc
                     • remove from .casd_state$tokens
                     • restore/unset HADOOP_TOKEN_FILE_LOCATION
                       (reponts to remaining token, restores original,
                        or unsets depending on state)
                                   ▼
                                 Done
```

### Token lifecycle & state notes

- Uses `refresh-tokens.ps1 -Out`, so tokens are **not** in the PS session
  registry and expire on the cluster (e.g. 7 days) rather than being auto-revoked.
- `.casd_state$tokens` tracks every generated token; `last_token` is the newest.
- The finalizer (`reg.finalizer`, `onexit = TRUE`) best-effort deletes token
  files on normal R exit. It does **not** protect against R crashes, forced
  kills, or power loss, and does not disconnect Spark.
- Env-var restore logic handles three cases: other tokens still exist (points to
  a remaining one), an original value was saved (restores it), or none (unsets).
