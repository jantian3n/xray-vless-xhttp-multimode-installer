#!/usr/bin/env bash

set -euo pipefail

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
NONINTERACTIVE="${NONINTERACTIVE:-0}"

NAV_IDS=(overview deploy artifacts service maintenance briefing quit)
NAV_LABELS=(
  "总览"
  "部署向导"
  "档案 / 客户端"
  "服务控制"
  "维护"
  "帮助"
  "退出"
)

selected_index=0
running=1
ui_ready=0
term_cols=0
term_lines=0
log_capacity=8
LOG_LINES=()
last_term_cols=0
last_term_lines=0
screen_needs_clear=1
screen_small=0

state_mode_id=""
state_mode_label="未部署"
state_service_name="-"
state_service_active="n/a"
state_service_enabled="n/a"
state_upload="-"
state_download="-"
state_port="-"
state_security="-"
state_node_name="-"
state_uuid="-"
state_meta_exists="no"
state_config_exists="no"
state_xray_bin="no"
state_client_link="no"
state_client_readme="no"
state_client_patch="no"
state_client_outbound="no"
state_root_note="当前不是 root，部分部署元数据可能不可见"
last_dossier="尚未读取部署档案。进入“档案 / 客户端”后按回车可获取最新信息。"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

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

is_noninteractive() {
  [[ "${NONINTERACTIVE:-0}" == "1" ]]
}

