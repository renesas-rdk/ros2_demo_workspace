#!/bin/bash
# setup_rpc_server.sh, run once on the host machine: bash setup_rpc_server.sh
# Target board: R-Car/V4H

set -euo pipefail

# Settings, replace the values below with the ones of your setup
BOARD=ubuntu@192.168.1.100          # <user>@<ip> of the board
BOARD_PW=ubuntu                     # SSH password of the board
PKG=/path/to/hyco-install           # Root directory of the unpacked HyCo package
                                    # (i.e. the directory such that $PKG/installation/install.sh exists)
XOS_VERSION=v3.43.0                 # Installed xOS SDK version, adjust if different

INST=/opt/rcar-xos/$XOS_VERSION/tools/hyco/reaction/dockerfiles/install

# 1. Check the settings before doing anything
fail() { echo "ERROR: $*" >&2; exit 1; }

command -v sshpass >/dev/null || fail "sshpass is missing, run: sudo apt install sshpass"

[ -d "$PKG/packages/v4x" ] || fail "PKG is wrong, $PKG/packages/v4x does not exist"
ls "$PKG"/packages/v4x/*.whl >/dev/null 2>&1 \
   || fail "no .whl files in $PKG/packages/v4x, is the HyCo package unpacked?"

[ -d "$INST" ] || fail "$INST not found, check XOS_VERSION and that REACTION is installed"
ls "$INST"/R_Car_V4x_HyCo_L_TVM_v4h2_runtime-*-cp310-cp310-linux_aarch64.whl >/dev/null 2>&1 \
   || fail "V4H2 runtime wheel not found in $INST"
ls "$INST"/R_Car_V4x_HyCo_L_Artifact_Helper_v4h2-*-cp310-cp310-linux_aarch64.whl >/dev/null 2>&1 \
   || fail "artifact helper wheel not found in $INST"

BOARD_ARCH=$(sshpass -p "$BOARD_PW" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
   "$BOARD" uname -m) || fail "cannot log in to $BOARD, check BOARD and BOARD_PW"
[ "$BOARD_ARCH" = aarch64 ] \
   || fail "$BOARD reports $BOARD_ARCH instead of aarch64, is BOARD the target board?"

echo "Settings OK, installing the RPC server on $BOARD"
STAGE=$(mktemp -d)

# 2. Collect the wheels
cp "$PKG"/packages/v4x/*.whl "$STAGE"/   # The .whl files only, not the .rpm
cp "$INST"/R_Car_V4x_HyCo_L_TVM_v4h2_runtime-*-cp310-cp310-linux_aarch64.whl "$STAGE"/
cp "$INST"/R_Car_V4x_HyCo_L_Artifact_Helper_v4h2-*-cp310-cp310-linux_aarch64.whl "$STAGE"/

# 3. Bootstrap script, executed on the board in step 5
cat > "$STAGE/bootstrap.sh" <<'BOOTSTRAP'
#!/bin/bash
set -euo pipefail
curl -LsSf https://astral.sh/uv/install.sh | sh
export PATH=$HOME/.local/bin:$PATH
uv python install 3.10
cd "$HOME/rpc_server"
uv venv --python 3.10 .venv
uv pip install --python .venv/bin/python --no-index --find-links wheels \
   numpy scipy ml_dtypes cloudpickle decorator psutil attrs tornado packaging \
   typing_extensions pyzmq \
   R_Car_V4x_HyCo_L_TVM_v4h2_runtime R_Car_V4x_HyCo_L_Artifact_Helper_v4h2
BOOTSTRAP

# 4. Start script, stays on the board for every evaluation session
cat > "$STAGE/start_rpc_server.sh" <<'START'
#!/bin/bash
# Start the TVM RPC server from the Python 3.10 venv
cd "$HOME/rpc_server"

# Free the port if a previous server is still running
fuser -k 9090/tcp 2>/dev/null || true

# --no-fork is recommended: forking the hardware-backed runtime is fragile
.venv/bin/python -m tvm.exec.rpc_server --host 0.0.0.0 --port 9090 --no-fork
START

# 5. Copy everything to the board and install
sshpass -p "$BOARD_PW" ssh -o StrictHostKeyChecking=no "$BOARD" 'mkdir -p ~/rpc_server/wheels'
sshpass -p "$BOARD_PW" scp -o StrictHostKeyChecking=no "$STAGE"/*.whl "$BOARD":rpc_server/wheels/
sshpass -p "$BOARD_PW" scp -o StrictHostKeyChecking=no \
   "$STAGE/bootstrap.sh" "$STAGE/start_rpc_server.sh" "$BOARD":rpc_server/
sshpass -p "$BOARD_PW" ssh -o StrictHostKeyChecking=no "$BOARD" \
   'chmod +x ~/rpc_server/*.sh && bash ~/rpc_server/bootstrap.sh'

# 6. Verify the installation, prints the TVM version
sshpass -p "$BOARD_PW" ssh -o StrictHostKeyChecking=no "$BOARD" \
   '~/rpc_server/.venv/bin/python -c "import tvm, artifact_helper; print(tvm.__version__)"'

rm -rf "$STAGE"
echo "Done. Start the server on the board with: bash ~/rpc_server/start_rpc_server.sh"