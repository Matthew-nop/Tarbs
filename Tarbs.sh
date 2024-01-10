#!/bin/sh

usage() {
	cat <<EOF >&2
Usage: $(basename "$0") [-f] -p /home -o /mnt/backup/
  -f        Continue even if the last session exited unexpectedly
  -h        Display this help output
  -l        Path to list of paths to tar (/etc/tarbs/targets)
  -o        Output directory path for tar
  -p        Path to tar (/home)
EOF
	exit 0
}

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
	outputPath="${2}/$(generateFilename ${targetPath})"
	tarOptions=$3
	pxzOptions=$4
	excludes=""

	if [ ! -f "$targetPath" ]; then
		targetExcludesPath="${targetPath}/${EXCLUDES_FILENAME}"
		excludes=$(generateExcludes "$targetPath" "$targetExcludesPath")
	fi

	# Tar the filesystem
	echo "Backing up    : $targetPath -> $outputPath"
	echo "With excludes : $excludes"
	echo "Full command  : \"tar $tarOptions -cf - $targetPath | pxz $pxzOptions >$outputPath\""
	tar $tarOptions -cf - $targetPath | pxz $pxzOptions >$outputPath &
}

tarTargets() {
	targetsPath=$1
	outputPath=$2
	tarOptions=$3
	pxzOptions=$4

	while read t; do
		tarPath \
			"$t" \
			"$outputPath" \
			"$tarOptions" \
			"$pxzOptions"
	done <"$targetsPath"
}

# =============================================================================================
# TARBS START
# =============================================================================================

set -e

# Compression settings
DEFAULT_TAR_ARGS="-P -p --xattrs-include='*.*' --one-file-system"
DEFAULT_PXZ_ARGS="-5 -T8"

# Other settings
DATE_STRING="$(date -u +'%Y-%m-%dT%H-%M')"
EXCLUDES_FILENAME=".tarbs.excludes"
PID_PATH="/etc/tarbs/pid"
LOCKFILE_PATH="/etc/tarbs/lockfile"

# User input
dontPromptForCleanup=false
targetPath=""
targetsPath=""
outputPath=""
while getopts "fhp:l:o:" flag; do
	case $flag in
	f) # Save to clipboard
		dontPromptForCleanup=true
		;;
	h) # Display script help information
		usage
		;;
	o) # Delete last output
		outputPath=$OPTARG
		;;
	p) # Path to target with tar
		targetPath=$OPTARG
		;;
	l) # Path to a list of paths to target with tar
		targetsPath=$OPTARG
		;;
	\?) # Handle invalid options
		exit 1
		;;
	esac
done

if [[ -z "$targetPath" && -z "$targetsPath" ]]; then
	echo "No target or list of targets was specified" >&2
	exit 1
elif [[ ! -z "$targetPath" && ! -z "$targetsPath" ]]; then
	echo "Only a target or list of targets can be specified" >&2
	exit 1
elif [[ -z $outputPath ]]; then
	echo "No output path was specified" >&2
	exit 1
fi

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
		echo "Remove previous PID file and run Tarbs again? (Y/N)" 1>&2
		confirmContinue || exit 1
	fi

	echo $$ >"$PID_PATH"
	sync
) 9>"$LOCKFILE_PATH" || exit 1
# Done with flock, safe to remove the lockfile
rm "$LOCKFILE_PATH"

if [ ! -d "$outputPath" ] && [ ! -L "$outputPath" ]; then
	echo "$outputPath is not a directory or symlink" 1>&2
	tarbsExit 1
fi

# Begin backing up targets
if [[ ! -z "$targetPath" ]]; then
	tarPath \
		"$targetPath" \
		"$outputPath" \
		"$DEFAULT_TAR_ARGS" \
		"$DEFAULT_PXZ_ARGS"
elif [[ ! -z "$targetsPath" ]]; then
	tarTargets \
		"$targetsPath" \
		"$outputPath" \
		"$DEFAULT_TAR_ARGS" \
		"$DEFAULT_PXZ_ARGS"
fi

wait
tarbsExit 0
