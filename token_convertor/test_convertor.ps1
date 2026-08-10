# 1. Retrieve the local Hadoop classpath
$hadoopCp = (hdfs classpath | Out-String).Trim()

# 2. Combine with your compiled JAR path using a semicolon ';'
$fullCp = "$hadoopCp;target/make-creds-file-1.0.0-SNAPSHOT.jar"

# 3. Execute
java -cp $fullCp org.casd.util.MakeCredsFile `
  "C:\tmp\creds.bin" `
  "HDFS_DELEGATION_TOKEN" "JQAIaG9y..." "10.0.0.1:8020" `