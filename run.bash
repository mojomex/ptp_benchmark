#!/usr/bin/bash

if [ $# -ne 1 ]; then
  echo "Usage: $0 <scenario_name>"
  exit 1
fi

scenario_dir="runs/$1"

if [ -d "$scenario_dir" ]; then
  read -p "Run $1 already exists, overwrite? (y/n) " -n1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$scenario_dir"
  else
    exit 1
  fi
fi

mkdir -p "$scenario_dir"
base_dir=$PWD
cd "$scenario_dir" || exit 1

if ! (ros2 pkg list | grep nebula_ros >/dev/null); then
  echo "Nebula workspace is not sourced, exiting."
  exit 1
fi

ps -aux >running_processes.log
if grep -q ptp4l running_processes.log; then
  echo "Found already running PTP4L instance, exiting."
  exit 1
fi

if grep -q phc2sys running_processes.log; then
  echo "Found already running PHC2Sys instance, exiting."
  exit 1
fi

echo "Requesting sudo privileges..."
sudo echo "Ok."

echo "Stopping NTP synchronization (chronyd)..."
sudo systemctl stop chronyd

if [ "$(ps -aux | grep chronyd | wc -l)" -ne 1 ]; then
  echo "Tried to stop chronyd but it is still running, exiting."
  exit 1
fi

echo "OK."

tag_runner="  [RUNNER]"
tag_ptp4l="   [PTP4L]"
tag_phc2sys=" [PHC2SYS]"
tag_nebula="  [NEBULA]"
tag_phc_ctl=" [PHC_CTL]"

echo "${tag_runner}Started runner."
echo "${tag_runner}Starting PTP server (PTP4L)..."
# shellcheck disable=SC2024
sudo ptp4l -2 -i enp7s0f1 -f /usr/share/doc/linuxptp/configs/automotive-master.cfg -m -l7 2>&1 | tee ptp4l.log | sed "s/^/$tag_ptp4l/" &

echo "${tag_runner}Starting PTP <-> system clock sync (PHC2SYS)..."
# shellcheck disable=SC2024
sudo phc2sys -c /dev/ptp2 -s CLOCK_REALTIME -R 10 -O 0 -m -l7 2>&1 | tee phc2sys.log | sed "s/^/$tag_phc2sys/" &

sudo bash -c "$base_dir/log_clock_times.bash clock_times.csv" &
pid_log_clock=$!

echo "${tag_runner}Starting Rosbag recording..."
bash -i -c 'ros2 bag record -o rosbag -s mcap --regex '\''.*?diff_sensor_system_ms$'\'' 2>&1 | tee rosbag.log | sed "s/^/  [ROSBAG]/"' &

echo "${tag_runner}Starting Nebula (OT128)..."
ros2 launch nebula_ros hesai_launch_all_hw.xml sensor_model:=Pandar128E4X 2>&1 | tee ot.log | sed "s/^/$tag_nebula/" &

echo "${tag_runner}Waiting 10s for Nebula start & PTP convergence..."
sleep 10s
n_repetitions=5
echo "${tag_runner}Running test pattern $n_repetitions times..."
for i in $(seq 1 $n_repetitions); do
  echo "${tag_runner}- Iteration $i / $n_repetitions"
  # shellcheck disable=SC2024
  sudo phc_ctl /dev/ptp2 -- get adj 1 get wait 10 adj -1 get wait 10 | tee -a phc_ctl.log | sed "s/^/$tag_phc_ctl/"
done
echo "${tag_runner}Done. Stopping processes..."

kill_and_wait() {
  local process_name="$1"
  local i=0
  local sig=2

  while [ "$(pgrep -f "$process_name" | wc -l)" -ne 0 ]; do
    echo "${tag_runner}Killing $process_name..."
    sudo pkill "-$sig" -f "$process_name"
    sleep 1s
    i=$((i + 1))
    if [ $i -ge 5 ]
    then
      sig=9
    fi
  done
  echo "${tag_runner}Killed  $process_name."
}

kill_and_wait "nebula"
kill_and_wait "ros2 bag record"
kill_and_wait "phc2sys"
kill_and_wait "ptp4l"
kill -15 "$pid_log_clock"

echo "${tag_runner}Starting NTP synchronization (chronyd) again..."
sudo systemctl start chronyd | sed "s/^/$tag_runner/"

echo "${tag_runner}Done."
