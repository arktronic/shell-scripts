#!/bin/bash
set -e

# This script performs backups of QEMU-KVM virtual machines using `virsh`.
# It is heavily inspired by https://gist.github.com/cabal95/e36c06e716d3328b512b and similar efforts.
# A recent version of `virsh` is required.
# If qcow2 disk image shrinking is enabled, `qemu-img` is required.
# If emailing the log, a properly configured mail user agent and functional `mail` executable are required.

# To skip a VM, add "skip-kvm-backup" to its name, title, or description (anywhere in the XML).

### CONFIGURATION ###

# The backup destination directory:
BACKUP_ROOT=/mnt/kvm-backups/$(uname -n)
# Maximum number of days to keep backups - set to 0 to disable removal of old backups:
KEEP_BACKUPS_MAX_DAYS=7
# Set this to a username or email address to send the backup log via email:
EMAIL_LOG_TO="root"
# Set to 1 to enable standard out logging in addition to the log file:
OUTPUT_TO_STDOUT=1
# Set to 1 to shrink backed up qcow2 disk images, which takes additional time:
SHRINK_DISK_IMAGES=1

### END CONFIGURATION ###

##########################################################################

DATE=$(date +%Y%m%d.%H%M%S)
BACKUP_DIR="$BACKUP_ROOT/$DATE"
LOG="$BACKUP_DIR/log.txt"

mkdir -p "$BACKUP_DIR"

process_all_vms () {
  do_log "Starting backup."
  ALL_VMS=$(virsh list --all --uuid)
  INACTIVE_VMS=$(virsh list --inactive --uuid)
  TOTAL_VM_COUNT=0
  COMPLETED_VM_COUNT=0
  SKIPPED_VM_COUNT=0
  for VM in $ALL_VMS; do
    ((TOTAL_VM_COUNT=TOTAL_VM_COUNT+1))
    $(virsh dumpxml $VM | grep skip-kvm-backup >/dev/null) && {
      ((SKIPPED_VM_COUNT=SKIPPED_VM_COUNT+1))
      do_log "Skipping backup of VM '$VM'."
      continue
    }
    $(echo $INACTIVE_VMS | grep $VM >/dev/null) && VM_ACTIVE=0 || VM_ACTIVE=1
    back_up_vm $VM $VM_ACTIVE && ((COMPLETED_VM_COUNT=COMPLETED_VM_COUNT+1)) || do_log "Backup of VM '$VM' failed"
  done
  do_log "Backup finished: $COMPLETED_VM_COUNT/$TOTAL_VM_COUNT backed up, $SKIPPED_VM_COUNT skipped."
}

