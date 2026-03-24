#!/usr/bin/env bash

set -euo pipefail

# Confirmed against the current xray-core source tree:
# - streamSettings.network "xhttp" maps to the underlying "splithttp" transport.
# - xhttpSettings supports host/path/mode and can also carry downloadSettings.
# - REALITY supports RAW, XHTTP and gRPC.

SCRIPT_NAME="$(basename "$0")"

XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/deploy_mode.env"
CLIENT_LINK_FILE="${CONFIG_DIR}/client_vless_link.txt"
CLIENT_PATCH_FILE="${CONFIG_DIR}/client_split_patch.json"
CLIENT_OUTBOUND_FILE="${CONFIG_DIR}/client_outbound.json"
CLIENT_README_FILE="${CONFIG_DIR}/client_readme.txt"

XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
PROXY_SERVICE_NAME="xhttp-upload-proxy"
PROXY_SERVICE_FILE="/etc/systemd/system/${PROXY_SERVICE_NAME}.service"
PROXY_CONFIG_FILE="/etc/haproxy/${PROXY_SERVICE_NAME}.cfg"

GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"

DEPLOY_MODE=""
SERVICE_KIND=""
ACTIVE_SERVICE=""
SECURITY_MODE=""

PORT=""
UPLOAD_ADDRESS=""
DOWNLOAD_ADDRESS=""
BACKEND_ADDRESS=""
BACKEND_PORT=""

UUID=""
SNI=""
UPLOAD_SNI=""
DOWNLOAD_SNI=""
REALITY_DEST=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
SHORT_ID=""
TLS_CERT_FILE=""
TLS_KEY_FILE=""
FINGERPRINT=""
SPIDERX=""
XHTTP_PATH=""
XHTTP_MODE=""
NODE_NAME=""

log() {
  printf '[*] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请用 root 运行：sudo bash ${SCRIPT_NAME}"
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

banner() {
  cat <<'EOF'
===========================================================
 Xray 一键部署脚本
 支持模式:
 1. 单 VPS: VLESS + XHTTP + REALITY
 2. IPv6 上行 + IPv4 下行: 同一 VPS 后端
 3. VPS1 上行 + VPS2 下行: VPS1 透传 / VPS2 后端
 4. CDN 上行 + VPS 下行: TLS + XHTTP

 说明:
 - 基础 vless:// 链接会生成
 - 分离上下行模式还会额外生成客户端补丁和 outbound JSON
 - 如果客户端不支持自定义 JSON，就只能用普通单机模式
===========================================================
EOF
}

usage() {
  cat <<EOF
用法:
  bash ${SCRIPT_NAME}              进入交互菜单
  bash ${SCRIPT_NAME} install      安装或重装
  bash ${SCRIPT_NAME} show         查看当前配置和客户端信息
  bash ${SCRIPT_NAME} service      服务管理
  bash ${SCRIPT_NAME} update-core  更新 Xray 内核
  bash ${SCRIPT_NAME} uninstall    卸载脚本部署的组件
EOF
}

urlencode() {
  local raw="${1:-}"
  local encoded=""
  local index char hex

  for ((index = 0; index < ${#raw}; index++)); do
    char="${raw:index:1}"
    case "${char}" in
      [a-zA-Z0-9.~_-])
        encoded+="${char}"
        ;;
      *)
        printf -v hex '%%%02X' "'${char}"
        encoded+="${hex}"
        ;;
    esac
  done

  printf '%s' "${encoded}"
}

json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "${value}"
}

format_uri_host() {
  local host="${1:-}"
  if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
    printf '[%s]' "${host}"
  else
    printf '%s' "${host}"
  fi
}

format_haproxy_host() {
  local host="${1:-}"
  if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
    printf '[%s]' "${host}"
  else
    printf '%s' "${host}"
  fi
}

prompt_default() {
  local prompt="${1}"
  local default="${2-}"
  local reply

  if [[ -n "${default}" ]]; then
    read -r -p "${prompt} [${default}]: " reply
    printf '%s' "${reply:-${default}}"
  else
    read -r -p "${prompt}: " reply
    printf '%s' "${reply}"
  fi
}

prompt_yes_no() {
  local prompt="${1}"
  local default="${2:-y}"
  local reply suffix

  if [[ "${default}" == "y" ]]; then
    suffix="Y/n"
  else
    suffix="y/N"
  fi

  read -r -p "${prompt} [${suffix}]: " reply
  reply="${reply:-${default}}"

  case "${reply}" in
    y|Y|yes|YES)
      return 0
      ;;
    n|N|no|NO)
      return 1
      ;;
    *)
      warn "输入无效，按默认值处理。"
      if [[ "${default}" == "y" ]]; then
        return 0
      fi
      return 1
      ;;
  esac
}

validate_port() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  ((port >= 1 && port <= 65535))
}

