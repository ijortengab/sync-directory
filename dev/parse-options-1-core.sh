#!/bin/bash
OPTIONS4EMBED='--compact --clean --no-error-invalid-options --no-error-require-arguments --no-hash-bang --no-original-arguments'
parse-options.sh \
    $OPTIONS4EMBED \
    --without-end-options-double-dash \
    --with-end-options-specific-operand \
    --output-file parse-options-1-core.txt \
    --debug-file parse-options-1-core-debug.txt \
    << EOF
OPERAND=(
    test
    start
    status
    stop
    update
    restart
    get
    rsync
    push
    pull
)
VALUE=(
    '--myname|-n'
    '--remote-dir-file|-f'
    '--directory|-d'
)
MULTIVALUE=(
    '--remote-dir|-r'
    '--ignore|-i'
)
EOF
