#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""repo-guard —— 项目合规守卫（给任意项目用）。

在项目仓库内运行，检查《w-dev 项目规范》中**可机检**的部分。

用法
----
    python repo-guard.py                 # 全量检查（当前目录）
    python repo-guard.py D:\\w-dev\\xx\\yy  # 检查指定项目（不必 cd）
    python repo-guard.py --staged        # 提交前：额外扫 staged diff 的密钥
    python repo-guard.py --quiet         # 只输出问题项
    python repo-guard.py --all           # 批量项目体检 D:\\w-dev 全部 git 项目，出汇总
                         python repo-guard.py --version       # 打印守卫版本（核验装上的是哪一版）
                                         #   + 快照落盘 本项目 .local/体检快照/项目体检-<日期>.md
                                         #   （.local/ 永不入库 —— 体检快照是运行产物不是资产；
                                         #     同名快照已存在 → 先把旧版转存 ...-<HHMM>.md，不丢档）

退出码
------
0 = 无 FAIL（WARN 不阻断）；1 = 有 FAIL（--all 时只统计**非归档**项目）

归档判定
--------
目录名以 `_` 开头、或含 `rescue` / `superseded` → 视为待删归档：
单独列出、不阻断退出码。**整改后应删除对应行。**

与 check-drift.py 的分工
------------------------
- `check-drift.py`：**本项目自身**的漂移守卫（SKILL.md ↔ README.md ↔ new-project.ps1）
- `repo-guard.py`：**任意项目**的合规守卫（命名 / 敏感文件 / 密钥 / .gitignore）
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
from pathlib import Path

# 守卫版本：`--version` 与 CI 副本（`cmp` 比对）用。
# 与 templates/pre-commit 的 GUARD-HOOK-VERSION 是**两件事**（2026-09-25 澄清，
# 原文写「成对改」会误导）：钩子认的是本脚本的**命令行契约**（`--staged --quiet`），
# 契约不变则钩子版本无需跟动；下游按路径引用本脚本 ⇒ 仅新增/调整判据自动生效。
GUARD_SCRIPT_VERSION = "1.2.4"

try:
    import tomllib            # Python ≥ 3.11；旧解释器退回文本启发式
except ModuleNotFoundError:   # pragma: no cover
    tomllib = None

# ---------------- 规则 ----------------

NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")

BANNED_TRACKED = [
    (r"(^|/)\.env$", ".env 真实配置"),
    (r"(^|/)\.env\.local$", ".env.local"),
    (r"(^|/)node_modules/", "node_modules/"),
    (r"(^|/)\.?venv/", "虚拟环境目录"),
    (r"(^|/)__pycache__/", "__pycache__/"),
    (r"(^|/)dist/", "dist/"),
    (r"(^|/)build/", "build/"),
    (r"(^|/)target/", "target/"),
    (r"\.(db|sqlite|sqlite3)$", "数据库文件"),
    (r"\.log$", "日志文件"),
]

# 密钥规则分两路：带引号写法阈值沿用旧版（密码 6+ / 密钥 12+）；
# 无引号写法（.env / YAML / dotenv 主流）要求值像随机串（≥20 位且含数字）压误报，
# 并排除占位符（<TOKEN> / xxx / your_* / changeme / example / ${VAR}）。
# 2026-09-21：旧版前两条值部分写死 ['\"]，无引号密钥全漏。
_SECRET_PLACEHOLDER = r"(?!<)(?!xxx)(?!your[_-]?)(?!changeme)(?!example)(?!\$\{)"
# 2026-09-24：排除「值本身就是点号命名标识符」的写法 —— 如 VS Code 密钥存储的
# 键名书写成点号分隔的命名空间串（如某编辑器的密钥存储键）（键名，非密钥值），
# 实测误报 2 处（workbuddy-switch）。判据：整值是 `A.B.C` 形态的标识符路径。
_SECRET_ID_LIKE = r"(?![A-Za-z][A-Za-z0-9_-]*(?:\.[A-Za-z0-9_-]+)+['\"])"

SECRET_PATTERNS = [
    (r"(?i)\b(password|passwd)\s*[:=]\s*['\"]" + _SECRET_ID_LIKE + r"[^'\"]{6,}", "疑似硬编码密码"),
    (r"(?i)\b(api[_-]?key|secret[_-]?key|access[_-]?token)\s*[:=]\s*['\"]" + _SECRET_ID_LIKE + r"[^'\"]{12,}", "疑似硬编码密钥"),
    (r"(?i)\b(password|passwd|api[_-]?key|secret[_-]?key|access[_-]?token)\s*[:=]\s*['\"]?"
     + _SECRET_PLACEHOLDER + r"(?=[^\s'\"]*\d)[^\s'\"]{20,}",
     "疑似硬编码密码/密钥（无引号）"),
    (r"AKIA[0-9A-Z]{16}", "AWS Access Key"),
    (r"sk-[A-Za-z0-9]{20,}", "疑似 OpenAI Key"),
    (r"ghp_[A-Za-z0-9]{36}", "GitHub Personal Token"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "私钥文件内容"),
]

GITIGNORE_ESSENTIAL = [".env"]
# 第 8 项：只校验「形状」（`type(scope): 描述`），**不锁类型枚举** ——
# 8.2 的 11 类是给人/评审看的清单，项目自定义类型（`deps` / `wip`）不该被门拦下。
# `!?` = Conventional Commits 破坏性标记（`feat!:` / `feat(api)!:`，规范 8.2.1）。
COMMIT_RE = re.compile(r"^[a-z]+(\([^)]+\))?!?: .{2,}$")
COMMIT_EXEMPT_RE = re.compile(r"^(Merge |Revert )")  # 8.6 --no-ff 合并产生的自动信息，豁免格式检查

# ---- 16.1 README 门面（第 10 项机检） ----
README_MAX_LINES = 200
# 本机用户路径：C:\Users\<ascii用户名>\...（排除 <...> 占位示例）
README_LOCAL_PATH_RE = re.compile(r"(?i)C:\\Users\\(?!<)[A-Za-z][A-Za-z0-9_.-]*")
# 内网真实 IP（排除 127.0.0.1 回环）
README_PRIVATE_IP_RE = re.compile(
    r"\b(?:192\.168\.\d{1,3}\.\d{1,3}"
    r"|10\.\d{1,3}\.\d{1,3}\.\d{1,3}"
    r"|172\.(?:1[6-9]|2\d|3[01])\.\d{1,3}\.\d{1,3})\b")
# 疑似真实口令/密钥（负向前瞻排除 <TOKEN> / xxx / your_* / changeme / example 占位）
README_SECRET_RE = re.compile(
    r"(?i)\b(password|passwd|pwd|api[_-]?key|access[_-]?token|secret)\s*[:=]\s*['\"]?"
    r"(?!<)(?!xxx)(?!your[_-]?)(?!changeme)(?!example)[^\s'\"]{6,}")

ARCHIVE_RE = re.compile(r"^_|rescue|superseded", re.I)

# ---- 第 13 项 CHANGELOG 版本节（规范 12.3，2026-09-25 新增） ----
# 宽松口径：只要求「有版本节」，不锁单一形态 —— Keep a Changelog 的
# `## [Unreleased]` / `## [1.2.3] - 日期`，与按版本追加的 `## 1.38.1（日期）` 都认。
# 动机：原判据只看文件在不在 ⇒ 建个空壳 CHANGELOG.md 就能过。
CHANGELOG_SEC_RE = re.compile(
    r"^##\s+(\[Unreleased\]|\[v?\d+\.\d+\.\d+[^\]]*\]|v?\d+\.\d+\.\d+)(?![\d.])",
    re.M | re.I)