normalize_path() {
  local path="${1:-}"
  [[ -n "${path}" ]] || return 1
  if [[ "${path}" != /* ]]; then
    path="/${path}"
  fi
  printf '%s' "${path}"
}

normalize_dest() {
  local dest="${1:-}"
  if [[ -z "${dest}" ]]; then
    return 1
  fi

  if [[ "${dest}" == \[*\]:* ]]; then
    printf '%s' "${dest}"
    return 0
  fi

  if [[ "${dest}" == *:* ]]; then
    printf '%s' "${dest}"
  else
    printf '%s:443' "${dest}"
  fi
}

normalize_spiderx() {
  local spiderx="${1:-/}"
  [[ -n "${spiderx}" ]] || spiderx="/"
  if [[ "${spiderx}" != /* ]]; then
    spiderx="/${spiderx}"
  fi
  printf '%s' "${spiderx}"
}

detect_public_ipv4() {
  local address=""
  address="$(curl -4 -fsSL https://api64.ipify.org 2>/dev/null || true)"
  if [[ -z "${address}" ]]; then
    address="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${address}"
}

detect_public_ipv6() {
  local address=""
  address="$(curl -6 -fsSL https://api64.ipify.org 2>/dev/null || true)"
  printf '%s' "${address}"
}

detect_public_address() {
  local address
  address="$(detect_public_ipv4)"
  if [[ -z "${address}" ]]; then
    address="$(detect_public_ipv6)"
  fi
  printf '%s' "${address}"
}

is_xray_mode() {
  case "${DEPLOY_MODE}" in
    single_reality|split_dualstack_reality|split_dualvps_reality_backend|split_cdn_tls_backend)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_split_mode() {
  case "${DEPLOY_MODE}" in
    split_dualstack_reality|split_dualvps_reality_backend|split_cdn_tls_backend)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_reality_mode() {
  [[ "${SECURITY_MODE:-}" == "reality" ]]
}

is_tls_mode() {
  [[ "${SECURITY_MODE:-}" == "tls" ]]
}

mode_label() {
  case "${DEPLOY_MODE}" in
    single_reality)
      printf '单 VPS: VLESS + XHTTP + REALITY'
      ;;
    split_dualstack_reality)
      printf '同机分离: IPv6 上行 + IPv4 下行'
      ;;
    split_dualvps_reality_backend)
      printf '双 VPS: VPS2 后端 / 下行服务器'
      ;;
    split_dualvps_reality_proxy)
      printf '双 VPS: VPS1 上传代理'
      ;;
    split_cdn_tls_backend)
      printf 'CDN 上行 + VPS 下行: TLS + XHTTP'
      ;;
    *)
      printf '未设置'
      ;;
  esac
}

default_mode_number() {
  case "${1:-}" in
    single_reality) printf '1' ;;
    split_dualstack_reality) printf '2' ;;
    split_dualvps_reality_backend) printf '3' ;;
    split_dualvps_reality_proxy) printf '4' ;;
    split_cdn_tls_backend) printf '5' ;;
    *) printf '1' ;;
  esac
}

choose_deploy_mode() {
  local current="${1:-single_reality}"
  local choice

  cat <<'EOF'
请选择部署模式:
1. 单 VPS：VLESS + XHTTP + REALITY
2. IPv6 上行 + IPv4 下行：同一 VPS 后端
3. VPS1 上行 + VPS2 下行：当前机器部署 VPS2 后端
4. VPS1 上行 + VPS2 下行：当前机器部署 VPS1 上传代理
5. CDN 上行 + VPS 下行：当前机器部署 TLS 后端
EOF

  while true; do
    choice="$(prompt_default "输入序号" "$(default_mode_number "${current}")")"
    case "${choice}" in
      1) printf 'single_reality'; return 0 ;;
      2) printf 'split_dualstack_reality'; return 0 ;;
      3) printf 'split_dualvps_reality_backend'; return 0 ;;
      4) printf 'split_dualvps_reality_proxy'; return 0 ;;
      5) printf 'split_cdn_tls_backend'; return 0 ;;
      *) warn "请输入 1-5。" ;;
    esac
  done
}

default_xhttp_mode_number() {
  case "${1:-auto}" in
    auto) printf '1' ;;
    packet-up) printf '2' ;;
    stream-up) printf '3' ;;
    stream-one) printf '4' ;;
    *) printf '1' ;;
  esac
}

choose_xhttp_mode() {
  local current="${1:-auto}"
  local allow_stream_one="${2:-yes}"
  local choice

  cat <<'EOF'
请选择 XHTTP mode:
1. auto       (推荐)
2. packet-up
3. stream-up
EOF

  if [[ "${allow_stream_one}" == "yes" ]]; then
    printf '%s\n' '4. stream-one'
  fi

  while true; do
    choice="$(prompt_default "输入序号" "$(default_xhttp_mode_number "${current}")")"
    case "${choice}" in
      1) printf 'auto'; return 0 ;;
      2) printf 'packet-up'; return 0 ;;
      3) printf 'stream-up'; return 0 ;;
      4)
        if [[ "${allow_stream_one}" == "yes" ]]; then
          printf 'stream-one'
          return 0
        fi
        warn "当前模式不建议使用 stream-one。"
        ;;
      *)
        warn "请输入有效序号。"
        ;;
    esac
  done
}

prompt_required() {
  local prompt="${1}"
  local default="${2-}"
  local reply

  while true; do
    reply="$(prompt_default "${prompt}" "${default}")"
    if [[ -n "${reply}" ]]; then
      printf '%s' "${reply}"
      return 0
    fi
    warn "该项不能为空。"
  done
}

prompt_port() {
  local default="${1:-443}"
  local reply

  while true; do
    reply="$(prompt_default "监听端口" "${default}")"
    if validate_port "${reply}"; then
      printf '%s' "${reply}"
      return 0
    fi
    warn "端口必须是 1-65535 的整数。"
  done
}

prompt_path() {
  local default="${1:-/$(openssl rand -hex 6)}"
  local reply

  while true; do
    reply="$(prompt_default "XHTTP path" "${default}")"
    reply="$(normalize_path "${reply}")" || true
    if [[ -n "${reply}" ]]; then
      printf '%s' "${reply}"
      return 0
    fi
    warn "path 不能为空。"
  done
}

prompt_dest() {
  local prompt="${1}"
  local default="${2}"
  local reply

  while true; do
    reply="$(prompt_default "${prompt}" "${default}")"
    reply="$(normalize_dest "${reply}")" || true
    if [[ -n "${reply}" ]]; then
      printf '%s' "${reply}"
      return 0
    fi
    warn "dest 不能为空。"
  done
}

prompt_existing_file() {
  local prompt="${1}"
  local default="${2-}"
  local reply

  while true; do
    reply="$(prompt_default "${prompt}" "${default}")"
    if [[ -f "${reply}" ]]; then
      printf '%s' "${reply}"
      return 0
    fi
    warn "文件不存在: ${reply}"
  done
}

port_maybe_busy_warning() {
  local port="${1}"
  if command_exists ss && ss -lntH "( sport = :${port} )" 2>/dev/null | grep -q .; then
    warn "检测到 TCP 端口 ${port} 已被占用。若不是当前服务，请改端口。"
  fi
}

detect_asset_name() {
  local arch
  arch="$(uname -m)"

  case "${arch}" in
    x86_64|amd64) printf 'Xray-linux-64.zip' ;;
    aarch64|arm64) printf 'Xray-linux-arm64-v8a.zip' ;;
    armv7l|armv7*) printf 'Xray-linux-arm32-v7a.zip' ;;
    armv6l|armv6*) printf 'Xray-linux-arm32-v6.zip' ;;
    armv5l|armv5*) printf 'Xray-linux-arm32-v5.zip' ;;
    i386|i486|i586|i686) printf 'Xray-linux-32.zip' ;;
    s390x) printf 'Xray-linux-s390x.zip' ;;
    riscv64) printf 'Xray-linux-riscv64.zip' ;;
    loongarch64|loong64) printf 'Xray-linux-loong64.zip' ;;
    mips64el|mips64le) printf 'Xray-linux-mips64le.zip' ;;
    mips64) printf 'Xray-linux-mips64.zip' ;;
    mipsel|mips32le) printf 'Xray-linux-mips32le.zip' ;;
    mips|mips32) printf 'Xray-linux-mips32.zip' ;;
    ppc64) printf 'Xray-linux-ppc64.zip' ;;
    ppc64le) printf 'Xray-linux-ppc64le.zip' ;;
    *)
      die "暂不支持当前架构: ${arch}"
      ;;
  esac
}

install_dependencies_xray() {
  command_exists apt-get || die "当前脚本只处理 Debian / Ubuntu 系。"
  export DEBIAN_FRONTEND=noninteractive
  log "安装 Xray 依赖中..."
  apt-get update -y
  apt-get install -y curl unzip ca-certificates openssl
}

install_dependencies_proxy() {
  command_exists apt-get || die "当前脚本只处理 Debian / Ubuntu 系。"
  export DEBIAN_FRONTEND=noninteractive
  log "安装上传代理依赖中..."
  apt-get update -y
  apt-get install -y haproxy ca-certificates
}

ensure_runtime_prereqs() {
  if ! command_exists curl || ! command_exists openssl; then
    install_dependencies_xray
  fi
}

fetch_latest_tag() {
  local tag
  tag="$(
    curl -fsSL "${GITHUB_API}" \
      | sed -n 's/.*"tag_name": "\(v[^"]*\)".*/\1/p' \
      | head -n 1
  )"
  [[ -n "${tag}" ]] || die "获取 Xray 最新版本失败。"
  printf '%s' "${tag}"
}

install_or_update_xray_core() {
  local asset latest_tag download_url tmp_dir

  install_dependencies_xray
  asset="$(detect_asset_name)"
  latest_tag="$(fetch_latest_tag)"
  download_url="https://github.com/XTLS/Xray-core/releases/download/${latest_tag}/${asset}"
  tmp_dir="$(mktemp -d)"

  log "下载 Xray ${latest_tag} (${asset})..."
  curl -fL "${download_url}" -o "${tmp_dir}/xray.zip"
  unzip -qo "${tmp_dir}/xray.zip" -d "${tmp_dir}"

  [[ -f "${tmp_dir}/xray" ]] || die "下载包内未找到 xray 可执行文件。"

  install -d "${CONFIG_DIR}"
  install -m 755 "${tmp_dir}/xray" "${XRAY_BIN}"
  rm -rf "${tmp_dir}"

  log "Xray 已安装到 ${XRAY_BIN}"
}

ensure_xray_service_file() {
  cat > "${XRAY_SERVICE_FILE}" <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
}

ensure_xray_installed() {
  ensure_runtime_prereqs
  if [[ ! -x "${XRAY_BIN}" ]]; then
    install_or_update_xray_core
  fi
  ensure_xray_service_file
}

generate_uuid_value() {
  if [[ -x "${XRAY_BIN}" ]]; then
    "${XRAY_BIN}" uuid
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

generate_reality_keypair() {
  local output
  output="$("${XRAY_BIN}" x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${output}" | awk -F': ' '/^PrivateKey: /{print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${output}" | awk -F': ' '/^Password \(PublicKey\): /{print $2}')"

  [[ -n "${REALITY_PRIVATE_KEY:-}" ]] || die "生成 REALITY privateKey 失败。"
  [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || die "生成 REALITY publicKey 失败。"
}

generate_short_id_value() {
  openssl rand -hex 8
}

load_existing_meta_if_any() {
  if [[ -f "${META_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${META_FILE}"
  fi
}

save_meta() {
  install -d -m 755 "${CONFIG_DIR}"

  {
    printf 'DEPLOY_MODE=%q\n' "${DEPLOY_MODE-}"
    printf 'SERVICE_KIND=%q\n' "${SERVICE_KIND-}"
    printf 'ACTIVE_SERVICE=%q\n' "${ACTIVE_SERVICE-}"
    printf 'SECURITY_MODE=%q\n' "${SECURITY_MODE-}"
    printf 'PORT=%q\n' "${PORT-}"
    printf 'UPLOAD_ADDRESS=%q\n' "${UPLOAD_ADDRESS-}"
    printf 'DOWNLOAD_ADDRESS=%q\n' "${DOWNLOAD_ADDRESS-}"
    printf 'BACKEND_ADDRESS=%q\n' "${BACKEND_ADDRESS-}"
    printf 'BACKEND_PORT=%q\n' "${BACKEND_PORT-}"
    printf 'UUID=%q\n' "${UUID-}"
    printf 'SNI=%q\n' "${SNI-}"
    printf 'UPLOAD_SNI=%q\n' "${UPLOAD_SNI-}"
    printf 'DOWNLOAD_SNI=%q\n' "${DOWNLOAD_SNI-}"
    printf 'REALITY_DEST=%q\n' "${REALITY_DEST-}"
    printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY-}"
    printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY-}"
    printf 'SHORT_ID=%q\n' "${SHORT_ID-}"
    printf 'TLS_CERT_FILE=%q\n' "${TLS_CERT_FILE-}"
    printf 'TLS_KEY_FILE=%q\n' "${TLS_KEY_FILE-}"
    printf 'FINGERPRINT=%q\n' "${FINGERPRINT-}"
    printf 'SPIDERX=%q\n' "${SPIDERX-}"
    printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH-}"
    printf 'XHTTP_MODE=%q\n' "${XHTTP_MODE-}"
    printf 'NODE_NAME=%q\n' "${NODE_NAME-}"
  } > "${META_FILE}"

  chmod 600 "${META_FILE}"
}

reset_mode_specific_values() {
  BACKEND_ADDRESS=""
  BACKEND_PORT=""
  TLS_CERT_FILE=""
  TLS_KEY_FILE=""
  REALITY_DEST=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  SHORT_ID=""
  SNI=""
  UPLOAD_SNI=""
  DOWNLOAD_SNI=""
  SPIDERX=""
}

maybe_refresh_uuid() {
  local keep="n"
  if [[ -n "${UUID:-}" ]]; then
    if prompt_yes_no "保留现有 UUID 吗" "y"; then
      keep="y"
    fi
  fi
  if [[ "${keep}" != "y" || -z "${UUID:-}" ]]; then
    UUID="$(generate_uuid_value)"
  fi
}

maybe_refresh_reality_material() {
  local keep="n"
  if [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" && -n "${SHORT_ID:-}" ]]; then
    if prompt_yes_no "保留现有 REALITY 密钥和 ShortId 吗" "y"; then
      keep="y"
    fi
  fi
  if [[ "${keep}" != "y" || -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" || -z "${SHORT_ID:-}" ]]; then
    generate_reality_keypair
    SHORT_ID="$(generate_short_id_value)"
  fi
}

collect_single_reality_inputs() {
  local auto_addr default_addr

  DEPLOY_MODE="single_reality"
  SERVICE_KIND="xray"
  ACTIVE_SERVICE="xray"
  SECURITY_MODE="reality"

  auto_addr="$(detect_public_address)"
  default_addr="${UPLOAD_ADDRESS:-${auto_addr}}"

  UPLOAD_ADDRESS="$(prompt_required "节点连接地址（域名或公网 IP）" "${default_addr}")"
  DOWNLOAD_ADDRESS="${UPLOAD_ADDRESS}"
  PORT="$(prompt_port "${PORT:-443}")"
  port_maybe_busy_warning "${PORT}"

  SNI="$(prompt_required "REALITY 的 SNI / serverName" "${SNI:-www.cloudflare.com}")"
  UPLOAD_SNI="${SNI}"
  DOWNLOAD_SNI="${SNI}"
  REALITY_DEST="$(prompt_dest "REALITY 目标站 dest（默认跟 SNI 走 443）" "${REALITY_DEST:-${SNI}:443}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(openssl rand -hex 6)}")"
  XHTTP_MODE="$(choose_xhttp_mode "${XHTTP_MODE:-auto}" "yes")"
  FINGERPRINT="$(prompt_required "客户端 fingerprint" "${FINGERPRINT:-chrome}")"
  SPIDERX="$(normalize_spiderx "$(prompt_default "SpiderX" "${SPIDERX:-/}")")"
  NODE_NAME="$(prompt_required "节点备注名" "${NODE_NAME:-VLESS-XHTTP-REALITY}")"

  TLS_CERT_FILE=""
  TLS_KEY_FILE=""
  BACKEND_ADDRESS=""
  BACKEND_PORT=""

  maybe_refresh_uuid
  ensure_xray_installed
  maybe_refresh_reality_material
}

collect_split_dualstack_reality_inputs() {
  local auto_v4 auto_v6

  DEPLOY_MODE="split_dualstack_reality"
  SERVICE_KIND="xray"
  ACTIVE_SERVICE="xray"
  SECURITY_MODE="reality"

  auto_v4="$(detect_public_ipv4)"
  auto_v6="$(detect_public_ipv6)"

  UPLOAD_ADDRESS="$(prompt_required "上行地址（建议 IPv6 域名或 IPv6）" "${UPLOAD_ADDRESS:-${auto_v6}}")"
  DOWNLOAD_ADDRESS="$(prompt_required "下行地址（建议 IPv4 域名或 IPv4）" "${DOWNLOAD_ADDRESS:-${auto_v4}}")"
  PORT="$(prompt_port "${PORT:-443}")"
  port_maybe_busy_warning "${PORT}"

  SNI="$(prompt_required "REALITY 的 SNI / serverName" "${SNI:-www.cloudflare.com}")"
  UPLOAD_SNI="${SNI}"
  DOWNLOAD_SNI="${SNI}"
  REALITY_DEST="$(prompt_dest "REALITY 目标站 dest（默认跟 SNI 走 443）" "${REALITY_DEST:-${SNI}:443}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(openssl rand -hex 6)}")"
  XHTTP_MODE="$(choose_xhttp_mode "${XHTTP_MODE:-auto}" "no")"
  FINGERPRINT="$(prompt_required "客户端 fingerprint" "${FINGERPRINT:-chrome}")"
  SPIDERX="$(normalize_spiderx "$(prompt_default "SpiderX" "${SPIDERX:-/}")")"
  NODE_NAME="$(prompt_required "节点备注名" "${NODE_NAME:-VLESS-XHTTP-IPv6UP-IPv4DOWN}")"

  TLS_CERT_FILE=""
  TLS_KEY_FILE=""
  BACKEND_ADDRESS=""
  BACKEND_PORT=""

  maybe_refresh_uuid
  ensure_xray_installed
  maybe_refresh_reality_material
}

collect_split_dualvps_reality_backend_inputs() {
  local auto_v4

  DEPLOY_MODE="split_dualvps_reality_backend"
  SERVICE_KIND="xray"
  ACTIVE_SERVICE="xray"
  SECURITY_MODE="reality"

  auto_v4="$(detect_public_ipv4)"

  UPLOAD_ADDRESS="$(prompt_required "上行地址（VPS1 上传代理地址）" "${UPLOAD_ADDRESS:-}")"
  DOWNLOAD_ADDRESS="$(prompt_required "下行地址（当前 VPS2 直连地址）" "${DOWNLOAD_ADDRESS:-${auto_v4}}")"
  PORT="$(prompt_port "${PORT:-443}")"
  port_maybe_busy_warning "${PORT}"

  SNI="$(prompt_required "REALITY 的 SNI / serverName" "${SNI:-www.cloudflare.com}")"
  UPLOAD_SNI="${SNI}"
  DOWNLOAD_SNI="${SNI}"
  REALITY_DEST="$(prompt_dest "REALITY 目标站 dest（默认跟 SNI 走 443）" "${REALITY_DEST:-${SNI}:443}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(openssl rand -hex 6)}")"
  XHTTP_MODE="$(choose_xhttp_mode "${XHTTP_MODE:-auto}" "no")"
  FINGERPRINT="$(prompt_required "客户端 fingerprint" "${FINGERPRINT:-chrome}")"
  SPIDERX="$(normalize_spiderx "$(prompt_default "SpiderX" "${SPIDERX:-/}")")"
  NODE_NAME="$(prompt_required "节点备注名" "${NODE_NAME:-VLESS-XHTTP-VPS1UP-VPS2DOWN}")"

  TLS_CERT_FILE=""
  TLS_KEY_FILE=""
  BACKEND_ADDRESS=""
  BACKEND_PORT=""

  maybe_refresh_uuid
  ensure_xray_installed
  maybe_refresh_reality_material
}

collect_split_dualvps_reality_proxy_inputs() {
  local auto_addr

  DEPLOY_MODE="split_dualvps_reality_proxy"
  SERVICE_KIND="proxy"
  ACTIVE_SERVICE="${PROXY_SERVICE_NAME}"
  SECURITY_MODE="reality"

  auto_addr="$(detect_public_address)"
  UPLOAD_ADDRESS="${auto_addr}"
  DOWNLOAD_ADDRESS=""

  PORT="$(prompt_port "${PORT:-443}")"
  port_maybe_busy_warning "${PORT}"
  BACKEND_ADDRESS="$(prompt_required "后端地址（VPS2 直连地址）" "${BACKEND_ADDRESS:-}")"
  BACKEND_PORT="$(prompt_port "${BACKEND_PORT:-${PORT}}")"
  NODE_NAME="$(prompt_required "代理备注名" "${NODE_NAME:-XHTTP-UPLOAD-PROXY}")"

  UUID=""
  SNI=""
  UPLOAD_SNI=""
  DOWNLOAD_SNI=""
  REALITY_DEST=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  SHORT_ID=""
  TLS_CERT_FILE=""
  TLS_KEY_FILE=""
  FINGERPRINT=""
  SPIDERX=""
  XHTTP_PATH=""
  XHTTP_MODE=""
}

collect_split_cdn_tls_backend_inputs() {
  local auto_v4

  DEPLOY_MODE="split_cdn_tls_backend"
  SERVICE_KIND="xray"
  ACTIVE_SERVICE="xray"
  SECURITY_MODE="tls"

  auto_v4="$(detect_public_ipv4)"

  UPLOAD_ADDRESS="$(prompt_required "上行地址（CDN 域名）" "${UPLOAD_ADDRESS:-}")"
  DOWNLOAD_ADDRESS="$(prompt_required "下行地址（直连域名或 IP，建议域名）" "${DOWNLOAD_ADDRESS:-${auto_v4}}")"
  PORT="$(prompt_port "${PORT:-443}")"
  port_maybe_busy_warning "${PORT}"

  UPLOAD_SNI="$(prompt_required "上传侧 TLS SNI" "${UPLOAD_SNI:-${UPLOAD_ADDRESS}}")"
  DOWNLOAD_SNI="$(prompt_required "下行侧 TLS SNI" "${DOWNLOAD_SNI:-${DOWNLOAD_ADDRESS}}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(openssl rand -hex 6)}")"
  XHTTP_MODE="$(choose_xhttp_mode "${XHTTP_MODE:-auto}" "no")"
  FINGERPRINT="$(prompt_required "客户端 fingerprint" "${FINGERPRINT:-chrome}")"
  TLS_CERT_FILE="$(prompt_existing_file "证书文件 certificateFile" "${TLS_CERT_FILE:-/etc/ssl/xray/fullchain.pem}")"
  TLS_KEY_FILE="$(prompt_existing_file "私钥文件 keyFile" "${TLS_KEY_FILE:-/etc/ssl/xray/private.key}")"
  NODE_NAME="$(prompt_required "节点备注名" "${NODE_NAME:-VLESS-XHTTP-CDNUP-VPSDOWN}")"

  SNI=""
  REALITY_DEST=""
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  SHORT_ID=""
  SPIDERX=""
  BACKEND_ADDRESS=""
  BACKEND_PORT=""

  maybe_refresh_uuid
}

collect_inputs_for_selected_mode() {
  DEPLOY_MODE="$(choose_deploy_mode "${DEPLOY_MODE:-single_reality}")"

  case "${DEPLOY_MODE}" in
    single_reality)
      collect_single_reality_inputs
      ;;
    split_dualstack_reality)
      collect_split_dualstack_reality_inputs
      ;;
    split_dualvps_reality_backend)
      collect_split_dualvps_reality_backend_inputs
      ;;
    split_dualvps_reality_proxy)
      collect_split_dualvps_reality_proxy_inputs
      ;;
    split_cdn_tls_backend)
      collect_split_cdn_tls_backend_inputs
      ;;
    *)
      die "未知部署模式。"
      ;;
  esac
}

