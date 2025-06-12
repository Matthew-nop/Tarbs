#!/bin/bash

usage() {
	cat <<EOF >&2
Usage: $(basename "$0") [-f] [-p /home] [-l /etc/tarbs/targets] -o /mnt/backup/
  -f        Continue even if the last session exited unexpectedly
  -h        Display this help output
  -l        Path to list of paths to tar (/etc/tarbs/targets)
  -o        Output directory path for tar
  -p        Path to tar (/home)
  -u        Run Tarbs with user permissions
EOF
	exit 0
}

confirmContinue() {
	read -r continue
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

	if ps -p "$tarbsPid" >/dev/null; then
		echo "Tarbs is already running with PID: ${tarbsPid}" 1>&2
		# Don't cleanup since files are owned by another process
		exit 1
	fi
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
	if [ -f "$PID_PATH" ]; then
		rm "$PID_PATH"
	fi

	exit "$1"
}

# =============================================================================================
# TARBS START
# =============================================================================================

# Compression settings
DEFAULT_TAR_ARGS=("-p" "--xattrs-include='*.*'" "--one-file-system")
DEFAULT_PXZ_ARGS=()

# Other settings
DATE_STRING="$(date -u +'%Y-%m-%dT%H-%M')"
EXCLUDES_FILENAME=".tarbs.excludes"
PID_PATH="/etc/tarbs/pid"
LOCKFILE_PATH="/etc/tarbs/lockfile"

# User input
dontPromptForCleanup=false
userPermissions=false
targetPath=""
targetsPath=""
outputDirPath=""

set -e

while getopts "fhp:l:o:u" flag; do
	case $flag in
	f)
		dontPromptForCleanup=true
		;;
	h)
		usage
		;;
	o)
		outputDirPath=$OPTARG
		;;
	p)
		targetPath=$OPTARG
		;;
	l)
		targetsPath=$OPTARG
		;;
	u)
		userPermissions=true
		;;
	\?)
		exit 1
		;;
	esac
done

if [[ -z "$targetPath" && -z "$targetsPath" ]]; then
	echo "A target or list of targets must be specified" 1>&2
	exit 1
elif [[ -z $outputDirPath ]]; then
	echo "An output path must be specified" 1>&2
	exit 1
fi

# If '-u' isn't set and not root, escalate with sudo
$userPermissions || [ "$UID" -eq 0 ] || exec sudo "$0" "$@"

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
		$dontPromptForCleanup || confirmContinue || exit 1
	fi

	echo $$ >"$PID_PATH"
	echo "Syncing..."
	sync
) 9>"$LOCKFILE_PATH" || exit 1
# Done with flock, safe to remove the lockfile
rm "$LOCKFILE_PATH"

if [ ! -d "$outputDirPath" ] && [ ! -L "$outputDirPath" ]; then
	echo "$outputDirPath is not a directory or symlink" 1>&2
	tarbsExit 1
fi

targets=()

# Populate targets array
if [[ -n "$targetPath" ]]; then
	targets+=("$targetPath")
fi
if [[ -n "$targetsPath" ]]; then
	while read -r t; do
		targets+=("$t")
	done <"$targetsPath"
fi

# Tar targets
umask 0077
for target in "${targets[@]}"; do
	excludes=()
	outputPath="${outputDirPath}/$(generateFilename ${target})"

	echo "Backing up    : $target -> $outputPath"
	echo "Tar args      : ${DEFAULT_TAR_ARGS[*]}"
	echo "pxz args      : ${DEFAULT_PXZ_ARGS[*]}"
	if [ -f "$target" ]; then
		echo "Full command  : \"tar ${DEFAULT_TAR_ARGS[*]} -cf - $target | pxz ${DEFAULT_PXZ_ARGS[*]} > $outputPath\""
		tar "${DEFAULT_TAR_ARGS[@]}" -cf - "$target" | pxz "${DEFAULT_PXZ_ARGS[@]}" >"$outputPath" &

	elif [[ -d "$target" || (-L "$target" && -e "$target") ]]; then
		pushd "$target" >/dev/null
		if [ -f "$EXCLUDES_FILENAME" ]; then
			while read -r l; do
				excludes+=("--exclude=./${l}")
			done <"$EXCLUDES_FILENAME"
		fi

		echo "PWD           : ${PWD}"
		echo "Excludes      : ${excludes[*]}"
		echo "Full command  : \"tar ${DEFAULT_TAR_ARGS[*]} ${excludes[*]} -cf - . | pxz ${DEFAULT_PXZ_ARGS[*]} > $outputPath\""
		tar "${excludes[@]}" "${DEFAULT_TAR_ARGS[@]}" -cf - . | pxz "${DEFAULT_PXZ_ARGS[@]}" >"$outputPath" &
		popd >/dev/null
	fi
	echo ""
done

wait
echo $'===============================\nTarbs finished with all targets\n==============================='
tarbsExit 0