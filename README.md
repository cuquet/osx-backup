# OS X CLI backup file
Bash script based on bender 2.7 written by Robot Cloud
[http://www.forgetcomputers.com/robot-cloud](http://www.forgetcomputers.com/robot-cloud).

Usage:

`sudo mel_backup.sh [options] `

Options:

* `-m` Backup Mysql/MariaDB databases. Require mysql password file. Please check https://stackoverflow.com/a/32409448
* `-p` Backup Postgres databases.
* `-b value` Destination folder
* `-f value` Folder to backup

Example:

`sudo /usr/local/bin/mel_backup.sh [ -b BACKUP_FOLDER ] [-m -p] [-f folderpath]`

Restore functions:

* To restore all OS X Server settings:

`sudo serveradmin settings < /path/to/your-sa_backup-allservices.backup`	
* To restore a specific OS X Server setting:

`sudo serveradmin settings < /path/to/your-sa_backup-servicename.backup`	
* To restore Profile Manager:

`sudo cat /path/to/your-profile-backup.sql | psql -h /Library/Server/ProfileManager/Config/var/PostgreSQL -U _devicemgr devicemgr_v2m0`
* To restore an Open Directory archive. First command for the password:

`system_profiler SPHardwareDataType | awk '/Hardware UUID/{print $3}'`

`sudo slapconfig -restoredb /path/to/your/archive.sparseimage`
