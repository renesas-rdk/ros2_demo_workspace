#!/usr/bin/env bash
# setup_rdk_docker.sh: quick setup script for a Docker environment used to cross-build applications for the Renesas ARM64 platforms (R-Car V4H, RZ/V2H)
set -euo pipefail

DEFAULT_IMAGE="ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:multiarch"
DEFAULT_CONTAINER_NAME="ros2_cross_build_container"
DEFAULT_ROS2_WS="$HOME/ros2_ws"
REMOTE_SCRIPT_URL="https://github.com/renesas-rdk/ros2_demo_workspace/raw/refs/heads/main/common_utils/setup_rdk_docker.sh"

# Original args, preserved so we can re-exec after a self-update.
ORIG_ARGS=("$@")

PLATFORM="${1:-}"
if [ "$PLATFORM" == "rcarv4h" ]; then
    DEFAULT_IMAGE="ghcr.io/renesas-rdk/rcarv4h_ubuntu_xbuild:multiarch"
    shift
elif [ "$PLATFORM" == "rzv2h" ]; then
    DEFAULT_IMAGE="ghcr.io/renesas-rdk/rzv2h_ubuntu_xbuild:multiarch"
    shift
fi

IMAGE="$DEFAULT_IMAGE"
DOCKER_PLATFORM="native"
CONTAINER_NAME=""
ROS2_WS=""
AUTO_YES=0
AUTO_PULL=0
AUTO_CREATE=0
AUTO_SHELL=0
SKIP_SELF_UPDATE=0

# Global variable used by ask_input to return its result
__INPUT_RESULT=""

usage() {
    cat <<EOF
Usage: $0 [platform] [options]

Platform: if specified, sets the default image and some config for a particular Renesas platform. If not specified, defaults to RZ/V2H.
  rcarv4h                      Use R-Car V4H image
  rzv2h                        Use RZ/V2H image (default)

Options:
  -i, --image IMAGE            Docker image
      --platform PLATFORM      Docker platform: native, linux/amd64, or linux/arm64
                               (default: native)
  -n, --container-name NAME    Container name
  -w, --workspace PATH         Host ROS 2 workspace path (absolute or relative)
  -y, --yes                    Non-interactive; accept yes for confirmations
      --pull                   Automatically pull/update image if needed
      --create                 Automatically create/start container if needed
      --shell                  Open shell in container after setup
      --no-self-update         Skip checking the remote repo for a newer script
  -h, --help                   Show this help

Examples:
  $0
  $0 rcarv4h
  $0 rzv2h
  $0 rcarv4h -n my_container -w ~/ros2_ws
  $0 rzv2h -n my_container -w ~/ros2_ws
  $0 rcarv4h -n my_container -w ~/ros2_ws -y --pull --create
  $0 rzv2h -n my_container -w ~/ros2_ws -y --pull --create
  $0 rzv2h --platform linux/arm64 -n my_container -w ~/ros2_ws -y --pull --create
  $0 rcarv4h --platform linux/arm64 -n my_container -w ~/ros2_ws -y --pull --create
  $0 rcarv4h -n my_container -w ~/ros2_ws -y --pull --create --shell
  $0 rzv2h -n my_container -w ~/ros2_ws -y --pull --create --shell
EOF
}

require_cmd() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Error: required command '$1' not found."
        exit 1
    fi
}

detect_host_os() {
    uname -s 2>/dev/null || echo unknown
}

validate_platform() {
    case "$DOCKER_PLATFORM" in
        native|linux/amd64|linux/arm64) ;;
        *)
            echo "Error: invalid --platform '$DOCKER_PLATFORM'. Use native, linux/amd64, or linux/arm64." >&2
            exit 1
            ;;
    esac
}

docker_platform_args() {
    if [ "$DOCKER_PLATFORM" != "native" ]; then
        printf '%s\n' --platform "$DOCKER_PLATFORM"
    fi
}

docker_native_arch() {
    local arch
    arch="$(docker info --format '{{.Architecture}}' 2>/dev/null || true)"
    case "$arch" in
        amd64|x86_64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) echo "" ;;
    esac
}

platform_arch() {
    case "$DOCKER_PLATFORM" in
        linux/amd64) echo "amd64" ;;
        linux/arm64) echo "arm64" ;;
        native) docker_native_arch ;;
    esac
}

