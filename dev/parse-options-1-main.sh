#!/bin/bash

parse-options.sh \
    --compact \
    --clean \
    --no-error-invalid-options \
    --no-error-require-arguments \
    --no-hash-bang \
    --no-original-arguments \
    --without-end-options-double-dash \
    --output-file parse-1-main.txt \
    --debug-file debug-1-main.txt \
    << EOF
VALUE=(
    '--cluster-name|-c'
    '--myname|-n'
    '--cluster-file|-f'
)
MULTIVALUE=(
    '--exclude|-e'
)
EOF
