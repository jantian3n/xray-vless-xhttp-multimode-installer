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
  "Overview"
  "Install / Reinstall"
  "Deployment Dossier"
  "Service Control"
  "Maintenance"
  "Help"
  "Quit"
)

selected_index=0
running=1
ui_ready=0
term_cols=0
term_lines=0
log_capacity=8
LOG_LINES=()

state_mode_id=""
state_mode_label="Not deployed"
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
state_root_note="running as non-root; deployment metadata may be hidden"
last_dossier="No dossier loaded yet. Press Enter on Deployment Dossier to fetch details."

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
  printf '[x] missing curl or wget; cannot fetch stable core script: %s\n' "${CORE_REMOTE_URL}" >&2
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
    printf '[x] failed to find or download deploy_vless_xhttp.sh\n' >&2
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
  printf '\033[%s;%sH' "$(($1 + 1))" "$(($2 + 1))"
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
    single_reality) printf 'Single VPS: VLESS + XHTTP + REALITY' ;;
    split_dualstack_reality) printf 'Dualstack: IPv6 up + IPv4 down' ;;
    split_dualvps_reality_backend) printf 'Dual VPS: backend / downlink server' ;;
    split_dualvps_reality_proxy) printf 'Dual VPS: upload proxy' ;;
    split_cdn_tls_backend) printf 'CDN uplink + VPS downlink: TLS + XHTTP' ;;
    *) printf 'Not deployed' ;;
  esac
}

reset_state() {
  state_mode_id=""
  state_mode_label="Not deployed"
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
    state_root_note="root access available"
  else
    if [[ ${EUID} -ne 0 && -f "${META_FILE}" ]]; then
      state_root_note="metadata hidden by file permissions; run with sudo for full visibility"
    else
      state_root_note="no deployment metadata found yet"
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

  append_log "State refreshed from local deployment files."
}

run_core_capture() {
  bash "${CORE_SCRIPT}" "$1" 2>&1 || true
}

suspend_for_local_console() {
  local banner="$1"
  shift
  restore_terminal
  ui_ready=0
  printf '\n%s\n' "$(repeat_char '=' 72)"
  printf '[XRAY DEPLOYMENT CONSOLE]\n'
  printf '%s\n' "${banner}"
  printf 'Command: %s\n' "$*"
  printf '%s\n' "$(repeat_char '=' 72)"
  "$@"
  printf '\n[XRAY DEPLOYMENT CONSOLE] Press Enter to return...'
  read -r _
  printf '\033[?1049h\033[?25l'
  ui_ready=1
  refresh_state
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
    overview) printf 'Current local deployment state, service posture and generated artifacts.' ;;
    deploy) printf 'Launch the stable local installer for install or reinstall operations.' ;;
    dossier) printf 'Read the deployment summary and client-side instructions from local files.' ;;
    service) printf 'Inspect or control the active systemd service on this host.' ;;
    maintenance) printf 'Run update-core or uninstall from the stable local backend.' ;;
    briefing) printf 'Keyboard help, local-only execution notes and console behavior.' ;;
    quit) printf 'Leave the deployment console.' ;;
    *) printf '' ;;
  esac
}

build_main_content() {
  local id="$1"
  case "${id}" in
    overview)
      cat <<EOF2
DEPLOYMENT STATUS
- mode: ${state_mode_label}
- service: ${state_service_name}
- active: ${state_service_active}
- enabled: ${state_service_enabled}
- permissions: ${state_root_note}

SIGNALS
- upload: ${state_upload}
- download: ${state_download}
- port: ${state_port}
- security: ${state_security}
- node: ${state_node_name}

ARTIFACTS
- meta: ${state_meta_exists}
- config: ${state_config_exists}
- xray bin: ${state_xray_bin}
- client link: ${state_client_link}
- client readme: ${state_client_readme}
- split patch: ${state_client_patch}
- outbound: ${state_client_outbound}
EOF2
      ;;
    deploy)
      cat <<'EOF2'
INSTALL / REINSTALL

Press Enter to launch the stable deployment installer.
The console will temporarily yield control to the shell installer and
return here after the command finishes.

Recommended usage:
- run this wrapper with sudo
- keep the terminal window reasonably large
- use the stable script for the actual deployment logic
EOF2
      ;;
    dossier)
      cat <<EOF2
DEPLOYMENT DOSSIER

Preview:
$(printf '%s
' "${last_dossier}" | sed -n '1,14p')

Press Enter to fetch the latest dossier from the local stable script.
EOF2
      ;;
    service)
      cat <<EOF2
SERVICE CONTROL

