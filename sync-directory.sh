#!/bin/bash
#
# https://github.com/ijortengab/sync-directory
# http://ijortengab.id

# Dependencies.
command -v "ssh" >/dev/null || { echo "ssh command not found."; exit 1; }
command -v "rsync" >/dev/null || { echo "rsync command not found."; exit 1; }
command -v "screen" >/dev/null || { echo "screen command not found."; exit 1; }
command -v "inotifywait" >/dev/null || { echo "inotifywait command not found."; exit 1; }

# Parse Options.
_new_arguments=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cluster-name=*|-c=*) cluster_name="${1#*=}"; shift ;;
        --cluster-name|-c) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then cluster_name="$2"; shift; fi; shift ;;
        --exclude=*|-e=*) exclude+=("${1#*=}"); shift ;;
        --exclude|-e) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then exclude+=("$2"); shift; fi; shift ;;
        --myname=*|-n=*) myname="${1#*=}"; shift ;;
        --myname|-n) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then myname="$2"; shift; fi; shift ;;
        --nodes-ini-file=*|-i=*) nodes_ini_file="${1#*=}"; shift ;;
        --nodes-ini-file|-i) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then nodes_ini_file="$2"; shift; fi; shift ;;
        *) _new_arguments+=("$1"); shift ;;
    esac
done

set -- "${_new_arguments[@]}"

_new_arguments=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -[^-]*) OPTIND=1
            while getopts ":c:e:n:i:" opt; do
                case $opt in
                    c) cluster_name="$OPTARG" ;;
                    e) exclude+=("$OPTARG") ;;
                    n) myname="$OPTARG" ;;
                    i) nodes_ini_file="$OPTARG" ;;
                esac
            done
            shift "$((OPTIND-1))"
            ;;
        *) _new_arguments+=("$1"); shift ;;
    esac
done

set -- "${_new_arguments[@]}"

unset _new_arguments

# Verification.
[ -n "$myname" ] || { echo "Argument --myname (-n) required.">&2; exit 1; }
[ -n "$nodes_ini_file" ] || { echo "Argument --nodes-ini-file (-i) required.">&2; exit 1; }

# Populate variables
list_all=$(grep -o -P "^\[\K([^\[\]]+)" "$nodes_ini_file")
list_other=

# Verification of myname and populate variable $list_other.
found=
while IFS= read -r line; do
    [[ "$line" == "$myname" ]] && found=1 || list_other+="$line"$'\n'
done <<< "$list_all"
[ -n "$found" ] || { echo "My hostname '$myname' not found in '$nodes_ini_file'.">&2; exit 1; }
[ -n "$list_other" ] && list_other=${list_other%$'\n'} # trim trailing \n

# @todo, pull node terupdate.

# Populate variable associative array.
declare -A DIRECTORIES
found=
while IFS= read -r hostname; do
    _directory=$(sed -n '/^[ \t]*\['"$hostname"'\]/,/\[/s/^[ \t]*directory[ \t]*=[ \t]*//p' "$nodes_ini_file")
    [ -n "$_directory" ] && DIRECTORIES+=( ["$hostname"]="${_directory%/}" ) || found="$hostname"
done <<< "$list_all"
[ -n "$found" ] && { echo "Directory of '$found' not found in '$nodes_ini_file'.">&2; exit 1; }

# Populate variable $mydirectory.
mydirectory="${DIRECTORIES[$myname]}"

case "$1" in
    test)
        while IFS= read -r hostname; do
            echo '- Test connect to host '"$hostname"'.'
            echo -n '  '; ssh "$hostname" 'echo -e "\e[32mSuccess\e[0m"'
            if [[ $? == 0 ]];then
                echo '  Test connect back from host '"$hostname"' to '"$myname"
                echo -n '  '; ssh "$hostname" 'ssh "'"$myname"'" echo -e "\\\e[32mSuccess\\\e[0m"'
                if [[ $? == 0 ]];then
                    file=$(mktemp)
                    content=$RANDOM
                    echo $content > $file
                    echo '  Test host '"$hostname"' pull a file from '"$myname"
                    echo -n '  '; ssh "$hostname" '
                        temp=$(mktemp)
                        rsync -avr "'"$myname"'":"'"$file"'" "'"$file"'" &> $temp
                        [[ "'"$content"'" == $(<"'"$file"'") ]] && echo -e "\e[32mSuccess\e[0m" || cat $temp
                        rm "'"$file"'" $temp
                        '
                fi
            fi
        done <<< "$list_other"
        exit 0
        ;;
    watch)
        [ -n "$cluster_name" ] || { echo "Argument --cluster-name (-c) required.">&2; exit 1; }
    ;;
    *)
        echo Command unknown. Command available: test, watch.
        exit 1
