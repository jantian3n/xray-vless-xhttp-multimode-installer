#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_SCRIPT="${SCRIPT_DIR}/deploy_vless_xhttp.sh"

if [[ ! -f "${CORE_SCRIPT}" ]]; then
  printf '[x] 未找到核心脚本: %s\n' "${CORE_SCRIPT}" >&2
  exit 1
fi

case "${1:-}" in
  gui|apply-env)
    cat >&2 <<'EOF'
[x] GUI 模式和 XRAY_GUI_* 环境变量入口已移除。
[*] 请直接使用传统终端菜单版：
    sudo bash deploy_vless_xhttp.sh
EOF
    exit 1
    ;;
esac

exec bash "${CORE_SCRIPT}" "$@"
