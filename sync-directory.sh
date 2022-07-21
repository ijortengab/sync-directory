#!/bin/bash
#
# https://github.com/ijortengab/sync-directory
# http://ijortengab.id

# Dependencies.
command -v "ssh" >/dev/null || { echo "ssh command not found."; exit 1; }
command -v "rsync" >/dev/null || { echo "rsync command not found."; exit 1; }
command -v "inotifywait" >/dev/null || { echo "inotifywait command not found."; exit 1; }

[ -n "$1" ] || { echo "Argument <cluster-name> required.">&2; exit 1; }
cluster_name="$1"; shift;
[[ "$cluster_name" =~ ^[^a-zA-Z] ]] && { echo "Cluster name invalid: \`${cluster_name}\`. Must start with alphabet."; exit 1; }

# Parse Options.
_new_arguments=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --directory=*|-d=*) directory="${1#*=}"; shift ;;
        --directory|-d) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then directory="$2"; shift; fi; shift ;;
        --exclude=*|-e=*) exclude+=("${1#*=}"); shift ;;
        --exclude|-e) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then exclude+=("$2"); shift; fi; shift ;;
        --ignore=*|-i=*) ignore+=("${1#*=}"); shift ;;
        --ignore|-i) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then ignore+=("$2"); shift; fi; shift ;;
        --myname=*|-n=*) myname="${1#*=}"; shift ;;
        --myname|-n) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then myname="$2"; shift; fi; shift ;;
        --remote-dir=*|-r=*) remote_dir+=("${1#*=}"); shift ;;
        --remote-dir|-r) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then remote_dir+=("$2"); shift; fi; shift ;;
        --remote-dir-file=*|-f=*) remote_dir_file="${1#*=}"; shift ;;
        --remote-dir-file|-f) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then remote_dir_file="$2"; shift; fi; shift ;;
        --[^-]*) shift ;;
        test|start|status|stop|update|restart|get-file|rsync)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    *) _new_arguments+=("$1"); shift ;;
                esac
            done
            ;;
        *) _new_arguments+=("$1"); shift ;;
    esac
done

set -- "${_new_arguments[@]}"

_new_arguments=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -[^-]*) OPTIND=1
            while getopts ":d:e:i:n:r:f:" opt; do
                case $opt in
                    d) directory="$OPTARG" ;;
                    e) exclude+=("$OPTARG") ;;
                    i) ignore+=("$OPTARG") ;;
                    n) myname="$OPTARG" ;;
                    r) remote_dir+=("$OPTARG") ;;
                    f) remote_dir_file="$OPTARG" ;;
                esac
            done
            shift "$((OPTIND-1))"
            ;;
        test|start|status|stop|update|restart|get-file|rsync)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    *) _new_arguments+=("$1"); shift ;;
                esac
            done
            ;;
        *) _new_arguments+=("$1"); shift ;;
    esac
done

set -- "${_new_arguments[@]}"

unset _new_arguments

# Populate variable.
# _remote_dir= string with multilines, trim trailing line feed (\n)
# _remote_path_array=  associative array, belum difilter oleh --ignore.
# REMOTE= string with multilines, trim trailing line feed (\n)
# REMOTE_PATH= string with multilines, trim trailing line feed (\n)
# REMOTE_PATH_ARRAY=associative array, sudah difilter oleh --ignore.
REMOTE=
REMOTE_PATH=
_remote_dir=
_ignore=
declare -A _remote_path_array
declare -A REMOTE_PATH_ARRAY

# Verification.
[ -n "$remote_dir_file" ] && {
    [ -f "$remote_dir_file" ] && _remote_dir=$(<"$remote_dir_file") || echo "File ${remote_dir_file} not found.">&2;
}

[ "${#remote_dir[@]}" -gt 0 ] && {
    _remote_dir+=$'\n'
    _implode=$(printf $'\n'"%s" "${remote_dir[@]}")
    _implode=${_implode:1}
    _remote_dir+="${_implode}"
}

[ -z "$_remote_dir" ] && {
    echo "Requires at least one remote directory [--remote-dir],[--remote-dir-file].">&2; exit 1;
}
# Filter yang duplicate. Kita gunakan value yang terakhir.
while IFS= read -r line; do
    # Skip comment line.
    if [[ $(grep -E '^[[:space:]]*#' <<< "$line") ]];then
        continue
    fi
    _hostname=$(cut -d: -f1 <<< "$line")
    # Baris yang kosong, kita lewati
    [ -z "$_hostname" ] && continue
    line=$(sed 's/^'"$_hostname"'//' <<< "$line")
    [[ "${line:0:1}" == ':' ]] && line="${line:1}"
    _directory=${line}
    # Trailing slash, cegah duplikat.
    [ -n "$_directory" ] && _directory="${_directory%/}/"
    _remote_path_array+=( ["$_hostname"]="$_directory" )
done <<< "$_remote_dir"

#
[ -n "$myname" ] && {
    # Jika ada informasi pada option --remote-dir atau --remote-dir-file.
    mydirectory=${_remote_path_array[$myname]}
    # Tambahkan ke ignore.
    ignore+=( "$myname" )
}
# Filter --ignore.
[[ "${#ignore[@]}" -gt 0 ]] && {
    _ignore=$(printf $'\n'"%s" "${ignore[@]}")
    _ignore=${_ignore:1}
}
for i in "${!_remote_path_array[@]}"
do
    grep -q "^${i}$" <<< "$_ignore" || {
        REMOTE+="${i}"$'\n'
        REMOTE_PATH+="${i}:${_remote_path_array[$i]}"$'\n'
        REMOTE_PATH_ARRAY+=( ["${i}"]="${_remote_path_array[$i]}" )
    }
done
[ -n "$REMOTE" ] && REMOTE=${REMOTE%$'\n'} # trim trailing \n
[ -n "$REMOTE_PATH" ] && REMOTE_PATH=${REMOTE_PATH%$'\n'} # trim trailing \n

# Variable REMOTE dan REMOTE_PATH berisi informasi valid yang sudah filter.
# Jika PATH tidak kosong, maka tambahkan trailing slash.
# Option --directory, meng-override informasi directory pada --remote-dir atau
# --remote-dir-file.
[ -n "$directory" ] && mydirectory="$directory"
# Jika tidak ada, gunakan current.
[ -z "$mydirectory" ] && mydirectory="$PWD"
# Convert . atau .. jika ada.
mydirectory=$(realpath "$mydirectory")
# Trailing slash, cegah duplikat.
mydirectory="${mydirectory%/}/"

