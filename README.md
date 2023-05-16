# README

*   *forked from [YoSiJo/run-mariabackup](https://codeberg.org/YoSiJo/run-mariabackup)*
    *   *forked from [omegazeng/run-mariabackup](https://github.com/omegazeng/run-mariabackup)*
        *   *forked from [jmfederico/run-xtrabackup.sh](https://gist.github.com/jmfederico/1495347)*

Note: I have tested this on openSUSE Tumbleweed 20230512 with MariaDB 10.11.2.

## Fat Warning

This new fork (as of 2023-05-15) has seen only very limited testing and use. In particular, only with MyISAM and InnoDB tables.
In these limited cases, it worked fine but there is no guarantee at all that it will fulfill any purpose in your specific environment. As it is acting on complete database server setups with possibly many databases and complexities which I have never seen before, there is a high probability that this script will break in your scenario and can possibly have catastrophic effects. Just as a non-exclusive single example, I have not tried it on databases with stored procedures or triggers.

So, use these scripts only after your own educated review and on your own risk!

Also, please share any concerns and observations, most preferred of course, in the form of pull-requests or bug reports.

## Remark

This fork is a thorough rewrite of the above mentioned precursors. It contains various fixes and extensions, in particular single-database restore.

## Links

[Full Backup and Restore with Mariabackup](https://mariadb.com/kb/en/library/full-backup-and-restore-with-mariabackup/)

[Incremental Backup and Restore with Mariabackup](https://mariadb.com/kb/en/library/incremental-backup-and-restore-with-mariabackup/)

[Individual Database Restores with MariaBackup from Full backup](https://mariadb.com/kb/en/individual-database-restores-with-mariabackup-from-full-backup/)

## Install mariabackup

    sudo apt install mariadb-backup

## Create a backup user

```sql
-- See https://mariadb.com/kb/en/mariabackup-overview/#authentication-and-privileges
CREATE USER 'backup'@'localhost' IDENTIFIED BY 'YourPassword';
-- MariaDB < 10.5:
GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'localhost';
-- MariaDB >= 10.5:
GRANT RELOAD, PROCESS, LOCK TABLES, BINLOG MONITOR ON *.* TO 'backup'@'localhost';
FLUSH PRIVILEGES;
```

## Configuration

Edit `config.sh` to match your needs and environment.

## Usage

    MYSQL_PASSWORD=YourPassword bash run-mariabackup/backup.sh

You can place a file called `base-backup.request` into `${BACKUP_PATH}` in order to request a base
(non-incremental) backup (e.g. using a weekly cron-job on Sunday night).

For an all-database restore, go to the directory with your intended backup state, 
i.e. `${BACKUP_PATH}/base/yyyy-mm-dd_HH-MM-SS` 
or `${BACKUP_PATH}/incr/yyyy-mm-dd_HH-MM-SS/yyyy-mm-dd_HH-MM-SS` and run:

    MYSQL_PASSWORD=YourPassword bash run-mariabackup/restore.sh

For a single-database restore:

    MYSQL_PASSWORD=YourPassword bash run-mariabackup/restore.sh <src-database> <dst-database>

## Crontab

    #MySQL Backup
    30 2 * * * MYSQL_PASSWORD=YourPassword bash /data/run-mariabackup/backup.sh &> /var/log/mariabackup.log
