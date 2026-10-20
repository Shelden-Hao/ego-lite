#!/bin/sh
#v1.5 2026.06.04 17:16
#v1.6 2026.10.20 Windows support: download and run the official x64 installer

set -eu

# Default package URL and installation paths.
DMG_URL_ARM64="https://cdn.ego.app/setup/macos/arm64/egolite-fHoqgZ74bOEM.dmg"
DMG_URL_X64="https://cdn.ego.app/setup/macos/x64/egolite-fHoqgZ74bOEM.dmg"
EXE_URL_X64="https://cdn.ego.app/setup/windows/x64/egoliteSetup-fHoqgZ74bOEM.exe"
APP_NAME="ego lite"
APP_BUNDLE_NAME="$APP_NAME.app"
APP_PATH="/Applications/$APP_BUNDLE_NAME"
USER_APP_PATH="$HOME/Applications/$APP_BUNDLE_NAME"
EGO_BROWSER_HELPER_NAME="ego-browser"
EXE_NAME="egoliteSetup.exe"

# Seconds to wait for the interactive Windows installer to finish.
WINDOWS_INSTALL_TIMEOUT=600

# Temporary directories created when mounting the DMG; cleaned up on exit.
TEMP_DIR=""
MOUNT_DIR=""
DMG_ATTACHED=""

log() {
	printf '%s\n' "$*" >&2
}

