#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
CORE_LOCAL_SCRIPT="${SCRIPT_DIR}/deploy_vless_xhttp.sh"
CORE_REMOTE_URL="${XRAY_STABLE_SCRIPT_URL:-https://raw.githubusercontent.com/jantian3n/xray-vless-xhttp-multimode-installer/main/deploy_vless_xhttp.sh}"
CORE_SCRIPT=""
BOOTSTRAP_FILE=""

XRAY_BIN="/usr/local/bin/xray"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="${CONFIG_DIR}/config.json"
META_FILE="${CONFIG_DIR}/deploy_mode.env"
CLIENT_LINK_FILE="${CONFIG_DIR}/client_vless_link.txt"
CLIENT_PATCH_FILE="${CONFIG_DIR}/client_split_patch.json"
CLIENT_OUTBOUND_FILE="${CONFIG_DIR}/client_outbound.json"
CLIENT_README_FILE="${CONFIG_DIR}/client_readme.txt"
PROXY_SERVICE_NAME="xhttp-upload-proxy"

NAV_IDS=(overview deploy dossier service maintenance briefing quit)
NAV_LABELS=(
  "总览"
  "安装 / 重装"
  "部署档案"
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
last_dossier="尚未读取部署档案。进入“部署档案”后按回车可获取最新信息。"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

append_log() {
  LOG_LINES+=("[$(date '+%H:%M:%S')] $*")
  while ((${#LOG_LINES[@]} > log_capacity)); do
    LOG_LINES=("${LOG_LINES[@]:1}")
  done
}

cleanup_bootstrap() {
  if [[ -n "${BOOTSTRAP_FILE}" && -f "${BOOTSTRAP_FILE}" ]]; then
    rm -f "${BOOTSTRAP_FILE}"
  fi
}

restore_terminal() {
  if [[ "${ui_ready}" == "1" ]]; then
    printf '\033[0m\033[?25h\033[?1049l' >/dev/tty 2>/dev/null || true
  fi
}

download_core_script() {
  local target_file="$1"
  if command_exists curl; then
    curl -fsSL "${CORE_REMOTE_URL}" -o "${target_file}"
    return 0
  fi
  if command_exists wget; then
    wget -qO "${target_file}" "${CORE_REMOTE_URL}"
    return 0
  fi
  printf '[x] 缺少 curl 或 wget，无法拉取稳定版核心脚本：%s\n' "${CORE_REMOTE_URL}" >&2
  return 1
}

resolve_core_script() {
  if [[ -f "${CORE_LOCAL_SCRIPT}" ]]; then
    CORE_SCRIPT="${CORE_LOCAL_SCRIPT}"
    return 0
  fi

  BOOTSTRAP_FILE="$(mktemp)"
  if ! download_core_script "${BOOTSTRAP_FILE}"; then
    rm -f "${BOOTSTRAP_FILE}"
    BOOTSTRAP_FILE=""
    printf '[x] 无法找到或下载 deploy_vless_xhttp.sh\n' >&2
    return 1
  fi
  CORE_SCRIPT="${BOOTSTRAP_FILE}"
}

trap 'restore_terminal; cleanup_bootstrap' EXIT

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

run_core_capture() {
  bash "${CORE_SCRIPT}" "$1" 2>&1 || true
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
    deploy) printf '通过内置安装向导完成参数填写、确认和部署执行。' ;;
    dossier) printf '读取部署摘要、客户端说明和当前机器生成结果。' ;;
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
安装 / 重装

这版控制台已经内置安装向导：
- 先选部署模式
- 再在 GUI 里填写参数
- 提交后在当前界面直接执行部署
- 完成后可查看完整输出

说明：
- 底层仍复用稳定版 deploy_vless_xhttp.sh
- 不会启动浏览器，也不会暴露 Web 服务
- 建议用 sudo 运行，以便直接执行部署和服务管理
EOF2
      ;;
    dossier)
      cat <<EOF2
部署档案

预览：
$(printf '%s
' "${last_dossier}" | sed -n '1,14p')

按回车从稳定版后端读取最新部署档案。
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
- 底层部署、更新和卸载仍复用稳定版 Shell 脚本
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
    return 0
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
  local row i line wrapped visible_tail

  output_file="$(mktemp)"
  status_file="$(mktemp)"
  rm -f "${status_file}"

  (
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
  local env_args=()

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
        env_args=(
          "XRAY_GUI_DEPLOY_MODE=${mode_id}"
          "XRAY_GUI_PORT=${port}"
          "XRAY_GUI_UPLOAD_ADDRESS=${upload_address}"
          "XRAY_GUI_DOWNLOAD_ADDRESS=${download_address}"
          "XRAY_GUI_BACKEND_ADDRESS=${backend_address}"
          "XRAY_GUI_BACKEND_PORT=${backend_port}"
          "XRAY_GUI_SNI=${sni}"
          "XRAY_GUI_UPLOAD_SNI=${upload_sni}"
          "XRAY_GUI_DOWNLOAD_SNI=${download_sni}"
          "XRAY_GUI_REALITY_DEST=${reality_dest}"
          "XRAY_GUI_TLS_CERT_FILE=${cert_file}"
          "XRAY_GUI_TLS_KEY_FILE=${key_file}"
          "XRAY_GUI_FINGERPRINT=${fingerprint}"
          "XRAY_GUI_SPIDERX=${spiderx}"
          "XRAY_GUI_XHTTP_PATH=${xhttp_path}"
          "XRAY_GUI_XHTTP_MODE=${xhttp_mode}"
          "XRAY_GUI_NODE_NAME=${node_name}"
        )
        append_log "已提交安装向导参数，准备执行部署。"
        run_streaming_task "安装 / 重装" env "${env_args[@]}" bash "${CORE_SCRIPT}" apply-env
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
        run_streaming_task "更新 xray-core" bash "${CORE_SCRIPT}" update-core
      fi
      ;;
    1)
      if confirm_dialog "卸载" "要在当前机器上执行卸载吗？"; then
        append_log "进入卸载流程。"
        run_streaming_task "卸载当前部署" bash "${CORE_SCRIPT}" uninstall
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
      run_install_wizard
      ;;
    dossier)
      output="$(run_core_capture show)"
      last_dossier="${output:-没有返回部署档案内容。}"
      append_log "已从稳定版后端获取部署档案。"
      show_text_dialog "部署档案" "${last_dossier}"
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
  bash ${SCRIPT_NAME} --help

说明:
- 这是一个本地 bash+ANSI 终端 GUI
- 不会启动浏览器，也不会启动 Web 服务
- 安装流程已经内置为 GUI 向导
- 底层稳定版后端仍然是 deploy_vless_xhttp.sh
- 如果缺少稳定版后端，这个控制台会自动从 GitHub 拉取
EOF2
}

ensure_interactive_terminal() {
  [[ -t 0 && -t 1 ]] || { printf '[x] 需要交互式终端环境\n' >&2; exit 1; }
}

init_ui() {
  ensure_interactive_terminal
  resolve_core_script || exit 1
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

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

init_ui
main_loop
