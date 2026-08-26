# 1. Retrieve the local Hadoop classpath
$hadoopCp = (hdfs classpath | Out-String).Trim()

# 2. Combine with your compiled JAR path using a semicolon ';'
$TOKEN_GEN_JAR_NAME = "make-creds-file-1.0.0-SNAPSHOT.jar"
$fullCp = "$hadoopCp;target/$TOKEN_GEN_JAR_NAME"
$TOKEN_GEN_CLASS_NAME = "org.casd.util.MakeCredsFile"
$DestinationPath = "C:\Users\pliu\Documents\git\win_hdp_token_manager\token_convertor\tmp\creds.dt"
# to get the token string, you need to run:
# curl -k --negotiate -u : "https://deb13-spark1.casdds.casd:50470/webhdfs/v1/?op=GETDELEGATIONTOKEN&renewer=hdfs"
# make sure you have a valid kerberos before running this command.
$tokenStr = "IgAHcGxpdS1hZARoZGZzAIoBn-wMxPSKAaAQGUj0jgE_j9gU6yi6RBmIDbDA2hOzqdolWkuNbAgTU1dFQkhERlMgZGVsZWdhdGlvbhAxMC41MC41LjIwMzo5MDAw"

$serviceStr = "127.0.0.1:8088"
# 3. Execute
$javaArgs = @(
    "-cp", "$fullCp",
    "$TOKEN_GEN_CLASS_NAME",
    $DestinationPath,
    "HDFS_DELEGATION_TOKEN", "$tokenStr", "$serviceStr")

$output = & java @javaArgs 2>&1

$output | ForEach-Object {
    if ($_ -match "ERROR|Exception|Fail")
    {
        Write-Host $_ -ForegroundColor Red
    }
    else
    {
        Write-Host $_
    }
}

# the above command is like below
#java -cp $fullCp "$TOKEN_GEN_CLASS_NAME" `
#  "C:\Users\pliu\Documents\git\win_hdp_token_manager\token_convertor\tmp\creds.dt" `
#  "HDFS_DELEGATION_TOKEN" "$tokenStr" "$serviceStr"