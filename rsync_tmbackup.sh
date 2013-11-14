#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Log functions
# -----------------------------------------------------------------------------

fn_log_info() {
	echo "rsync_tmbackup: $1"
}

fn_log_warn() {
	echo "rsync_tmbackup: [WARNING] $1"
}

fn_log_error() {
	echo "rsync_tmbackup: [ERROR] $1"
}

# -----------------------------------------------------------------------------
# Make sure everything really stops when CTRL+C is pressed
# -----------------------------------------------------------------------------

fn_terminate_script() {
	echo "rsync_tmbackup: SIGINT caught."
	exit 1
}

trap 'fn_terminate_script' SIGINT

# -----------------------------------------------------------------------------
# Source and destination information
# -----------------------------------------------------------------------------

SRC_FOLDER=${1%/}
DEST_FOLDER=${2%/}
INCLUSION_FILE=$3
EXCLUSION_FILE=$4

for arg in "$SRC_FOLDER" "$DEST_FOLDER" "$INCLUSION_FILE" "$EXCLUSION_FILE"; do
	if [[ "$arg" == *"'"* ]]; then
		fn_log_error 'Arguments may not have any single quote characters.'
		exit 1
	fi
done

# -----------------------------------------------------------------------------
# Check that the destination drive is a backup drive
# -----------------------------------------------------------------------------

# TODO: check that the destination supports hard links

fn_backup_marker_path() {
	echo "$1/backup.marker"
}

fn_is_backup_destination() {
	DEST_MARKER_FILE="$(fn_backup_marker_path $1)"
	if [ -f "$DEST_MARKER_FILE" ]; then
		echo "1"
	else
		echo "0"
	fi
}

if [ "$(fn_is_backup_destination $DEST_FOLDER)" != "1" ]; then
	fn_log_info "Safety check failed - the destination does not appear to be a backup folder or drive (marker file not found)."
	fn_log_info "If it is indeed a backup folder, you may add the marker file by running the following command:"
	fn_log_info ""
	fn_log_info "touch \"$(fn_backup_marker_path $DEST_FOLDER)\""
	fn_log_info ""
	exit 1
fi

# -----------------------------------------------------------------------------
# Setup additional variables
# -----------------------------------------------------------------------------

BACKUP_FOLDER_PATTERN=????-??-??-??????
NOW=$(date +"%Y-%m-%d-%H%M%S")
PROFILE_FOLDER="$HOME/.rsync_tmbackup"
LOG_FILE="$PROFILE_FOLDER/$NOW.log"
DEST=$DEST_FOLDER/$NOW
PREVIOUS_DEST=$(find "$DEST_FOLDER" -type d -name "$BACKUP_FOLDER_PATTERN" -prune | sort | tail -n 1)
INPROGRESS_FILE=$DEST_FOLDER/backup.inprogress

# -----------------------------------------------------------------------------
# Create profile folder if it doesn't exist
# -----------------------------------------------------------------------------

if [ ! -d "$PROFILE_FOLDER" ]; then
	fn_log_info "Creating profile folder in '$PROFILE_FOLDER'..."
	mkdir -- "$PROFILE_FOLDER"
fi

# -----------------------------------------------------------------------------
# Handle case where a previous backup failed or was interrupted.
# -----------------------------------------------------------------------------

if [ -f "$INPROGRESS_FILE" ]; then
	if [ "$PREVIOUS_DEST" != "" ]; then
		# - Last backup is moved to current backup folder so that it can be resumed.
		# - 2nd to last backup becomes last backup.
		fn_log_info "$INPROGRESS_FILE already exists - the previous backup failed or was interrupted. Backup will resume from there."
		LINE_COUNT=$(find "$DEST_FOLDER" -type d -name "$BACKUP_FOLDER_PATTERN" -prune | sort | tail -n 2 | wc -l)
		mv -- "$PREVIOUS_DEST" "$DEST"
		if [ "$LINE_COUNT" -gt 1 ]; then
			PREVIOUS_PREVIOUS_DEST=$(find "$DEST_FOLDER" -type d -name "$BACKUP_FOLDER_PATTERN" -prune | sort | tail -n 2 | head -n 1)
			PREVIOUS_DEST=$PREVIOUS_PREVIOUS_DEST
		else
			PREVIOUS_DEST=""
		fi
	fi
fi

