param(
    [string] $Out,
    [switch] $Cancel,
    [switch] $Quiet
)

$ErrorActionPreference = "Stop"
$REG      = "HKCU:\Software\CASD\Hadoop"
$REG_SESS = "$REG\Sessions"

function Ecrire($msg) { if (-not $Quiet) { Write-Host $msg } }

# configuration : tout vient du registre
function Get-Conf {
    if (-not (Test-Path $REG)) {
        throw "Configuration absente dans $REG. Executer d'abord install-tokens.ps1."
    }
    Get-ItemProperty -Path $REG
}
$c = Get-Conf

# TLS (PowerShell 5.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
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

# appels REST
function Invoke-Sso($uri, $methode = "GET", $corps = $null, $entetes = $null) {
    $p = @{ Uri = $uri; Method = $methode; UseBasicParsing = $true; UseDefaultCredentials = $true }
    if ($corps)   { $p.Body = $corps; $p.ContentType = "application/json" }
    if ($entetes) { $p.Headers = $entetes }
    try {
        (Invoke-WebRequest @p).Content
    } catch {
        $r = try { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }
             catch { $_.Exception.Message }
        throw "Appel $methode $uri en echec : $r"
    }
}

function New-HdfsToken {
    $raw = Invoke-Sso "$($c.NameNodeWeb)/webhdfs/v1/?op=GETDELEGATIONTOKEN&renewer=$($c.Renewer)"
    $t = ($raw | ConvertFrom-Json).Token.urlString
    if (-not $t) { throw "Token HDFS vide. Reponse : $raw" }
    $t
}

function New-RmToken {
    $raw = Invoke-Sso "$($c.RmWeb)/ws/v1/cluster/delegation-token" "POST" ('{"renewer":"' + $c.Renewer + '"}')
    $t = ($raw | ConvertFrom-Json).token
    if (-not $t) { throw "Token RM vide. Reponse : $raw" }
    $t
}

function Revoke-HdfsToken($tok) {
    if (-not $tok) { return }
    try { Invoke-Sso "$($c.NameNodeWeb)/webhdfs/v1/?op=CANCELDELEGATIONTOKEN&token=$tok" "PUT" | Out-Null }
    catch { Ecrire "  (revocation HDFS ignoree : $($_.Exception.Message))" }
}

function Revoke-RmToken($tok) {
    if (-not $tok) { return }
    try { Invoke-Sso "$($c.RmWeb)/ws/v1/cluster/delegation-token" "DELETE" $null `
                     @{ "X-Hadoop-Delegation-Token" = $tok } | Out-Null }
    catch { Ecrire "  (revocation RM ignoree : $($_.Exception.Message))" }
}

# suivi des sessions dans le registre
function Get-SessionKey($id) { "$REG_SESS\$id" }

function Remove-Session($id) {
    $k = Get-SessionKey $id
    if (-not (Test-Path $k)) { return }
    $s = Get-ItemProperty -Path $k
    Revoke-HdfsToken $s.HdfsToken
    Revoke-RmToken   $s.RmToken
    if ($s.TokenFile -and (Test-Path $s.TokenFile)) {
        $crc = Join-Path (Split-Path $s.TokenFile) (".$(Split-Path $s.TokenFile -Leaf).crc")
        Remove-Item $s.TokenFile, $crc -ErrorAction SilentlyContinue
    }
    Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue
}

function Clear-OrphanSessions {
    if (-not (Test-Path $REG_SESS)) { return }
    foreach ($k in Get-ChildItem $REG_SESS) {
        $id = $k.PSChildName
        if ($id -eq "$PID") { continue }
        if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
            Ecrire "Revocation du token de la session $id (terminee)"
            Remove-Session $id
        }
    }
}

# mode revocation : appele a la fermeture de session
if ($Cancel) {
    Remove-Session $PID
    Ecrire "Tokens de la session $PID revoques."
    return
}

# fabrication du fichier de credentials
function Write-CredsFile($chemin, $hdfsTok, $rmTok) {
    $cp = (hdfs classpath | Out-String).Trim()
    $sauve = $env:HADOOP_TOKEN_FILE_LOCATION
    $env:HADOOP_TOKEN_FILE_LOCATION = $null
    $eap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $sortie = & java -cp "$cp;$($c.ToolsPath)" MakeCredsFile $chemin `
      HDFS_DELEGATION_TOKEN "$hdfsTok" "$($c.ServiceIp):$($c.HdfsRpcPort)" `
      HDFS_DELEGATION_TOKEN "$hdfsTok" "$($c.ServiceFqdn):$($c.HdfsRpcPort)" `
      RM_DELEGATION_TOKEN   "$rmTok"   "$($c.ServiceIp):$($c.RmRpcPort)" `
      RM_DELEGATION_TOKEN   "$rmTok"   "$($c.ServiceFqdn):$($c.RmRpcPort)" 2>&1
    $code = $LASTEXITCODE

    $ErrorActionPreference = $eap
    $env:HADOOP_TOKEN_FILE_LOCATION = $sauve

    if (-not $Quiet) { $sortie | ForEach-Object { Write-Host $_ } }
    if ($code -ne 0)          { throw "MakeCredsFile a echoue (code $code)" }
    if (-not (Test-Path $chemin)) { throw "Le fichier $chemin n'a pas ete cree" }
}

# 1. token jetable pour un job (R, Python, spark-submit)
if ($Out) {
    Write-CredsFile $Out (New-HdfsToken) (New-RmToken)
    return
}

# 2. token de session
Clear-OrphanSessions
Remove-Session $PID          # revoque et efface l'eventuel token precedent

if (-not (Test-Path $c.TokenDir)) { New-Item -ItemType Directory -Path $c.TokenDir -Force | Out-Null }
$fichier = Join-Path $c.TokenDir "hadoop-$PID.dt"

$hdfsTok = New-HdfsToken
$rmTok   = New-RmToken
Write-CredsFile $fichier $hdfsTok $rmTok

$k = Get-SessionKey $PID
New-Item -Path $k -Force | Out-Null
New-ItemProperty -Path $k -Name "TokenFile" -Value $fichier   -PropertyType String -Force | Out-Null
New-ItemProperty -Path $k -Name "HdfsToken" -Value $hdfsTok   -PropertyType String -Force | Out-Null
New-ItemProperty -Path $k -Name "RmToken"   -Value $rmTok     -PropertyType String -Force | Out-Null
New-ItemProperty -Path $k -Name "Created"   -Value (Get-Date).ToString("s") -PropertyType String -Force | Out-Null

[Environment]::SetEnvironmentVariable("HADOOP_TOKEN_FILE_LOCATION", $fichier, "User")
$env:HADOOP_TOKEN_FILE_LOCATION = $fichier
Ecrire "Tokens de session ($env:USERNAME, renewer=$($c.Renewer)) : $fichier"