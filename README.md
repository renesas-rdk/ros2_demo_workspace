# ROS 2 Demo Workspace

This repository is a lightweight bootstrap workspace for Renesas RZ/V and R-Car ROS 2 demos. It does not contain the demo packages directly. Instead, it provides:

- `vcs` lock files for importing pinned demo repositories
- helper scripts for preparing a target Ubuntu system with ROS 2 Jazzy
- a Docker helper for setting up the Renesas cross-build container on a host machine

The workspace is intended to make demo setup repeatable by keeping dependency revisions fixed in `.repos` manifests.

## Repository Layout

- `common_utils/apt_install_ros2.sh`
  Installs ROS 2 Jazzy on Ubuntu 24.04 ARM64. The script is designed for target-side setup and must be run as `root`.
- `common_utils/setup_rdk_docker.sh`
  Creates and prepares a Docker container based on `ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:multiarch` for cross-building ROS 2 workspaces on a Linux host (Ubuntu, MacOS).
- `common_utils/setup_rdk_docker.ps1`
  Creates and prepares a Docker container based on `ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:multiarch` for cross-building ROS 2 workspaces on a Windows host.
- `vcs_manifests/<platform>/*.lock.repos`
  Pinned import manifests for individual demos and deployment targets.

## Available Manifests

Each manifest imports a different set of repositories into `src/`:

```bash
vcs import src < vcs_manifests/rcar-v4h/rock_paper_scissors.target.lock.repos
```

Manifests are platform-specific. The two platforms use different inference
backends (`rzv_*` versus `rcar_*` packages), so a manifest from one directory
will not build the demo for the other.

### RZ/V2H (`vcs_manifests/rz-v2h/`)

- `hand_landmark_estimation.target.lock.repos`
  Vision inference stack for hand landmark and pose estimation on target.
- `queens_hand.target.lock.repos`
  Chess-playing demo: Agilex Piper arm plus hand assembly, chess piece detection,
  RealSense perception, and the behavior tree decision stack.
- `rock_paper_scissors.target.lock.repos`
  Rock-paper-scissors demo with hand control, object detection, and dexterous hand packages.
- `static_object_detection.target.lock.repos`
  Static object detection stack built around Renesas model and detection packages.
- `vision_based_dexterous_hand.target.lock.repos`
  Vision-based dexterous hand demo packages for target deployment.
- `vision_based_dexterous_hand_with_sensors.target.lock.repos`
  The dexterous hand demo extended with the SSC tactile glove and object-aware
  force thresholds, driven by the RZ/V2H pose and soft-object detection nodes.
- `vision_based_grasping.target.lock.repos`
  Behavior-tree pick-and-place with RealSense perception and RZ/V2H soft object
  detection. `renesas_vision_based_grasping` is hardware-neutral, so this manifest
  also imports both supported arm-and-hand assemblies; build with
  `--packages-up-to` to select one.
- `vision_based_robotic_arm_teleoperation.target.lock.repos`
  Full target-side teleoperation stack including arm, hand, perception, and bringup packages.
- `vision_based_robotic_arm_teleoperation.host.lock.repos`
  Host-side simulation and teleoperation dependencies, including MuJoCo-based components.

### R-Car V4H (`vcs_manifests/rcar-v4h/`)

- `hand_landmark_estimation.target.lock.repos`
  Vision inference stack for hand landmark and pose estimation on target, using
  the R-Car YOLOX + MediaPipe pose stack.
- `static_object_detection.target.lock.repos`
  Static object detection stack built around the R-Car model and YOLO detection
  packages (YOLOv5, YOLOv8, YOLOX).
- `vision_based_dexterous_hand.target.lock.repos`
  Hand landmark estimation retargeted onto a dexterous hand, using the R-Car
  YOLOX + MediaPipe pose stack. Covers the Inspire RH56, Inspire RH56E2, and
  Ruiyan RH2 hands.
- `vision_based_dexterous_hand_with_sensors.target.lock.repos`
  The dexterous hand demo extended with the SSC tactile glove and object-aware
  force thresholds, driven by the tri-cascade inference node.
- `rock_paper_scissors.target.lock.repos`
  Rock-paper-scissors demo with R-Car object detection and the three supported hands.
- `queens_hand.target.lock.repos`
  Chess-playing demo: Agilex Piper arm plus hand assembly, chess piece detection,
  RealSense perception, and the behavior tree decision stack.
- `vision_based_grasping.target.lock.repos`
  Behavior-tree pick-and-place with RealSense perception and R-Car object detection.
  `renesas_vision_based_grasping` is hardware-neutral, so this manifest also imports
  both supported arm-and-hand assemblies; build with `--packages-up-to` to select one.

## Quick Start

The following table lists the online documentation for each platform. Select the
column that matches the target hardware.

| Topic | Purpose | RZ/V2H | R-Car V4H |
| --- | --- | --- | --- |
| Sample applications | Build and run the demo applications. | [Guide](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/index.html#application-development-with-rz-v2h-rdk) | [Guide](https://renesas-rdk.github.io/rcarv4h_sh_documentation/latest/chapter-4/sample_apps/sample_apps.html) |
| First boot and target setup | Install ROS 2 on the target. | [Guide](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-1/quick_setup_guide.html#first-time-boot-setup) | [Guide](https://renesas-rdk.github.io/rcarv4h_sh_documentation/latest/chapter-1/quick_setup_guide/boot_and_first_setup.html#first-boot-and-software-setup) |
| Cross-build setup | Prepare the Docker container on a host machine. | [Guide](https://renesas-rdk.github.io/rzv2h_rdk_documentation/latest/chapter-4/development_guide/development_guide.html) | [Guide](https://renesas-rdk.github.io/rcarv4h_sh_documentation/latest/chapter-4/development_guide/development_guide.html) |

## License

See [LICENSE](./LICENSE).
