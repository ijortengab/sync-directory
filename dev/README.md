## README

How to develop this project.

## Prepare

Put this directory at beginning in $PATH.

Example:

```
PATH=~/github.com/ijortengab/sync-directory/dev:$PATH
```

Make sure the command of `sync-directory.sh`, using file from `dev` directory.

```
which sync-directory.sh
```

## Ngoprek

Just **utak-atik** `sync-directory.sh` file inside `dev` directory.

## Build

Execute `./build.sh` to create `sync-directory.sh` file in the root of Git Repo.

Switch to master branch `. back.sh`.

Pull `sync-directory.sh` file from devel branch: `./get.sh`.

Add file to staged, then commit in master branch.

```
git add sync-directory.sh
git commit -m
```
