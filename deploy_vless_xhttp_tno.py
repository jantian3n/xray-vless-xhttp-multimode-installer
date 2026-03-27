#!/usr/bin/env python3

import curses
import locale
import os
import shlex
import subprocess
import sys
import textwrap
import time
from typing import Dict, List, Optional, Sequence, Tuple

locale.setlocale(locale.LC_ALL, "")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_CORE_SCRIPT = os.path.join(SCRIPT_DIR, "deploy_vless_xhttp.sh")
CORE_SCRIPT = os.environ.get("XRAY_CORE_SCRIPT", DEFAULT_CORE_SCRIPT)

XRAY_BIN = "/usr/local/bin/xray"
CONFIG_DIR = "/usr/local/etc/xray"
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
META_FILE = os.path.join(CONFIG_DIR, "deploy_mode.env")
CLIENT_LINK_FILE = os.path.join(CONFIG_DIR, "client_vless_link.txt")
CLIENT_PATCH_FILE = os.path.join(CONFIG_DIR, "client_split_patch.json")
CLIENT_OUTBOUND_FILE = os.path.join(CONFIG_DIR, "client_outbound.json")
CLIENT_README_FILE = os.path.join(CONFIG_DIR, "client_readme.txt")
PROXY_SERVICE_NAME = "xhttp-upload-proxy"

X_RAY_MODES = {
    "single_reality",
    "split_dualstack_reality",
    "split_dualvps_reality_backend",
    "split_cdn_tls_backend",
}

MODE_LABELS = {
    "single_reality": "单 VPS: VLESS + XHTTP + REALITY",
    "split_dualstack_reality": "同机分离: IPv6 上行 + IPv4 下行",
    "split_dualvps_reality_backend": "双 VPS: VPS2 后端 / 下行服务器",
    "split_dualvps_reality_proxy": "双 VPS: VPS1 上传代理",
    "split_cdn_tls_backend": "CDN 上行 + VPS 下行: TLS + XHTTP",
}

NAV_ITEMS = [
    {
        "id": "overview",
        "title": "STRATEGIC OVERVIEW",
        "summary": "态势总览、部署信息、服务运行状态。",
    },
    {
        "id": "deploy",
        "title": "DEPLOYMENT CONSOLE",
        "summary": "进入本地安全部署控制台，执行安装或重装。",
    },
    {
        "id": "dossier",
        "title": "DEPLOYMENT DOSSIER",
        "summary": "读取当前部署摘要、节点文件与服务线索。",
    },
    {
        "id": "service",
        "title": "SERVICE COMMAND",
        "summary": "查看状态、启动、重启或停止 systemd 服务。",
    },
    {
        "id": "maintenance",
        "title": "MAINTENANCE",
        "summary": "更新 Xray 内核或执行本地卸载流程。",
    },
    {
        "id": "briefing",
        "title": "BRIEFING",
        "summary": "查看这个独立 TNO 风格终端的设计说明。",
    },
    {
        "id": "exit",
        "title": "EXIT",
        "summary": "离开当前战略终端。",
    },
]


