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
        --cluster-file=*|-f=*) cluster_file="${1#*=}"; shift ;;
        --cluster-file|-f) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then cluster_file="$2"; shift; fi; shift ;;
        *) _new_arguments+=("$1"); shift ;;
    esac
done

set -- "${_new_arguments[@]}"

_new_arguments=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -[^-]*) OPTIND=1
            while getopts ":c:e:n:f:" opt; do
                case $opt in
                    c) cluster_name="$OPTARG" ;;
                    e) exclude+=("$OPTARG") ;;
                    n) myname="$OPTARG" ;;
                    f) cluster_file="$OPTARG" ;;
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
[ -n "$cluster_name" ] || { echo "Argument --cluster-name (-c) required.">&2; exit 1; }
[ -n "$cluster_file" ] || { echo "Argument --cluster-file (-f) required.">&2; exit 1; }
[ -n "$myname" ] || { echo "Argument --myname (-n) required.">&2; exit 1; }

# Populate variables
list_all=$(grep -o -P "^\[\K([^\[\]]+)" "$cluster_file")
list_other=

# Verification of myname and populate variable $list_other.
found=
while IFS= read -r line; do
    [[ "$line" == "$myname" ]] && found=1 || list_other+="$line"$'\n'
done <<< "$list_all"
[ -n "$found" ] || { echo "My hostname '$myname' not found in '$cluster_file'.">&2; exit 1; }
[ -n "$list_other" ] && list_other=${list_other%$'\n'} # trim trailing \n

# @todo, pull node terupdate.

# Populate variable associative array.
declare -A DIRECTORIES
found=
while IFS= read -r hostname; do
    _directory=$(sed -n '/^[ \t]*\['"$hostname"'\]/,/\[/s/^[ \t]*directory[ \t]*=[ \t]*//p' "$cluster_file")
    [ -n "$_directory" ] && DIRECTORIES+=( ["$hostname"]="${_directory%/}" ) || found="$hostname"
done <<< "$list_all"
[ -n "$found" ] && { echo "Directory of '$found' not found in '$cluster_file'.">&2; exit 1; }

ISCYGWIN=
if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    ISCYGWIN=1
fi

# Populate variable $mydirectory.
mydirectory="${DIRECTORIES[$myname]}"
instance_dir="/dev/shm/${cluster_name}"
queue_file="${instance_dir}/_queue.txt"
object_watched_2="$queue_file"
[ -n "$ISCYGWIN" ] && object_watched_2=$(cygpath -w "$queue_file")
line_file="${instance_dir}/_line.txt"
log_file="${instance_dir}/_log.txt"
updated_file="${instance_dir}/_updated.txt"
rsync_output_file="${instance_dir}/_rsync_output.txt"
rsync_list_file="${instance_dir}/_rsync_list.txt"
queue_watcher="${instance_dir}/_queue_watcher.sh"

# Get pid, return multi line.
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
            fi
        done
        IFS=$ifs
    fi
}

# Populate variable $object_watched, $format, and $bin.
object_watched="$mydirectory"
[ -n "$ISCYGWIN" ] && object_watched=$(cygpath -w "$mydirectory")
bin=$(command -v inotifywait)
[ -n "$ISCYGWIN" ] && bin=$(cygpath -w "$bin")
format='<<%e>><<%w>><<%f>><<%T>>'

# Kill existing before.
doStop() {
    PIDS=()
    command="${bin} -q -e modify ${object_watched_2}"
    while read -r _pid; do
        [ -n "$_pid" ] && PIDS+=("$_pid")
    done <<< $(getPid inotifywait "$command")
    command="${bin} -q -e modify,create,delete,move -m -r --format ${format} ${object_watched}"
    while read -r _pid; do
        [ -n "$_pid" ] && PIDS+=("$_pid")
    done <<< $(getPid inotifywait "$command")
    [[ "${#PIDS[@]}" -gt 0 ]] && {
        echo -n "Stopping..."; sleep .5
        for _pid in "${PIDS[@]}"; do
          kill $_pid
        done
        printf "\r\033[K"
        echo "Stopped."
    }
}

