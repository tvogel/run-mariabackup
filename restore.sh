#!/usr/bin/env bash

# WARNING : DO NOT RUN THIS SCRIPT Without understanding exactly what it does.
# BECAUSE Carnivorous lazer wielding baboons will come and EAT your database

# set -o xtrace
set -o errexit

script_path=$(dirname $(realpath $0))
source "${script_path}/common.sh"

ExistsDatabase () {
  mysql ${mysql_user_arg} -Ne "show databases like '$1'" | grep -qF "$1"
}

SecureFileDir () {
  if ! secure_file_dir=$(mysql ${mysql_user_arg} -Ne "select @@secure_file_priv" 2>/dev/null) \
    || [ "${secure_file_dir}" = "NULL" ]
  then
    echo "${TMPDIR}"
    return 0
  fi
  echo "${secure_file_dir}"
}

IsIncremental() {
  grep -q '^tool_command = .* --incremental-basedir=.* --stream=' xtrabackup_info
}

GetBaseDir() {
  if ! IsIncremental; then
    echo "Cannot find basedir!" >&2
    return 1
  fi
  grep '^tool_command = ' xtrabackup_info | sed -r 's/^.* --incremental-basedir=(.*) --stream=.*$/\1/'
}

StartMysql() {
  systemctl start ${MYSQL_SERVICE}
}

if [ ! -e "backup.stream.${COMPRESS_EXT}" ]; then
  echo "Cannot find backup.stream.${COMPRESS_EXT}. $(basename $0) must be run from the respective backup dir." >&2
  exit 1
fi

if [ ! -e "xtrabackup_info" ]; then
  echo "Missing xtrabackup_info." >&2
  exit 1
fi

src_database="$1"
dst_database="$2"

if [ -n "${src_database}" ] && [ -z "${dst_database}" ]; then
  echo "Missing <dst_database>" >&2
  echo "Usage: $(basename $0) [<src_database> <dst_database>]" >&2
  exit 1
fi

if [ -z "${src_database}" ]; then
  echo "Restoring all databases"
  if [ -e "${MYSQL_DATA_PATH}_before_restore" ] ; then
    echo "${MYSQL_DATA_PATH}_before_restore already exists." >&2
    exit 1
  fi
else
  if [ "${src_database}" = "${dst_database}" ]; then
    echo "<src_database> and <dst_database> must be different." >&2
    exit 1
  fi
  if ExistsDatabase "${dst_database}"; then
    echo "<dst_database> must not exist." >&2
    exit 1
  fi
  echo "Restoring \`${src_database}\` into \`${dst_database}\`"

  if [ ! -e "${src_database}-schema.sql" ]; then
    echo "Missing ${src_database}-schema.sql which is required for single-database restore." >&2
    exit 1
  fi
fi

leafdir="$PWD"

backup_stack=()
while true; do
  backup_stack=("$PWD" "${backup_stack[@]}")
  IsIncremental && is_incremental=1 || is_incremental=0
  if [ ${is_incremental} = 1 ]; then
    cd $(GetBaseDir)
  fi
  [ ${is_incremental} = 0 ] && break
done

tag="base"
echo "Backup stack:"
for backup in "${backup_stack[@]}"; do
  echo "${tag} ${backup}"
  if [ ! -e "${backup}/backup.stream.${COMPRESS_EXT}" ]; then
    echo "Missing backup.stream.${COMPRESS_EXT}." >&2
    exit 1
  fi

  if [ ! -e "${backup}/xtrabackup_info" ]; then
    echo "Missing xtrabackup_info." >&2
    exit 1
  fi

  tag="incr"
done

echo "Preparing restore..."
rm -rf "${leafdir}/restore"
mkdir -p "${leafdir}/restore"

tag="base"
for backup in "${backup_stack[@]}"; do
  echo "${tag} ${backup}"

  if [ ${tag} = base ]; then
    ${UNCOMPRESS} "$backup/backup.stream.${COMPRESS_EXT}" | ${STREAM} -x -C "${leafdir}/restore"
    ${MARIABACKUP} --prepare --target-dir="${leafdir}/restore"
  else
    rm -rf "${backup}/unpack"
    mkdir -p "${backup}/unpack"
    ${UNCOMPRESS} "${backup}/backup.stream.${COMPRESS_EXT}" | ${STREAM} -x -C "${backup}/unpack"
    ${MARIABACKUP} --prepare --target-dir="${leafdir}/restore" --incremental-dir="${backup}/unpack"
    rm -rf "${backup}/unpack"
  fi

  tag="incr"
done

echo "Preparation complete."

cd "${leafdir}"


echo "Restoring data"
if [ -z "${src_database}" ]; then # all-database restore
  echo "Stopping MariaDB"
  systemctl stop ${MYSQL_SERVICE}
  trap StartMysql EXIT
  mv "${MYSQL_DATA_PATH}" "${MYSQL_DATA_PATH}_before_restore"
  echo "Copying files to ${MYSQL_DATA_PATH}"
  ${MARIABACKUP} --copy-back --target-dir "${leafdir}/restore"
  rm -rf "${leafdir}/restore"
  chown -R ${MYSQL_FS_USER}:${MYSQL_FS_GROUP} "${MYSQL_DATA_PATH}"
  echo "Starting MariaDB"
  systemctl start ${MYSQL_SERVICE}
  trap EXIT