esac

# Populate variable $object_watched, $format, and $bin.
object_watched="$mydirectory"
object_watched_2="$queue_file"
bin=$(command -v inotifywait)

instance_dir="/dev/shm/${cluster_name}"
mkdir -p "$instance_dir"
queue_file="${instance_dir}/_queue.txt"
line_file="${instance_dir}/_line.txt"
log_file="${instance_dir}/_log.txt"
queue_watcher="${instance_dir}/_queue_watcher.sh"

if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    object_watched=$(cygpath -w "$mydirectory")
    object_watched_2=$(cygpath -w "$queue_file")
    bin=$(cygpath -w "$bin")
fi

touch "$queue_file"
touch "$line_file"
touch "$log_file"
touch "$queue_watcher"
chmod a+x "$queue_watcher"

# ------------------------------------------------------------------------------
# Begin Bash Script.
cat <<'EOF' > "$queue_watcher"
#!/bin/bash
cluster_name="$1"; myname="$2"; nodes_ini_file="$3"
instance_dir="/dev/shm/${cluster_name}"; queue_file="${instance_dir}/_queue.txt"
line_file="${instance_dir}/_line.txt"; log_file="${instance_dir}/_log.txt"
command_file="${instance_dir}/_command.txt"
# List action result:
#1 ssh_rsync
#2 ssh_rm
#3 ssh_rename_file
#4 ssh_rename_dir
#5 ssh_mkdir
#6 ssh_mv_file
#7 ssh_mv_dir
parseLineContents() {
    local LINEBELOW _linecontent _linecontentbelow
    # Jika "$line_file" kehapus, maka pastikan baris yang sudah di proses
    # tidak lagi digunakan.
    sleep .5
    while true; do
        _linecontent=$(sed "$LINE"'q;d' "$queue_file")
        if [[ "${_linecontent:0:1}" == '=' ]];then
            let LINE++
            continue
        fi
        break
    done
    while true; do
        sleep .5
        _linecontent=$(sed "$LINE"'q;d' "$queue_file")
        _event=$(echo "$_linecontent" | cut -d' ' -f1)
        _state=$(echo "$_linecontent" | cut -d' ' -f2)
        _path=$(echo "$_linecontent" | sed 's|'"${_event} ${_state} "'||')
        let "LINEBELOW = $LINE + 1"
        _linecontentbelow=$(sed "$LINEBELOW"'q;d' "$queue_file")
        _eventbelow=$(echo "$_linecontentbelow" | cut -d' ' -f1)
        _statebelow=$(echo "$_linecontentbelow" | cut -d' ' -f2)
        _pathbelow=$(echo "$_linecontentbelow" | sed 's|'"${_eventbelow} ${_statebelow} "'||')
        if [[ "$_event" == "CREATE" && "$_state" == "(isfileisnotdir)" && "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
            # Contoh kasus:
            # touch a.txt (file belum ada sebelumnya)
            # echo 'anu' > a.txt (file belum ada sebelumnya)
            ACTION='ssh_rsync'
            ARGUMENT1="$_path"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
            let LINE++;
            break
        elif [[ "$_event" == "CREATE" && "$_state" == "(isfileisnotdir)" ]];then
            # Contoh kasus:
            # klik kanan pada windows explorer, new file.
            ACTION='ssh_rsync'
            ARGUMENT1="$_path"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            break
        elif [[ "$_event" == "MODIFY" && "$_state" == "(isfileisnotdir)" && "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
            # Contoh kasus:
            # echo 'anu' > a.txt (file sudah ada sebelumnya)
            ACTION='ssh_rsync'
            ARGUMENT1="$_path"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
            let LINE++;
            break
        elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "CREATE,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && $(basename "$_path") == $(basename "$_pathbelow") ]];then
            # Contoh kasus:
            # mv ini.d itu.d (directory itu.d sudah ada sebelumnya)
            ACTION='ssh_mv_dir'
            ARGUMENT1="$_path"
            ARGUMENT2="$_pathbelow"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
            let LINE++;
            break
        elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "CREATE" && "$_statebelow" == "(isfileisnotdir)" && $(basename "$_path") == $(basename "$_pathbelow") ]];then
            # Contoh kasus:
            # mv anu.txt itu.d (directory itu.d sudah ada sebelumnya)
            ACTION='ssh_mv_file'
            ARGUMENT1="$_path"
            ARGUMENT2="$_pathbelow"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
            let LINE++;
            break
        elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" ]];then
            # Contoh kasus:
            # rm a.txt (file sudah ada sebelumnya)
            ACTION='ssh_rm'
            ARGUMENT1="$_path"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            break
        elif [[ "$_event" == "MODIFY" && "$_state" == "(isfileisnotdir)" ]];then
            # Contoh kasus:
            # echo 'anu' >> a.txt (file sudah ada sebelumnya)
            ACTION='ssh_rsync'
            ARGUMENT1="$_path"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            break
        elif [[ "$_event" == "CREATE,ISDIR" && "$_state" == "(isnotfileisdir)" &&  "$_eventbelow" == "CREATE,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_pathbelow" =~ ^"$_path" ]];then
            # Contoh kasus:
            # mkdir -p aa/bb (directory belum ada sebelumnya)
            # mkdir -p cc/dd/ee (directory belum ada sebelumnya)
            ACTION='ssh_mkdir'
            ARGUMENT1="$_pathbelow"
            # Coret satu dulu.
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            let LINE++;
            # Restart:
            _linecontent="$_linecontentbelow"
            _event="$_eventbelow"
            _state="$_statebelow"
            _path=$"$_pathbelow"
            let "LINEBELOW = $LINE + 1"
            _linecontentbelow=$(sed "$LINEBELOW"'q;d' "$queue_file")
            _eventbelow=$(echo "$_linecontentbelow" | cut -d' ' -f1)
            _statebelow=$(echo "$_linecontentbelow" | cut -d' ' -f2)
            _pathbelow=$(echo "$_linecontentbelow" | sed 's|'"${_eventbelow} ${_statebelow} "'||')
            stop=
            until [[ -n "$stop" ]]; do
                if [[ "$_event" == "CREATE,ISDIR" && "$_state" == "(isnotfileisdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_path" =~ ^"$_pathbelow" ]];then
                    ARGUMENT1="$_path"
                    sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
                    sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
                    let LINE++;
                    # Test dulu:
                    let LINE++;
                    _linecontent=$(sed "$LINE"'q;d' "$queue_file")
                    _event=$(echo "$_linecontent" | cut -d' ' -f1)
                    _state=$(echo "$_linecontent" | cut -d' ' -f2)
                    _path=$(echo "$_linecontent" | sed 's|'"${_event} ${_state} "'||')
                    let "LINEBELOW = $LINE + 1"
                    _linecontentbelow=$(sed "$LINEBELOW"'q;d' "$queue_file")
                    _eventbelow=$(echo "$_linecontentbelow" | cut -d' ' -f1)
                    _statebelow=$(echo "$_linecontentbelow" | cut -d' ' -f2)
                    _pathbelow=$(echo "$_linecontentbelow" | sed 's|'"${_eventbelow} ${_statebelow} "'||')
                else
                    # Kembali ke line sebelumnya.
                    let LINE--;
                    stop=1
                fi
            done
            break
        elif [[ "$_event" == "CREATE,ISDIR" && "$_state" == "(isnotfileisdir)" ]];then
            ACTION='ssh_mkdir'
            ARGUMENT1="$_path"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            break
        elif [[ "$_event" == "MOVED_FROM" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "MOVED_TO,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && ! "$_path" == "$_pathbelow" ]];then
            # Contoh kasus:
            # mv ini.d itu.d (directory itu.d belum ada sebelumnya)
            ACTION='ssh_rename_dir'
            ARGUMENT1="$_path"
            ARGUMENT2="$_pathbelow"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
            let LINE++;
            break
        elif [[ "$_event" == "MOVED_FROM" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "MOVED_TO" && "$_statebelow" == "(isfileisnotdir)" && ! "$_path" == "$_pathbelow" ]];then
            # Contoh kasus:
            # mv ini.txt itu.txt (file itu.txt belum ada sebelumnya)
            ACTION='ssh_rename_file'
            ARGUMENT1="$_path"
            ARGUMENT2="$_pathbelow"
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
            let LINE++;
            break
        fi
        # ignore else format line.
        ACTION='ignore'
        ARGUMENT1="$_linecontent"
        sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
        break
    done
}

doIt() {
    style="$1"
    uriPath1="$2"
    uriPath2="$3"
    while IFS= read -r hostname; do
        rsynctempdir="${DIRECTORIES[$hostname]}/.tmp.sync-directory"
        fullpath1="${DIRECTORIES[$hostname]}${uriPath1}"
        dirpath1=$(dirname "$fullpath1")
        basename1=$(basename "$fullpath1")
        temppath1="${dirpath1}/.${basename1}.ignore-this"
        [ -n "$uriPath2" ] && {
            fullpath2="${DIRECTORIES[$hostname]}${uriPath2}"
            dirpath2=$(dirname "$fullpath2")
            basename2=$(basename "$fullpath2")
            temppath2="${dirpath2}/.${basename2}.ignore-this"
        }
        # echo "  [debug] \$hostname ${hostname}" >> "$log_file"
        # echo "  [debug] \$fullpath1 ${fullpath1}" >> "$log_file"
        # echo "  [debug] \$dirpath1 ${dirpath1}" >> "$log_file"
        # echo "  [debug] \$basename1 ${basename1}" >> "$log_file"
        # echo "  [debug] \$temppath1 ${temppath1}" >> "$log_file"
        # echo "  [debug] \$fullpath2 ${fullpath2}" >> "$log_file"
        # echo "  [debug] \$dirpath2 ${dirpath2}" >> "$log_file"
        # echo "  [debug] \$basename2 ${basename2}" >> "$log_file"
        # echo "  [debug] \$temppath2 ${temppath2}" >> "$log_file"
        case "$style" in
            ssh_rsync) #1
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"
    mkdir -p "'"$rsynctempdir"'"
    touch "'"$temppath1"'"
    rsync -T "'"$rsynctempdir"'" -s -avr "'"${myname}:${mydirectory}${uriPath1}"'" "'"$fullpath1"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rmdir --ignore-fail-on-non-empty "'"$rsynctempdir"'"
    '
EOL
                screen -d -m \
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"
    mkdir -p "'"$rsynctempdir"'"
    touch "'"$temppath1"'"
    rsync -T "'"$rsynctempdir"'" -s -avr "'"${myname}:${mydirectory}${uriPath1}"'" "'"$fullpath1"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rmdir --ignore-fail-on-non-empty "'"$rsynctempdir"'"
    '
                ;;
            ssh_rm) #2
                # Something bisa file atau direktori.
                # Gunakan sleep untuk mengerem command remove file temp.
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    touch "'"$temppath1"'"
    rm -rf "'"$fullpath1"'";
    sleep 1;
    rm -rf "'"$temppath1"'"
    '
EOL
                screen -d -m \
ssh "$hostname" '
    touch "'"$temppath1"'"
    rm -rf "'"$fullpath1"'";
    sleep 1;
    rm -rf "'"$temppath1"'"
    '
                ;;
            ssh_rename_file) #3
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"
    mkdir -p "'"$rsynctempdir"'"
    touch "'"$temppath1"'"
    rsync -T "'"$rsynctempdir"'" -s -avr "'"${myname}:${mydirectory}${uriPath2}"'" "'"$fullpath1"'";
    sleep .5
    mkdir -p "'"$dirpath2"'";
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    rmdir --ignore-fail-on-non-empty "'"$rsynctempdir"'"
    '
EOL
                screen -d -m \
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"
    mkdir -p "'"$rsynctempdir"'"
    touch "'"$temppath1"'"
    rsync -T "'"$rsynctempdir"'" -s -avr "'"${myname}:${mydirectory}${uriPath2}"'" "'"$fullpath1"'";
    sleep .5
    mkdir -p "'"$dirpath2"'";
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    rmdir --ignore-fail-on-non-empty "'"$rsynctempdir"'"
    '
                ;;
            ssh_rename_dir) #4
                # fullpath1 dipastikan ada dulu.
                # fullpath2 dipastikan tidak ada dulu.
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    touch "'"$temppath1"'"
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    '
EOL
                screen -d -m \
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    touch "'"$temppath1"'"
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    '
                ;;
            ssh_mkdir) #5
                # mkdir terlalu rumit dan njelimit.
                # jadi kita biarkan terjadi efek berantai.
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    '
EOL
                screen -d -m \
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    '
                ;;
            ssh_mv_file) #6
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"
    mkdir -p "'"$rsynctempdir"'"
    touch "'"$temppath1"'"
    rsync -T "'"$rsynctempdir"'" -s -avr '"${myname}:${mydirectory}${uriPath2}"' '"$fullpath1"';
    sleep 1
    mkdir -p "'"$dirpath2"'";
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    rmdir --ignore-fail-on-non-empty "'"$rsynctempdir"'"
    '