# ---- 第 18 项 BOM 污染（Windows 平台坑表 / 规范 16.1） ----
# 实测两处真害（2026-09-24 全库标定，22 个入库文件带 BOM）：
#   · `kb-obsidian/pyproject.toml` 带 BOM ⇒ tomllib 与 pytest 直接报
#     `Invalid statement (at line 1, column 1)`
#   · `net-warp/.gitignore` 首行带 BOM ⇒ 该行**不再被识别为规则 / 注释**，
#     若首行恰是忽略规则，规则会**静默失效**（安全类）
# `.ps1` / `.bat` / `.cmd` 的 BOM 是平台正确姿势（PS 5.1 读中文需要）⇒ 跳过；
# `.sln` / `.csproj` / `.xaml` / `.cs` 由 VS / MSBuild 生成时默认带 BOM，剥掉会被工具写回（2026-09-25 实测 gis 三仓）⇒ 同样跳过。
BOM = b"\xef\xbb\xbf"
BOM_PARSER_EXTS = {".toml"}                    # 解析器会直接报错
BOM_PARSER_NAMES = {"go.mod"}
BOM_SKIP_EXTS = {
    ".ps1", ".psm1", ".psd1", ".bat", ".cmd",   # Windows 脚本：PS 5.1 读中文需要 BOM
    ".sln", ".csproj", ".xaml", ".cs",          # .NET：VS / MSBuild 默认写 BOM，剥了会被工具写回
}

# ---- 第 17 项 依赖锁定文件（规范 17.2） ----
# 判据细化过的两类「不算缺失」（全库标定把 9 处误报压到 0）：
#   · 空骨架：清单里 0 依赖（模板仓 / 纯 stdlib）不要求锁定文件
#   · `requirements.txt` 已用 `==` 全钉：等价于锁定
LOCK_ACCEPT = {
    "package.json": (("pnpm-lock.yaml", "package-lock.json", "yarn.lock", "bun.lockb"),
                     "建议 `pnpm install` 生成 `pnpm-lock.yaml`"),
    "pyproject.toml": (("poetry.lock", "uv.lock", "Pipfile.lock", "pdm.lock"),
                       "建议 `poetry lock` / `uv lock`"),
    "Cargo.toml": (("Cargo.lock",), "`Cargo.toml` 有依赖但无 `Cargo.lock`"),
}

SELF_ROOT = Path(__file__).resolve().parents[1]   # repo-discipline 本体
W_DEV = SELF_ROOT.parents[1]                      # D:\w-dev

# 顶层准入白名单（README §二「顶层准入清单」2026-09-24 定稿）
# 顶层只允许这 12 个领域目录 + `_archive\`；**新增领域时与本次一并改**（README 同步点）。
DOMAIN_ALLOW = {"stock", "ai", "gis", "common", "wb", "net",
                "github", "remote", "kb", "sys", "ide", "iot"}

fails: list[str] = []
warns: list[str] = []
ignores: set[str] = set()


def load_ignores(root: Path) -> set[str]:
    """读取 `.repo-guard-ignore`：每行一个被豁免的检查项（`#` 开头为注释）。

    用于**存量项目过渡期** —— 既成事实的违规（如历史项目名）可先豁免，
    避免「门一挂就被绕过」（人一旦习惯 `--no-verify`，门就废了）。
    **整改后应删除对应行。**

    两种粒度：
      · 裸项名         = 整个检查项豁免（如 `README ≤ 200 行`）
      · `项名: 路径`   = 只豁免该项下的**某个具体对象**（如 `领域目录准入: ide/ide-vscode`）
        路径粒度是为第 24 项这类**全局遍历型检查**准备的 —— 它一次扫所有领域目录，
        没路径粒度就只能整项豁免（等于关掉整个检查），代价太大。
    """
    f = root / ".repo-guard-ignore"
    if not f.exists():
        return set()
    return {ln.strip() for ln in f.read_text(encoding="utf-8", errors="replace").splitlines()
            if ln.strip() and not ln.startswith("#")}


def _scoped_ignores(prefix: str, root: Path) -> set[str]:
    """取「`前缀: 路径`」形态的豁免路径集合（用于全局遍历型检查按对象豁免）。"""
    out: set[str] = set()
    for ln in load_ignores(root):
        if ":" in ln:
            k, v = ln.split(":", 1)
            if k.strip() == prefix:
                out.add(v.strip().replace("\\", "/"))
    return out


# ---------------- 第 20 / 21 项规则（2026-09-25 新增） ----------------

# 钩子版本标记（模板与下发副本都带；双门 / 自定义门没有 ⇒ 跳过不误报）
HOOK_VER_RE = re.compile(r"GUARD-HOOK-VERSION[:= ]+([0-9]+\.[0-9]+\.[0-9]+)")
# 已入库单文件告警阈值（MB）——**观察级**：先提示，不阻断
BIG_FILE_MB = 50
# 上游（repo-discipline 本体）定位：换机器时用环境变量覆盖
UPSTREAM_ENV = "REPO_DISCIPLINE_HOME"


def _upstream_root() -> "Path | None":
    """定位 repo-discipline 本体（下发物的上游），找不到返回 None。

    下游副本与上游逐字节比对才知道「模板改了但项目没跟上」。
    上游不可达（换机器 / 路径变了）时**整项不判** —— 制造噪声比漏报更伤。
    """
    cands: list[Path] = []
    env = os.environ.get(UPSTREAM_ENV)
    if env:
        cands.append(Path(env))
    cands.append(W_DEV / "common" / "repo-discipline")
    for c in cands:
        if (c / "scripts" / "repo-guard.py").is_file() and (c / "templates").is_dir():
            return c
    return None


def _lint_state(root: Path) -> "tuple[str | None, bool, str]":
    """返回 (语言, 是否有 lint/格式配置, 建议)。

    只判**有明确配置文件**的语言：Rust(clippy)/Java(checkstyle 由构建带)/C# 由工具链自带，
    缺文件不等于没规范 ⇒ 返回 `None` 表示不判，避免制造噪声。
    """
    if (root / "pyproject.toml").is_file() or (root / "requirements.txt").is_file():
        has = (root / "ruff.toml").is_file() or (root / ".ruff.toml").is_file()
        if not has and (root / "pyproject.toml").is_file():
            try:
                has = b"[tool.ruff" in (root / "pyproject.toml").read_bytes()
            except OSError:
                has = False
        return "python", has, "ruff 配置（`pyproject.toml` 的 `[tool.ruff]` 或 `ruff.toml`）"
    if (root / "Cargo.toml").is_file():
        # Rust：fmt / clippy 由工具链自带，缺文件 ≠ 没规范 ⇒ 不判。
        # （Rust + 前端壳的项目带 package.json，不先判会把它误判成 node 要求 eslint）
        return None, True, ""
    if (root / "package.json").is_file():
        has = bool(list(root.glob(".eslintrc*")) or list(root.glob("eslint.config.*")))
        if not has:
            try:
                has = b'"eslint"' in (root / "package.json").read_bytes()
            except OSError:
                has = False
        return "node", has, "eslint 配置（`.eslintrc*` / `eslint.config.*`）"
    if (root / "go.mod").is_file():
        return "go", bool(list(root.glob(".golangci.*"))), "`.golangci.*`（`go vet` 内置，不算配置）"
    return None, True, ""