else # single-database restore
  if [ ! -e "${leafdir}/restore/${src_database}" ]; then
    echo "${leafdir}/restore/${src_database} not found." >&2
    exit 1
  fi
  ${MARIABACKUP} --prepare --export --target-dir="${leafdir}/restore"

  mysqladmin ${mysql_user_arg} create "${dst_database}"
  mysql ${mysql_user_arg} "${dst_database}" < "${leafdir}/${src_database}-schema.sql"

  if [ ! -e "${MYSQL_DATA_PATH}/${dst_database}" ]; then
    echo "${MYSQL_DATA_PATH}/${dst_database} not found." >&2
    exit 1
  fi

  securefiledir="$(SecureFileDir)/restore_${dst_database}"
  mkdir -p "${securefiledir}"
  chown -R ${MYSQL_FS_USER}:${MYSQL_FS_GROUP} "${securefiledir}"
  rm -rf ${securefiledir}/drop_fk.sql \
    ${securefiledir}/discard_tablespace.sql \
    ${securefiledir}/import_tablespace.sql \
    ${securefiledir}/add_fk.sql

  mysql ${mysql_user_arg} information_schema <<SQL
select concat("ALTER TABLE ",table_name," DISCARD TABLESPACE;")  AS discard_tablespace
into outfile '${securefiledir}/discard_tablespace.sql'
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
from tables
where TABLE_SCHEMA='${dst_database}' and engine='InnoDB';

select concat("ALTER TABLE ",table_name," IMPORT TABLESPACE;") AS import_tablespace
into outfile '${securefiledir}/import_tablespace.sql'
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
from tables
where TABLE_SCHEMA='${dst_database}' and engine='InnoDB';

SELECT
concat ("ALTER TABLE ", rc.CONSTRAINT_SCHEMA, ".",rc.TABLE_NAME," DROP FOREIGN KEY ", rc.CONSTRAINT_NAME,";") AS drop_keys
into outfile '${securefiledir}/drop_fk.sql'
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
FROM REFERENTIAL_CONSTRAINTS AS rc
JOIN TABLES t ON t.TABLE_SCHEMA = rc.CONSTRAINT_SCHEMA AND t.TABLE_NAME = rc.TABLE_NAME
where CONSTRAINT_SCHEMA = '${dst_database}' AND t.ENGINE = 'InnoDB';

SELECT
CONCAT ("ALTER TABLE ",
KCU.CONSTRAINT_SCHEMA, ".",
KCU.TABLE_NAME,"
ADD CONSTRAINT ",
KCU.CONSTRAINT_NAME, "
FOREIGN KEY ", "
(\`",KCU.COLUMN_NAME,"\`)", "
REFERENCES \`",REFERENCED_TABLE_NAME,"\`
(\`",REFERENCED_COLUMN_NAME,"\`)" ,"
ON UPDATE " ,(SELECT UPDATE_RULE FROM REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_NAME = KCU.CONSTRAINT_NAME AND CONSTRAINT_SCHEMA = KCU.CONSTRAINT_SCHEMA),"
ON DELETE ",(SELECT DELETE_RULE FROM REFERENTIAL_CONSTRAINTS WHERE CONSTRAINT_NAME = KCU.CONSTRAINT_NAME AND CONSTRAINT_SCHEMA = KCU.CONSTRAINT_SCHEMA),";") AS add_keys
into outfile '${securefiledir}/add_fk.sql'
FIELDS TERMINATED BY ','
LINES TERMINATED BY '\n'
FROM KEY_COLUMN_USAGE AS KCU
JOIN TABLES T ON T.TABLE_SCHEMA = KCU.CONSTRAINT_SCHEMA AND T.TABLE_NAME = KCU.TABLE_NAME
WHERE KCU.CONSTRAINT_SCHEMA = '${dst_database}' AND T.ENGINE = 'InnoDB'
AND KCU.POSITION_IN_UNIQUE_CONSTRAINT >= 0
AND KCU.CONSTRAINT_NAME NOT LIKE 'PRIMARY';
SQL
  echo "Dropping foreign keys"
  mysql ${mysql_user_arg} "${dst_database}" < "${securefiledir}/drop_fk.sql"
  echo "Discarding tablespace"
  mysql ${mysql_user_arg} "${dst_database}" < "${securefiledir}/discard_tablespace.sql"

  echo "Stopping MariaDB"
  systemctl stop ${MYSQL_SERVICE}
  trap StartMysql EXIT

  echo "Copying files to ${MYSQL_DATA_PATH}/${dst_database}/"
  cp "${leafdir}/restore/${src_database}"/* "${MYSQL_DATA_PATH}/${dst_database}/"
  chown -R ${MYSQL_FS_USER}:${MYSQL_FS_GROUP} "${MYSQL_DATA_PATH}/${dst_database}"

  echo "Starting MariaDB"
  systemctl start ${MYSQL_SERVICE}
  trap EXIT

  echo "Importing tablespace"
  mysql ${mysql_user_arg} "${dst_database}" < "${securefiledir}/import_tablespace.sql"
  echo "Adding foreign keys"
  mysql ${mysql_user_arg} "${dst_database}" < "${securefiledir}/add_fk.sql"

  rm -rf ${securefiledir}/drop_fk.sql \
    ${securefiledir}/discard_tablespace.sql \
    ${securefiledir}/import_tablespace.sql \
    ${securefiledir}/add_fk.sql \
    restore

  cat <<MSG
Database restored to ${dst_database}. If you are happy with its state, move it to the original database using:
> mysqldump ${mysql_user_arg} --routines "${dst_database}" | mysql "${src_database}"
> mysqladmin ${mysql_user_arg} drop "${dst_database}"
MSG
fi

echo "MariaDB is back up."

exit 0