EOL
                screen -d -m \
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"
    mkdir -p "'"$rsynctempdir"'"
    touch "'"$temppath1"'"
    rsync -T "'"$rsynctempdir"'" -s -avr '"${myname}:${mydirectory}${uriPath2}"' '"$fullpath1"';
    sleep 1
    mkdir -p "'"$dirpath2"'";
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    rmdir --ignore-fail-on-non-empty "'"$rsynctempdir"'"
    '
                ;;
            ssh_mv_dir) #7
                # fullpath1 dipastikan ada dulu.
                # fullpath2 dipastikan tidak ada dulu.
                # dirpath2 dipastikan ada dulu.
                cat <<EOL >> "$command_file"
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    mkdir -p "'"$dirpath2"'";
    touch "'"$temppath1"'"
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
done
    '
EOL
                screen -d -m \
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    mkdir -p "'"$dirpath2"'";
    touch "'"$temppath1"'"
    touch "'"$temppath2"'";
    mv "'"$fullpath1"'" "'"$fullpath2"'"
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    done
    '
                ;;
        esac
    done <<< "$list_other"
}
declare -A DIRECTORIES; list_all=$(grep -o -P "^\[\K([^\[\]]+)" "$nodes_ini_file"); list_other=
while IFS= read -r line; do
    [[ ! "$line" == "$myname" ]] && list_other+="$line"$'\n'
