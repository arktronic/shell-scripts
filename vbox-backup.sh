#!/bin/bash

### ABOUT
# This script performs backups of VirtualBox VMs. It should be run from cron as a user with appropriate access.

###

show_help() {
echo Usage: ${0##*/} path/to/destination max_days_to_keep_backups [user_to_mail_report_to]
echo
echo Hint: add \"vbox-backup::off\" to a VM\'s description to skip it.
}

if [[ $# -ne 2 ]] && [[ $# -ne 3 ]]; then
  show_help >&2
  exit 1
fi

[ -d $1 ] || {
  echo "ERROR: $1 is not a valid destination directory." >&2
  exit 1
}

DESTINATION=$1
BACKUP_DAYS=$2
REPORT_MAIL=$3
BACKUP_ID=$(date +%Y%m%d.%H%M%S)
TMP_DIR=/tmp/vbox-backup-tmp

echo "Starting backup $BACKUP_ID" > /tmp/vbox-backup.log

log() {
  echo $(echo $* | tr -d '\r' | tr -d '\n') >> /tmp/vbox-backup.log
}

geterr() {
  cat /tmp/vbox-backup.err | tr -d '\r' | tr '\n' ' '
}

process_vm() {
  vmname=$(echo "$1" | cut -d\" -f2)
  vmuuid=$(echo "$1" | grep -o '\{.*\}')
  vmskip=$(VBoxManage showvminfo $vmuuid --machinereadable | grep -c 'vbox-backup::off')
  
  if [[ $vmskip -gt 0 ]]; then
    log "Skipping backup of VM $1"
	return 1
  fi
  
  log "Backing up VM $1:"
  
  snap="backup.$BACKUP_ID"
  log "- Creating snapshot $snap"
  VBoxManage snapshot "$vmuuid" take $snap --live >/dev/null 2>/tmp/vbox-backup.err
  [ $? -eq 0 ] || {
    log "- ERROR: Could not create snapshot: " $(geterr)
	return 2
  }
  
  log "- Cloning to $vmname.bak"
  VBoxManage clonevm $vmuuid --snapshot $snap --options keepallmacs,keepdisknames,keephwuuids --basefolder $TMP_DIR --name "$vmname.bak" >/dev/null 2>/tmp/vbox-backup.err
  [ $? -eq 0 ] || {
    log "- ERROR: Could not clone snapshot: " $(geterr)
	VBoxManage snapshot $vmuuid delete $snap || log "- ERROR: Could not delete snapshot of failed clone"
	return 2
  }
  mv $TMP_DIR/$vmname.bak $DESTINATION/$BACKUP_ID/ >/dev/null 2>/tmp/vbox-backup.err
  [ $? -eq 0 ] || {
    log "- ERROR: Could not move snapshot clone to destination: " $(geterr)
	return 2
  }
  
  log "- Deleting snapshot"
  VBoxManage snapshot $vmuuid delete $snap 2>/tmp/vbox-backup.err
  [ $? -eq 0 ] || {
    log "- ERROR: Could not delete snapshot: " $(geterr)
	return 2
  }
  
  return 0
}

rm -rf $TMP_DIR
mkdir $TMP_DIR || {
  echo "ERROR: Could not create directory $TMP_DIR" >&2
  exit 1
}

mkdir $DESTINATION/$BACKUP_ID || {
  echo "ERROR: Could not create directory $DESTINATION/$BACKUP_ID" >&2
  exit 1
}
log "Destination directory: $DESTINATION/$BACKUP_ID"

allvms=$(VBoxManage list vms)
ok=0
total=0
skip=0
while read line; do
  log ""
  process_vm "$line"
  retval=$?
  [ $retval -eq 0 ] && {
    ((total++))
	((ok++))
  }
  [ $retval -eq 1 ] && ((skip++))
  [ $retval -ne 0 ] && [ $retval -ne 1 ] && ((total++))
done <<< "$(echo -e "$allvms")"

oldbackups=$(find $DESTINATION -mindepth 1 -maxdepth 1 -type d -ctime +$BACKUP_DAYS)
[[ ! -z $oldbackups ]] && {
  log "Deleting backups older than $BACKUP_DAYS days: $oldbackups"
  rm -rf $oldbackups
}

donesecs=$SECONDS
donetime=$(printf '%02dh %02dm %02ds' $(($donesecs / 3600)) $(($donesecs % 3600 / 60)) $(($donesecs % 60)))
log ""
log "Completed in $donetime"

[[ ! -z $REPORT_MAIL ]] && {
  cat /tmp/vbox-backup.log | mail -s "$(uname -n) VM backup report: $ok/$total ok, $skip skipped" $REPORT_MAIL
}
