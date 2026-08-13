<#
.SYNOPSIS
    Hadoop Delegation Token Manager for Windows Server / Multi-User Environments.

.DESCRIPTION
    This script automates the retrieval, local storage, tracking, and revocation
    of Hadoop HDFS and YARN Resource Manager delegation tokens.

    It supports multi-tenant / RDS Remote Desktop environments by isolating token
    files per Process ID (PID) and securing them with explicit NTFS permissions.

.PARAMETER Out
    Optional file path. When specified, generates a single token file at the given
    path (for background jobs, Spark, R, Python) and terminates without creating a session.

.PARAMETER Cancel
    Switch flag. Revokes and cleans up all active cluster tokens associated with
    the current Process ID ($PID).

.PARAMETER Quiet
    Switch flag. Suppresses non-essential terminal console outputs.

.NOTES
    Author:      Enterprise Systems Administration
    Registry:    HKCU:\Software\CASD\Hadoop
    Security:    Requires valid Cluster CA installed in Windows Trusted Root Store.
#>

param(
    [string] $Out,
    [switch] $Cancel,
    [switch] $Quiet
)

# Enforce strict error handling: any unhandled exception immediately stops execution.
$ErrorActionPreference = "Stop"

# User-level registry locations for configuration and active session state tracking.
$REG      = "HKCU:\Software\CASD\Hadoop"
$REG_SESS = "$REG\Sessions"

# ==============================================================================
# LOGGING & CONSOLE OUTPUT HELPERS
# ==============================================================================

<#
.SYNOPSIS
    Writes messages to standard output unless -Quiet is passed.
#>
function Write-LogMessage([string]$msg) {
    if (-not $Quiet) { Write-Host $msg }
}

# ==============================================================================
# CONFIGURATION & SECURITY SETUP
# ==============================================================================

# Enforce strong TLS encryption (TLS 1.2 / TLS 1.3).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
# Cluster CA certificates MUST be deployed to the Windows Trusted Root Store. Todo, for now we trust all.
if (-not ("TrustAllCerts" -as [type])) {
Add-Type @"
using System.Net;
public static class TrustAllCerts {
    public static void Enable() {
        ServicePointManager.ServerCertificateValidationCallback = (s, cert, chain, errors) => true;
    }
}
"@
}
[TrustAllCerts]::Enable()
<#
.SYNOPSIS
    Reads Hadoop client configuration from HKCU registry.
#>
function Get-HadoopConfig {
    if (-not (Test-Path $REG)) {
        throw "Configuration missing in $REG. Please execute 'install-tokens.ps1' first."
    }
    return Get-ItemProperty -Path $REG
}

# Load current user configuration from registry
$c = Get-HadoopConfig

<#
.SYNOPSIS
    Restricts NTFS access permissions on sensitive delegation token files.
.DESCRIPTION
    In multi-user (RDS / Terminal Services) environments, default permissions
    may allow other authenticated users to read token files. This function
    disables inheritance and grants Full Control strictly to the Current User and SYSTEM.
.PARAMETER filePath
    Path to the token file requiring ACL hardening.
#>
function Protect-TokenFile([string]$filePath) {
    if (-not (Test-Path $filePath)) { return }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Instantiate ACL object and disable inheritance ($true), discarding inherited rules ($false)
    $acl = Get-Acl $filePath
    $acl.SetAccessRuleProtection($true, $false)

    # Define explicit access rules
    $accessRuleUser   = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser, "FullControl", "Allow")
    $accessRuleSystem = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "Allow")

    $acl.AddAccessRule($accessRuleUser)
    $acl.AddAccessRule($accessRuleSystem)

    # Apply hardened ACL back to the file
    Set-Acl -Path $filePath -AclObject $acl
}

# ==============================================================================
# REST API / HTTP HELPERS (SPNEGO / KERBEROS SSO)
# ==============================================================================

<#
.SYNOPSIS
    Executes REST API requests using Windows Integrated Authentication (Kerberos/SPNEGO).
