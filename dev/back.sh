#!/bin/bash

# Back to default branch (master).
git switch -

# Back to parent directory.
_file=$(realpath "$0")
_dir=$(dirname "$_file")
parent_dir=$(realpath "$_dir"/../)
cd "$parent_dir"

# Copy file from devel branch.
git restore --source=master sync-directory.sh
