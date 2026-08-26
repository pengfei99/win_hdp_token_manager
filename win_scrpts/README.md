
## User profile token wrapper

Session Token: Acquire a fresh set of tokens every time a new console opens.
a global session token for all basic operations such as hdfs, yarn
For spark-submit we need a new token, because hadoop will revoke the token
after the job is finished, if we use the global token for spark-submit,
after the job is finished, we can not do hdfs or yarn command.
The old token is revoked during this process, similar to a Kerberos logon.