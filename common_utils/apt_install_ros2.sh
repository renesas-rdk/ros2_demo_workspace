#!/bin/bash
# ------------------------------------------------------------------------------------------#
# Script to install ROS2 Jazzy on Ubuntu 24.04 LTS for ARM64 architecture
# Tested on: Ubuntu 24.04 LTS
# ------------------------------------------------------------------------------------------#

# Must be run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit
fi

export LC_ALL=C
apt update

# Set DEBIAN_FRONTEND globally
export DEBIAN_FRONTEND=noninteractive

# Setup locale
apt update && apt install locales -y
locale-gen en_US en_US.UTF-8
update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8

# Ensure that the Ubuntu Universe repository is enabled properly.
apt update && apt install software-properties-common -y
add-apt-repository universe -y

# Install curl and dpkg for downloading ROS2 APT source
apt update && apt install curl dpkg -y

# Add the repository to sources list
export ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F "tag_name" | awk -F\" '{print $4}')
curl -L -o /tmp/ros2-apt-source.deb "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo $VERSION_CODENAME)_all.deb"
dpkg -i /tmp/ros2-apt-source.deb

# Install development tools
apt update && apt install ros-dev-tools -y

# Install ROS2 Jazzy
apt update
apt install ros-jazzy-ros-base -y

echo "ROS2 installation complete!"

rosdep init
sudo -u ubuntu bash -c "source /opt/ros/jazzy/setup.bash && rosdep update --rosdistro jazzy"