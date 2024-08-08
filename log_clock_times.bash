#!/usr/bin/bash

if [ $# -ne 1 ]; then
  echo "Usage: $0 <filename>"
  exit 1
fi

mkdir -p "$(dirname "$1")" || exit 1

echo "system_clock,ptp,diff_sys_ptp" > "$1"
while true; do
  sys_time=$(date -u "+%s.%N")
  ptp_time=$(sudo phc_ctl /dev/ptp2 get -q | awk '{print $5}')
  diff=$(bc -l <<< "$sys_time - $ptp_time")
  echo "$sys_time,$ptp_time,$diff" >> "$1"
  sleep 0.1
done
