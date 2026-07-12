# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

X-MILI 是基于 [3X-UI](https://github.com/MHSanaei/3x-ui) 精简改造的 Xray 管理面板，Go module 仍为 `github.com/mhsanaei/3x-ui/v2`。在 3X-UI 能力之上，重点增加了：

- VPNGate / OpenVPN 公益节点出站（出站标签固定为 `vpngate`）
- Cloudflare WARP 出站管理与自动修复
- 中文运维菜单快捷命令 `ml`（脚本层，不是 Go 子命令）

面板不默认接管全部流量：`vpngate` 只有在 Xray 路由规则中被手动选中时才会生效。

当前版本见 `config/version`（构建时嵌入）；应用名见 `config/name`（默认 `x-ui`，影响数据库文件名）。

## 常用命令

### 本地构建与运行

```bash
# 需要 CGO（sqlite）
CGO_ENABLED=1 go build -ldflags "-w -s" -o build/x-ui main.go

# 下载 Xray 二进制与 geo 数据到 build/bin（参数为架构：amd64 / arm64 / arm32 等）
./DockerInit.sh amd64

# 直接运行面板（无子命令时默认启动 web + sub server）
./build/x-ui
# 或
go run main.go
go run main.go run
```

本地开发环境变量参考 `.env.example`：

```bash
XUI_DEBUG=true
XUI_DB_FOLDER=x-ui
XUI_LOG_FOLDER=x-ui
XUI_BIN_FOLDER=x-ui   # 或指向含 xray 二进制的 bin 目录
```

`XUI_DEBUG=true` 时 Gin 走 Debug 模式，并从磁盘加载 `web/html` / `web/assets`（便于改前端模板和静态资源）；生产构建使用 `//go:embed` 打包。

### 测试

```bash
# 全部测试
go test ./...

# 单包
go test ./web/service/
go test ./web/controller/
go test ./web/job/
go test ./database/model/

# 单个测试
go test ./web/service/ -run TestVPNGate
go test ./web/service/ -run TestWarp
go test ./web/controller/ -run TestXraySetting
```

仓库没有独立 lint / Makefile；以 `go test` 与 `go build` 为主。CI（`.github/workflows/prebuilt-linux.yml`）在 `main` 推送时用 `golang:1.26.2-bookworm` 构建 linux/amd64 预编译包并发布到 `latest` release。

### Docker

```bash
docker compose build
docker compose up -d
```

Docker 版刻意使用 `network_mode: host`、`NET_ADMIN`、`/dev/net/tun`，以支持 Xray / WARP / VPNGate；数据卷默认挂到 `/etc/x-ui`。

### 面板 CLI（Go 二进制）

```bash
./x-ui -v
./x-ui run
./x-ui migrate
./x-ui setting -show
./x-ui setting -port 2053 -username admin -password '***' -webBasePath /secret/
./x-ui setting -reset
./x-ui setting -resetTwoFactor
./x-ui setting -webCert /path/cert.pem -webCertKey /path/key.pem
./x-ui setting -getCert
./x-ui setting -getListen
```

### 运维菜单 `ml` / `x-ui.sh`

安装后提供 `ml` 快捷键（Docker 镜像里 `x-ui.sh` 同时装为 `/usr/bin/ml`）：

```bash
ml                  # 交互菜单
ml start|stop|restart|restart-xray|status|log|update|uninstall
# Docker 额外：ml shell
# 宿主机额外：ml settings
```

一键安装脚本：`install.sh`（systemd 宿主机）、`install-docker.sh`（Compose）。

## 高层架构

```
main.go
  ├─ database (SQLite + GORM)          # /etc/x-ui/x-ui.db 或 XUI_DB_FOLDER
  ├─ web.Server                         # 管理面板 HTTP(S) + 后台 cron
  │    ├─ controller                    # Gin 路由 / 页面
  │    ├─ service                       # 业务逻辑
  │    ├─ job                           # 定时任务
  │    ├─ websocket                     # 实时推送
  │    └─ html + assets + translation   # 服务端渲染 UI（Vue 2 + Ant Design Vue，非 SPA 构建）
  ├─ sub.Server                         # 独立订阅 HTTP(S) 服务
  └─ xray.Process                       # 子进程管理 Xray-core + gRPC Stats/Handler API
```

### 进程与信号

- 无参数或 `run`：初始化日志 → 加载 `.env` → 打开 DB → 启动 `web.Server` 与 `sub.Server`。
- `SIGHUP`：热重启 web + sub。
- `SIGUSR1`：仅重启 Xray。
- 其他终止信号：优雅 Stop。

### 路由分层

- 页面（需登录）：`{basePath}/panel/`、`/panel/inbounds`、`/panel/settings`、`/panel/xray`、`/panel/recommend`
- API（未登录返回 404 隐藏端点）：`{basePath}/panel/api/inbounds`、`/panel/api/server`、`/panel/api/custom-geo`
- Xray 配置 API：`{basePath}/panel/xray/*`（含 `/warp/:action`、`/vpngate/list`、`/vpngate/:action`、`/testOutbound`、`/update`）
- WebSocket：`{basePath}/ws`
- 旧路径 `/xui` 由 middleware 重定向到 `/panel`

前端是嵌入式 HTML 模板 + 静态 JS 模型（`web/assets/js/model/*`），不是 npm/webpack 工程。

### 数据与配置

| 用途 | 默认路径 | 环境变量覆盖 |
| --- | --- | --- |
| SQLite DB | `/etc/x-ui/x-ui.db`（Windows 为可执行文件目录） | `XUI_DB_FOLDER` |
| Xray 二进制 / config / geo | `bin/` | `XUI_BIN_FOLDER` |
| 日志 | `/var/log/x-ui` | `XUI_LOG_FOLDER` |
| 日志级别 | info | `XUI_LOG_LEVEL` / `XUI_DEBUG` |

核心模型：`User`、`Inbound`（含客户端 JSON settings）、`OutboundTraffics`、`Setting`（KV）、`ClientTraffic`、`CustomGeoResource`。入站协议与 Xray 配置通过 `model.Inbound.GenXrayInboundConfig()` 与 `web/service/xray*.go` 组装；默认 Xray 模板在 `web/service/config.json`。

### Xray 管理

`web/service/xray.go` 持有全局 `xray.Process`：根据 DB 入站 + 模板出站/路由/DNS 生成配置，写入 `bin/config.json` 后拉起 `xray-{os}-{arch}`。流量与在线客户端通过 Xray gRPC API 拉取；`job/xray_traffic_job.go` 每 10s 统计，`check_xray_running_job` 每秒巡检，`IsNeedRestartAndSetFalse` 合并重启请求。

### X-MILI 特色：VPNGate / OpenVPN

代码主要在 `web/service/vpngate*.go` 与 `web/service/openvpn.go`：

1. `VPNGateFetcher` 拉取 `https://www.vpngate.net/api/iphone/`，校验、按延迟/会话数排序，缓存约 5 分钟，最多 100 节点。
2. `OpenVPNService.StartVPNGate` 用节点 OpenVPN 配置拉起本地 openvpn，管理 tun 设备与策略路由（路由表 `10077`），产出 tag 为 `vpngate` 的 Xray 出站。
3. 规则模式：`default` / `fixed`（国家固定）等；支持失败节点 TTL、自动 failover、定时刷新（cron 每分钟检查，间隔设置默认 120 分钟，下限 15）。
4. UI：`web/html/modals/vpngate_modal.html` + `settings/xray/outbounds`；API 经 `XraySettingController`。

依赖宿主机/容器具备 TUN 与 `openvpn`；OpenVZ/LXC 常需手动开 TUN。

### WARP

`web/service/warp.go`：Cloudflare WARP 配置与连通性；cron 每 12 分钟 `CheckAndRepairWarp`。与 VPNGate 一样通过 Xray 出站体系接入，修复逻辑与出站测试（`OutboundService` / `testOutbound`）相关。

### 订阅服务

`sub/` 独立 Gin 服务，复用 web 的 embed HTML/assets 与 SettingService，按客户端 `subId` 下发订阅链接、Clash、JSON 配置（`subService` / `subClashService` / `subJsonService`）。域名与证书可与面板分开配置。

### 后台任务（`web/job`）

- Xray 存活、流量统计、客户端 IP 限制日志解析
- 日志清理（日）
- 入站流量按 hour/day/week/month 重置
- VPNGate 刷新、WARP 修复
- 启动时 `CustomGeoService.EnsureOnStartup`

### 安装与发布相关文件

- `install.sh` / `update.sh` / `x-ui.sh`：宿主机 systemd 安装与 `ml` 菜单
- `install-docker.sh`、`Dockerfile`、`DockerEntrypoint.sh`、`DockerInit.sh`：镜像构建（Go 1.26-alpine，CGO，附带 openvpn / fail2ban）
- 预编译产物：`build/x-ui` + `build/bin/xray-linux-*` + geo dat，打成 `x-mili-linux-amd64.tar.gz`
- Docker 镜像：`.github/workflows/docker-image.yml` 在 `main` 推送/标签/`workflow_dispatch` 时构建 `linux/amd64,linux/arm64` 并推送到 Docker Hub `kingxujw/x-mili`（`latest`、`config/version`、短 SHA、semver 标签）。需要仓库 Secrets：`DOCKERHUB_USERNAME`、`DOCKERHUB_TOKEN`

## 修改时注意

- **模块路径**：import 使用 `github.com/mhsanaei/3x-ui/v2/...`，与 GitHub 仓库名 `Aimilibot/X-MILI` 不同，勿随意改 module path。
- **CGO**：SQLite 驱动需要 `CGO_ENABLED=1`；Windows 本地开发需可用的 C 编译器。
- **前后端同仓**：改面板 UI 通常改 `web/html/**` 与 `web/assets/js/**`，无需 Node 构建；生产靠 embed，debug 模式才热读磁盘。
- **出站标签**：`vpngate` 为约定常量（`vpnGateOutboundTag`）；路由规则与统计按 tag 关联，改名需前后端与 OpenVPN 服务一并改。
- **Xray 模板**：设置页可能把带 wrapper 的 JSON 回写；读取时 `UnwrapXrayTemplateConfig` 会剥壳并尝试回写修复，改序列化时注意兼容。
- **权限与网络**：VPNGate/WARP 相关改动需考虑 `NET_ADMIN`、host 网络与 Linux-only 假设；Windows 上部分能力降级或不可用。
- **版本**：发版时改 `config/version`；可选写入 `build/.x-mili-commit` 影响 `GetAssetVersion()` 缓存破坏。