Current unit: ${state_service_name}
Active state: ${state_service_active}
Enablement: ${state_service_enabled}

Press Enter to open the service command menu.
EOF2
      ;;
    maintenance)
      cat <<'EOF2'
MAINTENANCE

Press Enter to open maintenance operations:
- update xray-core
- uninstall current deployment

These actions execute only on the current machine.
EOF2
      ;;
    briefing)
      cat <<'EOF2'
HELP

This is a local terminal GUI built with bash, tput, ANSI and read.
It does not launch a browser and does not expose a local web service.

Keys:
- j / k or arrow keys: move selection
- Enter: execute selected action
- r: refresh state
- q: quit

Operational note:
- deployment, update and uninstall still reuse the stable local shell script
- run with sudo for full metadata visibility and service control
EOF2
      ;;
    quit)
      cat <<'EOF2'
QUIT

Press Enter to close the deployment console.
EOF2
      ;;
  esac
}

draw_header() {
  local clock_text
  clock_text="$(date '+%Y-%m-%d %H:%M:%S')"
  erase_row 0
  print_at 0 0 " $(repeat_char ' ' $((term_cols - 1)))" "$(color_header)"
  print_at 0 1 "XRAY DEPLOYMENT CONSOLE" "$(color_header)"
  print_at 0 $((term_cols - ${#clock_text} - 2)) "${clock_text}" "$(color_header)"
}

draw_nav() {
  local top=1
  local left=0
  local height=$((term_lines - 10))
  local width=30
  local i
  local row
  draw_box "${top}" "${left}" "${height}" "${width}" "SECTIONS" "$(color_accent)"
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
      if [[ "${line}" =~ ^[A-Z][A-Z\ /-]+$ && ${#line} -lt content_width ]]; then
        print_at "${row}" $((left + 2)) "${wrapped}" "$(color_accent)"
      else
        print_at "${row}" $((left + 2)) "${wrapped}" "$(color_reset)"
      fi
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
  draw_box "${top}" "${left}" "${height}" "${width}" "LOG" "$(color_warn)"
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
  local footer_text=" j/k move | Enter execute | r refresh | q quit | local shell only "
  erase_row "${footer_row}"
  print_at "${footer_row}" 0 " $(repeat_char ' ' $((term_cols - 1)))" "$(color_focus)"
  print_at "${footer_row}" 1 "${footer_text}" "$(color_focus)"
}

draw_screen() {
  get_terminal_size
  printf '\033[2J\033[H'
  if (( term_cols < 100 || term_lines < 28 )); then
    center_text 2 "Terminal too small for Xray Deployment Console" "$(color_warn)"
    center_text 4 "Required: at least 100x28" "$(color_warn)"
    center_text 5 "Current: ${term_cols}x${term_lines}" "$(color_warn)"
    center_text 7 "Resize terminal, then press r. Press q to quit." "$(color_label)"
    return
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
    '') printf 'enter' ;;
    $'\n'|$'\r') printf 'enter' ;;
    j|J) printf 'down' ;;
    k|K) printf 'up' ;;
    q|Q) printf 'quit' ;;
    r|R) printf 'refresh' ;;
    *) printf '%s' "${key}" ;;
  esac
}

