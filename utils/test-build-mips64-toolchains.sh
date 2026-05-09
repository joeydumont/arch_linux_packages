#!/usr/bin/env bash
set -euo pipefail

trap 'trap - SIGTERM && kill -- -$$' SIGINT SIGTERM EXIT

#------------------------------------------------------------------------------
# Globals
#------------------------------------------------------------------------------
FORCE_REBUILD=0
DRY_RUN=0
USE_TMUX=0

declare -a BUILT=()
declare -a SKIPPED=()
declare -a FAILED=()

#------------------------------------------------------------------------------
# Logging
#------------------------------------------------------------------------------
eerror() { echo "!!! $*" >&2; }
einfo()  { echo "* $*"; }

#------------------------------------------------------------------------------
# Command runner
#------------------------------------------------------------------------------
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

#------------------------------------------------------------------------------
# Usage
#------------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  -t <variant>     Toolchain variant (default: mips64-ultra-elf)
  -c <chroot>      Path to chroot
  -f               Force rebuild
  -n, --dry-run    Show what would be executed
  -m, --tmux       Auto-open tail in tmux pane
  -h               Show this help
EOF
}

#------------------------------------------------------------------------------
# Prompt title helpers
#------------------------------------------------------------------------------
ORIG_PROMPT_COMMAND=${PROMPT_COMMAND:-}
push_prompt_command() { echo -en "\033]0; $1 \a"; }
pop_prompt_command()  { [[ -n "$ORIG_PROMPT_COMMAND" ]] && eval "$ORIG_PROMPT_COMMAND"; }

#------------------------------------------------------------------------------
# tmux integration
#------------------------------------------------------------------------------
open_tmux_tail() {
  local log_path="$1"

  [[ "$USE_TMUX" -eq 1 ]] || return
  [[ -n "${TMUX:-}" ]] || return

  if tmux list-panes -F '#{pane_title}' 2>/dev/null | grep -q '^build-log$'; then
    tmux send-keys -t build-log "clear; tail -f \"$log_path\"" C-m
  else
    tmux split-window -v -p 30 "tail -f \"$log_path\""
    tmux select-pane -T build-log
  fi
}

#------------------------------------------------------------------------------
# PKGBUILD helpers
#------------------------------------------------------------------------------
get_pkgver() {
  # shellcheck disable=SC1091,SC2154
  source PKGBUILD
  echo "${pkgver}-${pkgrel}"
}

check_last_build() {
  diff <(sha256sum PKGBUILD) \
       <(cat .last_successful_build_chksum 2>/dev/null) \
       &>/dev/null
}

save_last_build() {
  sha256sum PKGBUILD > .last_successful_build_chksum
}

#------------------------------------------------------------------------------
# Build function
#------------------------------------------------------------------------------
build_package() {
  local dir="$1"
  shift

  push_prompt_command "Building $dir..."
  local cwd
  cwd=$(pwd)

  if ! cd "$dir"; then
    eerror "Missing directory: $dir"
    FAILED+=("$dir")
    return 1
  fi

  run makepkg -o &>/dev/null || true

  local log_file="build-${dir}.log"
  local log_path="${cwd}/${dir}/${log_file}"

  if ! check_last_build || [[ "$FORCE_REBUILD" -eq 1 ]]; then
    einfo "Building $dir"
    einfo "  tail -f \"$log_path\""

    if [[ "$DRY_RUN" -eq 1 ]]; then
      echo "[dry-run] would open tmux pane"
    else
      open_tmux_tail "$log_path"
    fi

    export FORCE_REBUILD=1

    if [[ "$#" -eq 0 ]]; then
      if run makechrootpkg -c -r "$CHROOT" &> "$log_file"; then
        BUILT+=("$dir")
      else
        eerror "Failed: $dir"
        FAILED+=("$dir")
        return 1
      fi
    else
      local pkgs=()
      for dep in "$@"; do pkgs+=(-I "$dep"); done

      if run makechrootpkg -c -r "$CHROOT" "${pkgs[@]}" &> "$log_file"; then
        BUILT+=("$dir")
      else
        eerror "Failed: $dir"
        FAILED+=("$dir")
        return 1
      fi
    fi

    run save_last_build
  else
    einfo "Skipping $dir (up-to-date)"
    SKIPPED+=("$dir")
  fi

  PKGVER=$(get_pkgver)
  export PKGVER

  cd "$cwd" || exit 1
  pop_prompt_command
}

#------------------------------------------------------------------------------
# Resolve script dir
#------------------------------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [[ -h "$SOURCE" ]]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

#------------------------------------------------------------------------------
# Defaults
#------------------------------------------------------------------------------
CHROOT="${SCRIPT_DIR}/chroot"
VARIANT="mips64-ultra-elf"
NEWLIB_ARCH="x86_64"

#------------------------------------------------------------------------------
# Args
#------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      VARIANT="$2"
      NEWLIB_ARCH="any"
      shift 2
      ;;
    -c)
      CHROOT="$2"
      shift 2
      ;;
    -f)
      FORCE_REBUILD=1
      shift
      ;;
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    -m|--tmux)
      USE_TMUX=1
      shift
      ;;
    -h)
      usage
      exit 0
      ;;
    *)
      eerror "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

#------------------------------------------------------------------------------
# Sudo keepalive
#------------------------------------------------------------------------------
run sudo -v
( while sleep 180; do run sudo -v; done ) &

#------------------------------------------------------------------------------
# Build sequence
#------------------------------------------------------------------------------
run arch-nspawn "$CHROOT/root" pacman -Syu

build_package "${VARIANT}-binutils"
BINUTILS_VER="$PKGVER"

build_package "${VARIANT}-gcc-stage1" \
  "../${VARIANT}-binutils/${VARIANT}-binutils-${BINUTILS_VER}-x86_64.pkg.tar.zst"
GCCSTAGE1_VER="$PKGVER"

build_package "${VARIANT}-newlib" \
  "../${VARIANT}-binutils/${VARIANT}-binutils-${BINUTILS_VER}-x86_64.pkg.tar.zst" \
  "../${VARIANT}-gcc-stage1/${VARIANT}-gcc-stage1-${GCCSTAGE1_VER}-x86_64.pkg.tar.zst"
NEWLIB_VER="$PKGVER"

build_package "${VARIANT}-gcc" \
  "../${VARIANT}-binutils/${VARIANT}-binutils-${BINUTILS_VER}-x86_64.pkg.tar.zst" \
  "../${VARIANT}-newlib/${VARIANT}-newlib-${NEWLIB_VER}-${NEWLIB_ARCH}.pkg.tar.zst"

build_package "${VARIANT}-gdb"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
echo
echo "========== BUILD SUMMARY =========="

echo "Built (${#BUILT[@]}):"
printf '  - %s\n' "${BUILT[@]:-none}"

echo
echo "Skipped (${#SKIPPED[@]}):"
printf '  - %s\n' "${SKIPPED[@]:-none}"

echo
echo "Failed (${#FAILED[@]}):"
printf '  - %s\n' "${FAILED[@]:-none}"

echo "==================================="

[[ ${#FAILED[@]} -gt 0 ]] && exit 1
