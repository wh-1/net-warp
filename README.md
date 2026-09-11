<div align="center">

# net-warp

**Windows 上一键加速 GitHub / Google / YouTube —— Cloudflare WARP proxy 模式 + 本地智能分流桥**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)
![Go](https://img.shields.io/badge/Go-1.21%2B-00ADD8?logo=go&logoColor=white)

</div>

> **设计前提**：本机经常被远程桌面（RDP）接入，因此全程使用 WARP 的 **proxy 模式**，
> 绝不使用 TUN 模式（TUN 会改默认路由，卡死 RDP）。局域网与远程桌面流量零影响。

## ✨ 特性

- **一键开关** —— 双击 bat 即可，无需研究代理配置
- **智能分流** —— 自研 Go 桥内置国内域名白名单，国内直连（0.1s 级）、国外走 WARP 隧道
- **DoH 本地解析 + IPv4 优先** —— 绕开 DNS 污染与运营商伪造的 AAAA 记录
- **hosts 三层防护** —— 原子写（进程被杀也不会写坏）+ 每 10 分钟自愈 + 写入者审计追因
- **开机自启** —— 3 个计划任务，最高权限无 UAC 弹窗，失败自动重启
- **访问日志** —— 按天记录每个请求（目标 / 直连 or 代理 / 上下行流量 / 耗时），可做用量分析

## 🏗 架构

```
                    +----------------------------------+
   便携 Chrome -------> |  net-warp-bridge  127.0.0.1:7890  | ----+
   (国外站)         |  DoH 解析 · IPv4 优先 · 智能分流     |     |
                    +----------------------------------+     |
   git (github/gist)                                      v
   curl -------------------------------------------> WARP SOCKS5 127.0.0.1:40000
                                                          |
   日常 Edge（直连，不碰代理）--------------------------> 国内站 / 办公
```

国内域名由桥的白名单判定后**直连出网**（不进隧道），其余经 WARP SOCKS5 出国。
`git` 与浏览器流量统一过桥，全部请求记录在 `logs/net-warp-bridge-access-YYYY-MM-DD.log`。

## 🚀 快速开始

**前置条件**：Windows 10/11、[Cloudflare WARP 客户端](https://one.one.one.one/)、Go 1.21+（仅编译桥时需要）

```bat
git clone https://github.com/wh-1/net-warp.git
cd net-warp
cd net-warp-bridge && go build -trimpath -ldflags "-s -w -H=windowsgui" -o ../net-warp-bridge.exe . && cd ..
1-开启加速.bat
```

注册开机自启（可选）：

```bat
4-开机自启-开关.bat
```

## 📦 全部命令

| 脚本 | 作用 |
|---|---|
| `1-开启加速.bat` | 一键开启：清劫持 → WARP proxy → 起桥 → 配 git → 冒烟 → 刷污染域名 |
| `2-关闭加速.bat` | 一键关闭（断开 WARP，还原 git 代理） |
| `3-浏览器走加速.bat` | 打开走桥的浏览器窗口（国内站仍直连） |
| `4-开机自启-开关.bat` | 注册 / 查看 / 移除登录自启 |
| `5-刷新被污染域名.bat` | 经 WARP 查 DoH，刷新 hosts 双栈固定记录 |
| `6-体检.bat` | 全链路体检（排障第一步，只读，发现 hosts 异常会自动修复） |

## 🔧 排障

**第一步永远是 `6-体检.bat`**——WARP 状态 / 双端口 / git 代理 / hosts 完整性 / 三层连通性 / 计划任务设置，一次查完。

| 症状 | 多半是 | 处理 |
|---|---|---|
| `curl --socks5-hostname 127.0.0.1:40000 https://www.google.com/` 卡 5s 返回 000 | hosts 被清空（污染 AAAA 胜出） | 多半已被自愈守护修好；跑体检确认 |
| 浏览器和 git 全不通，体检里「WARP 40000 上游直测」却通 | 桥挂了（7890 未监听） | `powershell -File net-warp-autostart.ps1 restart` |
| 浏览器和 git 全不通，「上游直测」也 FAIL | WARP 掉线 / hosts 被清空 | 重新跑 `1-开启加速.bat` |

更多细节（hosts 原子写防清空的完整取证）见 [docs/hosts归零-根因报告.md](docs/hosts归零-根因报告.md)。

## ⚠️ 已知限制

- 国内直连白名单为**静态后缀表**（`net-warp-bridge/main.go` 的 `directSuffixes`），白名单外的小众国内站会绕道国外
- hosts 托管块按 **A + AAAA 双栈**固定：只写 A 记录无效（伪造的 AAAA 仍会胜出）
- 桥是单点：挂了浏览器退回裸 SOCKS5（个别域名会失败），由计划任务失败重启兜底

## 📄 License

[MIT](LICENSE)