parseStartCommand() {
    _new_arguments=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --exclude=*|-e=*) exclude+=("${1#*=}"); shift ;;
            --exclude|-e) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then exclude+=("$2"); shift; fi; shift ;;
            --pull-all) all=1; shift ;;
            --pull-latest) latest=1; shift ;;
            --pull=*) target+=("${1#*=}"); shift ;;
            --pull) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then target+=("$2"); shift; fi; shift ;;
            --[^-]*) shift ;;
            *) _new_arguments+=("$1"); shift ;;
        esac
    done

    set -- "${_new_arguments[@]}"

    _new_arguments=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -[^-]*) OPTIND=1
                while getopts ":e:" opt; do
                    case $opt in
                        e) exclude+=("$OPTARG") ;;
                    esac
                done
                shift "$((OPTIND-1))"
                ;;
            *) _new_arguments+=("$1"); shift ;;
        esac
    done

    set -- "${_new_arguments[@]}"

    unset _new_arguments
}

# populate global variable rsync_args
parseRsyncCommand() {
    _new_arguments=()
    _n=

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all) all=1; shift ;;
            --latest) latest=1; shift ;;
            --path=*|-p=*) path="${1#*=}"; shift ;;
            --path|-p) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then path="$2"; shift; fi; shift ;;
            --pull) pull=1; shift ;;
            --push) push=1; shift ;;
            --target=*|-t=*) target+=("${1#*=}"); shift ;;
            --target|-t) if [[ ! $2 == "" && ! $2 =~ ^-[^-] ]]; then target+=("$2"); shift; fi; shift ;;
            --)
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        *) _new_arguments+=("$1"); shift ;;
                    esac
                done
                ;;
            --[^-]*) shift ;;
            *) _new_arguments+=("$1"); shift ;;
        esac
    done

    set -- "${_new_arguments[@]}"

    _new_arguments=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -[^-]*) OPTIND=1
                while getopts ":p:t:" opt; do
                    case $opt in
                        p) path="$OPTARG" ;;
                        t) target+=("$OPTARG") ;;
                    esac
                done
                _n="$((OPTIND-1))"
                _n=${!_n}
                shift "$((OPTIND-1))"
                if [[ "$_n" == '--' ]];then
                    while [[ $# -gt 0 ]]; do
                        case "$1" in
                            *) _new_arguments+=("$1"); shift ;;
                        esac
                    done
                fi
                ;;
            --) shift
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        *) _new_arguments+=("$1"); shift ;;
                    esac
                done
                ;;
            *) _new_arguments+=("$1"); shift ;;
        esac
    done

    set -- "${_new_arguments[@]}"

    unset _new_arguments
    unset _n

    # Save Positional Argument to Global Array.
    rsync_args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            *) rsync_args+=("$1"); shift ;;
        esac
    done
}

prepareDirectory() {
    mkdir -p "$instance_dir"
}

ISCYGWIN=
if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    ISCYGWIN=1
fi

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
action_rsync_push="${instance_dir}/_action_rsync_push.sh"
action_remove_force="${instance_dir}/_action_remove_force.sh"
action_rename_file="${instance_dir}/_action_rename_file.sh"
action_rename_dir="${instance_dir}/_action_rename_dir.sh"
action_make_dir="${instance_dir}/_action_make_dir.sh"

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
[ -n "$ISCYGWIN" ] && bin=$(cygpath -w "$bin") || bin=inotifywait
format='<<%e>><<%w>><<%f>><<%T>>'

