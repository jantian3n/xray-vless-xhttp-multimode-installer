#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "$0")"
BETA_LOCAL_CORE_SCRIPT="${SCRIPT_DIR}/deploy_vless_xhttp.sh"
BETA_REMOTE_CORE_URL="${XRAY_STABLE_SCRIPT_URL:-https://raw.githubusercontent.com/jantian3n/xray-vless-xhttp-multimode-installer/main/deploy_vless_xhttp.sh}"
BETA_BOOTSTRAP_FILE=""
BETA_UI_MODE="${XRAY_UI_MODE:-auto}"
BETA_UI_THEME="${XRAY_UI_THEME:-vim}"
BETA_WHIPTAIL_BIN=""
BETA_GUI_READY="0"
BETA_NEWT_COLORS=""
BETA_DIALOG_TITLE="Xray 一键部署脚本 Beta"
BETA_BACKTITLE="[VIM] Xray Beta | VLESS + XHTTP 多模式安装器"
BETA_MENU_HEIGHT=22
BETA_MENU_WIDTH=92
BETA_TEXT_HEIGHT=26
BETA_TEXT_WIDTH=100

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

beta_ui_mode_label() {
  if [[ -n "${DEPLOY_MODE:-}" ]]; then
    mode_label
  else
    printf '未部署'
  fi
}

beta_ui_service_label() {
  if [[ -n "${ACTIVE_SERVICE:-}" ]]; then
    printf '%s' "${ACTIVE_SERVICE}"
  elif [[ -n "${DEPLOY_MODE:-}" ]]; then
    active_service_name
  else
    printf '-'
  fi
}

beta_render_panel() {
  local state="$1"
  local title="$2"
  local body="$3"
  local keys="$4"
  local mode_text
  local service_text

  mode_text="$(beta_ui_mode_label)"
  service_text="$(beta_ui_service_label)"

  cat <<EOF
+--------------------------------------------------------------+
[$(printf '%s' "${state}" | tr '[:lower:]' '[:upper:]')] ${title}
mode: ${mode_text}
service: ${service_text}
theme: ${BETA_UI_THEME}
keys: ${keys}
+--------------------------------------------------------------+
${body}
EOF
}

beta_apply_theme() {
  case "${BETA_UI_THEME}" in
    vim)
      BETA_NEWT_COLORS='root=green,black;window=white,black;border=green,black;title=lightgreen,black;textbox=white,black;entry=white,black;button=black,green;actbutton=black,lightgreen;checkbox=green,black;actcheckbox=black,green;compactbutton=black,green'
      ;;
    default|classic|"")
      BETA_NEWT_COLORS=""
      ;;
    *)
      classic_warn "未知 XRAY_UI_THEME=${BETA_UI_THEME}，将使用 vim 主题。"
      BETA_NEWT_COLORS='root=green,black;window=white,black;border=green,black;title=lightgreen,black;textbox=white,black;entry=white,black;button=black,green;actbutton=black,lightgreen;checkbox=green,black;actcheckbox=black,green;compactbutton=black,green'
      ;;
  esac

  if [[ -n "${BETA_NEWT_COLORS}" ]]; then
    export NEWT_COLORS="${BETA_NEWT_COLORS}"
  else
    unset NEWT_COLORS || true
  fi
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
    beta_apply_theme
    return 0
  fi

  BETA_GUI_READY="0"
  return 1
}

beta_textbox() {
  local title="$1"
  local content="$2"
  local tmp_file
  local framed_content

  if ! beta_should_use_gui; then
    printf '%s\n' "${content}"
    return 0
  fi

  tmp_file="$(mktemp)"
  framed_content="$(beta_render_panel "view" "${title}" "" "Up/Down scroll | PgUp/PgDn fast | Tab switch | Enter close")"
  printf '%s\n\n%s\n' "${framed_content}" "${content}" > "${tmp_file}"
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
  local framed_message

  if ! beta_should_use_gui; then
    printf '[!] %s\n' "${message}" >&2
    return 0
  fi

  framed_message="$(beta_render_panel "message" "${title}" "${message}" "Enter close")"
  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --msgbox "${framed_message}" 16 88
}

beta_inputbox() {
  local title="$1"
  local prompt="$2"
  local default_value="${3-}"
  local result
  local framed_prompt

  framed_prompt="$(beta_render_panel "input" "${title}" "${prompt}" "Edit value | Enter confirm | Esc cancel")"
  if result="$("${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --inputbox "${framed_prompt}" 18 88 "${default_value}" \
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
  local framed_prompt
  shift 3

  framed_prompt="$(beta_render_panel "normal" "${title}" "${prompt}" "Up/Down move | Tab buttons | Enter select | Esc back")"
  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --default-item "${default_item}" \
    --menu "${framed_prompt}" "${BETA_MENU_HEIGHT}" "${BETA_MENU_WIDTH}" 9 \
    "$@" \
    3>&1 1>&2 2>&3
}

beta_yesno() {
  local title="$1"
  local prompt="$2"
  local default_choice="${3:-y}"
  local -a args=()
  local framed_prompt

  if [[ "${default_choice}" == "n" ]]; then
    args+=(--defaultno)
  fi

  framed_prompt="$(beta_render_panel "confirm" "${title}" "${prompt}" "Tab switch | Enter confirm | Esc cancel")"
  "${BETA_WHIPTAIL_BIN}" \
    --backtitle "${BETA_BACKTITLE}" \
    --title "${title}" \
    --yes-button "是" \
    --no-button "否" \
    "${args[@]}" \
    --yesno "${framed_prompt}" 16 88
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
    "MODE SELECT" \
    "请选择当前机器要承担的角色。" \
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

  if choice="$(beta_menu "XHTTP MODE" "请选择 XHTTP 传输模式。" "${default_item}" "${menu_items[@]}")"; then
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
- 默认使用 vim 风格配色，可用 XRAY_UI_THEME=default 切回默认主题
- 界面额外加入了 NORMAL / INPUT / VIEW / CONFIRM 风格状态栏和快捷键提示

提示:
- Debian / Ubuntu 可执行: apt-get update -y && apt-get install -y whiptail
- 也可以设置 XRAY_UI_MODE=classic 强制使用旧菜单
EOF
}

main_menu() {
  local current_state
  local choice

  if ! beta_should_use_gui; then
    classic_main_menu
    return 0
  fi

  if [[ -f "${META_FILE}" ]]; then
    load_existing_meta_if_any
  fi

  current_state="欢迎进入 beta 安装器。

这里保留稳定版的底层逻辑，只优化终端交互层。
请选择要执行的操作。"

  while true; do
    if choice="$(beta_menu \
      "NORMAL" \
      "${current_state}" \
      "1" \
      1 "[Install] 安装 / 重装" \
      2 "[Inspect] 查看当前配置和客户端信息" \
      3 "[Service] 服务管理" \
      4 "[Update] 更新 Xray 内核" \
      5 "[Clean] 卸载" \
      6 "[Help] Beta 说明" \
      0 "[Quit] 退出 / :q")"; then
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
      fi
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
      "SERVICE" \
      "当前服务: ${service_name}

请选择操作。" \
      "1" \
      1 "[:status] 查看状态" \
      2 "[:start] 启动服务" \
      3 "[:restart] 重启服务" \
      4 "[:stop] 停止服务" \
      0 "[:back] 返回")"; then
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
