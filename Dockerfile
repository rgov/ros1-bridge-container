# At least 4096 MB of RAM is recommended, e.g.,
#     podman machine set --memory 4096
#     container build --memory=4G ...
#
# It is also *highly* recommended to persist the ccache directory, e.g.,
#     podman build --volume ~/.cache/ros-bridge-ccache:/ccache:Z -t ros2-first-steps .

FROM whoi/phyto-arm:install-test AS ros1-pkg


FROM ubuntu:20.04 AS ros1-ros2-base

ENV ROS1_DISTRO=noetic
ENV ROS2_DISTRO=foxy

RUN apt-get update \
 && apt-get install -y \
        curl \
        jq \
        locales \
        software-properties-common

RUN locale-gen en_US en_US.UTF-8 \
 && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8

ENV LANG=en_US.UTF-8

RUN ROS_APT_SOURCE_VERSION=$(\
        curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
        | jq -r .tag_name) \
 && curl -L -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo $VERSION_CODENAME)_all.deb" \
 && apt-get install -y /tmp/ros2-apt-source.deb

# Also add the ROS1 apt sources
RUN echo "deb http://packages.ros.org/ros/ubuntu $(lsb_release -sc) main" \
        > /etc/apt/sources.list.d/ros1.list \
 && curl -s https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc \
        | apt-key add -

# ROS base packages
RUN apt-get update \
 && apt-get install -y \
        ros-"${ROS1_DISTRO}"-ros-base \
        ros-"${ROS2_DISTRO}"-ros-base


# Use an intermediate stage for building the ros1_bridge
FROM ros1-ros2-base AS ros1-ros2-build

# Development tools
RUN apt-get update \
 && apt-get install -y \
        ccache \
        ros-dev-tools

# Configure ccache for much faster builds
ENV PATH="/usr/lib/ccache:${PATH}"
ENV CCACHE_DIR="/ccache"
ENV CCACHE_MAXSIZE="2G"

# Clone the ros1_bridge source
RUN mkdir -p /bridge_ws/src \
 && cd /bridge_ws \
 && git clone https://github.com/ros2/ros1_bridge.git src/ros1_bridge \
 && (cd src/ros1_bridge && git checkout "${ROS2_DISTRO}" || true)

# Fix the build -- https://github.com/ros2/ros1_bridge/issues/459
RUN sed -i '/xmlrpcpp/d' /bridge_ws/src/ros1_bridge/package.xml

# Patch ros1_bridge to add converters for std_msgs/Duration and std_msgs/Time.
# https://github.com/ros2/ros1_bridge/issues/464
ADD std_msgs_converters.cpp /bridge_ws/src/ros1_bridge/src/
RUN sed -i \
    '/"src\/builtin_interfaces_factories.cpp"/a "src/std_msgs_converters.cpp"' \
    /bridge_ws/src/ros1_bridge/CMakeLists.txt

# Install system dependencies of ros1_bridge.
#
# So that our final image only contains runtime dependencies, we could also run
#     rosdep install --simulate --dependency-types exec ...
# However, it does not appear that the base image is missing any.
#
# The skipped dependencies below are taken from
# https://docs.ros.org/en/foxy/Installation/Alternatives/Ubuntu-Development-Setup.html#install-dependencies-using-rosdep
RUN rosdep init \
 && rosdep update --include-eol-distros \
 && rosdep install -y \
        --from-paths $(colcon list --paths-only --packages-up-to ros1_bridge) \
        --ignore-src \
        --skip-keys "fastcdr rti-connext-dds-6.0.1 urdfdom_headers" \
        --rosdistro "${ROS2_DISTRO}"

# Install the ros2_message_convert tool
RUN mkdir /ros2_message_convert \
 && curl -L https://github.com/rgov/ros2_convert_msg/archive/refs/heads/master.tar.gz?7 \
        | tar -xz --strip-components=1 -C /ros2_message_convert

# Copy pre-built ROS1 packages from another image.
# Must use the same path as the original build to keep pkg-config working.
COPY --from=ros1-pkg /app/install /app/install

# Find all packages and synthesize ROS2 messages for them
RUN /bin/bash -c " \
    mkdir -p /ros2_msgs_ws/src && \
    source /opt/ros/noetic/setup.bash && \
    source /app/install/setup.bash && \
    for pkg in \$(rospack list | grep '/app/install' | awk '{print \$1}'); \
    do \
        pkg_path=\$(rospack find \$pkg); \
        python3 /ros2_message_convert/convert.py \$pkg_path /ros2_msgs_ws/src/;\
    done \
    "

# Build the synthesized ROS2 messages
RUN /bin/bash -c " \
    source /opt/ros/${ROS2_DISTRO}/setup.bash && \
    cd /ros2_msgs_ws && \
    colcon build --merge-install \
    "

# Build the ros1_bridge
RUN /bin/bash -c " \
    source /opt/ros/${ROS1_DISTRO}/setup.bash && \
    source /opt/ros/${ROS2_DISTRO}/setup.bash && \
    source /app/install/setup.bash && \
    source /ros2_msgs_ws/install/local_setup.bash && \
    cd /bridge_ws && \
    MAKEFLAGS=-j1 colcon build \
        --packages-select ros1_bridge \
        --cmake-force-configure \
        --cmake-args -DCMAKE_BUILD_TYPE=Release \
        --event-handlers console_cohesion+ \
    "


# Use a clean stage and copy the build products into it
FROM ros1-ros2-base AS final

# Allow apt to autoremove packages we may not need anymore
RUN apt-mark auto \
    curl \
    jq \
    software-properties-common \
 && apt-get autoremove -y

COPY --from=ros1-ros2-build /bridge_ws/install /bridge_ws/install
COPY --from=ros1-ros2-build /app/install /app/install
COPY --from=ros1-ros2-build /ros2_msgs_ws/install /ros2_msgs_ws/install

COPY ros-entrypoint.sh /ros-entrypoint.sh
ENTRYPOINT ["/ros-entrypoint.sh"]
CMD ["ros2", "run", "ros1_bridge", "dynamic_bridge", "--bridge-all-topics"]

# Test with:
# podman run --rm -it ros2-first-steps ros2 run ros1_bridge dynamic_bridge --print-pairs