die() {
	log "error: $*"
	exit 1
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

select_dmg_url() {
	if [ "$(uname -m)" = "arm64" ]; then
		printf '%s\n' "$DMG_URL_ARM64"
	else
		printf '%s\n' "$DMG_URL_X64"
	fi
}

run_with_sudo_if_needed() {
	# Try without elevated privileges first; fall back to sudo to avoid unnecessary prompts.
	if "$@"; then
		return 0
	fi

	if [ "$(id -u)" -eq 0 ]; then
		return 1
	fi

	require_command sudo
	sudo "$@"
}

cleanup() {
	# Detach the DMG and remove the temp directory on success, failure, or Ctrl+C.
	if [ "$DMG_ATTACHED" = "1" ]; then
		if ! hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1; then
			log "warning: failed to detach $MOUNT_DIR"
		fi
		DMG_ATTACHED=""
	fi

	if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
		rm -rf "$TEMP_DIR" >/dev/null 2>&1 ||
			log "warning: failed to remove temporary directory: $TEMP_DIR"
	fi
}

strip_quarantine_attributes() {
	app_path="$1"
	run_with_sudo_if_needed xattr -dr com.apple.quarantine "$app_path" \
		>/dev/null 2>&1 || true
}

trap cleanup EXIT HUP INT TERM

find_ego_browser_in_app() {
	app_path="$1"

	[ -d "$app_path/Contents" ] || return 1

	# A Chromium app bundle may contain multiple versions; prefer the one under Current.
	for candidate in "$app_path"/Contents/Frameworks/*.framework/Versions/Current/Helpers/"$EGO_BROWSER_HELPER_NAME"; do
		if [ -x "$candidate" ]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	# ego-browser may live in various locations inside the bundle; search under Contents.
	browser_path=$(
		find "$app_path/Contents" -type f -name "$EGO_BROWSER_HELPER_NAME" 2>/dev/null |
			while IFS= read -r candidate; do
				if [ -x "$candidate" ]; then
					printf '%s\n' "$candidate"
					break
				fi
			done
	)

	if [ -n "$browser_path" ]; then
		printf '%s\n' "$browser_path"
		return 0
	fi

	return 1
}

is_ego_lite_app() {
	app_path="$1"

	# The directory exists and contains a working ego-browser — ego lite is considered installed.
	[ -d "$app_path" ] || return 1
	find_ego_browser_in_app "$app_path" >/dev/null
}

find_ego_lite_app() {
	for app_path in "$APP_PATH" "$USER_APP_PATH"; do
		if is_ego_lite_app "$app_path"; then
			printf '%s\n' "$app_path"
			return 0
		fi
	done

	for apps_dir in "$(dirname "$APP_PATH")" "$(dirname "$USER_APP_PATH")"; do
		[ -d "$apps_dir" ] || continue

		app_path=$(
			find "$apps_dir" -maxdepth 1 -type d -iname "$APP_BUNDLE_NAME" 2>/dev/null |
				while IFS= read -r candidate; do
					if is_ego_lite_app "$candidate"; then
						printf '%s\n' "$candidate"
						break
					fi
				done
		)
		if [ -n "$app_path" ]; then
			printf '%s\n' "$app_path"
			return 0
		fi
	done

	return 1
}

install_ego_lite() {
	require_command curl
	require_command hdiutil

	# Download and mount the DMG in an isolated temp directory to avoid polluting the CWD.
	temp_base_dir=${TMPDIR:-/tmp}
	temp_base_dir=${temp_base_dir%/}
	TEMP_DIR=$(mktemp -d "$temp_base_dir/ego-lite-install.XXXXXX")
	MOUNT_DIR="$TEMP_DIR/mount"
	dmg_path="$TEMP_DIR/egolite.dmg"
	dmg_url=$(select_dmg_url)
	mkdir -p "$MOUNT_DIR"

	log "$APP_NAME is not installed. Downloading $dmg_url ..."
	curl -fL --retry 3 --output "$dmg_path" "$dmg_url" ||
		die "failed to download $APP_NAME from $dmg_url"

	log "Mounting installer ..."
	hdiutil attach "$dmg_path" -nobrowse -readonly -mountpoint "$MOUNT_DIR" \
		>/dev/null
	DMG_ATTACHED="1"

	# Handle DMGs that contain the app bundle directly.
	app_in_dmg=$(
		find "$MOUNT_DIR" -maxdepth 2 \
			-type d -iname "$APP_BUNDLE_NAME" |
			head -n 1
	)

	if [ -n "$app_in_dmg" ]; then
		staged_app="$TEMP_DIR/$APP_BUNDLE_NAME"

		log "Installing $APP_NAME to $APP_PATH ..."
		ditto "$app_in_dmg" "$staged_app" ||
			die "failed to stage $APP_NAME from installer"
		find_ego_browser_in_app "$staged_app" >/dev/null ||
			die "installed $APP_NAME does not contain $EGO_BROWSER_HELPER_NAME"

		# Strip quarantine attributes to prevent Gatekeeper from blocking the first launch.
		log "Removing quarantine attributes from $APP_NAME ..."
		xattr -dr com.apple.quarantine "$staged_app" \
			>/dev/null 2>&1 || true

		if [ -d "$APP_PATH" ]; then
			run_with_sudo_if_needed rm -rf "$APP_PATH" ||
				die "failed to replace existing $APP_PATH"
		fi
		run_with_sudo_if_needed mv "$staged_app" "$APP_PATH" ||
			die "failed to move $APP_NAME to $APP_PATH"
		return 0
	fi

	# Fall back to pkg installer if the DMG contains a .pkg instead of an app bundle.
	pkg_in_dmg=$(
		find "$MOUNT_DIR" -maxdepth 2 -type f -name "*.pkg" |
			head -n 1
	)

	if [ -n "$pkg_in_dmg" ]; then
		log "Installing $APP_NAME package ..."
		run_with_sudo_if_needed installer -pkg "$pkg_in_dmg" -target / ||
			die "failed to install $APP_NAME package"
		return 0
	fi

	die "cannot find $APP_NAME app or pkg in mounted DMG"
}

# --- Windows ----------------------------------------------------------------
# Everything below runs under Git Bash, MSYS2, or Cygwin. Paths coming from
# Windows environment variables are converted with cygpath so that `test -d`,
# `find`, and `curl` all see the same filesystem view.

win_to_posix() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -u "$1" 2>/dev/null || printf '%s\n' "$1"
	elif [ -n "$1" ]; then
		printf '%s\n' "$1"
	fi
}

posix_to_win() {
	if command -v cygpath >/dev/null 2>&1; then
		cygpath -w "$1" 2>/dev/null || printf '%s\n' "$1"
	else
		printf '%s\n' "$1"
	fi
}

win_env() {
	# Windows variable names are case-insensitive, but the environment Git Bash
	# exports is not, so try the spellings actually seen in the wild.
	for name in "$@"; do
		value=$(printenv "$name" 2>/dev/null || true)
		if [ -n "$value" ]; then
			printf '%s\n' "$value"
			return 0
		fi
	done

	return 1
}

is_ego_lite_dir() {
	dir="$1"
	[ -n "$dir" ] || return 1
	[ -d "$dir" ] || return 1

	# Chromium ships the helper as an .exe on Windows; fall back to a .cmd shim.
	[ -f "$dir/$EGO_BROWSER_HELPER_NAME.exe" ] ||
		[ -f "$dir/$EGO_BROWSER_HELPER_NAME.cmd" ] ||
		[ -f "$dir/$EGO_BROWSER_HELPER_NAME" ]
}

find_ego_lite_dir() {
	local_app_data=$(win_to_posix "$(win_env LOCALAPPDATA || true)")
	program_files=$(win_to_posix "$(win_env ProgramFiles PROGRAMFILES || true)")
	# The variable name contains parentheses, so ${...} expansion cannot be used.
	program_files_x86=$(win_to_posix "$(win_env 'ProgramFiles(x86)' 'PROGRAMFILES(X86)' || true)")

	# Per-user installs land in LOCALAPPDATA; machine-wide installs in Program Files.
	for dir in \
		"$local_app_data/Programs/$APP_NAME" \
		"$local_app_data/$APP_NAME" \
		"$program_files/$APP_NAME" \
		"$program_files_x86/$APP_NAME"; do
		if is_ego_lite_dir "$dir"; then
			printf '%s\n' "$dir"
			return 0
		fi
	done

	return 1
}

install_ego_lite_windows() {
	require_command curl

	case "$(uname -m)" in
		x86_64 | amd64) ;;
		*)
			die "$APP_NAME ships an x64 installer only. Download the build for this CPU from https://lite.ego.app/"
			;;
	esac

	temp_base_dir=${TMPDIR:-/tmp}
	temp_base_dir=${temp_base_dir%/}
	TEMP_DIR=$(mktemp -d "$temp_base_dir/ego-lite-install.XXXXXX")
	exe_path="$TEMP_DIR/$EXE_NAME"

	log "$APP_NAME is not installed. Downloading $EXE_URL_X64 ..."
	curl -fL --retry 3 --output "$exe_path" "$EXE_URL_X64" ||
		die "failed to download $APP_NAME from $EXE_URL_X64"

	log "Installing $APP_NAME ..."
	# The Windows build installs per user and raises its own UAC prompt, so run the
	# installer instead of unpacking it. It may hand off to an elevated child and
	# return immediately, so wait for the app directory rather than for the process.
	cmd //c start "" "$(posix_to_win "$exe_path")" ||
		die "failed to launch $exe_path"

	waited=0
	while [ "$waited" -lt "$WINDOWS_INSTALL_TIMEOUT" ]; do
		if find_ego_lite_dir >/dev/null; then
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done

	die "$APP_NAME was not installed within ${WINDOWS_INSTALL_TIMEOUT}s; finish the setup wizard and rerun this script"
}

launch_ego_lite() {
	dir="$1"
	exe="$dir/$APP_NAME.exe"

	if [ ! -f "$exe" ]; then
		# Fall back to the first top-level executable that mentions ego.
		exe=$(find "$dir" -maxdepth 1 -type f -iname "*ego*.exe" 2>/dev/null | head -n 1)
	fi

	[ -n "$exe" ] && [ -f "$exe" ] ||
		die "found $dir but not the $APP_NAME executable inside it"

	cmd //c start "" "$(posix_to_win "$exe")" ||
		die "failed to launch $exe"
}

main_macos() {
	# Install first if not present; otherwise use the ego-browser bundled inside the app.
	installed_app_path=$(find_ego_lite_app || true)
	if [ -z "$installed_app_path" ]; then
		install_ego_lite
		installed_app_path=$(find_ego_lite_app || true)
		[ -n "$installed_app_path" ] ||
			die "$APP_NAME install completed, but app was not found"
	fi

	strip_quarantine_attributes "$installed_app_path"
	cleanup

	log "Launching $APP_NAME ..."
	exec open "$installed_app_path"
}

main_windows() {
	installed_app_dir=$(find_ego_lite_dir || true)
	if [ -z "$installed_app_dir" ]; then
		install_ego_lite_windows
		installed_app_dir=$(find_ego_lite_dir || true)
		[ -n "$installed_app_dir" ] ||
			die "$APP_NAME install completed, but the app directory was not found"
	fi

	cleanup

	log "Launching $APP_NAME ..."
	launch_ego_lite "$installed_app_dir"

	log "Complete onboarding in $APP_NAME so it registers the $EGO_BROWSER_HELPER_NAME command on PATH, then open a new terminal: an existing one keeps the PATH it started with."
}

main() {
	case "$(uname -s)" in
		Darwin) main_macos ;;
		MINGW* | MSYS* | CYGWIN*) main_windows ;;
		*)
			die "this script supports macOS and Windows; on other platforms install from https://lite.ego.app/"
			;;
	esac
}

main
