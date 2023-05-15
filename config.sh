MARIABACKUP=mariabackup                            # Galera Cluster uses mariabackup instead of xtrabackup.
MARIABACKUP_OPTIONS=()                             # Additional mariabackup options (backup only, not restore)
COMPRESS="xz -1"                                   # pigz (a parallel implementation of gzip) could be used if available.
COMPRESS_EXT="xz"                                  # extension of the compressed stream
UNCOMPRESS="xzcat"                                 # tool to uncompress to stdout
STREAM=mbstream                                    # sometimes named mbstream to avoid clash with Percona command
BACKUP_PATH=/var/backups/mariabackup               # Backup target
FULLBACKUP_EVERY_SECONDS="$(( 7 * 24 * 60 * 60 ))" # Create a new full backup every X seconds
EXTRA_FULL_BACKUPS_TO_KEEP=0                       # Number of additional backups cycles a backup should be kept for.
LOCKDIR=/tmp/mariabackup.lock                      # Path of lockfile
MYSQL_SERVICE=mysql                                # Name of the MariaDB systemd service
MYSQL_USER=root                                    # MariaDB database backup user
MYSQL_DATA_PATH=/var/lib/mysql                     # Path to the MariaDB data files
MYSQL_FS_USER=mysql                                # System user for the MariaDB data files
MYSQL_FS_GROUP=mysql                               # System group for the MariaDB data files
