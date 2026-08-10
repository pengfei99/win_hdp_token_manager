# Delegation token convertor

This project aims to convert a base64 encoded hadoop cluster delegation token into a binary file and stores it
in a specific file path.

For more information about what is a hadoop cluster delegation token, you can visit this
page [delegation_tokens_in_hdp.md](../docs/delegation_tokens_in_hdp.md).

It depends on the

## 1. Project architecture

```text
make-creds-file/
├── pom.xml
├── README.md
└── src/main/java/org/casd/util/
    └── MakeCredsFile.java
```

### 1.1 Key points of project setup

| Item              | Choice              | Why                                      |
|-------------------|---------------------|------------------------------------------|
| Package           | org.casd.util       | Proper Maven layout (no default package) |
| Java version      | 11 (--release 11)   | Matches the java version of hadoop 3.3.6 |
| Hadoop dependency | hadoop-common:3.5.0 | Latest stable version                    |
| Packaging         | Executable JAR      | thin or fat based on user requirement    |
| Build system      | maven 3.9.x+        | Produces a clean, reproducible release   |

> This project requires jdk 11+ and maven 3.9.x+

## 2. How to build

```shell
# go to project root folder
cd token_convertor

# compile the source file 
mvn clean compile

# run unit tests
mvn test 
```

To create a Lightweight jar without hadoop-common dependencies, set `hadoop-common` to `<scope>provided</scope>`

```xml
 <dependency>
            <groupId>org.apache.hadoop</groupId>
            <artifactId>hadoop-common</artifactId>
            <version>${hadoop.version}</version>
            <scope>provided</scope>
            <exclusions>
...
```
and run `mvn clean package`

To create a Self-Contained Fat JAR (~50 MB) with the `maven-shade-plugin`, you only need to remove the line `<scope>provided</scope>`.
and run `mvn clean package`


## 3. How to run the application