append_log() {
  LOG_LINES+=("[$(date '+%H:%M:%S')] $*")
  while ((${#LOG_LINES[@]} > log_capacity)); do
    LOG_LINES=("${LOG_LINES[@]:1}")
  done
}

restore_terminal() {
  if [[ "${ui_ready}" == "1" ]]; then
    printf '\033[0m\033[?25h\033[?1049l' >/dev/tty 2>/dev/null || true
  fi
}

trap 'restore_terminal' EXIT

color_reset() { printf '\033[0m'; }
color_header() { printf '\033[1;30;43m'; }
color_accent() { printf '\033[1;33m'; }
color_focus() { printf '\033[1;30;46m'; }
color_label() { printf '\033[1;36m'; }
color_warn() { printf '\033[1;31m'; }
color_dim() { printf '\033[37m'; }
color_success() { printf '\033[1;32m'; }

show_cursor() { printf '\033[?25h'; }
hide_cursor() { printf '\033[?25l'; }

get_terminal_size() {
  local size
  size="$(stty size 2>/dev/null || true)"
  if [[ -n "${size}" ]]; then
    term_lines="${size%% *}"
    term_cols="${size##* }"
  else
    term_lines="${LINES:-24}"
    term_cols="${COLUMNS:-80}"
  fi
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i
  for ((i = 0; i < count; i++)); do
    out+="${char}"
  done
  printf '%s' "${out}"
}

move_to() {
  printf '\033[%s;%sH' "$(( $1 + 1 ))" "$(( $2 + 1 ))"
}

print_at() {
  local row="$1"
  local col="$2"
  local text="$3"
  local style="${4:-}"
  move_to "${row}" "${col}"
  if [[ -n "${style}" ]]; then
    printf '%s%s%s' "${style}" "${text}" "$(color_reset)"
  else
    printf '%s' "${text}"
  fi
}

erase_row() {
  local row="$1"
  move_to "${row}" 0
  printf '%s' "$(repeat_char ' ' "${term_cols}")"
}

clear_region() {
  local top="$1"
  local left="$2"
  local height="$3"
  local width="$4"
  local row
  local blank
  blank="$(repeat_char ' ' "${width}")"
  for ((row = top; row < top + height; row++)); do
    move_to "${row}" "${left}"
    printf '%s' "${blank}"
  done
}

draw_box() {
  local top="$1"
  local left="$2"
  local height="$3"
  local width="$4"
  local title="$5"
  local style="$6"
  local inner_width=$((width - 2))
  local r

  print_at "${top}" "${left}" "+$(repeat_char '-' "${inner_width}")+" "${style}"
  for ((r = top + 1; r < top + height - 1; r++)); do
    print_at "${r}" "${left}" "|" "${style}"
    print_at "${r}" $((left + width - 1)) "|" "${style}"
    print_at "${r}" $((left + 1)) "$(repeat_char ' ' "${inner_width}")"
  done
  print_at $((top + height - 1)) "${left}" "+$(repeat_char '-' "${inner_width}")+" "${style}"
  if [[ -n "${title}" && ${#title} -lt $((inner_width - 2)) ]]; then
    print_at "${top}" $((left + 2)) " ${title} " "${style}"
  fi
}

wrap_text() {
  local text="$1"
  local width="$2"
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" ]]; then
      printf '\n'
      continue
    fi
    printf '%s\n' "${line}" | fold -s -w "${width}"
  done <<< "${text}"
}

normalize_path_local() {
  local path="${1:-}"
  [[ -n "${path}" ]] || return 1
  if [[ "${path}" != /* ]]; then
    path="/${path}"
  fi
  printf '%s' "${path}"
}

normalize_dest_local() {
  local dest="${1:-}"
  [[ -n "${dest}" ]] || return 1
  if [[ "${dest}" == \[*\]:* ]]; then
    printf '%s' "${dest}"
    return 0
  fi
  if [[ "${dest}" =~ ^[0-9A-Fa-f:]+$ ]]; then
    printf '[%s]:443' "${dest}"
  elif [[ "${dest}" == *:* ]]; then
    printf '%s' "${dest}"
  else
    printf '%s:443' "${dest}"
  fi
}

normalize_spiderx_local() {
  local spiderx="${1:-/}"
  [[ -n "${spiderx}" ]] || spiderx="/"
  if [[ "${spiderx}" != /* ]]; then
    spiderx="/${spiderx}"
  fi
  printf '%s' "${spiderx}"
}

validate_port() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

random_hex() {
  if command_exists openssl; then
    openssl rand -hex 6
  else
    date '+%s%N' | sha256sum | cut -c1-12
  fi
}

detect_public_ipv4_local() {
  local address=""
  if command_exists curl; then
    address="$(curl -4 -fsSL https://api64.ipify.org 2>/dev/null || true)"
  fi
  if [[ -z "${address}" ]]; then
    address="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  printf '%s' "${address}"
}

detect_public_ipv6_local() {
  local address=""
  if command_exists curl; then
    address="$(curl -6 -fsSL https://api64.ipify.org 2>/dev/null || true)"
  fi
  printf '%s' "${address}"
}

detect_public_address_local() {
  local address
  address="$(detect_public_ipv4_local)"
  if [[ -z "${address}" ]]; then
    address="$(detect_public_ipv6_local)"
  fi
  printf '%s' "${address}"
}

meta_readable() {
  [[ -r "${META_FILE}" ]]
}

service_name_from_mode() {
  case "$1" in
    single_reality|split_dualstack_reality|split_dualvps_reality_backend|split_cdn_tls_backend)
      printf 'xray'
      ;;
    split_dualvps_reality_proxy)
      printf '%s' "${PROXY_SERVICE_NAME}"
      ;;
    *)
      printf '-'
      ;;
  esac
}

mode_label_from_id() {
  case "$1" in
    single_reality) printf '单 VPS：VLESS + XHTTP + REALITY' ;;
    split_dualstack_reality) printf '同机分离：IPv6 上行 + IPv4 下行' ;;
    split_dualvps_reality_backend) printf '双 VPS：后端 / 下行服务器' ;;
    split_dualvps_reality_proxy) printf '双 VPS：上行代理' ;;
    split_cdn_tls_backend) printf 'CDN 上行 + VPS 下行：TLS + XHTTP' ;;
    *) printf '未部署' ;;
  esac
}

mode_short_label_from_id() {
  case "$1" in
    single_reality) printf '单 VPS' ;;
    split_dualstack_reality) printf '同机分离' ;;
    split_dualvps_reality_backend) printf '双 VPS 后端' ;;
    split_dualvps_reality_proxy) printf '双 VPS 上行代理' ;;
    split_cdn_tls_backend) printf 'CDN + VPS' ;;
    *) printf '未部署' ;;
  esac
}

xhttp_mode_label() {
  case "$1" in
    auto) printf 'auto' ;;
    packet-up) printf 'packet-up' ;;
    stream-up) printf 'stream-up' ;;
    stream-one) printf 'stream-one' ;;
    *) printf '%s' "$1" ;;
  esac
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

normalize_path() {
  normalize_path_local "$@"
}

normalize_dest() {
  normalize_dest_local "$@"
}

normalize_spiderx() {
  normalize_spiderx_local "$@"
}

detect_public_ipv4() {
  detect_public_ipv4_local
}

detect_public_ipv6() {
  detect_public_ipv6_local
}

detect_public_address() {
  detect_public_address_local
}

prompt_default() {
  local prompt="${1}"
  local default="${2-}"
  local reply

  if is_noninteractive; then
    printf '%s' "${default}"
    return 0
  fi

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

  if is_noninteractive; then
    if [[ "${default}" == "y" ]]; then
      return 0
    fi
    return 1
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

is_xray_mode() {
  [[ "${SERVICE_KIND:-}" == "xray" ]]
}

is_split_mode() {
  case "${DEPLOY_MODE:-}" in
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
  mode_label_from_id "${DEPLOY_MODE:-}"
}

default_mode_number() {
  case "${1:-single_reality}" in
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

  while true; do
    choice="$(prompt_default "输入序号" "$(default_mode_number "${current}")")"
    case "${choice}" in
      1) printf 'single_reality'; return 0 ;;
      2) printf 'split_dualstack_reality'; return 0 ;;
      3) printf 'split_dualvps_reality_backend'; return 0 ;;
      4) printf 'split_dualvps_reality_proxy'; return 0 ;;
      5) printf 'split_cdn_tls_backend'; return 0 ;;
      *)
        if is_noninteractive; then
          die "非交互安装时 DEPLOY_MODE 无效，请传入 single_reality / split_dualstack_reality / split_dualvps_reality_backend / split_dualvps_reality_proxy / split_cdn_tls_backend。"
        fi
        warn "请输入 1-5。"
        ;;
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
        if is_noninteractive; then
          die "当前部署模式不支持非交互选择 stream-one。"
        fi
        warn "当前模式不建议使用 stream-one。"
        ;;
      *)
        if is_noninteractive; then
          die "非交互安装时 XHTTP_MODE 无效，请传入 auto / packet-up / stream-up / stream-one。"
        fi
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
    if is_noninteractive; then
      die "非交互安装缺少必填项：${prompt}"
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
    if is_noninteractive; then
      die "非交互安装端口无效：${reply:-<empty>}"
    fi
    warn "端口必须是 1-65535 的整数。"
  done
}

prompt_path() {
  local default="${1:-/$(random_hex)}"
  local reply

  while true; do
    reply="$(prompt_default "XHTTP path" "${default}")"
    reply="$(normalize_path "${reply}")" || true
    if [[ -n "${reply}" ]]; then
      printf '%s' "${reply}"
      return 0
    fi
    if is_noninteractive; then
      die "非交互安装的 XHTTP path 无效。"
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
    if is_noninteractive; then
      die "非交互安装的 dest 无效：${prompt}"
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
    if is_noninteractive; then
      die "非交互安装要求文件存在，但未找到：${reply:-<empty>}"
    fi
    warn "文件不存在: ${reply}"
  done
}

load_noninteractive_env_inputs() {
  if [[ -n "${XRAY_GUI_DEPLOY_MODE:-}" ]]; then
    case "${XRAY_GUI_DEPLOY_MODE}" in
      single_reality|split_dualstack_reality|split_dualvps_reality_backend|split_dualvps_reality_proxy|split_cdn_tls_backend)
        DEPLOY_MODE="${XRAY_GUI_DEPLOY_MODE}"
        ;;
      *)
        die "XRAY_GUI_DEPLOY_MODE 无效：${XRAY_GUI_DEPLOY_MODE}"
        ;;
    esac
  fi
  [[ -n "${XRAY_GUI_PORT:-}" ]] && PORT="${XRAY_GUI_PORT}"
  [[ -n "${XRAY_GUI_UPLOAD_ADDRESS:-}" ]] && UPLOAD_ADDRESS="${XRAY_GUI_UPLOAD_ADDRESS}"
  [[ -n "${XRAY_GUI_DOWNLOAD_ADDRESS:-}" ]] && DOWNLOAD_ADDRESS="${XRAY_GUI_DOWNLOAD_ADDRESS}"
  [[ -n "${XRAY_GUI_BACKEND_ADDRESS:-}" ]] && BACKEND_ADDRESS="${XRAY_GUI_BACKEND_ADDRESS}"
  [[ -n "${XRAY_GUI_BACKEND_PORT:-}" ]] && BACKEND_PORT="${XRAY_GUI_BACKEND_PORT}"
  [[ -n "${XRAY_GUI_SNI:-}" ]] && SNI="${XRAY_GUI_SNI}"
  [[ -n "${XRAY_GUI_UPLOAD_SNI:-}" ]] && UPLOAD_SNI="${XRAY_GUI_UPLOAD_SNI}"
  [[ -n "${XRAY_GUI_DOWNLOAD_SNI:-}" ]] && DOWNLOAD_SNI="${XRAY_GUI_DOWNLOAD_SNI}"
  [[ -n "${XRAY_GUI_REALITY_DEST:-}" ]] && REALITY_DEST="${XRAY_GUI_REALITY_DEST}"
  [[ -n "${XRAY_GUI_TLS_CERT_FILE:-}" ]] && TLS_CERT_FILE="${XRAY_GUI_TLS_CERT_FILE}"
  [[ -n "${XRAY_GUI_TLS_KEY_FILE:-}" ]] && TLS_KEY_FILE="${XRAY_GUI_TLS_KEY_FILE}"
  [[ -n "${XRAY_GUI_FINGERPRINT:-}" ]] && FINGERPRINT="${XRAY_GUI_FINGERPRINT}"
  [[ -n "${XRAY_GUI_SPIDERX:-}" ]] && SPIDERX="${XRAY_GUI_SPIDERX}"
  [[ -n "${XRAY_GUI_XHTTP_PATH:-}" ]] && XHTTP_PATH="${XRAY_GUI_XHTTP_PATH}"
  if [[ -n "${XRAY_GUI_XHTTP_MODE:-}" ]]; then
    case "${XRAY_GUI_XHTTP_MODE}" in
      auto|packet-up|stream-up|stream-one)
        XHTTP_MODE="${XRAY_GUI_XHTTP_MODE}"
        ;;
      *)
        die "XRAY_GUI_XHTTP_MODE 无效：${XRAY_GUI_XHTTP_MODE}"
        ;;
    esac
  fi
  [[ -n "${XRAY_GUI_NODE_NAME:-}" ]] && NODE_NAME="${XRAY_GUI_NODE_NAME}"
  [[ -n "${XRAY_GUI_UUID:-}" ]] && UUID="${XRAY_GUI_UUID}"
  [[ -n "${XRAY_GUI_REALITY_PRIVATE_KEY:-}" ]] && REALITY_PRIVATE_KEY="${XRAY_GUI_REALITY_PRIVATE_KEY}"
  [[ -n "${XRAY_GUI_REALITY_PUBLIC_KEY:-}" ]] && REALITY_PUBLIC_KEY="${XRAY_GUI_REALITY_PUBLIC_KEY}"
  [[ -n "${XRAY_GUI_SHORT_ID:-}" ]] && SHORT_ID="${XRAY_GUI_SHORT_ID}"
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
  local response tag

  response="$(
    curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H "User-Agent: ${SCRIPT_NAME}" \
      "${GITHUB_API}"
  )" || die "请求 GitHub API 失败，请检查 VPS 到 api.github.com 的连通性。"

  tag="$(
    printf '%s' "${response}" \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\(v[^"]*\)".*/\1/p' \
      | head -n 1
  )"

  if [[ -z "${tag}" ]]; then
    if printf '%s' "${response}" | grep -q '"API rate limit exceeded"'; then
      die "获取 Xray 最新版本失败：GitHub API 触发了速率限制。"
    fi
    die "获取 Xray 最新版本失败：GitHub API 返回中未找到 tag_name。"
  fi

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
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${output}" | awk -F': ' '/^PrivateKey: /{print $2; exit}')"
  REALITY_PUBLIC_KEY="$(
    printf '%s\n' "${output}" | awk -F': ' '
      /^Password \(PublicKey\): / { print $2; exit }
      /^Password: / { print $2; exit }
      /^PublicKey: / { print $2; exit }
      /^Public key: / { print $2; exit }
    '
  )"

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

  SNI="$(prompt_required "REALITY 的 SNI / serverName" "${SNI:-download-installer.cdn.mozilla.net}")"
  UPLOAD_SNI="${SNI}"
  DOWNLOAD_SNI="${SNI}"
  REALITY_DEST="$(prompt_dest "REALITY 目标站 dest（默认跟 SNI 走 443）" "${REALITY_DEST:-${SNI}:443}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(random_hex)}")"
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

  SNI="$(prompt_required "REALITY 的 SNI / serverName" "${SNI:-download-installer.cdn.mozilla.net}")"
  UPLOAD_SNI="${SNI}"
  DOWNLOAD_SNI="${SNI}"
  REALITY_DEST="$(prompt_dest "REALITY 目标站 dest（默认跟 SNI 走 443）" "${REALITY_DEST:-${SNI}:443}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(random_hex)}")"
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

  SNI="$(prompt_required "REALITY 的 SNI / serverName" "${SNI:-download-installer.cdn.mozilla.net}")"
  UPLOAD_SNI="${SNI}"
  DOWNLOAD_SNI="${SNI}"
  REALITY_DEST="$(prompt_dest "REALITY 目标站 dest（默认跟 SNI 走 443）" "${REALITY_DEST:-${SNI}:443}")"
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(random_hex)}")"
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
  XHTTP_PATH="$(prompt_path "${XHTTP_PATH:-/$(random_hex)}")"
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

configure_and_apply_noninteractive() {
  require_root
  NONINTERACTIVE=1
  load_existing_meta_if_any
  load_noninteractive_env_inputs
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

capture_current_info() {
  if [[ ! -f "${META_FILE}" ]]; then
    printf '未检测到历史部署信息: %s\n' "${META_FILE}"
    return 1
  fi

  if [[ ! -r "${META_FILE}" ]]; then
    printf '当前账号没有权限读取 %s\n请使用 sudo 重新运行当前 GUI。\n' "${META_FILE}"
    return 1
  fi

  load_existing_meta_if_any
  show_summary
}

show_current_info() {
  capture_current_info
}

show_service_status() {
  local service_name
  service_name="$(active_service_name)"
  systemctl status "${service_name}" --no-pager || true
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

perform_uninstall() {
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

uninstall_all() {
  require_root

  if ! prompt_yes_no "确认卸载脚本部署的 Xray / 上传代理 / 配置文件吗" "n"; then
    log "已取消卸载。"
    return 0
  fi

  perform_uninstall
}

uninstall_all_no_prompt() {
  require_root
  perform_uninstall
}

reset_state() {
  state_mode_id=""
  state_mode_label="未部署"
  state_service_name="-"
  state_service_active="n/a"
  state_service_enabled="n/a"
  state_upload="-"
  state_download="-"
  state_port="-"
  state_security="-"
  state_node_name="-"
  state_uuid="-"
  state_meta_exists="no"
  state_config_exists="no"
  state_xray_bin="no"
  state_client_link="no"
  state_client_readme="no"
  state_client_patch="no"
  state_client_outbound="no"
}

refresh_state() {
  local meta_deploy_mode=""
  local meta_active_service=""
  local meta_upload=""
  local meta_download=""
  local meta_port=""
  local meta_security=""
  local meta_node_name=""
  local meta_uuid=""
  local active_out=""
  local enabled_out=""

  reset_state
  [[ -f "${META_FILE}" ]] && state_meta_exists="yes"
  [[ -f "${CONFIG_FILE}" ]] && state_config_exists="yes"
  [[ -x "${XRAY_BIN}" ]] && state_xray_bin="yes"
  [[ -f "${CLIENT_LINK_FILE}" ]] && state_client_link="yes"
  [[ -f "${CLIENT_README_FILE}" ]] && state_client_readme="yes"
  [[ -f "${CLIENT_PATCH_FILE}" ]] && state_client_patch="yes"
  [[ -f "${CLIENT_OUTBOUND_FILE}" ]] && state_client_outbound="yes"

  if meta_readable; then
    local DEPLOY_MODE=""
    local ACTIVE_SERVICE=""
    local UPLOAD_ADDRESS=""
    local DOWNLOAD_ADDRESS=""
    local PORT=""
    local SECURITY_MODE=""
    local NODE_NAME=""
    local UUID=""
    # shellcheck disable=SC1090
    source "${META_FILE}"
    meta_deploy_mode="${DEPLOY_MODE-}"
    meta_active_service="${ACTIVE_SERVICE-}"
    meta_upload="${UPLOAD_ADDRESS-}"
    meta_download="${DOWNLOAD_ADDRESS-}"
    meta_port="${PORT-}"
    meta_security="${SECURITY_MODE-}"
    meta_node_name="${NODE_NAME-}"
    meta_uuid="${UUID-}"
    state_root_note="已具备 root 可见权限"
  else
    if [[ ${EUID} -ne 0 && -f "${META_FILE}" ]]; then
      state_root_note="元数据受权限保护；建议用 sudo 运行以查看完整信息"
    else
      state_root_note="尚未发现部署元数据"
    fi
  fi

  state_mode_id="${meta_deploy_mode}"
  state_mode_label="$(mode_label_from_id "${meta_deploy_mode}")"
  if [[ -n "${meta_active_service}" ]]; then
    state_service_name="${meta_active_service}"
  else
    state_service_name="$(service_name_from_mode "${meta_deploy_mode}")"
  fi
  [[ -n "${meta_upload}" ]] && state_upload="${meta_upload}"
  [[ -n "${meta_download}" ]] && state_download="${meta_download}"
  [[ -n "${meta_port}" ]] && state_port="${meta_port}"
  [[ -n "${meta_security}" ]] && state_security="${meta_security}"
  [[ -n "${meta_node_name}" ]] && state_node_name="${meta_node_name}"
  [[ -n "${meta_uuid}" ]] && state_uuid="${meta_uuid}"

  if [[ "${state_service_name}" != "-" ]]; then
    active_out="$(systemctl is-active "${state_service_name}" 2>/dev/null || true)"
    enabled_out="$(systemctl is-enabled "${state_service_name}" 2>/dev/null || true)"
    state_service_active="${active_out:-unknown}"
    state_service_enabled="${enabled_out:-unknown}"
  fi

  append_log "已根据本地部署文件刷新状态。"
}

run_function_capture() {
  "$@" 2>&1 || true
}

center_text() {
  local row="$1"
  local text="$2"
  local style="${3:-}"
  local col=0
  if (( ${#text} < term_cols )); then
    col=$(((term_cols - ${#text}) / 2))
  fi
  print_at "${row}" "${col}" "${text}" "${style}"
}

active_nav_id() {
  printf '%s' "${NAV_IDS[${selected_index}]}"
}

nav_summary() {
  case "$1" in
    overview) printf '查看当前部署状态、服务态势和生成的客户端文件。' ;;
    deploy) printf '进入部署子菜单，运行安装向导或查看五种模式说明。' ;;
    artifacts) printf '查看部署摘要、vless 链接、补丁、outbound 和说明文件。' ;;
    service) printf '查看并控制当前机器上的 systemd 服务。' ;;
    maintenance) printf '在控制台内执行更新内核或卸载流程。' ;;
    briefing) printf '查看按键说明、运行方式和控制台行为。' ;;
    quit) printf '退出当前部署控制台。' ;;
    *) printf '' ;;
  esac
}

build_main_content() {
  local id="$1"
  case "${id}" in
    overview)
      cat <<EOF2
部署状态
- 模式：${state_mode_label}
- 服务：${state_service_name}
- 运行状态：${state_service_active}
- 开机自启：${state_service_enabled}
- 权限说明：${state_root_note}

部署信号
- 上行地址：${state_upload}
- 下行地址：${state_download}
- 端口：${state_port}
- 安全层：${state_security}
- 节点名：${state_node_name}
- UUID：${state_uuid}

文件情况
- 元数据：${state_meta_exists}
- 配置文件：${state_config_exists}
- Xray 二进制：${state_xray_bin}
- 分享链接：${state_client_link}
- 客户端说明：${state_client_readme}
- 分离补丁：${state_client_patch}
- Outbound：${state_client_outbound}
EOF2
      ;;
    deploy)
      cat <<'EOF2'
部署向导

这是一个独立 GUI 部署入口：
- 安装、重装、更新、卸载都在当前脚本内完成
- 不再调用旧版 deploy_vless_xhttp.sh
- 先选模式，再进入分步骤 GUI 表单
- 提交后会在当前界面直接执行部署并显示输出

说明：
- 不会启动浏览器，也不会暴露 Web 服务
- 建议用 sudo 运行，以便直接执行部署和服务管理
EOF2
      ;;
    artifacts)
      cat <<EOF2
档案 / 客户端

预览：
$(printf '%s\n' "${last_dossier}" | sed -n '1,14p')

按回车进入子菜单，查看部署摘要、链接和客户端文件。
EOF2
      ;;
    service)
      cat <<EOF2
服务控制

当前服务：${state_service_name}
运行状态：${state_service_active}
开机自启：${state_service_enabled}

按回车进入服务命令菜单。
EOF2
      ;;
    maintenance)
      cat <<'EOF2'
维护

按回车进入维护菜单：
- 更新 xray-core
- 卸载当前部署

这些操作会在当前控制台界面内直接执行。
EOF2
      ;;
    briefing)
      cat <<'EOF2'
帮助

这是一个基于 bash、ANSI 和 read 的本地终端 GUI。
它不会启动浏览器，也不会暴露本地 Web 服务。

按键：
- j / k 或方向键：移动选择
- Enter：执行当前操作
- r：刷新状态
- q：退出或关闭弹窗

说明：
- 安装流程已经做进本地 GUI 向导
- 所有部署逻辑都已经内置到当前单文件 GUI
- 建议终端窗口至少 100x28，并使用 sudo 运行
EOF2
      ;;
    quit)
      cat <<'EOF2'
