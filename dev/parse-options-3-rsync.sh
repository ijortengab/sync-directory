#!/bin/bash

parse-options.sh \
    --compact \
    --clean \
    --no-error-invalid-options \
    --no-error-require-arguments \
    --no-hash-bang \
    --no-original-arguments \
    --output-file parse-options-3-rsync.txt \
    --debug-file parse-options-3-rsync-debug.txt \
    << EOF
LEADING_SPACE='    '
FLAG=(
    --pull
    --push
    --latest
    --all
    --parallel
)
VALUE=(
    '--path|-p'
)
MULTIVALUE=(
    '--target|-t'
)
EOF