# Kill existing before.
doStop() {
    local command
    PIDS=()
    command="${bin} -q -e modify ${object_watched_2}"
    while read -r _pid; do
        [ -n "$_pid" ] && PIDS+=("$_pid")
    done <<< $(getPid inotifywait "$command")
    command="${bin} -q -e modify,create,delete,move -m -r --timefmt %Y%m%d-%H%M%S --format ${format} ${object_watched}"
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

pullFrom() {
    local updated_host="$1" tempdir _lines
    echo "Pull update from host: ${updated_host}"
    echo "[directory] ("$(date +%Y-%m-%d\ %H:%M:%S)") Pull update from host: ${updated_host}." >> "$log_file"
    if [[ "${#exclude[@]}" == 0 ]];then
        tempdir="${mydirectory}.tmp.sync-directory"
        mkdir -p "$tempdir"
        rsync -e "ssh -o ConnectTimeout=2" -T "$tempdir" -s -avr -u "${updated_host}:${REMOTE_PATH_ARRAY[$updated_host]}/" "${mydirectory}" 2>&1 | tee -a "$rsync_output_file"
        rmdir --ignore-fail-on-non-empty "$tempdir"
    else
        while true; do
            rsync -e "ssh -o ConnectTimeout=2" -n -s -avr -u "${updated_host}:${REMOTE_PATH_ARRAY[$updated_host]}/" "${mydirectory}" 2>&1 | tee "$rsync_list_file"
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
            tempdir="${mydirectory}.tmp.sync-directory"
            mkdir -p "$tempdir"
            rsync -e "ssh -o ConnectTimeout=2" -T "$tempdir" -s -avr -u --files-from="$rsync_list_file" "${updated_host}:${REMOTE_PATH_ARRAY[$updated_host]}/" "${mydirectory}"  2>&1 | tee -a "$rsync_output_file"
            rmdir --ignore-fail-on-non-empty "$tempdir"
            break
        done
    fi
}

# populate global variable: updated, updated_host
getLatestUpdateHost() {
    prepareDirectory
    local hostname _updated updated_host_file
    while IFS= read -r hostname; do
        updated_host_file="${instance_dir}/_updated_${hostname}.txt"
        rm -rf "$updated_host_file"
        ssh -o StrictHostKeyChecking=no -o PreferredAuthentications=publickey -o PasswordAuthentication=no "$hostname" '
            [ -f "'"$updated_file"'" ] && cat "'"$updated_file"'" | head -n1
            ' > "$updated_host_file" &
    done <<< "$REMOTE"
    local n=5
    until [[ $n == 0 ]]; do
        printf "\r\033[K"  >&2
        echo -n Waiting $n...  >&2
        let n--
        sleep 1
    done
    printf "\r\033[K" >&2
    updated=
    [[ -f "$updated_file" && -s "$updated_file" ]] && {
        updated=$(head -n 1 "$updated_file")
    }
    [[ ! "$updated" =~ ^[0-9]+$ ]] && {
        updated=
    }
    echo -n "Current update date: "
    [ -n "$updated" ] && date +%Y%m%d-%H%M%S -d '@'$updated || echo
    updated_host=
    while IFS= read -r hostname; do
        echo -n "$hostname update date: "
        updated_host_file="${instance_dir}/_updated_${hostname}.txt"
        _updated=
        [[ -f "$updated_host_file" && -s "$updated_host_file" ]] && {
            _updated=$(<"$updated_host_file")
        }
        [ -n "$_updated" ] && date +%Y%m%d-%H%M%S -d '@'$_updated || echo
        [[ $_updated =~ ^[0-9]+$ && $_updated -gt $updated ]] && {
            updated="$_updated"
            updated_host="$hostname"
        }
        rm -rf "$updated_host_file"
    done <<< "$REMOTE"
    [ -n "$updated_host" ] && {
        echo "$updated_host is updated. "
    }
}

doUpdateLatest() {
    getLatestUpdateHost
    [ -n "$updated_host" ] && {
        pullFrom "$updated_host"
        date +%s%n%Y%m%d-%H%M%S -d '@'$updated > "$updated_file"
    }
}

doUpdate() {
    local updated updated_host hostname _updated updated_host_file tempdir
    local _lines tempdir
    echo "Pull update from all host."
    echo "[directory] ("$(date +%Y-%m-%d\ %H:%M:%S)") Pull update from all host." >> "$log_file"
    while IFS= read -r updated_host; do
        pullFrom "$updated_host"
    done <<< "$REMOTE"
    date +%s%n%Y%m%d-%H%M%S > "$updated_file"
}

doTest() {
    local array_list_other
    # hostname tidak boleh mengandung karakter spasi/whitespace.
    array_list_other=$(tr '\n' ' ' <<< "$REMOTE")
    for hostname in ${array_list_other[@]}; do
        echo -e '- '"\e[33m$hostname\e[0m"
        echo '  Test connect from '"$myname"' to host '"$hostname"'.'
        echo -n '  '; ssh "$hostname" 'echo -e "\e[32mSuccess\e[0m"'
        if [[ $? == 0 ]];then
            echo '  Test connect back from host '"$hostname"' to '"$myname"'.'
            echo -n '  '; ssh "$hostname" 'ssh "'"$myname"'" echo -e "\\\e[32mSuccess\\\e[0m"'
            if [[ $? == 0 ]];then
                file=$(mktemp)
                content=$RANDOM
                echo $content > $file
                echo '  Test host '"$hostname"' pull a file from '"$myname"'.'
                echo -n '  '; ssh "$hostname" '
                    temp=$(mktemp)
                    rsync -avr "'"$myname"'":"'"$file"'" "'"$file"'" &> $temp
                    [[ "'"$content"'" == $(<"'"$file"'") ]] && echo -e "\e[32mSuccess\e[0m" || cat $temp
                    rm "'"$file"'" $temp
                    '
                rm "$file"
            fi
        fi
    done
}

doStatus() {
    local command
    command="${bin} -q -e modify,create,delete,move -m -r --timefmt %Y%m%d-%H%M%S --format ${format} ${object_watched}"
    PIDS=()
    while read -r _pid; do
        [ -n "$_pid" ] && PIDS+=("$_pid")
    done <<< $(getPid inotifywait "$command")
    [[ "${#PIDS[@]}" -gt 0 ]] && {
        echo -n Synchronize on.
        [[ "${#PIDS[@]}" -gt 1 ]] && _label='PIDS' || _label='PID'
        echo " ${_label}: ${PIDS[@]}"
    } || echo Synchronize off.
    echo 'Local Directory: '"$mydirectory"
    echo 'Remote Directory:'
    while IFS= read -r line; do
        echo " - ${line}"
    done <<< "$REMOTE_PATH"
}

getFile() {
    [ -n "$1" ] || { echo "Argument dibutuhkan.">&2; exit 1; }
    local path="$1" fullpath dirpath hostname found=0
    tempdir="${mydirectory}.tmp.sync-directory"
    mkdir -p "$tempdir"
    if [ "${path:0:1}" = "/" ];then
        # Absolute path.
        fullpath="$path"
        [ -f "$fullpath" ] && { echo "Cancelled. File existing."; exit 1; }
        dirpath=$(dirname "$fullpath")
        mkdir -p "$dirpath"
        while IFS= read -r hostname; do
            rsync -e "ssh -o ConnectTimeout=2" -T "$tempdir" -s -avr --ignore-existing "${hostname}:${fullpath}" "${fullpath}" &
        done <<< "$REMOTE"
    else
        # Relative path.
        fullpath="${mydirectory}${path}"
        [ -f "$fullpath" ] && { echo "Cancelled. File existing."; exit 1; }
        dirpath=$(dirname "$fullpath")
        mkdir -p "$dirpath"
        while IFS= read -r hostname; do
            rsync -e "ssh -o ConnectTimeout=2" -T "$tempdir" -s -avr --ignore-existing "${hostname}:${REMOTE_PATH_ARRAY[$hostname]}/${path}" "${fullpath}" &
        done <<< "$REMOTE"
    fi
    local n=3
    until [[ $n == 0 ]]; do
        printf "\r\033[K" >&2
        echo -n Waiting $n...  >&2
        if [ -f "$fullpath" ];then
            found=1
            break
        fi
        let n--
        sleep 1
    done
    printf "\r\033[K"  >&2
    [[ $found == 0 ]] && { echo "File still not found."; exit 1; }
    echo "File pulled successfully.";
}

doRsync() {
    local source destination relPath
    local line _target _implode _remote
    [[ -n "$pull" && -n "$push" ]] && { echo "[rsync] Choose one: --pull or --push, not both.">&2; exit 1; }
    [[ -z "$pull" && -z "$push" ]] && { echo "[rsync] Choose one: --pull or --push, can't empty.">&2; exit 1; }
    if [ -n "$path" ];then
        [[ "${path:0:1}" == '/' ]] && { echo "[rsync] Can't absolute path: ${path}.">&2; exit 1; }
        relPath="$path"
    fi
    # Populate `$_remote` variable.
    if [ -n "$all" ];then
        _remote+="$REMOTE"$'\n'
    else
        if [ "${#target[@]}" -gt 0 ];then
            _implode=$(printf $'\n'"%s" "${target[@]}")
            _implode=${_implode:1}
            _target="$_implode"
            while IFS= read -r line; do
                grep -q "^${line}$" <<< "$REMOTE" && {
                    _remote+="$line"$'\n'
                }
            done <<< "$_target"
        fi
        if [ -n "$latest" ];then
            getLatestUpdateHost
            [ -n "$updated_host" ] && {
                _remote+="$updated_host"$'\n'
            }
        fi
    fi
    [ -n "$_remote" ] && _remote=${_remote%$'\n'} || return 1 # trim trailing \n

    # Execute.
    set -- "${rsync_args[@]}"

    while IFS= read -r hostname; do
        if [ -n "$pull" ];then
            echo 'Execute rsync. Pull from '"${hostname}".
            tempdir="${mydirectory}.tmp.sync-directory"
            mkdir -p "$tempdir"
            rsync \
                -e "ssh -o ConnectTimeout=2" \
                -T "$tempdir" \
                -s -avr \
                "$@" \
                "${hostname}:${REMOTE_PATH_ARRAY[$hostname]}${relPath}" \
                "${mydirectory}${relPath}"
            rmdir --ignore-fail-on-non-empty "$tempdir"
        else
            echo 'Execute rsync. Push to '"${hostname}".
            tempdir="${REMOTE_PATH_ARRAY[$hostname]}.tmp.sync-directory"
            ssh "$hostname" mkdir -p "$tempdir"
            rsync \
                -e "ssh -o ConnectTimeout=2" \
                -T "$tempdir" \
                -s -avr \
                "$@" \
                "${mydirectory}${relPath}" \
                "${hostname}:${REMOTE_PATH_ARRAY[$hostname]}${relPath}"
            ssh "$hostname" rmdir --ignore-fail-on-non-empty "$tempdir"
        fi
    done <<< "$_remote"
}

command="$1"; shift

case "$command" in
    status) doStatus; exit;;
    test) doTest; exit;;
    stop)
        echo "[directory] ("$(date +%Y-%m-%d\ %H:%M:%S)") Stop watching." >> "$log_file"
        doStop;
        exit
        ;;
    update)
        doStatus
        parseRsyncCommand --pull --all -- --update
        doRsync "$@"
        prepareDirectory
        date +%s%n%Y%m%d-%H%M%S > "$updated_file"
        exit
        ;;
    start)
        parseStartCommand "$@"
        ;;
    restart)
        doStop
        ;;
    get-file)
        getFile "$2"
        exit
        ;;
    rsync)
        parseRsyncCommand "$@"
        doRsync
        exit
        ;;
    *)
        echo Command available: test, start, status, stop, update, restart, get-file, rsync. >&2
        exit 1
