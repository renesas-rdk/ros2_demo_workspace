# ROS 2 Demo Workspace

This repository is a lightweight bootstrap workspace for Renesas RZ/V ROS 2 demos. It does not contain the demo packages directly. Instead, it provides:

- `vcs` lock files for importing pinned demo repositories
- helper scripts for preparing a target Ubuntu system with ROS 2 Jazzy
- a Docker helper for setting up the Renesas cross-build container on a host machine

The workspace is intended to make demo setup repeatable by keeping dependency revisions fixed in `.repos` manifests.

## Repository Layout

- `common_utils/apt_install_ros2.sh`
  Installs ROS 2 Jazzy on Ubuntu 24.04 ARM64. The script is designed for target-side setup and must be run as `root`.
- `common_utils/setup_rdk_docker.sh`
  Creates and prepares a Docker container based on `ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:latest` for cross-building ROS 2 workspaces on a host machine.
- `vcs_manifests/*.lock.repos`
  Pinned import manifests for individual demos and deployment targets.

## Available Manifests

Each manifest imports a different set of repositories into `src/`.

- `hand_landmark_estimation.target.lock.repos`
  Vision inference stack for hand landmark and pose estimation on target.
- `rock_paper_scissors.target.lock.repos`
  Rock-paper-scissors demo with hand control, object detection, and dexterous hand packages.
- `static_object_detection.target.lock.repos`
  Static object detection stack built around Renesas model and detection packages.
- `vision_based_dexterous_hand.target.lock.repos`
  Vision-based dexterous hand demo packages for target deployment.
- `vision_based_robotic_arm_teleoperation.target.lock.repos`
  Full target-side teleoperation stack including arm, hand, perception, and bringup packages.
- `vision_based_robotic_arm_teleoperation.host.lock.repos`
  Host-side simulation and teleoperation dependencies, including MuJoCo-based components.

## Quick Start

For more detail, please refer to the following guides:
- [Sample Applications](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/index.html#application-development-with-rz-v2h-rdk) in the RDK online documentation.
- [First time boot setup](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-1/quick_setup_guide.html#first-time-boot-setup) for installing ROS 2 on the target.
- [Cross-build setup](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/development_guide/development_guide.html) for preparing the Docker container on a host machine.

## License

See [LICENSE](./LICENSE).
