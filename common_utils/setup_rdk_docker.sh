#!/usr/bin/env bash
# setup_rdk_docker.sh: quick setup script for a Docker environment used to cross-build applications for the RZ/V2H RDK
set -euo pipefail

DEFAULT_IMAGE="ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:latest"
DEFAULT_CONTAINER_NAME="ros2_cross_build_container"
DEFAULT_ROS2_WS="$HOME/ros2_ws"

IMAGE="$DEFAULT_IMAGE"
CONTAINER_NAME=""
ROS2_WS=""
AUTO_YES=0
AUTO_PULL=0
AUTO_CREATE=0
AUTO_PREP=0
AUTO_SHELL=0

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -i, --image IMAGE            Docker image
  -n, --container-name NAME    Container name
  -w, --workspace PATH         Host ROS 2 workspace path
  -y, --yes                    Non-interactive; accept yes for confirmations
      --pull                   Automatically pull/update image if needed
      --create                 Automatically create/start container if needed
      --prep                   Automatically prepare workspace
      --shell                  Open shell in container after setup
  -h, --help                   Show this help

Examples:
  $0
  $0 -n my_container -w ~/ros2_ws
  $0 -n my_container -w ~/ros2_ws -y --pull --create --prep
  $0 -n my_container -w ~/ros2_ws -y --pull --create --prep --shell
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command '$1' not found."
        exit 1
    fi
}

