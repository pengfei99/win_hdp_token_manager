# Delegation token convertor

This project aims to convert a base64 encoded Hadoop cluster delegation token into a binary file and stores it
in a specific file path.

For more information about what is a Hadoop cluster delegation token, you can visit this
page [delegation_tokens_in_hdp.md](../docs/delegation_tokens_in_hdp.md).

## 1. Java class

`org.casd.util.MakeCredsFile` — a utility class that reads one or more base64
encoded Hadoop delegation token strings, validates them, and writes them to a
binary Hadoop *credentials storage file* (the same format read via
`HADOOP_TOKEN_FILE_LOCATION`).

Each token is wrapped in a Hadoop `org.apache.hadoop.security.token.Token` and
registered in an `org.apache.hadoop.security.Credentials` object, including its
*kind* and *service* identity, before being serialized with
`Credentials.writeTokenStorageFile`.

### 1.1 What it validates

| Token aspect | Rule |
|--------------|------|
| Kind         | Only `HDFS_DELEGATION_TOKEN` or `RM_DELEGATION_TOKEN` are accepted. |
| Service      | Must be `fqdn:port` or `ip:port` form; port must be in `1..65535`. |
| Token string | Must be a valid base64 encoded token, length at least 40 chars. |

> The token string itself must already be the encoded form produced by a source
> such as the WebHDFS/Web YARN REST API (`JsonUtil.toJson` / base64 of the
> token's `Token.identifier`). This tool does not request tokens from Hadoop —
> it only serializes already-obtained token strings.

## 2. Project architecture

```text
make-creds-file/
├── pom.xml
├── README.md
└── src/main/java/org/casd/util/
    └── MakeCredsFile.java
```
### 2.1 Project Requirements

- **JDK 11+** (the project compiles with `--release 11`)
- **Maven 3.9.x+**
- At runtime (lightweight jar): Hadoop libraries must be on the classpath
  (e.g. set `HADOOP_CLASSPATH` or use `hdfs classpath`), or use the fat jar
  which bundles `hadoop-common`.

## 3. How to build

```shell
# go to project root folder
cd token_convertor

# compile the source file
mvn clean compile

# compile, run tests and build the jar
mvn clean package

# skip unit test
mvn clean package -DskipTests

# run unit tests
mvn test
```

- **Lightweight JAR** (default): `hadoop-common` is `<scope>provided</scope>`,
  so the JAR is small but requires Hadoop on the classpath at runtime. Build with
  `mvn clean package`.
- **Self-Contained Fat JAR (~50 MB)**: remove the `<scope>provided</scope>`
  line from `hadoop-common` in `pom.xml`, then `mvn clean package`. The
  `maven-shade-plugin` bundles all dependencies and sets the main class in the
  manifest.

Output JAR (lightweight and fat) is written to:

```text
# lightweight jar
token_convertor/target/make-creds-file-1.0.0-SNAPSHOT.jar

# fat jar
token_convertor/target/make-creds-file-1.0.0-SNAPSHOT-shaded.jar
```

> This filename is hardcoded and referenced by `refresh-tokens.ps1` and
> `test_convertor.ps1` — do not rename it during dev.

## 4. Usage

### 4.1 Parameters

```
java [-cp <classpath>] org.casd.util.MakeCredsFile <outFile> (<kind> <encodedTokenString> <service>)...
```

| Argument             | Description                                                    |
|----------------------|----------------------------------------------------------------|
| `outFile`            | Path of the binary credentials (`.dt`) file to write.          |
| `kind`               | Token kind — `HDFS_DELEGATION_TOKEN` or `RM_DELEGATION_TOKEN`. |
| `encodedTokenString` | The base64 encoded delegation token string.                    |
| `service`            | Target service as `fqdn:port` or `ip:port`.                    |

You may pass any number of tokens; each token consumes **3** consecutive
arguments (`kind`, `encodedTokenString`, `service`).

### 4.2 Run the fat jar

```shell
java -jar target/make-creds-file-1.0.0-SNAPSHOT.jar \
    out.dt \
    HDFS_DELEGATION_TOKEN "AAPj/wIAAAE..." "nn01.cluster.example.com:8020"
```

### 4.3 Run the lightweight jar

The lightweight jar needs Hadoop on the classpath. On Linux use the
`hdfs classpath` command to build the classpath:

```shell
export CLASSPATH="$(hdfs classpath --glob):target/make-creds-file-1.0.0-SNAPSHOT.jar"
java org.casd.util.MakeCredsFile \
    out.dt \
    HDFS_DELEGATION_TOKEN "AAPj/wIAAAE..." "nn01.cluster.example.com:8020"
```

### 4.4 Multiple tokens in one call

```shell
java -jar target/make-creds-file-1.0.0-SNAPSHOT.jar out.dt \
    HDFS_DELEGATION_TOKEN "<hdfsToken>" "nn01.cluster.example.com:8020" \
    RM_DELEGATION_TOKEN   "<rmToken>"   "rm01.cluster.example.com:8050"
```

### 4.5 Output

On success a binary credentials file is written to `outFile`, and a log line is
printed:

```text
Successfully generated credentials file: /path/to/out.dt
```

The generated file (plus its `<name>.crc` sidecar) is what you point
`HADOOP_TOKEN_FILE_LOCATION` at for clients such as HDFS, YARN, Spark, and the
adapters in this repository.

## 5. Exit codes

| Code | Meaning                          |
|------|----------------------------------|
| `0`  | Success.                         |
| `1`  | I/O or serialization failure.    |
| `2`  | Invalid arguments (usage error). |

## 6. Notes / Gotchas

- In **PowerShell**, ensure empty variables are not dropped from the argument
  list — wrap each token argument in quotes, otherwise an empty variable can
  shift the positional arguments and break token alignment.
- Only `HDFS_DELEGATION_TOKEN` and `RM_DELEGATION_TOKEN` are supported; any
  other kind fails with exit code `2`.
