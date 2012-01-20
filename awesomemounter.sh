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
# so it effectively storage-balances all the involved partitions.
# This allows to simply plug a new drive when you run out of space in existing ones.
# Existing drives can also be unmounted at any time.
# 
#
# REAL WORLD EXAMPLE:
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
# Which is fine, actually, because AwesomeMounter will take care of it all!
#
# Just add the following line to your config file:
# /home/foo/music  /media/pendrive/music,/home/mldonkey/music,/mnt/windows/mydocs/music
#
# And then just run this very script.
# AwesomeMounter will then keep an eye on mounted systems, and make sure
# everything works accordingly.
#
# More info at www.stenyak.com
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


### start of configuration ###
# temporary file for storing possible error logs
errlog=$(mktemp)

# path to the configuration file (optionally passed as first parameter)
cfg="$HOME/.awesomemounter/config"
if [ ! -z $1 ]
then
    cfg=$1
fi
test

### start of helper functions ###
# should be run before exiting, but can be run at any time
# will clean up all temporary files, and show any possible error logs if the first parameter is != 0
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

# allows to check the return code of a command, and act in consequence.
# first param should be $LINENO, for debugging purposes
# second param should be the error code, typically $? right after execution of command
# third param is the error message to be displayed if necessary
# fourth param can be omitted, should be "force" if an error should exit the whole program
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
        # print the offending line of bash code that crashed
        #echo "$file:$line: Code: $(cat $file |head -n $line |tail -n 1)"
        clean 1
        # exit if necessary
        if [ "$force" == "force" ]
        then
            exit $err
        fi
    fi
}

# checks whether the specified program is installed on the system or not
# if program is not installed, it exits.
function checkprg()
{
    local prg=$1
    if ! which $prg >/dev/null
    then
        check $(($LINENO-1)) 1 "Program $prg not found. Please install it and re-run'" "force"
    fi
}

# given a CSV string of directories, return a CSV string with those that actually exist
# (or empty string if none exists)
function filterExistingDirs()
{
    local mntdirs="$1"
    local result=""
    local IFSOLD=$IFS
    IFS=$','
    for i in $mntdirs
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

# given a mount point, find out whether it's mounted at least one time, as reported by mtab
function ismounted()
{
    local mntpoint="$1"
    cat /etc/mtab |awk '{ print $2 }' |grep "^$mntpoint$" &>$errlog
    return $?
}

# given a mount point, find out if the mounted directories are exactly those specified
# in the CSV string of directories passed as second parameter
function hasmounted()
{
    local mntpoint="$1"
    local mntdirs="$2"
    local realmntdirs="$(cat /etc/mtab |grep " $mntpoint "|awk '{ print $1 }' |sed "s/;/,/g")"
    test "$realmntdirs" != "$mntdirs"
    local result=$?
    if [ $result -eq 0 ]
    then
        : echo "Mounted with incorrect dirs"
    fi
    return $result
}

# helper function to print a pretty log message on console
function inf()
{
    echo ">>> $(date): $*"
}

# will mount the provided mount dir/s (first param) in the mount dir (second param)
# if the mount dir are none, do nothing
# if the mount dir is a single one, use --bing
# if the mount dirs are many, use mhddfs with storage balancing enabled
function magicmount()
{
    local mntdirs=$1
    local mntpoint=$2
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
        : echo "nothing to mount at $mntpoint"
    fi
    if [ "$count" -eq 1 ]
    then
        inf "mounting just one dir ($mntdirs) with bind at $mntpoint"
        mkdir -p $mntpoint
        mount --bind $mntdirs $mntpoint  &>$errlog
        check $LINENO $? "couldn't mount '$mntpoint'"
    fi
    if [ "$count" -gt 1 ]
    then
        inf "mounting several dirs ($mntdirs) at $mntpoint"
        mkdir -p $mntpoint
        mhddfs $mntdirs $mntpoint -o allow_other,mlimit=1024G &>$errlog
        check $LINENO $? "couldn't mount '$mntpoint'"
    fi
}

# make sure the specified directory is mounted *zero* times
# (because there could be several bind mounts to the same point)
function magicumount()
{
    local mntpoint=$1
    while ismounted $mntpoint
    do
        inf "umounting $mntpoint"
        umount $mntpoint &>$errlog
        check $LINENO $? "couldn't umount '$mntpoint'"
    done
}

# high level manager of mount points
# first param: the mount point
# second param: the mount directory/ies
# it makes sure that the final state of the mount is the desired one.
# for that, it'll umount/remount/mount stuff if needed
function magicremount()
{
    local mntpoint=$1
    local mntdirs=$2
    mntdirs=$(filterExistingDirs $mntdirs)
    if ismounted $mntpoint
    then
        if hasmounted $mntpoint $mntdirs
        then
            inf "$mntpoint mount has changed. Remounting now"
            magicumount $mntpoint
        else
            : echo ">>> $mntpoint mount is correct. Nothing to do"
        fi
    else
        : echo ">>> $mntpoint mount does not exist. Mounting now"
    fi
    if ! ismounted $mntpoint
    then
        magicmount "$mntdirs" "$mntpoint"
    fi
}

### start of main program code ###

# make sure all dependencies are met before starting
checkprg sudo
checkprg awk
checkprg sed
checkprg mhddfs
checkprg inotifywait

# switch to root user (using sudo) if not already
# (but use the configuration file of the user that initially run the program)
if [ "$(whoami)" != "root" ]
then
    echo "I'm sorry, $(whoami). I'm afraid I can't do that. Trying to get root access..."
    sudo $0 $cfg
    clean 0
    exit 0
fi
echo ">>> Starting AwesomeMounter"

# main loop, monitor mount actions, and do stuff according to the configuratino file
while true
do
    # always reload configuration, no need to restart AwesomeMounter (because it's awesome)
    test -f $cfg
    check $LINENO $? "couldn't open configuration file '$cfg'" "force"

    # process config file lines, one by one
    IFSOLD=$IFS
    IFS=$'\n'
    for i in $(cat $cfg)
    do
        #skip comment lines
        if [ "$(echo $i |sed "s/^\s*//g" |cut -c -1)" == "#" ]; then continue; fi
        #skip empty lines
        if [ "$(echo $i |sed "s/^\s*//g" |wc -c)" -le "1" ]; then continue; fi
        # find out mount point and mount dirs
        mntpoint=$(echo $i |sed "s/\s\s*.*$//g")
        mntdirs=$(echo $i |sed "s/^.*\s\s*//g")
        # apply the mount to the system
        magicremount $mntpoint $mntdirs
    done
    IFS=$IFSOLD

    # wait for 5 seconds for mount actions, otherwise restart the loop for a rutinary check
    inotifywait -t 5 -q /mnt /media &>$errlog
done

echo ">>> Terminating AwesomeMounter"
exit 0