def _big_tracked(root: Path, mb: int) -> "list[tuple[float, str]]":
    """已入库且 > mb MB 的 [(size_mb, path)]。

    取 **blob 大小**而非工作区大小：工作区的大文件可能已被 .gitignore 挡住（未入库），
    那不算违规；只有真进库的才占 clone 体积。用 `cat-file --batch-check` 一次批量取，
    避免逐文件 spawn。
    """
    out = git("ls-files", "-s", cwd=root)
    if not out:
        return []
    shas: list[str] = []
    paths: list[str] = []
    for ln in out.splitlines():
        parts = ln.split("\t", 1)
        if len(parts) != 2:
            continue
        meta = parts[0].split()
        if len(meta) < 2:
            continue
        shas.append(meta[1])
        paths.append(parts[1])
    if not shas:
        return []
    try:
        r = subprocess.run(["git", "cat-file", "--batch-check=%(objectsize)"],
                           input="\n".join(shas), cwd=str(root), capture_output=True,
                           text=True, encoding="utf-8", errors="replace")
        sizes = r.stdout.split()
    except Exception:  # noqa: BLE001 — 探测失败就当没大文件，不做判据
        return []
    big: list[tuple[float, str]] = []
    for path, s in zip(paths, sizes):
        try:
            v = int(s) / 1048576
        except ValueError:
            continue
        if v > mb:
            big.append((v, path))
    big.sort(reverse=True)
    return big


def git(*args: str, cwd: Path) -> str:
    try:
        p = subprocess.run(["git", *args], cwd=str(cwd), capture_output=True,
                           text=True, encoding="utf-8", errors="replace")
        return p.stdout.strip() if p.returncode == 0 else ""
    except FileNotFoundError:
        return ""


def is_ignored(root: Path, rel: str) -> bool:
    """用 `git check-ignore` 判定路径是否被忽略（RC=0 = 被忽略）。

    比「读 .gitignore 猜规则」可靠：走 git 自己的匹配引擎（含 .gitignore /
    .git/info/exclude / 全局 excludesfile / 父目录规则）。
    """
    try:
        p = subprocess.run(["git", "check-ignore", "-q", rel], cwd=str(root),
                           capture_output=True)
        return p.returncode == 0
    except FileNotFoundError:
        return False


def staged_added_lines(root: Path, path: str) -> list[str]:
    """取暂存区中指定文件的**新增行**（`+` 行，丢掉 `+++` 头与 hunk 元信息）。

    供 `--staged`（提交门）做增量扫描：只判本次提交**引入**的问题；
    存量违规归全量体检（`--all`）负责，避免挂门即被历史遗留拦死。
    """
    d = git("diff", "--staged", "-U0", "--", path, cwd=root)
    return [ln[1:] for ln in d.splitlines()
            if ln.startswith("+") and not ln.startswith("+++")]


# ---- 存量密钥扫描（全量模式，第 5 项的另一半） ----
# 为什么必须有：提交门（`--staged`）只拦**本次新增**的密钥，此前已入库的密钥
# 没有任何一道机检会报 —— 全量体检若也只看暂存区，等于这道防线不存在（2026-09-24 实测缺口）。
# 护栏：只扫代码 / 配置类扩展名，单文件 ≤ 512 KB，最多 4000 个文件，含 NUL 字节即判二进制跳过。
SECRET_SCAN_EXTS = {
    ".py", ".pyw", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".vue",
    ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env",
    ".txt", ".ps1", ".psm1", ".sh", ".bash", ".zsh", ".bat", ".cmd",
    ".go", ".rs", ".java", ".kt", ".cs", ".php", ".rb", ".pl", ".sql",
    ".html", ".htm", ".css", ".xml", ".properties", ".gradle", ".tf",
}
SECRET_SCAN_NAMES = {"Dockerfile", "Makefile", "makefile", "Jenkinsfile",
                     ".env.example", ".env.sample", ".gitlab-ci.yml"}
# 存量扫描（提示级）用**高信号子集**：全库实测 10 处命中**全是误报**
# （语言包里的 `password` 标签（值为单词）/ litellm 文档的 `os.environ/XXX` 环境变量引用 /
# 测试里的假串 `sk-super…` 长串）⇒ 抢答式报警会被无视，宁可少报：
#   · 引号类通用形态提高到「值 ≥20 位且含数字」；短值只管提交门（增量、人当场可见）
#   · 高信号 token 形态（AKIA / sk- / ghp_ / 私钥块）原样保留
SECRET_PATTERNS_STRONG = [
    (r"(?i)\b(password|passwd|api[_-]?key|secret[_-]?key|access[_-]?token)\s*[:=]\s*['\"]"
     + _SECRET_ID_LIKE + r"(?=[^'\"]*\d)[^'\"]{20,}", "疑似硬编码密码/密钥"),
    (r"AKIA[0-9A-Z]{16}", "AWS Access Key"),
    (r"sk-[A-Za-z0-9]{20,}", "疑似 OpenAI Key"),
    (r"ghp_[A-Za-z0-9]{36}", "GitHub Personal Token"),
    (r"-----BEGIN [A-Z ]*PRIVATE KEY-----", "私钥文件内容"),
]
# 噪声区：测试夹具 / 文档示例 / 依赖目录 —— 形似密钥的示例串密度最高
SECRET_SCAN_SKIP_DIRS = {"node_modules", "__tests__", "tests", "test", "testdata",
                         "fixtures", "samples", "examples", "docs", "doc"}
SECRET_SCAN_MAX_BYTES = 512 * 1024
SECRET_SCAN_MAX_FILES = 4000
SECRET_SCAN_MAX_HITS = 8


def scan_tracked_secrets(root: Path) -> list[str]:
    """扫**已入库文本文件**内容里的密钥（存量，返回 `文件:行号 类型` 列表）。

    只报**高信号形态**且**跳过测试 / 文档等噪声区** —— 全库标定 10 处命中全为误报，
    提示级通道一旦被误报淹没就没人看了（详见 `SECRET_PATTERNS_STRONG` 注释）。
    短值 / 引号类的完整宽度由**提交门**（`--staged`，FAIL 级）负责。
    """
    hits: list[str] = []
    scanned = 0
    for rel in git("ls-files", cwd=root).splitlines():
        p = root / rel
        if p.suffix.lower() not in SECRET_SCAN_EXTS and p.name not in SECRET_SCAN_NAMES:
            continue
        if SECRET_SCAN_SKIP_DIRS.intersection(p.parts[:-1]):
            continue
        if scanned >= SECRET_SCAN_MAX_FILES or len(hits) > SECRET_SCAN_MAX_HITS:
            break
        try:
            if not p.is_file() or p.stat().st_size > SECRET_SCAN_MAX_BYTES:
                continue
            raw = p.read_bytes()
        except OSError:
            continue
        if b"\x00" in raw:                      # 二进制（含 .pyd / 图片 / 压缩包）跳过
            continue
        scanned += 1
        for lineno, line in enumerate(raw.decode("utf-8", errors="replace").splitlines(), 1):
            for pat, label in SECRET_PATTERNS_STRONG:
                if re.search(pat, line):
                    hits.append(f"{rel}:{lineno} {label}")
                    break
            if len(hits) > SECRET_SCAN_MAX_HITS:
                break
    return hits


def _read_text_sig(root: Path, name: str) -> str:
    """读清单文件（容忍 BOM），失败返回空串。"""
    try:
        return (root / name).read_bytes().decode("utf-8-sig", errors="replace")
    except OSError:
        return ""