build_reality_server_names_block() {
  local primary secondary
  primary="${UPLOAD_SNI:-${SNI}}"
  secondary="${DOWNLOAD_SNI:-${SNI}}"

  if [[ -n "${primary}" && -n "${secondary}" && "${primary}" != "${secondary}" ]]; then
    cat <<EOF
          "serverNames": [
            "$(json_escape "${primary}")",
            "$(json_escape "${secondary}")"
          ],
EOF
  else
    cat <<EOF
          "serverNames": [
            "$(json_escape "${primary}")"
          ],
EOF
  fi
}

write_xray_config() {
  local security_block

  install -d -m 755 "${CONFIG_DIR}"

  if is_reality_mode; then
    security_block="$(cat <<EOF
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$(json_escape "${REALITY_DEST}")",
          "xver": 0,
$(build_reality_server_names_block)
          "privateKey": "$(json_escape "${REALITY_PRIVATE_KEY}")",
          "shortIds": [
            "$(json_escape "${SHORT_ID}")"
          ]
        },
EOF
)"
  else
    security_block="$(cat <<EOF
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "$(json_escape "${TLS_CERT_FILE}")",
              "keyFile": "$(json_escape "${TLS_KEY_FILE}")"
            }
          ]
        },
EOF
)"
  fi

  cat > "${CONFIG_FILE}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-xhttp-in",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(json_escape "${UUID}")"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