check_docker_platform_emulation() {
    local native_arch requested_arch binfmt_arch binfmt_name binfmt_path
    native_arch="$(docker_native_arch)"
    requested_arch="$(platform_arch)"

    if [ -z "$native_arch" ] || [ -z "$requested_arch" ] || [ "$native_arch" = "$requested_arch" ]; then
        return 0
    fi

    if [ "$(detect_host_os)" != "Linux" ]; then
        echo "Non-native Docker platform requested; assuming Docker Desktop or OrbStack provides the required emulation."
        return 0
    fi

    case "$requested_arch" in
        arm64)
            binfmt_arch="arm64"
            binfmt_name="qemu-aarch64"
            ;;
        amd64)
            binfmt_arch="amd64"
            binfmt_name="qemu-x86_64"
            ;;
        *)
            echo "Error: unsupported Docker platform architecture '$requested_arch'." >&2
            exit 1
            ;;
    esac

    binfmt_path="/proc/sys/fs/binfmt_misc/$binfmt_name"
    if [ ! -r "$binfmt_path" ] || ! grep -q '^enabled' "$binfmt_path"; then
        echo "Error: Docker platform $DOCKER_PLATFORM needs binfmt handler '$binfmt_name' on this Linux $native_arch Docker host." >&2
        echo "Register it first, for example:" >&2
        echo "  docker run --privileged --rm tonistiigi/binfmt --install $binfmt_arch" >&2
        echo "Or use a native-platform image/container instead." >&2
        exit 1
    fi
}

local_image_available() {
    docker image inspect "$IMAGE" >/dev/null 2>&1 || return 1

    local expected_arch
    expected_arch="$(platform_arch)"
    if [ -z "$expected_arch" ]; then
        return 0
    fi

    local local_arch
    local_arch="$(docker image inspect "$IMAGE" --format '{{.Architecture}}' 2>/dev/null || true)"
    [ "$local_arch" = "$expected_arch" ]
}

is_numeric_gid() {
    case "$1" in
        ""|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

get_docker_socket_gid() {
    local socket="$1"
    shift
    local image="${1:-}"
    if [ "$#" -gt 0 ]; then
        shift
    fi

    local gid

    # Prefer the GID Docker will expose after bind-mounting the socket. Some
    # desktop/VM runtimes do not preserve the host-side socket ownership.
    if [ -n "$image" ]; then
        gid="$(docker run --rm "$@" \
            -v "$socket:$socket" \
            --entrypoint stat \
            "$image" -c %g "$socket" 2>/dev/null || true)"
        if is_numeric_gid "$gid"; then
            echo "$gid"
            return 0
        fi
    fi

    if gid="$(stat -L -c %g "$socket" 2>/dev/null)" && is_numeric_gid "$gid"; then
        echo "$gid"
    elif gid="$(stat -c %g "$socket" 2>/dev/null)" && is_numeric_gid "$gid"; then
        echo "$gid"
    elif gid="$(stat -L -f %g "$socket" 2>/dev/null)" && is_numeric_gid "$gid"; then
        echo "$gid"
    elif gid="$(stat -f %g "$socket" 2>/dev/null)" && is_numeric_gid "$gid"; then
        echo "$gid"
    fi
}

# Look up a user's home directory. Uses `getent` on Linux and falls back to
# `dscl` on macOS, which has no getent.
lookup_user_home() {
    local username="$1" home=""
    home="$(getent passwd "$username" 2>/dev/null | cut -d: -f6)" || true
    if [ -z "$home" ] && command -v dscl >/dev/null 2>&1; then
        home="$(dscl . -read "/Users/$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')" || true
    fi
    printf '%s' "$home"
}

# Collapse '.', '..', and duplicate slashes in an absolute path purely
# lexically (no filesystem access). Used as a fallback when GNU `realpath -m`
# is unavailable (e.g. BSD/macOS realpath) and the path does not yet exist, so
# Docker never receives an un-normalized '..' in a volume path.
_lexical_normalize() {
    local input="$1" result="" part oldifs="$IFS"
    # Split on '/' without temp files (no here-strings) and without globbing,
    # so this is safe under `set -u` and on minimal/locked-down shells.
    set -f
    IFS='/'
    set -- $input
    IFS="$oldifs"
    set +f
    for part in "$@"; do
        case "$part" in
            ''|.) ;;
            ..) result="${result%/*}" ;;
            *) result="$result/$part" ;;
        esac
    done
    [ -n "$result" ] || result="/"
    printf '%s\n' "$result"
}