esac

# Command start below.
doStop
if [[ -n "$all" || -n "$latest" || "${#target[@]}" -gt 0 ]];then
    pull=1
    doRsync
fi

mkdir -p "$instance_dir"
touch "$queue_file"
touch "$line_file"
touch "$log_file"
touch "$queue_watcher"
chmod a+x "$queue_watcher"
touch "$action_rsync_push"
chmod a+x "$action_rsync_push"
touch "$action_remove_force"
chmod a+x "$action_remove_force"
touch "$action_rename_file"
chmod a+x "$action_rename_file"
touch "$action_rename_dir"
chmod a+x "$action_rename_dir"
touch "$action_make_dir"
chmod a+x "$action_make_dir"

[[ -w /var/log ]] && ln -sf "$log_file" "/var/log/sync-directory-${cluster_name}.log"

# ------------------------------------------------------------------------------
# Begin Bash Script.
cat <<'EOF' > "$queue_watcher"
#!/bin/bash
cluster_name="$1"; mydirectory="$2";
instance_dir="/dev/shm/${cluster_name}"; queue_file="${instance_dir}/_queue.txt"
line_file="${instance_dir}/_line.txt"; log_file="${instance_dir}/_log.txt"
command_file="${instance_dir}/_command.txt"; updated_file="${instance_dir}/_updated.txt"
action_rsync_push="${instance_dir}/_action_rsync_push.sh"
action_remove_force="${instance_dir}/_action_remove_force.sh"
action_rename_file="${instance_dir}/_action_rename_file.sh"
action_rename_dir="${instance_dir}/_action_rename_dir.sh"
action_make_dir="${instance_dir}/_action_make_dir.sh"

# List action result:
#1 ssh_rsync
#2 ssh_rm
#3 ssh_rename_file
#4 ssh_rename_dir
#5 ssh_mkdir
#6 ssh_mv_file
#7 ssh_mv_dir
#8 ssh_rmdir
#9 ssh_mkdir_parents
#10 ssh_rsync_office, ssh_rsync_code

