#!/bin/bash

set -e
set -o pipefail  # Bashism

PARDUS_DIST="onyedi"
PARDUS_VARIANT="XFCE"
PARDUS_VERSION="17.1"
TARGET_DIR="/var/images"
TARGET_SUBDIR=""
SUDO="sudo"
VERBOSE=""
HOST_ARCH=$(dpkg --print-architecture)
TIMESTAMP=$(date +"%Y%m%d%H%M")

bin_exits() {
	hash $1 2>/dev/null
}

scm_version() {
	local head=""

	if ! bin_exits git; then
		return
	fi

	if test -z "$(git rev-parse --show-cdup 2>/dev/null)" &&
		head=`git rev-parse --verify --short HEAD 2>/dev/null`; then
		printf '%s%s' -g $head

		if [ -n "$(git diff-index --name-only HEAD)" ]; then
			printf '%s\n' +
		fi
	fi
}

image_name() {
	local arch=$1

	case "$arch" in
		i386|amd64)
			IMAGE_TEMPLATE="live-image-ARCH.hybrid.iso"
		;;
		armel|armhf)
			IMAGE_TEMPLATE="live-image-ARCH.img"
		;;
	esac
	echo $IMAGE_TEMPLATE | sed -e "s/ARCH/$arch/"
}

target_image_name() {
	local arch=$1
	local scm_v=$(scm_version)

	IMAGE_NAME="$(image_name $arch)"
	IMAGE_EXT="${IMAGE_NAME##*.}"
	if [ "$IMAGE_EXT" = "$IMAGE_NAME" ]; then
		IMAGE_EXT="img"
	fi
	if [ "$PARDUS_VARIANT" = "default" ]; then
		echo "${TARGET_SUBDIR:+$TARGET_SUBDIR/}Pardus-$PARDUS_VERSION-$PARDUS_ARCH-$TIMESTAMP$scm_v.$IMAGE_EXT"
	else
		echo "${TARGET_SUBDIR:+$TARGET_SUBDIR/}Pardus-$PARDUS_VARIANT-$PARDUS_VERSION-$PARDUS_ARCH-$TIMESTAMP$scm_v.$IMAGE_EXT"
	fi
}

target_build_log() {
	TARGET_IMAGE_NAME=$(target_image_name $1)
	echo ${TARGET_IMAGE_NAME%.*}.log
}

default_version() {
	case "$1" in
	    pardus-*)
		echo "${1#pardus-}"
		;;
	    *)
		echo "$1"
		;;
	esac
}

failure() {
	# Cleanup update-pardus-menu that might stay around so that the
	# build chroot can be properly unmounted
	$SUDO pkill -f update-pardus-menu || true
	echo "Build of $PARDUS_DIST/$PARDUS_VARIANT/$PARDUS_ARCH live image failed (see build.log for details)" >&2
	exit 2
}

run_and_log() {
	if [ -n "$VERBOSE" ]; then
		"$@" 2>&1 | tee -a build.log
	else
		"$@" >>build.log 2>&1
	fi
	return $?
}

. $(dirname $0)/.getopt.sh

# Parsing command line options
temp=$(getopt -o "$BUILD_OPTS_SHORT" -l "$BUILD_OPTS_LONG,get-image-path" -- "$@")
eval set -- "$temp"
while true; do
	case "$1" in
		-d|--distribution) PARDUS_DIST="$2"; shift 2; ;;
		-p|--proposed-updates) OPT_pu="1"; shift 1; ;;
		-a|--arch) PARDUS_ARCHES="${PARDUS_ARCHES:+$PARDUS_ARCHES } $2"; shift 2; ;;
		-v|--verbose) VERBOSE="1"; shift 1; ;;
		-s|--salt) shift; ;;
		--variant) PARDUS_VARIANT="$2"; shift 2; ;;
		--version) PARDUS_VERSION="$2"; shift 2; ;;
		--subdir) TARGET_SUBDIR="$2"; shift 2; ;;
		--get-image-path) ACTION="get-image-path"; shift 1; ;;
		--) shift; break; ;;
		*) echo "ERROR: Invalid command-line option: $1" >&2; exit 1; ;;
        esac
