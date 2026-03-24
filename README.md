# Xray VLESS XHTTP Multimode Deploy

一个面向 Debian/Ubuntu VPS 的一键部署脚本，基于 `xray-core` 当前源码能力整理，支持多种 `VLESS + XHTTP` 场景。

脚本文件:

- `deploy_vless_xhttp.sh`

支持模式:

1. 单 VPS: `VLESS + XHTTP + REALITY`
2. `IPv6` 上行 + `IPv4` 下行: 同一 VPS 后端
3. `VPS1` 上行 + `VPS2` 下行: 当前机器部署 `VPS2` 后端
4. `VPS1` 上行 + `VPS2` 下行: 当前机器部署 `VPS1` 上传代理
5. `CDN` 上行 + `VPS` 下行: `TLS + XHTTP`

特点:

- 交互式菜单
- 自定义端口
- 自定义 `SNI`
- 自定义 `XHTTP path`
- 自动生成基础 `vless://` 分享链接
- 对分离上下行模式额外生成:
  - `client_split_patch.json`
  - `client_outbound.json`
  - `client_readme.txt`

使用:

```bash
sudo bash deploy_vless_xhttp.sh
```

或:

```bash
sudo bash deploy_vless_xhttp.sh install
```

注意:

- 普通单机模式可以直接导入 `vless://` 链接。
- 分离上下行模式通常不能只靠纯 `vless://` 链接使用，客户端需要支持高级 JSON / 自定义 outbound。
- 双 VPS 模式请先部署 `VPS2` 后端，再部署 `VPS1` 上传代理。
