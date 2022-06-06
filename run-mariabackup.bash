#!/usr/bin/env bash

BACKCMD=mariabackup                       # Galera Cluster uses mariabackup instead of xtrabackup.
GZIPCMD=gzip                              # pigz (a parallel implementation of gzip) could be used if available.
STREAMCMD=xbstream                        # sometimes named mbstream to avoid clash with Percona command
BACKDIR=/var/backup/mariadb               # Backup target
FULLBACKUPCYCLE="$(( 7 * 24 * 60 * 60 ))" # Create a new full backup every X seconds
KEEP=3                                    # Number of additional backups cycles a backup should be kept for.
LOCKDIR=/tmp/mariabackup.lock             # Path of lockfile

ReleaseLockAndExitWithCode () {
  if rmdir "${LOCKDIR}"
  then
    echo "Lock directory removed"
  else
    echo "Could not remove lock dir" >&2
  fi
  exit "${1}"
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
}

BASEBACKDIR=$BACKDIR/base
INCRBACKDIR=$BACKDIR/incr
START="$(date +%s)"

echo "----------------------------"
echo
echo "run-mariabackup.sh: MySQL backup script"
echo "started: $(date)"
echo

[ ! -d "${BASEBACKDIR}" ] && mkdir -p "${BASEBACKDIR}"

# Check base dir exists and is writable
[ ! -d "${BASEBACKDIR}" ] || [ ! -w "${BASEBACKDIR}" ] &&
  ( echo "${BASEBACKDIR} does not exist or is not writable"; exit 1 )

[ ! -d "${INCRBACKDIR}" ] && mkdir -p "${INCRBACKDIR}"

# check incr dir exists and is writable
[ ! -d "${INCRBACKDIR}" ] || [ ! -w "${INCRBACKDIR}" ] &&
  ( echo "${INCRBACKDIR} does not exist or is not writable"; exit 1 )

! mysqladmin ping &> /dev/null &&
  ( echo "HALTED: MySQL ping failed."; exit 1 )

GetLockOrDie

echo "Check completed OK"

# Find latest backup directory
LATEST="$(find "${BASEBACKDIR}" -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1)"

AGE="$(stat -c %Y "${BASEBACKDIR}/${LATEST}/backup.stream.gz")"

if [ "${LATEST}" ] && [ "$(( AGE + FULLBACKUPCYCLE + 5 ))" -ge "${START}" ]; then
  echo 'New incremental backup'
  # Create an incremental backup

  # Check incr sub dir exists
  # try to create if not
  [ ! -d "${INCRBACKDIR}/${LATEST}" ] && mkdir -p "${INCRBACKDIR}/${LATEST}"

  # Check incr sub dir exists and is writable
  [ -d "${INCRBACKDIR}/${LATEST}" ] || [ ! -w "${INCRBACKDIR}/${LATEST}" ] &&
    (
      echo "${INCRBACKDIR}/${LATEST} does not exist or is not writable"
      ReleaseLockAndExitWithCode 1
    )

  LATESTINCR="$(find "${INCRBACKDIR}/${LATEST}" -mindepth 1  -maxdepth 1 -type d | sort -nr | head -1)"
  if [ ! "${LATESTINCR}" ]; then
    # This is the first incremental backup
    INCRBASEDIR="$BASEBACKDIR/${LATEST}"
  else
    # This is a 2+ incremental backup
    INCRBASEDIR="${LATESTINCR}"
  fi

  TARGETDIR="${INCRBACKDIR}/${LATEST}/$(date +%F_%H-%M-%S)"
  mkdir -p "${TARGETDIR}"

  # Create incremental Backup
  ${BACKCMD} --backup --extra-lsndir="${TARGETDIR}" --incremental-basedir="${INCRBASEDIR}" --stream="${STREAMCMD}" | ${GZIPCMD} > "${TARGETDIR}/backup.stream.gz"
else
  echo 'New full backup'

  TARGETDIR="$BASEBACKDIR/$(date +%F_%H-%M-%S)"
  mkdir -p "${TARGETDIR}"

  # Create a new full backup
  ${BACKCMD} --backup --extra-lsndir="${TARGETDIR}" --stream="${STREAMCMD}" | $GZIPCMD > "${TARGETDIR}/backup.stream.gz"
fi

MINS="$(( FULLBACKUPCYCLE * ( KEEP + 1 ) / 60 ))"
echo "Cleaning up old backups (older than ${MINS} minutes) and temporary files"

# Delete old backups
find "${BASEBACKDIR}" -mindepth 1 -maxdepth 1 -type d -mmin +${MINS} -print0 |
  while IFS= read -r -d '' DEL; do
    echo "deleting $DEL"
    rm -rf "${BASEBACKDIR:?}/${DEL}"
    rm -rf "${INCRBACKDIR:?}/${DEL}"
  done

SPENT="$(( $(date +%s) - START ))"
echo
echo "took ${SPENT} seconds"
echo "completed: $(date)"
ReleaseLockAndExitWithCode 0
