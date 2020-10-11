#!/bin/bash

# backup-lv
# ---------
# Differential backups using LVM snapshots and rdiff
# (C) 2015-2019 Alexander Koch <mail@alexanderkoch.net>
#
# Released under the terms of the MIT License, see 'LICENSE'


# presets
readonly PRUNE_DAYS=14               # days to prune old backups after
readonly FULL_DAY=0                  # weekday to perform full backup on
readonly MIN_FREE=2048               # minimum free space on dest, in MB
readonly SNAP_SIZE="1G"              # space allocated for LVM snapshot
readonly LOCKD="/tmp/.lvsnap.lck"    # lock to prevent parallel execution

# check arguments
if [ $# -lt 2 ]; then
    echo "Error: insufficient arguments" >&2
    echo "Usage: $0 SOURCE DEST [full]"
    exit 1
fi
if ! [ -r "$1" ]; then
    echo "Error: unable to read source volume '$SRC'" >&2
    exit 1
fi
if ! [ -d "$2" ]; then
    echo "Error: invalid destination directory '$DST'" >&2
    exit 1
fi

function bailout() {
    [ -n "$1" ] && echo "Error: $1" >&2
    # destroy lvm snapshot if existing
    [ -e "$SNAP" ] && lvremove -f "$SNAP" >/dev/null
    # remove lock
    rmdir "$LOCKD"

    exit 1
}

function megs_free() {
    AVAIL="$(df -BM --output=avail "$1" | tail -n 1 | tr -d " " | tr -d "M")"
    if [ -z "$AVAIL" ] || ! [[ $AVAIL =~ ^[0-9]+$ ]]; then
        echo "0"
    else
        echo "$AVAIL"
    fi
}

SRC="$1"
SRC_LV="$(basename "$SRC")"
SNAP="${SRC}-snap"
SNAP_LV="$(basename "$SNAP")"
STAMP="$(date +%F)"
DST="$2"
DST_FULL="${DST}/${STAMP}-${SRC_LV}.full.bz2"
DST_FULL_SIG="${DST_FULL%.bz2}.sig"
DST_DIFF="${DST}/${STAMP}-${SRC_LV}.diff.bz2"


# check required utilities
export PATH="/usr/bin:/usr/sbin:/bin:/sbin:/usr/local/sbin"
which lvcreate >/dev/null || bailout "'lvcreate' missing"
which rdiff >/dev/null || bailout "'rdiff' missing"
which pbzip2 >/dev/null || bailout "'pbzip2' missing"

# prevent parallel execution
if ! mkdir "$LOCKD"; then
    echo "Error: lock '$LOCKD' present, aborting." >&2
    exit 1
fi

# check free space
FREE=$(megs_free "$DST")
if [ $FREE -lt $MIN_FREE ]; then
    bailout "out of space on backup destination ($FREE MB available)"
fi

# create snapshot
lvcreate -n "$SNAP_LV" -L $SNAP_SIZE -s "$SRC" >/dev/null || bailout \
    "failed to create LVM snapshot"

# perform backup
if [ "$3" == "full" ] || [ "$(date +%w)" == "$FULL_DAY" ]; then
    # full backup
    tty -s && echo "dumping image: '$DST_FULL'"
    pbzip2 -c < "$SNAP" > "$DST_FULL"
    if [ $? -ne 0 ]; then
        rm -f "$DST_FULL"
        bailout "failed to dump image"
    fi
    tty -s && echo "creating signature: '$DST_FULL_SIG'"
    rdiff signature "$SNAP" "$DST_FULL_SIG"
    if [ $? -ne 0 ]; then
        rm -f "$DST_FULL" "$DST_FULL_SIG"
        bailout "failed to create signature"
    fi
else
    # incremental backup
    SIG="$(ls -1 "${DST}/"*"-${SRC_LV}.full.sig" | tail -n 1)"
    if [ -z "$SIG" ]; then
        bailout "no full image found for reference"
    fi
    tty -s && echo "creating delta: '$DST_DIFF'"
    rdiff delta "$SIG" "$SNAP" | pbzip2 -c > "$DST_DIFF"
    if [ $? -ne 0 ]; then
        rm -f "$DST_DIFF"
        bailout "failed to create delta"
    fi
fi

# destroy LVM snapshot
lvremove -f "$SNAP" >/dev/null || bailout "failed to destroy snapshot"

# prune old backups
find "$DST" -type f -name "*-${SRC_LV}.diff.bz2" -mtime +$PRUNE_DAYS -delete || \
    bailout "failed to prune old backups"
FULL_DAYS=$(($PRUNE_DAYS + $(date +%w) - $FULL_DAY)) 
find "$DST" -type f -name "*-${SRC_LV}.full.*" -mtime +$FULL_DAYS -delete || \
    bailout "failed to prune old backups"

# clean up
rmdir "$LOCKD"

exit 0

# vim: ts=4 et