退出

按回车关闭当前部署控制台。
EOF2
      ;;
  esac
}

draw_header() {
  local clock_text
  local mode_text
  clock_text="$(date '+%Y-%m-%d %H:%M:%S')"
  mode_text="$(mode_short_label_from_id "${state_mode_id}")"
  erase_row 0
  print_at 0 0 " $(repeat_char ' ' $((term_cols - 1)))" "$(color_header)"
  print_at 0 1 "XRAY 部署控制台" "$(color_header)"
  print_at 0 20 "模式: ${mode_text}" "$(color_header)"
  print_at 0 $((term_cols - ${#clock_text} - 2)) "${clock_text}" "$(color_header)"
}

draw_nav() {
  local top=1
  local left=0
  local height=$((term_lines - 10))
  local width=30
  local i
  local row
  draw_box "${top}" "${left}" "${height}" "${width}" "菜单" "$(color_accent)"
  for ((i = 0; i < ${#NAV_LABELS[@]}; i++)); do
    row=$((top + 2 + i * 2))
    if (( row >= top + height - 2 )); then
      break
    fi
    if (( i == selected_index )); then
      print_at "${row}" $((left + 2)) "> ${NAV_LABELS[$i]}" "$(color_focus)"
    else
      print_at "${row}" $((left + 2)) "  ${NAV_LABELS[$i]}" "$(color_reset)"
    fi
  done
}

draw_main_panel() {
  local top=1
  local left=30
  local height=$((term_lines - 10))
  local width=$((term_cols - left))
  local id
  local summary
  local content
  local row
  local content_width
  id="$(active_nav_id)"
  summary="$(nav_summary "${id}")"
  content="$(build_main_content "${id}")"
  draw_box "${top}" "${left}" "${height}" "${width}" "${NAV_LABELS[$selected_index]}" "$(color_label)"
  print_at $((top + 2)) $((left + 2)) "${summary}" "$(color_label)"
  row=$((top + 4))
  content_width=$((width - 4))
  while IFS= read -r line; do
    if (( row >= top + height - 2 )); then
      break
    fi
    if [[ -z "${line}" ]]; then
      row=$((row + 1))
      continue
    fi
    while IFS= read -r wrapped; do
      if (( row >= top + height - 2 )); then
        break 2
      fi
      print_at "${row}" $((left + 2)) "${wrapped}" "$(color_reset)"
      row=$((row + 1))
    done < <(wrap_text "${line}" "${content_width}")
  done <<< "${content}"
}

draw_logs() {
  local top=$((term_lines - 9))
  local left=0
  local height=8
  local width="${term_cols}"
  local row=$((top + 1))
  local line
  draw_box "${top}" "${left}" "${height}" "${width}" "日志" "$(color_warn)"
  for line in "${LOG_LINES[@]}"; do
    if (( row >= top + height - 1 )); then
      break
    fi
    print_at "${row}" 2 "${line}" "$(color_dim)"
    row=$((row + 1))
  done
}

draw_footer() {
  local footer_row=$((term_lines - 1))
  local footer_text=" j/k 或方向键移动 | Enter 执行 | r 刷新 | q 退出 / 关闭弹窗 | 纯本地 shell GUI "
  erase_row "${footer_row}"
  print_at "${footer_row}" 0 " $(repeat_char ' ' $((term_cols - 1)))" "$(color_focus)"
  print_at "${footer_row}" 1 "${footer_text}" "$(color_focus)"
}

draw_screen() {
  get_terminal_size
  if (( term_cols != last_term_cols || term_lines != last_term_lines )); then
    last_term_cols="${term_cols}"
    last_term_lines="${term_lines}"
    screen_needs_clear=1
  fi

  if (( term_cols < 100 || term_lines < 28 )); then
    if (( screen_needs_clear == 1 || screen_small == 0 )); then
      printf '\033[2J\033[H'
      screen_needs_clear=0
    fi
    screen_small=1
    center_text 2 "终端窗口过小，无法正常显示 Xray 部署控制台" "$(color_warn)"
    center_text 4 "建议尺寸：至少 100x28" "$(color_warn)"
    center_text 5 "当前尺寸：${term_cols}x${term_lines}" "$(color_warn)"
    center_text 7 "请调整终端大小后按 r 刷新，或按 q 退出。" "$(color_label)"
    return
  fi

  if (( screen_small == 1 )); then
    screen_needs_clear=1
    screen_small=0
  fi

  if (( screen_needs_clear == 1 )); then
    printf '\033[2J\033[H'
    screen_needs_clear=0
  fi

  draw_header
  draw_nav
  draw_main_panel
  draw_logs
  draw_footer
}

read_key() {
  local key
  IFS= read -rsn1 key || return 1
  if [[ "${key}" == $'\x1b' ]]; then
    IFS= read -rsn1 -t 0.01 key || { printf 'esc'; return 0; }
    if [[ "${key}" == '[' ]]; then
      IFS= read -rsn1 -t 0.01 key || { printf 'esc'; return 0; }
      case "${key}" in
        A) printf 'up' ;;
        B) printf 'down' ;;
        C) printf 'right' ;;
        D) printf 'left' ;;
        *) printf 'esc' ;;
      esac
      return 0
    fi
    printf 'esc'
    return 0
  fi
  case "${key}" in
    ''|$'\n'|$'\r') printf 'enter' ;;
    j|J) printf 'down' ;;
    k|K) printf 'up' ;;
    h|H) printf 'left' ;;
    l|L) printf 'right' ;;
    q|Q) printf 'quit' ;;
    r|R) printf 'refresh' ;;
    *) printf '%s' "${key}" ;;
  esac
}

