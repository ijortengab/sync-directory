# Sync Directory

Inspired from galeracluster, instead of database, this is codebase synchronous replication for multi master/node.

## How to use

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

```
OPTIONS SUMMARY

    -c, --cluter-name       Set the name of cluster.
                            This is the name of directory in `/dev/shm`.
    -i, --nodes-ini-file    Ini file that map between hostname and their
                            directory.
    -n, --my-name           This hostname.
    -e, --exclude           Exclude regex pattern. Multivalue.
```

## References

 - Google: sed read ini file
   https://stackoverflow.com/a/22559504
   https://gist.github.com/thomedes/6201620
 - Google: inotifywait example
   https://unix.stackexchange.com/q/323901
 - Google: sed change line number
   https://unix.stackexchange.com/a/70879
 - Google: while read contains space
   https://stackoverflow.com/a/7314111
 - Google: rsync file contains spaces
   https://unix.stackexchange.com/a/137285
