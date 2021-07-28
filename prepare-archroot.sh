#!/usr/bin/env bash
# Prepare a chroot to build packages.
LOCATION=$HOME/build/arch_chroot

usage() {
    echo "Usage: prepare_chroot.sh [ -o | --chroot-location]"
}

invalid_usage() {
    usage
    exit 2
}

PARSED_ARGUMENTS=$(getopt -a -n prepare_chroot -o o: --long chroot-location: -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
    invalid_usage
fi

eval set -- "$PARSED_ARGUMENTS"
while :
do
    case "$1" in
	-o | --chroot-location)
	    LOCATION="$2"
	    shift;
	    ;;
	--)
	    shift;
	    break;;
	*)
	    echo "Unexpected option $1 - this should not happen."
	    invalid_usage;;
    esac
done

mkdir -p $LOCATION
mkarchroot -C /etc/pacman.conf -M /etc/makepkg.conf $LOCATION/root base-devel


