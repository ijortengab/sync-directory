#!/bin/bash

if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    if [[ "$0" =~ todev\.sh$ ]];then
        echo 'Cara penggunaan yang benar adalah `. todev.sh`'
    else
        git switch devel
        cd $PWD/dev/
    fi
fi
