# Xray VLESS XHTTP Multimode Deploy

一个面向 Debian/Ubuntu VPS 的传统终端一键部署脚本，支持多种 `VLESS + XHTTP` 场景。

脚本文件:

- `deploy_vless_xhttp.sh`: 主脚本，纯文本菜单交互
- `deploy_vless_xhttp_console.sh`: 兼容入口，内部转发到主脚本

支持模式:

1. 单 VPS: `VLESS + XHTTP + REALITY`
2. `IPv6` 上行 + `IPv4` 下行: 同一 VPS 后端
3. `VPS1` 上行 + `VPS2` 下行: 当前机器部署 `VPS2` 后端
4. `VPS1` 上行 + `VPS2` 下行: 当前机器部署 `VPS1` 上传代理
5. `CDN` 上行 + `VPS` 下行: `TLS + XHTTP`

特点:

- 传统终端菜单
- 自定义端口
- 自定义 `SNI`
- 自定义 `XHTTP path`
- 自动生成基础 `vless://` 分享链接
- 分离上下行模式额外生成:
  - `client_split_patch.json`
  - `client_outbound.json`
  - `client_readme.txt`

使用:

```bash
wget -O deploy_vless_xhttp.sh https://raw.githubusercontent.com/jantian3n/xray-vless-xhttp-multimode-installer/main/deploy_vless_xhttp.sh
chmod +x deploy_vless_xhttp.sh
sudo bash deploy_vless_xhttp.sh
```

也可以直接进入安装向导:

```bash
sudo bash deploy_vless_xhttp.sh install
```

常用子命令:

```bash
sudo bash deploy_vless_xhttp.sh show
sudo bash deploy_vless_xhttp.sh service
sudo bash deploy_vless_xhttp.sh update-core
sudo bash deploy_vless_xhttp.sh uninstall
```

说明:

- 现在仓库只保留传统终端交互，不再提供 GUI / TUI / `XRAY_GUI_*` 环境变量入口。
- 如果旧用法里调用了 `deploy_vless_xhttp_console.sh`，它会自动转发到 `deploy_vless_xhttp.sh`。
- 普通单机模式可以直接导入 `vless://` 链接。
- 分离上下行模式通常不能只靠纯 `vless://` 链接使用，客户端需要支持高级 JSON / 自定义 outbound。
- 双 VPS 模式请先部署 `VPS2` 后端，再部署 `VPS1` 上传代理。
