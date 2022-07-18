#!/bin/bash

# Populate parent_dir
_file=$(realpath "$0")
_dir=$(dirname "$_file")
file_="${_dir}/sync-directory.sh"
parent_dir=$(realpath "$_dir"/../)

cp -rf "$file_" -t "$parent_dir"

file="${parent_dir}/sync-directory.sh"

# Replace string
FILE2=$(<"$file") && \
FILE1=$(<"${_dir}/parse-1-main.txt") && \
echo "${FILE2//source \$(dirname \$0)\/parse-1-main.txt/$FILE1}" > "$file"

# Remove string
sed -i '/source \$(dirname \$0)\/debug-1-main.txt/d' "$file"
sed -e '/var-dump\.function\.sh/d' -e '/^VarDump/d' -e '/^# VarDump/d' -i "$file"

git diff "$file"