${security_block}
        "xhttpSettings": {
          "path": "$(json_escape "${XHTTP_PATH}")",
          "mode": "$(json_escape "${XHTTP_MODE}")"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ]
}
EOF
}

test_xray_config() {
  [[ -x "${XRAY_BIN}" ]] || die "未检测到 ${XRAY_BIN}"
  "${XRAY_BIN}" run -test -config "${CONFIG_FILE}" >/dev/null
}

restart_xray_service() {
  ensure_xray_service_file
  systemctl restart xray
  systemctl enable xray >/dev/null 2>&1 || true
}

write_proxy_config() {
  local backend_host

  install -d -m 755 "$(dirname "${PROXY_CONFIG_FILE}")"
  backend_host="$(format_haproxy_host "${BACKEND_ADDRESS}")"

  cat > "${PROXY_CONFIG_FILE}" <<EOF
global
  maxconn 4096

defaults
  mode tcp
  timeout connect 10s
  timeout client 1h
  timeout server 1h

frontend ${PROXY_SERVICE_NAME}_front
  bind :::${PORT} v4v6
  default_backend ${PROXY_SERVICE_NAME}_back

backend ${PROXY_SERVICE_NAME}_back
  server xray_backend ${backend_host}:${BACKEND_PORT} check
EOF
}

