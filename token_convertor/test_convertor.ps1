# 1. Retrieve the local Hadoop classpath
$hadoopCp = (hdfs classpath | Out-String).Trim()

# 2. Combine with your compiled JAR path using a semicolon ';'
$fullCp = "$hadoopCp;target/make-creds-file-1.0.0-SNAPSHOT.jar"

# to get the token string, you need to run:
# curl -k --negotiate -u : "https://deb13-spark1.casdds.casd:50470/webhdfs/v1/?op=GETDELEGATIONTOKEN&renewer=hdfs"
# make sure you have a valid kerberos before running this command.
$tokenStr = "IgAHcGxpdS1hZARoZGZzAIoBn-wMxPSKAaAQGUj0jgE_j9gU6yi6RBmIDbDA2hOzqdolWkuNbAgTU1dFQkhERlMgZGVsZWdhdGlvbhAxMC41MC41LjIwMzo5MDAw"

$serviceStr = "10.50.5.224:8020"

# 3. Execute
java -cp $fullCp org.casd.util.MakeCredsFile `
  "C:\Users\pliu\Documents\git\win_hdp_token_manager\token_convertor\tmp\creds.dt" `
  "HDFS_DELEGATION_TOKEN" "$tokenStr" "$serviceStr"