prompt_choice() {
  local title="$1"
  local body="$2"
  shift 2
  local options=("$@")
  local local_index=0
  local top left width height i key body_row body_width choice_row_start

  while true; do
    draw_screen
    width=$((term_cols - 16))
    if (( width > 96 )); then width=96; fi
    height=$(( ${#options[@]} * 2 + 8 ))
    if (( height < 12 )); then height=12; fi
    top=$(((term_lines - height) / 2))
    left=$(((term_cols - width) / 2))
    draw_box "${top}" "${left}" "${height}" "${width}" "${title}" "$(color_accent)"
    body_row=$((top + 2))
    body_width=$((width - 4))
    while IFS= read -r line; do
      [[ -z "${line}" ]] && { body_row=$((body_row + 1)); continue; }
      while IFS= read -r wrapped; do
        if (( body_row >= top + height - 4 )); then
          break 2
        fi
        print_at "${body_row}" $((left + 2)) "${wrapped}" "$(color_label)"
        body_row=$((body_row + 1))
      done < <(wrap_text "${line}" "${body_width}")
    done <<< "${body}"
    choice_row_start=$((top + height - (${#options[@]} * 2) - 2))
    for ((i = 0; i < ${#options[@]}; i++)); do
      if (( i == local_index )); then
        print_at $((choice_row_start + i * 2)) $((left + 4)) "> ${options[$i]}" "$(color_focus)"
      else
        print_at $((choice_row_start + i * 2)) $((left + 4)) "  ${options[$i]}" "$(color_reset)"
      fi
    done
    key="$(read_key || true)"
    case "${key}" in
      up) local_index=$(((local_index - 1 + ${#options[@]}) % ${#options[@]})) ;;
      down) local_index=$(((local_index + 1) % ${#options[@]})) ;;
      enter) printf '%s' "${local_index}"; return 0 ;;
      quit|esc) return 1 ;;
    esac
  done
}

show_text_dialog() {
  local title="$1"
  local body="$2"
  local lines=()
  local offset=0
  local visible=0
  local width height top left key i line wrap_width

  draw_screen
  wrap_width=$(( term_cols > 114 ? 102 : term_cols - 12 ))
  while IFS= read -r line; do
    lines+=("${line}")
  done < <(wrap_text "${body}" "${wrap_width}")

  while true; do
    draw_screen
    width=$((term_cols - 8))
    if (( width > 110 )); then width=110; fi
    height=$((term_lines - 6))
    top=3
    left=$(((term_cols - width) / 2))
    draw_box "${top}" "${left}" "${height}" "${width}" "${title}" "$(color_label)"
    visible=$((height - 4))
    for ((i = 0; i < visible; i++)); do
      if (( offset + i >= ${#lines[@]} )); then
        break
      fi
      print_at $((top + 2 + i)) $((left + 2)) "${lines[$((offset + i))]}" "$(color_reset)"
    done
    print_at $((top + height - 2)) $((left + 2)) "j/k 滚动 | Enter / q 关闭" "$(color_accent)"
    key="$(read_key || true)"
    case "${key}" in
      up) (( offset > 0 )) && offset=$((offset - 1)) ;;
      down) (( offset + visible < ${#lines[@]} )) && offset=$((offset + 1)) ;;
      enter|quit|esc) return 0 ;;
    esac
  done
}

confirm_dialog() {
  local title="$1"
  local body="$2"
  local choice
  if choice="$(prompt_choice "${title}" "${body}" "继续" "取消")"; then
    [[ "${choice}" == "0" ]]
    return $?
  fi
  return 1
}

input_dialog() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local help_text="${4:-留空使用默认值；输入 !q 取消本次向导。}"
  local width height top left row input

  draw_screen
  width=$((term_cols - 16))
  if (( width > 96 )); then width=96; fi
  height=12
  top=$(((term_lines - height) / 2))
  left=$(((term_cols - width) / 2))
  draw_box "${top}" "${left}" "${height}" "${width}" "${title}" "$(color_accent)"
  print_at $((top + 2)) $((left + 2)) "${prompt}" "$(color_label)"
  print_at $((top + 4)) $((left + 2)) "${help_text}" "$(color_dim)"
  if [[ -n "${default_value}" ]]; then
    print_at $((top + 6)) $((left + 2)) "默认值：${default_value}" "$(color_dim)"
  fi
  print_at $((top + 8)) $((left + 2)) "> " "$(color_focus)"
  show_cursor
  move_to $((top + 8)) $((left + 4))
  IFS= read -r input </dev/tty || input="!q"
  hide_cursor
  if [[ "${input}" == "!q" ]]; then
    return 1
  fi
  if [[ -z "${input}" ]]; then
    input="${default_value}"
  fi
  printf '%s' "${input}"
}

input_required_value() {
  local title="$1"
  local prompt="$2"
  local default_value="${3:-}"
  local help_text="${4:-留空使用默认值；输入 !q 取消本次向导。}"
  local value
  while true; do
    value="$(input_dialog "${title}" "${prompt}" "${default_value}" "${help_text}")" || return 1
    if [[ -n "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
    show_text_dialog "输入无效" "${prompt} 不能为空。"
  done
}

input_port_value() {
  local title="$1"
  local default_value="${2:-443}"
  local value
  while true; do
    value="$(input_dialog "${title}" "监听端口" "${default_value}" "请输入 1-65535 的端口；输入 !q 取消本次向导。")" || return 1
    if validate_port "${value}"; then
      printf '%s' "${value}"
      return 0
    fi
    show_text_dialog "端口无效" "监听端口必须是 1-65535 的整数。"
  done
}

input_path_value() {
  local title="$1"
  local default_value="$2"
  local value normalized
  while true; do
    value="$(input_dialog "${title}" "XHTTP path" "${default_value}" "建议以 / 开头；输入 !q 取消本次向导。")" || return 1
    normalized="$(normalize_path_local "${value}")" || true
    if [[ -n "${normalized}" ]]; then
      printf '%s' "${normalized}"
      return 0
    fi
    show_text_dialog "Path 无效" "XHTTP path 不能为空。"
  done
}

input_dest_value() {
  local title="$1"
  local prompt="$2"
  local default_value="$3"
  local value normalized
  while true; do
    value="$(input_dialog "${title}" "${prompt}" "${default_value}" "留空将使用默认值；输入 !q 取消本次向导。")" || return 1
    normalized="$(normalize_dest_local "${value}")" || true
    if [[ -n "${normalized}" ]]; then
      printf '%s' "${normalized}"
      return 0
    fi
    show_text_dialog "Dest 无效" "请填写合法的 dest，支持 host:port 或域名。"
  done
}

input_file_value() {
  local title="$1"
  local prompt="$2"
  local default_value="$3"
  local value
  while true; do
    value="$(input_dialog "${title}" "${prompt}" "${default_value}" "请输入当前机器上已存在的文件路径；输入 !q 取消本次向导。")" || return 1
    if [[ -f "${value}" ]]; then
      printf '%s' "${value}"
      return 0
    fi
    show_text_dialog "文件不存在" "未找到文件：${value:-<empty>}"
  done
}

choose_mode_dialog() {
  local current="$1"
  local default_index=0
  case "${current}" in
    split_dualstack_reality) default_index=1 ;;
    split_dualvps_reality_backend) default_index=2 ;;
    split_dualvps_reality_proxy) default_index=3 ;;
    split_cdn_tls_backend) default_index=4 ;;
  esac
  prompt_choice \
    "部署模式" \
    "请选择当前机器要执行的部署模式。" \
    "单 VPS：VLESS + XHTTP + REALITY" \
    "同机分离：IPv6 上行 + IPv4 下行" \
    "双 VPS：当前机器部署后端 / 下行服务器" \
    "双 VPS：当前机器部署上行代理" \
    "CDN 上行 + VPS 下行：TLS + XHTTP"
}

choose_xhttp_mode_dialog() {
  local allow_stream_one="$1"
  local current="$2"
  local choice
  if [[ "${allow_stream_one}" == "yes" ]]; then
    choice="$(prompt_choice \
      "XHTTP Mode" \
      "请选择 XHTTP mode。当前值：${current:-auto}" \
      "auto（推荐）" \
      "packet-up" \
      "stream-up" \
      "stream-one")" || return 1
    case "${choice}" in
      0) printf 'auto' ;;
      1) printf 'packet-up' ;;
      2) printf 'stream-up' ;;
      3) printf 'stream-one' ;;
    esac
  else
    choice="$(prompt_choice \
      "XHTTP Mode" \
      "当前模式不建议使用 stream-one。当前值：${current:-auto}" \
      "auto（推荐）" \
      "packet-up" \
      "stream-up")" || return 1
    case "${choice}" in
      0) printf 'auto' ;;
      1) printf 'packet-up' ;;
      2) printf 'stream-up' ;;
    esac
  fi
}

build_install_summary() {
  local mode_id="$1"
  local upload_address="$2"
  local download_address="$3"
  local port="$4"
  local sni="$5"
  local upload_sni="$6"
  local download_sni="$7"
  local reality_dest="$8"
  local xhttp_path="$9"
  local xhttp_mode="${10}"
  local fingerprint="${11}"
  local spiderx="${12}"
  local backend_address="${13}"
  local backend_port="${14}"
  local cert_file="${15}"
  local key_file="${16}"
  local node_name="${17}"

  case "${mode_id}" in
    single_reality)
      cat <<EOF2
模式：$(mode_label_from_id "${mode_id}")
节点连接地址：${upload_address}
监听端口：${port}
REALITY SNI：${sni}
REALITY dest：${reality_dest}
XHTTP path：${xhttp_path}
XHTTP mode：${xhttp_mode}
Fingerprint：${fingerprint}
SpiderX：${spiderx}
节点备注：${node_name}

自动处理：
- 如有现有 UUID，会优先复用；否则自动生成
- 如有现有 REALITY 密钥，会优先复用；否则自动生成
EOF2
      ;;
    split_dualstack_reality|split_dualvps_reality_backend)
      cat <<EOF2
模式：$(mode_label_from_id "${mode_id}")
上行地址：${upload_address}
下行地址：${download_address}
监听端口：${port}
REALITY SNI：${sni}
REALITY dest：${reality_dest}
XHTTP path：${xhttp_path}
XHTTP mode：${xhttp_mode}
Fingerprint：${fingerprint}
SpiderX：${spiderx}
节点备注：${node_name}

自动处理：
- 如有现有 UUID，会优先复用；否则自动生成
- 如有现有 REALITY 密钥，会优先复用；否则自动生成
EOF2
      ;;
    split_dualvps_reality_proxy)
      cat <<EOF2
模式：$(mode_label_from_id "${mode_id}")
当前机器上行地址参考：$(detect_public_address_local)
监听端口：${port}
后端地址：${backend_address}
后端端口：${backend_port}
代理备注：${node_name}
EOF2
      ;;
    split_cdn_tls_backend)
      cat <<EOF2
模式：$(mode_label_from_id "${mode_id}")
上行地址（CDN 域名）：${upload_address}
下行地址：${download_address}
监听端口：${port}
上传侧 TLS SNI：${upload_sni}
下行侧 TLS SNI：${download_sni}
XHTTP path：${xhttp_path}
XHTTP mode：${xhttp_mode}
Fingerprint：${fingerprint}
证书文件：${cert_file}
私钥文件：${key_file}
节点备注：${node_name}

自动处理：
- 如有现有 UUID，会优先复用；否则自动生成
EOF2
      ;;
  esac
}

run_streaming_task() {
  local title="$1"
  shift
  local output_file status_file spinner='|/-\\'
  local spinner_index=0
  local pid width height top left body_height status_text exit_code full_output
  local lines=()
  local row i line wrapped

  output_file="$(mktemp)"
  status_file="$(mktemp)"
  rm -f "${status_file}"

  (
    set +e
    "$@" >"${output_file}" 2>&1
    printf '%s' "$?" >"${status_file}"
  ) &
  pid=$!

  while true; do
    draw_screen
    width=$((term_cols - 8))
    if (( width > 110 )); then width=110; fi
    height=$((term_lines - 6))
    top=3
    left=$(((term_cols - width) / 2))
    body_height=$((height - 6))
    draw_box "${top}" "${left}" "${height}" "${width}" "${title}" "$(color_label)"
    status_text="执行中 ${spinner:spinner_index:1}"
    spinner_index=$(((spinner_index + 1) % 4))
    print_at $((top + 2)) $((left + 2)) "${status_text}" "$(color_accent)"
    mapfile -t lines < <(tail -n "${body_height}" "${output_file}" 2>/dev/null || true)
    row=$((top + 3))
    for line in "${lines[@]}"; do
      while IFS= read -r wrapped; do
        if (( row >= top + height - 2 )); then
          break 2
        fi
        print_at "${row}" $((left + 2)) "${wrapped}" "$(color_reset)"
        row=$((row + 1))
      done < <(wrap_text "${line}" $((width - 4)))
    done
    print_at $((top + height - 2)) $((left + 2)) "正在执行，请稍候..." "$(color_dim)"
    if [[ -f "${status_file}" ]]; then
      break
    fi
    sleep 0.15
  done

  wait "${pid}" 2>/dev/null || true
  exit_code="$(cat "${status_file}" 2>/dev/null || printf '1')"
  full_output="$(cat "${output_file}" 2>/dev/null || true)"
  rm -f "${output_file}" "${status_file}"

  if [[ "${exit_code}" == "0" ]]; then
    append_log "${title} 执行完成。"
    refresh_state
    if confirm_dialog "${title} 完成" "操作已完成。是否查看完整输出？"; then
      show_text_dialog "${title} 输出" "${full_output:-没有输出。}"
    fi
    return 0
  fi

  append_log "${title} 执行失败。"
  show_text_dialog "${title} 失败" "${full_output:-命令没有返回输出。}"
  return 1
}

run_install_wizard() {
  local existing_mode="single_reality"
  local existing_port="443"
  local existing_upload=""
  local existing_download=""
  local existing_backend_address=""
  local existing_backend_port=""
  local existing_sni="download-installer.cdn.mozilla.net"
  local existing_upload_sni=""
  local existing_download_sni=""
  local existing_dest=""
  local existing_path="/$(random_hex)"
  local existing_xhttp_mode="auto"
  local existing_fingerprint="chrome"
  local existing_spiderx="/"
  local existing_cert="/etc/ssl/xray/fullchain.pem"
  local existing_key="/etc/ssl/xray/private.key"
  local existing_node_name="VLESS-XHTTP-REALITY"
  local mode_choice mode_id allow_stream_one mode_summary choice
  local auto_addr auto_v4 auto_v6
  local upload_address download_address port sni upload_sni download_sni reality_dest
  local xhttp_path xhttp_mode fingerprint spiderx backend_address backend_port cert_file key_file node_name

  if [[ ${EUID} -ne 0 ]]; then
    show_text_dialog "需要 root 权限" "安装、重装、更新和卸载都需要 root 权限。请使用 sudo 重新运行当前控制台。"
    return 0
  fi

  auto_addr="$(detect_public_address_local)"
  auto_v4="$(detect_public_ipv4_local)"
  auto_v6="$(detect_public_ipv6_local)"

  if meta_readable; then
    local DEPLOY_MODE=""
    local PORT=""
    local UPLOAD_ADDRESS=""
    local DOWNLOAD_ADDRESS=""
    local BACKEND_ADDRESS=""
    local BACKEND_PORT=""
    local SNI=""
    local UPLOAD_SNI=""
    local DOWNLOAD_SNI=""
    local REALITY_DEST=""
    local XHTTP_PATH=""
    local XHTTP_MODE=""
    local FINGERPRINT=""
    local SPIDERX=""
    local TLS_CERT_FILE=""
    local TLS_KEY_FILE=""
    local NODE_NAME=""
    # shellcheck disable=SC1090
    source "${META_FILE}"
    [[ -n "${DEPLOY_MODE:-}" ]] && existing_mode="${DEPLOY_MODE}"
    [[ -n "${PORT:-}" ]] && existing_port="${PORT}"
    [[ -n "${UPLOAD_ADDRESS:-}" ]] && existing_upload="${UPLOAD_ADDRESS}"
    [[ -n "${DOWNLOAD_ADDRESS:-}" ]] && existing_download="${DOWNLOAD_ADDRESS}"
    [[ -n "${BACKEND_ADDRESS:-}" ]] && existing_backend_address="${BACKEND_ADDRESS}"
    [[ -n "${BACKEND_PORT:-}" ]] && existing_backend_port="${BACKEND_PORT}"
    [[ -n "${SNI:-}" ]] && existing_sni="${SNI}"
    [[ -n "${UPLOAD_SNI:-}" ]] && existing_upload_sni="${UPLOAD_SNI}"
    [[ -n "${DOWNLOAD_SNI:-}" ]] && existing_download_sni="${DOWNLOAD_SNI}"
    [[ -n "${REALITY_DEST:-}" ]] && existing_dest="${REALITY_DEST}"
    [[ -n "${XHTTP_PATH:-}" ]] && existing_path="${XHTTP_PATH}"
    [[ -n "${XHTTP_MODE:-}" ]] && existing_xhttp_mode="${XHTTP_MODE}"
    [[ -n "${FINGERPRINT:-}" ]] && existing_fingerprint="${FINGERPRINT}"
    [[ -n "${SPIDERX:-}" ]] && existing_spiderx="${SPIDERX}"
    [[ -n "${TLS_CERT_FILE:-}" ]] && existing_cert="${TLS_CERT_FILE}"
    [[ -n "${TLS_KEY_FILE:-}" ]] && existing_key="${TLS_KEY_FILE}"
    [[ -n "${NODE_NAME:-}" ]] && existing_node_name="${NODE_NAME}"
  fi

  while true; do
    mode_choice="$(choose_mode_dialog "${existing_mode}")" || return 0
    case "${mode_choice}" in
      0) mode_id="single_reality" ;;
      1) mode_id="split_dualstack_reality" ;;
      2) mode_id="split_dualvps_reality_backend" ;;
      3) mode_id="split_dualvps_reality_proxy" ;;
      4) mode_id="split_cdn_tls_backend" ;;
      *) return 0 ;;
    esac
    existing_mode="${mode_id}"

    upload_address="${existing_upload}"
    download_address="${existing_download}"
    port="${existing_port}"
    sni="${existing_sni}"
    upload_sni="${existing_upload_sni}"
    download_sni="${existing_download_sni}"
    reality_dest="${existing_dest:-${existing_sni}:443}"
    xhttp_path="${existing_path}"
    xhttp_mode="${existing_xhttp_mode}"
    fingerprint="${existing_fingerprint}"
    spiderx="${existing_spiderx}"
    backend_address="${existing_backend_address}"
    backend_port="${existing_backend_port:-${existing_port}}"
    cert_file="${existing_cert}"
    key_file="${existing_key}"
    node_name="${existing_node_name}"

    case "${mode_id}" in
      single_reality)
        [[ -n "${upload_address}" ]] || upload_address="${auto_addr}"
        [[ -n "${node_name}" ]] || node_name="VLESS-XHTTP-REALITY"
        upload_address="$(input_required_value "安装向导" "节点连接地址（域名或公网 IP）" "${upload_address}")" || return 0
        port="$(input_port_value "安装向导" "${port}")" || return 0
        sni="$(input_required_value "安装向导" "REALITY 的 SNI / serverName" "${sni}")" || return 0
        reality_dest="$(input_dest_value "安装向导" "REALITY 目标站 dest" "${reality_dest:-${sni}:443}")" || return 0
        xhttp_path="$(input_path_value "安装向导" "${xhttp_path}")" || return 0
        xhttp_mode="$(choose_xhttp_mode_dialog yes "${xhttp_mode}")" || return 0
        fingerprint="$(input_required_value "安装向导" "客户端 fingerprint" "${fingerprint}")" || return 0
        spiderx="$(input_required_value "安装向导" "SpiderX" "${spiderx}")" || return 0
        spiderx="$(normalize_spiderx_local "${spiderx}")"
        node_name="$(input_required_value "安装向导" "节点备注名" "${node_name}")" || return 0
        download_address="${upload_address}"
        upload_sni=""
        download_sni=""
        backend_address=""
        backend_port=""
        cert_file=""
        key_file=""
        ;;
      split_dualstack_reality)
        [[ -n "${upload_address}" ]] || upload_address="${auto_v6}"
        [[ -n "${download_address}" ]] || download_address="${auto_v4}"
        node_name="${node_name:-VLESS-XHTTP-IPv6UP-IPv4DOWN}"
        upload_address="$(input_required_value "安装向导" "上行地址（建议 IPv6 域名或 IPv6）" "${upload_address}")" || return 0
        download_address="$(input_required_value "安装向导" "下行地址（建议 IPv4 域名或 IPv4）" "${download_address}")" || return 0
        port="$(input_port_value "安装向导" "${port}")" || return 0
        sni="$(input_required_value "安装向导" "REALITY 的 SNI / serverName" "${sni}")" || return 0
        reality_dest="$(input_dest_value "安装向导" "REALITY 目标站 dest" "${reality_dest:-${sni}:443}")" || return 0
        xhttp_path="$(input_path_value "安装向导" "${xhttp_path}")" || return 0
        xhttp_mode="$(choose_xhttp_mode_dialog no "${xhttp_mode}")" || return 0
        fingerprint="$(input_required_value "安装向导" "客户端 fingerprint" "${fingerprint}")" || return 0
        spiderx="$(input_required_value "安装向导" "SpiderX" "${spiderx}")" || return 0
        spiderx="$(normalize_spiderx_local "${spiderx}")"
        node_name="$(input_required_value "安装向导" "节点备注名" "${node_name}")" || return 0
        upload_sni=""
        download_sni=""
        backend_address=""
        backend_port=""
        cert_file=""
        key_file=""
        ;;
      split_dualvps_reality_backend)
        [[ -n "${download_address}" ]] || download_address="${auto_v4}"
        node_name="${node_name:-VLESS-XHTTP-VPS1UP-VPS2DOWN}"
        upload_address="$(input_required_value "安装向导" "上行地址（VPS1 上传代理地址）" "${upload_address}")" || return 0
        download_address="$(input_required_value "安装向导" "下行地址（当前 VPS2 直连地址）" "${download_address}")" || return 0
        port="$(input_port_value "安装向导" "${port}")" || return 0
        sni="$(input_required_value "安装向导" "REALITY 的 SNI / serverName" "${sni}")" || return 0
        reality_dest="$(input_dest_value "安装向导" "REALITY 目标站 dest" "${reality_dest:-${sni}:443}")" || return 0
        xhttp_path="$(input_path_value "安装向导" "${xhttp_path}")" || return 0
        xhttp_mode="$(choose_xhttp_mode_dialog no "${xhttp_mode}")" || return 0
        fingerprint="$(input_required_value "安装向导" "客户端 fingerprint" "${fingerprint}")" || return 0
        spiderx="$(input_required_value "安装向导" "SpiderX" "${spiderx}")" || return 0
        spiderx="$(normalize_spiderx_local "${spiderx}")"
        node_name="$(input_required_value "安装向导" "节点备注名" "${node_name}")" || return 0
        upload_sni=""
        download_sni=""
        backend_address=""
        backend_port=""
        cert_file=""
        key_file=""
        ;;
      split_dualvps_reality_proxy)
        node_name="${node_name:-XHTTP-UPLOAD-PROXY}"
        port="$(input_port_value "安装向导" "${port}")" || return 0
        backend_address="$(input_required_value "安装向导" "后端地址（VPS2 直连地址）" "${backend_address}")" || return 0
        backend_port="$(input_port_value "安装向导" "${backend_port:-${port}}")" || return 0
        node_name="$(input_required_value "安装向导" "代理备注名" "${node_name}")" || return 0
        upload_address=""
        download_address=""
        sni=""
        upload_sni=""
        download_sni=""
        reality_dest=""
        xhttp_path=""
        xhttp_mode=""
        fingerprint=""
        spiderx=""
        cert_file=""
        key_file=""
        ;;
      split_cdn_tls_backend)
        node_name="${node_name:-VLESS-XHTTP-CDNUP-VPSDOWN}"
        upload_address="$(input_required_value "安装向导" "上行地址（CDN 域名）" "${upload_address}")" || return 0
        download_address="$(input_required_value "安装向导" "下行地址（直连域名或 IP）" "${download_address:-${auto_v4}}")" || return 0
        port="$(input_port_value "安装向导" "${port}")" || return 0
        upload_sni="$(input_required_value "安装向导" "上传侧 TLS SNI" "${upload_sni:-${upload_address}}")" || return 0
        download_sni="$(input_required_value "安装向导" "下行侧 TLS SNI" "${download_sni:-${download_address}}")" || return 0
        xhttp_path="$(input_path_value "安装向导" "${xhttp_path}")" || return 0
        xhttp_mode="$(choose_xhttp_mode_dialog no "${xhttp_mode}")" || return 0
        fingerprint="$(input_required_value "安装向导" "客户端 fingerprint" "${fingerprint}")" || return 0
        cert_file="$(input_file_value "安装向导" "证书文件 certificateFile" "${cert_file}")" || return 0
        key_file="$(input_file_value "安装向导" "私钥文件 keyFile" "${key_file}")" || return 0
        node_name="$(input_required_value "安装向导" "节点备注名" "${node_name}")" || return 0
        sni=""
        reality_dest=""
        spiderx=""
        backend_address=""
        backend_port=""
        ;;
    esac

    mode_summary="$(build_install_summary \
      "${mode_id}" \
      "${upload_address}" \
      "${download_address}" \
      "${port}" \
      "${sni}" \
      "${upload_sni}" \
      "${download_sni}" \
      "${reality_dest}" \
      "${xhttp_path}" \
      "${xhttp_mode}" \
      "${fingerprint}" \
      "${spiderx}" \
      "${backend_address}" \
      "${backend_port}" \
      "${cert_file}" \
      "${key_file}" \
      "${node_name}")"

    existing_upload="${upload_address}"
    existing_download="${download_address}"
    existing_port="${port}"
    existing_sni="${sni}"
    existing_upload_sni="${upload_sni}"
    existing_download_sni="${download_sni}"
    existing_dest="${reality_dest}"
    existing_path="${xhttp_path}"
    existing_xhttp_mode="${xhttp_mode}"
    existing_fingerprint="${fingerprint}"
    existing_spiderx="${spiderx}"
    existing_backend_address="${backend_address}"
    existing_backend_port="${backend_port}"
    existing_cert="${cert_file}"
    existing_key="${key_file}"
    existing_node_name="${node_name}"

    show_text_dialog "部署预览" "${mode_summary}"
    choice="$(prompt_choice "部署确认" "请确认上面的参数。确认后会直接在本控制台里执行部署。" "开始部署" "重新填写" "取消")" || return 0
    case "${choice}" in
      0)
        XRAY_GUI_DEPLOY_MODE="${mode_id}"
        XRAY_GUI_PORT="${port}"
        XRAY_GUI_UPLOAD_ADDRESS="${upload_address}"
        XRAY_GUI_DOWNLOAD_ADDRESS="${download_address}"
        XRAY_GUI_BACKEND_ADDRESS="${backend_address}"
        XRAY_GUI_BACKEND_PORT="${backend_port}"
        XRAY_GUI_SNI="${sni}"
        XRAY_GUI_UPLOAD_SNI="${upload_sni}"
        XRAY_GUI_DOWNLOAD_SNI="${download_sni}"
        XRAY_GUI_REALITY_DEST="${reality_dest}"
        XRAY_GUI_TLS_CERT_FILE="${cert_file}"
        XRAY_GUI_TLS_KEY_FILE="${key_file}"
        XRAY_GUI_FINGERPRINT="${fingerprint}"
        XRAY_GUI_SPIDERX="${spiderx}"
        XRAY_GUI_XHTTP_PATH="${xhttp_path}"
        XRAY_GUI_XHTTP_MODE="${xhttp_mode}"
        XRAY_GUI_NODE_NAME="${node_name}"
        append_log "已提交安装向导参数，准备执行部署。"
        run_streaming_task "安装 / 重装" configure_and_apply_noninteractive
        return 0
        ;;
      1)
        append_log "重新进入安装向导填写参数。"
        ;;
      *)
        return 0
        ;;
    esac
  done
}