write_proxy_service_file() {
  cat > "${PROXY_SERVICE_FILE}" <<EOF
[Unit]
Description=XHTTP Upload TCP Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/sbin/haproxy -db -f ${PROXY_CONFIG_FILE}
ExecStop=/bin/kill -TERM \$MAINPID
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${PROXY_SERVICE_NAME}" >/dev/null 2>&1 || true
}

test_proxy_config() {
  /usr/sbin/haproxy -c -f "${PROXY_CONFIG_FILE}" >/dev/null
}

restart_proxy_service() {
  write_proxy_service_file
  systemctl restart "${PROXY_SERVICE_NAME}"
  systemctl enable "${PROXY_SERVICE_NAME}" >/dev/null 2>&1 || true
}

maybe_open_ufw_port() {
  if command_exists ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    log "检测到 UFW 已启用，已尝试放行 ${PORT}/tcp"
  fi
}

build_base_share_link() {
  local server_host fragment query
  local params=()

  server_host="$(format_uri_host "${UPLOAD_ADDRESS}")"
  params+=("encryption=none")
  params+=("type=xhttp")
  params+=("path=$(urlencode "${XHTTP_PATH}")")
  params+=("mode=$(urlencode "${XHTTP_MODE}")")

  if is_reality_mode; then
    params+=("security=reality")
    params+=("sni=$(urlencode "${UPLOAD_SNI:-${SNI}}")")
    params+=("fp=$(urlencode "${FINGERPRINT}")")
    params+=("pbk=$(urlencode "${REALITY_PUBLIC_KEY}")")
    params+=("sid=$(urlencode "${SHORT_ID}")")
    params+=("spx=$(urlencode "${SPIDERX}")")
  else
    params+=("security=tls")
    params+=("sni=$(urlencode "${UPLOAD_SNI}")")
    params+=("fp=$(urlencode "${FINGERPRINT}")")
    params+=("alpn=h2")
  fi

  query="$(IFS='&'; printf '%s' "${params[*]}")"
  fragment="$(urlencode "${NODE_NAME}")"

  printf 'vless://%s@%s:%s?%s#%s\n' \
    "$(urlencode "${UUID}")" \
    "${server_host}" \
    "${PORT}" \
    "${query}" \
    "${fragment}"
}