def _has_deps(root: Path, manifest: str) -> bool:
    """清单是否**真的声明了依赖** —— 空骨架（0 依赖）不该被要求锁定文件。"""
    raw = _read_text_sig(root, manifest)
    if manifest == "package.json":
        blocks = re.findall(r'"(?:dev)?[Dd]ependencies"\s*:\s*\{([^}]*)\}', raw)
        return any(re.search(r'"\S+"\s*:', b) for b in blocks)
    if manifest == "Cargo.toml":
        m = re.search(r"(?ms)^\[(?:workspace\.)?dependencies\]\s*$(.*?)(?=^\[|\Z)", raw)
        return bool(m and re.search(r"(?m)^\s*[\w-]+\s*=", m.group(1)))
    if manifest == "pyproject.toml":
        if tomllib is not None:
            try:
                d = tomllib.loads(raw)
            except Exception:  # noqa: BLE001 — 语法 / BOM 问题交第 18 项报
                d = None
            if d is not None:
                if d.get("project", {}).get("dependencies"):
                    return True
                pd = (d.get("tool", {}).get("poetry", {}) or {}).get("dependencies", {}) or {}
                return any(k.lower() != "python" for k in pd)
        return bool(re.search(r"(?m)^\s*dependencies\s*=\s*\[\s*[^\]]", raw))
    return False


def _reqs_pinned(root: Path) -> tuple[int, int]:
    """`requirements.txt` 的依赖条数 / 未用 `==` 钉死条数。

    `python>=3.10` 这类解释器声明、`-r` / `-e` / 点路径不算依赖条目。
    """
    deps = loose = 0
    for ln in _read_text_sig(root, "requirements.txt").splitlines():
        s = ln.split("#")[0].strip()
        if not s or s.startswith(("-", ".")):
            continue
        if re.match(r"(?i)^python\b", s):
            continue
        deps += 1
        if "==" not in s:
            loose += 1
    return deps, loose


