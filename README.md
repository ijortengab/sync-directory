# Sync Directory

Inspired from galeracluster, instead of database, this is codebase synchronous replication for multi master/node.

# How to use

- You must create Host Alias for every node in `$HOME/.ssh/config` files.
- Make sure you can ssh using only key method, not password.
- Just create ini file format, then describe the full path of directory.
- Execute this shell script, or set as cronjob.

Example of ini file:

```
[pcone]
directory=/cygwin/d/centra
[pctwo]
directory=/cygwin/d/centra
[pcbackup]
directory=/mnt/backup
```

Command Argument:

--cluter-name / -c : Set the name of cluster. This is the name of directory ini `dev/shm`.
--nodes-ini-file / -i : Ini file that descript the node/master.
-my-name / -n : This host name.