write_client_patch_file() {
  if ! is_split_mode; then
    : > "${CLIENT_PATCH_FILE}"
    return 0
  fi

  if is_reality_mode; then
    cat > "${CLIENT_PATCH_FILE}" <<EOF
{
  "downloadSettings": {
    "address": "$(json_escape "${DOWNLOAD_ADDRESS}")",
    "port": ${PORT},
    "network": "xhttp",
    "security": "reality",
    "realitySettings": {
      "serverName": "$(json_escape "${DOWNLOAD_SNI:-${SNI}}")",
      "fingerprint": "$(json_escape "${FINGERPRINT}")",
      "publicKey": "$(json_escape "${REALITY_PUBLIC_KEY}")",
      "shortId": "$(json_escape "${SHORT_ID}")",
      "spiderX": "$(json_escape "${SPIDERX}")"
    },
    "xhttpSettings": {
      "path": "$(json_escape "${XHTTP_PATH}")",
      "mode": "$(json_escape "${XHTTP_MODE}")"
    }
  }
}
EOF
  else
    cat > "${CLIENT_PATCH_FILE}" <<EOF
{
  "downloadSettings": {
    "address": "$(json_escape "${DOWNLOAD_ADDRESS}")",
    "port": ${PORT},
    "network": "xhttp",
    "security": "tls",
    "tlsSettings": {
      "serverName": "$(json_escape "${DOWNLOAD_SNI}")",
      "fingerprint": "$(json_escape "${FINGERPRINT}")"
    },
    "xhttpSettings": {
      "path": "$(json_escape "${XHTTP_PATH}")",
      "mode": "$(json_escape "${XHTTP_MODE}")"
    }
  }
}
EOF
  fi
}

build_client_download_settings_block() {
  if ! is_split_mode; then
    return 0
  fi

  if is_reality_mode; then
    cat <<EOF
      "downloadSettings": {
        "address": "$(json_escape "${DOWNLOAD_ADDRESS}")",
        "port": ${PORT},
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "serverName": "$(json_escape "${DOWNLOAD_SNI:-${SNI}}")",
          "fingerprint": "$(json_escape "${FINGERPRINT}")",
          "publicKey": "$(json_escape "${REALITY_PUBLIC_KEY}")",
          "shortId": "$(json_escape "${SHORT_ID}")",
          "spiderX": "$(json_escape "${SPIDERX}")"
        },
        "xhttpSettings": {
          "path": "$(json_escape "${XHTTP_PATH}")",
          "mode": "$(json_escape "${XHTTP_MODE}")"
        }
      }