class TNOApp:
    def __init__(self) -> None:
        if not os.path.isfile(CORE_SCRIPT):
            raise SystemExit(
                "未找到 deploy_vless_xhttp.sh。\n"
                "这个 TNO 终端不会联网拉取核心脚本，请把稳定版脚本放到同目录，"
                "或设置 XRAY_CORE_SCRIPT 指向本地 deploy_vless_xhttp.sh。"
            )

        self.stdscr: Optional[curses.window] = None
        self.selected_index = 0
        self.running = True
        self.logs: List[str] = []
        self.state: Dict[str, str] = {}
        self.last_dossier = "尚未生成 dossier。按 Enter 可读取最新部署摘要。"
        self.refresh_state(initial=True)

    def log(self, message: str) -> None:
        timestamp = time.strftime("%H:%M:%S")
        self.logs.append(f"[{timestamp}] {message}")
        self.logs = self.logs[-8:]

    def run_capture(self, args: Sequence[str]) -> Tuple[int, str]:
        proc = subprocess.run(
            args,
            text=True,
            capture_output=True,
            encoding="utf-8",
            errors="replace",
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode, output.strip()

    def run_core_capture(self, command: str) -> Tuple[int, str]:
        return self.run_capture(["bash", CORE_SCRIPT, command])

    def parse_meta_file(self) -> Dict[str, str]:
        meta: Dict[str, str] = {}
        if not os.path.isfile(META_FILE):
            return meta

        with open(META_FILE, "r", encoding="utf-8", errors="replace") as handle:
            for raw_line in handle:
                line = raw_line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                try:
                    parsed = shlex.split(value, posix=True)
                    meta[key] = parsed[0] if parsed else ""
                except ValueError:
                    meta[key] = value
        return meta

    def resolve_service_name(self, meta: Dict[str, str]) -> str:
        if meta.get("ACTIVE_SERVICE"):
            return meta["ACTIVE_SERVICE"]
        deploy_mode = meta.get("DEPLOY_MODE", "")
        if deploy_mode in X_RAY_MODES:
            return "xray"
        if deploy_mode == "split_dualvps_reality_proxy":
            return PROXY_SERVICE_NAME
        return "-"

    def probe_service_state(self, service_name: str) -> Dict[str, str]:
        if service_name == "-":
            return {"active": "n/a", "enabled": "n/a"}

        active_code, active_out = self.run_capture(["systemctl", "is-active", service_name])
        enabled_code, enabled_out = self.run_capture(["systemctl", "is-enabled", service_name])
        return {
            "active": active_out if active_out else ("active" if active_code == 0 else "unknown"),
            "enabled": enabled_out if enabled_out else ("enabled" if enabled_code == 0 else "unknown"),
        }

    def refresh_state(self, initial: bool = False) -> None:
        meta = self.parse_meta_file()
        service_name = self.resolve_service_name(meta)
        service_state = self.probe_service_state(service_name)

        self.state = {
            "mode_id": meta.get("DEPLOY_MODE", ""),
            "mode_label": MODE_LABELS.get(meta.get("DEPLOY_MODE", ""), "未部署"),
            "service_name": service_name,
            "service_active": service_state.get("active", "n/a"),
            "service_enabled": service_state.get("enabled", "n/a"),
            "upload": meta.get("UPLOAD_ADDRESS", "-"),
            "download": meta.get("DOWNLOAD_ADDRESS", "-"),
            "port": meta.get("PORT", "-"),
            "security": meta.get("SECURITY_MODE", "-"),
            "node_name": meta.get("NODE_NAME", "-"),
            "uuid": meta.get("UUID", "-"),
            "config_exists": "yes" if os.path.isfile(CONFIG_FILE) else "no",
            "meta_exists": "yes" if os.path.isfile(META_FILE) else "no",
            "xray_bin": "yes" if os.path.isfile(XRAY_BIN) else "no",
            "client_readme": "yes" if os.path.isfile(CLIENT_README_FILE) else "no",
            "client_link": "yes" if os.path.isfile(CLIENT_LINK_FILE) else "no",
            "client_patch": "yes" if os.path.isfile(CLIENT_PATCH_FILE) else "no",
            "client_outbound": "yes" if os.path.isfile(CLIENT_OUTBOUND_FILE) else "no",
        }
        if initial:
            self.log("TNO command room online.")
        else:
            self.log("State refreshed from local deployment files.")

    def init_colors(self) -> None:
        curses.start_color()
        curses.use_default_colors()
        curses.init_pair(1, curses.COLOR_YELLOW, curses.COLOR_BLACK)
        curses.init_pair(2, curses.COLOR_BLACK, curses.COLOR_YELLOW)
        curses.init_pair(3, curses.COLOR_WHITE, curses.COLOR_BLACK)
        curses.init_pair(4, curses.COLOR_RED, curses.COLOR_BLACK)
        curses.init_pair(5, curses.COLOR_CYAN, curses.COLOR_BLACK)
        curses.init_pair(6, curses.COLOR_BLACK, curses.COLOR_WHITE)

    def color(self, pair_id: int) -> int:
        return curses.color_pair(pair_id)

    def safe_add(self, win: curses.window, y: int, x: int, text: str, attr: int = 0) -> None:
        try:
            height, width = win.getmaxyx()
            if y < 0 or y >= height or x >= width:
                return
            clipped = text[: max(0, width - x - 1)]
            win.addstr(y, x, clipped, attr)
        except curses.error:
            return

    def draw_box(self, win: curses.window, title: str, accent: int) -> None:
        height, width = win.getmaxyx()
        win.erase()
        win.attron(accent)
        try:
            win.border()
        except curses.error:
            pass
        self.safe_add(win, 0, 2, f" {title} ", accent | curses.A_BOLD)
        self.safe_add(win, height - 1, 2, " local-only secure terminal ", accent)
        win.attroff(accent)

    def wrap_block(self, text: str, width: int) -> List[str]:
        lines: List[str] = []
        for paragraph in text.splitlines():
            if not paragraph.strip():
                lines.append("")
                continue
            wrapped = textwrap.wrap(paragraph, width=width, replace_whitespace=False) or [""]
            lines.extend(wrapped)
        return lines

    def build_overview_lines(self) -> List[str]:
        lines = [
            "THEATER STATUS",
            f"- mode: {self.state['mode_label']}",
            f"- service: {self.state['service_name']}",
            f"- active: {self.state['service_active']}",
            f"- enabled: {self.state['service_enabled']}",
            "",
            "DEPLOYMENT SIGNALS",
            f"- upload: {self.state['upload']}",
            f"- download: {self.state['download']}",
            f"- port: {self.state['port']}",
            f"- security: {self.state['security']}",
            f"- node: {self.state['node_name']}",
            "",
            "ARTIFACT PRESENCE",
            f"- meta: {self.state['meta_exists']}",
            f"- config: {self.state['config_exists']}",
            f"- xray bin: {self.state['xray_bin']}",
            f"- client link: {self.state['client_link']}",
            f"- client readme: {self.state['client_readme']}",
            f"- split patch: {self.state['client_patch']}",
            f"- outbound: {self.state['client_outbound']}",
        ]
        if self.state["mode_id"] in X_RAY_MODES:
            lines.extend([
                "",
                "RECOMMENDED ORDERS",
                "- Enter dossier to read the exact local deployment summary.",
                "- Enter maintenance to update xray-core in-place.",
                "- Enter service command if the unit needs recovery.",
            ])
        else:
            lines.extend([
                "",
                "RECOMMENDED ORDERS",
                "- Enter deployment console to start a fresh install.",
                "- This terminal keeps all actions local to the machine.",
            ])
        return lines

    def build_briefing_text(self) -> str:
        return "\n".join([
            "TNO LOCAL COMMAND ROOM",
            "",
            "This interface is a separate local TUI frontend.",
            "It does not spin up a browser, does not open a local web server, and",
            "does not expose a remote control surface beyond your shell session.",
            "",
            "Design goals:",
            "- Stronger strategic dashboard feel than the whiptail beta shell.",
            "- Local-only execution path for lower security exposure.",
            "- Reuse the existing deploy script as the operational backbone.",
            "",
            "Keybindings:",
            "- j / k or arrow keys: move through sections",
            "- Enter: execute the selected operation",
            "- r: refresh deployment state",
            "- q: quit the command room",
            "",
            "Install workflow note:",
            "- Deployment itself still hands control to the existing local installer",
            "  so we keep the proven shell logic instead of re-implementing it twice.",
        ])

    def main_panel_lines(self) -> List[str]:
        item = NAV_ITEMS[self.selected_index]
        if item["id"] == "overview":
            return self.build_overview_lines()
        if item["id"] == "deploy":
            return [
                "DEPLOYMENT CONSOLE",
                "",
                "Press Enter to drop into the local deployment console.",
                "The TUI will temporarily yield the terminal to the original installer,",
                "then recover the screen when you return.",
                "",
                "Why this path:",
                "- no browser",
                "- no exposed localhost service",
                "- no duplicated deployment backend",
            ]
        if item["id"] == "dossier":
            preview = self.last_dossier.splitlines()[:10]
            lines = ["DOSSIER PREVIEW", ""]
            lines.extend(preview or ["No dossier loaded yet."])
            lines.extend(["", "Press Enter to capture the latest deployment dossier."])
            return lines
        if item["id"] == "service":
            return [
                "SERVICE COMMAND",
                "",
                f"Current unit: {self.state['service_name']}",
                f"Active state: {self.state['service_active']}",
                f"Enablement: {self.state['service_enabled']}",
                "",
                "Press Enter to open the service command submenu.",
            ]
        if item["id"] == "maintenance":
            return [
                "MAINTENANCE",
                "",
                "Press Enter to open maintenance orders:",
                "- update xray-core",
                "- local uninstall flow",
                "",
                "These actions still execute only on the current machine.",
            ]
        if item["id"] == "briefing":
            return self.build_briefing_text().splitlines()
        return [
            "EXIT",
            "",
            "Press Enter or q to leave the terminal.",
        ]

    def draw_header(self, win: curses.window) -> None:
        height, width = win.getmaxyx()
        title = " TNO STRATEGIC COMMAND // XRAY DIRECTORATE "
        clock = time.strftime("%Y-%m-%d %H:%M:%S")
        win.erase()
        win.bkgd(" ", self.color(2) | curses.A_BOLD)
        self.safe_add(win, 0, 1, title, self.color(2) | curses.A_BOLD)
        self.safe_add(win, 0, max(1, width - len(clock) - 2), clock, self.color(2) | curses.A_BOLD)

    def draw_nav(self, win: curses.window) -> None:
        self.draw_box(win, "SECTORS", self.color(1))
        for index, item in enumerate(NAV_ITEMS):
            marker = ">" if index == self.selected_index else " "
            label = f"{marker} {item['title']}"
            attr = self.color(2) | curses.A_BOLD if index == self.selected_index else self.color(3)
            self.safe_add(win, 2 + index * 2, 2, label, attr)

    def draw_main(self, win: curses.window) -> None:
        item = NAV_ITEMS[self.selected_index]
        self.draw_box(win, item["title"], self.color(5))
        self.safe_add(win, 2, 2, item["summary"], self.color(5) | curses.A_BOLD)
        content_lines = self.main_panel_lines()
        y = 4
        height, width = win.getmaxyx()
        for raw in content_lines:
            for line in self.wrap_block(raw, max(10, width - 4)) or [""]:
                if y >= height - 2:
                    return
                attr = self.color(3)
                if raw.isupper() and line == raw and len(raw) < width - 4:
                    attr = self.color(1) | curses.A_BOLD
                self.safe_add(win, y, 2, line, attr)
                y += 1

    def draw_logs(self, win: curses.window) -> None:
        self.draw_box(win, "FIELD LOG", self.color(4))
        recent = self.logs[-(win.getmaxyx()[0] - 3):]
        for idx, line in enumerate(recent, start=1):
            self.safe_add(win, idx, 2, line, self.color(3))

    def draw_footer(self, win: curses.window) -> None:
        height, width = win.getmaxyx()
        footer = " j/k move | Enter execute | r refresh | q quit | local terminal only "
        win.erase()
        win.bkgd(" ", self.color(6) | curses.A_BOLD)
        self.safe_add(win, 0, 1, footer[: max(0, width - 2)], self.color(6) | curses.A_BOLD)

    def popup_menu(self, title: str, intro: str, options: List[Tuple[str, str]]) -> Optional[int]:
        selected = 0
        while True:
            max_y, max_x = self.stdscr.getmaxyx()
            box_h = min(max_y - 4, max(12, len(options) * 2 + 8))
            box_w = min(max_x - 6, 96)
            start_y = (max_y - box_h) // 2
            start_x = (max_x - box_w) // 2
            win = curses.newwin(box_h, box_w, start_y, start_x)
            self.draw_box(win, title, self.color(1))
            body_width = max(10, box_w - 4)
            row = 2
            for line in self.wrap_block(intro, body_width):
                if row >= box_h - 4:
                    break
                self.safe_add(win, row, 2, line, self.color(3))
                row += 1
            row += 1
            for idx, (label, _) in enumerate(options):
                attr = self.color(2) | curses.A_BOLD if idx == selected else self.color(3)
                self.safe_add(win, row + idx * 2, 4, label, attr)
            win.refresh()
            key = self.stdscr.getch()
            if key in (ord("q"), 27):
                return None
            if key in (curses.KEY_UP, ord("k")):
                selected = (selected - 1) % len(options)
            elif key in (curses.KEY_DOWN, ord("j")):
                selected = (selected + 1) % len(options)
            elif key in (10, 13, curses.KEY_ENTER):
                return selected

    def popup_text(self, title: str, text: str) -> None:
        lines = text.splitlines() or [""]
        offset = 0
        while True:
            max_y, max_x = self.stdscr.getmaxyx()
            box_h = min(max_y - 4, 30)
            box_w = min(max_x - 6, 110)
            start_y = (max_y - box_h) // 2
            start_x = (max_x - box_w) // 2
            win = curses.newwin(box_h, box_w, start_y, start_x)
            self.draw_box(win, title, self.color(5))
            visible = box_h - 4
            body_width = max(10, box_w - 4)
            for row in range(visible):
                idx = offset + row
                if idx >= len(lines):
                    break
                rendered = self.wrap_block(lines[idx], body_width)
                if rendered:
                    self.safe_add(win, 2 + row, 2, rendered[0], self.color(3))
            hint = " j/k scroll | PgUp/PgDn fast | q close "
            self.safe_add(win, box_h - 2, 2, hint, self.color(1) | curses.A_BOLD)
            win.refresh()
            key = self.stdscr.getch()
            if key in (ord("q"), 27, 10, 13, curses.KEY_ENTER):
                return
            if key in (curses.KEY_UP, ord("k")):
                offset = max(0, offset - 1)
            elif key in (curses.KEY_DOWN, ord("j")):
                offset = min(max(0, len(lines) - visible), offset + 1)
            elif key == curses.KEY_PPAGE:
                offset = max(0, offset - visible)
            elif key == curses.KEY_NPAGE:
                offset = min(max(0, len(lines) - visible), offset + visible)
            elif key == curses.KEY_HOME:
                offset = 0
            elif key == curses.KEY_END:
                offset = max(0, len(lines) - visible)

    def confirm(self, title: str, message: str) -> bool:
        choice = self.popup_menu(title, message, [("Proceed", "yes"), ("Abort", "no")])
        return choice == 0

    def suspend_for_local_console(self, args: Sequence[str], banner: str) -> None:
        curses.def_prog_mode()
        curses.endwin()
        try:
            print("=" * 72)
            print("[TNO LOCAL CONSOLE]")
            print(banner)
            print(f"Command: {' '.join(shlex.quote(part) for part in args)}")
            print("=" * 72)
            subprocess.run(args)
            input("\n[TNO LOCAL CONSOLE] Press Enter to return to command room...")
        finally:
            curses.reset_prog_mode()
            self.stdscr.refresh()
            curses.curs_set(0)
            self.refresh_state()

    def build_dossier_text(self, command_output: str) -> str:
        return "\n".join([
            "XRAY DEPLOYMENT DOSSIER",
            "",
            command_output or "No deployment information was returned.",
        ])

    def service_menu(self) -> None:
        service_name = self.state["service_name"]
        if service_name == "-":
            self.popup_text("SERVICE", "No active service was detected from local deployment metadata.")
            return

        choice = self.popup_menu(
            "SERVICE COMMAND",
            f"Target unit: {service_name}\nChoose the command to issue.",
            [
                (":status  Inspect systemd status", "status"),
                (":start   Start service", "start"),
                (":restart Restart service", "restart"),
                (":stop    Stop service", "stop"),
                (":back    Return", "back"),
            ],
        )
        if choice is None or choice == 4:
            return

        action = ["status", "start", "restart", "stop"][choice]
        if action == "status":
            _, output = self.run_capture(["systemctl", "status", service_name, "--no-pager"])
            self.log(f"Loaded systemd status for {service_name}.")
            self.popup_text("SERVICE STATUS", output or f"No status text returned for {service_name}.")
            return

        code, output = self.run_capture(["systemctl", action, service_name])
        self.refresh_state()
        if code == 0:
            self.log(f"Service command succeeded: {action} {service_name}.")
            self.popup_text("SERVICE COMMAND", f"Command completed successfully.\n\n{action} {service_name}")
        else:
            self.log(f"Service command failed: {action} {service_name}.")
            self.popup_text("SERVICE COMMAND", output or f"Command failed: {action} {service_name}")

    def maintenance_menu(self) -> None:
        choice = self.popup_menu(
            "MAINTENANCE",
            "Choose the local maintenance order to execute.",
            [
                (":update-core  Refresh xray-core from upstream release", "update"),
                (":uninstall    Remove deployed services and configs", "uninstall"),
                (":back         Return", "back"),
            ],
        )
        if choice is None or choice == 2:
            return
        if choice == 0:
            if self.confirm("UPDATE CORE", "This will run the local update-core flow on this host."):
                self.suspend_for_local_console(
                    ["bash", CORE_SCRIPT, "update-core"],
                    "Updating xray-core through the stable local script.",
                )
                self.log("Update-core command completed and control returned to TNO UI.")
            return
        if self.confirm("UNINSTALL", "This will enter the local uninstall flow for this host."):
            self.suspend_for_local_console(
                ["bash", CORE_SCRIPT, "uninstall"],
                "Entering local uninstall flow through the stable script.",
            )
            self.log("Uninstall flow returned to TNO UI.")

    def execute_selected(self) -> None:
        item_id = NAV_ITEMS[self.selected_index]["id"]
        if item_id == "overview":
            self.popup_text("STRATEGIC OVERVIEW", "\n".join(self.build_overview_lines()))
            return
        if item_id == "deploy":
            if self.confirm(
                "DEPLOYMENT CONSOLE",
                "The TUI will temporarily yield the terminal to the stable local installer. Continue?",
            ):
                self.suspend_for_local_console(
                    ["bash", CORE_SCRIPT, "install"],
                    "Switching to the local deployment console. No browser will be used.",
                )
                self.log("Deployment console exited back to TNO UI.")
            return
        if item_id == "dossier":
            code, output = self.run_core_capture("show")
            dossier = self.build_dossier_text(output)
            self.last_dossier = dossier
            if code == 0:
                self.log("Deployment dossier captured from local script.")
            else:
                self.log("Deployment dossier request returned a non-zero status.")
            self.popup_text("DEPLOYMENT DOSSIER", dossier)
            return
        if item_id == "service":
            self.service_menu()
            return
        if item_id == "maintenance":
            self.maintenance_menu()
            return
        if item_id == "briefing":
            self.popup_text("BRIEFING", self.build_briefing_text())
            return
        self.running = False

    def draw_screen(self) -> None:
        max_y, max_x = self.stdscr.getmaxyx()
        if max_y < 28 or max_x < 100:
            self.stdscr.erase()
            warning = [
                "Terminal too small for TNO interface.",
                "Required: at least 100x28.",
                f"Current: {max_x}x{max_y}.",
                "Resize the terminal, then press r.",
                "Press q to quit.",
            ]
            for idx, line in enumerate(warning, start=2):
                self.safe_add(self.stdscr, idx, 2, line, self.color(4) | curses.A_BOLD)
            self.stdscr.refresh()
            return

        header_h = 1
        footer_h = 1
        logs_h = 9
        nav_w = 30
        main_h = max_y - header_h - footer_h - logs_h
        main_w = max_x - nav_w

        header = self.stdscr.derwin(header_h, max_x, 0, 0)
        nav = self.stdscr.derwin(main_h, nav_w, header_h, 0)
        main = self.stdscr.derwin(main_h, main_w, header_h, nav_w)
        logs = self.stdscr.derwin(logs_h, max_x, header_h + main_h, 0)
        footer = self.stdscr.derwin(footer_h, max_x, max_y - footer_h, 0)

        self.draw_header(header)
        self.draw_nav(nav)
        self.draw_main(main)
        self.draw_logs(logs)
        self.draw_footer(footer)

        header.noutrefresh()
        nav.noutrefresh()
        main.noutrefresh()
        logs.noutrefresh()
        footer.noutrefresh()
        curses.doupdate()

    def mainloop(self, stdscr: curses.window) -> None:
        self.stdscr = stdscr
        curses.curs_set(0)
        stdscr.keypad(True)
        self.init_colors()

        while self.running:
            self.draw_screen()
            key = stdscr.getch()
            if key in (ord("q"),):
                self.running = False
            elif key in (curses.KEY_UP, ord("k")):
                self.selected_index = (self.selected_index - 1) % len(NAV_ITEMS)
            elif key in (curses.KEY_DOWN, ord("j")):
                self.selected_index = (self.selected_index + 1) % len(NAV_ITEMS)
            elif key in (10, 13, curses.KEY_ENTER):
                self.execute_selected()
            elif key in (ord("r"), ord("R")):
                self.refresh_state()
            elif key in (ord("s"), ord("S")):
                self.selected_index = 3
                self.execute_selected()
            elif key in (ord("d"), ord("D")):
                self.selected_index = 1
                self.execute_selected()
            elif key in (ord("i"), ord("I")):
                self.selected_index = 2
                self.execute_selected()


def usage() -> None:
    print(
        "用法:\n"
        "  python3 deploy_vless_xhttp_tno.py      进入本地 TNO 风格终端 GUI\n"
        "  python3 deploy_vless_xhttp_tno.py --help\n\n"
        "说明:\n"
        "- 这是一个本地 curses TUI，不会启动网页服务\n"
        "- 默认复用同目录的 deploy_vless_xhttp.sh 作为底层执行核心\n"
        "- 可用 XRAY_CORE_SCRIPT 覆盖核心脚本路径\n"
    )


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] in {"-h", "--help", "help"}:
        usage()
        return 0
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        print("当前环境不是交互式终端，无法启动 curses TUI。", file=sys.stderr)
        return 1
    app = TNOApp()
    curses.wrapper(app.mainloop)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