expand_path() {
    local path="$1"
    if [[ "$path" == "~" ]]; then
        echo "$HOME"
    elif [[ "$path" == ~/* ]]; then
        echo "$HOME/${path#~/}"
    else
        echo "$path"
    fi
}

ask_input() {
    local prompt="$1"
    local default_value="$2"
    local user_input

    read -r -p "$prompt [default: $default_value]: " user_input
    if [ -z "$user_input" ]; then
        echo "$default_value"
    else
        echo "$user_input"
    fi
}

confirm_yes() {
    local prompt="$1"
    if [ "$AUTO_YES" -eq 1 ]; then
        return 0
    fi
    local reply
    read -r -p "$prompt [Y/n]: " reply
    reply="${reply:-Y}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

confirm_no_default() {
    local prompt="$1"
    if [ "$AUTO_SHELL" -eq 1 ]; then
        return 0
    fi
    if [ "$AUTO_YES" -eq 1 ]; then
        return 1
    fi
    local reply
    read -r -p "$prompt [y/N]: " reply
    reply="${reply:-N}"
    [[ "$reply" =~ ^[Yy]$ ]]
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--image)
                IMAGE="$2"
                shift 2
                ;;
            -n|--container-name)
                CONTAINER_NAME="$2"
                shift 2
                ;;
            -w|--workspace)
                ROS2_WS="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_YES=1
                shift
                ;;
            --pull)
                AUTO_PULL=1
                shift
                ;;
            --create)
                AUTO_CREATE=1
                shift
                ;;
            --prep)
                AUTO_PREP=1
                shift
                ;;
            --shell)
                AUTO_SHELL=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Error: unknown option: $1"
                echo
                usage
                exit 1
                ;;
        esac
    done
}

parse_args "$@"

require_cmd docker
require_cmd realpath

echo "=============================================="
echo " Renesas RDK Docker Cross-Build Setup"
echo "=============================================="
echo

if [ -z "$CONTAINER_NAME" ]; then
    CONTAINER_NAME="$(ask_input "Enter container name" "$DEFAULT_CONTAINER_NAME")"
    if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        echo
        echo "A Docker container named '$CONTAINER_NAME' already exists."
        echo "Please choose a different name or remove the existing container."
        echo "To remove the existing container, use: docker rm -f $CONTAINER_NAME"
        echo "Or choose a different container name and run the script again."
        exit 1
    fi
fi

if [ -z "$ROS2_WS" ]; then
    ROS2_WS_INPUT="$(ask_input "Enter ROS 2 workspace path on host" "$DEFAULT_ROS2_WS")"
else
    ROS2_WS_INPUT="$ROS2_WS"
fi

ROS2_WS="$(realpath -m "$(expand_path "$ROS2_WS_INPUT")")"

echo
echo "Configuration:"
echo "  Docker image   : $IMAGE"
echo "  Container name : $CONTAINER_NAME"
echo "  ROS 2 workspace: $ROS2_WS"
echo

if ! confirm_yes "Proceed with this configuration?"; then
    echo "Aborted by user."
    exit 0
fi

mkdir -p "$ROS2_WS"

LOCAL_DIGEST=""
REMOTE_DIGEST=""
SHOULD_PULL=0

echo
echo "==> Checking local image..."
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Local image exists."
    LOCAL_DIGEST="$(docker image inspect "$IMAGE" --format '{{join .RepoDigests "\n"}}' 2>/dev/null | grep "^${IMAGE%:*}@sha256:" | head -n1 | cut -d@ -f2 || true)"
    if [ -n "$LOCAL_DIGEST" ]; then
        echo "Local digest: $LOCAL_DIGEST"
    else
        echo "Local digest not available."
    fi
else
    echo "Local image does not exist."
    SHOULD_PULL=1
fi

if [ "$SHOULD_PULL" -eq 0 ]; then
    echo
    if docker buildx version >/dev/null 2>&1; then
        echo "==> Checking remote image digest..."
        set +e
        REMOTE_RAW="$(docker buildx imagetools inspect "$IMAGE" 2>/dev/null)"
        STATUS=$?
        set -e

        if [ $STATUS -eq 0 ]; then
            REMOTE_DIGEST="$(printf '%s\n' "$REMOTE_RAW" | awk '/Digest:/ {print $2; exit}')"
            if [ -n "$REMOTE_DIGEST" ]; then
                echo "Remote digest: $REMOTE_DIGEST"
            else
                echo "Could not determine remote digest."
            fi
        else
            echo "Could not inspect remote image."
        fi
    else
        echo "docker buildx not available; skipping remote image check."
    fi

    if [ -n "$REMOTE_DIGEST" ] && [ -n "$LOCAL_DIGEST" ]; then
        if [ "$LOCAL_DIGEST" != "$REMOTE_DIGEST" ]; then
            echo "Remote image differs from local image."
            SHOULD_PULL=1
        else
            echo "Local image is up to date."
        fi
    elif [ -z "$LOCAL_DIGEST" ] && [ -n "$REMOTE_DIGEST" ]; then
        echo "Local digest unavailable. Pull required."
        SHOULD_PULL=1
    else
        echo "Remote comparison unavailable. Keeping local image."
    fi
fi

if [ "$SHOULD_PULL" -eq 1 ]; then
    echo
    if [ "$AUTO_PULL" -eq 1 ] || confirm_yes "Pull/update image now?"; then
        echo "==> Pulling Docker image..."
        docker pull "$IMAGE"
    else
        echo "Image pull skipped by user."
        if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
            echo "Error: image is not available locally, cannot continue."
            exit 1
        fi
    fi
fi

echo
echo "==> Container '$CONTAINER_NAME' does not exist."
if [ "$AUTO_CREATE" -eq 1 ] || confirm_yes "Create and start container now?"; then
    docker run -dt --name "$CONTAINER_NAME" \
        --privileged \
        --hostname ubuntu-xbuild \
        -v "$ROS2_WS:/home/ubuntu/ros2_ws" \
        "$IMAGE" >/dev/null
    echo "Container created and started."
else
    echo "Container creation skipped."
    exit 0
fi

echo
echo "Prepare ROS 2 workspace (required for first use or when mounting a new workspace path)."
if [ "$AUTO_PREP" -eq 1 ] || confirm_yes "Run now?"; then
    echo "==> Preparing workspace..."
    docker exec "$CONTAINER_NAME" bash -c "
        sudo chown -R ubuntu:ubuntu /home/ubuntu/ros2_ws &&
        cp -r /home/ubuntu/toolchains/.vscode /home/ubuntu/ros2_ws/ &&
        cp /home/ubuntu/toolchains/.clang-format /home/ubuntu/ros2_ws/
    "
    echo "Done."
else
    echo "Skipped."
fi

echo
if confirm_no_default "Open a shell inside the container now?"; then
    exec docker exec -it "$CONTAINER_NAME" bash
fi

echo
echo "Setup complete."
echo "To access the container later, run:"
echo "  docker exec -it \"$CONTAINER_NAME\" bash"
echo
echo "Inside the container, go to:"
echo "  cd ~/ros2_ws"