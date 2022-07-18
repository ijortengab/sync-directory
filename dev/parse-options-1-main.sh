#!/bin/bash

parse-options.sh \
    --compact \
    --clean \
    --no-error-invalid-options \
    --no-error-require-arguments \
    --no-hash-bang \
    --no-original-arguments \
    --without-end-options-double-dash \
    --with-end-options-specific-operand \
    --output-file parse-1-main.txt \
    --debug-file debug-1-main.txt \
    << EOF
OPERAND=(
    test
    start
    status
    stop
    update-latest
    update
    restart
    get-file
)
VALUE=(
    '--cluster-name|-c'
    '--myname|-n'
    '--remote-dir-file|-f'
)
MULTIVALUE=(
    '--exclude|-e'
    '--remote-dir|-r'
)
EOF
