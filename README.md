# ROS2 First Steps: ROS1 Bridge Container

This project contains an example Dockerfile for building the [ros1_bridge](https://github.com/ros2/ros1_bridge) with support for custom message types.

It was tested with ROS1 Noetic and ROS2 Foxy, which both run on Ubuntu 20.04 and hence is a natural place to start on a ROS2 migration.

The build process takes a ROS1 workspace and creates a ROS2 workspace with stub packages containing only message definitions. Message definitions are converted using a fork of [ros2_convert_msg](https://github.com/CentraleNantesRobotics/ros2_convert_msg) with a few improvements.

Because upstream ros1_bridge is currently broken, the container also includes fixes for https://github.com/ros2/ros1_bridge/issues/459 and https://github.com/ros2/ros1_bridge/issues/464.

Due to heavy use of C++ template metaprogramming, ros1_bridge takes an agonizingly long time to compile. It is strongly recommended to persist the compilation cache to speed up future builds. For example:

    podman build --volume ~/.cache/ros-bridge-ccache:/ccache:Z \
        --tag ros2-first-steps .

It is also strongly recommended that you build with at least 4GB of memory allocated to the container. For example, you may need to raise the memory allocation to the podman machine VM used on macoS:

    podman machine set --memory 4096

To print the list of converted messages, you can run:

    podman run --rm -it ros2-first-steps \
        ros2 run ros1_bridge dynamic_bridge --print-pairs