show_message() {
  local title="$1"
  local body="$2"
  show_text_dialog "${title}" "${body}"
}

show_modes_guide() {
  show_text_dialog "模式说明" "$(cat <<'EOF'
1. 单 VPS：VLESS + XHTTP + REALITY
- 当前机器直接提供完整节点服务
- 最适合普通单机部署

2. 同机分离：IPv6 上行 + IPv4 下行
- 同一台机器做后端
- 客户端上传走 IPv6，下行走 IPv4

3. 双 VPS：当前机器部署后端 / 下行服务器
- 当前机器承担 Xray 后端
- 需要另一台 VPS 再部署上传代理

4. 双 VPS：当前机器部署上行代理
- 当前机器只监听并透传到后端 VPS
- 不直接生成节点链接

5. CDN 上行 + VPS 下行：TLS + XHTTP
- 上传地址走 CDN 域名
- 下行直接回源到 VPS
- 需要当前机器上已有可用证书和私钥

建议顺序：
- 双 VPS 模式先部署后端，再部署上行代理
- 分离上下行模式通常需要客户端支持自定义 JSON / outbound
EOF
)"
}

show_file_dialog() {
  local title="$1"
  local path="$2"
  local body

  if [[ ! -e "${path}" ]]; then
    show_text_dialog "${title}" "文件不存在：${path}"
    return 0
  fi

  if [[ ! -r "${path}" ]]; then
    show_text_dialog "${title}" "$(printf '当前账号没有权限读取：%s\n请使用 sudo 重新运行当前 GUI。' "${path}")"
    return 0
  fi

  body="$(cat "${path}" 2>/dev/null || true)"
  if [[ -z "${body}" ]]; then
    body="文件存在，但当前内容为空：${path}"
  fi
  show_text_dialog "${title}" "${body}"
}

