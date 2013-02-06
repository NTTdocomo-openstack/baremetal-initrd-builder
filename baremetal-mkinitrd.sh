#!/bin/bash

# Copyright (c) 2012 NTT DOCOMO, INC. 
# All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

if [ $# -lt 2 ]; then
	cat <<EOF
usage: $0 OUTFILE KERNEL_VERSION [MODULE_ROOT]
EOF
	exit 1
fi

BUSYBOX=${BUSYBOX:-$(which busybox)}
if [ -z "$BUSYBOX" ]; then
	echo "busybox is not found in PATH" 1>&2
	echo "Please set environment variable BUSYBOX to path to busybox executable" 1>&2
	exit 1
fi

function fullpath() {
	local f=$1
	if [ "${f#/}" = "$f" ]; then
		echo `pwd`/"$f"
	else
		echo "$f"
	fi
}

DIR=`dirname "$0"`
INIT="$DIR/scripts/init"
FUNCTIONS_D="$DIR/scripts/d"

DEST=`fullpath "$1"`
KERNEL_VERSION=$2
MODULE_ROOT=${3:-""}
LIB_UDEV_ROOT=${4:-""}
MODULE_DIR=$MODULE_ROOT/lib/modules/$KERNEL_VERSION
FIRMWARE_DIR=$MODULE_ROOT/lib/firmware
LIB_UDEV=$LIB_UDEV_ROOT/lib/udev

if [ ! -d "$MODULE_DIR" ]; then
	echo "ERROR: kernel module directory not found at $MODULE_DIR"
	return 1
fi

INITRD_DIR=`mktemp -t -d baremetal-mkinitrd.XXXXXXXX`
if [ $? -ne 0 ]; then
	exit 1
fi
function cleanup() {
	rm -r "$INITRD_DIR"
}
trap cleanup EXIT
echo "working in $INITRD_DIR"

mkdir -p "$INITRD_DIR/bin"
ln -s bin "$INITRD_DIR/sbin"
mkdir -p "$INITRD_DIR/lib"
ln -s lib "$INITRD_DIR/lib64"
mkdir -p "$INITRD_DIR/lib/modules"
mkdir -p "$INITRD_DIR/etc"
mkdir -p "$INITRD_DIR/etc/udev"
mkdir -p "$INITRD_DIR/lib/udev/rules.d"

cp -a "$LIB_UDEV/rules.d/50-firmware.rules" "$INITRD_DIR/lib/udev/rules.d"
cp -a "$LIB_UDEV/rules.d/80-drivers.rules" "$INITRD_DIR/lib/udev/rules.d"
cp -a "$LIB_UDEV/firmware" "$INITRD_DIR/lib/udev"

mkdir -p "$INITRD_DIR/etc/modprobe.d"
echo "blacklist evbug" > "$INITRD_DIR/etc/modprobe.d/blacklist.conf"

mkdir -p "$INITRD_DIR/etc/udev"
cat >"$INITRD_DIR/etc/udev/udev.conf" <<EOF
udev_root="/dev"
udev_rules="/lib/udev/rules.d"
udev_log="no"
EOF

function copy_link_so() {
  local name path 
  local IFS="
"
  ldd_out=`ldd "$1"`
  if [ $? -ne 0 ]; then
    return
  fi
  for i in `echo "$ldd_out" | sed -e 's/^\t*//'`; do
    name=$( echo "$i" | awk -F '[ ]' '{print $1}')
    path=$( echo "$i" | awk -F '[ ]' '$2 == "=>" {print $3}
                                      $2 != "=>" {print $1}')
    if [ -z "$path" ]; then
      continue
    fi
    if [ "$name" != "${name#/}" ]; then
      # name is an absolute path
      if [ `dirname "$name"` != "/lib" ]; then
        mkdir -p "$INITRD_DIR/"`dirname $name`
        if ! [ -e "$INITRD_DIR/$name" ]; then
          ln -s /lib/`basename $path` "$INITRD_DIR/$name"
        fi
      fi
    fi
    cp -Ln "$path" "$INITRD_DIR/lib"
  done
}

for i in "$BUSYBOX" "$LIB_UDEV/firmware" bash modprobe udevd udevadm wget tgtd tgtadm reboot shutdown; do
	if "$BUSYBOX" --list | grep "^$i\$" >/dev/null; then
		continue
	fi
	path=`which $i 2>/dev/null` || path=$i
	if ! [ -x "$path" ]; then
		echo "$i is not found in PATH" 2>&1
		exit 1
	fi
	cp -L "$path" "$INITRD_DIR/bin/"
	copy_link_so "$path"
done

for i in $( "$BUSYBOX" --list ); do
	if [ -f "$INITRD_DIR/bin/$i" ]; then
		echo "skip $i"
		continue
	fi
	ln -s busybox "$INITRD_DIR/bin/$i"
done

cp -a "$MODULE_DIR" "$INITRD_DIR/lib/modules/$KERNEL_VERSION"

cp -a "$FIRMWARE_DIR" "$INITRD_DIR/lib/firmware"

cp "$INIT" "$INITRD_DIR/init"
chmod +x $INITRD_DIR/init
rm -f "$INITRD_DIR/bin/init"
for F in "$FUNCTIONS_D"/* ; do
	cp "$F" "$INITRD_DIR"
done

(cd "$INITRD_DIR"; find . | cpio -o -H newc | gzip > "$DEST" )