doUpdate() {
    local updated updated_host hostname _updated updated_host_file rsynctempdir
    local _lines rsynctempdir
    while IFS= read -r hostname; do
        updated_host_file="${instance_dir}/_updated_${hostname}.txt"
        rm -rf "$updated_host_file"
        screen -d -m ssh "$hostname" '
            head -n1 "'"$updated_file"'" | ssh "'"$myname"'" "cat > "'"$updated_host_file"'""
            '
    done <<< "$list_other"
    local n=5
    until [[ $n == 0 ]]; do
        printf "\r\033[K"
        echo -n Waiting $n...
        let n--
        sleep 1
    done
    printf "\r\033[K"
    updated=
    [[ -f "$updated_file" && -s "$updated_file" ]] && {
        updated=$(head -n 1 "$updated_file")
    }
    [[ ! "$updated" =~ ^[0-9]+$ ]] && {
        updated=
    }
    updated_host=
    while IFS= read -r hostname; do
        updated_host_file="${instance_dir}/_updated_${hostname}.txt"
        _updated=
        [[ -f "$updated_host_file" && -s "$updated_host_file" ]] && {
            _updated=$(<"$updated_host_file")
        }
        [[ $_updated =~ ^[0-9]+$ && $_updated -gt $updated ]] && {
            updated="$_updated"
            updated_host="$hostname"
        }
        rm -rf "$updated_host_file"
    done <<< "$list_other"
    [ -n "$updated_host" ] && {
        echo "Pull update from host: ${updated_host}"
        echo "[directory] ("$(date +%Y-%m-%d\ %H:%M:%S)") Pull update from host: ${updated_host}." >> "$log_file"
        if [[ "${#exclude[@]}" == 0 ]];then
            rsynctempdir="${mydirectory}/.tmp.sync-directory"
            mkdir -p "$rsynctempdir"
            rsync -T "$rsynctempdir" -avr -u "${updated_host}:${DIRECTORIES[$updated_host]}/" "${mydirectory}/" 2>&1 | tee -a "$rsync_output_file"
            rmdir --ignore-fail-on-non-empty "$rsynctempdir"
            date +%s%n%Y%m%d-%H%M%S > "$updated_file"
        else
            while true; do
                rsync -n -avr -u "${updated_host}:${DIRECTORIES[$updated_host]}/" "${mydirectory}/" 2>&1 | tee "$rsync_list_file"
                _lines=$(wc -l < "$rsync_list_file")
                if [[ $_lines -le 4 ]];then
                    break
                fi
                let "_bottom = $_lines - 3"
                sed -n -i '2,'"$_bottom"'p' "$rsync_list_file"
                sed -i '/\/$/d' "$rsync_list_file"
                _lines=$(wc -l < "$rsync_list_file")
                if [[ $_lines -lt 1 ]];then
                    break
                fi
                sed -i 's,^,/,g' "$rsync_list_file"
                for i in "${exclude[@]}"; do
                    # escape slash
                    i=$(echo "$i" | sed 's,/,\\/,g')
                    sed -i -E '/'"${i}"'/d' "$rsync_list_file"
                done
                sed -i 's,^/,,g' "$rsync_list_file"
                _lines=$(wc -l < "$rsync_list_file")
                if [[ $_lines -lt 1 ]];then
                    break
                fi
                rsynctempdir="${mydirectory}/.tmp.sync-directory"
                mkdir -p "$rsynctempdir"
                rsync -T "$rsynctempdir" -avr -u --files-from="$rsync_list_file" "${updated_host}:${DIRECTORIES[$updated_host]}/" "${mydirectory}/"  2>&1 | tee -a "$rsync_output_file"
                rmdir --ignore-fail-on-non-empty "$rsynctempdir"
                date +%s%n%Y%m%d-%H%M%S > "$updated_file"
                break
            done
        fi

    }
}

doTest() {
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
                rm "$file"
            fi
        fi
    done <<< "$list_other"
}