populateVariables() {
    case "$1" in
        init)
            _linecontent=$(sed "$LINE"'q;d' "$queue_file")
            _event=$(echo "$_linecontent" | cut -d' ' -f1)
            _state=$(echo "$_linecontent" | cut -d' ' -f2)
            _path=$(echo "$_linecontent" | sed 's|'"${_event} ${_state} "'||')
            _dirname=$(dirname "$_path")
            let "LINEBELOW = $LINE + 1"
            _linecontentbelow=$(sed "$LINEBELOW"'q;d' "$queue_file")
            _eventbelow=$(echo "$_linecontentbelow" | cut -d' ' -f1)
            _statebelow=$(echo "$_linecontentbelow" | cut -d' ' -f2)
            _pathbelow=$(echo "$_linecontentbelow" | sed 's|'"${_eventbelow} ${_statebelow} "'||')
            _dirnamebelow=$(dirname "$_pathbelow")
            ;;
        up)
            _linecontent="$_linecontentbelow"
            _event="$_eventbelow"
            _state="$_statebelow"
            _path="$_pathbelow"
            _dirname="$_dirnamebelow"
            let "LINEBELOW = $LINE + 1"
            _linecontentbelow=$(sed "$LINEBELOW"'q;d' "$queue_file")
            _eventbelow=$(echo "$_linecontentbelow" | cut -d' ' -f1)
            _statebelow=$(echo "$_linecontentbelow" | cut -d' ' -f2)
            _pathbelow=$(echo "$_linecontentbelow" | sed 's|'"${_eventbelow} ${_statebelow} "'||')
            _dirnamebelow=$(dirname "$_pathbelow")
    esac
}
parseLineContents() {
    local LINEBELOW _linecontent _linecontentbelow _first
    # Jika "$line_file" kehapus, maka pastikan baris yang sudah di proses
    # tidak lagi digunakan.
    while true; do
        _linecontent=$(sed "$LINE"'q;d' "$queue_file")
        _first="${_linecontent:0:1}"
        # = rsync
        # - delete
        # ~ rename
        # + create
        # % dir modify
        # > moving
        # ? ignore
        if [[ "$_first" == '=' || "$_first" == '-' || "$_first" == '~' || "$_first" == '+' || "$_first" == '%' || "$_first" == '>' || "$_first" == '?' ]];then
            let LINE++
            continue
        fi
        break
    done
    populateVariables init
    if [[ "$_event" == "CREATE" && "$_state" == "(isfileisnotdir)" && "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
        # Contoh kasus:
        # touch a.txt (file belum ada sebelumnya)
        # echo 'anu' > a.txt (file belum ada sebelumnya)
        ACTION='ssh_rsync'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"+${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'"+${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
    elif [[ "$_event" == "CREATE" && "$_state" == "(isfileisnotdir)" ]];then
        # Contoh kasus:
        # klik kanan pada windows explorer, new file.
        ACTION='ssh_rsync'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
    elif [[ "$_event" == "CREATE" && "$_state" == "(isnotfileisnotdir)" ]];then
        [ -n "$ISCYGWIN" ] && sleep 2
        # Contoh kasus: nge-save file office .docx, .xlsx.
        # Test dulu jika terjadi saving file office.
        recognize=
        line_destination=
        _file_temp="$_path"
        _file_temp2=
        _file_dirname="$_dirname"
        _file_path=
        step=0
        backup_line="$LINE"
        # Test turun dulu.
        let LINE++; populateVariables up
        while true; do
            if [[ "$_event" == "MODIFY,ISDIR" && "$_state" == "(isnotfileisdir)" && "$_path" == "$_file_dirname" ]];then
                let LINE++; populateVariables up
                continue
            fi
            if [[ "$step" == 0 && "$_event" == "MODIFY" && "$_state" == "(isnotfileisnotdir)" && "$_path" == "$_file_temp" ]];then
                let LINE++; populateVariables up
                continue
            fi
            if [[ "$step" == 0 && "$_event" == "MOVED_FROM" && "$_state" == "(isfileisnotdir)" && "$_dirname" == "$_file_dirname" ]];then
                _file_path="$_path"
                let LINE++; populateVariables up
                step=1; continue
            fi
            if [[ "$step" == 1 && "$_event" == "MOVED_TO" && "$_state" == "(isnotfileisnotdir)" && "$_dirname" == "$_file_dirname" ]];then
                _file_temp2="$_path"
                let LINE++; populateVariables up
                step=2; continue
            fi
            if [[ "$step" == 2 && "$_event" == "MOVED_FROM" && "$_state" == "(isnotfileisnotdir)" && "$_path" == "$_file_temp" ]];then
                let LINE++; populateVariables up
                step=3; continue
            fi
            if [[ "$step" == 3 && "$_event" == "MOVED_TO" && "$_state" == "(isfileisnotdir)" && "$_path" == "$_file_path" ]];then
                let LINE++; populateVariables up
                step=4; continue
            fi
            if [[ "$step" == 4 && "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_path" == "$_file_temp2" ]];then
                let LINE++; populateVariables up
                step=5; continue
            fi
            if [[ "$step" == 5 ]];then
                let LINE--;
                break
            fi
            break
        done
        [[ "$step" == 5 ]] && {
            recognize=yes
            line_destination="$LINE"
            ACTION='ssh_rsync_office'
            ARGUMENT1="$_file_path"
        }
        # Kembalikan ke semula.
        LINE="$backup_line"

        if [[ ! $recognize == yes ]];then
            # Contoh kasus: Twig menggenerate file PHP.
            step=0
            backup_line="$LINE"
            # Test turun dulu.
            let LINE++; populateVariables init
            while true; do
                if [[ "$step" == 0 && "$_event" == "MODIFY" && "$_state" == "(isnotfileisnotdir)" && "$_path" == "$_file_temp" ]];then
                    let LINE++; populateVariables up
                    continue
                fi
                if [[ "$step" == 0 && "$_event" == "MOVED_FROM" && "$_state" == "(isnotfileisnotdir)" && "$_path" == "$_file_temp" ]];then
                    let LINE++; populateVariables up
                    step=1; continue
                fi
                if [[ "$step" == 1 && "$_event" == "MOVED_TO" && "$_state" == "(isfileisnotdir)" ]];then
                    _file_path="$_path"
                    let LINE++; populateVariables up
                    step=2; continue
                fi
                if [[ "$step" == 2 ]];then
                    let LINE--;
                    break
                fi
                break
            done
            [[ "$step" == 2 ]] && {
                recognize=yes
                line_destination="$LINE"
                ACTION='ssh_rsync_code'
                ARGUMENT1="$_file_path"
            }
            # Kembalikan ke semula.
            LINE="$backup_line"
        fi

        # echo "  [debug] \$LINE ${LINE}" >> "$log_file"
        # echo "  [debug] \$line_destination ${line_destination}" >> "$log_file"
        if [[ $recognize == yes ]];then
            _linecontent=$(sed "$LINE"'q;d' "$queue_file")
            until [[ "$LINE" -gt "$line_destination" ]]; do
                _linecontent=$(sed "$LINE"'q;d' "$queue_file")
                sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
                let LINE++;
            done
            let LINE--;
        else
            # ignore else format line.
            ACTION='ignore'
            ARGUMENT1="$_linecontent"
            sed -i "$LINE"'s|^.*$|'"?${_linecontent}"'|' "$queue_file"
        fi
    elif [[ "$_event" == "MODIFY" && "$_state" == "(isfileisnotdir)" && "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
        # Contoh kasus:
        # echo 'anu' > a.txt (file sudah ada sebelumnya)
        ACTION='ssh_rsync'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
        # Cek lagi dibawahnya.
        stop=
        until [[ -n "$stop" ]]; do
            # Restart:
            populateVariables up
            if [[ "$_event" == "MODIFY" && "$_state" == "(isfileisnotdir)" && "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
                # Coret dibawahnya.
                sed -i "$LINEBELOW"'s|^.*$|'"=${_linecontentbelow}"'|' "$queue_file"
                let LINE++;
            else
                # sed -i "$LINE"'s|^.*$|'"%${_linecontent}"'|' "$queue_file"
                # let LINE--;
                stop=1
            fi
        done
    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "CREATE,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && $(basename "$_path") == $(basename "$_pathbelow") ]];then
        # Contoh kasus:
        # mv ini.d itu.d (directory itu.d sudah ada sebelumnya)
        ACTION='ssh_mv_dir'
        ARGUMENT1="$_path"
        ARGUMENT2="$_pathbelow"
        sed -i "$LINE"'s|^.*$|'">${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'">${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "CREATE" && "$_statebelow" == "(isfileisnotdir)" && $(basename "$_path") == $(basename "$_pathbelow") ]];then
        # Contoh kasus:
        # mv anu.txt itu.d (directory itu.d sudah ada sebelumnya)
        ACTION='ssh_mv_file'
        ARGUMENT1="$_path"
        ARGUMENT2="$_pathbelow"
        sed -i "$LINE"'s|^.*$|'">${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'">${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" ]];then
        # Contoh kasus:
        # rm a.txt (file sudah ada sebelumnya)
        ACTION='ssh_rm'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"-${_linecontent}"'|' "$queue_file"
        # Test dulu jika terjadi rm -rf dir/
        backup_line="$LINE"
        isrmdir=
        while true; do
            if [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "DELETE" && "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_dirnamebelow" ]];then
                let LINE++;
                populateVariables up
                continue
            fi
            if [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "MODIFY" &&  "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_pathbelow" ]];then
                let LINE++;
                populateVariables up
                if [[ "$_event" == "MODIFY" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "DELETE" && "$_statebelow" == "(isnotfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
                    let LINE++;
                    populateVariables up
                    if [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_pathbelow" ]];then
                        let LINE++;
                    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_pathbelow" ]];then
                        let LINE++;
                    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_dirname" == "$_pathbelow" ]];then
                        let LINE++;
                    fi
                    isrmdir="$LINE"
                fi
                break
            fi
            if [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "MODIFY,ISDIR" &&  "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_pathbelow" ]];then
                let LINE++;
                populateVariables up
                if [[ "$_event" == "MODIFY,ISDIR" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "DELETE" && "$_statebelow" == "(isnotfileisnotdir)" && "$_path" == "$_pathbelow" ]];then
                    let LINE++;
                    populateVariables up
                    if [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "MODIFY" && "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_pathbelow" ]];then
                        let LINE++;
                    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisnotdir)" && "$_dirname" == "$_pathbelow" ]];then
                        let LINE++;
                    elif [[ "$_event" == "DELETE" && "$_state" == "(isnotfileisnotdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_dirname" == "$_pathbelow" ]];then
                        let LINE++;
                    fi
                    isrmdir="$LINE"
                fi
                break
            fi
            break
        done
        LINE="$backup_line"
        if [[ -n "$isrmdir" ]];then
            ACTION='ssh_rmdir'
            ARGUMENT1="$_path"
            _linecontent=$(sed "$LINE"'q;d' "$queue_file")
            until [[ "$LINE" -ge "$isrmdir" ]]; do
                let LINE++;
                _linecontent=$(sed "$LINE"'q;d' "$queue_file")
                sed -i "$LINE"'s|^.*$|'"-${_linecontent}"'|' "$queue_file"
            done
        fi
    elif [[ "$_event" == "DELETE,ISDIR" && "$_state" == "(isnotfileisnotdir)" ]];then
        ACTION='ssh_rmdir'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"-${_linecontent}"'|' "$queue_file"
    elif [[ "$_event" == "MODIFY" && "$_state" == "(isfileisnotdir)" ]];then
        # Contoh kasus:
        # echo 'anu' >> a.txt (file sudah ada sebelumnya)
        ACTION='ssh_rsync'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"=${_linecontent}"'|' "$queue_file"
    elif [[ "$_event" == "MODIFY,ISDIR" && "$_state" == "(isnotfileisdir)" ]];then
        # Coret satu dulu.
        sed -i "$LINE"'s|^.*$|'"%${_linecontent}"'|' "$queue_file"
        let LINE++;
        stop=
        until [[ -n "$stop" ]]; do
            # Restart:
            populateVariables up
            if [[ "$_event" == "MODIFY,ISDIR" && "$_state" == "(isnotfileisdir)" ]];then
                # Coret satu dulu.
                sed -i "$LINE"'s|^.*$|'"%${_linecontent}"'|' "$queue_file"
                let LINE++;
            else
                # sed -i "$LINE"'s|^.*$|'"%${_linecontent}"'|' "$queue_file"
                let LINE--;
                stop=1
            fi
        done
    elif [[ "$_event" == "CREATE,ISDIR" && "$_state" == "(isnotfileisdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_dirname" == "$_pathbelow" ]];then
        # Contoh kasus:
        # mkdir -p aa/bb (directory belum ada sebelumnya)
        # mkdir -p cc/dd/ee (directory belum ada sebelumnya)
        ACTION='ssh_mkdir'
        ARGUMENT1="$_path"
        # Coret
        sed -i "$LINE"'s|^.*$|'"+${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'"+${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
        let LINE++;
        stop=
        until [[ -n "$stop" ]]; do
            populateVariables init
            if [[ "$_event" == "CREATE,ISDIR" && "$_state" == "(isnotfileisdir)" &&  "$_eventbelow" == "MODIFY,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && "$_dirname" == "$_pathbelow" && "$_dirname" == "$ARGUMENT1" ]];then
                ACTION='ssh_mkdir_parents'
                ARGUMENT1="$_path"
                sed -i "$LINE"'s|^.*$|'"+${_linecontent}"'|' "$queue_file"
                sed -i "$LINEBELOW"'s|^.*$|'"+${_linecontentbelow}"'|' "$queue_file"
                let LINE++;
                let LINE++;
            else
                # Kembali ke line sebelumnya.
                let LINE--;
                stop=1
            fi
        done
    elif [[ "$_event" == "CREATE,ISDIR" && "$_state" == "(isnotfileisdir)" ]];then
        ACTION='ssh_mkdir'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"+${_linecontent}"'|' "$queue_file"
    elif [[ "$_event" == "MOVED_FROM" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "MOVED_TO,ISDIR" && "$_statebelow" == "(isnotfileisdir)" && ! "$_path" == "$_pathbelow" ]];then
        # Contoh kasus:
        # mv ini.d itu.d (directory itu.d belum ada sebelumnya)
        ACTION='ssh_rename_dir'
        ARGUMENT1="$_path"
        ARGUMENT2="$_pathbelow"
        sed -i "$LINE"'s|^.*$|'"~${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'"~${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
    elif [[ "$_event" == "MOVED_FROM" && "$_state" == "(isnotfileisnotdir)" && "$_eventbelow" == "MOVED_TO" && "$_statebelow" == "(isfileisnotdir)" && ! "$_path" == "$_pathbelow" ]];then
        # Contoh kasus:
        # mv ini.txt itu.txt (file itu.txt belum ada sebelumnya)
        ACTION='ssh_rename_file'
        ARGUMENT1="$_path"
        ARGUMENT2="$_pathbelow"
        sed -i "$LINE"'s|^.*$|'"~${_linecontent}"'|' "$queue_file"
        sed -i "$LINEBELOW"'s|^.*$|'"~${_linecontentbelow}"'|' "$queue_file"
        let LINE++;
    elif [[ "$_event" == "MOVED_TO" && "$_state" == "(isfileisnotdir)" ]];then
        # Contoh kasus:
        # mv ini.txt -t /dir (file ini.txt belum ada sebelumnya didalam direktori /dir)
        ACTION='ssh_rsync'
        ARGUMENT1="$_path"
        sed -i "$LINE"'s|^.*$|'"+${_linecontent}"'|' "$queue_file"
    else
        # ignore else format line.
        ACTION='ignore'
        ARGUMENT1="$_linecontent"
        sed -i "$LINE"'s|^.*$|'"?${_linecontent}"'|' "$queue_file"
    fi
}

doIt() {
    style="$1"
    relPath1="$2"
    relPath2="$3"
    while IFS= read -r hostname; do
        # echo "  [debug] \$hostname ${hostname}" >> "$log_file"
        # echo "  [debug] \$fullpath1 ${fullpath1}" >> "$log_file"
        # echo "  [debug] \$dirpath1 ${dirpath1}" >> "$log_file"
        # echo "  [debug] \$basename1 ${basename1}" >> "$log_file"
        # echo "  [debug] \$temppath1 ${temppath1}" >> "$log_file"
        # echo "  [debug] \$fullpath2 ${fullpath2}" >> "$log_file"
        # echo "  [debug] \$dirpath2 ${dirpath2}" >> "$log_file"
        # echo "  [debug] \$basename2 ${basename2}" >> "$log_file"
        # echo "  [debug] \$temppath2 ${temppath2}" >> "$log_file"
        remote_dir=$(grep '^'"$hostname"':' <<< "$REMOTE_PATH" | sed -E 's|'"$hostname"':(.*)$|\1|')
        case "$style" in
            ssh_rsync|ssh_rsync_*) #1
                cat <<EOL >> "$command_file"
"$action_rsync_push" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
EOL
                "$action_rsync_push" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
                ;;
            ssh_rm|ssh_rmdir) #2
                cat <<EOL >> "$command_file"
"$action_remove_force" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
EOL
                "$action_remove_force" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
                ;;
            ssh_rename_file|ssh_mv_file) #3, #6
                cat <<EOL >> "$command_file"
"$action_rename_file" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
EOL
                "$action_rename_file" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
                ;;
            ssh_rename_dir|ssh_mv_dir) #4, #7
                cat <<EOL >> "$command_file"
"$action_rename_dir" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
EOL
                "$action_rename_dir" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
                ;;
            ssh_mkdir|ssh_mkdir_parents) #5
                cat <<EOL >> "$command_file"
"$action_make_dir" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
EOL
                "$action_make_dir" "$mydirectory" "$hostname" "$remote_dir" "$relPath1" "$relPath2" &
                ;;
        esac
    done <<< "$REMOTE"
}

object_watched_2="$queue_file";
if [[ $(uname | cut -c1-6) == "CYGWIN" ]];then
    object_watched_2=$(cygpath -w "$queue_file");
fi

REMOTE_PATH=$(cat -)
while IFS= read -r line; do
    _hostname=$(cut -d: -f1 <<< "$line")
    _directory=$(cut -d: -f2 <<< "$line")
    REMOTE+="$_hostname"$'\n'
done <<< "$REMOTE_PATH"
[ -n "$REMOTE" ] && REMOTE=${REMOTE%$'\n'} # trim trailing \n

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
    waiting=0
    until [[ $LINE -gt $LINES ]]; do
        sleep $waiting
        ACTION=; ARGUMENT1=; ARGUMENT2=
        parseLineContents
        [ -n "$ACTION" ] && echo "[queue] ${ACTION} ${ARGUMENT1} ${ARGUMENT2}" >> "$log_file"
        [[ -n "$ACTION" && ! "$ACTION" == ignore ]] && {
            doIt "${ACTION}" "${ARGUMENT1}" "${ARGUMENT2}"
            date +%s%n%Y%m%d-%H%M%S > "$updated_file"
        }
        let LINE++;
        LINES=$(wc -l < "$queue_file")
        if [[ $LINES -ge $LINE ]];then
            let "_diff = $LINES - $LINE"
            [[ $_diff -le 1 ]] && waiting=1 || waiting=0
        fi
    done
    # Dump current LINE for next trigger
    echo "$LINE" > "$line_file"
done
EOF
cat <<'EOF' > "$action_rsync_push"
#!/bin/bash
mydirectory="$1"; hostname="$2"; hostnamedirectory="$3"; relPath1="$4"; relPath2="$5";
tempdir="${hostnamedirectory}.tmp.sync-directory"
fullpath1="${hostnamedirectory}${relPath1}"
dirpath1=$(dirname "$fullpath1")
basename1=$(basename "$fullpath1")
temppath1="${dirpath1}/.${basename1}.ignore-this"
[ -n "$relPath2" ] && {
    fullpath2="${hostnamedirectory}${relPath2}"
    dirpath2=$(dirname "$fullpath2")
    basename2=$(basename "$fullpath2")
    temppath2="${dirpath2}/.${basename2}.ignore-this"
}
ssh "$hostname" '
    mkdir -p "'"$dirpath1"'"; touch "'"$temppath1"'"
    mkdir -p "'"$tempdir"'";
    '
rsync -T "$tempdir" -s -avr "${mydirectory}${relPath1}" "${hostname}:$fullpath1"
ssh "$hostname" '
    sleep 1
    rm -rf "'"$temppath1"'"
    [ -d "'"$tempdir"'" ] && rmdir --ignore-fail-on-non-empty "'"$tempdir"'"
    '
EOF
cat <<'EOF' > "$action_remove_force"
#!/bin/bash
# Something bisa file atau direktori.
# Gunakan sleep untuk mengerem command remove file temp.
mydirectory="$1"; hostname="$2"; hostnamedirectory="$3"; relPath1="$4"; relPath2="$5"
tempdir="${hostnamedirectory}.tmp.sync-directory"
fullpath1="${hostnamedirectory}${relPath1}"
dirpath1=$(dirname "$fullpath1")
basename1=$(basename "$fullpath1")
temppath1="${dirpath1}/.${basename1}.ignore-this"
[ -n "$relPath2" ] && {
    fullpath2="${hostnamedirectory}${relPath2}"
    dirpath2=$(dirname "$fullpath2")
    basename2=$(basename "$fullpath2")
    temppath2="${dirpath2}/.${basename2}.ignore-this"
}
ssh "$hostname" '
    touch "'"$temppath1"'"
    rm -rf "'"$fullpath1"'";
    sleep 1;
    rm -rf "'"$temppath1"'"
    '
EOF
cat <<'EOF' > "$action_rename_file"
#!/bin/bash
mydirectory="$1"; hostname="$2"; hostnamedirectory="$3"; relPath1="$4"; relPath2="$5"
tempdir="${hostnamedirectory}.tmp.sync-directory"
fullpath1="${hostnamedirectory}${relPath1}"
dirpath1=$(dirname "$fullpath1")
basename1=$(basename "$fullpath1")
temppath1="${dirpath1}/.${basename1}.ignore-this"
[ -n "$relPath2" ] && {
    fullpath2="${hostnamedirectory}${relPath2}"
    dirpath2=$(dirname "$fullpath2")
    basename2=$(basename "$fullpath2")
    temppath2="${dirpath2}/.${basename2}.ignore-this"
}
ssh "$hostname" '
    if [ -f "'"$fullpath1"'" ];then
        mkdir -p "'"$dirpath1"'"; touch "'"$temppath1"'";
        mkdir -p "'"$dirpath2"'"; touch "'"$temppath2"'";
        mv "'"$fullpath1"'" "'"$fullpath2"'";
    fi
    '
_buffer=$(ssh "$hostname" '
    if [ ! -f "'"$fullpath2"'" ];then
        mkdir -p "'"$dirpath1"'"; touch "'"$temppath1"'";
        mkdir -p "'"$dirpath2"'"; touch "'"$temppath2"'";
        mkdir -p "'"$tempdir"'";
        echo 0;
    fi
    '
)
[[ $_buffer == 0 ]] && rsync -T "$tempdir" -s -avr "${mydirectory}${relPath2}" "${hostname}:$fullpath2"
ssh "$hostname" '
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'"
    [ -d "'"$tempdir"'" ] && rmdir --ignore-fail-on-non-empty "'"$tempdir"'"
    '
EOF
cat <<'EOF' > "$action_rename_dir"
#!/bin/bash
mydirectory="$1"; hostname="$2"; hostnamedirectory="$3"; relPath1="$4"; relPath2="$5"
tempdir="${hostnamedirectory}.tmp.sync-directory"
fullpath1="${hostnamedirectory}${relPath1}"
dirpath1=$(dirname "$fullpath1")
basename1=$(basename "$fullpath1")
temppath1="${dirpath1}/.${basename1}.ignore-this"
[ -n "$relPath2" ] && {
    fullpath2="${hostnamedirectory}${relPath2}"
    dirpath2=$(dirname "$fullpath2")
    basename2=$(basename "$fullpath2")
    temppath2="${dirpath2}/.${basename2}.ignore-this"
}
ssh "$hostname" '
    if [ -d "'"$fullpath1"'" ];then
        mkdir -p "'"$dirpath1"'"; touch "'"$temppath1"'"
        mkdir -p "'"$dirpath2"'"; touch "'"$temppath2"'"
        mv "'"$fullpath1"'" "'"$fullpath2"'"
    fi
    sleep 1
    rm -rf "'"$temppath1"'"
    rm -rf "'"$temppath2"'";
    '
EOF
cat <<'EOF' > "$action_make_dir"
#!/bin/bash
# mkdir terlalu rumit dan njelimit.
# jadi kita biarkan terjadi efek berantai.
mydirectory="$1"; hostname="$2"; hostnamedirectory="$3"; relPath1="$4"; relPath2="$5"
tempdir="${hostnamedirectory}.tmp.sync-directory"
fullpath1="${hostnamedirectory}${relPath1}"
dirpath1=$(dirname "$fullpath1")
basename1=$(basename "$fullpath1")
temppath1="${dirpath1}/.${basename1}.ignore-this"
[ -n "$relPath2" ] && {
    fullpath2="${hostnamedirectory}${relPath2}"
    dirpath2=$(dirname "$fullpath2")
    basename2=$(basename "$fullpath2")
    temppath2="${dirpath2}/.${basename2}.ignore-this"
}
ssh "$hostname" '
    mkdir -p "'"$fullpath1"'";
    '
EOF
# End Bash Script.
# ------------------------------------------------------------------------------

"$queue_watcher" "$cluster_name" "$mydirectory" <<< "$REMOTE_PATH" &

IFS=''
echo "[directory] ("$(date +%Y-%m-%d\ %H:%M:%S)") Start watching." >> "$log_file"
inotifywait -q -e modify,create,delete,move -m -r --timefmt %Y%m%d-%H%M%S --format "$format" "$object_watched" | while read -r LINE
do
    # echo "[debug] LINE: ${LINE}" >> "$log_file"
    # Posisi paling kanan menyebabkan terdapat tambahan karakter \r (CR)
    [ -n "$ISCYGWIN" ] && LINE=$(sed 's/\r$//' <<< "$LINE")
    EVENT=$(sed -E 's|<<(.*)>><<(.*)>><<(.*)>><<(.*)>>|\1|' <<< "$LINE")
    DIR=$(sed -E 's|<<(.*)>><<(.*)>><<(.*)>><<(.*)>>|\2|' <<< "$LINE")
    [ -n "$ISCYGWIN" ] && DIR=$(cygpath "$DIR") || DIR=${DIR%/}
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
    RELPATH=$(echo "$ABSPATH" | sed "s|${mydirectory}||")
    skip=
    for i in "${exclude[@]}"; do
        if [[ "$RELPATH" =~ $i ]];then
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
    LINE+="$RELPATH"
    echo "$LINE" >> "$queue_file"
done