def run_checks(root: Path, staged: bool = False, ci: bool = False) -> tuple[list[str], list[str], list[str]]:
    """对单个项目执行 23 项机检，返回 (fails, warns, lines)。不打印。

    `ci=True` = **服务端（GitHub Actions 等）全量判定**：
      - 为什么不用 `--staged`：CI 是干净检出，暂存区恒空 ⇒ `git diff --cached` 必然为空
        ⇒ 密钥扫描**假 PASS**（同一类「空态掩盖」——链路坏了与真干净的输出一模一样）。
        服务端没有「增量」概念，只能全量判。
      - 密钥项由 WARN **升为 FAIL**（CI 是最后兜底：`--no-verify` 绕掉本地门后全靠它拦）；
      - hooksPath 项**跳过**（它是 local 级 git config，不随 clone 传播，CI 上必造噪声）。
    """
    f2: list[str] = []
    w2: list[str] = []
    lines: list[str] = []

    def emit(ok: bool, label: str, detail: str = "", level: str = "FAIL",
             incremental: bool = False) -> None:
        """`incremental=True` = 该项只判「本次提交新增的部分」。

        提交门模式（`--staged`）下，属性类问题（改名 / 补文件 / 历史遗留）
        不是本次提交能改的，降为 WARN 提示而不阻断 —— 否则存量项目一挂门
        就被既成事实拦死，人一旦习惯 `--no-verify`，门就废了。
        全量体检请跑 `--all`。
        """
        if ok:
            lines.append(f"  [PASS] {label}")
            return
        if label in ignores:
            lines.append(f"  [SKIP] {label}  → 已豁免（{detail}）")
            w2.append(f"{label}（豁免中，待整改）")
            return
        if staged and not incremental and level == "FAIL":
            level = "WARN"
            detail = (detail + "；" if detail else "") + "属性类问题，提交门不阻断（全量体检跑 --all）"
        lines.append(f"  [{level}] {label}" + (f"  → {detail}" if detail else ""))
        (f2 if level == "FAIL" else w2).append(label)

    # 1) 项目名
    emit(bool(NAME_RE.match(root.name)), "项目名为全小写 kebab-case",
         f"实际 `{root.name}`（规范第 3.1 / 7 章）")

    # 2) 嵌套同名目录
    emit(not (root / root.name).exists(), "无嵌套同名目录",
         f"存在 {root.name}/{root.name}/（规范第 7 章）")

    # 2b) 同一项目内目录**不混用 `-` 与 `_`**（规范第 7 章第 2 条）
    #     只查目录名（文件名常有下划线是语言惯例，如 `test_foo.py` / `my_module.rs`）。
    #     顶层目录里 `-` 与 `_` 同时出现 = 混用信号。
    dir_names: list[str] = []
    try:
        for d in root.iterdir():
            if d.is_dir() and not d.name.startswith(".") and d.name not in (
                    "node_modules", "__pycache__", "target", "bin", "obj"):
                dir_names.append(d.name)
    except OSError:
        pass
    has_dash = any("-" in n for n in dir_names)
    has_under = any("_" in n for n in dir_names)
    mixed = [n for n in dir_names if ("-" in n or "_" in n)]
    emit(not (has_dash and has_under), "目录命名不混用 - 与 _（规范第 7 章第 2 条）",
         f"同时存在含 `-` 与含 `_` 的目录：{', '.join(sorted(mixed))}", incremental=True)

    # 3) .gitignore
    gi = root / ".gitignore"
    if gi.exists():
        text = gi.read_text(encoding="utf-8", errors="replace")
        miss = [k for k in GITIGNORE_ESSENTIAL if k not in text]
        emit(not miss, ".gitignore 含安全基线条目", f"缺 {', '.join(miss)}")
    else:
        emit(False, ".gitignore 存在", "规范第 11 章要求必须有")

    # 4) 敏感文件是否已入库（--staged 只看本次新增 / 改动 / 改名）
    if staged:
        scope = git("diff", "--staged", "--name-only", "--diff-filter=ACMR",
                    cwd=root).splitlines()
        label4 = "本次提交未带入敏感文件"
    else:
        scope = git("ls-files", cwd=root).splitlines()
        label4 = "无敏感文件入库"
    hits = []
    for f in scope:
        for pat, name in BANNED_TRACKED:
            if re.search(pat, f):
                hits.append(f"{f}（{name}）")
                break
    emit(not hits, label4,
         f"{len(hits)} 个：{'；'.join(hits[:5])}" + ("…" if len(hits) > 5 else ""),
         incremental=staged)

    # 5) 密钥扫描
    #    --staged：扫暂存区**新增行**（提交门，FAIL 阻断泄露）
    #    全量：扫**已入库文本文件内容**（存量，WARN —— 提交门管增量、全量提示存量）
    #    --ci  ：同样扫存量，但**升为 FAIL**（服务端没有「这次提交」的概念，已入库即既成事实）
    if staged:
        diff = git("diff", "--staged", "-U0", cwd=root)
        found = []
        for line in diff.splitlines():
            if not line.startswith("+") or line.startswith("+++"):
                continue
            for pat, label in SECRET_PATTERNS:
                if re.search(pat, line):
                    found.append(label)
                    break
        emit(not found, "staged diff 无密钥泄露",
             f"{', '.join(sorted(set(found)))}" if found else "",
             incremental=True)
    else:
        hits5 = scan_tracked_secrets(root)
        emit(not hits5, "已入库文件无密钥（存量扫描）",
             (f"{len(hits5)} 处（规范 10.2.1 禁止硬编码密钥）：" + "；".join(hits5[:5]) +
              ("…" if len(hits5) > 5 else "")) if hits5 else "",
             level="FAIL" if ci else "WARN")

    # 6) .env 与 .env.example 配对（WARN）
    if (root / ".env").exists():
        emit((root / ".env.example").exists(), "有 .env 则应有 .env.example",
             "缺 .env.example（规范第 10.1 章）", level="WARN")

    # 7) hooksPath（WARN）
    hp = git("config", "--get", "core.hooksPath", cwd=root)
    #    `--ci` 下跳过：`core.hooksPath` 是 **local 级 git config**，不随 clone 传播，
    #    服务端检出必然没有 ⇒ 该项在 CI 上只能恒定报 WARN，留着就是噪声。
    if not ci:
        emit(bool(hp), "已挂 core.hooksPath（提交门）",
             "未挂载，建议 `git config core.hooksPath githooks`", level="WARN")

    # 8) 最近一次提交信息格式（WARN）
    # BOM 前缀会让格式判定失败（实测 tristate-system 的 `chore(memory):` 提交带 \ufeff）
    subject = git("log", "-1", "--format=%s", cwd=root).lstrip("\ufeff")
    if subject:
        ok = bool(COMMIT_RE.match(subject) or COMMIT_EXEMPT_RE.match(subject))
        emit(ok, "最近提交符合 `type(scope): 描述`",
             f"实际 `{subject}`（规范第 8.2 章；Merge/Revert 自动信息豁免）", level="WARN")

    # 9) .editorconfig（WARN）
    emit((root / ".editorconfig").exists(), "有 .editorconfig",
         "缺（common/templates/.editorconfig 可复制）", level="WARN")

    # 13) CHANGELOG.md（12.3，FAIL 级）：① 存在 ② 含版本节（非空壳）
    #     ② 必须挂在 ① 之内判：`stock/daily_stock_analysis` 的「无 CHANGELOG」
    #     走 `.repo-guard-ignore` 豁免，若无条件判 ② 会绕过豁免直接报 FAIL。
    chlog = root / "CHANGELOG.md"
    emit(chlog.exists(), "有 CHANGELOG.md",
         "缺（12.3 变更日志；common/templates/CHANGELOG.md 骨架可复制）")
    if chlog.exists():
        emit(CHANGELOG_SEC_RE.search(_read_text_sig(root, "CHANGELOG.md")) is not None,
             "CHANGELOG 含版本节（不是空壳）",
             "只有标题、无版本节 —— 未发布阶段也应有 `## [Unreleased]`（12.3）")

    # 10) README 门面（规范 16.1，2026-09-11 新增）
    rd = root / "README.md"
    if not rd.exists() or rd.stat().st_size == 0:
        emit(False, "README.md 存在且非空", "规范第 16 章要求必须有")
    else:
        rtext = rd.read_text(encoding="utf-8", errors="replace")
        emit(True, "README.md 存在且非空")
        rlines = rtext.splitlines()
        emit(len(rlines) <= README_MAX_LINES, f"README ≤ {README_MAX_LINES} 行",
             f"实际 {len(rlines)} 行（规范 16.1；细节应进 docs/ 或 HANDOFF.md）",
             level="WARN")
        # --staged（提交门）只判本次新增行；全量体检扫全文
        scan = staged_added_lines(root, "README.md") if staged else rlines
        rscope = " 新增行" if staged else ""
        for name, rx, lv in (
            ("无本机用户路径", README_LOCAL_PATH_RE, "FAIL"),
            ("无疑似真实口令/密钥", README_SECRET_RE, "WARN"),
            ("无内网真实 IP", README_PRIVATE_IP_RE, "WARN"),
        ):
            hits = [i for i, ln in enumerate(scan, 1) if rx.search(ln)]
            emit(not hits, f"README{rscope} {name}",
                 f"{len(hits)} 处（规范 16.1）：" +
                 "；".join(f"L{i}" for i in hits[:5]) + ("…" if len(hits) > 5 else ""),
                 level=lv, incremental=staged)

    # 14) `.local/` 若存在必须被忽略（规范 2.2：本机私有区 —— 凭据副本 / 抓包测试数据，永不入库）
    if (root / ".local").is_dir():
        emit(is_ignored(root, ".local/_probe_"), ".local/ 已被忽略（本机私有区）",
             "`.local/` 未被 .gitignore 挡住 —— 规范 2.2 要求永不入库（凭据副本 / 测试数据会随提交外泄）；"
             "在 .gitignore 加 `.local/` 或 `*.local`")

    # 15) fork / 公开仓口径：有 upstream remote 且 .memory/ 入库（规范 2.2，WARN）
    if "upstream" in git("remote", cwd=root).split():
        mem = git("ls-files", "--", ".memory", cwd=root)
        emit(not mem, ".memory/ 公开仓口径",
             f"本仓有 `upstream`（fork 仓，多半面向公开）且 `.memory/` 已入库 {len(mem.splitlines())} 个文件 —— "
             "公开仓须忽略 `.memory/`（规范 2.2：它含本机路径 / 内部项目名 / 隐私）", level="WARN")

    # 16) 提交门防线（2026-09-24 新增）：**挂了 ≠ 有效**
    #     三种静默失效：① hooksPath 指向不存在的路径 ② 目录里没有钩子文件
    #     ③ 钩子行尾未被 .gitattributes 锁 LF ⇒ 换机（core.autocrlf=true）重新检出即 CRLF 化，
    #        报 `bad interpreter: /bin/sh^M`，且 `git status` 毫无提示（规范 16.1 / SKILL.md Windows 坑表）。
    #     `--ci` 补充：CI 上是干净检出，**没有 local 级 hooksPath** ⇒ 若按 hp 判定，
    #     该项整段跳过 ⇒ CI 永远看不到门是否存在。故退一步审「已入库的钩子目录」本身：
    #     钩子进版本控制 = 它能随 clone 传播的唯一前提；行尾锁 = 传播后是否还活着。
    if hp:
        hd = Path(hp)
        hd = hd if hd.is_absolute() else (root / hd)
        shown = f"`core.hooksPath` = `{hp}`"
    elif ci:
        hd = next((root / d for d in ("githooks", ".githooks") if (root / d).is_dir()), None)
        shown = "已入库的钩子目录"
    else:
        hd = None
        shown = ""
    if hd is not None:
        hook_files: list[Path] = []
        if hd.is_dir():
            hook_files = [p for p in sorted(hd.iterdir())
                          if p.is_file() and not p.name.endswith(".sample")]
        problems: list[str] = []
        level = "WARN"
        if not hd.is_dir():
            problems.append(f"{shown} 不存在 —— 门指向空处")
        elif not hook_files:
            problems.append(f"{shown} 指向的目录内无钩子文件 —— 门形同虚设")
        else:
            ac = git("config", "--get", "core.autocrlf", cwd=root)
            by_git = ac == "true"
            for p in hook_files:
                try:
                    rel = p.relative_to(root).as_posix()
                except ValueError:
                    continue                     # 钩子目录在仓外（全局模板），属性不归本仓管
                eol = git("check-attr", "eol", "--", rel, cwd=root).rsplit(": ", 1)[-1].strip()
                if eol != "lf":
                    problems.append(f"`{rel}` 行尾未锁（eol: {eol or 'unspecified'}）")
                    if by_git:
                        level = "FAIL"
        if problems:
            emit(False, "提交门防线可用（挂载点 + 钩子 + 行尾锁 LF）",
                 "；".join(problems) + (
                     "。本机 `core.autocrlf=true` ⇒ **重新检出即变 CRLF**、钩子报 "
                     "`bad interpreter: /bin/sh^M` 而静默失效；修法：`.gitattributes` 加 "
                     "`<钩子路径>/* text eol=lf`（规范 16.1）"
                     if level == "FAIL" else
                     "；加固：`.gitattributes` 加 `<钩子路径>/* text eol=lf`，"
                     "或对齐 hooksPath 与实际钩子目录"),
                 level=level)
        else:
            emit(True, "提交门防线可用（挂载点 + 钩子 + 行尾锁 LF）")

    # 17) 依赖锁定文件已入库（规范 17.2；WARN —— 存量整改成本高，先走提示通道）
    unl: list[str] = []
    for manifest, (accept, hint) in LOCK_ACCEPT.items():
        if (root / manifest).exists() and _has_deps(root, manifest) \
                and not any((root / a).exists() for a in accept):
            unl.append(f"`{manifest}` 有依赖但无锁定文件 —— {hint}")
    if (root / "requirements.txt").exists():
        dep_n, loose_n = _reqs_pinned(root)
        if dep_n and loose_n and not any(
                (root / a).exists() for a in ("poetry.lock", "uv.lock", "Pipfile.lock")):
            unl.append(f"`requirements.txt` {dep_n} 条依赖中 {loose_n} 条未用 `==` 钉死，"
                       "且无锁定文件 —— 版本会漂")
    if (root / "go.mod").exists() and "require" in _read_text_sig(root, "go.mod") \
            and not (root / "go.sum").exists():
        unl.append("`go.mod` 有 require 但无 `go.sum`")
    emit(not unl, "依赖锁定文件已入库（规范 17.2）", "；".join(unl), level="WARN")

    # 18) BOM 污染（平台坑表 / 规范 16.1）
    bom_hard: list[str] = []
    bom_soft: list[str] = []
    for rel in git("ls-files", cwd=root).splitlines():
        p = root / rel
        if p.suffix.lower() in BOM_SKIP_EXTS:
            continue
        try:
            if not p.is_file() or p.stat().st_size < 3:
                continue
            with p.open("rb") as fh:
                if fh.read(3) != BOM:
                    continue
        except OSError:
            continue
        if p.suffix.lower() in BOM_PARSER_EXTS or p.name in BOM_PARSER_NAMES:
            bom_hard.append(f"`{rel}`（解析器会直接报错）")
        elif p.name == ".gitignore":
            first = p.read_bytes()[3:].split(b"\n", 1)[0].lstrip()
            if first and not first.startswith(b"#"):
                bom_hard.append(f"`{rel}`（首行是忽略规则 ⇒ **该规则静默失效**）")
            else:
                bom_soft.append(f"`{rel}`（首行是注释，暂无实害）")
        else:
            bom_soft.append(f"`{rel}`")
    detail = "；".join(bom_hard)
    if bom_hard and bom_soft:
        detail += f"；另 {len(bom_soft)} 处提示级"
    emit(not bom_hard, "无 BOM 污染（解析器 / 忽略规则类）", detail)
    if bom_soft:
        emit(False, "无 BOM 污染（其他文本）",
             "；".join(bom_soft[:5]) + ("…" if len(bom_soft) > 5 else "") +
             " —— 约定入库文本无 BOM（`.ps1` / `.bat` / `.cmd` 已排除，其 BOM 是平台要求）",
             level="WARN")

    # 20) 下发物与上游一致（**模板漂移**，只报不改）
    #     背景：install-guard.sh 只幂等升级「提交门」相关下发物；模板（守卫副本 / CI 工作流 /
    #     钩子模板）改了之后，存量项目并不感知 —— 过去全靠人肉批处理（见 2026-09-25 #25）。
    #     这里做**只读比对**：不一致只 WARN，同步动作仍走安装器（时机由人决定）。
    #     钩子按**版本号**比而非逐字节：双门 / 本仓自用钩子本就与模板不同，逐字节必误报。
    up = _upstream_root()
    if up is not None:
        drift: list[str] = []
        for rel, up_rel in (("scripts/repo-guard.py", "scripts/repo-guard.py"),
                            (".github/workflows/guard.yml", "templates/guard-workflow.yml")):
            lp, rp = root / rel, up / up_rel
            if lp.is_file() and rp.is_file() and lp.read_bytes() != rp.read_bytes():
                drift.append(f"`{rel}` ≠ 上游 `{up_rel}`")
        h = root / "githooks/pre-commit"
        t = up / "templates/pre-commit"
        if h.is_file() and t.is_file():
            m1 = HOOK_VER_RE.search(h.read_bytes().decode("utf-8", "replace"))
            m2 = HOOK_VER_RE.search(t.read_bytes().decode("utf-8", "replace"))
            if m1 and m2 and m1.group(1) != m2.group(1):
                drift.append(f"钩子版 {m1.group(1)} ≠ 模板 {m2.group(1)}")
        if drift:
            emit(False, "下发物与上游一致（模板漂移）",
                 "；".join(drift) + " → 跑 install-guard.sh 同步（本项只报不改，不改文件）",
                 level="WARN")
        else:
            emit(True, "下发物与上游一致（模板漂移）")

    # 21) 已入库大文件（观察级）：git 不适合存大二进制，clone 体积是所有人付的成本
    big = _big_tracked(root, BIG_FILE_MB)
    if big:
        emit(False, f"无超大文件入库（>{BIG_FILE_MB}MB）",
             "；".join(f"`{p}` {s:.0f}MB" for s, p in big[:5]) +
             ("…" if len(big) > 5 else "") +
             " → 走 git-lfs 或移出仓库（规范 11.2）", level="WARN")
    else:
        emit(True, f"无超大文件入库（>{BIG_FILE_MB}MB）")

    # 22) 语言 lint / 格式配置（观察级）—— 规范 19.8
    #     只判「有明确配置文件」的语言；Rust / Java / C# 由工具链自带，不判。
    lang, has_lint, hint = _lint_state(root)
    emit(has_lint, "语言 lint / 格式配置已下发",
         f"{lang} 项目未见 {hint}（规范 19.8：lint 命令要能真跑起来，不能只写在 AGENTS 里）"
         if lang else "", level="WARN")

    # 23) 远端协议 —— 本机 https 走代理不稳（8.x 既定纪律）
    #     纯本地仓无 remote ⇒ 不适用，直接 PASS 不刷屏。
    remotes = git("remote", cwd=root).split()
    if not remotes:
        emit(True, "远端使用 ssh 协议", "无远端（纯本地仓，不适用）")
    else:
        bad_url = []
        for r in remotes:
            u = git("remote", "get-url", r, cwd=root)
            if u and not u.startswith(("git@", "ssh://")):
                bad_url.append(f"`{r}` = {u}")
        emit(not bad_url, "远端使用 ssh 协议",
             "；".join(bad_url) + " → 改 ssh：`git remote set-url <名> git@gh-<别名>:<owner>/<repo>.git`"
             "（https 在本机受代理影响，README 8.x）", level="WARN")

    return f2, w2, lines


