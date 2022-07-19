#!/bin/bash

parse-options.sh \
    --compact \
    --clean \
    --no-error-invalid-options \
    --no-error-require-arguments \
    --no-hash-bang \
    --no-original-arguments \
    --without-end-options-double-dash \
    --output-file parse-options-2-start.txt \
    --debug-file parse-options-2-start-debug.txt \
    << EOF
LEADING_SPACE='    '
FLAG=(
    --pull-all
    --pull-latest
)
VALUE=(
    '--pull'
    '--exclude|-e'
)
EOF