done

# Set default values
PARDUS_ARCHES=${PARDUS_ARCHES:-$HOST_ARCH}
if [ -z "$PARDUS_VERSION" ]; then
	PARDUS_VERSION="$(default_version $PARDUS_DIST)"
fi

# Check parameters
for arch in $PARDUS_ARCHES; do
	if [ "$arch" = "$HOST_ARCH" ]; then
		continue
	fi
	case "$HOST_ARCH/$arch" in
		amd64/i386|i386/amd64)
		;;
		*)
			echo "Can't build $arch image on $HOST_ARCH system." >&2
			exit 1
		;;
	esac
done
if [ ! -d "$(dirname $0)/pardus-config/variant-$PARDUS_VARIANT" ]; then
	echo "ERROR: Unknown variant of Pardus configuration: $PARDUS_VARIANT" >&2
fi

# Build parameters for lb config
PARDUS_CONFIG_OPTS="--distribution $PARDUS_DIST -- --variant $PARDUS_VARIANT"
if [ -n "$OPT_pu" ]; then
	PARDUS_CONFIG_OPTS="$PARDUS_CONFIG_OPTS --proposed-updates"
	PARDUS_DIST="$PARDUS_DIST+pu"
fi

# Set sane PATH (cron seems to lack /sbin/ dirs)
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Either we use a git checkout of live-build
# export LIVE_BUILD=/srv/cdimage.pardus.org/live/live-build

# Or we ensure we have proper version installed
ver_live_build=$(dpkg-query -f '${Version}' -W live-build)
if dpkg --compare-versions "$ver_live_build" lt 1:20151215pardus1; then
	echo "ERROR: You need live-build (>= 1:20151215pardus1), you have $ver_live_build" >&2
	exit 1
fi
if ! echo "$ver_live_build" | grep -q pardus; then
	echo "ERROR: You need a Pardus patched live-build. Your current version: $ver_live_build" >&2
	exit 1
fi

# Check we have a good debootstrap
ver_debootstrap=$(dpkg-query -f '${Version}' -W debootstrap)
if ! echo "$ver_debootstrap" | grep -q pardus; then
	echo "ERROR: You need a Pardus patched debootstrap. Your current version: $ver_debootstrap" >&2
	exit 1
fi

# We need root rights at some point
if [ "$(whoami)" != "root" ]; then
	if ! which $SUDO >/dev/null; then
		echo "ERROR: $0 is not run as root and $SUDO is not available" >&2
		exit 1
	fi
else
	SUDO="" # We're already root
fi

if [ "$ACTION" = "get-image-path" ]; then
	for PARDUS_ARCH in $PARDUS_ARCHES; do
		echo $(target_image_name $PARDUS_ARCH)
	done
	exit 0
fi

cd $(dirname $0)
mkdir -p $TARGET_DIR/$TARGET_SUBDIR

for PARDUS_ARCH in $PARDUS_ARCHES; do
  echo "Building $(target_image_name $PARDUS_ARCH)"
	IMAGE_NAME="$(image_name $PARDUS_ARCH)"
	set +e
	: > build.log
	run_and_log $SUDO lb clean --purge
	[ $? -eq 0 ] || failure
	run_and_log lb config -a $PARDUS_ARCH $PARDUS_CONFIG_OPTS "$@"
	[ $? -eq 0 ] || failure
	run_and_log $SUDO lb build
	if [ $? -ne 0 ] || [ ! -e $IMAGE_NAME ]; then
		failure
	fi
	set -e
	mv -f $IMAGE_NAME $TARGET_DIR/$(target_image_name $PARDUS_ARCH)
	mv -f build.log $TARGET_DIR/$(target_build_log $PARDUS_ARCH)
done