def discover_projects() -> list[Path]:
    """扫描 D:\\w-dev\\<领域>\\<项目>，返回含 .git 的项目根列表。"""
    out = []
    if not W_DEV.exists():
        return out
    for dom in sorted(W_DEV.iterdir()):
        if not dom.is_dir() or dom.name.startswith(".") or dom.name.startswith("_"):
            continue
        for p in sorted(dom.iterdir()):
            if (p / ".git").exists():
                out.append(p)
    return out


def is_archive(root: Path) -> bool:
    return bool(ARCHIVE_RE.search(root.name))


def check_top_level() -> tuple[list[str], list[str]]:
    r"""顶层准入检查：`D:\w-dev` 顶层只允许 12 个领域目录 + `_archive\`。

    依据 README §二「顶层准入清单」（2026-09-24 定稿）—— 顶层是**工作根不是暂存区**，
    散文件 / 临时产物（`_tmp*` / `_rescue*` / `_revtmp*`）/ 依赖缓存（vendor / node_modules / .venv）/
    工具目录一律不许停在这里。返回 (fails, lines)。
    """
    fails: list[str] = []
    lines: list[str] = []
    if not W_DEV.exists():
        return fails, lines
    for item in sorted(W_DEV.iterdir()):
        if item.name in DOMAIN_ALLOW or item.name == "_archive":
            continue
        kind = "目录" if item.is_dir() else "文件"
        fails.append(item.name)
        lines.append(f"  [FAIL] 顶层只允许「12 个领域目录 + _archive」 → 多了{kind} `{item.name}`"
                     "（README 二章：归位 / 进 _archive / 删除）")
    return fails, lines


