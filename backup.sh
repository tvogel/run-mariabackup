#!/usr/bin/env bash

# set -o xtrace
set -o errexit
set -o pipefail

script_path=$(dirname $(realpath $0))
source "${script_path}/common.sh"

DumpSchema () {
  mysql ${mysql_user_arg} -e 'show databases' |
    grep -Ev 'Database|information_schema|performance_schema' |
    while read dbname; do
      mysqldump ${mysql_user_arg} --routines --no-data ${dbname} > "${target_dir}/${dbname}-schema.sql"
    done
}

BaseBackupRequested () {
  rm "${BACKUP_PATH}/base-backup.request" &>/dev/null
}

base_backup_path="${BACKUP_PATH:?}/base"
incr_backup_path="${BACKUP_PATH:?}/incr"
start_timestamp="$(date +%s)"

echo "----------------------------"
echo
echo "run-mariabackup.sh: MySQL backup script"
echo "started: $(date -d @${start_timestamp})"
echo

mkdir -p "${base_backup_path}"

[ ! -d "${base_backup_path}" ] || [ ! -w "${base_backup_path}" ] &&
  ( echo "${base_backup_path} does not exist or is not writable"; exit 1 )

mkdir -p "${incr_backup_path}"

[ ! -d "${incr_backup_path}" ] || [ ! -w "${incr_backup_path}" ] &&
  ( echo "${incr_backup_path} does not exist or is not writable"; exit 1 )

! mysqladmin ping &> /dev/null &&
  ( echo "HALTED: MySQL ping failed."; exit 1 )

[ -n "${LIMIT_OPEN_FILES}" ] && ulimit -n ${LIMIT_OPEN_FILES}

GetLockOrDie

latest_base_backup="$(find "${base_backup_path}" -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1)"

base_timestamp=$([ "${latest_base_backup}" ] && stat -c %Y "${base_backup_path}/${latest_base_backup}/backup.stream.${COMPRESS_EXT}" || true)

if ! BaseBackupRequested && [ "${latest_base_backup}" ] && [ "$(( base_timestamp + FULLBACKUP_EVERY_SECONDS + 5 ))" -ge "${start_timestamp}" ]; then
  echo 'New incremental backup'

  mkdir -p "${incr_backup_path}/${latest_base_backup}"

  [ ! -d "${incr_backup_path}/${latest_base_backup}" ] || [ ! -w "${incr_backup_path}/${latest_base_backup}" ] &&
    (
      echo "${incr_backup_path}/${latest_base_backup} does not exist or is not writable"
      exit 1
    )

  latest_incr_backup="$(find . -mindepth 2  -maxdepth 2 -name xtrabackup_checkpoints -printf '%h\n' | sort -nr | head -1)"
  if [ "${latest_incr_backup}" ]; then
    # This is a 2+ incremental backup
    incremental_basedir="${latest_incr_backup}"
  else
    # This is the first incremental backup
    incremental_basedir="${base_backup_path}/${latest_base_backup}"
  fi

  target_dir="${incr_backup_path}/${latest_base_backup}/$(date +%F_%H-%M-%S)"
  mkdir -p "${target_dir}"

  # Create incremental Backup
  DumpSchema
  (${MARIABACKUP} "${MARIABACKUP_OPTIONS[@]}" \
    --backup \
    --extra-lsndir="${target_dir}" \
    --incremental-basedir="${incremental_basedir}" \
    --stream="${STREAM}" \
    | ${COMPRESS} > "${target_dir}/backup.stream.${COMPRESS_EXT}") \
  2>&1 | tee >(${COMPRESS} > "${target_dir}/backup.log.${COMPRESS_EXT}")
else
  echo 'New full backup'

  latest_base_backup=$(date +%F_%H-%M-%S)
  target_dir="${base_backup_path}/${latest_base_backup}"
  mkdir -p "${target_dir}"

  # Create a new full backup
  DumpSchema
  (${MARIABACKUP} "${MARIABACKUP_OPTIONS[@]}" \
    --backup \
    --extra-lsndir="${target_dir}" \
    --stream="${STREAM}" | ${COMPRESS} > "${target_dir}/backup.stream.${COMPRESS_EXT}") \
  2>&1 | tee >(${COMPRESS} > "${target_dir}/backup.log.${COMPRESS_EXT}")
fi

max_age_minutes="$(( FULLBACKUP_EVERY_SECONDS * ( EXTRA_FULL_BACKUPS_TO_KEEP + 1 ) / 60 ))"
echo "Cleaning up old backups (older than $(FormatSeconds $((max_age_minutes * 60)))) and temporary files"

# Delete old backups
find "${base_backup_path}" -mindepth 1 -maxdepth 1 -type d -mmin +${max_age_minutes} -printf "%P\n" |
  while read -r old_backup; do
    if [ "${old_backup}" = "${latest_base_backup}" ]; then
        echo "keeping current ${old_backup}"
        continue
    fi
    echo "deleting ${old_backup}"
    rm -rf "${base_backup_path}/${old_backup:?}"
    rm -rf "${incr_backup_path}/${old_backup:?}"
  done

completed_timestamp=$(date +%s)
spent_seconds="$(( completed_timestamp - start_timestamp ))"
echo
echo "took ${spent_seconds} seconds"
echo "completed_timestamp: $(date -d @${completed_timestamp})"
exit 0