doStatus() {
    command="${bin} -q -e modify,create,delete,move -m -r --format ${format} ${object_watched}"
    PIDS=()
    while read -r _pid; do
        [ -n "$_pid" ] && PIDS+=("$_pid")
    done <<< $(getPid inotifywait "$command")
    [[ "${#PIDS[@]}" -gt 0 ]] && {
        [[ "${#PIDS[@]}" -gt 1 ]] && _label='PIDS' || _label='PID'
        echo 'Watching directory: '"$mydirectory"'.'
        echo "${_label}: ${PIDS[@]}"
    }
}

case "$1" in
    stop) doStop; exit;;
    status) doStatus; exit;;
    test) doTest; exit;;
    update)
        doUpdate
        exit
        ;;
    start)
        doStop
        doUpdate
        ;;
    restart)
        doStop
        ;;
    *)
        echo Command available: test, start, status, stop, update, restart. >&2
        exit 1
esac

mkdir -p "$instance_dir"
touch "$queue_file"
touch "$line_file"
touch "$log_file"
touch "$queue_watcher"
chmod a+x "$queue_watcher"
ln -sf "$log_file" "/var/log/sync-directory-${cluster_name}.log"

# ------------------------------------------------------------------------------
# Begin Bash Script.
cat <<'EOF' > "$queue_watcher"
#!/bin/bash
cluster_name="$1"; myname="$2"; cluster_file="$3"
instance_dir="/dev/shm/${cluster_name}"; queue_file="${instance_dir}/_queue.txt"
line_file="${instance_dir}/_line.txt"; log_file="${instance_dir}/_log.txt"
command_file="${instance_dir}/_command.txt"; updated_file="${instance_dir}/_updated.txt"
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
        elif [[ "$_event" == "MODIFY,ISDIR" && "$_state" == "(isnotfileisdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_path" == "$_pathbelow" ]];then
            # Coret satu dulu.
            sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
            let LINE++;
            stop=
            until [[ -n "$stop" ]]; do
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
                if [[ "$_event" == "MODIFY,ISDIR" && "$_state" == "(isnotfileisdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_path" == "$_pathbelow" ]];then
                    # Coret satu dulu.
                    sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
                    let LINE++;
                else
                    sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
                    stop=1
                fi
            done
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
declare -A DIRECTORIES; list_all=$(grep -o -P "^\[\K([^\[\]]+)" "$cluster_file"); list_other=
while IFS= read -r line; do
    [[ ! "$line" == "$myname" ]] && list_other+="$line"$'\n'
done <<< "$list_all"
[ -n "$list_other" ] && list_other=${list_other%$'\n'} # trim trailing \n
while IFS= read -r h; do
    _d=$(sed -n '/^[ \t]*\['"$h"'\]/,/\[/s/^[ \t]*directory[ \t]*=[ \t]*//p' "$cluster_file")
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
        [ -n "$ACTION" ] && echo "[queue] ${ACTION} ${ARGUMENT1} ${ARGUMENT2}" >> "$log_file"
        [[ -n "$ACTION" && ! "$ACTION" == ignore ]] && {
            doIt "${ACTION}" "${ARGUMENT1}" "${ARGUMENT2}"
            date +%s%n%Y%m%d-%H%M%S > "$updated_file"
        }
        let LINE++;
        LINES=$(wc -l < "$queue_file")
    done
    # Dump current LINE for next trigger
    echo "$LINE" > "$line_file"
done
EOF
# End Bash Script.
# ------------------------------------------------------------------------------

"$queue_watcher" "$cluster_name" "$myname" "$cluster_file" &

IFS=''
echo "[directory] ("$(date +%Y-%m-%d\ %H:%M:%S)") Start watching." >> "$log_file"
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
    # Terdapat bug/inkonsistensi. Sehingga perlu dibuat informasi
    # seperti 4 baris dibawah.
    LINE="${EVENT} ("
    [ -f "$ABSPATH" ] && LINE+='isfile'
    [ ! -f "$ABSPATH" ] && LINE+='isnotfile'
    [ -d "$ABSPATH" ] && LINE+='isdir'
    [ ! -d "$ABSPATH" ] && LINE+='isnotdir'
    LINE+=") "
    LINE+="$URIPATH"
    echo "$LINE" >> "$queue_file"
done
