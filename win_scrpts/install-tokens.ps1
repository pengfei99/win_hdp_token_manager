
param(
    [string] $NameNodeWeb = "https://deb13-spark1.casdds.casd:50470",
    [string] $RmWeb       = "https://deb13-spark1.casdds.casd:8090",
    [string] $ServiceIp   = "10.50.5.203",
    [string] $ServiceFqdn = "deb13-spark1.casdds.casd",
    [string] $Renewer     = "hdfs",
    [string] $HdfsRpcPort = "9000",
    [string] $RmRpcPort   = "8032",
    [string] $StagingDir  = "hdfs://deb13-spark1.casdds.casd:9000/users",
    [int]    $DriverPort  = 20000
)

$ErrorActionPreference = "Stop"
$tools  = $PSScriptRoot
$REG    = "HKCU:\Software\CASD\Hadoop"
$profil = $PROFILE.CurrentUserAllHosts        # valable console ET ISE
$marker = "# === HDFS/YARN/Spark delegation tokens ==="

# controles
if (-not (Test-Path (Join-Path $tools "refresh-tokens.ps1"))) {
    throw "refresh-tokens.ps1 introuvable dans $tools"
}
if (-not $env:HADOOP_HOME) { Write-Warning "HADOOP_HOME n'est pas defini." }
if (-not $env:SPARK_HOME)  { Write-Warning "SPARK_HOME n'est pas defini." }

# 1. configuration en base de registre
$tokenDir = Join-Path $env:LOCALAPPDATA "CASD\tokens"
New-Item -Path $REG -Force | Out-Null

$conf = @{
    ToolsPath   = $tools
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
foreach ($k in $conf.Keys) {
    New-ItemProperty -Path $REG -Name $k -Value $conf[$k] -PropertyType String -Force | Out-Null
}
New-ItemProperty -Path $REG -Name "DriverPort" -Value $DriverPort -PropertyType DWord -Force | Out-Null

New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null
Write-Host "Configuration ecrite dans $REG"

# 2. bloc du profil PowerShell
foreach ($f in 'spark-submit','hdfs','yarn','spark-run') {
    Remove-Item "Function:\$f" -ErrorAction SilentlyContinue
}
if (-not (Test-Path $profil)) { New-Item -ItemType File -Path $profil -Force | Out-Null }

if (Select-String -Path $profil -Pattern $marker -SimpleMatch -Quiet) {
    Write-Host "Bloc deja present dans $profil - rien a ajouter."
}
else {
    $bloc = @"

$marker

# Token de session : un jeu neuf a chaque ouverture de console.
# L'ancien est revoque au passage, comme un ticket Kerberos au logon.
& '$tools\refresh-tokens.ps1' -Quiet

# Revocation a la fermeture de la console (equivalent d'un logout).
Register-EngineEvent PowerShell.Exiting -SupportEvent -Action {
    & '$tools\refresh-tokens.ps1' -Cancel -Quiet
} | Out-Null

# spark-submit : le job recoit un token jetable, le token de session est preserve
function spark-submit {
    `$jobDt = Join-Path `$env:TEMP "hadoop-job-`$PID.dt"
    & '$tools\refresh-tokens.ps1' -Out `$jobDt -Quiet
    `$save = `$env:HADOOP_TOKEN_FILE_LOCATION
    `$env:HADOOP_TOKEN_FILE_LOCATION = `$jobDt
    try {
        & "`$env:SPARK_HOME\bin\spark-submit.cmd" @args
    }
    finally {
        `$env:HADOOP_TOKEN_FILE_LOCATION = `$save
        Remove-Item `$jobDt -ErrorAction SilentlyContinue
        Remove-Item (Join-Path `$env:TEMP ".hadoop-job-`$PID.dt.crc") -ErrorAction SilentlyContinue
    }
}
"@
    Add-Content -Path $profil -Value $bloc
    Write-Host "Bloc ajoute a $profil"
}

# 3. premier token
& (Join-Path $tools "refresh-tokens.ps1")

Write-Host ""
Write-Host "Installation terminee." -ForegroundColor Green
Write-Host "Ouvrir une NOUVELLE console PowerShell, puis tester :"
Write-Host "    hdfs dfs -ls /"
Write-Host "    spark-submit --deploy-mode cluster --master yarn mon_job.py"