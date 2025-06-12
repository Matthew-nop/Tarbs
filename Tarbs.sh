#!/bin/sh

cleanup() {
	if [ -f "$PID_PATH" ]; then
		rm "$PID_PATH"
	fi
}

confirmContinue() {
	read continue
	case "$continue" in
	[yY][eE][sS] | [yY])
		return 0
		;;
	[nN][oO] | [nN])
		return 1
		;;
	*)
		echo "Invalid response, please enter y/n or yes/no."
		confirmContinue
		;;
	esac
}

exitIfAlreadyRunning() {
	tarbsPid=$1
	
	if ps -p $tarbsPid >/dev/null; then
		echo "Tarbs is already running with PID: ${tarbsPid}" 1>&2
		# Don't cleanup since files are owned by another process
		exit 1
	fi
}

generateExcludes() {
	base=$1
	excludesListPath=$2
	excludes=""

	if [ -f "$excludesListPath" ]; then
		while read l; do
			excludes="${excludes} --exclude=\"${base}/${l}\""
		done <"$excludesListPath"
	fi

	echo -n "$excludes"
}

generateFilename() {
	target=$1

	filename=$(basename "$target")
	if [ "$filename" = "/" ]; then
		filename="root"
	fi
	filename="$(hostname)_${filename}-${DATE_STRING}.tar.xz"

	echo -n "$filename"
}

tarbsExit() {
	cleanup
	exit $1
}

tarPath() {
	targetPath=$1
	outputPath=$2
	excludes=""

	if [ ! -f "$targetPath" ]; then
		targetExcludesPath="${targetPath}/${EXCLUDES_FILENAME}"
		excludes=$(generateExcludes "$targetPath" "$targetExcludesPath")
	fi

	commandString="tar $TAR_ARGS -cf - $targetPath | pxz $PXZ_ARGS -T0 >$outputPath"
	# Tar the filesystem
	echo "Backing up    : $targetPath -> $outputPath"
	echo "With excludes : $excludes"
	echo "Full command  : \"tar $TAR_ARGS -cf - $targetPath | pxz $PXZ_ARGS >$outputPath\""
	tar $TAR_ARGS -cf - $targetPath | pxz $PXZ_ARGS >$outputPath &
}

tarTargets() {
	targets=$1
	
	while read t; do
		tarPath "$t" "${STORE_PATH}/$(generateFilename "$t")"
	done <"$targets"
}

# =============================================================================================
# TARBS START
# =============================================================================================

set -e

# Filepaths
STORE_PATH="/mnt/Corundum/Backup/Ilmenite"
TARGETS_PATH="/etc/tarbs/targets"
PID_PATH="/etc/tarbs/pid"
LOCKFILE_PATH="/etc/tarbs/lockfile"

# Other consts
COMPRESSION_LEVEL="-7"
DATE_STRING="$(date -u +'%Y-%m-%dT%H-%M')"
TAR_ARGS="-P -p --xattrs-include='*.*' --one-file-system"
PXZ_ARGS="-4 -T8"
EXCLUDES_FILENAME=".tarbs.excludes"

# Escalate with sudo if not root
[ "$UID" -eq 0 ] || exec sudo "$0" "$@"

# Kill process group on exit
trap 'kill -TERM -$( ps -o pgid= $$ | tr -d \ )' EXIT

# To prevent race conditions, use flock to grab a lockfile before writing PID to PID file
(
	flock -x -w 10 9 || exit 1

	# Checks for PID file, and if it exists, checks if tarbs is currently running.
	if [ -f "$PID_PATH" ]; then
		exitIfAlreadyRunning $(cat "$PID_PATH")
		echo "Tarbs previously exited unsuccessfully, please verify file integrity." 1>&2
		echo "Remove previous PID file and run Targs again? (Y/N)" 1>&2
		confirmContinue || exit 1
	fi

	echo $$ >"$PID_PATH"
	sync
) 9>"$LOCKFILE_PATH" || exit 1
# Done with flock, safe to remove the lockfile
rm "$LOCKFILE_PATH"

if [ ! -d "$STORE_PATH" ] && [ ! -L "$STORE_PATH" ]; then
	echo "$STORE_PATH is not a directory symlink" 1>&2
	tarbsExit 1
fi

# Begin backing up targets
if [ -f "$TARGETS_PATH" ]; then
	tarTargets "$TARGETS_PATH"
elif [ -d "$TARGETS_PATH" ] || [ -L "$TARGETS_PATH" ]; then
	for targetsFile in "$TARGETS_PATH"; do
		tarTargets "$TARGETS_PATH"
	done
else
	echo "No targets file exists at ${TARGETS_PATH}"
	tarbsExit 1
fi

wait
tarbsExit 0
