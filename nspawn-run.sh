#!/bin/bash

# nspawn-run
# ----------
# systemd-nspawn wrapper for volatile containers
# (C) 2020 Alexander Koch <mail@alexanderkoch.net>
#
# Released under the terms of the MIT License, see 'LICENSE'

# WARNING: This script relies on a proper 'sudo' setup to prevent users from
#          switching to arbitrary UIDs! Make sure to include 'NOSETENV' in the
#          corresponding line in /etc/sudoers, e.g.:
#
#          %users  ALL=(root) NOPASSWD:NOSETENV: /usr/local/bin/nspawn-run


readonly CONTAINER_BASE="/var/lib/machines"
readonly CONTAINER_SHELL="bash"

function print_usage() {
    echo "Usage: $0 [OPTIONS] COMMAND"
    echo "    COMMAND    Command(s) to execute, may contain shell globs"
    echo "Options:"
    echo "    -n NAME     Name of the container to run in (required)"
    echo "    -a ARCH     Architecture: x86 or x86-64 (default: native)"
    echo "    -h          Display this usage information"
}


# transparently run via 'sudo' if required
if [ $(id -u) -ne 0 ]; then
    exec sudo "$0" "$@"
fi

# parse cmdline options
while getopts ":a:n:h" OPT; do
    case "$OPT" in
        a)
            PERSONALITY="$OPTARG"
            ;;
        n)
            CONTAINER="$OPTARG"
            ;;
        h)
            print_usage
            exit 0
            ;;
        \?)
            echo "Error: invalid option: -$OPTARG." >&2
            exit 1
            ;;
        :)
            echo "Error: option -$OPTARG requires an argument." >&2
            exit 1
            ;;
    esac
done
shift $(($OPTIND - 1))

# support only a single command expression
if [ $# -gt 1 ]; then
    echo "Error: excessive arguments. Try -h for help." >&2
    exit 1
fi

# default to native container personality
if [ -z "$PERSONALITY" ]; then
    if [ "$(uname -m)" == "x86_64" ]; then
        PERSONALITY="x86-64"
    else
        PERSONALITY="x86"
    fi
fi

# prepare arguments for container shell
COMMAND=($CONTAINER_SHELL)
if [ $# -gt 0 ]; then
    COMMAND+=(-c)
    COMMAND+=("$1")
fi

# ensure sudo invocation for user switch inside container
if [ -z "$SUDO_USER" ]; then
    echo "Error: this script is designed to be run via sudo." >&2
    exit 1
fi

# verify container name
if [ -z "$CONTAINER" ] || ! [ -d "${CONTAINER_BASE}/${CONTAINER}" ]; then
    echo "Error: container '$CONTAINER' not found in $CONTAINER_BASE" >&2
    exit 1
fi

exec systemd-nspawn \
    --personality="$PERSONALITY" \
    --ephemeral \
    --read-only \
    --directory="${CONTAINER_BASE}/${CONTAINER}" \
    --bind-ro=/etc/passwd \
    --bind-ro=/etc/group \
    --bind=/home \
    --user="$SUDO_USER" \
    --chdir="$PWD" \
    "${COMMAND[@]}"