deploy_menu() {
  local choice
  choice="$(prompt_choice "部署向导" "请选择部署子菜单。" \
    "运行安装 / 重装向导" \
    "查看五种模式说明" \
    "返回")" || return 0
  case "${choice}" in
    0) run_install_wizard ;;
    1) show_modes_guide ;;
  esac
}

artifacts_menu() {
  local choice output
  choice="$(prompt_choice "档案 / 客户端" "请选择要查看的部署细节。" \
    "部署摘要" \
    "基础 vless 链接" \
    "客户端说明" \
    "分离补丁" \
    "Outbound JSON" \
    "主配置 config.json" \
    "部署元数据 deploy_mode.env" \
    "返回")" || return 0
  case "${choice}" in
    0)
      output="$(run_function_capture show_current_info)"
      last_dossier="${output:-没有返回部署摘要。}"
      append_log "已读取当前部署摘要。"
      show_text_dialog "部署摘要" "${last_dossier}"
      ;;
    1)
      append_log "已打开基础链接文件。"
      show_file_dialog "基础 vless 链接" "${CLIENT_LINK_FILE}"
      ;;
    2)
      append_log "已打开客户端说明文件。"
      show_file_dialog "客户端说明" "${CLIENT_README_FILE}"
      ;;
    3)
      append_log "已打开分离补丁文件。"
      show_file_dialog "分离补丁" "${CLIENT_PATCH_FILE}"
      ;;
    4)
      append_log "已打开 outbound 文件。"
      show_file_dialog "Outbound JSON" "${CLIENT_OUTBOUND_FILE}"
      ;;
    5)
      append_log "已打开 Xray 主配置。"
      show_file_dialog "config.json" "${CONFIG_FILE}"
      ;;
    6)
      append_log "已打开部署元数据。"
      show_file_dialog "deploy_mode.env" "${META_FILE}"
      ;;
  esac
}

