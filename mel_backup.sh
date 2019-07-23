#!/bin/bash

MYSQL_PASSWD_FILE="/usr/local/etc/.sqlpwd"

host=$(hostname)
macOS=$(sw_vers | awk '/ProductVersion/{print substr($2,1,5)}' | tr -d ".")
date=$(date +%Y-%m-%d-%H%M)
ldapPass=$(system_profiler SPHardwareDataType | awk '/Hardware UUID/{print $3}')
pathBackups=""
macSN=$(system_profiler SPHardwareDataType | awk '/Serial Number/{print $4}')
notifTitle="Backup Error on: $macSN"
keepUntil="15"
pathLog="/usr/local/var/log/$(basename $0).log"
CMD_MYSQLDUMP="$(which mysqldump)"
CMD_MYSQL="$(which mysql)"
CMD_PSQL="$(which psql)"
CMD_PG_DUMP="$(which pg_dump)"
CMD_VACUUMDB="$(which vacuumdb)"


function usage() {
	echo "Backup script for Apple Server, Mysql, Postgres and web files.
	Usage:
	    sudo $(basename $0) [options] 
	    -m          Backup Mysql/MariaDB databases. Require mysql password file (ex: MYSQL_PASSWD_FILE=/usr/local/etc/.sqlpwd)
			Please check https://stackoverflow.com/a/32409448
	    -p          Backup Postgres databases.
	    -b value    Destination folder
	    -f value	Folder to backup
	Example:
	    sudo $(basename $0) [ -b BACKUP_FOLDER ] [-m -p] [-f folderpath]
	
	Restore functions:
	  -To restore all OS X Server settings:
	    sudo serveradmin settings < /path/to/your-sa_backup-allservices.backup
	
	  -To restore a specific OS X Server setting:
	    sudo serveradmin settings < /path/to/your-sa_backup-servicename.backup
	
	  -To restore Profile Manager:
	    sudo cat /path/to/your-profile-backup.sql | psql -h /Library/Server/ProfileManager/Config/var/PostgreSQL -U _devicemgr devicemgr_v2m0
	
	  -To restore an Open Directory archive:
	    password: system_profiler SPHardwareDataType | awk '/Hardware UUID/{print $3}'
	    sudo slapconfig -restoredb /path/to/your/archive.sparseimage"
	    exit ${1:-0}
}

# https://www.shellscript.sh/tips/spinner/
# https://github.com/tlatsas/bash-spinner/
function _spinner() {
    # $1 start/stop
    #
    # on start: $2 display message
    # on stop : $2 process exit status
    #           $3 spinner function pid (supplied from stop_spinner)

    local on_success="DONE"
    local on_fail="FAIL"

    case $1 in
        start)
            # calculate the column where spinner and status msg will be displayed
            let column=$(tput cols)-${#2}-8
            # display message and position the cursor in $column column
            echo -ne ${2}
            printf "%${column}s"

            # start spinner
            i=1
            sp='\|/-'
            delay=${SPINNER_DELAY:-0.15}

            while :
            do
                printf "\b${sp:i++%${#sp}:1}"
                sleep $delay
            done
            ;;
        stop)
            if [[ -z ${3} ]]; then
                echo "spinner is not running.."
                exit 1
            fi

            kill $3 > /dev/null 2>&1

            # inform the user uppon success or failure
            echo -en "\b["
            if [[ $2 -eq 0 ]]; then
                echo -en "${on_success}"
            else
                echo -en "${on_fail}"
            fi
            echo -e "]"
            ;;
        *)
            echo "invalid argument, try {start/stop}"
            exit 1
            ;;
    esac
}

function start_spinner {
    # $1 : msg to display
    _spinner "start" "${1}" &
    # set global spinner pid
    _sp_pid=$!
    disown
}

function stop_spinner {
    # $1 : command exit status
    _spinner "stop" $1 $_sp_pid
    unset _sp_pid
}