# Run in a loop to handle the "No space left on device" logic.
while [ "1" ]; do

	# -----------------------------------------------------------------------------
	# Check if we are doing an incremental backup (if previous backup exists) or not
	# -----------------------------------------------------------------------------

	LINK_DEST_OPTION=""
	if [ "$PREVIOUS_DEST" == "" ]; then
		fn_log_info "No previous backup - creating new one."
	else
		# If the path is relative, it needs to be relative to the destination. To keep
		# it simple, just use an absolute path. See http://serverfault.com/a/210058/118679
		PREVIOUS_DEST=`cd \`dirname -- "$PREVIOUS_DEST"\`; pwd`"/"`basename -- "$PREVIOUS_DEST"`
		fn_log_info "Previous backup found - doing incremental backup from $PREVIOUS_DEST"
		LINK_DEST_OPTION="--link-dest=$PREVIOUS_DEST"
	fi

	# -----------------------------------------------------------------------------
	# Create destination folder if it doesn't already exists
	# -----------------------------------------------------------------------------

	if [ ! -d "$DEST" ]; then
		fn_log_info "Creating destination $DEST"
		mkdir -p -- "$DEST"
	fi

	# -----------------------------------------------------------------------------
	# Start backup
	# -----------------------------------------------------------------------------

	LOG_FILE="$PROFILE_FOLDER/$(date +"%Y-%m-%d-%H%M%S").log"

	fn_log_info "Starting backup..."
	fn_log_info "From: $SRC_FOLDER"
	fn_log_info "To:   $DEST"

	CMD="rsync"
	CMD="$CMD --compress"
	CMD="$CMD --numeric-ids"
	CMD="$CMD --links"
	CMD="$CMD --hard-links"
	CMD="$CMD --delete"
	CMD="$CMD --delete-excluded"
	CMD="$CMD --archive"
	CMD="$CMD --itemize-changes"
	CMD="$CMD --verbose"
	CMD="$CMD --log-file '$LOG_FILE'"
	if [ "$INCLUSION_FILE" != "" ]; then
		# We've already checked that $INCLUSION_FILE doesn't contain a single quote
		CMD="$CMD --include-from '$INCLUSION_FILE'"
	fi
	if [ "$EXCLUSION_FILE" != "" ]; then
		# We've already checked that $EXCLUSION_FILE doesn't contain a single quote
		CMD="$CMD --exclude-from '$EXCLUSION_FILE'"
	fi
	CMD="$CMD $LINK_DEST_OPTION"
	CMD="$CMD -- '$SRC_FOLDER/' '$DEST/'"
	CMD="$CMD | grep -E '^deleting|[^/]$'"

	fn_log_info "Running command:"
	fn_log_info "$CMD"

	touch -- "$INPROGRESS_FILE"
	eval nice -n19 ionice -c3 nocache $CMD
	RSYNC_EXIT_CODE=$?

	# -----------------------------------------------------------------------------
	# Check if we ran out of space
	# -----------------------------------------------------------------------------

	# TODO: find better way to check for out of space condition without parsing log.
	grep --quiet "No space left on device (28)" "$LOG_FILE"
	NO_SPACE_LEFT="$?"
	if [ "$NO_SPACE_LEFT" != "0" ]; then
		# This error might also happen if there is no space left
		grep --quiet "Result too large (34)" "$LOG_FILE"
		NO_SPACE_LEFT="$?"
	fi
		
	rm -- "$LOG_FILE"
	
	if [ "$NO_SPACE_LEFT" == "0" ]; then
		# TODO: -y flag
		read -p "It looks like there is no space left on the destination. Delete old backup? (Y/n) " yn
		case $yn in
			[Nn]* ) exit 0;;
		esac

		fn_log_warn "No space left on device - removing oldest backup and resuming."
		
		BACKUP_FOLDER_COUNT=$(find "$DEST_FOLDER" -type d -name "$BACKUP_FOLDER_PATTERN" -prune | wc -l)
		if [ "$BACKUP_FOLDER_COUNT" -lt "2" ]; then
			fn_log_error "No space left on device, and no old backup to delete."
			exit 1
		fi
				
		OLD_BACKUP_PATH=$(find "$DEST_FOLDER" -type d -name "$BACKUP_FOLDER_PATTERN" -prune | head -n 1)
		if [ "$OLD_BACKUP_PATH" == "" ]; then
			fn_log_error "No space left on device, and cannot get path to oldest backup to delete."
			exit 1
		fi
				
		# Double-check that we're on a backup destination to be completely sure we're deleting the right folder
		OLD_BACKUP_PARENT_PATH=$(dirname -- "$OLD_BACKUP_PATH")
		if [ "$(fn_is_backup_destination $OLD_BACKUP_PARENT_PATH)" != "1" ]; then
			fn_log_error "'$OLD_BACKUP_PATH' is not on a backup destination - aborting."
			exit 1
		fi
		
		fn_log_info "Deleting '$OLD_BACKUP_PATH'..."
		rm -rf -- "$OLD_BACKUP_PATH"
		
		# Resume backup
		continue
	fi

	if [ "$RSYNC_EXIT_CODE" != "0" ]; then
		fn_log_error "Exited with error code $RSYNC_EXIT_CODE"
		exit $RSYNC_EXIT_CODE
	fi

	rm -f $DEST_FOLDER/latest
	ln -sr $DEST $DEST_FOLDER/latest

	rm -- "$INPROGRESS_FILE"
	# TODO: grep for "^rsync error:.*$" in log
	fn_log_info "Backup completed without errors."
	exit 0
done
