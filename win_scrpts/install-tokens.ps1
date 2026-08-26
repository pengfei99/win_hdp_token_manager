<#
.SYNOPSIS
    Configures the local PowerShell environment for secure Hadoop/Spark delegation token management.

.DESCRIPTION
    This script sets up the necessary registry keys, directories, and PowerShell profile wrappers
    to automatically manage Hadoop/YARN/Spark delegation tokens.

    It ensures that:
    1. A fresh session token is acquired when a new PowerShell console opens.
    2. The session token is revoked when the console closes (acting like a Kerberos logout).
    3. Commands like `spark-submit`, `hdfs`, `yarn`, and `spark-run` are wrapped to temporarily
       inject an ephemeral, job-specific token, protecting the main session token from being
       accidentally exposed or reused by cluster nodes.

.PARAMETER NameNodeWeb
    The WebHDFS URL of the NameNode (e.g., https://deb13-spark1.casdds.casd:50470).
.PARAMETER RmWeb
    The ResourceManager Web UI URL (e.g., https://deb13-spark1.casdds.casd:8090).
.PARAMETER ServiceIp
    The IP address of the primary service node.
.PARAMETER ServiceFqdn
    The Fully Qualified Domain Name (FQDN) of the primary service node.
.PARAMETER Renewer
    The principal authorized to renew the delegation tokens (default: "hdfs").
.PARAMETER HdfsRpcPort
    The RPC port for HDFS (default: 9000).
.PARAMETER RmRpcPort
    The RPC port for YARN ResourceManager (default: 8032).
.PARAMETER StagingDir
    The HDFS staging directory for Spark jobs.
.PARAMETER DriverPort
    The port used by the Spark driver (default: 20000).

.EXAMPLE
    .\Setup-HadoopTokens.ps1 -Verbose
    Runs the setup with verbose output to track each configuration step.

.EXAMPLE
    .\Setup-HadoopTokens.ps1 -ServiceFqdn "custom-node.example.com" -HdfsRpcPort 8020
    Runs the setup with custom FQDN and RPC port overrides.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, HelpMessage = "WebHDFS URL of the NameNode")]
    [string] $NameNodeWeb = "https://deb13-spark1.casdds.casd:50470",

    [Parameter(Mandatory = $false, HelpMessage = "ResourceManager Web UI URL")]
    [string] $RmWeb       = "https://deb13-spark1.casdds.casd:8090",

    [Parameter(Mandatory = $false, HelpMessage = "IP address of the service node")]
    [string] $ServiceIp   = "10.50.5.203",

    [Parameter(Mandatory = $false, HelpMessage = "FQDN of the service node")]
    [string] $ServiceFqdn = "deb13-spark1.casdds.casd",

    [Parameter(Mandatory = $false, HelpMessage = "Principal authorized to renew tokens")]
    [string] $Renewer     = "hdfs",

    [Parameter(Mandatory = $false, HelpMessage = "HDFS RPC port")]
    [string] $HdfsRpcPort = "9000",

    [Parameter(Mandatory = $false, HelpMessage = "YARN ResourceManager RPC port")]
    [string] $RmRpcPort   = "8032",

    [Parameter(Mandatory = $false, HelpMessage = "HDFS staging directory for Spark")]
    [string] $StagingDir  = "hdfs://deb13-spark1.casdds.casd:9000/users",

    [Parameter(Mandatory = $false, HelpMessage = "Spark driver port")]
    [int]    $DriverPort  = 20000
)

# ==============================================================================
# Initialization
# ==============================================================================
$ErrorActionPreference = "Stop"

# return the root dir path of the install-tokens.ps1
$toolsDir = $PSScriptRoot
# refresh script name
$RefreshScriptName = "refresh-tokens.ps1"
$registryPath    = "HKCU:\Software\CASD\Hadoop"
$profilePath = $PROFILE.CurrentUserAllHosts
$configMarker = "# === HDFS/YARN/Spark delegation tokens ==="

Write-Verbose "Starting Hadoop/Spark cluster token environment configuration..."

# ==============================================================================
#region 0. Pre-flight Checks
# ==============================================================================

$refreshScript = Join-Path $toolsDir $RefreshScriptName

if (-not (Test-Path $refreshScript)) {
     throw "Critical dependency missing: '$RefreshScriptName' not found in directory: $toolsDir"
}

if ([string]::IsNullOrWhiteSpace($env:HADOOP_HOME)) {
    Write-Warning "Environment variable 'HADOOP_HOME' is not defined. Some wrapped commands may fail."
}
if ([string]::IsNullOrWhiteSpace($env:HADOOP_CONF_DIR)) {
    Write-Warning "Environment variable 'HADOOP_CONF_DIR' is not defined. Some wrapped commands may fail."
}
if ([string]::IsNullOrWhiteSpace($env:SPARK_HOME)) {
    Write-Warning "Environment variable 'SPARK_HOME' is not defined. Some wrapped commands may fail."
}
#endregion 0

# ==============================================================================
#region 1. Registry and Directory Configuration
# ==============================================================================
$tokenDir = Join-Path $env:LOCALAPPDATA "CASD\tokens"