def _looks_like_project(d: Path) -> bool:
    r"""目录是否有「项目特征」—— 用于区分「未初始化的项目」与「真散落物」。

    2026-09-25 首跑实证：`gis/wgis`（29M，含 .sln + 交付报告）/ `wb/wb-ng`（807M，Electron 应用）
    这类**是真实项目、只是没 git init**，若按「有没有 `.git`」一刀切会全部误判为散落物 ⇒
    降为 WARN 提示补 `git init`，而不是让人去删自己的项目。
    """
    if not d.is_dir():
        return False
    marks = ("README.md", "README", "AGENTS.md", "ARCHITECTURE.md", "package.json",
             "pyproject.toml", "Cargo.toml", "go.mod", "requirements.txt",
             "composer.json", "pom.xml", "index.html")
    if any((d / m).exists() for m in marks):
        return True
    try:
        for p in d.iterdir():
            if p.suffix.lower() in (".sln", ".csproj", ".vcxproj", ".xcodeproj") or p.name == "Directory.Build.props":
                return True
            if p.is_dir() and p.name in ("src", "app", "backend", "frontend", "packages", "renderer"):
                return True
            # 单子目录包裹形态（如 `wb-ng/workbuddy-extracted/`）—— 特征文件在下一层
            if p.is_dir():
                if any((p / m).exists() for m in marks):
                    return True
    except OSError:
        return False
    return False


def check_domain_level() -> tuple[list[str], list[str], list[str]]:
    r"""领域目录准入检查（**第 24 项**）：领域目录下只允许「项目目录 + `_archive\`」。

    依据 README §二「领域目录准入清单」（2026-09-25 定稿）—— 领域目录是**项目的容器不是工作台**。
    三级判定（**不能只看有没有 `.git`**，见 `_looks_like_project`）：
      ① 有 `.git` = 项目 → PASS
      ② 无 `.git` 但有项目特征 = **未初始化的项目** → **WARN**（提示补 `git init`）
      ③ 无 `.git` 且无项目特征 = 散落物（工具产物 / 抓包 / 试验场）→ **FAIL**
    另查各项目 `.local/` 内**无嵌套 `.git`**（B-1 细则：私有区不许藏仓库）。
    返回 (fails, warns, lines)。
    """
    fails: list[str] = []
    warns: list[str] = []
    lines: list[str] = []
    if not W_DEV.exists():
        return fails, warns, lines

    # 按路径豁免（`.repo-guard-ignore` 的 `领域目录准入: <domain>/<name>` 形态）——
    # 给「主人已裁定保留、但机检无法区分」的特例留一条不关整项的通路（2026-09-25：
    # `ide/ide-vscode` 是承认 ide 域时的占位空壳，主人明确保留）。
    exempt = _scoped_ignores("领域目录准入", SELF_ROOT)

    # ① 领域目录层的散落物 / 未初始化项目
    for domain in sorted(W_DEV.iterdir()):
        if not domain.is_dir() or domain.name not in DOMAIN_ALLOW:
            continue
        # 领域目录**自身**不得是 git 仓（规范第七章第 3 条：禁止在领域目录层级建仓）
        # —— 注意区分：领域下的**项目**含 `.git` 是合规的（第二章准入），
        #    这里禁的是 `stock/.git` 这种「领域目录自己变成仓」。
        if (domain / ".git").exists():
            rel_d = domain.name
            fails.append(rel_d)
            lines.append(f"  [FAIL] 领域目录 `{rel_d}/` **自身**是 git 仓（`.git` 直接位于领域层）"
                         "→ 禁止在领域目录层级建仓（规范第七章第 3 条）；"
                         "把仓下沉到 `\u003c域\u003e/\u003c项目\u003e/` 一层")

        for item in sorted(domain.iterdir()):
            if item.name == "_archive":          # 领域级归档区，豁免
                continue
            if f"{domain.name}/{item.name}" in exempt:
                continue                          # 已登记豁免（PASS，不占 FAIL / WARN 计数）
            if item.is_dir() and (item / ".git").exists():
                # 合规：是个项目。但 `_` 前缀的 git 仓要单独提示 —— 它多半是**临时探针仓**
                # （规范明说「临时 git 仓禁停此处」），也可能是真归档仓。**只 WARN 不 FAIL**，
                # 因为无法机检区分二者，误杀归档仓的代价更高（2026-09-25）。
                if item.name.startswith("_"):
                    rel = f"{domain.name}/{item.name}"
                    warns.append(rel)
                    lines.append(f"  [WARN] `{rel}` 是 `_` 前缀的 git 仓 → 临时探针 / 对拍仓应**用完即删**；"
                                 "真归档仓请移入领域 `_archive/`（README 二章「临时 git 仓」条）")
                continue
            rel = f"{domain.name}/{item.name}"
            if _looks_like_project(item):
                warns.append(rel)
                lines.append(f"  [WARN] `{rel}` 像**未初始化的项目**（无 `.git`）→ `git init` 后即合规"
                             "（README 二章「领域目录准入」；若确非项目，按归位四类表处置）")
                continue
            kind = "目录" if item.is_dir() else "文件"
            fails.append(rel)
            lines.append(f"  [FAIL] 领域目录只允许「项目目录 + _archive」 → 多了{kind} `{rel}`"
                         "（README 二章「领域目录准入」：运行产物 / 长期资产 → 该项目 .local/；"
                         "一次性物 / 临时仓 → 删除）")

    # ② 各项目 .local/ 内禁嵌套 .git —— **只查第一层子目录**
    #    2026-09-25 实测教训：工具链自带的 `.git` 会出现在深层
    #    （`kit/blutter/.git` 深度 3、`kit/blutter/dartsdk/v3.11.3/.git` 深度 5），
    #    它们是**工具自身的版本管理**，不是「用户往私有区塞了个仓」⇒ 一刀切 rglob 会误伤。
    #    典型违规形态 = `.local/<某仓>/.git`（深度 1），判据就卡这一层。
    for domain in sorted(W_DEV.iterdir()):
        if not domain.is_dir() or domain.name not in DOMAIN_ALLOW:
            continue
        for proj in sorted(domain.iterdir()):
            if not proj.is_dir() or not (proj / ".git").exists():
                continue
            local = proj / ".local"
            if not local.is_dir():
                continue
            for sub in sorted(local.iterdir()):
                if not sub.is_dir() or not (sub / ".git").exists():
                    continue
                if (sub / ".git").is_file():
                    continue                     # submodule / worktree 形态，跳过
                rel = sub.relative_to(proj).as_posix()
                fails.append(f"{domain.name}/{proj.name}/{rel}")
                lines.append(f"  [FAIL] `.local/` 第一层不许放 git 仓 → `{domain.name}/{proj.name}/{rel}`"
                             "（README 2.2 B-1：会造「仓库里的仓库」，撞第 2 项；临时仓用完即删。"
                             "工具链自带的深层 `.git` 不在此限）")
    return fails, warns, lines


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default=None,
                    help="要检查的项目目录（缺省 = 当前目录）")
    ap.add_argument("--staged", action="store_true",
                    help="提交门模式：只阻断本次新增的问题（密钥 / 敏感文件 / README 新增行），"
                         "属性类问题降为 WARN")
    ap.add_argument("--quiet", action="store_true", help="只输出问题项")
    ap.add_argument("--version", action="store_true", help="打印守卫版本")
    ap.add_argument("--ci", action="store_true",
                    help="CI 模式（服务端全量判定）：密钥项由 WARN 升 FAIL，"
                         "跳过 hooksPath 等本机专属项。给 GitHub Actions / 远端流水线用，"
                         "**不要**在本地提交门里用（那里该用 --staged）")
    ap.add_argument("--all", action="store_true",
                    help="批量项目体检 D:\\w-dev 全部 git 项目（汇总 + 快照落盘）")
    args = ap.parse_args()

    if args.version:
        print(f"repo-guard {GUARD_SCRIPT_VERSION}")
        return 0

    # ---------- 批量模式 ----------
    if args.all:
        return run_batch(staged=args.staged, ci=args.ci)

    # ---------- 单项目模式 ----------
    global ignores
    start = Path(args.path).resolve() if args.path else Path.cwd()
    top = git("rev-parse", "--show-toplevel", cwd=start)
    if not top:
        print("[SKIP] 当前目录不是 git 仓库 —— repo-guard 只检查有版本控制的项目")
        return 0
    root = Path(top)
    ignores.update(load_ignores(root))
    if not args.quiet:
        print(f"检查项目：{root}")
        if args.staged:
            print("  模式：提交门（--staged）—— 只阻断本次增量问题，属性类降为 WARN")
        if args.ci:
            print("  模式：CI 全量（--ci）—— 服务端判定，密钥项升级为 FAIL")
        if ignores:
            print(f"  ⚠ 豁免项（`.repo-guard-ignore`）：{'；'.join(sorted(ignores))}")
    f2, w2, lines = run_checks(root, staged=args.staged, ci=args.ci)
    for ln in lines:
        if args.quiet and "[PASS]" in ln:
            continue
        print(ln)
    print("-" * 62)
    if f2:
        print(f"结论：{len(f2)} 项 FAIL、{len(w2)} 项 WARN —— 有阻断项，请先修")
        return 1
    print("结论：无 FAIL" + (f"，{len(w2)} 项 WARN" if w2 else "，全部通过"))
    return 0


