$TOKEN_GEN_JAR_NAME = "make-creds-file-1.0.0-SNAPSHOT-shaded.jar"
$jar_path = "jars/$TOKEN_GEN_JAR_NAME"
$tokenStr = "IgAHcGxpdS1hZARoZGZzAIoBn-wMxPSKAaAQGUj0jgE_j9gU6yi6RBmIDbDA2hOzqdolWkuNbAgTU1dFQkhERlMgZGVsZWdhdGlvbhAxMC41MC41LjIwMzo5MDAw"
$serviceStr = "127.0.0.1:8088"
$DestinationPath = "C:\Users\pliu\Documents\git\win_hdp_token_manager\token_convertor\tmp\creds.dt"

$javaArgs = @(
    "-jar", "$jar_path",
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


# java -jar target/make-creds-file-1.0.0-SNAPSHOT.jar \
#    $DestinationPath \
#    HDFS_DELEGATION_TOKEN $tokenStr $serviceStr