# trap ctrl-c and call ctrl_c()
trap ctrl_c INT

function ctrl_c() {
        echo "** Trapped CTRL-C"
        stop_spinner $?
}

function set_variable() {
  local varname=$1
  shift
  if [ -z "${!varname}" ]; then
    eval "$varname=\"$@\""
  else
    echo "Error: $varname already set"
    usage
  fi
}

function LogNotification(){
	# if string isn't empty
	if [ -n "$P_ERROR" ]; then
		open /Applications/Utilities/Console.app  $pathLog
		/usr/bin/osascript -e "display notification \"$pathLog\" with title \"$notifTitle\""
	fi
}

function _log_msg() {
	echo $(date "+%Y-%m-%d %H:%M:%S: ") ["$(basename $0)"] $1 >> "$pathLog"
}

function _log_event () {
	echo $1
	echo $(_log_msg "$1")
}

function Compress_File () {
	/usr/bin/bzip2 -c $1 
}

function RemoveOldBackups () {
	# Remove backups that are older than 14 days.
	_log_event "[ maintenance ] Pruning files in $1 older than $keepUntil days."
	find "$pathBackups/$BACKUP_FOLDER" -mtime +$keepUntil -maxdepth 1 -exec rm -rf {} \;
}

function BackupStructure {
	# Ensure the appropriate directories are in place to generate a log and alert.
	# mkdir -p /usr/local/robotcloud/{bin,data,logs}
	# Ensure the log file is present.
	if [ ! -e "$pathLog" ]; then
		/usr/bin/touch "$pathLog"
	fi
	# Check to see if the destination backup folder was created.
	# If not, default to boot drive.
	backupDestination="$BACKUP_FOLDER/$date"
	if [ `echo "$pathBackups" | grep -c "Volumes"` -gt "0" ]; then
		# Backup destination is on an external disk. Confirm it is mounted.
		nameVolume=$(echo "$pathBackups" | sed -e 's#/Volumes/##g' | sed 's#/.*##')
		if [ `diskutil list | grep -c "$nameVolume"` -gt "0" ]; then
			backupDestination="$pathBackups/$BACKUP_FOLDER/$date"
		fi
	fi
	/bin/mkdir -p "$backupDestination"
}

function CheckOS {
	# Set the serveradmin variable according to operating system.
	if [ "$macOS" -ge "108" ]; then
		if [ "$macOS" -ge "109" ]; then
			SOCKET="/Library/Server/ProfileManager/Config/var/PostgreSQL" 
			WIKISOCKET="/Library/Server/Wiki/PostgresSocket" 
			DATABASE=devicemgr_v2m0 
			WIKIDATABASE=collab 
		else
			SOCKET="/Library/Server/PostgreSQL For Server Services/Socket"
			WIKISOCKET="/Library/Server/PostgreSQL For Server Services/Socket" 
			DATABASE=device_management
			WIKIDATABASE=collab
		fi
		if [ -e /Applications/Server.app/Contents/ServerRoot/usr/sbin/serveradmin ]; then
			serveradmin="/Applications/Server.app/Contents/ServerRoot/usr/sbin/serveradmin"
			SERVERROOT="/Applications/Server.app/Contents/ServerRoot/usr/bin"
			_log_event "[ check ] The serveradmin binary has been found."
		else
			_log_event "[ error ] The serveradmin binary could not be found. Exit Code: $?"
		fi
	elif [ -e /usr/sbin/serveradmin ]; then
		serveradmin="/usr/sbin/serveradmin"
		_log_event "[ check ] The serveradmin binary has been found."
	else
		_log_event "[ error ] The serveradmin binary could not be found. Exit Code: $?"		
	fi
}
 
