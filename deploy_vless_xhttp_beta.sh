#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
BETA_LOCAL_CORE_SCRIPT="${SCRIPT_DIR}/deploy_vless_xhttp.sh"
BETA_REMOTE_CORE_URL="${XRAY_STABLE_SCRIPT_URL:-https://raw.githubusercontent.com/jantian3n/xray-vless-xhttp-multimode-installer/main/deploy_vless_xhttp.sh}"
BETA_BOOTSTRAP_FILE=""
BETA_UI_MODE="${XRAY_UI_MODE:-auto}"
BETA_WHIPTAIL_BIN=""
BETA_GUI_READY="0"
BETA_DIALOG_TITLE="Xray 一键部署脚本 Beta"
BETA_BACKTITLE="VLESS + XHTTP 多模式安装器 Beta"
BETA_MENU_HEIGHT=18
BETA_MENU_WIDTH=88
BETA_TEXT_HEIGHT=24
BETA_TEXT_WIDTH=96

cleanup_beta_bootstrap() {
  if [[ -n "${BETA_BOOTSTRAP_FILE}" && -f "${BETA_BOOTSTRAP_FILE}" ]]; then
    rm -f "${BETA_BOOTSTRAP_FILE}"
  fi
}

download_beta_core_script() {
  local target_file="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${BETA_REMOTE_CORE_URL}" -o "${target_file}"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "${target_file}" "${BETA_REMOTE_CORE_URL}"
    return 0
  fi

  printf '[x] 缺少 curl 或 wget，无法自动下载稳定版脚本: %s\n' "${BETA_REMOTE_CORE_URL}" >&2
  exit 1
}

resolve_beta_core_script() {
  if [[ -f "${BETA_LOCAL_CORE_SCRIPT}" ]]; then
    printf '%s' "${BETA_LOCAL_CORE_SCRIPT}"
    return 0
  fi

  BETA_BOOTSTRAP_FILE="$(mktemp)"

  if ! download_beta_core_script "${BETA_BOOTSTRAP_FILE}"; then
    rm -f "${BETA_BOOTSTRAP_FILE}"
    BETA_BOOTSTRAP_FILE=""
    printf '[x] 未在本地找到 deploy_vless_xhttp.sh，且自动下载失败。\n' >&2
    printf '[x] 你可以把稳定版脚本放到同目录，或设置 XRAY_STABLE_SCRIPT_URL 指向可访问地址。\n' >&2
    exit 1
  fi

  printf '%s' "${BETA_BOOTSTRAP_FILE}"
}

trap cleanup_beta_bootstrap EXIT

# shellcheck source=./deploy_vless_xhttp.sh
source "$(resolve_beta_core_script)"

clone_function() {
  local source_name="$1"
  local target_name="$2"

  eval "$(declare -f "${source_name}" | sed "1s/^${source_name} ()/${target_name} ()/")"
}

clone_function prompt_default classic_prompt_default
clone_function prompt_yes_no classic_prompt_yes_no
clone_function choose_deploy_mode classic_choose_deploy_mode
clone_function choose_xhttp_mode classic_choose_xhttp_mode
clone_function main_menu classic_main_menu
clone_function service_menu classic_service_menu
clone_function show_summary classic_show_summary
clone_function show_service_status classic_show_service_status
clone_function warn classic_warn

beta_should_use_gui() {
  [[ "${BETA_GUI_READY}" == "1" ]]
}

beta_init_ui() {
  case "${BETA_UI_MODE}" in
    classic)
      BETA_GUI_READY="0"
      return 1
      ;;
    auto|whiptail)
      ;;
    *)
      classic_warn "未知 XRAY_UI_MODE=${BETA_UI_MODE}，将按 auto 处理。"
      ;;
  esac

  if [[ ! -t 0 || ! -t 1 ]]; then
    BETA_GUI_READY="0"
    return 1
  fi

  if command -v whiptail >/dev/null 2>&1; then
    BETA_WHIPTAIL_BIN="$(command -v whiptail)"
    BETA_GUI_READY="1"
    return 0
  fi

  BETA_GUI_READY="0"
  return 1
}

beta_textbox() {
  local title="$1"
  local content="$2"
  local tmp_file

  if ! beta_should_use_gui; then
    printf '%s\n' "${content}"
    return 0
  fi

  tmp_file="$(mktemp)"
  printf '%s\n' "${content}" > "${tmp_file}"
  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --scrolltext \
    --textbox "${tmp_file}" "${BETA_TEXT_HEIGHT}" "${BETA_TEXT_WIDTH}"
  rm -f "${tmp_file}"
}

