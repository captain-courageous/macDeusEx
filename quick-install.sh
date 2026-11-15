#!/bin/bash
# Deus Ex (macOS Apple Silicon / Metal) quick packager, updater & installer.
#
# Downloads the prebuilt native ARM64 engine-only Deus Ex.app, locates your
# legal Deus Ex GOTY (1.112fm) installation (Steam, GOG, standalone folder,
# CrossOver/Whisky bottle, or existing .app), optionally adds Deus Ex: Revision
# (from Steam, GOG, CrossOver/Whisky, Windows installer/zip, or automatic
# download from dx-revision.com), extracts the original game icon, bakes the
# assets into Deus Ex.app/Contents/Resources/GameData, ad-hoc signs the bundle,
# and either updates your existing Deus Ex.app in-place or installs a new copy
# in ~/Downloads.
#
# No original copyrighted game data or icons are hosted or bundled in the
# release archive — all game assets come strictly from your own local copy or
# official mod distribution mirrors.
#
# Usage:
#   quick-install.sh [--dmg] [-g|--game <path>] [-r|--revision <path|auto>]
#                    [--with-revision] [--update-revision] [--vanilla]
#                    [--local <tarball_or_app>] [game_files_dir]
set -euo pipefail

REPO="${DEUS_EX_MAC_REPO:-captain-courageous/macDeusEx}"
BRANCH="${DEUS_EX_MAC_BRANCH:-main}"
RELEASE_TAG="${DEUS_EX_RELEASE_TAG:-latest}"
if [ "$RELEASE_TAG" = "latest" ]; then
	RELEASE_BASE="https://github.com/$REPO/releases/latest/download"
else
	RELEASE_BASE="https://github.com/$REPO/releases/download/$RELEASE_TAG"
fi
RELEASE_URL="${DEUS_EX_RELEASE_URL:-$RELEASE_BASE/DeusEx-macos-arm64.tar.gz}"
CHECKSUM_URL="${DEUS_EX_CHECKSUM_URL:-$RELEASE_BASE/SHA256SUMS.txt}"

APP_NAME="Deus Ex"
VOLNAME="$APP_NAME"
BUNDLE_ID="local.deusex.native"
DL="$HOME/Downloads"
SUPPORT_DIR="$HOME/Library/Application Support/Deus Ex Native"
TOOLS_DIR="$SUPPORT_DIR/tools"

