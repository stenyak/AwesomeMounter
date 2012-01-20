#!/bin/bash
#### MANUAL ####################################################################
# NAME
#   awesomemounter.sh - automatically merges directories into a single one
#
# SYNOPSIS
#   awesomemounter.sh [configuration file]
#
# DESCRIPTION:
# This script allows to join together many directories into a single (virtual) one.
#
# Quick list of features:
#  - Any number of directories is supported (want 15 directories? no prob!)
#  - Plug-n-play is supported through inotify (e.g. an external usb pendrive)
#  - Any filesystem is supported (e.g. ext3, vfat...)
#
# Configuration must be passed in a file (default path: ~/.awesomemounter/config
#
# When writing, singles files will go to the directory with the most free space,
# so it effectively space-balances all the involved partitions.
# This allows to simply plug a new drive when you run out of space in existing ones.
# 
#
# REAl WORLD EXAMPLE:
# Premises:
#
# You have 3 directories you want to "merge":
#  - /media/pendrive/music (contains reggae and pop)
#  - /home/mldonkey/music (contains metal and pop)
#  - /mnt/windows/mydocs/music (contains hiphop)
#
# You want all those directories merged seamlessly, in a single place:
#  - /home/foo/music (should contain reggae, metal, pop and hiphop)
# 
# You do not always have the pendrive plugged in.
# Nor do is the windows partition always mounted.
# Which is fine, actually.
#
#
# 
# AUTHOR
# Written by STenyaK <stenyak@stenyak.com>.
#
# COPYRIGHT
# Copyright © 2012 Bruno Gonzalez.  License GPLv3+: GNU GPL version 3 or later <http://gnu.org/licenses/gpl.html>
# This is free software: you are free to change and redistribute it.  There is NO WARRANTY, to the extent permitted by law.
#
# REPORTING BUGS
# This script is known to work on Debian/Ubuntu based distros.
# Please report bugs to <stenyak@stenyak.com>.
################################################################################


# temporary file for storing possible error logs
errlog=$(mktemp)
cfg="$HOME/.awesomemounter/config"
if [ ! -z $1 ]
then
    cfg=$1
fi
test

# takes care of cleaning up when AwesomeMounter ends
function clean()
{
    err=$1
    if [ "$err" -ne "0" ]
    then
        echo ""
        echo -n "Execution log:"
        test -f $errlog && cat $errlog || echo "<empty>"
    fi
    rm $errlog
    return $err
}
function check()
{
    local file=$0
    local line=$(($1 - 1))
    local err=$2
    local msg=$3
    local force=$4
    if [ "$err" -ne "0" ]
    then
        echo "$file:$line: ERROR: $msg"
        #echo "$file:$line: Code: $(cat $file |head -n $line |tail -n 1)"
        clean 1
        if [ "$force" == "force" ]
        then
            exit $err
        fi
    fi
}
function checkprg()
{
    local prg=$1
    if ! which $prg >/dev/null
    then
        check $(($LINENO-1)) 1 "Program $prg not found. Please install it and re-run'"
    fi
}

checkprg sudo
checkprg awk
checkprg sed
checkprg mhddfs
checkprg inotifywait


if [ "$(whoami)" != "root" ]
then
    echo "I'm sorry, $(whoami). I'm afraid I can't do that. Trying to get root access..."
    sudo $0 $cfg
    clean 0
    exit 0
fi
function filterExistingDirs()
{
    local directories="$1"
    local result=""
    local IFSOLD=$IFS
    IFS=$','
    for i in $directories
    do
        if [ -d "$i" ]
        then
            result="$result,$i"
        fi
    done
    IFS=$IFSOLD
    local result="$(echo $result | cut -c 2-)"
    echo $result
}
function ismounted()
{
    local dir="$1"
    cat /etc/mtab |awk '{ print $2 }' |grep "^$dir$" &>$errlog
    return $?
}
function hasmounted()
{
    local dir="$1"
    local mnts="$2"
    local extcur="$(cat /etc/mtab |grep " $dir "|awk '{ print $1 }' |sed "s/;/,/g")"
    test "$extcur" != "$mnts"
    local result=$?
    if [ $result -eq 0 ]
    then
        : echo "Mounted with incorrect dirs"
    fi
    return $result
}
function inf()
{
    echo ">>> $(date): $*"
}
function magicmount()
{
    mntdirs=$1
    mntdir=$2
    local IFSOLD=$IFS
    IFS=$','
    local count=0
    for i in $mntdirs
    do
        let count=$count+1
    done
    IFS=$IFSOLD
    if [ "$count" -le 0 ]
    then
        : echo "nothing to mount at $mntdir"
    fi
    if [ "$count" -eq 1 ]
    then
        inf "mounting just one dir ($mntdirs) with bind at $mntdir"
        mkdir -p $mntdir
        mount --bind $mntdirs $mntdir  &>$errlog
        check $LINENO $? "couldn't mount '$mntdir'"
    fi
    if [ "$count" -gt 1 ]
    then
        inf "mounting several dirs ($mntdirs) at $mntdir"
        mkdir -p $mntdir
        mhddfs $mntdirs $mntdir -o allow_other,mlimit=1024G &>$errlog
        check $LINENO $? "couldn't mount '$mntdir'"
    fi
}
function magicumount()
{
    mntdir=$1
    while ismounted $mntdir
    do
        inf "umounting $mntdir"
        umount $mntdir &>$errlog
        check $LINENO $? "couldn't umount '$mntdir'"
    done
}
function magicremount()
{
    local extmnt=$1
    local extdirs=$2
    extdirs=$(filterExistingDirs $extdirs)
    if ismounted $extmnt
    then
        if hasmounted $extmnt $extdirs
        then
            inf "$extmnt mount has changed. Remounting now"
            magicumount $extmnt
        else
            : echo ">>> $extmnt mount is correct. Nothing to do"
        fi
    else
        : echo ">>> $extmnt mount does not exist. Mounting now"
    fi
    if ! ismounted $extmnt
    then
        magicmount "$extdirs" "$extmnt"
    fi
}
echo ">>> Starting AwesomeMounter"
while true
do
    test -f $cfg
    check $LINENO $? "couldn't open configuration file '$cfg'" "force"
    IFSOLD=$IFS
    IFS=$'\n'
    for i in $(cat $cfg)
    do
        #skip comment lines
        if [ "$(echo $i |sed "s/^\s*//g" |cut -c -1)" == "#" ]; then continue; fi
        #skip empty lines
        if [ "$(echo $i |sed "s/^\s*//g" |wc -c)" -le "1" ]; then continue; fi
        extmnt=$(echo $i |sed "s/\s\s*.*$//g")
        extdirs=$(echo $i |sed "s/^.*\s\s*//g")
        magicremount $extmnt $extdirs
    done
    IFS=$IFSOLD
    inotifywait -t 5 -q /mnt /media &>$errlog
done

echo ">>> Terminating AwesomeMounter"
exit 0
