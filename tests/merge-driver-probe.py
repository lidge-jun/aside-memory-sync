#!/usr/bin/env python3
"""aside-memory-merge 자가 점검.

의존성 없이 드라이버를 직접 호출해서 세 가지를 확인한다.

  1. 머리말 합집합  - 제목(H2 이상) 이 없는 L1 파일에서 양쪽 줄이 모두 남는가
  2. 스텁 합류      - 스텁 L1 기기가 합류할 때 상대 기기의 머리말이 살아남는가
  3. 줄바꿈         - 결과가 LF 로만 쓰이는가 (Windows 에서 CRLF 가 섞이면 함대 전체가 흔들린다)

실행:
    python3 tests/merge-driver-probe.py
    %USERPROFILE%\\.aside\\runtime\\bin\\python3.cmd tests\\merge-driver-probe.py

인자로 드라이버 경로를 주면 그 파일을 대신 검사한다. 수정 전 버전을 꺼내
이 테스트가 실제로 판별력이 있는지 확인할 때 쓴다:

    git show HEAD~1:bin/aside-memory-merge > /tmp/old && python3 tests/merge-driver-probe.py /tmp/old

종료 코드 0 이면 통과. 실패한 항목은 FAIL 로 찍고 1 을 돌려준다.
"""
from __future__ import annotations

import pathlib
import shutil
import subprocess
import sys
import tempfile

try:  # 콘솔 인코딩(cp949 등) 때문에 리포트가 죽지 않도록.
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:  # pragma: no cover
    pass

ROOT = pathlib.Path(__file__).resolve().parent.parent
DRIVER = (
    pathlib.Path(sys.argv[1]).resolve()
    if len(sys.argv) > 1
    else ROOT / "bin" / "aside-memory-merge"
)

STUB = "# Memory Briefing\n\n<!-- L1 operating briefing: refreshed by dreaming. -->\n"
FULL = (
    "# Memory Briefing\n"
    "\n"
    "<!-- L1 operating briefing: refreshed by dreaming. -->\n"
    "\n"
    "> Reconstructed 2026-09-09 after this file was found empty.\n"
    "\n"
    "## Environment\n"
    "- Bash starts with a minimal PATH.\n"
)

failures: list[str] = []


def run_driver(base: str, ours: str, theirs: str, name: str):
    """드라이버를 한 번 돌리고 (종료코드, 결과 바이트) 를 준다."""
    tmp = pathlib.Path(tempfile.mkdtemp(prefix="aside-merge-probe-"))
    try:
        o, a, b = tmp / "base", tmp / "ours", tmp / "theirs"
        o.write_bytes(base.encode("utf-8"))
        a.write_bytes(ours.encode("utf-8"))
        b.write_bytes(theirs.encode("utf-8"))
        proc = subprocess.run(
            [sys.executable, str(DRIVER), str(o), str(a), str(b), name],
            capture_output=True,
        )
        return proc.returncode, a.read_bytes()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check(label: str, condition: bool, detail: str = "") -> None:
    if condition:
        print("PASS  %s" % label)
    else:
        print("FAIL  %s%s" % (label, ("  -- " + detail) if detail else ""))
        failures.append(label)


def case_preamble_union() -> None:
    base = "# Memory\n\n- alpha\n- bravo\n"
    ours = "# Memory\n\n- alpha\n- bravo\n- windows-only\n"
    theirs = "# Memory\n\n- alpha\n- bravo\n- mac-only\n"
    code, out = run_driver(base, ours, theirs, "MEMORY.md")
    text = out.decode("utf-8")
    check("1a 제목 없는 L1 병합이 깨끗하게 끝난다", code == 0, "exit=%d" % code)
    check("1b 이쪽 줄이 남는다", "windows-only" in text)
    check("1c 저쪽 줄이 남는다", "mac-only" in text, repr(text))


def case_stub_join() -> None:
    ours = STUB + "\n- windows local note\n"
    code, out = run_driver(STUB, ours, FULL, "MEMORY.md")
    text = out.decode("utf-8")
    check("2a 스텁 합류 병합이 깨끗하게 끝난다", code == 0, "exit=%d" % code)
    check("2b 상대 기기 머리말이 살아남는다", "Reconstructed 2026-09-09" in text, repr(text))
    check("2c 상대 기기 본문 제목이 살아남는다", "## Environment" in text)
    check("2d 이쪽 로컬 줄이 남는다", "windows local note" in text)
    check("2e 충돌 마커가 없다", "<<<<<<<" not in text)


def case_line_endings() -> None:
    base = "# Memory\n\n## A\n- one\n"
    ours = "# Memory\n\n## A\n- one\n- two\n"
    theirs = "# Memory\n\n## A\n- one\n- three\n"
    _, out = run_driver(base, ours, theirs, "MEMORY.md")
    check("3a 결과에 CRLF 가 없다", out.count(b"\r\n") == 0, "CRLF=%d" % out.count(b"\r\n"))
    check("3b 결과에 홀로 선 CR 이 없다", out.count(b"\r") == 0)


def main() -> int:
    if not DRIVER.exists():
        print("FAIL  드라이버를 찾을 수 없다: %s" % DRIVER)
        return 1
    print("드라이버: %s" % DRIVER)
    case_preamble_union()
    case_stub_join()
    case_line_endings()
    print()
    if failures:
        print("실패 %d 건: %s" % (len(failures), ", ".join(failures)))
        return 1
    print("전부 통과")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