done <<< "$list_all"
[ -n "$list_other" ] && list_other=${list_other%$'\n'} # trim trailing \n
while IFS= read -r h; do
    _d=$(sed -n '/^[ \t]*\['"$h"'\]/,/\[/s/^[ \t]*directory[ \t]*=[ \t]*//p' "$nodes_ini_file")
    DIRECTORIES+=( ["$h"]="${_d%/}" )
done <<< "$list_all"
mydirectory="${DIRECTORIES[$myname]}"; object_watched_2="$queue_file";
if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    object_watched_2=$(cygpath -w "$queue_file");
fi
while inotifywait -q -e modify "$object_watched_2"; do
    # Get current LINE.
    if [[ -s "$line_file" ]];then
        LINE=$(<"$line_file")
    else
        LINE=1
    fi
    LINES=$(wc -l < "$queue_file")
    # Correction.
    if [[ $LINE -gt $LINES ]];then
        LINE=$LINES
    fi
    until [[ $LINE -gt $LINES ]]; do
        sleep 1
        ACTION=; ARGUMENT1=; ARGUMENT2=
        parseLineContents
        echo "[queue] ${ACTION} ${ARGUMENT1} ${ARGUMENT2}" >> "$log_file"
        [[ "$ACTION" == ignore ]] || doIt "${ACTION}" "${ARGUMENT1}" "${ARGUMENT2}"
        let LINE++;
        LINES=$(wc -l < "$queue_file")
    done
    # Dump current LINE for next trigger
    echo "$LINE" > "$line_file"