back_up_vm () {
  RESULT=0
  VM="$1"
  VM_ACTIVE="$2"
  VM_NAME=$(virsh dominfo $VM | grep "^Name" | awk '{print $2}')
  VM_DIR="$BACKUP_DIR/$VM_NAME"
  mkdir -p "$VM_DIR"
  do_log "Backing up XML for VM '$VM_NAME'..."
  virsh dumpxml $VM > $VM_DIR/local.xml || {
    do_log "ERROR: dumpxml failed for VM '$VM_NAME'!"
    return 1
  }
  virsh dumpxml $VM --migratable > $VM_DIR/migratable.xml || {
    do_log "ERROR: dumpxml migratable failed for VM '$VM_NAME'!"
    return 1
  }
  TARGETS=$(virsh domblklist $VM --details | grep disk | awk '{print $3}')
  SOURCES=$(virsh domblklist $VM --details | grep disk | awk '{print $4}')
  echo $SOURCES | grep \.kvm-backup >/dev/null && {
    do_log "ERROR: At least one source for VM '$VM_NAME' appears to be an intermediate backup source - cannot proceed!"
    return 1
  }
  [ $VM_ACTIVE -eq 1 ] && {
    # The VM is active, so a snapshot must be made for backing up
    DISKSPEC=""
    for TARGET in $TARGETS; do
      DISKSPEC="$DISKSPEC --diskspec $TARGET,snapshot=external"
    done
    # Create disk snapshots, renaming the active disks in the process to *.kvm-backup
    do_log "Creating disk snapshot(s) for VM '$VM_NAME'..."
    virsh snapshot-create-as $VM --name kvm-backup-$DATE --no-metadata --atomic --disk-only $DISKSPEC >/dev/null || {
      do_log "ERROR: Failed to create snapshot for VM '$VM_NAME'!"
      return 1
    }
    BACKUP_SOURCES=$(virsh domblklist $VM --details | grep disk | awk '{print $4}')
    # Copy the original disk sources to the backup location
    do_log "Backing up disk snapshot(s) for VM '$VM_NAME'..."
    for SOURCE in $SOURCES; do
      NAME=$(basename $SOURCE)
      cp "$SOURCE" "$VM_DIR/$NAME" || {
        do_log "ERROR: Unable to back up disk '$NAME' for VM '$VM_NAME'"
        RESULT=1
        # Proceed to merge anyway to avoid leaving the VM in a bad state
      }
    done
    # Merge back to the original disk sources
    do_log "Completing backup for VM '$VM_NAME'..."
    for TARGET in $TARGETS; do
      virsh blockcommit $VM $TARGET --active --pivot --wait >/dev/null || {
        do_log "CRITICAL ERROR: Unable to merge changes for target '$TARGET' of VM '$VM_NAME' - data corruption may have occurred!"
        return 1
      }
    done
    # Clean up merged backup disks
    for BACKUP in $BACKUP_SOURCES; do
      rm -f "$BACKUP" || do_log "WARNING: Unable to clean up merged backup changes for VM '$VM_NAME'!"
    done
  } || {
    # The VM is inactive, so its disk images should be safe to copy directly
    do_log "Backing up disk image(s) for inactive VM '$VM_NAME'..."
    for SOURCE in $SOURCES; do
      NAME=$(basename $SOURCE)
      cp "$SOURCE" "$VM_DIR/$NAME" || {
        do_log "ERROR: Unable to back up disk '$NAME' for VM '$VM_NAME'."
        RESULT=1
      }
    done
  }
  [ $SHRINK_DISK_IMAGES -eq 1 ] && {
    do_log "Shrinking qcow2 disk image(s)..."
    for SOURCE in $SOURCES; do
      NAME=$(basename $SOURCE)
      echo $NAME | grep ".qcow2$" >/dev/null && {
        qemu-img convert -O qcow2 "$VM_DIR/$NAME" "$VM_DIR/$NAME.shrunk" \
        && rm -f "$VM_DIR/$NAME" \
        && mv "$VM_DIR/$NAME.shrunk" "$VM_DIR/$NAME" \
        || {
          do_log "ERROR: Unable to shrink disk '$NAME' for VM '$VM_NAME'. The backup may be in an invalid state."
          RESULT=1
        }
      }
    done
  }
  write_restore_scripts "$VM_NAME" "$VM_DIR" "$SOURCES"
  [ $RESULT -eq 0 ] && do_log "Backup of VM '$VM_NAME' done."
  return $RESULT
}

write_restore_scripts () {
  VM_NAME="$1"
  VM_DIR="$2"
  SOURCES="$3"
  CP_COMMANDS="echo \"Copying disk image(s)...\""
  for SOURCE in $SOURCES; do
    NAME=$(basename $SOURCE)
    IMAGE_DIR=$(dirname $SOURCE)
    CP_COMMANDS="$CP_COMMANDS; cp -n \"$NAME\" \"$IMAGE_DIR\""
  done
  cat << EOF > "$VM_DIR/restore-local.sh"
#!/bin/bash
set -e
cd \$(dirname "\${BASH_SOURCE[0]}")
echo Restoring VM '$VM_NAME'...
virsh define local.xml
$CP_COMMANDS
echo Done!
EOF
  cat << EOF > "$VM_DIR/restore-migratable.sh"
#!/bin/bash
set -e
cd \$(dirname "\${BASH_SOURCE[0]}")
echo Restoring VM '$VM_NAME'...
virsh define migratable.xml
$CP_COMMANDS
echo Done!
EOF
  chmod +x "$VM_DIR/restore-local.sh" "$VM_DIR/restore-migratable.sh"
}

delete_old_backups () {
  # Do not delete old backups if max days is less than 1:
  [ $KEEP_BACKUPS_MAX_DAYS -lt 1 ] && return 0

  BACKUPS_TO_DELETE=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -ctime +$KEEP_BACKUPS_MAX_DAYS)
  [ -z "$BACKUPS_TO_DELETE" ] || {
    BACKUPS_TO_DELETE_ONELINE=$(echo "$BACKUPS_TO_DELETE" | tr '\n' ' ')
    do_log "Deleting backups older than $KEEP_BACKUPS_MAX_DAYS day(s): $BACKUPS_TO_DELETE_ONELINE"
    rm -rf $BACKUPS_TO_DELETE
  }
}

email_log () {
  [ -z "$EMAIL_LOG_TO" ] || {
    cat "$LOG" | mail -s "kvm-backup on $(uname -n): $COMPLETED_VM_COUNT/$TOTAL_VM_COUNT completed, $SKIPPED_VM_COUNT skipped" "$EMAIL_LOG_TO"
  }
}

do_log () {
  NOW=$(date +%Y%m%d.%H%M%S)
  echo -e "$NOW\t\t$1" >> "$LOG"
  [ $OUTPUT_TO_STDOUT -eq 1 ] && echo "$1"
}

process_all_vms
delete_old_backups
email_log