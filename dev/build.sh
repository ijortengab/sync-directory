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
FILE1=$(<"${_dir}/parse-options-1-core.txt") && \
echo "${FILE2//source \$(dirname \$0)\/parse-options-1-core.txt/$FILE1}" > "$file"

# Replace string
FILE2=$(<"$file") && \
FILE1=$(<"${_dir}/parse-options-2-start.txt") && \
echo "${FILE2//source \$(dirname \$0)\/parse-options-2-start.txt/$FILE1}" > "$file"

# Remove string
sed -i '/source \$(dirname \$0)\/parse-options-1-core-debug.txt/d' "$file"
sed -i '/source \$(dirname \$0)\/parse-options-2-start-debug.txt/d' "$file"
sed -e '/var-dump\.function\.sh/d' -e '/^[# ]*VarDump/d' -i "$file"

# Trim Trailing Space
sed -i -e 's/[ ]*$//'  "$file"
git diff "$file"