done
EOF
# End Bash Script.
# ------------------------------------------------------------------------------

# Kill existing before.
getPid() {
    if [[ $(uname) == "Linux" ]];then
        pid=$(ps aux | grep "$2" | grep -v grep | awk '{print $2}')
        echo $pid
    elif [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
        local pid command ifs
        ifs=$IFS
        ps -s | grep "$1" | awk '{print $1}' | while IFS= read -r pid; do\
            command=$(cat /proc/${pid}/cmdline | tr '\0' ' ')
            command=$(echo "$command" | sed 's/\ $//')
            IFS=$ifs
            if [[ "$command" == "$2" ]];then
                echo $pid
                break
            fi
        done
        IFS=$ifs
    fi
}
format='<<%e>><<%w>><<%f>><<%T>>'
command="${bin} -q -e modify,create,delete,move -m -r --format \"${format}\" ${object_watched}"
pid=$(getPid inotifywait "$command")
[ -n "$pid" ] && {
    echo "$pid" | xargs kill
}
command="${bin} -q -e modify ${object_watched_2}"
pid=$(getPid inotifywait "$command")
[ -n "$pid" ] && {
    echo "$pid" | xargs kill
}

"$queue_watcher" "$cluster_name" "$myname" "$nodes_ini_file" &

ISCYGWIN=
if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    ISCYGWIN=1
fi

IFS=''
inotifywait -q -e modify,create,delete,move -m -r --format "$format" "$object_watched" | while read -r LINE
do
    # echo "[debug] LINE: ${LINE}" >> "$log_file"
    # Posisi paling kanan menyebabkan terdapat tambahan karakter \r (CR)
    [ -n "$ISCYGWIN" ] && LINE=$(sed 's/\r$//' <<< "$LINE")
    EVENT=$(sed -E 's|<<(.*)>><<(.*)>><<(.*)>><<(.*)>>|\1|' <<< "$LINE")
    DIR=$(sed -E 's|<<(.*)>><<(.*)>><<(.*)>><<(.*)>>|\2|' <<< "$LINE")
    [ -n "$ISCYGWIN" ] && DIR=$(cygpath "$DIR")
    FILE=$(sed -E 's|<<(.*)>><<(.*)>><<(.*)>><<(.*)>>|\3|' <<< "$LINE")
    TIME=$(sed -E 's|<<(.*)>><<(.*)>><<(.*)>><<(.*)>>|\4|' <<< "$LINE")
    [ -n "$ISCYGWIN" ] && LINE="<<${EVENT}>><<${DIR}>><<${FILE}>><<${TIME}>>"
    # echo "[debug] EVENT: ${EVENT}" >> "$log_file"
    # echo "[debug] DIR: ${DIR}" >> "$log_file"
    # echo "[debug] FILE: ${FILE}" >> "$log_file"
    if [[ "$FILE" =~ ^\..*\.ignore-this$ || "$FILE" == '.tmp.sync-directory' || "$DIR" =~ \.tmp\.sync-directory$ ]];then
        # echo "  [debug] Something happend with file temporary." >> "$log_file"
        # echo "  [debug] Process Stop." >> "$log_file"
        continue
    fi

    TEMPPATH="${DIR}/.${FILE}.ignore-this"
    # echo "[debug] TEMPPATH: ${TEMPPATH}" >> "$log_file"
    if [[ -f "${TEMPPATH}" ]];then
        # echo "  [debug] File temporary found." >> "$log_file"
        # echo "  [debug] Process Stop." >> "$log_file"
        continue
    # else
        # echo "  [debug] File temporary not found." >> "$log_file"
        # echo "  [debug] Process Continue." >> "$log_file"
    fi

    ABSPATH="${DIR}/${FILE}"
    URIPATH=$(echo "$ABSPATH" | sed "s|${mydirectory}||")
    skip=
    for i in "${exclude[@]}"; do
        if [[ "$URIPATH" =~ $i ]];then
            skip=1
        fi
    done
    if [[ -n "$skip" ]];then
        continue
    fi

    echo "[directory] ${LINE}" >> "$log_file"
    echo -n "${EVENT} (" >> "$queue_file"
    # Terdapat bug/inkonsistensi. Sehingga perlu dibuat informasi
    # seperti 4 baris dibawah.
    [ -f "$ABSPATH" ] && echo -n 'isfile' >> "$queue_file"
    [ ! -f "$ABSPATH" ] && echo -n 'isnotfile' >> "$queue_file"
    [ -d "$ABSPATH" ] && echo -n 'isdir' >> "$queue_file"
    [ ! -d "$ABSPATH" ] && echo -n 'isnotdir' >> "$queue_file"
    echo -n ") " >> "$queue_file"
    echo "$URIPATH" >> "$queue_file"
done