beta_msgbox() {
  local title="$1"
  local message="$2"

  if ! beta_should_use_gui; then
    printf '[!] %s\n' "${message}" >&2
    return 0
  fi

  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --msgbox "${message}" 12 78
}

beta_inputbox() {
  local title="$1"
  local prompt="$2"
  local default_value="${3-}"
  local result

  if result="$("${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --inputbox "${prompt}" 12 88 "${default_value}" \
    3>&1 1>&2 2>&3)"; then
    printf '%s' "${result}"
    return 0
  fi

  return 1
}

beta_menu() {
  local title="$1"
  local prompt="$2"
  local default_item="$3"
  shift 3

  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --default-item "${default_item}" \
    --menu "${prompt}" "${BETA_MENU_HEIGHT}" "${BETA_MENU_WIDTH}" 9 \
    "$@" \
    3>&1 1>&2 2>&3
}

beta_yesno() {
  local title="$1"
  local prompt="$2"
  local default_choice="${3:-y}"
  local -a args=()

  if [[ "${default_choice}" == "n" ]]; then
    args+=(--defaultno)
  fi

  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --yes-button "是" \
    --no-button "否" \
    "${args[@]}" \
    --yesno "${prompt}" 12 78
}

warn() {
  if beta_should_use_gui; then
    beta_msgbox "提示" "$*"
  else
    classic_warn "$@"
  fi
}

die() {
  local message="$*"

  if beta_should_use_gui; then
    beta_msgbox "错误" "${message}"
  fi

  printf '[x] %s\n' "${message}" >&2
  exit 1
}

prompt_default() {
  local prompt="$1"
  local default_value="${2-}"
  local reply

  if ! beta_should_use_gui; then
    classic_prompt_default "$@"
    return 0
  fi

  if reply="$(beta_inputbox "参数输入" "${prompt}" "${default_value}")"; then
    printf '%s' "${reply:-${default_value}}"
    return 0
  fi

  die "已取消操作。"
}

prompt_yes_no() {
  local prompt="$1"
  local default_value="${2:-y}"

  if ! beta_should_use_gui; then
    classic_prompt_yes_no "$@"
    return 0
  fi

  beta_yesno "确认" "${prompt}" "${default_value}"
}

choose_deploy_mode() {
  local current="${1:-single_reality}"
  local choice

  if ! beta_should_use_gui; then
    classic_choose_deploy_mode "$@"
    return 0
  fi

  if choice="$(beta_menu \
    "部署模式" \
    "请选择当前机器要承担的角色：" \
    "$(default_mode_number "${current}")" \
    1 "单 VPS：VLESS + XHTTP + REALITY" \
    2 "同机分离：IPv6 上行 + IPv4 下行" \
    3 "双 VPS：当前机器部署 VPS2 后端" \
    4 "双 VPS：当前机器部署 VPS1 上传代理" \
    5 "CDN 上行 + VPS 下行：TLS 后端")"; then
    case "${choice}" in
      1) printf 'single_reality' ;;
      2) printf 'split_dualstack_reality' ;;
      3) printf 'split_dualvps_reality_backend' ;;
      4) printf 'split_dualvps_reality_proxy' ;;
      5) printf 'split_cdn_tls_backend' ;;
      *) die "未知部署模式。" ;;
    esac
    return 0
  fi

  die "已取消操作。"
}

choose_xhttp_mode() {
  local current="${1:-auto}"
  local allow_stream_one="${2:-yes}"
  local default_item
  local choice
  local -a menu_items=(
    1 "auto：默认推荐，兼容性最好"
    2 "packet-up：偏传统上行包模式"
    3 "stream-up：流式上行"
  )

  if ! beta_should_use_gui; then
    classic_choose_xhttp_mode "$@"
    return 0
  fi

  default_item="$(default_xhttp_mode_number "${current}")"
  if [[ "${allow_stream_one}" == "yes" ]]; then
    menu_items+=(4 "stream-one：单流模式")
  elif [[ "${default_item}" == "4" ]]; then
    default_item="1"
  fi

  if choice="$(beta_menu "XHTTP Mode" "请选择 XHTTP 传输模式：" "${default_item}" "${menu_items[@]}")"; then
    case "${choice}" in
      1) printf 'auto' ;;
      2) printf 'packet-up' ;;
      3) printf 'stream-up' ;;
      4)
        if [[ "${allow_stream_one}" == "yes" ]]; then
          printf 'stream-one'
        else
          die "当前模式不建议使用 stream-one。"
        fi
        ;;
      *) die "未知 XHTTP mode。" ;;
    esac
    return 0
  fi

  die "已取消操作。"
}