service_menu() {
  local choice output
  if [[ "${state_service_name}" == "-" ]]; then
    show_message "服务控制" "当前还没有识别到活动服务。请先部署，或使用 sudo 刷新以查看完整信息。"
    return 0
  fi
  choice="$(prompt_choice "服务控制" "请选择当前服务要执行的操作。" \
    "查看 systemd 状态" \
    "启动服务" \
    "重启服务" \
    "停止服务" \
    "返回")" || return 0
  case "${choice}" in
    0)
      output="$(systemctl status "${state_service_name}" --no-pager 2>&1 || true)"
      append_log "已读取 ${state_service_name} 的 systemd 状态。"
      show_text_dialog "服务状态" "${output:-没有返回状态输出。}"
      ;;
    1)
      if systemctl start "${state_service_name}" >/dev/null 2>&1; then
        refresh_state
        append_log "已启动 ${state_service_name}。"
        show_message "服务控制" "服务已启动：${state_service_name}"
      else
        output="$(systemctl start "${state_service_name}" 2>&1 || true)"
        append_log "启动 ${state_service_name} 失败。"
        show_text_dialog "服务控制" "${output:-启动服务失败。}"
      fi
      ;;
    2)
      if systemctl restart "${state_service_name}" >/dev/null 2>&1; then
        refresh_state
        append_log "已重启 ${state_service_name}。"
        show_message "服务控制" "服务已重启：${state_service_name}"
      else
        output="$(systemctl restart "${state_service_name}" 2>&1 || true)"
        append_log "重启 ${state_service_name} 失败。"
        show_text_dialog "服务控制" "${output:-重启服务失败。}"
      fi
      ;;
    3)
      if systemctl stop "${state_service_name}" >/dev/null 2>&1; then
        refresh_state
        append_log "已停止 ${state_service_name}。"
        show_message "服务控制" "服务已停止：${state_service_name}"
      else
        output="$(systemctl stop "${state_service_name}" 2>&1 || true)"
        append_log "停止 ${state_service_name} 失败。"
        show_text_dialog "服务控制" "${output:-停止服务失败。}"
      fi
      ;;
  esac
}