function OpenDirectoryBackup {
	# Check to see if Open Directory service is running.
	odBackupDestinationStatus=$(sudo $serveradmin status dirserv | grep -c "RUNNING")
	if [ $odBackupDestinationStatus = 1 ]; then
		# Check to see if Open Directory is set to Master.
		odmaster=$(sudo $serveradmin settings dirserv | grep "LDAPServerType" | grep -c "master")
		if [ $odmaster = 1 ]; then
			_log_event "[ check ] Open Directory is running and is set to master."
			# Ensure the backup directory is present and assign the path as a variable.
			/bin/mkdir -p "$backupDestination"/OpenDirectory
			# Instruct the serveradmin binary to create a backup.
			$serveradmin command <<-EOC
				dirserv:backupArchiveParams:archivePassword = $ldapPass
				dirserv:backupArchiveParams:archivePath = ${backupDestination}/OpenDirectory/od_backup-${host}-${date}.sparseimage
				dirserv:command = backupArchive
 
				EOC
			# Check to see if there were any errors backing up Open Directory.
			if [ $? == 0 ]; then
				_log_event "[ backup ] Open Directory successfully backed up."
			else
				_log_event "[ error ] There was an error attempting to back up Open Directory. Exit Code: $?"
			fi
		else
			_log_event "[ check ] Open Directory not set to master. No backup required."
		fi
	else
		_log_event "[ check ] Open Directory is not running. No backup required."
	fi			
}
 
function ServerAdminBackup () {
	# Ensure the backup directory is present and assign the path as a variable.
	/bin/mkdir -p "$backupDestination"/ServerAdmin
	# Create a backup of all services, regardless if they are running or not.
	sudo $serveradmin settings all > "$backupDestination"/ServerAdmin/sa_backup-allservices-$host-$date.backup
	list=$(sudo $serveradmin list)
	for service in $list; do
	 	sudo $serveradmin settings $service > "$backupDestination"/ServerAdmin/sa_backup-$service-$host-$date.backup
		if [ $? == 0 ]; then
			_log_event "[ backup ] $service successfully backed up."
		else
			_log_event "[ error ] Could not back up $service. Exit Code: $?"
		fi
	done
}
 
function ProfileManagerBackup () {
	# Ensure the backup directory is present and assign the path as a variable.
	/bin/mkdir -p "$backupDestination"/ProfileManager
	# Create a backup of profilemanager database.
	sudo -u _devicemgr /Applications/Server.app/Contents/ServerRoot/usr/bin/pg_dump -h /Library/Server/ProfileManager/Config/var/PostgreSQL -U _devicemgr devicemgr_v2m0 -c -f "$backupDestination"/ProfileManager/device_management-$host-$date.sql
	if [ $? == 0 ]; then
		_log_event "[ backup ] ProfileManager successfully backed up."
	else
		_log_event "[ error ] Could not back up ProfileManager. Exit Code: $?"
	fi
}

function BackupMariaDB () {
	start_spinner "Mysql/MariaDB backup ..."
	local destination="$backupDestination/MariaDB"
	/bin/mkdir -p "$destination"
	# # Verify MySQL connection.
	$CMD_MYSQL --defaults-extra-file=${MYSQL_PASSWD_FILE} -e 'SHOW DATABASES' > /dev/null 2>&1
	if [ $? != 0 ]; then
		_log_msg "[ error ] MySQL username or password is incorrect. Exit Code: $?."
	fi
	# # Backup.
	DATABASES="$(${CMD_MYSQL} --defaults-extra-file=${MYSQL_PASSWD_FILE} -Bse 'SHOW DATABASES')"
	for db in ${DATABASES}; do
		if [ "$db" != "information_schema" ] && [ "$db" != "performance_schema" ] && [ "$db" != "mysql" ]; then
			$CMD_MYSQLDUMP --defaults-extra-file=${MYSQL_PASSWD_FILE} --host=localhost $db  | Compress_File > "$destination/$db-$date.sql.bz2"
			_log_msg "[ success ] Backup complete at $date on mysql database: $db "
		fi
	done
	sleep 2
	stop_spinner $?
	if [ $? == 0 ]; then
		echo "[ success ] All Mysql/MariaDB Databases successfully backed up."
	else
		_log_msg "[ error ] Could not back up Mysql/MariaDB databases. Exit Code: $?"
  fi
}