EOF
  else
    cat <<EOF
      "downloadSettings": {
        "address": "$(json_escape "${DOWNLOAD_ADDRESS}")",
        "port": ${PORT},
        "network": "xhttp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "$(json_escape "${DOWNLOAD_SNI}")",
          "fingerprint": "$(json_escape "${FINGERPRINT}")"
        },
        "xhttpSettings": {
          "path": "$(json_escape "${XHTTP_PATH}")",
          "mode": "$(json_escape "${XHTTP_MODE}")"
        }
      }
EOF
  fi
}

write_client_outbound_file() {
  local security_block
  local download_block

  if ! is_xray_mode; then
    : > "${CLIENT_OUTBOUND_FILE}"
    return 0
  fi

  if is_reality_mode; then
    security_block="$(cat <<EOF
    "security": "reality",
    "realitySettings": {
      "serverName": "$(json_escape "${UPLOAD_SNI:-${SNI}}")",
      "fingerprint": "$(json_escape "${FINGERPRINT}")",
      "publicKey": "$(json_escape "${REALITY_PUBLIC_KEY}")",
      "shortId": "$(json_escape "${SHORT_ID}")",
      "spiderX": "$(json_escape "${SPIDERX}")"
    },
EOF
)"
  else
    security_block="$(cat <<EOF
    "security": "tls",
    "tlsSettings": {
      "serverName": "$(json_escape "${UPLOAD_SNI}")",
      "fingerprint": "$(json_escape "${FINGERPRINT}")"
    },
EOF
)"
  fi

  download_block="$(build_client_download_settings_block || true)"

  cat > "${CLIENT_OUTBOUND_FILE}" <<EOF
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "$(json_escape "${UPLOAD_ADDRESS}")",
        "port": ${PORT},
        "users": [
          {
            "id": "$(json_escape "${UUID}")",
            "encryption": "none"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "xhttp",
${security_block}
    "xhttpSettings": {
      "path": "$(json_escape "${XHTTP_PATH}")",
      "mode": "$(json_escape "${XHTTP_MODE}")"$(if [[ -n "${download_block}" ]]; then printf ','; fi)
${download_block}
    }
  }
}
EOF
}

write_client_readme_file() {
  local link

  if ! is_xray_mode; then
    cat > "${CLIENT_README_FILE}" <<EOF
当前模式是上传代理模式，不生成节点链接。

当前机器角色:
- 模式: $(mode_label)
- 监听端口: ${PORT}
- 转发到后端: ${BACKEND_ADDRESS}:${BACKEND_PORT}

用法:
1. 先在 VPS2 运行本脚本，选择“当前机器部署 VPS2 后端”
2. 再在 VPS1 运行本脚本，选择“当前机器部署 VPS1 上传代理”
3. 客户端使用 VPS2 后端脚本输出的基础链接和补丁
EOF
    return 0
  fi

  link="$(build_base_share_link)"

  if ! is_split_mode; then
    cat > "${CLIENT_README_FILE}" <<EOF
当前模式:
- $(mode_label)

基础 vless 链接:
${link}

使用方式:
1. 直接把上面的链接导入支持 XHTTP 的客户端
2. 不需要再补 downloadSettings

本机生成文件:
- 基础链接: ${CLIENT_LINK_FILE}
- outbound 示例: ${CLIENT_OUTBOUND_FILE}
EOF
    return 0
  fi

  cat > "${CLIENT_README_FILE}" <<EOF
当前模式:
- $(mode_label)

基础 vless 链接:
${link}

这类“上/下行分离”模式，标准 vless:// 链接本身不够用。
正确做法是:
1. 先导入上面的基础链接
2. 打开该节点的高级配置 / 自定义 JSON / 底层 outbound
3. 在该节点的 xhttpSettings 下，补上 ${CLIENT_PATCH_FILE} 里的 downloadSettings

如果客户端支持直接导入/粘贴 outbound JSON:
- 直接参考: ${CLIENT_OUTBOUND_FILE}

客户端需要补的核心逻辑:
- 上传地址: ${UPLOAD_ADDRESS}:${PORT}
- 下行地址: ${DOWNLOAD_ADDRESS}:${PORT}
- path: ${XHTTP_PATH}
- mode: ${XHTTP_MODE}
- security: ${SECURITY_MODE}

如果客户端完全不支持自定义 JSON:
- 这类分离上下行模式无法只靠纯 vless:// 链接使用
- 只能换支持自定义 Xray JSON 的客户端，或回退到普通单 VPS 模式
EOF
}

write_client_artifacts() {
  if ! is_xray_mode; then
    : > "${CLIENT_LINK_FILE}"
    : > "${CLIENT_PATCH_FILE}"
    : > "${CLIENT_OUTBOUND_FILE}"
    write_client_readme_file
    chmod 600 "${CLIENT_LINK_FILE}" "${CLIENT_PATCH_FILE}" "${CLIENT_OUTBOUND_FILE}" "${CLIENT_README_FILE}"
    return 0
  fi

  build_base_share_link > "${CLIENT_LINK_FILE}"
  chmod 600 "${CLIENT_LINK_FILE}"

  write_client_patch_file
  write_client_outbound_file
  write_client_readme_file

  chmod 600 "${CLIENT_PATCH_FILE}" "${CLIENT_OUTBOUND_FILE}" "${CLIENT_README_FILE}"
}

apply_xray_mode() {
  require_root
  ensure_xray_installed
  write_xray_config
  test_xray_config
  ensure_xray_service_file
  save_meta
  write_client_artifacts
  maybe_open_ufw_port
  restart_xray_service
}

apply_proxy_mode() {
  require_root
  install_dependencies_proxy
  write_proxy_config
  test_proxy_config
  write_proxy_service_file
  save_meta
  write_client_artifacts
  maybe_open_ufw_port
  restart_proxy_service
}

configure_and_apply() {
  require_root
  load_existing_meta_if_any
  collect_inputs_for_selected_mode

  if is_xray_mode; then
    apply_xray_mode
  else
    apply_proxy_mode
  fi

  show_summary
}

active_service_name() {
  if [[ -n "${ACTIVE_SERVICE:-}" ]]; then
    printf '%s' "${ACTIVE_SERVICE}"
    return 0
  fi

  if is_xray_mode; then
    printf 'xray'
  else
    printf '%s' "${PROXY_SERVICE_NAME}"
  fi
}