show_summary() {
  local content

  if ! beta_should_use_gui; then
    classic_show_summary
    return 0
  fi

  content="$(classic_show_summary)"
  beta_textbox "部署摘要" "${content}"
}

show_service_status() {
  local content
  local service_name

  if ! beta_should_use_gui; then
    classic_show_service_status
    return 0
  fi

  service_name="$(active_service_name)"
  content="$(systemctl status "${service_name}" --no-pager 2>&1 || true)"
  beta_textbox "服务状态" "${content}"
}

beta_runtime_hint() {
  cat <<'EOF'
当前界面是 Beta 终端 GUI。

说明:
- 底层部署逻辑仍然复用稳定版脚本
- 如果目标机器安装了 whiptail，就会显示图形化终端菜单
- 如果没有 whiptail，会自动回退到经典文本菜单

提示:
- Debian / Ubuntu 可执行: apt-get update -y && apt-get install -y whiptail
- 也可以设置 XRAY_UI_MODE=classic 强制使用旧菜单
EOF
}

main_menu() {
  local current_state
  local current_mode="未部署"
  local current_service="-"
  local choice

  if ! beta_should_use_gui; then
    classic_main_menu
    return 0
  fi

  if [[ -f "${META_FILE}" ]]; then
    load_existing_meta_if_any
    current_mode="$(mode_label)"
    current_service="$(active_service_name)"
  fi

  current_state="当前状态:
- 模式: ${current_mode}
- 服务: ${current_service}

请选择要执行的操作："

  while true; do
    if choice="$(beta_menu \
      "${BETA_DIALOG_TITLE}" \
      "${current_state}" \
      "1" \
      1 "安装 / 重装" \
      2 "查看当前配置和客户端信息" \
      3 "服务管理" \
      4 "更新 Xray 内核" \
      5 "卸载" \
      6 "Beta 说明" \
      0 "退出")"; then
      case "${choice}" in
        1) configure_and_apply ;;
        2) show_current_info ;;
        3) service_menu ;;
        4) update_core_only ;;
        5) uninstall_all ;;
        6) beta_textbox "Beta 说明" "$(beta_runtime_hint)" ;;
        0) return 0 ;;
        *) warn "请输入有效序号。" ;;
      esac

      if [[ -f "${META_FILE}" ]]; then
        load_existing_meta_if_any
        current_mode="$(mode_label)"
        current_service="$(active_service_name)"
      else
        current_mode="未部署"
        current_service="-"
      fi
      current_state="当前状态:
- 模式: ${current_mode}
- 服务: ${current_service}

请选择要执行的操作："
      continue
    fi

    return 0
  done
}

service_menu() {
  local service_name
  local choice

  if ! beta_should_use_gui; then
    classic_service_menu
    return 0
  fi

  require_root
  load_existing_meta_if_any
  service_name="$(active_service_name)"

  while true; do
    if choice="$(beta_menu \
      "服务管理" \
      "当前服务: ${service_name}

请选择操作：" \
      "1" \
      1 "查看状态" \
      2 "启动服务" \
      3 "重启服务" \
      4 "停止服务" \
      0 "返回")"; then
      case "${choice}" in
        1) show_service_status ;;
        2) systemctl start "${service_name}" ; beta_msgbox "完成" "已启动 ${service_name}" ;;
        3) systemctl restart "${service_name}" ; beta_msgbox "完成" "已重启 ${service_name}" ;;
        4) systemctl stop "${service_name}" ; beta_msgbox "完成" "已停止 ${service_name}" ;;
        0) return 0 ;;
        *) warn "请输入有效序号。" ;;
      esac
      continue
    fi

    return 0
  done
}

beta_dispatch() {
  local command="${1:-menu}"

  beta_init_ui || true

  if ! beta_should_use_gui; then
    case "${command}" in
      menu|install|service)
        classic_warn "未检测到 whiptail，Beta 版将自动回退到经典文本菜单。若要启用终端 GUI，可先安装 whiptail。"
        ;;
    esac
  fi

  dispatch_cli "$@"
}

beta_dispatch "$@"