def run_batch(staged: bool, ci: bool = False) -> int:
    """批量项目体检：逐项目跑机检，汇总输出 + 快照落盘 `.local/体检快照/项目体检-<日期>.md`。"""
    global ignores
    projects = discover_projects()
    if not projects:
        print(f"[FAIL] 在 {W_DEV} 下未发现 git 项目")
        return 1
    print(f"批量项目体检：{W_DEV} 下 {len(projects)} 个 git 项目")
    print("=" * 62)
    tl_fails, tl_lines = check_top_level()
    print(f"【顶层准入检查】{W_DEV} 顶层（README 二章）")
    if tl_fails:
        for ln in tl_lines:
            print(ln)
    else:
        print("  [PASS] 顶层只有 12 个领域目录 + _archive")
    print("-" * 62)
    dl_fails, dl_warns, dl_lines = check_domain_level()
    print(f"【领域目录准入检查】各领域目录（README 二章「领域目录准入」，第 24 项）")
    if dl_fails or dl_warns:
        for ln in dl_lines:
            print(ln)
    else:
        print("  [PASS] 领域目录下只有项目目录 + _archive；`.local/` 内无嵌套 git 仓")
    print("-" * 62)

    results: list[tuple[Path, int, list[str], list[str]]] = []  # (root, nfail, nwarn, problines)
    for root in projects:
        ignores = load_ignores(root)
        f2, w2, lines = run_checks(root, staged=staged, ci=ci)
        results.append((root, len(f2), len(w2), lines))
        tag = "归档" if is_archive(root) else "项目"
        if f2 or w2:
            print(f"[{len(f2)}F/{len(w2)}W] {root.parent.name}/{root.name}（{tag}）")
            for ln in lines:
                if "[PASS]" not in ln:
                    print(ln)
        else:
            print(f"[PASS] {root.parent.name}/{root.name}（{tag}）")

    print("=" * 62)
    live = [(r, nf, nw, pb) for r, nf, nw, pb in results if not is_archive(r)]
    arch = [(r, nf, nw, pb) for r, nf, nw, pb in results if is_archive(r)]
    bad_live = [x for x in live if x[1] > 0]
    bad_arch = [x for x in arch if x[1] > 0]

    print(f"汇总：活项目 {len(live)} 个（FAIL {len(bad_live)}）、归档 {len(arch)} 个（FAIL {len(bad_arch)}，不阻断）")
    print(f"  顶层准入：{len(tl_fails)} 项违规" + (f" —— {'、'.join(tl_fails)}" if tl_fails else ""))
    print(f"  领域目录准入：{len(dl_fails)} 项违规、{len(dl_warns)} 项 WARN（未初始化项目）"
          + (f" —— {'、'.join(dl_fails[:6])}" if dl_fails else ""))
    for r, nf, nw, _ in bad_live + bad_arch:
        print(f"  → {r.parent.name}/{r.name}：{nf} FAIL / {nw} WARN")

    # 快照落盘（2026-09-25：改落 `.local/` —— 体检快照是**运行产物**不是项目资产，
    #   落 docs/ 会日日堆积（同日重跑还会连环转存），且每次跑完 docs/ 都显示 M。
    #   `.local/` 被 .gitignore 挡住、永不入库，符合规范 2.2「本机私有区」定义。
    #   同名已存在 → 旧版先转存带时间戳，避免同日重跑直接覆盖丢档）
    today = datetime.date.today().isoformat()
    snap_dir = SELF_ROOT / ".local" / "体检快照"
    snap_dir.mkdir(parents=True, exist_ok=True)
    snap = snap_dir / f"项目体检-{today}.md"
    if snap.exists():
        stamp = datetime.datetime.now().strftime("%H%M")
        keep = snap.with_name(f"项目体检-{today}-{stamp}.md")
        n = 1
        while keep.exists():
            keep = snap.with_name(f"项目体检-{today}-{stamp}-{n}.md")
            n += 1
        snap.replace(keep)
        print(f"（同名快照已存在 → 旧版转存 {keep.name}）")
    lines_out = [f"# 批量项目体检快照 {today}", "",
                 f"- 范围：{W_DEV} 下 {len(results)} 个 git 项目",
                 f"- 结果：活项目 {len(live)}（FAIL {len(bad_live)}）/ 归档 {len(arch)}（FAIL {len(bad_arch)}，不阻断）",
                 f"- 顶层准入（README 二章）：{len(tl_fails)} 项违规" + (f" —— {'、'.join(tl_fails)}" if tl_fails else ""), ""]
    lines_out.append(f"- 领域目录准入（README 二章，第 24 项）：{len(dl_fails)} 项违规、{len(dl_warns)} 项 WARN" +
                     (f" —— {'、'.join(dl_fails)}" if dl_fails else ""))
    linept = f"- 领域目录准入 WARN（未初始化项目，建议 git init）：{'、'.join(dl_warns)}" if dl_warns else ""
    if linept:
        lines_out.append(linept)
    lines_out.append("")
    for r, nf, nw, pb in results:
        tag = "（归档）" if is_archive(r) else ""
        lines_out.append(f"## {r.parent.name}/{r.name} {tag} — {nf} FAIL / {nw} WARN")
        lines_out += [ln.strip() for ln in pb if "[PASS]" not in ln] or ["全部通过"]
        lines_out.append("")
    snap.write_text("\n".join(lines_out), encoding="utf-8")
    print(f"快照已落盘：{snap}")

    return 1 if (bad_live or tl_fails or dl_fails) else 0


if __name__ == "__main__":
    sys.exit(main())