# ---------------------------------------------------------------------------
# Terminal UI (degrades gracefully to plain "==>" lines when non-interactive).
# ---------------------------------------------------------------------------
FANCY=no
[ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && FANCY=yes || true

if [ "$FANCY" = yes ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 256 ]; then
	G1=$'\033[38;5;220m' G2=$'\033[38;5;214m' G3=$'\033[38;5;178m'
	G4=$'\033[38;5;109m' G5=$'\033[38;5;74m'  G6=$'\033[38;5;39m'
	AMBER=$'\033[38;5;214m' CYAN=$'\033[38;5;45m'
	GREEN=$'\033[38;5;84m' RED=$'\033[38;5;203m'
	BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
elif [ "$FANCY" = yes ]; then
	G1=$'\033[93m' G2=$'\033[93m' G3=$'\033[33m'
	G4=$'\033[36m' G5=$'\033[96m' G6=$'\033[96m'
	AMBER=$'\033[93m' CYAN=$'\033[96m'
	GREEN=$'\033[92m' RED=$'\033[91m'
	BOLD=$'\033[1m' DIM=$'\033[2m' RESET=$'\033[0m'
else
	G1= G2= G3= G4= G5= G6= AMBER= CYAN= GREEN= RED= BOLD= DIM= RESET=
fi

SPIN=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
BAR_WIDTH=24

banner() {
	printf '\n'
	printf '  %s██████╗ ███████╗██╗   ██╗███████╗    ███████╗██╗  ██╗%s\n' "$G1" "$RESET"
	printf '  %s██╔══██╗██╔════╝██║   ██║██╔════╝    ██╔════╝╚██╗██╔╝%s\n' "$G2" "$RESET"
	printf '  %s██║  ██║█████╗  ██║   ██║███████╗    █████╗   ╚███╔╝ %s\n' "$G3" "$RESET"
	printf '  %s██║  ██║██╔══╝  ██║   ██║╚════██║    ██╔══╝   ██╔██╗ %s\n' "$G4" "$RESET"
	printf '  %s██████╔╝███████╗╚██████╔╝███████║    ███████╗██╔╝ ██╗%s\n' "$G5" "$RESET"
	printf '  %s╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝    ╚══════╝╚═╝  ╚═╝%s\n' "$G6" "$RESET"
	printf '\n'
	printf '  %sDeus Ex · Native Metal · Apple Silicon%s\n' "$DIM" "$RESET"
	printf '\n'
}

STEPS_TOTAL=5
STEP=0
step() {
	STEP=$((STEP + 1))
	printf '\n%s◆%s %s[%d/%d]%s %s\n' "$AMBER" "$RESET" "$BOLD" "$STEP" "$STEPS_TOTAL" "$RESET" "$1"
}
ok() { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$AMBER" "$RESET" "$1"; }
die() {
	printf '  %s✘ error:%s %s\n' "$RED" "$RESET" "$1" >&2
	shift
	local line
	for line in "$@"; do printf '    %s\n' "$line" >&2; done
	exit 1
}

can_prompt() {
	[ "${DEUS_EX_NO_PROMPT:-0}" != "1" ] || return 1
	[ "$FANCY" = yes ] && [ -e /dev/tty ] && ( : </dev/tty ) 2>/dev/null
}

ask_tty() {
	local prompt=$1 default=${2:-} reply=""
	if can_prompt; then
		printf '  %s%s%s ' "$BOLD" "$prompt" "$RESET" >/dev/tty
		if ! IFS= read -r reply </dev/tty; then
			reply=""
		fi
	fi
	printf '%s\n' "${reply:-$default}"
}

hsize() {
	awk -v b="${1:-0}" 'BEGIN {
		u[1]="B"; u[2]="KB"; u[3]="MB"; u[4]="GB"; i=1
		while (b >= 1024 && i < 4) { b /= 1024; i++ }
		if (i == 1) printf "%d %s", b, u[i]; else printf "%.1f %s", b, u[i]
	}'
}
file_bytes() { stat -f%z "$1" 2>/dev/null || echo 0; }
du_bytes() {
	local kb
	kb=$(du -skL "$1" 2>/dev/null | awk 'NR==1 {print $1}')
	echo $(( ${kb:-0} * 1024 ))
}

draw_bar() {
	local glyph=$1 label=$2 cur=$3 total=$4
	local pct=0 filled=0 bar='' j=0 tdisp='?'
	if [ "$total" -gt 0 ]; then
		pct=$((cur * 100 / total))
		[ "$pct" -gt 100 ] && pct=100
		tdisp=$(hsize "$total")
	fi
	filled=$((pct * BAR_WIDTH / 100))
	while [ "$j" -lt "$BAR_WIDTH" ]; do
		if [ "$j" -lt "$filled" ]; then bar="${bar}█"; else bar="${bar}░"; fi
		j=$((j + 1))
	done
	printf '\r  %s %s %s%s%s %3d%%  %s%s / %s%s\033[K' \
		"$glyph" "$label" "$AMBER" "$bar" "$RESET" "$pct" \
		"$DIM" "$(hsize "$cur")" "$tdisp" "$RESET"
}

watch_bytes() {
	local pid=$1 label=$2 total=$3
	shift 3
	local i=0 rc=0 cur=0
	printf '\033[?25l'
	while kill -0 "$pid" 2>/dev/null; do
		cur=$("$@" 2>/dev/null || echo 0)
		draw_bar "${CYAN}${SPIN[$((i % 10))]}${RESET}" "$label" "$cur" "$total"
		i=$((i + 1))
		sleep 0.2
	done
	wait "$pid" || rc=$?
	printf '\033[?25h'
	if [ "$rc" -eq 0 ]; then
		if [ "$total" -le 0 ]; then
			total=$("$@" 2>/dev/null || echo 0)
		fi
		draw_bar "${GREEN}✔${RESET}" "$label" "$total" "$total"
		printf '\n'
	else
		printf '\r  %s✘%s %s failed\033[K\n' "$RED" "$RESET" "$label"
	fi
	return "$rc"
}

run_task() {
	local label=$1
	shift
	if [ "$FANCY" = no ]; then
		echo "==> $label"
		"$@"
		return
	fi
	local i=0 rc=0 pid
	"$@" &
	pid=$!
	printf '\033[?25l'
	while kill -0 "$pid" 2>/dev/null; do
		printf '\r  %s%s%s %s\033[K' "$CYAN" "${SPIN[$((i % 10))]}" "$RESET" "$label"
		i=$((i + 1))
		sleep 0.1
	done
	wait "$pid" || rc=$?
	printf '\033[?25h'
	if [ "$rc" -eq 0 ]; then
		printf '\r  %s✔%s %s\033[K\n' "$GREEN" "$RESET" "$label"
	else
		printf '\r  %s✘%s %s failed\033[K\n' "$RED" "$RESET" "$label"
	fi
	return "$rc"
}

usage() {
	cat <<EOF
Usage: $(basename "$0") [options] [game_files_dir]

Options:
  -g, --game <path>      Path to your Deus Ex GOTY folder (Steam, GOG, disc, or .app)
  -r, --revision <path>  Path to Deus Ex: Revision folder or Windows installer (.zip/.exe/.wim),
                         or 'auto' to detect locally / download from dx-revision.com
      --with-revision    Include Deus Ex: Revision (same as --revision auto)
      --update-revision  Force re-downloading/updating Revision mod files
      --vanilla          Install/update Vanilla GOTY only (exclude Revision)
      --no-revision      Alias for --vanilla
      --dmg              Also wrap Deus Ex.app into ~/Downloads/Deus Ex.dmg
      --local <path>     Use a local DeusEx-macos-arm64.tar.gz or engine .app
  -h, --help             Show this help message

When run again on a system with an existing Deus Ex.app (/Applications, ~/Applications,
or ~/Downloads), the existing bundle is updated in-place while keeping your saves, configs,
and installed mod data.

Environment overrides:
  DEUS_EX_MAC_REPO     GitHub owner/repo hosting release assets (default: $REPO)
  DEUS_EX_RELEASE_URL  Direct URL to DeusEx-macos-arm64.tar.gz
  DEUS_EX_REVISION_URL Direct URL to official Revision_*_SteamInstaller.zip
EOF
}

# ---------------------------------------------------------------------------
# Case-insensitive lookup & Deus Ex GOTY / Revision validation.
# ---------------------------------------------------------------------------
find_ci_dir() {
	local parent=$1 target_lower=$2 entry base lower
	[ -d "$parent" ] || return 1
	for entry in "$parent"/*; do
		[ -d "$entry" ] || continue
		base="$(basename "$entry")"
		lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
		if [ "$lower" = "$target_lower" ]; then
			printf '%s\n' "$entry"
			return 0
		fi
	done
	return 1
}

find_ci_file() {
	local parent=$1 target_lower=$2 entry base lower
	[ -d "$parent" ] || return 1
	for entry in "$parent"/*; do
		[ -f "$entry" ] || continue
		base="$(basename "$entry")"
		lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
		if [ "$lower" = "$target_lower" ]; then
			printf '%s\n' "$entry"
			return 0
		fi
	done
	return 1
}

has_ci_ext() {
	local dir=$1 ext_lower=$2 entry lower
	[ -d "$dir" ] || return 1
	for entry in "$dir"/*; do
		[ -f "$entry" ] || continue
		lower="$(printf '%s' "${entry##*.}" | tr '[:upper:]' '[:lower:]')"
		if [ "$lower" = "$ext_lower" ] && [ -s "$entry" ]; then
			return 0
		fi
	done
	return 1
}

validate_game_dir() {
	local root=$1 sys maps tex snd mus
	sys="$(find_ci_dir "$root" "system")" || return 1
	maps="$(find_ci_dir "$root" "maps")" || return 1
	tex="$(find_ci_dir "$root" "textures")" || return 1
	snd="$(find_ci_dir "$root" "sounds")" || return 1
	mus="$(find_ci_dir "$root" "music")" || return 1

	find_ci_file "$sys" "deusex.exe" >/dev/null || return 1
	find_ci_file "$sys" "core.u" >/dev/null || return 1
	find_ci_file "$sys" "engine.u" >/dev/null || return 1
	find_ci_file "$sys" "deusex.u" >/dev/null || return 1
	find_ci_file "$sys" "deusexui.u" >/dev/null || return 1
	find_ci_file "$sys" "default.ini" >/dev/null || return 1
	find_ci_file "$maps" "entry.dx" >/dev/null || return 1
	find_ci_file "$maps" "01_nyc_unatcoisland.dx" >/dev/null || return 1

	has_ci_ext "$tex" "utx" || return 1
	has_ci_ext "$snd" "uax" || return 1
	has_ci_ext "$mus" "umx" || return 1
	return 0
}

validate_revision_dir() {
	local root=$1 sys maps tex mus
	sys="$(find_ci_dir "$root" "system")" || return 1
	maps="$(find_ci_dir "$root" "maps")" || return 1
	tex="$(find_ci_dir "$root" "textures")" || return 1
	mus="$(find_ci_dir "$root" "music")" || return 1

	find_ci_file "$sys" "revision.u" >/dev/null || return 1
	(find_ci_file "$sys" "revision.ini" >/dev/null || find_ci_file "$sys" "revisiondefault.ini" >/dev/null) || return 1
	has_ci_ext "$maps" "dx" || return 1
	has_ci_ext "$tex" "utx" || return 1
	has_ci_ext "$mus" "ogg" || has_ci_ext "$mus" "umx" || return 1
	return 0
}

resolve_game_dir() {
	local base="${1%/}" root dir cand
	for root in "$base" "$base.app"; do
		[ -d "$root" ] || continue
		if [ "$(basename "$root" | tr '[:upper:]' '[:lower:]')" = "system" ]; then
			cand="$(dirname "$root")"
			if validate_game_dir "$cand"; then
				printf '%s\n' "$cand"
				return 0
			fi
		fi
		for dir in \
			"$root" \
			"$root/Contents/Resources/GameData" \
			"$root/Put game files here" \
			"$root/Game Files" \
			"$root/Deus Ex" \
			"$root/Deus Ex GOTY" \
			"$root/drive_c/Program Files/Deus Ex" \
			"$root/drive_c/Program Files (x86)/Deus Ex" \
			"$root/drive_c/GOG Games/Deus Ex GOTY" \
			"$root/drive_c/GOG Games/Deus Ex" \
			"$root/drive_c/Program Files/Steam/steamapps/common/Deus Ex" \
			"$root/drive_c/Program Files (x86)/Steam/steamapps/common/Deus Ex" \
			"$root/drive_c/Program Files/Steam/steamapps/common/Deus Ex GOTY" \
			"$root/drive_c/Program Files (x86)/Steam/steamapps/common/Deus Ex GOTY" \
			"$root/Contents/Resources/drive_c/Program Files/Deus Ex" \
			"$root/Contents/Resources/drive_c/Program Files (x86)/Deus Ex" \
			"$root/Contents/Resources/drive_c/GOG Games/Deus Ex GOTY" \
			"$root/Contents/SharedSupport/prefix/drive_c/Program Files/Deus Ex" \
			"$root/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Deus Ex" \
			"$root/Contents/SharedSupport/prefix/drive_c/GOG Games/Deus Ex GOTY"
		do
			if validate_game_dir "$dir"; then
				printf '%s\n' "$dir"
				return 0
			fi
		done
	done
	return 1
}

resolve_revision_dir() {
	local base="${1%/}" root dir cand sub
	for root in "$base" "$base.app"; do
		[ -d "$root" ] || continue
		if [ "$(basename "$root" | tr '[:upper:]' '[:lower:]')" = "system" ]; then
			cand="$(dirname "$root")"
			if validate_revision_dir "$cand"; then
				printf '%s\n' "$cand"
				return 0
			fi
		fi
		for dir in \
			"$root" \
			"$root/Revision" \
			"$root/Contents/Resources/GameData/Revision" \
			"$root/Put game files here/Revision" \
			"$root/Deus Ex Revision" \
			"$root/Deus Ex Revision/Revision" \
			"$root/Deus Ex/Revision" \
			"$root/Deus Ex GOTY/Revision" \
			"$root/drive_c/GOG Games/Deus Ex Revision" \
			"$root/drive_c/GOG Games/Deus Ex Revision/Revision" \
			"$root/drive_c/GOG Games/Deus Ex GOTY/Revision" \
			"$root/drive_c/GOG Games/Deus Ex/Revision" \
			"$root/drive_c/Program Files/Steam/steamapps/common/Deus Ex Revision" \
			"$root/drive_c/Program Files/Steam/steamapps/common/Deus Ex Revision/Revision" \
			"$root/drive_c/Program Files (x86)/Steam/steamapps/common/Deus Ex Revision" \
			"$root/drive_c/Program Files (x86)/Steam/steamapps/common/Deus Ex Revision/Revision" \
			"$root/drive_c/Program Files/Steam/steamapps/common/Deus Ex/Revision" \
			"$root/drive_c/Program Files (x86)/Steam/steamapps/common/Deus Ex/Revision" \
			"$root/Contents/Resources/drive_c/GOG Games/Deus Ex Revision/Revision" \
			"$root/Contents/Resources/drive_c/GOG Games/Deus Ex GOTY/Revision" \
			"$root/Contents/SharedSupport/prefix/drive_c/GOG Games/Deus Ex Revision/Revision" \
			"$root/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Steam/steamapps/common/Deus Ex Revision/Revision"
		do
			if validate_revision_dir "$dir"; then
				printf '%s\n' "$dir"
				return 0
			fi
			sub="$(find_ci_dir "$dir" "revision" 2>/dev/null || true)"
			if [ -n "$sub" ] && validate_revision_dir "$sub"; then
				printf '%s\n' "$sub"
				return 0
			fi
		done
	done
	return 1
}

# Collect all candidate Steam/Bottle/GOG paths into global CAND_DIRS array.
collect_install_candidates() {
	CAND_DIRS=(
		"$DL/Deus Ex Mac/Put game files here"
		"$HOME/Library/Application Support/Steam/steamapps/common/Deus Ex"
		"$HOME/Library/Application Support/Steam/steamapps/common/Deus Ex GOTY"
		"$HOME/Library/Application Support/Steam/steamapps/common/Deus Ex Revision"
		"$HOME/Games/Heroic/Deus Ex GOTY"
		"$HOME/Games/Heroic/Deus Ex"
		"$HOME/Games/Heroic/Deus Ex Revision"
		"$HOME/Games/Deus Ex GOTY"
		"$HOME/Games/Deus Ex"
		"$HOME/Games/Deus Ex Revision"
		"$DL/Deus Ex GOTY"
		"$DL/Deus Ex"
		"$DL/Deus Ex Revision"
		"$HOME/Desktop/Deus Ex GOTY"
		"$HOME/Desktop/Deus Ex"
		"$HOME/Desktop/Deus Ex Revision"
	)
	local vdf="$HOME/Library/Application Support/Steam/steamapps/libraryfolders.vdf"
	if [ -f "$vdf" ]; then
		local lib
		while IFS= read -r lib; do
			[ -d "$lib" ] || continue
			CAND_DIRS+=(
				"$lib/steamapps/common/Deus Ex"
				"$lib/steamapps/common/Deus Ex GOTY"
				"$lib/steamapps/common/Deus Ex Revision"
			)
		done <<EOF
$(sed -n 's/^[[:space:]]*"path"[[:space:]]*"\([^"]*\)".*/\1/p' "$vdf")
EOF
	fi
	# Manual depot downloads from the Steam console (`download_depot 6910 6911`),
	# needed on macOS because Steam won't install the Windows-only app.
	local depot
	for depot in \
		"$HOME/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steamapps/content"/app_*/depot_* \
		"$HOME/Library/Application Support/Steam/steamapps/content"/app_*/depot_*
	do
		if [ -d "$depot" ]; then
			CAND_DIRS+=("$depot")
		fi
	done
	local bottle
	for bottle in \
		"$HOME/Library/Application Support/CrossOver/Bottles"/* \
		"$HOME/Library/Containers/com.isaacmarovitz.Whisky/Bottles"/* \
		"$HOME/Applications/Porting Kit"/*
	do
		if [ -d "$bottle" ]; then
			CAND_DIRS+=("$bottle")
		fi
	done
	return 0
}

# Parse arguments.
WANT_DMG=no
LOCAL_SRC=""
GAME_ARG=""
REV_MODE=""      # "", "yes", "no", or "auto"
REV_ARG=""       # explicit --revision path/archive if given
UPDATE_REV=no
while [ $# -gt 0 ]; do
	case "$1" in
		--dmg) WANT_DMG=yes; shift ;;
		-g|--game)
			[ $# -ge 2 ] || die "$1 requires a path to your Deus Ex GOTY installation"
			GAME_ARG="$2"; shift 2 ;;
		--game=*)
			GAME_ARG="${1#--game=}"; shift ;;
		-r|--revision)
			[ $# -ge 2 ] || die "$1 requires a folder/archive path or 'auto'"
			if [ "$2" = "auto" ]; then
				REV_MODE="auto"
			else
				REV_MODE="yes"
				REV_ARG="$2"
			fi
			shift 2 ;;
		--revision=*)
			val="${1#--revision=}"
			if [ "$val" = "auto" ]; then
				REV_MODE="auto"
			else
				REV_MODE="yes"
				REV_ARG="$val"
			fi
			shift ;;
		--with-revision)
			REV_MODE="auto"; shift ;;
		--update-revision)
			REV_MODE="auto"; UPDATE_REV=yes; shift ;;
		--vanilla|--no-revision)
			REV_MODE="no"; REV_ARG=""; shift ;;
		--local)
			[ $# -ge 2 ] || die "--local requires a path to DeusEx-macos-arm64.tar.gz or Deus Ex.app"
			LOCAL_SRC="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option: $1" ;;
		*) GAME_ARG="$1"; shift ;;
	esac
done

banner

if [ "$(uname -sm)" != "Darwin arm64" ]; then
	die "this installer is for Apple Silicon Macs (arm64) only"
fi

TMP=""
DEV=""
cleanup() {
	kill $(jobs -p) 2>/dev/null || true
	[ -n "$DEV" ] && hdiutil detach "$DEV" >/dev/null 2>&1 || true
	[ -n "$TMP" ] && rm -rf "$TMP"
	[ "$FANCY" = yes ] && printf '\033[?25h' || true
}
trap cleanup EXIT

# Auto-detect sibling tarball if script is invoked locally without --local.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -z "$LOCAL_SRC" ] && [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/DeusEx-macos-arm64.tar.gz" ]; then
	LOCAL_SRC="$SCRIPT_DIR/DeusEx-macos-arm64.tar.gz"
fi

# ---------------------------------------------------------------------------
# Step 1: Locate original Deus Ex GOTY game files & optional Revision mod.
# ---------------------------------------------------------------------------
step "Locating your Deus Ex GOTY game files"

EXISTING_APP=""
EXISTING_ICNS=""
EXISTING_VER=""
ASSET_SRC=""
collect_install_candidates

# Check existing self-contained Deus Ex.app installs first (supports seamless in-place updates).
APP_SEARCH_LIST=(
	"/Applications/$APP_NAME.app"
	"$HOME/Applications/$APP_NAME.app"
	"$DL/$APP_NAME.app"
	"$DL/Deus Ex Mac/$APP_NAME.app"
)
if [ -n "${DEUS_EX_DEST_DIR:-}" ]; then
	APP_SEARCH_LIST=("${DEUS_EX_DEST_DIR%/}/$APP_NAME.app")
fi
for app in "${APP_SEARCH_LIST[@]}"; do
	if validate_game_dir "$app/Contents/Resources/GameData"; then
		EXISTING_APP="$app"
		if [ -f "$app/Contents/Resources/DeusEx.icns" ]; then
			EXISTING_ICNS="$app/Contents/Resources/DeusEx.icns"
		fi
		EXISTING_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || true)"
		if [ -z "$GAME_ARG" ]; then
			ASSET_SRC="$app/Contents/Resources/GameData"
			ok "Found existing installation: $app${EXISTING_VER:+ (v$EXISTING_VER)}"
		fi
		break
	fi
done

if [ -n "$GAME_ARG" ]; then
	if ! ASSET_SRC="$(resolve_game_dir "$GAME_ARG")"; then
		die "complete Deus Ex GOTY files not found in: $GAME_ARG" \
			"Pass the Deus Ex GOTY folder containing System/, Maps/, Textures/, Sounds/, and Music/."
	fi
	ok "Using game files from $ASSET_SRC"
elif [ -z "$ASSET_SRC" ]; then
	for cand in "${CAND_DIRS[@]}"; do
		if ASSET_SRC="$(resolve_game_dir "$cand")"; then
			ok "Using game files from $ASSET_SRC"
			break
		fi
		ASSET_SRC=""
	done

	if [ -z "$ASSET_SRC" ]; then
		for search_root in "$DL" "$HOME/Desktop" "$HOME/Games"; do
			[ -d "$search_root" ] || continue
			for cand in "$search_root"/*; do
				[ -d "$cand" ] || continue
				case "$(basename "$cand" | tr '[:upper:]' '[:lower:]')" in
					*deus*) ;;
					*) continue ;;
				esac
				if ASSET_SRC="$(resolve_game_dir "$cand")"; then
					ok "Using game files from $ASSET_SRC"
					break 2
				fi
				ASSET_SRC=""
			done
		done
	fi

	if [ -z "$ASSET_SRC" ]; then
		die "Deus Ex GOTY game files not found" \
			"Steam on macOS won't install Deus Ex (Windows-only). Either:" \
			"  - open steam://open/console and run: download_depot 6910 6911  (then re-run this script), or" \
			"  - install it via GOG/CrossOver/Whisky, or copy the game folder (System, Maps, Textures, Sounds, Music) to ~/Downloads," \
			"or pass its path explicitly with --game:" \
			"  curl -fsSL https://raw.githubusercontent.com/$REPO/$BRANCH/quick-install.sh | bash -s -- --game ~/path/to/\"Deus Ex GOTY\""
	fi
fi

# Locate any local Revision folder or Windows Revision installer archive.
REV_SRC=""
REV_ARCHIVE=""
REV_DOWNLOAD=no

find_local_revision() {
	local cand=""
	if [ -n "$REV_ARG" ]; then
		if [ -d "$REV_ARG" ]; then
			REV_SRC="$(resolve_revision_dir "$REV_ARG" || true)"
			[ -n "$REV_SRC" ] || die "Deus Ex: Revision files not found in folder: $REV_ARG"
			return 0
		elif [ -f "$REV_ARG" ]; then
			REV_ARCHIVE="$REV_ARG"
			return 0
		else
			die "Revision path not found: $REV_ARG"
		fi
	fi

	# 1. Existing Revision alongside ASSET_SRC or inside EXISTING_APP (unless forcing refresh).
	if [ "$UPDATE_REV" != yes ]; then
		REV_SRC="$(resolve_revision_dir "$ASSET_SRC" || true)"
		[ -n "$REV_SRC" ] && return 0
	fi

	# 2. Common Steam / GOG / CrossOver / Whisky / Downloads folders.
	for cand in "${CAND_DIRS[@]}"; do
		REV_SRC="$(resolve_revision_dir "$cand" || true)"
		[ -n "$REV_SRC" ] && return 0
	done
	for search_root in "$DL" "$HOME/Desktop" "$HOME/Games"; do
		[ -d "$search_root" ] || continue
		for cand in "$search_root"/*; do
			case "$(basename "$cand" | tr '[:upper:]' '[:lower:]')" in
				*revision*|*deus*) ;;
				*) continue ;;
			esac
			if [ -d "$cand" ]; then
				REV_SRC="$(resolve_revision_dir "$cand" || true)"
				[ -n "$REV_SRC" ] && return 0
			elif [ -f "$cand" ]; then
				case "$(basename "$cand" | tr '[:upper:]' '[:lower:]')" in
					revision*steaminstaller*.zip|setup_deus_ex_revision*.exe)
						REV_ARCHIVE="$cand"
						return 0 ;;
				esac
			fi
		done
	done
	return 1
}

if [ "$REV_MODE" != "no" ]; then
	find_local_revision || true
fi

if [ "$REV_MODE" = "no" ]; then
	REV_SRC=""
	REV_ARCHIVE=""
	ok "Mode: Vanilla Deus Ex GOTY"
elif [ -n "$REV_MODE" ]; then
	if [ -n "$REV_SRC" ]; then
		ok "Using Deus Ex: Revision files from $REV_SRC"
	elif [ -n "$REV_ARCHIVE" ]; then
		ok "Using Deus Ex: Revision installer: $(basename "$REV_ARCHIVE")"
	else
		REV_DOWNLOAD=yes
		ok "Will download and install official Deus Ex: Revision mod"
	fi
else
	# No explicit Revision flag: preserve existing Revision on upgrade, otherwise offer interactively.
	if [ -n "$EXISTING_APP" ] && validate_revision_dir "$EXISTING_APP/Contents/Resources/GameData/Revision"; then
		REV_SRC="$EXISTING_APP/Contents/Resources/GameData/Revision"
		ok "Preserving installed Deus Ex: Revision mod during update"
	elif [ -n "$REV_SRC" ]; then
		if can_prompt; then
			ans="$(ask_tty "Found Deus Ex: Revision at $REV_SRC. Include it? [Y/n]" "y")"
			case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
				n|no) REV_SRC="" ;;
				*) ok "Including Deus Ex: Revision" ;;
			esac
		else
			REV_SRC=""
		fi
	elif [ -n "$REV_ARCHIVE" ]; then
		if can_prompt; then
			ans="$(ask_tty "Found Revision installer $(basename "$REV_ARCHIVE"). Install it? [Y/n]" "y")"
			case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
				n|no) REV_ARCHIVE="" ;;
				*) ok "Including Deus Ex: Revision from $(basename "$REV_ARCHIVE")" ;;
			esac
		else
			REV_ARCHIVE=""
		fi
	elif can_prompt; then
		ans="$(ask_tty "Also install Deus Ex: Revision mod (downloads ~3.1 GB official installer)? [y/N]" "n")"
		case "$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')" in
			y|yes)
				REV_DOWNLOAD=yes
				ok "Will download and install Deus Ex: Revision" ;;
		esac
	fi
fi

# ---------------------------------------------------------------------------
# Step 2: Obtain & unpack engine-only Deus Ex.app.
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
APP="$TMP/$APP_NAME.app"
GDATA="$APP/Contents/Resources/GameData"

step "Fetching native Apple Silicon DXEngine"

if [ -n "$LOCAL_SRC" ]; then
	if [ -d "$LOCAL_SRC" ] && [ -d "$LOCAL_SRC/Contents/MacOS" ]; then
		run_task "Copying local engine bundle" cp -R "$LOCAL_SRC" "$APP"
	elif [ -f "$LOCAL_SRC" ]; then
		run_task "Unpacking local engine archive" tar -xzf "$LOCAL_SRC" -C "$TMP"
		ok "Loaded local engine archive: $(basename "$LOCAL_SRC")"
	else
		die "local engine path not found: $LOCAL_SRC"
	fi
else
	case "$REPO" in
		*YOUR_GITHUB_USER*)
			die "DEUS_EX_MAC_REPO is not configured yet" \
				"Host the release folder on GitHub and update REPO in quick-install.sh," \
				"or pass --local /path/to/DeusEx-macos-arm64.tar.gz for offline packaging." ;;
	esac
	if [ "$FANCY" = yes ]; then
		DL_TOTAL="$(curl -sIL "$RELEASE_URL" 2>/dev/null \
			| awk 'tolower($1)=="content-length:" {gsub(/\r/,"",$2); cl=$2} END {printf "%d", cl}' || echo 0)"
		case "$DL_TOTAL" in ''|*[!0-9]*) DL_TOTAL=0 ;; esac
		curl -fsSL -o "$TMP/DeusEx-macos-arm64.tar.gz" "$RELEASE_URL" &
		watch_bytes $! "DeusEx-macos-arm64.tar.gz" "$DL_TOTAL" file_bytes "$TMP/DeusEx-macos-arm64.tar.gz" \
			|| die "download failed from $RELEASE_URL"
	else
		echo "==> Downloading DeusEx-macos-arm64.tar.gz..."
		curl -fL --progress-bar -o "$TMP/DeusEx-macos-arm64.tar.gz" "$RELEASE_URL" \
			|| die "download failed from $RELEASE_URL"
	fi
	if [ -z "${DEUS_EX_RELEASE_URL:-}" ] || [ -n "${DEUS_EX_CHECKSUM_URL:-}" ]; then
		curl -fsSL -o "$TMP/SHA256SUMS.txt" "$CHECKSUM_URL" \
			|| die "checksum download failed from $CHECKSUM_URL"
		EXPECTED_SHA="$(awk '$2 == "DeusEx-macos-arm64.tar.gz" {gsub(/\r/,"",$1); print $1; exit}' "$TMP/SHA256SUMS.txt")"
		[ -n "$EXPECTED_SHA" ] || die "DeusEx-macos-arm64.tar.gz checksum missing in $CHECKSUM_URL"
		ACTUAL_SHA="$(shasum -a 256 "$TMP/DeusEx-macos-arm64.tar.gz" | awk '{print $1}')"
		[ "$ACTUAL_SHA" = "$EXPECTED_SHA" ] || die "SHA-256 verification failed for DeusEx-macos-arm64.tar.gz" \
			"Expected: $EXPECTED_SHA" \
			"Actual:   $ACTUAL_SHA"
		ok "Verified SHA-256 checksum (${ACTUAL_SHA:0:12}...)"
	fi
	run_task "Unpacking Deus Ex.app" tar -xzf "$TMP/DeusEx-macos-arm64.tar.gz" -C "$TMP"
fi

if [ ! -d "$APP" ]; then
	FOUND_APP="$(find "$TMP" -maxdepth 2 -name '*.app' -print -quit 2>/dev/null || true)"
	[ -n "$FOUND_APP" ] || die "unpacked archive did not contain an .app bundle"
	mv "$FOUND_APP" "$APP"
fi

[ -x "$APP/Contents/MacOS/DXEngine" ] || die "DXEngine binary missing inside $APP"
NEW_VER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || true)"

/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Add :CFBundleName string $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile DeusEx" "$APP/Contents/Info.plist" 2>/dev/null \
	|| /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string DeusEx" "$APP/Contents/Info.plist"

# ---------------------------------------------------------------------------
# Step 3: Bake Deus Ex GOTY (+ optional Revision) into Contents/Resources/GameData.
# ---------------------------------------------------------------------------
step "Packaging game assets into Deus Ex.app"

mkdir -p "$GDATA"
SRC_SYS="$(find_ci_dir "$ASSET_SRC" "system")"
SRC_MAPS="$(find_ci_dir "$ASSET_SRC" "maps")"
SRC_TEX="$(find_ci_dir "$ASSET_SRC" "textures")"
SRC_SND="$(find_ci_dir "$ASSET_SRC" "sounds")"
SRC_MUS="$(find_ci_dir "$ASSET_SRC" "music")"
SRC_HELP="$(find_ci_dir "$ASSET_SRC" "help" || true)"

copy_deref() {
	local src=$1 dst=$2
	if ! cp -c -R -L "$src" "$dst" 2>/dev/null; then
		rm -rf "$dst" 2>/dev/null || true
		cp -R -L "$src" "$dst"
	fi
}

merge_deref() {
	local src=$1 dst=$2
	cp -c -R -L "$src"/. "$dst"/ 2>/dev/null || cp -R -L "$src"/. "$dst"/
}

bake_files() {
	copy_deref "$SRC_SYS" "$GDATA/System"
	copy_deref "$SRC_MAPS" "$GDATA/Maps"
	copy_deref "$SRC_TEX" "$GDATA/Textures"
	copy_deref "$SRC_SND" "$GDATA/Sounds"
	copy_deref "$SRC_MUS" "$GDATA/Music"
	[ -n "$SRC_HELP" ] && copy_deref "$SRC_HELP" "$GDATA/Help" || true
}

if [ "$FANCY" = yes ]; then
	BAKE_TOTAL=$(( \
		$(du_bytes "$SRC_SYS") + \
		$(du_bytes "$SRC_MAPS") + \
		$(du_bytes "$SRC_TEX") + \
		$(du_bytes "$SRC_SND") + \
		$(du_bytes "$SRC_MUS") ))
	bake_files &
	watch_bytes $! "Copying GOTY data" "$BAKE_TOTAL" du_bytes "$GDATA" \
		|| die "copying GOTY game files failed"
else
	echo "==> Copying Deus Ex GOTY game data into bundle..."
	bake_files
fi

# Helper: obtain 7zz (official macOS universal binary) for extracting Windows .wim/.7z/.zip Revision archives.
ensure_7zz() {
	if command -v 7zz >/dev/null 2>&1; then
		command -v 7zz; return 0
	fi
	if command -v 7z >/dev/null 2>&1; then
		command -v 7z; return 0
	fi
	if [ -x "$TOOLS_DIR/7zz" ]; then
		printf '%s\n' "$TOOLS_DIR/7zz"; return 0
	fi
	mkdir -p "$TOOLS_DIR"
	local rel="a/7z2301-mac.tar.xz"
	local detected
	detected="$(curl -fsSL https://www.7-zip.org/download.html 2>/dev/null | grep -oiE 'a/7z[0-9]+-mac\.tar\.xz' | head -n 1 || true)"
	[ -n "$detected" ] && rel="$detected"
	local url="https://www.7-zip.org/$rel"
	curl -fsSL -o "$TMP/7z-mac.tar.xz" "$url" || die "failed to download 7zz extractor from $url"
	mkdir -p "$TMP/7z_unpack"
	tar -xJf "$TMP/7z-mac.tar.xz" -C "$TMP/7z_unpack" || die "failed to unpack $url"
	local bin
	bin="$(find "$TMP/7z_unpack" -maxdepth 2 -name '7zz' -type f -print -quit)"
	[ -n "$bin" ] || die "7zz binary missing in $url"
	cp "$bin" "$TOOLS_DIR/7zz"
	xattr -cr "$TOOLS_DIR/7zz" 2>/dev/null || true
	chmod +x "$TOOLS_DIR/7zz"
	printf '%s\n' "$TOOLS_DIR/7zz"
}

resolve_revision_url() {
	if [ -n "${DEUS_EX_REVISION_URL:-}" ]; then
		printf '%s\n' "$DEUS_EX_REVISION_URL"
		return 0
	fi
	local live
	live="$(curl -fsSL https://www.dx-revision.com/download/ 2>/dev/null \
		| grep -oiE 'https://[^"'\'' ]*Revision_[^"'\'' ]*_SteamInstaller\.zip' | head -n 1 || true)"
	if [ -n "$live" ]; then
		printf '%s\n' "$live"
	else
		printf '%s\n' "https://cloudfront.dx-revision.com/releases/Revision_1_6_3_0_SteamInstaller.zip"
	fi
}

install_revision_archive() {
	local arc=$1 remove_arc=${2:-no}
	local lower
	lower="$(printf '%s' "$(basename "$arc")" | tr '[:upper:]' '[:lower:]')"
	local rev_out="$GDATA/Revision"
	mkdir -p "$rev_out"

	case "$lower" in
		setup_deus_ex_revision*.exe)
			local INNO=""
			if command -v innoextract >/dev/null 2>&1; then
				INNO="$(command -v innoextract)"
			elif command -v brew >/dev/null 2>&1; then
				run_task "Installing innoextract via Homebrew" brew install innoextract
				INNO="$(command -v innoextract || true)"
			fi
			[ -n "$INNO" ] || die "innoextract is required to unpack GOG installer $(basename "$arc")" \
				"Install Homebrew + 'brew install innoextract', or re-run with '--with-revision' to download the official zip installer instead."
			mkdir -p "$TMP/rev_inno"
			run_task "Extracting GOG Revision installer" "$INNO" -e -s -d "$TMP/rev_inno" "$arc"
			local extracted
			extracted="$(resolve_revision_dir "$TMP/rev_inno" || true)"
			[ -n "$extracted" ] || die "could not find Revision files inside $(basename "$arc")"
			cp -R -L "$extracted"/. "$rev_out/"
			rm -rf "$TMP/rev_inno"
			return 0 ;;
	esac

	local SEVENZ
	SEVENZ="$(ensure_7zz)"
	case "$lower" in
		*.wim)
			run_task "Extracting $(basename "$arc")" "$SEVENZ" x -y -aoa -o"$rev_out" "$arc" >/dev/null
			;;
		*.zip|*.7z|*.exe)
			mkdir -p "$TMP/rev_wims"
			run_task "Unpacking $(basename "$arc")" "$SEVENZ" e -y -aoa -o"$TMP/rev_wims" "$arc" "*.wim" >/dev/null || true
			[ "$remove_arc" = yes ] && rm -f "$arc"
			local wim_found=0 wim
			for wim_name in Content_Stock.wim Content_Patch.wim Content_Steam.wim; do
				wim="$(find_ci_file "$TMP/rev_wims" "$(printf '%s' "$wim_name" | tr '[:upper:]' '[:lower:]')" || true)"
				if [ -n "$wim" ]; then
					wim_found=1
					run_task "Extracting $wim_name into Revision" "$SEVENZ" x -y -aoa -o"$rev_out" "$wim" >/dev/null
					rm -f "$wim"
				fi
			done
			for wim in "$TMP/rev_wims"/*.wim "$TMP/rev_wims"/*.WIM; do
				[ -f "$wim" ] || continue
				wim_found=1
				run_task "Extracting $(basename "$wim") into Revision" "$SEVENZ" x -y -aoa -o"$rev_out" "$wim" >/dev/null
				rm -f "$wim"
			done
			if [ "$wim_found" -eq 0 ]; then
				# Plain archive (e.g. zipped Revision folder) without inner .wim containers.
				mkdir -p "$TMP/rev_plain"
				run_task "Extracting $(basename "$arc")" "$SEVENZ" x -y -aoa -o"$TMP/rev_plain" "$arc" >/dev/null
				local found_dir
				found_dir="$(resolve_revision_dir "$TMP/rev_plain" || true)"
				[ -n "$found_dir" ] || die "no Revision mod files found inside $(basename "$arc")"
				merge_deref "$found_dir" "$rev_out"
				rm -rf "$TMP/rev_plain"
			fi
			rm -rf "$TMP/rev_wims"
			;;
		*)
			die "unsupported Revision archive format: $arc" ;;
	esac
}

if [ "$REV_DOWNLOAD" = yes ]; then
	REV_URL="$(resolve_revision_url)"
	REV_DL_NAME="$(basename "${REV_URL%%\?*}")"
	[ -n "$REV_DL_NAME" ] || REV_DL_NAME="Revision_SteamInstaller.zip"
	REV_DL_PATH="$TMP/$REV_DL_NAME"
	if [ "$FANCY" = yes ]; then
		REV_TOTAL="$(curl -sIL "$REV_URL" 2>/dev/null \
			| awk 'tolower($1)=="content-length:" {gsub(/\r/,"",$2); cl=$2} END {printf "%d", cl}' || echo 0)"
		case "$REV_TOTAL" in ''|*[!0-9]*) REV_TOTAL=0 ;; esac
		curl -fsSL -o "$REV_DL_PATH" "$REV_URL" &
		watch_bytes $! "$REV_DL_NAME" "$REV_TOTAL" file_bytes "$REV_DL_PATH" \
			|| die "Revision download failed from $REV_URL"
	else
		echo "==> Downloading $REV_DL_NAME..."
		curl -fL --progress-bar -o "$REV_DL_PATH" "$REV_URL" \
			|| die "Revision download failed from $REV_URL"
	fi
	REV_ARCHIVE="$REV_DL_PATH"
fi

if [ -n "$REV_SRC" ]; then
	mkdir -p "$GDATA/Revision"
	bake_revision_dir() {
		local item base lower
		for item in "$REV_SRC"/*; do
			[ -e "$item" ] || continue
			base="$(basename "$item")"
			lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
			case "$lower" in
				save|cache) continue ;;
			esac
			copy_deref "$item" "$GDATA/Revision/$base"
		done
	}
	if [ "$FANCY" = yes ]; then
		REV_BYTES="$(du_bytes "$REV_SRC")"
		bake_revision_dir &
		watch_bytes $! "Copying Revision mod" "$REV_BYTES" du_bytes "$GDATA/Revision" \
			|| die "copying Revision mod files failed"
	else
		echo "==> Copying Deus Ex: Revision mod into bundle..."
		bake_revision_dir
	fi
fi

if [ -n "$REV_ARCHIVE" ]; then
	DL_REMOVE=no
	[ "$REV_DOWNLOAD" = yes ] && DL_REMOVE=yes
	install_revision_archive "$REV_ARCHIVE" "$DL_REMOVE"
fi

if [ -d "$GDATA/Revision" ]; then
	validate_revision_dir "$GDATA/Revision" || die "Revision files in $GDATA/Revision appear incomplete"
	REV_SYS_DIR="$(find_ci_dir "$GDATA/Revision" "system")"
	if ! find_ci_file "$REV_SYS_DIR" "revision.ini" >/dev/null; then
		REV_DEF_INI="$(find_ci_file "$REV_SYS_DIR" "revisiondefault.ini" || true)"
		[ -n "$REV_DEF_INI" ] && cp "$REV_DEF_INI" "$REV_SYS_DIR/Revision.ini"
	fi
	if ! find_ci_file "$REV_SYS_DIR" "revisionuser.ini" >/dev/null; then
		REV_DEF_USR="$(find_ci_file "$REV_SYS_DIR" "revisiondefuser.ini" || true)"
		[ -n "$REV_DEF_USR" ] && cp "$REV_DEF_USR" "$REV_SYS_DIR/RevisionUser.ini"
	fi
	ok "Baked Deus Ex: Revision mod into GameData/Revision"
fi

extract_pe_icon() {
	local exe=$1 out_ico=$2
	command -v python3 >/dev/null 2>&1 || return 1
	python3 - "$exe" "$out_ico" <<'PY' >/dev/null 2>&1
import struct, sys
exe_path, out_path = sys.argv[1], sys.argv[2]
with open(exe_path, "rb") as f:
    pe = f.read()
pe_off = struct.unpack_from("<I", pe, 0x3C)[0]
num_sec = struct.unpack_from("<H", pe, pe_off + 6)[0]
opt_sz = struct.unpack_from("<H", pe, pe_off + 20)[0]
sec_off = pe_off + 24 + opt_sz
rsrc_raw = 0
sections = []
for i in range(num_sec):
    o = sec_off + i * 40
    name = pe[o:o+8].rstrip(b"\x00").decode("latin1", "ignore")
    vsz, va, rsz, raw = struct.unpack_from("<IIII", pe, o + 8)
    sections.append((va, vsz, raw, rsz))
    if name == ".rsrc":
        rsrc_raw = raw
assert rsrc_raw
def rva_off(rva):
    for va, vsz, raw, rsz in sections:
        if va <= rva < va + max(vsz, rsz):
            return raw + (rva - va)
    raise ValueError(rva)
def entries(off):
    _, _, _, _, nn, ni = struct.unpack_from("<IIHHHH", pe, off)
    return [struct.unpack_from("<II", pe, off + 16 + i * 8) for i in range(nn + ni)]
icons, groups = {}, []
for tid, tsub in entries(rsrc_raw):
    if tid in (3, 14) and (tsub & 0x80000000):
        for iid, isub in entries(rsrc_raw + (tsub & 0x7FFFFFFF)):
            if isub & 0x80000000:
                for _, lsub in entries(rsrc_raw + (isub & 0x7FFFFFFF)):
                    if not (lsub & 0x80000000):
                        rva, sz, _, _ = struct.unpack_from("<IIII", pe, rsrc_raw + lsub)
                        data = pe[rva_off(rva):rva_off(rva) + sz]
                        if tid == 3:
                            icons[iid] = data
                        else:
                            groups.append(data)
assert groups
grp = groups[0]
_, _, cnt = struct.unpack_from("<HHH", grp, 0)
blobs, dirs = [], []
offset = 6 + cnt * 16
for k in range(cnt):
    w, h, cc, res, pl, bpp, isz, icon_id = struct.unpack_from("<BBBBHHIH", grp, 6 + k * 14)
    blob = icons[icon_id]
    dirs.append(struct.pack("<BBBBHHII", w, h, cc, res, pl, bpp, len(blob), offset))
    blobs.append(blob)
    offset += len(blob)
with open(out_path, "wb") as f:
    f.write(struct.pack("<HHH", 0, 1, cnt))
    for d in dirs:
        f.write(d)
    for b in blobs:
        f.write(b)
PY
}

shape_macos_icon() {
	local png=$1
	command -v osascript >/dev/null 2>&1 || return 0
	osascript -l JavaScript - "$png" <<'JXA' >/dev/null 2>&1 || true
ObjC.import("Cocoa");
function run(argv) {
	var p = argv[0];
	var src = $.NSImage.alloc.initWithContentsOfFile(p);
	if (!src || !src.TIFFRepresentation) return;
	var srcRep = $.NSBitmapImageRep.imageRepWithData(src.TIFFRepresentation);
	var pw = srcRep.pixelsWide, ph = srcRep.pixelsHigh;
	if (pw < 32 || ph < 32) return;
	var cy = Math.floor(ph / 2);
	var trimFrac = 0.0;
	if (srcRep.colorAtXY(0, 0).alphaComponent < 0.1 && srcRep.colorAtXY(Math.floor(pw / 2), cy).alphaComponent > 0.9) {
		for (var x = 0; x < Math.floor(pw / 2); x++) {
			if (srcRep.colorAtXY(x, cy).alphaComponent > 0.9) {
				trimFrac = (x + Math.round(pw * 0.044)) / pw;
				break;
			}
		}
	}
	var size = 1024;
	var canvas = $.NSImage.alloc.initWithSize($.NSMakeSize(size, size));
	canvas.lockFocus;
	$.NSGraphicsContext.currentContext.imageInterpolation = $.NSImageInterpolationHigh;
	var rect = $.NSMakeRect(0, 0, size, size);
	$.NSBezierPath.bezierPathWithRoundedRectXRadiusYRadius(rect, 224, 224).addClip;
	if (trimFrac > 0 && trimFrac < 0.35) {
		$.NSColor.colorWithCalibratedRedGreenBlueAlpha(0.015, 0.035, 0.075, 1.0).setFill;
		$.NSRectFill(rect);
		var cropFrac = 1.0 - 2.0 * trimFrac;
		var drawSize = (size * 1.30) / cropFrac;
		var offX = (size - drawSize) / 2.0;
		var offY = (size - drawSize) / 2.0 - size * 0.025;
		var r = (drawSize * cropFrac) * 0.495;
		var cx = size / 2.0, cY = size / 2.0 - size * 0.025;
		$.NSBezierPath.bezierPathWithOvalInRect($.NSMakeRect(cx - r, cY - r, r * 2, r * 2)).addClip;
		src.drawInRectFromRectOperationFraction($.NSMakeRect(offX, offY, drawSize, drawSize), $.NSZeroRect, $.NSCompositingOperationSourceOver, 1.0);
	} else {
		src.drawInRectFromRectOperationFraction(rect, $.NSZeroRect, $.NSCompositingOperationSourceOver, 1.0);
	}
	var outRep = $.NSBitmapImageRep.alloc.initWithFocusedViewRect(rect);
	canvas.unlockFocus;
	var data = outRep.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
	data.writeToFileAtomically(p, true);
}
JXA
}

install_original_icon() {
	local out="$APP/Contents/Resources/DeusEx.icns"
	command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 || {
		[ -n "$EXISTING_ICNS" ] && [ -f "$EXISTING_ICNS" ] && cp "$EXISTING_ICNS" "$out" && ok "Preserved app icon"
		return 0
	}
	local ico="" src_label="" exe="" cand=""
	ico="$(find -H "$ASSET_SRC" -maxdepth 2 -iname 'goggame-*.ico' -print -quit 2>/dev/null || true)"
	if [ -z "$ico" ] && [ -n "$EXISTING_APP" ] && [ "$ASSET_SRC" = "$EXISTING_APP/Contents/Resources/GameData" ]; then
		collect_install_candidates
		for cand in "${CAND_DIRS[@]}"; do
			[ -d "$cand" ] || continue
			ico="$(find -H "$cand" -maxdepth 2 -iname 'goggame-*.ico' -print -quit 2>/dev/null || true)"
			[ -f "$ico" ] && break || ico=""
		done
	fi
	if [ -z "$ico" ] && [ -n "$EXISTING_ICNS" ] && [ -f "$EXISTING_ICNS" ]; then
		cp "$EXISTING_ICNS" "$out"
		ok "Preserved existing game icon"
		return 0
	fi
	[ -n "$ico" ] || [ -z "$SRC_HELP" ] || ico="$(find -H "$SRC_HELP" -maxdepth 1 -iname 'DeusEx.ico' -print -quit 2>/dev/null || true)"
	[ -n "$ico" ] || ico="$(find -H "$ASSET_SRC" -maxdepth 2 -iname 'DeusEx.ico' -print -quit 2>/dev/null || true)"
	[ -n "$ico" ] || ico="$(find -H "$ASSET_SRC" -maxdepth 1 -iname '*.ico' ! -iname 'gog.ico' ! -iname 'support.ico' ! -iname 'unins*.ico' -print -quit 2>/dev/null || true)"
	if [ -f "$ico" ]; then
		src_label="$(basename "$ico")"
	else
		exe="$(find_ci_file "$SRC_SYS" "deusex.exe" || true)"
		if [ -n "$exe" ] && extract_pe_icon "$exe" "$TMP/deusex_pe.ico"; then
			ico="$TMP/deusex_pe.ico"
			src_label="$(basename "$exe")"
		fi
	fi
	[ -f "$ico" ] || return 0

	local base="$TMP/orig_icon.png" setdir="$TMP/DeusEx.iconset"
	sips -s format png "$ico" --out "$base" >/dev/null 2>&1 || return 0
	shape_macos_icon "$base"
	rm -rf "$setdir"
	mkdir -p "$setdir"
	sips -z 16 16     "$base" --out "$setdir/icon_16x16.png" >/dev/null 2>&1 || return 0
	sips -z 32 32     "$base" --out "$setdir/icon_16x16@2x.png" >/dev/null 2>&1 || return 0
	cp                "$setdir/icon_16x16@2x.png" "$setdir/icon_32x32.png"
	sips -z 64 64     "$base" --out "$setdir/icon_32x32@2x.png" >/dev/null 2>&1 || return 0
	sips -z 128 128   "$base" --out "$setdir/icon_128x128.png" >/dev/null 2>&1 || return 0
	sips -z 256 256   "$base" --out "$setdir/icon_128x128@2x.png" >/dev/null 2>&1 || return 0
	cp                "$setdir/icon_128x128@2x.png" "$setdir/icon_256x256.png"
	sips -z 512 512   "$base" --out "$setdir/icon_256x256@2x.png" >/dev/null 2>&1 || return 0
	cp                "$setdir/icon_256x256@2x.png" "$setdir/icon_512x512.png"
	sips -z 1024 1024 "$base" --out "$setdir/icon_512x512@2x.png" >/dev/null 2>&1 || return 0
	iconutil -c icns "$setdir" -o "$out" >/dev/null 2>&1 && ok "Applied original game icon ($src_label)" || true
}
install_original_icon

shasum -a 256 "$APP/Contents/MacOS/DXEngine" | awk '{print $1}' > "$APP/Contents/Resources/version.sha"

# Clear stale symlinks inside ~/Library/Application Support/Deus Ex Native so the
# updated GameData paths re-link cleanly while keeping saves and .ini settings.
if [ -d "$SUPPORT_DIR" ]; then
	find "$SUPPORT_DIR" -maxdepth 3 -type l -delete 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Step 4: Ad-hoc sign the finished self-contained app bundle.
# ---------------------------------------------------------------------------
step "Signing Deus Ex.app"

sign_bundle() {
	xattr -cr "$APP" 2>/dev/null || true
	if xcrun -f codesign_allocate >/dev/null 2>&1; then
		local bin
		for bin in "$APP"/Contents/Frameworks/*.dylib; do
			[ -e "$bin" ] || continue
			codesign --force --sign - "$bin" >/dev/null 2>&1 || return 1
		done
		codesign --force --sign - "$APP/Contents/MacOS/DXEngine" >/dev/null 2>&1 || return 1
		codesign --force --sign - "$APP" >/dev/null 2>&1 || return 1
		codesign --verify --deep --strict "$APP" >/dev/null 2>&1 || return 1
		return 0
	fi

	local LDID=""
	if command -v ldid >/dev/null 2>&1; then
		LDID="$(command -v ldid)"
	elif [ -n "${SIGNTOOL_URL:-}" ] && curl -fsSL -o "$TMP/signtool.tar.gz" "$SIGNTOOL_URL" 2>/dev/null; then
		tar -xzf "$TMP/signtool.tar.gz" -C "$TMP" || return 1
		xattr -cr "$TMP/signtool" 2>/dev/null || true
		LDID="$TMP/signtool/ldid"
	fi
	[ -n "$LDID" ] && [ -x "$LDID" ] || return 1

	rm -rf "$APP/Contents/_CodeSignature"
	local lib
	for lib in "$APP"/Contents/Frameworks/*.dylib; do
		[ -e "$lib" ] || continue
		"$LDID" -Cadhoc -S "$lib" || return 1
	done
	"$LDID" -Cadhoc -I"$BUNDLE_ID" -S "$APP/Contents/MacOS/DXEngine"
}

run_task "Ad-hoc signing app bundle" sign_bundle \
	|| die "signing failed (install Xcode Command Line Tools with 'xcode-select --install')"

# ---------------------------------------------------------------------------
# Step 5: Update existing installation in-place or install to ~/Downloads.
# ---------------------------------------------------------------------------
outro() {
	printf '\n'
	printf '%s✔ Done!%s %s\n' "$GREEN$BOLD" "$RESET" "$1"
	printf '  %s\n' "$2"
	printf '  Saves and configs live in: ~/Library/Application Support/Deus Ex Native\n'
	printf '  macOS Game Mode activates automatically while playing.\n'
	printf '\n'
	printf '       %s🕶  Welcome to UNATCO  🕶%s\n' "$CYAN" "$RESET"
	printf '       %sfinished in %dm %02ds%s\n' "$DIM" $((SECONDS / 60)) $((SECONDS % 60)) "$RESET"
	printf '\n'
}

if [ "$WANT_DMG" = no ]; then
	if [ -n "$EXISTING_APP" ]; then
		INSTALL_DIR="$(dirname "$EXISTING_APP")"
		step "Updating existing $EXISTING_APP${NEW_VER:+ to v$NEW_VER}"
		STAGED_NEW="$INSTALL_DIR/.${APP_NAME}.app.new.$$"
		BACKUP_OLD="$INSTALL_DIR/.${APP_NAME}.app.old.$$"
		if [ -w "$INSTALL_DIR" ] && [ ! -e "$EXISTING_APP" -o -w "$EXISTING_APP" ]; then
			rm -rf "$STAGED_NEW" "$BACKUP_OLD"
			mv "$APP" "$STAGED_NEW"
			mv "$EXISTING_APP" "$BACKUP_OLD"
			mv "$STAGED_NEW" "$EXISTING_APP"
			rm -rf "$BACKUP_OLD"
		elif can_prompt; then
			ok "Administrator permission needed to update $EXISTING_APP"
			sudo rm -rf "$STAGED_NEW" "$BACKUP_OLD"
			sudo mv "$APP" "$STAGED_NEW"
			sudo mv "$EXISTING_APP" "$BACKUP_OLD"
			sudo mv "$STAGED_NEW" "$EXISTING_APP"
			sudo rm -rf "$BACKUP_OLD"
		else
			warn "$INSTALL_DIR is not writable; placing updated app in $DL instead"
			mkdir -p "$DL"
			rm -rf "$DL/$APP_NAME.app"
			mv "$APP" "$DL/$APP_NAME.app"
			EXISTING_APP="$DL/$APP_NAME.app"
		fi
		/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$EXISTING_APP" >/dev/null 2>&1 || true
		ok "Updated $EXISTING_APP${NEW_VER:+ (v$NEW_VER)}"
		outro "$EXISTING_APP has been updated${NEW_VER:+ to v$NEW_VER}." \
			"Double-click it to launch (saves and settings preserved)."
		[ "$FANCY" = yes ] && open -R "$EXISTING_APP" >/dev/null 2>&1 || true
		exit 0
	fi

	TARGET_DIR="${DEUS_EX_DEST_DIR:-$DL}"
	mkdir -p "$TARGET_DIR"
	step "Installing to $TARGET_DIR"
	rm -rf "$TARGET_DIR/$APP_NAME.app"
	mv "$APP" "$TARGET_DIR/$APP_NAME.app"
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
	ok "Placed $APP_NAME.app in $TARGET_DIR"
	outro "$TARGET_DIR/$APP_NAME.app is ready." \
		"Drag it into /Applications (or double-click it directly) to play."
	[ "$FANCY" = yes ] && open -R "$TARGET_DIR/$APP_NAME.app" >/dev/null 2>&1 || true
	exit 0
fi

mkdir -p "$DL"
step "Building disk image"
STAGE="$TMP/stage"
mkdir -p "$STAGE"
mv "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
TMPDMG="$TMP/rw.dmg"
dmg_create() { hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW "$TMPDMG" >/dev/null; }
run_task "Creating disk image" dmg_create || die "hdiutil create failed"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$TMPDMG" | grep -E '^/dev/' | awk 'NR==1{print $1}')

osascript >/dev/null 2>&1 <<APPLESCRIPT || true
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {400, 100, 900, 430}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 128
    set position of item "$APP_NAME.app" of container window to {130, 165}
    set position of item "Applications" of container window to {370, 165}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEV" >/dev/null; DEV=""
rm -f "$DL/$APP_NAME.dmg"
dmg_convert() { hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$DL/$APP_NAME.dmg" >/dev/null; }
run_task "Compressing disk image" dmg_convert || die "hdiutil convert failed"
ok "Created $DL/$APP_NAME.dmg"

outro "$DL/$APP_NAME.dmg is ready." \
	"Opening it now — drag Deus Ex.app into Applications to install."
[ "$FANCY" = yes ] && open "$DL/$APP_NAME.dmg" >/dev/null 2>&1 || true
