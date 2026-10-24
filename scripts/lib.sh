# Sourced by the scripts in this directory. Sets ROOT/STATE and loads config.env.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STATE=$ROOT/state
if [[ ! -f $ROOT/config.env ]]; then
  echo "config.env not found: cp config.example.env config.env and edit it" >&2
  exit 1
fi
# shellcheck source=../config.example.env
source "$ROOT/config.env"

GPU_GROUP=$(basename "$(readlink -f "/sys/bus/pci/devices/$GPU_PCI/iommu_group" 2>/dev/null)" 2>/dev/null)
SSH_CONFIG=$STATE/ssh/config
QMP_SOCK=$STATE/qmp.sock

die() { echo "$*" >&2; exit 1; }
