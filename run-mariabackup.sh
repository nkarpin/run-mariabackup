#!/bin/bash

# Create a backup user
# GRANT RELOAD, PROCESS, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'backup'@'localhost' identified by 'YourPassword';
# FLUSH PRIVILEGES;
#
# Usage:
# MYSQL_PASSWORD=YourPassword bash run-mariabackup.sh

# FIXME: check available space for needed database volume (for full and incremental)
set -e
set -x

MARIADB_HOST=${MARIADB_HOST:-localhost}
BACKCMD=mariabackup # Galera Cluster uses mariabackup instead of xtrabackup.
BACKDIR=/var/backup
FULLBACKUPCYCLE=${MARIADB_FULL_BACKUP_CYCLE:-604800} # Create a new full backup every X seconds
MARIADB_BACKUPS_TO_KEEP=${MARIADB_BACKUPS_TO_KEEP:-3} # Number of additional backups cycles a backup should kept for.
MARIADB_BACKUP_TYPE=${MARIADB_BACKUP_TYPE:-full}
LOCKDIR=/var/backup/mariabackup.lock

# Prints line number and "message" in error format
# err $LINENO "message"
function err {
    local exitcode=$?
    local xtrace
    xtrace=$(set +o | grep xtrace)
    set +o xtrace
    local msg="[ERROR] ${BASH_SOURCE[2]}:$1 $2"
    echo "$msg" 1>&2;
    if [[ -n ${LOGDIR} ]]; then
        echo "$msg" >> "${LOGDIR}/error.log"
    fi
    $xtrace
    return $exitcode
}

# Prints backtrace info
# filename:lineno:function
# backtrace level
function backtrace {
    local level=$1
    local deep
    deep=$((${#BASH_SOURCE[@]} - 1))
    echo "[Call Trace]"
    while [ $level -le $deep ]; do
        echo "${BASH_SOURCE[$deep]}:${BASH_LINENO[$deep-1]}:${FUNCNAME[$deep-1]}"
        deep=$((deep - 1))
    done
}

# Prints line number and "message" then exits
# die $LINENO "message"
function die {
    local exitcode=$?
    set +o xtrace
    local line=$1; shift
    if [ $exitcode == 0 ]; then
        exitcode=1
    fi
    backtrace 2
    err $line "$*"
    # Give buffers a second to flush
    sleep 1
    exit $exitcode
}

USEROPTIONS="--defaults-file=/etc/mysql/admin_user.cnf --host=${MARIADB_HOST}"
ARGS=""
BASEBACKDIR=$BACKDIR/base
INCRBACKDIR=$BACKDIR/incr
START=`date +%s`

echo "----------------------------"
echo
echo "run-mariabackup.sh: MySQL backup script"
echo "started: `date`"
echo

if [ -z "`mysqladmin $USEROPTIONS status | grep 'Uptime'`" ]; then
  die $LINENO "FATAL ERROR: MySQL does not appear to be running."
fi
mysql $USEROPTIONS -s -e 'exit' || die $LINENO "FATAL ERROR: Could not connect to mysql with provided credentials"

mkdir $LOCKDIR || die $LINENO "Could not create lock directory ${LOCKDIR}"

echo "Lock directory created. Check completed."

mkdir -p $BASEBACKDIR
# Find latest backup directory
LATEST=`find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1`
AGE=`stat -c %Y $BASEBACKDIR/$LATEST`

if [ "$MARIADB_BACKUP_TYPE" = "incremental" -a "$LATEST" -a `expr $AGE + $FULLBACKUPCYCLE + 5` -ge $START ]; then
    echo 'New incremental backup'
    LATESTINCR=`find $INCRBACKDIR/$LATEST -mindepth 1  -maxdepth 1 -type d | sort -nr | head -1`
    if [ ! $LATESTINCR ]; then
        # This is the first incremental backup
        INCRBASEDIR=$BASEBACKDIR/$LATEST
    else
        # This is a 2+ incremental backup
        INCRBASEDIR=$LATESTINCR
    fi

    TARGETDIR=$INCRBACKDIR/$LATEST/`date +%F_%H-%M-%S`
    # Set incremental Backup options
    BACKUP_OPTIONS="$USEROPTIONS --backup $ARGS --extra-lsndir=$TARGETDIR --incremental-basedir=$INCRBASEDIR --stream=xbstream"
else
    echo 'New full backup'
    TARGETDIR=$BASEBACKDIR/`date +%F_%H-%M-%S`
    # Set full backup options
    BACKUP_OPTIONS="$USEROPTIONS --backup $ARGS --extra-lsndir=$TARGETDIR --stream=xbstream"
fi

mkdir -p $TARGETDIR

set -o pipefail
$BACKCMD $BACKUP_OPTIONS | gzip > $TARGETDIR/backup.stream.gz
set +o pipefail

MINS=$(($FULLBACKUPCYCLE * ($KEEP + 1 ) / 60))
echo "Cleaning up old backups (older than $MINS minutes) and temporary files"

# Delete old backups
for DEL in `find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -mmin +$MINS -printf "%P\n"`; do
    echo "deleting $DEL"
    rm -rf $BASEBACKDIR/$DEL
    rm -rf $INCRBACKDIR/$DEL
done

SPENT=$((`date +%s` - $START))
echo "Took $SPENT seconds. Completed: $(date)"
echo "Backup directories tree:"
echo "$(ls -R ${BACKDIR} | grep ':$' | sed -e 's/:$//' -e 's/[^-][^\/]*\//--/g' -e 's/^/   /' -e 's/-/|/')"
if rmdir $LOCKDIR; then
    echo "Lock directory removed"
else
    die $LINENO "Unable to remove lock directory ${LOCKDIR}"
fi