# Resolve a user-supplied path to an absolute path.
resolve_path() {
    local path="$1"

    # Expand ~ and ~user prefixes using case/glob to avoid regex pitfalls.
    case "$path" in
        "~")
            path="$HOME"
            ;;
        "~"/*)
            path="$HOME/${path:2}"
            ;;
        "~"*)
            local username rest user_home
            username="${path%%/*}"
            username="${username#\~}"
            rest="${path#*/}"
            # If no slash found, rest == path (no subdirectory)
            [ "$rest" = "$path" ] && rest="" || rest="/$rest"
            user_home="$(lookup_user_home "$username")"
            if [ -z "$user_home" ]; then
                echo "Error: cannot resolve home directory for user '$username'" >&2
                return 1
            fi
            path="${user_home}${rest}"
            ;;
    esac

    if [[ "$path" != /* ]]; then
        path="$(pwd)/$path"
    fi

    # Prefer GNU `realpath -m` (lexical, no existence requirement). On BSD/macOS
    # realpath lacks -m, so fall back to resolving an existing path or
    # normalizing a not-yet-existing one lexically.
    if command -v realpath >/dev/null 2>&1; then
        realpath -m -- "$path" 2>/dev/null || {
            if [ -e "$path" ]; then
                realpath "$path"
            else
                _lexical_normalize "$path"
            fi
        }
    else
        _lexical_normalize "$path"
    fi
}

# Sets __INPUT_RESULT instead of echoing, so it works
# correctly even when called from the main shell (no subshell).
ask_input() {
    local prompt="$1"
    local default_value="$2"
    local user_input

    read -r -p "$prompt [default: $default_value]: " user_input
    if [ -z "$user_input" ]; then
        __INPUT_RESULT="$default_value"
    else
        __INPUT_RESULT="$user_input"
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

# Check the remote repository for a newer version of this script and, with
# the user's consent, replace the local copy and re-execute it.
self_update() {
    # Avoid infinite re-exec loop and honor explicit opt-out.
    if [ "${RDK_SCRIPT_SELF_UPDATED:-0}" = "1" ] || [ "$SKIP_SELF_UPDATE" -eq 1 ]; then
        return 0
    fi

    local script_path
    script_path="$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
    if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
        return 0
    fi

    local downloader=""
    if command -v curl >/dev/null 2>&1; then
        downloader="curl"
    elif command -v wget >/dev/null 2>&1; then
        downloader="wget"
    else
        echo "Note: neither curl nor wget is available; skipping self-update check."
        return 0
    fi

    local tmp_file
    tmp_file="$(mktemp)"
    trap 'rm -f "$tmp_file"' RETURN

    echo
    echo "==> Checking remote for a newer version of this script..."
    echo "==> Fetching $REMOTE_SCRIPT_URL"
    local fetch_ok=0
    if [ "$downloader" = "curl" ]; then
        curl -fsSL -o "$tmp_file" "$REMOTE_SCRIPT_URL" && fetch_ok=1 || true
    else
        wget -q -O "$tmp_file" "$REMOTE_SCRIPT_URL" && fetch_ok=1 || true
    fi

    if [ "$fetch_ok" -ne 1 ] || [ ! -s "$tmp_file" ]; then
        echo "Could not fetch remote script; continuing with current version."
        return 0
    fi

    if cmp -s "$script_path" "$tmp_file"; then
        echo "Script is already up to date."
        return 0
    fi

    echo "A newer version of the script is available."
    if ! confirm_yes "Update local script and restart with the new version?"; then
        echo "Update skipped."
        return 0
    fi

    chmod --reference="$script_path" "$tmp_file" 2>/dev/null || chmod +x "$tmp_file"
    if ! mv "$tmp_file" "$script_path"; then
        echo "Failed to write '$script_path' (permission denied?). Continuing with current version."
        return 0
    fi
    # mv succeeded; tmp_file no longer exists, so cancel the RETURN trap cleanup.
    trap - RETURN

    echo "Script updated. Re-executing..."
    export RDK_SCRIPT_SELF_UPDATED=1
    exec "$script_path" "${ORIG_ARGS[@]}"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--image)
                IMAGE="$2"
                shift 2
                ;;
            --platform)
                DOCKER_PLATFORM="$2"
                shift 2
                ;;
            --platform=*)
                DOCKER_PLATFORM="${1#--platform=}"
                shift
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
            --shell)
                AUTO_SHELL=1
                shift
                ;;
            --no-self-update)
                SKIP_SELF_UPDATE=1
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
validate_platform

self_update

require_cmd docker

echo "=============================================="
echo " Renesas RDK Docker Cross-Build Setup"
echo "=============================================="
echo

if [ -z "$CONTAINER_NAME" ]; then
    ask_input "Enter container name" "$DEFAULT_CONTAINER_NAME"
    CONTAINER_NAME="$__INPUT_RESULT"
fi

if docker ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    echo
    echo "A Docker container named '$CONTAINER_NAME' already exists."
    echo "Please choose a different name or remove the existing container."
    echo "To remove the existing container, use: docker rm -f $CONTAINER_NAME"
    echo "Or choose a different container name and run the script again."
    exit 1
fi

if [ -z "$ROS2_WS" ]; then
    ask_input "Enter ROS 2 workspace path on host (absolute or relative)" "$DEFAULT_ROS2_WS"
    ROS2_WS_INPUT="$__INPUT_RESULT"
else
    ROS2_WS_INPUT="$ROS2_WS"
fi

ROS2_WS="$(resolve_path "$ROS2_WS_INPUT")"

echo
echo "Configuration:"
echo "  Docker image   : $IMAGE"
echo "  Docker platform: $DOCKER_PLATFORM"
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
PLATFORM_ARGS=()
while IFS= read -r arg; do
    PLATFORM_ARGS+=("$arg")
done < <(docker_platform_args)
check_docker_platform_emulation

echo
echo "==> Checking local image..."
if local_image_available; then
    echo "Local image exists."
    LOCAL_DIGEST="$(docker image inspect "$IMAGE" --format '{{join .RepoDigests "\n"}}' 2>/dev/null | grep "^${IMAGE%:*}@sha256:" | head -n1 | cut -d@ -f2 || true)"
    if [ -n "$LOCAL_DIGEST" ]; then
        echo "Local digest: $LOCAL_DIGEST"
    else
        echo "Local digest not available."
    fi
else
    echo "Local image does not exist for the requested platform."
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
        docker pull "${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"}" "$IMAGE"
    else
        echo "Image pull skipped by user."
        if ! local_image_available; then
            echo "Error: image is not available locally for the requested platform, cannot continue."
            exit 1
        fi
    fi
fi

echo
echo "==> Container '$CONTAINER_NAME' does not exist."
if [ "$AUTO_CREATE" -eq 1 ] || confirm_yes "Create and start container now?"; then
    # Docker-outside-of-Docker: bind-mount the host docker socket so
    # tooling inside the container (e.g. farm-image build/push) can
    # use the host daemon. Pass the mounted socket's GID via --group-add
    # so the non-root `ubuntu` user can read the socket without changing
    # the image.
    DOOD_ARGS=()
    if [ -S /var/run/docker.sock ]; then
        DOOD_ARGS=(-v /var/run/docker.sock:/var/run/docker.sock)
        DOCKER_SOCKET_GID="$(get_docker_socket_gid /var/run/docker.sock "$IMAGE" "${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"}" || true)"
        if [ -n "${DOCKER_SOCKET_GID:-}" ]; then
            DOOD_ARGS+=(--group-add "$DOCKER_SOCKET_GID")
            echo "Mounting host docker socket (GID $DOCKER_SOCKET_GID)."
        else
            echo "Mounting host docker socket without --group-add; socket GID could not be determined."
        fi
    else
        echo "Note: /var/run/docker.sock not found on host; docker-in-container disabled."
    fi

    docker run -dt --name "$CONTAINER_NAME" \
        "${PLATFORM_ARGS[@]+"${PLATFORM_ARGS[@]}"}" \
        --privileged \
        --hostname ubuntu-xbuild \
        -v "$ROS2_WS:/home/ubuntu/ros2_ws" \
        "${DOOD_ARGS[@]+"${DOOD_ARGS[@]}"}" \
        "$IMAGE" >/dev/null
    echo "Container created and started."
else
    echo "Container creation skipped."
    exit 0
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