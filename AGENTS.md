# AGENTS.md · net-warp

> 本地 AI 会话规则页（gitignore，不入库）。**只放指针 + 项目专属项**——通用规则在两个 skill 里各存一份，此处不复制。

## 通用规则（单一真源在 skill）

| 主题 | 真源 |
|---|---|
| 新项目立项 / 命名 / 端口登记 / 提交规范 `type(scope): 描述` | skill `repo-discipline` |
| 长会话成本 / `收尾`·`读档`·`继续` / 《收尾 通用序列》 | skill `context-discipline` |
| 架构原理 / 用法 / 排障 / 验收标准 | `README.md` |
| 状态（进度 / 决策+理由 / 坑位 / 下一步） | `HANDOFF.md`（每次收尾重写） |

> 注：`repo-discipline` / `context-discipline` 是维护者本地的 AI 工具链 skill，贡献者没有也无妨——
> 贡献者只需遵守下方「项目红线」与 README 的提交/验收要求。

## 项目红线（改代码前必读）

1. **禁止硬编码绝对路径**：一律 `$PSScriptRoot`（ps1）/ `%~dp0`（bat/cmd）。
   唯一例外：`3-浏览器走加速.bat` 里的便携 Chrome 路径（外部工具，不随项目走）。
2. **编码**：`.ps1` = UTF-8 **with BOM** + CRLF；`.bat`/`.cmd` = CRLF + 正文纯 ASCII。
   自检：`python tools/fix-encoding.py`
3. **hosts 只准原子写**：一律 `Write-HostsAtomic`（`net-warp-common.ps1`），
   **禁止** `Set-Content` / `Out-File` / `Copy-Item` 直接写 hosts——非原子写是两次归零事故的根因。
4. **改路径/项目名后必须重注册计划任务**：`net-warp-autostart.ps1 off` → 搬 → `on`。
   任务 Action 存绝对路径快照。
5. **常驻任务执行时限必须显式 `PT0S`**（默认 PT72H，桥跑满 3 天会被强杀不重启）。
6. **WARP 固定 proxy 模式**：关闭只 `disconnect`，绝不切 TUN（改路由、卡 RDP）。
7. **bat 语法铁律**：cmd 括号块读入即 tokenize——块内未转义 `(` `)` `&` `|` `<` `>` `#` 会让整个脚本 rc=255。

## 项目对通用流程的覆盖 / 例外

- **不建 `docs/PROGRESS.md`**：项目流水由 `.workbuddy/memory/YYYY-MM-DD.md` 承担，只追加（本目录已 gitignore 不入库）。
- 本项目验证命令（收尾第 1 步用）：
  `python tools/fix-encoding.py` → `powershell -File tools\test-common.ps1`（改 hosts 逻辑时）→ `6-体检.bat`
- hosts 相关状态档案在 `docs/hosts归零-根因报告.md`。

## 交接

- 冷启动：读 `HANDOFF.md` + memory → 复述确认 → 再动手（见 context-discipline）。
- 收尾后提示主人换会话；`收尾`/`读档`/`继续` 三段循环定义见 skill，此处不复述。
