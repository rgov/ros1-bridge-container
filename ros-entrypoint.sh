#!/bin/bash
set -eo pipefail  # no -u

# Load all of the ROS environments
source /opt/ros/${ROS1_DISTRO}/setup.bash
source /opt/ros/${ROS2_DISTRO}/setup.bash
source /app/install/setup.bash
source /ros2_msgs_ws/install/local_setup.bash
source /bridge_ws/install/local_setup.bash

exec "$@"