#>
function Invoke-Sso([string]$uri, [string]$method = "GET", [string]$body = $null, [hashtable]$headers = $null) {
    $params = @{
        Uri                   = $uri
        Method                = $method
        UseDefaultCredentials = $true  # Uses logged-in Windows user Kerberos ticket
        SkipHttpErrorCheck    = $false
    }

    if ($body)    { $params.Body = $body; $params.ContentType = "application/json" }
    if ($headers) { $params.Headers = $headers }

    try {
        return (Invoke-RestMethod @params)
    } catch {
        # Read API response body on failure for diagnostic insights
        $responseError = try {
            (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd()
        } catch {
            $_.Exception.Message
        }
        throw "REST Call Failure [$method $uri]: $responseError"
    }
}

# ==============================================================================
# HADOOP DELEGATION TOKEN CREATION & REVOCATION
# ==============================================================================

<#
.SYNOPSIS
    Requests a WebHDFS Delegation Token from the NameNode.
#>
function New-HdfsToken {
    $endpoint = "$($c.NameNodeWeb)/webhdfs/v1/?op=GETDELEGATIONTOKEN&renewer=$($c.Renewer)"
    $response = Invoke-Sso -uri $endpoint
    $token = $response.Token.urlString

    if (-not $token) { throw "Empty HDFS token returned by NameNode." }
    return $token
}

<#
.SYNOPSIS
    Requests a YARN Delegation Token from the Resource Manager.
#>
function New-RmToken {
    $endpoint = "$($c.RmWeb)/ws/v1/cluster/delegation-token"
    $body = @{ renewer = $c.Renewer } | ConvertTo-Json
    $response = Invoke-Sso -uri $endpoint -method "POST" -body $body
    $token = $response.token

    if (-not $token) { throw "Empty Resource Manager token returned." }
    return $token
}

<#
.SYNOPSIS
    Revokes an active HDFS token on the cluster.
#>
function Revoke-HdfsToken([string]$tok) {
    if (-not $tok) { return }
    try {
        $endpoint = "$($c.NameNodeWeb)/webhdfs/v1/?op=CANCELDELEGATIONTOKEN&token=$tok"
        Invoke-Sso -uri $endpoint -method "PUT" | Out-Null
    } catch {
        Write-LogMessage "  (HDFS revocation ignored: $($_.Exception.Message))"
    }
}

<#
.SYNOPSIS
    Revokes an active YARN Resource Manager token on the cluster.
#>
function Revoke-RmToken([string]$tok) {
    if (-not $tok) { return }
    try {
        $endpoint = "$($c.RmWeb)/ws/v1/cluster/delegation-token"
        $headers  = @{ "X-Hadoop-Delegation-Token" = $tok }
        Invoke-Sso -uri $endpoint -method "DELETE" -headers $headers | Out-Null
    } catch {
        Write-LogMessage "  (RM revocation ignored: $($_.Exception.Message))"
    }
}

# ==============================================================================
# SESSION LIFECYCLE MANAGEMENT
# ==============================================================================

function Get-SessionKey([string]$id) { "$REG_SESS\$id" }

<#
.SYNOPSIS
    Cleans up local token files, registry tracking keys, and revokes cluster tokens.
#>
function Remove-Session([string]$id) {
    $keyPath = Get-SessionKey $id
    if (-not (Test-Path $keyPath)) { return }

    $session = Get-ItemProperty -Path $keyPath

    # 1. Revoke tokens remotely on the Hadoop cluster
    if ($session.HdfsToken) { Revoke-HdfsToken $session.HdfsToken }
    if ($session.RmToken)   { Revoke-RmToken   $session.RmToken }

    # 2. Delete binary token file and associated Java CRC checksum file
    if ($session.TokenFile -and (Test-Path $session.TokenFile)) {
        $crcFile = Join-Path (Split-Path $session.TokenFile) (".$(Split-Path $session.TokenFile -Leaf).crc")
        Remove-Item $session.TokenFile, $crcFile -Force -ErrorAction SilentlyContinue
    }

    # 3. Purge session record from local registry
    Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
}

<#
.SYNOPSIS
    Scans the registry for session entries matching dead Windows process IDs and purges them.
#>
function Clear-OrphanSessions {
    if (-not (Test-Path $REG_SESS)) { return }

    foreach ($key in Get-ChildItem $REG_SESS) {
        $sessionId = $key.PSChildName

        # Skip current process ID
        if ($sessionId -eq "$PID") { continue }

        # If the process ID is no longer running in Task Manager, clean up its orphaned tokens
        if (-not (Get-Process -Id $sessionId -ErrorAction SilentlyContinue)) {
            Write-LogMessage "Revoking tokens for terminated session (PID: $sessionId)"
            Remove-Session $sessionId
        }
    }
}

# ==============================================================================
# EXECUTION BRANCH 1: SESSION CANCELLATION (-Cancel)
# ==============================================================================

if ($Cancel) {
    Remove-Session $PID
    Write-LogMessage "Tokens for current session PID $PID revoked."
    return
}

# ==============================================================================
# BINARY TOKEN GENERATION (JAVA INTEROP)
# ==============================================================================

<#
.SYNOPSIS
    Invokes helper Java class (MakeCredsFile) to format raw tokens into a Hadoop .dt container file.
#>
function Write-CredsFile([string]$destinationPath, [string]$hdfsTok, [string]$rmTok) {
    # Dynamically extract Hadoop Java classpath
    $classpath = (hdfs classpath | Out-String).Trim()

    # Temporarily unset variable to prevent recursion during MakeCredsFile run
    $savedEnv = $env:HADOOP_TOKEN_FILE_LOCATION
    $env:HADOOP_TOKEN_FILE_LOCATION = $null

    $savedEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    # Invoke Java binary helper
    $output = & java -cp "$classpath;$($c.ToolsPath)" MakeCredsFile $destinationPath `
      HDFS_DELEGATION_TOKEN "$hdfsTok" "$($c.ServiceIp):$($c.HdfsRpcPort)" `
      HDFS_DELEGATION_TOKEN "$hdfsTok" "$($c.ServiceFqdn):$($c.HdfsRpcPort)" `
      RM_DELEGATION_TOKEN   "$rmTok"   "$($c.ServiceIp):$($c.RmRpcPort)" `
      RM_DELEGATION_TOKEN   "$rmTok"   "$($c.ServiceFqdn):$($c.RmRpcPort)" 2>&1

    $exitCode = $LASTEXITCODE

    # Restore previous preference states
    $ErrorActionPreference = $savedEap
    $env:HADOOP_TOKEN_FILE_LOCATION = $savedEnv

    if (-not $Quiet) { $output | ForEach-Object { Write-Host $_ } }
    if ($exitCode -ne 0) { throw "MakeCredsFile failed with exit code $exitCode" }
    if (-not (Test-Path $destinationPath)) { throw "Target file $destinationPath was not created." }

    # Lock down file permissions immediately after creation
    Protect-TokenFile $destinationPath
}

# ==============================================================================
# EXECUTION BRANCH 2: ONE-OFF / BACKGROUND JOB (-Out)
# ==============================================================================

if ($Out) {
    Write-CredsFile -destinationPath $Out -hdfsTok (New-HdfsToken) -rmTok (New-RmToken)
    return
}

# ==============================================================================
# EXECUTION BRANCH 3: INTERACTIVE SESSION SETUP (DEFAULT)
# ==============================================================================

# Purge dead process sessions and reset current PID session state
Clear-OrphanSessions
Remove-Session $PID

# Ensure local token directory exists
if (-not (Test-Path $c.TokenDir)) {
    New-Item -ItemType Directory -Path $c.TokenDir -Force | Out-Null
}

# Target file path for the current process session
$tokenFilePath = Join-Path $c.TokenDir "hadoop-$PID.dt"

# Fetch fresh tokens and write Java token file
$hdfsTok = New-HdfsToken
$rmTok   = New-RmToken
Write-CredsFile -destinationPath $tokenFilePath -hdfsTok $hdfsTok -rmTok $rmTok

# Update Registry Session State
$sessionKey = Get-SessionKey $PID
New-Item -Path $sessionKey -Force | Out-Null
Set-ItemProperty -Path $sessionKey -Name "TokenFile" -Value $tokenFilePath -Type String -Force
Set-ItemProperty -Path $sessionKey -Name "HdfsToken" -Value $hdfsTok       -Type String -Force
Set-ItemProperty -Path $sessionKey -Name "RmToken"   -Value $rmTok         -Type String -Force
Set-ItemProperty -Path $sessionKey -Name "Created"   -Value (Get-Date).ToString("o") -Type String -Force

# Export environment variable for child processes (R, Python, Spark, etc.)
[Environment]::SetEnvironmentVariable("HADOOP_TOKEN_FILE_LOCATION", $tokenFilePath, "User")
$env:HADOOP_TOKEN_FILE_LOCATION = $tokenFilePath

Write-LogMessage "Session tokens established ($env:USERNAME, renewer=$($c.Renewer)): $tokenFilePath"