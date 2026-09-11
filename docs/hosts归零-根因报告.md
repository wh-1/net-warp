# hosts 归零 · 根因报告

> 结论日期：2026-09-11 ｜ 涉及提交：`5aa1e2c`
> 现象：系统 hosts 两次变成 **0 字节**（2026-09-10 17:14、2026-09-11 00:36）

## 一句话结论

**不是外部软件作恶，是本项目脚本自己「非原子写」。**
`Set-Content` / `Out-File` / `Copy-Item` 的语义都是**打开即截断，再逐块写** ——
写入期间进程被强制终止，文件就停在"已写入的部分"。hosts 只有几十行、写得极快，
所以一旦在开头被打断，结果就是 **0 字节**，而且看起来像"被清零"。

## 决定性实验

| 步骤 | 文件大小 |
|---|---|
| 准备一个 3,188,894 B 的文件 | 3,188,894 B |
| 启动慢速流式写入，**700ms 后杀进程** | **147 B** |
| 更早杀（截断后立即杀） | **0 B** |

→ 与事故特征完全对上：**0 字节 + CreationTime 不变（原地截断，非删除重建）+ 与备份同一秒**。

## 取证链（怎么锁定到"是我们自己写的"）

1. **CreationTime 是判据**：`hosts` 的创建时间仍是 `2022-05-07 13:24:58`（系统安装日）→ 原地截断，不是删除重建。
2. **用备份目录还原事故瞬间**：`hosts-backup/` 里
   - `hosts.bak-20260911-003639.txt` = **4615 B 健康备份**，内部 mtime 22:24:57
   - `hosts.bak-empty-20260911-013224.txt` = **0 B 事故现场**，内部 mtime 00:36:39

   两份指向同一秒 → 时序是「**先 Backup‑Hosts 成功 → 紧接着写 → 结果 0 字节**」，直接指向**写入器**，不是外部进程。
3. **读那份健康备份**：托管块之外还有 21 行微软头注释 + 主人自己的条目
   （`127.0.0.1 activate.navicat.com`、`127.0.0.1 aiot.us.ci`）
   → `Remove-ManagedBlock` 的 `$kept` 非空 → **排除关闭流程**；
   `refresh-poisoned-hosts.ps1` 的 `$kept + $block` 恒非空 → **一并排除**。
4. **用 Prefetch 还原"当时在跑什么"**（`C:\Windows\Prefetch\*.pf`）：
   `FLTMC.EXE` 00:36:14 → `warp-cli` 00:36:15 → `curl` 00:36:26 → `git-remote-https` 00:36:35。
   本项目 5 个 `.bat` 的自提权检查都是 `fltmc >nul 2>&1` → **`FLTMC.EXE` 出现 = 有人双击了 `1-开启加速.bat`**，
   后面的 `warp-cli`/`curl`/`git-remote-https` 正对应该脚本的 [4/9] 与 [8/9] 步。
   同期 00:34:04 任务管理器被打开 → 大概率是手动结束了卡住的加速窗口，正好命中 [9/9] 的写入。
5. **排除外部嫌疑**：
   - WorkBuddy 更新器 / RepairApp（00:30–01:44 确有活动）→ `%USERPROFILE%\.workbuddy\logs\update\*.log` **零 hosts 记录**
   - WorkBuddy network 诊断 → **只读** hosts
   - 火绒 → `hipsdaemon.log` 无 hosts 记录

## 修复

给 `net-warp-common.ps1` 增加 **`Write-HostsAtomic`**：

```
写同目录 .hosts.new.<guid>  →  写 .hosts.old.<guid>  →  NTFS File.Replace 原子替换  →  删 .hosts.old
```

- **原子性**：进程无论何时被杀，hosts 要么是旧内容、要么是完整新内容，**没有 0 字节中间态**
- **保留元数据**：`ReplaceFile` 保留目标原有 ACL / CreationTime / 属性
- **自带护栏**：payload 为空 → 直接 `throw`，不写；写后校验 0 字节
- **残留清理**：自动清掉超过 1 小时的 `.hosts.new.*` / `.hosts.old.*`

替换掉全部 4 处非原子写：`Remove-ManagedBlock`、`Restore-HostsFromLatest`（原用 `Copy-Item`）、
`net-warp-on.ps1` [2/9]、`refresh-poisoned-hosts.ps1` [2/3]。
另修：`Backup-Hosts` 与 `on.ps1` [2/9] 的空判定改用 `Test-HostsEffectivelyEmpty`（原用 `Get-Item.Length`，有缓存陷阱）。

`6-体检.bat` 第 4 段新增**原子写自检**，防将来回归。

## 验证结果

隔离测试（假 hosts，`.workbuddy/test-common.ps1`）—— **全绿**：

| 用例 | 结果 |
|---|---|
| D 正常写 | `write mode = ReplaceFile`，CreationTime 保留 ✓，无残留临时文件 |
| E 空 payload | 被拒 ✓，文件**未**被清零 ✓ |
| F 只剩托管块时移除块（历史毁灭路径） | 被拒 ✓，文件**未**被清零 ✓ |
| G 含空行的正常写入 | 成功 ✓，内容往返一致 |

真机端到端（跑真实 `refresh-poisoned-hosts.ps1`）：

```
sha256 changed = True          （确实写入）
CreationTime   = 2022-05-07 13:24:58  preserved = True
ACL            unchanged = True
用户条目 navicat / aiot 保留 = True      托管块 Start/End = True
etc 目录残留临时文件 = 0
```

全链路验收：

```
git ls-remote github          : 40 位 SHA ✓
40000 -> google.com           : 302 / 0.63s ✓   （修复前是 000 / 5.01s）
7890  -> youtube.com          : 200 ✓
7890  -> baidu.com            : 200 / 0.089s ✓  （直连分流）
```

## 留给以后的四条 PowerShell 陷阱

| 坑 | 现象 | 修法 |
|---|---|---|
| `File.Replace($tmp,$dst,$null)` | "路径的形式不合法" | 第 3 参数给**真实路径** |
| `File.Replace($tmp,$dst,[NullString]::Value)` | "在活动的激活上下文中找不到任何查找密钥" | 同上；两种写法都**静默退化**到非原子分支 |
| `[string[]]$Value` 只加 `[AllowEmptyCollection()]` | hosts 里的空行导致正常写入被拒 | 再补 `[AllowEmptyString()]` |
| `GetCreationTimeUtc` + `SetCreationTimeUtc` 配对 | 创建时间偏移 **+8h** | PS 会隐性转本地时间 → 同一对 API 别混用 Utc/Local |

## 还没做的（可选）

- 观察一段时间 `logs/hosts-guard.log`：原子写生效后应长期为空、且不再产生新的 `hosts.bak-empty-*.txt`。
- `net-warp-hosts-guard.ps1` 自身的日志写入仍是 `Set-Content` 截尾 —— 最坏只是丢日志，风险低，可后续一并原子化。
