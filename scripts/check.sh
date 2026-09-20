#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export XDG_DATA_HOME="$PWD/toolchain"
forge build --offline
forge test --offline
forge fmt --check
python3 scripts/export_abi.py --check
