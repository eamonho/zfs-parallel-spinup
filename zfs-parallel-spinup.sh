#!/bin/bash
#
# ZFS Parallel Spinup Monitor
# Version .5
#
# Requirements: Solaris and some SATA ZFS arrays connected to LSI controllers (NAPP-IT AIO basically).  Might work with other controllers and drives.
#               sdparm compiled and installed somewhere. http://sg.danny.cz/sg/sdparm.html
#
# Known issues:  There isn't a simple way to distinguish the sleep command issued by the OS from other activity so the script won't parallel spin up
# during a 30 second window right before a drive is scheduled to go idle.
#               Probably not the most green way of doing this, but it's better than waiting for someone else to fix it..
#               Might draw too much power if you have a really big array, and a small PSU.  No spinup groups.
#
# TBD:  Put the rest of the data in arrays and drop the temp dir, works well enough we don't those spinup scripts.
#       Find a better way to detect access activity (dtrace?)
#
# Any ideas and improvements?  Send to eamon.ho@gmail.com
#

#Temp folder to write some temp data.
DIR="/pools"
mkdir $DIR 2> /dev/null

#Location of sdparm utility
SDPARM="/usr/local/bin/sdparm"

#Cycle time is how often it samples for disk activity.  Keep it at 1 for fast response times, unless you're using a Transmeta Crusoe or something horrible.
CYCLE_TIME=1

#Sleepthreshold is probably a bad name.  This is a window before the schedule sleep time in which the monitor will ignore any disk I/O.  This is because the OS will send sleep instructions to your disks and we don't want to count it as activity and reset the idle counter.
SLEEPTHRESHOLD=30
declare -A DISKS
declare -A SLEEP
declare -A IDLE
declare -A POOLS

function prepare_spinup() {

        zpool list -H | grep -v rpool | cut -f 1 | while read ZPOOL; do
                POOLS[$ZPOOL]=$ZPOOL
        done

        zpool list -H | grep -v rpool | cut -f 1 > $DIR/POOLS
        while read POOL; do

                #Write a spinup script for this array
                zpool status $POOL | grep -A 100 NAME | tail +4 | grep ONLINE | tr -d "\t" | tr " " "\n" | grep -v -e ONLINE -e ^0$ -e ^$ | sed s_^_/usr/local/bin/sdparm\ -C\ start\ /dev/rdsk/_g | sed s/$/\ +/g | tr "+" "&" > $DIR/$POOL

                #Write the disk to pool mapping into an array
                while read LINE; do
                        DISK=`echo "$LINE" | cut -d "/" -f 8 | cut -d " " -f 1 `
                        #echo "Disk: $DISK"
                        #Associate disk to a pool
                        DISKS[$DISK]=$POOL
                        #Tag the disk as active
                        IDLE[$DISK]=0
                        #Get the current sleep setting (in seconds!) from power.conf
                        TIMEOUT=`cat /etc/power.conf | grep $DISK | tr " " "\n" | grep -v -e "^$" -e threshold -e /dev/dsk | tr -d s`

                        if [ -n "$TIMEOUT" ]; then
                                SLEEP[$DISK]=$TIMEOUT
                        else
                                SLEEP[$DISK]=0
                        fi
                done < $DIR/$POOL
                #Handy spinup script for other scripts to use to wake up your disks before writing to them.
                echo "#!/bin/bash" > $DIR/$POOL.sh
                cat $DIR/$POOL >> $DIR/$POOL.sh
        done  < $DIR/POOLS
}

prepare_spinup

function monitor_io() {
        #This tracks all I/O
        FIRSTRUN=1
        WAKE=""
        iostat -xnzr $CYCLE_TIME | while read ACTIVE; do

        #During the first run, we want to generate some IO after iostat starts so we can synchronize idle counters so we wake up the drives
        if [ $FIRSTRUN = "1" ]; then
                for IDLEDISK in "${!SLEEP[@]}"; do
                        $SDPARM -C start /dev/rdsk/$IDLEDISK > /dev/null &
                done
                FIRSTRUN=0
        fi
        #Check for device string
        echo $ACTIVE | grep "device" > /dev/null
        #if [ $? = "1" ]; then

                #Every Cycle_time we increment the idle timers for all the disks
                echo $ACTIVE | grep "extended" > /dev/null
                if [ $? = "0" ]; then
                        clear
                        for IDLEDISK in "${!SLEEP[@]}"; do
                                #Spinup disks if specified
                                if [ "$WAKE" = "${DISKS[$IDLEDISK]}" ]; then
                                        #Spinup and reset counter
                                        $SDPARM -C start /dev/rdsk/$IDLEDISK > /dev/null &
                                        IDLE[$IDLEDISK]=0
                                        echo "$IDLEDISK idle ${IDLE[$IDLEDISK]}/${SLEEP[$IDLEDISK]} array ${DISKS[$IDLEDISK]} (Spinup)"
                                else
                                        #Otherwise just show status
                                        echo "$IDLEDISK idle ${IDLE[$IDLEDISK]}/${SLEEP[$IDLEDISK]} array ${DISKS[$IDLEDISK]}"
                                        IDLE[$IDLEDISK]=$(( ${IDLE[$IDLEDISK]} + $CYCLE_TIME ))
                                fi
                        done
                        WAKE=""
                else

                        #If it's a disk access
                        ACTIVEDISK=`echo $ACTIVE | grep -v device | cut -d , -f 11`
                        if [ -n "$ACTIVEDISK" ]; then
                                #If this disk is power managed
                                if [ ${SLEEP[$ACTIVEDISK]} ]; then

                                        #If the disk is sleeping, we assume the array needs to be waken up
                                        if [ ${IDLE[$ACTIVEDISK]} -gt ${SLEEP[$ACTIVEDISK]} ]; then
                                                #Flag this array for spinup
                                                WAKE=${DISKS[$ACTIVEDISK]}
                                        fi

                                        #If the disk is  already idle
                                        if [ ${IDLE[$ACTIVEDISK]} -gt ${SLEEP[$ACTIVEDISK]} ]; then
                                                #We zero out the idle timer
                                                IDLE[$ACTIVEDISK]=0
                                        else
                                                #In the few seconds before the disk reaches its idle timeout, the OS will send a sleep command
                                                LEADTIME=$(( ${SLEEP[$ACTIVEDISK]} - ${IDLE[$ACTIVEDISK]} ))
                                                #If it's earlier than this window
                                                if [ $LEADTIME -gt $SLEEPTHRESHOLD ]; then
                                                        #We zero out the idle timer
                                                        IDLE[$ACTIVEDISK]=0
                                                fi
                                        fi
                                fi
                        fi
                fi
        #fi
        done
}
monitor_io
