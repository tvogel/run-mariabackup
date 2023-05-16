source "${script_path}/config.sh"

ReleaseLock () {
  if rmdir "${LOCKDIR}"
  then
    echo "Lock directory removed"
  else
    echo "Could not remove lock dir" >&2
  fi
}

GetLockOrDie () {
  if mkdir "${LOCKDIR}"
  then
    echo "Lock directory created"
  else
    echo "Could not create lock directory" "${LOCKDIR}"
    echo "Is another backup running?"
    exit 1
  fi
  trap ReleaseLock EXIT
}

FormatSeconds () {
  seconds="$1"
  date -ud @${seconds} +"$(( seconds/3600/24 ))d %Hh %Mm %Ss" \
    | sed -r 's/\b0([0-9])/\1/g; s/\b0(s|m|h|d)//g; s/ +/ /g; s/^ +//; s/ +$//; s/^$/0s/'
}

mysql_user_arg=""

if [ -n "${MYSQL_USER}" ] ; then
  mysql_user_arg="--user=${MYSQL_USER}"
  MARIABACKUP_OPTIONS=("${MARIABACKUP_OPTIONS[@]}" "${mysql_user_arg}")
fi