show_summary() {
  local service_name link
  service_name="$(active_service_name)"

  cat <<EOF

部署完成。

当前模式:
- $(mode_label)

服务信息:
- 服务名: ${service_name}
EOF

  if is_xray_mode; then
    link="$(build_base_share_link)"
    cat <<EOF
- Xray: ${XRAY_BIN}
- 配置文件: ${CONFIG_FILE}
- systemd: ${XRAY_SERVICE_FILE}

节点参数:
- 上传地址: ${UPLOAD_ADDRESS}
- 端口: ${PORT}
- UUID: ${UUID}
- XHTTP path: ${XHTTP_PATH}
- XHTTP mode: ${XHTTP_MODE}
- 节点备注: ${NODE_NAME}
EOF

    if is_reality_mode; then
      cat <<EOF
- 安全层: REALITY
- SNI: ${UPLOAD_SNI:-${SNI}}
- REALITY dest: ${REALITY_DEST}
- PublicKey: ${REALITY_PUBLIC_KEY}
- ShortId: ${SHORT_ID}
- Fingerprint: ${FINGERPRINT}
- SpiderX: ${SPIDERX}
EOF
    else
      cat <<EOF
- 安全层: TLS
- 上传 SNI: ${UPLOAD_SNI}
- 下行 SNI: ${DOWNLOAD_SNI}
- Fingerprint: ${FINGERPRINT}
- 证书: ${TLS_CERT_FILE}
- 私钥: ${TLS_KEY_FILE}
EOF
    fi

    if is_split_mode; then
      cat <<EOF
- 下行地址: ${DOWNLOAD_ADDRESS}
EOF
    fi

    cat <<EOF

基础 vless 链接:
${link}

客户端文件:
- 基础链接: ${CLIENT_LINK_FILE}
- 客户端说明: ${CLIENT_README_FILE}
- outbound JSON: ${CLIENT_OUTBOUND_FILE}
EOF

    if is_split_mode; then
      cat <<EOF
- 分离上下行补丁: ${CLIENT_PATCH_FILE}

使用提醒:
- 先导入上面的基础链接
- 再按 ${CLIENT_README_FILE} 的说明补 downloadSettings
EOF
    else
      cat <<EOF

使用提醒:
- 普通单机模式，直接导入上面的链接即可
EOF
    fi
  else
    cat <<EOF
- 代理配置: ${PROXY_CONFIG_FILE}
- systemd: ${PROXY_SERVICE_FILE}
- 监听端口: ${PORT}
- 转发后端: ${BACKEND_ADDRESS}:${BACKEND_PORT}
- 当前机器公网地址参考: ${UPLOAD_ADDRESS}
- 说明文件: ${CLIENT_README_FILE}

使用提醒:
- 这是上传代理角色，不直接生成节点链接
- 节点链接和补丁请看 VPS2 后端机器上的输出
EOF
  fi

  cat <<EOF

常用操作:
- 查看状态: systemctl status ${service_name}
- 重启服务: systemctl restart ${service_name}
- 查看日志: journalctl -u ${service_name} -f
- 重新进入菜单: bash ${SCRIPT_NAME}
EOF
}

show_current_info() {
  require_root
  [[ -f "${META_FILE}" ]] || die "未检测到历史部署信息: ${META_FILE}"
  load_existing_meta_if_any
  show_summary
}

show_service_status() {
  local service_name
  service_name="$(active_service_name)"
  systemctl status "${service_name}" --no-pager || true
}

service_menu() {
  require_root
  load_existing_meta_if_any

  local service_name
  service_name="$(active_service_name)"

  while true; do
    cat <<EOF

服务管理:
当前服务: ${service_name}
1. 查看状态
2. 启动服务
3. 重启服务
4. 停止服务
0. 返回上一级
EOF
    case "$(prompt_default "请选择" "1")" in
      1) show_service_status ;;
      2) systemctl start "${service_name}" ;;
      3) systemctl restart "${service_name}" ;;
      4) systemctl stop "${service_name}" ;;
      0) return 0 ;;
      *) warn "请输入 0-4。" ;;
    esac
  done
}

update_core_only() {
  require_root
  load_existing_meta_if_any

  if ! is_xray_mode; then
    die "当前部署不是 Xray 后端模式，不能更新 Xray 内核。"
  fi

  install_or_update_xray_core
  ensure_xray_service_file
  if systemctl is-active --quiet xray; then
    systemctl restart xray
  fi
  log "Xray 内核已更新。"
}

uninstall_all() {
  require_root

  if ! prompt_yes_no "确认卸载脚本部署的 Xray / 上传代理 / 配置文件吗" "n"; then
    log "已取消卸载。"
    return 0
  fi

  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true
  rm -f "${XRAY_SERVICE_FILE}"

  systemctl stop "${PROXY_SERVICE_NAME}" >/dev/null 2>&1 || true
  systemctl disable "${PROXY_SERVICE_NAME}" >/dev/null 2>&1 || true
  rm -f "${PROXY_SERVICE_FILE}"

  systemctl daemon-reload

  rm -f "${XRAY_BIN}"
  rm -rf "${CONFIG_DIR}"
  rm -f "${PROXY_CONFIG_FILE}"

  log "卸载完成。"
}

main_menu() {
  while true; do
    banner
    cat <<'EOF'
1. 安装 / 重装
2. 查看当前配置和客户端信息
3. 服务管理
4. 更新 Xray 内核
5. 卸载
0. 退出
EOF

    case "$(prompt_default "请选择" "1")" in
      1) configure_and_apply ;;
      2) show_current_info ;;
      3) service_menu ;;
      4) update_core_only ;;
      5) uninstall_all ;;
      0) exit 0 ;;
      *) warn "请输入 0-5。" ;;
    esac

    echo
    read -r -p "按回车继续..." _
    clear || true
  done
}

case "${1:-menu}" in
  menu)
    main_menu
    ;;
  install)
    configure_and_apply
    ;;
  show)
    show_current_info
    ;;
  service)
    service_menu
    ;;
  update-core)
    update_core_only
    ;;
  uninstall)
    uninstall_all
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    warn "未知参数: ${1}"
    usage
    exit 1
    ;;
esac