function BackupPsql () {
	start_spinner "PostgreSQL backup ..."
	local destination="$backupDestination/PostgresDB"
	/bin/mkdir -p "$destination"
	DATABASES=`${CMD_PSQL} -h localhost -U postgres -l -t | cut -d'|' -f1 | sed -e 's/ //g' -e '/^$/d'`
	for i in $DATABASES; do
		if [ "$i" != "template0" ] && [ "$i" != "template1" ]; then
        	$CMD_VACUUMDB -z -U postgres -h localhost $i > /dev/null 2>&1
        	$CMD_PG_DUMP -U postgres -h localhost -C -d $i | Compress_File > "$destination/$i-$date.sql.bz2"
			if [ $? == 0 ]; then
				_log_msg "[ success ] Backup and Vacuum complete at $date on postgres database: $i "
			fi
		fi
	done
	sleep 2
	stop_spinner $?
	if [ $? == 0 ]; then
		echo "[ success ] All Postgres Databases successfully backed up."
	else
		_log_msg "[ error ] Could not back up Postgres databases. Exit Code: $?"
  	fi
}


function BackupFiles () {
	local destination="$backupDestination/Files"
	/bin/mkdir -p "$destination"
	for _FOLDER in "${MULTIFOLDER[@]}"; do
		start_spinner "Folder '$_FOLDER' backup ..."
		# tar -cjvf "$destination"/$(basename $_FOLDER)_$(date +%Y%m%d).tar.bz2 "$_FOLDER"
		#if [ -e "$(which pv)" ]; then
		#	tar -cPf - "$_FOLDER" | pv -s $(($(du -sk "$_FOLDER" | awk '{print $1}') * 1024)) | Compress_File > "$destination"/$(basename $_FOLDER)_$(date +%Y%m%d).tar.bz2
		#else
			tar -cjPf "$destination"/$(basename $_FOLDER)_$(date +%Y%m%d).tar.bz2 "$_FOLDER"
		#fi
		#rsync -axv "$WWW_FOLDER" "$destination"/WebFiles/

		sleep 2
		stop_spinner $?
		
		if [ $? == 0 ]; then
			_log_event "[ success ] Backup files from '$_FOLDER'."
		else
			_log_msg "[ error ] Could not back up Files from '$_FOLDER'. Exit Code: $?"
		fi
	done
	chown -R root:admin "$destination"
	chmod -R 770 "$destination"
}

unset BACKUP_FOLDER MYSQL POSTGRES MULTIFOLDER serveradmin

while getopts 'mpb:f:?h' opt; do
  case $opt in
		m) set_variable MYSQL SAVE;;
		p) set_variable POSTGRES SAVE;;
		b) set_variable BACKUP_FOLDER $OPTARG;;
		f) MULTIFOLDER+=("$OPTARG");;
		h|?) usage ;;
	esac
done
shift $((OPTIND -1))

[ -z "$BACKUP_FOLDER" ] && usage

if [ -n "$BACKUP_FOLDER" ]; then
	BackupStructure
	echo "===========================[ $0 is starting... ]==========================="
	CheckOS
	if [ -n "$serveradmin" ]; then
		OpenDirectoryBackup
		ServerAdminBackup
		if [ `"$serveradmin" status devicemgr | grep -c "RUNNING"` = "1" ]; then
			ProfileManagerBackup
		fi
	fi
	if [ -n "$MYSQL" ]; then
		BackupMariaDB
	fi
	if [ -n "$POSTGRES" ]; then
		BackupPsql
	fi
	if [ -n "$MULTIFOLDER" ]; then
		BackupFiles
	fi
	RemoveOldBackups
	echo "==========================[ $0 has completed ]=========================="
fi