"""编码合规修复 / 自检（项目内工具，路径全部相对脚本推导，可随项目整体搬迁）

规则（见 skill: warp-socks-accelerator 第四节）：
  .ps1        -> UTF-8 with BOM + CRLF   （PowerShell 5.1 无 BOM 会把中文按 GBK 读，报"缺少终止符"）
  .bat/.cmd   -> CRLF + 正文纯 ASCII     （cmd.exe 按 936 码页读，正文中文必乱码）

非 ASCII 的 bat 只报错、不改写（避免静默破坏）。

用法：python tools/fix-encoding.py
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]   # tools/ -> 项目根
errors = []

# 项目根 + tools（工具脚本也要合规 —— 曾因 test-common.ps1 是
# LF-only + 无 BOM 含中文，导致 PowerShell 按 GBK 解码、断言假失败）
ps1_files = sorted(list(ROOT.glob("*.ps1")) + list(ROOT.glob("tools/*.ps1")))

for p in ps1_files:
    raw = p.read_bytes()
    text = raw.decode("utf-8-sig")
    text = text.replace("\r\n", "\n").replace("\n", "\r\n")
    p.write_bytes(b"\xef\xbb\xbf" + text.encode("utf-8"))
    rel = p.relative_to(ROOT).as_posix()
    print(f"[PS1 ] {rel:40} BOM+CRLF   {p.stat().st_size} B")

for p in sorted(list(ROOT.glob("*.bat")) + list(ROOT.glob("*.cmd"))):
    text = p.read_bytes().decode("utf-8")
    bad = [(i, ln) for i, ln in enumerate(text.splitlines(), 1)
           if any(ord(c) > 126 for c in ln)]
    if bad:
        errors.append(p.name)
        for i, ln in bad:
            print(f"[BAT!] {p.name}:{i} non-ASCII -> {ln.strip()}")
        continue                                  # 有中文就别动，交给人工改
    text = text.replace("\r\n", "\n").replace("\n", "\r\n")
    p.write_bytes(text.encode("ascii"))
    print(f"[BAT ] {p.name:30} CRLF        {p.stat().st_size} B")

if errors:
    print("\n[FAIL] 以下 bat/cmd 正文含非 ASCII（cmd 会乱码，需改成英文）：")
    for e in errors:
        print("   -", e)
    sys.exit(1)
print("\nOK - encoding compliant")
