#!/bin/ksh -p
# SPDX-License-Identifier: CDDL-1.0
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License (the "License").
# You may not use this file except in compliance with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or https://opensource.org/licenses/CDDL-1.0.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
#
# Copyright (c) 2017 by Intel Corporation. All rights reserved.
#

. $STF_SUITE/include/libtest.shlib
. $STF_SUITE/tests/functional/fault/fault.cfg

#
# DESCRIPTION:
# Testing Fault Management Agent ZED Logic - Automated Auto-Replace Test.
#
# STRATEGY:
# 1. Update /etc/zfs/vdev_id.conf with scsidebug alias for a persistent path.
#    This creates keys ID_VDEV and ID_VDEV_PATH and set phys_path="scsidebug".
# 2. Create a pool and set autoreplace=on (auto-replace is opt-in)
# 3. Export the pool
# 4. Wipe and offline the scsi_debug disk
# 5. Import the pool with missing disk
# 6. Re-online the wiped scsi_debug disk
# 7. Verify ZED detects the new blank disk and replaces the missing vdev
# 8. Verify that the scsi_debug disk was re-partitioned
#
# Creates a raidz1 zpool using persistent /dev/disk/by-vdev path names
# (ie not /dev/sdc)
#
# Auto-replace is opt in, and matches by phys_path.
#

verify_runnable "both"

if ! is_physical_device $DISKS; then
	log_unsupported "Unsupported disks for this test."
fi

function cleanup
{
	zpool status $TESTPOOL
	destroy_pool $TESTPOOL
	sed -i '/alias scsidebug/d' $VDEVID_CONF
	unload_scsi_debug
}

log_assert "Testing automated auto-replace FMA test"
log_onexit cleanup

load_scsi_debug $SDSIZE $SDHOSTS $SDTGTS $SDLUNS '512b'
SD=$(get_debug_device)
SD_DEVICE_ID=$(get_persistent_disk_name $SD)
SD_HOST=$(get_scsi_host $SD)

# Register vdev_id alias for scsi_debug device to create a persistent path
echo "alias scsidebug /dev/disk/by-id/$SD_DEVICE_ID" >>$VDEVID_CONF
block_device_wait

SD_DEVICE=$(udevadm info -q all -n $DEV_DSKDIR/$SD | \
    awk -F'=' '/ID_VDEV=/ {print $2; exit}')
[ -z $SD_DEVICE ] && log_fail "vdev rule was not registered properly"

log_must zpool events -c
log_must zpool create -f $TESTPOOL raidz1 $SD_DEVICE $DISK1 $DISK2 $DISK3

# Auto-replace is opt-in so need to set property
log_must zpool set autoreplace=on $TESTPOOL

# Add some data to the pool
log_must zfs create $TESTPOOL/fs
log_must fill_fs /$TESTPOOL/fs 4 100 4096 512 Z
log_must zpool export $TESTPOOL

# Record the partition UUID for later comparison
part_uuid=$(udevadm info --query=property --property=ID_PART_TABLE_UUID \
    --value /dev/disk/by-id/$SD_DEVICE_ID)
[[ -z "$part_uuid" ]] || log_note original disk GPT uuid ${part_uuid}

#
# Wipe and offline the disk
#
# Note that it is not enough to zero the disk to expunge the partitions.
# You also need to inform the kernel (e.g., 'hdparm -z' or 'partprobe').
#
# Using partprobe is overkill and hdparm is not as common as wipefs. So
# we use wipefs which lets the kernel know the partition was removed
# from the device (i.e., calls BLKRRPART ioctl).
#
log_must dd if=/dev/zero of=/dev/disk/by-id/$SD_DEVICE_ID bs=1M count=$SDSIZE
log_must /usr/sbin/wipefs -a /dev/disk/by-id/$SD_DEVICE_ID
remove_disk $SD
block_device_wait

# Re-import pool with drive missing
log_must zpool import $TESTPOOL
log_must check_state $TESTPOOL "" "DEGRADED"
block_device_wait

# Online an empty disk in the same physical location
insert_disk $SD $SD_HOST

# Wait for the new disk to be online and replaced
log_must wait_vdev_state $TESTPOOL "scsidebug" "ONLINE" 60
log_must wait_replacing $TESTPOOL 60

# Validate auto-replace was successful
log_must check_state $TESTPOOL "" "ONLINE"

#
# Confirm the partition UUID changed so we know the new disk was relabeled
#
# Note: some older versions of udevadm don't support "--property" option so
# we'll # skip this test when it is not supported
#
if [ ! -z "$part_uuid" ]; then
	new_uuid=$(udevadm info --query=property --property=ID_PART_TABLE_UUID \
	    --value /dev/disk/by-id/$SD_DEVICE_ID)
	log_note new disk GPT uuid ${new_uuid}
	[[ "$part_uuid" = "$new_uuid" ]] && \
	    log_fail "The new disk was not relabeled as expected"
fi

log_pass "Auto-replace test successful"
