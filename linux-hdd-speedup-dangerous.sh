#!/bin/bash

# source: https://unix.stackexchange.com/questions/30286/can-i-configure-my-linux-system-for-more-aggressive-file-system-caching

echo 40 > /proc/sys/vm/dirty_ratio
echo 30 > /proc/sys/vm/dirty_background_ratio

echo 10000 > /proc/sys/vm/dirty_expire_centisecs
echo 6000 > /proc/sys/vm/dirty_writeback_centisecs