maintenance_menu() {
  local choice
  if [[ ${EUID} -ne 0 ]]; then
    show_text_dialog "需要 root 权限" "更新内核和卸载都需要 root 权限。请使用 sudo 重新运行当前控制台。"
    return 0
  fi
  choice="$(prompt_choice "维护" "请选择要在当前机器上执行的维护动作。" \
    "更新 xray-core" \
    "卸载当前部署" \
    "返回")" || return 0
  case "${choice}" in
    0)
      if confirm_dialog "更新内核" "要在当前机器上执行 update-core 吗？"; then
        append_log "进入 update-core 流程。"
        run_streaming_task "更新 xray-core" update_core_only
      fi
      ;;
    1)
      if confirm_dialog "卸载" "要在当前机器上执行卸载吗？"; then
        append_log "进入卸载流程。"
        run_streaming_task "卸载当前部署" uninstall_all_no_prompt
      fi
      ;;
  esac
}

execute_selected() {
  local id output
  id="$(active_nav_id)"
  case "${id}" in
    overview)
      show_text_dialog "总览" "$(build_main_content overview)"
      ;;
    deploy)
      deploy_menu
      ;;
    artifacts)
      artifacts_menu
      ;;
    service)
      service_menu
      ;;
    maintenance)
      maintenance_menu
      ;;
    briefing)
      show_text_dialog "帮助" "$(build_main_content briefing)"
      ;;
    quit)
      running=0
      ;;
  esac
}

usage() {
  cat <<EOF2
用法:
  bash ${SCRIPT_NAME}              启动本地终端部署控制台
  bash ${SCRIPT_NAME} show         输出当前部署摘要
  bash ${SCRIPT_NAME} update-core  更新 xray-core
  bash ${SCRIPT_NAME} uninstall    卸载当前部署
  bash ${SCRIPT_NAME} apply-env    使用 XRAY_GUI_* 环境变量执行部署
  bash ${SCRIPT_NAME} --help

说明:
- 这是一个本地 bash+ANSI 终端 GUI
- 不会启动浏览器，也不会启动 Web 服务
- 安装流程已经内置为 GUI 向导
- 当前 GUI 已经是独立单文件，不再调用旧版 shell
EOF2
}

ensure_interactive_terminal() {
  [[ -t 0 && -t 1 ]] || { printf '[x] 需要交互式终端环境\n' >&2; exit 1; }
}

init_ui() {
  ensure_interactive_terminal
  printf '\033[?1049h\033[?25l'
  ui_ready=1
  screen_needs_clear=1
}

main_loop() {
  local key
  append_log "控制台已启动。"
  refresh_state
  while [[ "${running}" == "1" ]]; do
    draw_screen
    key="$(read_key || true)"
    case "${key}" in
      up)
        selected_index=$(((selected_index - 1 + ${#NAV_IDS[@]}) % ${#NAV_IDS[@]}))
        ;;
      down)
        selected_index=$(((selected_index + 1) % ${#NAV_IDS[@]}))
        ;;
      enter)
        execute_selected
        screen_needs_clear=1
        ;;
      refresh)
        refresh_state
        screen_needs_clear=1
        ;;
      quit|esc)
        running=0
        ;;
    esac
  done
}

dispatch_cli() {
  case "${1:-gui}" in
    gui|menu)
      init_ui
      main_loop
      ;;
    show)
      show_current_info
      ;;
    update-core)
      update_core_only
      ;;
    uninstall)
      uninstall_all
      ;;
    apply-env)
      configure_and_apply_noninteractive
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
}

dispatch_cli "$@"
