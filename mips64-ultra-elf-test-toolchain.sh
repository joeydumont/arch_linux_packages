#!/usr/bin/env bash

###############################################################################
# This script is meant to build all components of the mips64-ultra-elf        #
# toolchain and test it by compiling both gz and uss64. Once that's done, I   #
# should be notified via email so that I can run the ROMs.                    #
###############################################################################

# Kill background jobs started by this script.
trap "trap - SIGTERM && kill -- -$$" SIGINT SIGTERM EXIT
set -x

# Remember PROMPT_COMMAND
export MIPS_PROMPT_COMMAND=${PROMPT_COMMAND}

# Get path to this script.
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
export CHROOT="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"/chroot

# Cache sudo credentials
sudo -v
while sleep 180; do sudo -v; done &

# Update the chroot.
arch-nspawn $CHROOT/root pacman -Syu

# Check if we want to force a rebuild of all the packages.
if [[ -z ${FORCE_REBUILD} ]]; then
  export FORCE_REBUILD=0
else
  export FORCE_REBUILD=1
fi

# some basic output functions (from Gentoo Prefix bootstrap)
eerror() { echo "!!! $*" 1>&2; }
einfo() { echo "* $*"; }

# Change xterm tab title.
push_prompt_command() {
  echo -en "\033]0; $1 \a"
}

# Revert tab title to default value.
pop_prompt_command() {
  eval "$MIPS_PROMPT_COMMAND"
}

# Extract pkgver from the PKGBUILD
get_pkgver() {
  source PKGBUILD
  echo ${pkgver}-${pkgrel}
}

check_last_build() {
  # Check that the last build was successful.
  diff <(sha256sum PKGBUILD) <(cat .last_successful_build_chksum 2> /dev/null) &>/dev/null
  return $?
}

save_last_build() {
  sha256sum PKGBUILD > .last_successful_build_chksum
}

# Build the specified package.
# $1: Directory where the PKGBUILD is.
# $2...: Built dependencies.
build_package() {
  push_prompt_command "Building $1..."
  cwd=$(pwd)
  cd "$(pwd)/$1" || ( eerror "Directory does not exist."; exit 1 )

  makepkg -o &> /dev/null

  if ! check_last_build || [[ ! ${FORCE_REBUILD} -eq 0 ]]; then
    einfo "Building $1"
    # Rebuild packages that depend on this package (assumes that invocations are done in dep order).
    export FORCE_REBUILD=1
    if [[ "$#" -eq 1 ]]; then
      makechrootpkg -c -r $CHROOT &> build.log || ( eerror "Failed to build $1"; exit 1 )
    else
      PKGS=
      for ((i = 2; i <= $#; i++));
      do
        PKGS+=" -I ${!i}"
      done

      makechrootpkg -c -r $CHROOT ${PKGS}  &> build.log || ( eerror "Failed to build $1"; exit 1 )
    fi
    save_last_build
  else
    einfo "Already built $1."
  fi

  export PKGVER=$(get_pkgver)
  cd "${cwd}" || exit 1
  pop_prompt_command
}

export VARIANT="mips64-ultra-elf"
export NEWLIB_ARCH="x86_64"
while getopts ":t:" opt; do
  case ${opt} in
    t )
      export VARIANT=$OPTARG
      export NEWLIB_ARCH=any
      ;;
    : )
      echo "Invalid option: -$OPTARG requires an argument" 1>&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))


build_package "${VARIANT}"-binutils
BINUTILS_VER=${PKGVER}

build_package "${VARIANT}"-gcc-stage1 ../"${VARIANT}"-binutils/"${VARIANT}"-binutils-"${BINUTILS_VER}"-x86_64.pkg.tar.zst
GCCSTAGE1_VER=${PKGVER}

build_package "${VARIANT}"-newlib ../"${VARIANT}"-binutils/"${VARIANT}"-binutils-"${BINUTILS_VER}"-x86_64.pkg.tar.zst ../"${VARIANT}"-gcc-stage1/"${VARIANT}"-gcc-stage1-"${GCCSTAGE1_VER}"-x86_64.pkg.tar.zst
NEWLIB_VER=${PKGVER}

build_package "${VARIANT}"-gcc ../"${VARIANT}"-binutils/"${VARIANT}"-binutils-"${BINUTILS_VER}"-x86_64.pkg.tar.zst ../"${VARIANT}"-newlib/"${VARIANT}"-newlib-"${NEWLIB_VER}"-"${NEWLIB_ARCH}".pkg.tar.zst
GCC_VER=${PKGVER}

build_package "${VARIANT}"-gdb