# Ensure the token storage directory exists
if (-not (Test-Path $tokenDir)) {
    New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null
    Write-Verbose "Created token storage directory: $tokenDir"
}

# Ensure the registry key exists
if (-not (Test-Path $registryPath)) {
    New-Item -Path $registryPath -Force | Out-Null
}

# Define configuration properties to store in the registry
$conf = @{
    ToolsPath   = $toolsDir
    TokenDir    = $tokenDir
    NameNodeWeb = $NameNodeWeb
    RmWeb       = $RmWeb
    ServiceIp   = $ServiceIp
    ServiceFqdn = $ServiceFqdn
    Renewer     = $Renewer
    HdfsRpcPort = $HdfsRpcPort
    RmRpcPort   = $RmRpcPort
    StagingDir  = $StagingDir
    SparkHome   = $env:SPARK_HOME
    HadoopConf  = if ($env:HADOOP_HOME) { Join-Path $env:HADOOP_HOME "etc\hadoop" } else { "" }
}

# Write or update each property in the registry
foreach ($k in $conf.Keys) {
    New-ItemProperty -Path $registryPath -Name $k -Value $conf[$k] -PropertyType String -Force | Out-Null
}

# DriverPort is stored as a DWord (integer)
Set-ItemProperty -Path $registryPath -Name "DriverPort" -Value $DriverPort -PropertyType DWord -Force | Out-Null

New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null

Write-Verbose "Configuration successfully written to $registryPath"

#endregion 1

# ==============================================================================
#region 2. PowerShell Profile Injection
# ==============================================================================
# Remove any existing wrapped functions from the current session memory to ensure a clean state
foreach ($func in 'spark-submit', 'hdfs', 'yarn', 'spark-run') {
    Remove-Item "Function:\$func" -ErrorAction SilentlyContinue
}

# Ensure the profile's parent directory exists (prevents errors on fresh machines)
$profileDir = Split-Path -Parent $profilePath
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
}
if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

# Check if our configuration block is already present in the profile
if (Select-String -Path $profilePath -Pattern $configMarker -SimpleMatch -Quiet) {
    Write-Host "Configuration block already exists in $profilePath. Skipping injection." -ForegroundColor Yellow
}
else {
    Write-Verbose "Injecting configuration block into PowerShell profile..."

    # NOTE: The backtick (`) escapes the variables (e.g., `$env:TEMP`) so they are evaluated
    # at RUNTIME when the user opens a new console, NOT at install time.
    $profileBlock = @"

$configMarker

# Session Token: Acquire a fresh set of tokens every time a new console opens.
# a global session token for all basic operations such as hdfs, yarn
# For spark-submit we need a new token, because hadoop will revoke the token
# after the job is finished, if we use the global token for spark-submit,
# after the job is finished, we can not do hdfs or yarn command.
# The old token is revoked during this process, similar to a Kerberos logon.
& '$toolsDir\$RefreshScriptName' -Quiet

# Revocation on console exit (equivalent to a logout).
Register-EngineEvent PowerShell.Exiting -SupportEvent -Action {
    & '$toolsDir\$RefreshScriptName' -Cancel -Quiet
} | Out-Null

# -----------------------------------------------------------------------------
# Command Wrappers
# These wrappers ensure a valid session token is present, and for job-submission
# commands, they inject an ephemeral, job-specific token to protect the session.
# -----------------------------------------------------------------------------

function global:spark-submit {
    `$jobDt = Join-Path `$env:TEMP "hadoop-job-`$PID.dt"
    & '$toolsDir\$RefreshScriptName' -Out `$jobDt -Quiet

    `$savedTokenLocation = `$env:HADOOP_TOKEN_FILE_LOCATION
    `$env:HADOOP_TOKEN_FILE_LOCATION = `$jobDt
    try {
        & "`$env:SPARK_HOME\bin\spark-submit.cmd" @args
    }
    finally {
         # Restore original environment and clean up ephemeral token files
        `$env:HADOOP_TOKEN_FILE_LOCATION = `$savedTokenLocation
        Remove-Item `$jobDt -ErrorAction SilentlyContinue
        Remove-Item (Join-Path `$env:TEMP ".hadoop-job-`$PID.dt.crc") -ErrorAction SilentlyContinue
    }
}
"@
    # Append to profile using UTF8 encoding to prevent character corruption
    Add-Content -Path $profilePath -Value $profileBlock -Encoding UTF8
    Write-Host "Configuration block successfully added to $profilePath" -ForegroundColor Green
}

#endregion 2

# ==============================================================================
#region 3. Initial Token Generation
# ==============================================================================
Write-Host "Generating initial token set..." -NoNewline
& $refreshScript -Quiet
Write-Host " [OK]" -ForegroundColor Green
#endregion 3

# ==============================================================================
#region 4. Completion Message
# ==============================================================================
Write-Host ""
Write-Host "Token configuration completed successfully." -ForegroundColor Green
Write-Host "Please open a NEW PowerShell console for the changes to take effect."
Write-Host "Once opened, you can test the configuration with:"
Write-Host "    hdfs dfs -ls /"
Write-Host "    spark-submit --deploy-mode cluster --master yarn my_job.py"
#endregion4