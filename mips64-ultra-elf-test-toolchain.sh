#!/usr/bin/env bash

###############################################################################
# This script is meant to build all components of the mips64-elf-ultra        #
# toolchain and test it by compiling both gz and uss64. Once that's done, I   #
# should be notified via email so that I can run the ROMs.                    #
###############################################################################

trap 'exit 1' TERM KILL INT QUIT ABRT

# Remember PROMPT_COMMAND
export MIPS_PROMPT_COMMAND=${PROMPT_COMMAND}

# Chefk if we want to force a rebuild of all the packages.
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
  eval $MIPS_PROMPT_COMMAND
}

# Extract pkgver from the PKGBUILD
get_pkgver() {
  source PKGBUILD
  echo ${pkgver}-${pkgrel}
}

check_last_build() {
  # Check that the last build was successful.
  diff <(sha256sum PKGBUILD) <(cat .last_successful_build_chksum 2> /dev/null) &> /dev/null
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
  cd $(pwd)/$1 || ( eerror "Directory does not exist."; exit 1 )

  makepkg -o &> /dev/null
  check_last_build

  if [[ ! $? -eq 0 || ! ${FORCE_REBUILD} -eq 0 ]]; then
    # Rebuild packages that depend on this package (assumes that invocations are done in dep order).
    export FORCE_REBUILD=1
    if [[ "$#" -eq 1 ]]; then
      extra-x86_64-build &> build.log || ( eerror "Failed to build $1"; exit 1 )
    else
      PKGS=
      for ((i = 2; i <= $#; i++));
      do
        PKGS+=" -I ${!i}"
      done

      extra-x86_64-build -- ${PKGS}  &> build.log || ( eerror "Failed to build $1"; exit 1 )
    fi
    save_last_build
  else
    einfo "Already built this package."
  fi

  export PKGVER=$(get_pkgver)
  cd ${cwd}
  pop_prompt_command
}

build_package mips64-ultra-elf-binutils
BINUTILS_VER=$PKGVER

build_package mips64-ultra-elf-gcc-stage1 ../mips64-ultra-elf-binutils/mips64-ultra-elf-binutils-${BINUTILS_VER}-x86_64.pkg.tar.zst
GCCSTAGE1_VER=${PKGVER}

build_package mips64-ultra-elf-newlib ../mips64-ultra-elf-binutils/mips64-ultra-elf-binutils-${BINUTILS_VER}-x86_64.pkg.tar.zst ../mips64-ultra-elf-gcc-stage1/mips64-ultra-elf-gcc-stage1-${GCCSTAGE1_VER}-x86_64.pkg.tar.zst
NEWLIB_VER=${PKGVER}

build_package mips64-ultra-elf-gcc ../mips64-ultra-elf-binutils/mips64-ultra-elf-binutils-${BINUTILS_VER}-x86_64.pkg.tar.zst ../mips64-ultra-elf-newlib/mips64-ultra-elf-newlib-${NEWLIB_VER}-x86_64.pkg.tar.zst
GCC_VER=${PKGVER}