prompt_choice() {
  local title="$1"
  shift
  local options=("$@")
  local local_index=0
  local choice_row_start=0
  local top left width height i key

  while true; do
    draw_screen
    width=$((term_cols - 16))
    if (( width > 90 )); then width=90; fi
    height=$(( ${#options[@]} * 2 + 7 ))
    if (( height < 11 )); then height=11; fi
    top=$(((term_lines - height) / 2))
    left=$(((term_cols - width) / 2))
    draw_box "${top}" "${left}" "${height}" "${width}" "${title}" "$(color_accent)"
    print_at $((top + 2)) $((left + 2)) "Use j/k or arrows, Enter to select, q to cancel." "$(color_label)"
    choice_row_start=$((top + 4))
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
  local width height top left key i
  while IFS= read -r line; do
    lines+=("${line}")
  done < <(wrap_text "${body}" $(( term_cols > 110 ? 102 : term_cols - 12 )))
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
    print_at $((top + height - 2)) $((left + 2)) "j/k scroll | q close" "$(color_accent)"
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
  if choice="$(prompt_choice "${title}" "Proceed" "Abort")"; then
    if [[ "${choice}" == "0" ]]; then
      return 0
    fi
  fi
  return 1
}

show_message() {
  local title="$1"
  local body="$2"
  show_text_dialog "${title}" "${body}"
}

service_menu() {
  local choice output
  if [[ "${state_service_name}" == "-" ]]; then
    show_message "Service Control" "No active service is known yet. Deploy first, or refresh with sudo for full visibility."
    return 0
  fi
  choice="$(prompt_choice "Service Control" \
    ":status   Inspect systemd status" \
    ":start    Start service" \
    ":restart  Restart service" \
    ":stop     Stop service" \
    ":back     Return")" || return 0
  case "${choice}" in
    0)
      output="$(systemctl status "${state_service_name}" --no-pager 2>&1 || true)"
      append_log "Loaded systemd status for ${state_service_name}."
      show_text_dialog "Service Status" "${output:-No status output returned.}"
      ;;
    1)
      if systemctl start "${state_service_name}" >/dev/null 2>&1; then
        refresh_state
        append_log "Started ${state_service_name}."
        show_message "Service Control" "Service started: ${state_service_name}"
      else
        output="$(systemctl start "${state_service_name}" 2>&1 || true)"
        append_log "Failed to start ${state_service_name}."
        show_text_dialog "Service Control" "${output:-Failed to start service.}"
      fi
      ;;
    2)
      if systemctl restart "${state_service_name}" >/dev/null 2>&1; then
        refresh_state
        append_log "Restarted ${state_service_name}."
        show_message "Service Control" "Service restarted: ${state_service_name}"
      else
        output="$(systemctl restart "${state_service_name}" 2>&1 || true)"
        append_log "Failed to restart ${state_service_name}."
        show_text_dialog "Service Control" "${output:-Failed to restart service.}"
      fi
      ;;
    3)
      if systemctl stop "${state_service_name}" >/dev/null 2>&1; then
        refresh_state
        append_log "Stopped ${state_service_name}."
        show_message "Service Control" "Service stopped: ${state_service_name}"
      else
        output="$(systemctl stop "${state_service_name}" 2>&1 || true)"
        append_log "Failed to stop ${state_service_name}."
        show_text_dialog "Service Control" "${output:-Failed to stop service.}"
      fi
      ;;
  esac
}

maintenance_menu() {
  local choice
  choice="$(prompt_choice "Maintenance" \
    "update-core   Refresh xray-core using the stable backend" \
    "uninstall     Remove deployed services and files" \
    "back          Return")" || return 0
  case "${choice}" in
    0)
      if confirm_dialog "Update Core" "Run update-core on the current machine?"; then
        append_log "Entering update-core flow."
        suspend_for_local_console "Updating xray-core using the stable backend." bash "${CORE_SCRIPT}" update-core
      fi
      ;;
    1)
      if confirm_dialog "Uninstall" "Run uninstall on the current machine?"; then
        append_log "Entering uninstall flow."
        suspend_for_local_console "Entering uninstall flow using the stable backend." bash "${CORE_SCRIPT}" uninstall
      fi
      ;;
  esac
}

execute_selected() {
  local id output
  id="$(active_nav_id)"
  case "${id}" in
    overview)
      show_text_dialog "Overview" "$(build_main_content overview)"
      ;;
    deploy)
      if confirm_dialog "Install / Reinstall" "Launch the stable deployment installer now?"; then
        append_log "Entering stable install flow."
        suspend_for_local_console "Switching to the stable deployment installer." bash "${CORE_SCRIPT}" install
      fi
      ;;
    dossier)
      output="$(run_core_capture show)"
      last_dossier="${output:-No dossier output returned.}"
      append_log "Deployment dossier captured from stable backend."
      show_text_dialog "Deployment Dossier" "${last_dossier}"
      ;;
    service)
      service_menu
      ;;
    maintenance)
      maintenance_menu
      ;;
    briefing)
      show_text_dialog "Help" "$(build_main_content briefing)"
      ;;
    quit)
      running=0
      ;;
  esac
}

usage() {
  cat <<EOF2
Usage:
  bash ${SCRIPT_NAME}              start the local terminal deployment console
  bash ${SCRIPT_NAME} --help

Notes:
- this is a local bash+ANSI terminal GUI
- no browser and no web service are used
- the stable backend remains deploy_vless_xhttp.sh
- if the stable backend is missing, this wrapper can fetch it from GitHub
EOF2
}

ensure_interactive_terminal() {
  [[ -t 0 && -t 1 ]] || { printf '[x] interactive terminal required\n' >&2; exit 1; }
}

init_ui() {
  ensure_interactive_terminal
  resolve_core_script || exit 1
  printf '\033[?1049h\033[?25l'
  ui_ready=1
}

main_loop() {
  local key
  append_log "Console online."
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
        ;;
      refresh)
        refresh_state
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
