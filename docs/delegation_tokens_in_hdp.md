# Delegation tokens in hdp 

The hadoop cluster offers two authentication methods: `kerberos ticket` and `Delegation TOKEN`. Since we can't use
the kerberos ticket in Windows, so we try to use the `Delegation TOKEN`.

## What is a delegation token

`Hadoop Delegation Tokens` are `lightweight, short-lived authentication credentials` issued by Hadoop master services 
(such as the `HDFS NameNode or YARN ResourceManager`) after an initial Kerberos authentication. They solve the 
scalability bottleneck of Kerberos in large distributed systems.

For example, If you have a 1,000-node HDFS cluster, and whenever reading an HDFS block, you have to authenticate 
directly with a KDC on every worker node. The KDC would immediately crash under the load.

Delegation tokens allow a client to authenticate once with Kerberos, retrieve a token from the Hadoop service, 
and pass that token to thousands of worker tasks to access resources on the client's behalf.


## How the delegation token works

1. `Initial Kerberos Authentication`: The client (e.g., a user submitting a Spark job) authenticates with the Kerberos KDC.

2. `Token Request`: The client contacts the HDFS NameNode (or YARN ResourceManager) over a secure RPC connection and requests a Delegation Token.

3. `Token Issuance`: The NameNode generates a token containing `user identity, token ID, issue date, max lifetime, and a renewer ID`. 
          It signs the token using a secret key known only to the NameNode cluster and returns it to the client.

4. `Distribution to Workers`: The client embeds the delegation token into the application submission package sent to `YARN ApplicationMaster`.

5. `Task Execution`: Worker nodes use the token in place of Kerberos credentials to read/write HDFS data or register YARN containers. 
                The service validates the token using its internal secret key without contacting Kerberos.

6. `Renewal and Cancellation`: The token renewer (often the `ApplicationMaster`) periodically renews the token. 
       Once the job completes, the token is explicitly cancelled.


## Some default values of the token

|Attribute,Default Value,Description|
Renewal Interval,24 Hours,How often a token must be actively renewed before expiring.
Max Lifetime,7 Days,The maximum hard cap lifespan of a token; cannot be renewed past this point.
Validation,Local HMAC-SHA1,Services validate tokens using shared master secrets—zero KDC traffic.


In my case, the client is a Windows server, and the user already have Kerberos TGT ticket in his logon session(Step1 is ok).
For step2, I must use a Windows native service which can read TGT of LSA, so 
Explain the delegation tokens, mécanisme natif de Hadoop (celui qu'utilise YARN pour ses jobs). Le circuit :

un appel HTTP authentifié par le SSO Windows (SPNEGO via SSPI) demande un token au NameNode via WebHDFS, et un token au ResourceManager via son API REST
un petit outil Java (MakeCredsFile) convertit ces tokens en fichier de credentials Hadoop (hadoop.dt)
les clients Java (hdfs, yarn, spark-submit) chargent ce fichier via la variable HADOOP_TOKEN_FILE_LOCATION et s'authentifient en SASL/TOKEN. Plus aucune cryptographie Kerberos côté Java.