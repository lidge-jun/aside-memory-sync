#!/usr/bin/env bash
#
# install-autosync.sh - 주기 자동 동기화를 이 기기에 등록한다.
#
#   ./install-autosync.sh            # 15분마다
#   ./install-autosync.sh 30         # 30분마다
#   ./install-autosync.sh --remove   # 해제
#
#   ./install-autosync.sh 15 AsideAutosyncTest   # Windows 태스크 이름
#   ./install-autosync.sh --remove AsideAutosyncTest
#
# macOS 는 launchd, Windows 는 Task Scheduler, 리눅스는 cron 을 쓴다.
# 실행은 조용하고(--quiet) 변경이 있을 때만 로그를 남긴다.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LABEL="com.aside.autosync"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$HOME/.aside/tools/.autosync"
mkdir -p "$LOG_DIR"

GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
ok()   { printf '%s==>%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }

# Windows(MINGW/MSYS/CYGWIN) 여부. Darwin 분기는 이 함수를 타지 않는다.
windows_uname() {
  case "$(uname)" in
    MINGW*|MSYS*|CYGWIN*) return 0 ;;
    *) return 1 ;;
  esac
}

# schtasks 스위치는 /Create 형태라 Git Bash 가 C:/Create 로 바꿔 먹는다.
# MSYS_NO_PATHCONV 로 변환을 끄고, 경로는 이미 cygpath -w 로 넘긴다.
windows_schtasks() {
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' schtasks.exe "$@"
}

windows_xml_escape() {
  local s="$1"
  # Git Bash 는 ${var//pat/&x} 의 & 를 일치 문자열로 먹는다. 치환 값은 따옴표로 고정한다.
  s=${s//'&'/'&amp;'}
  s=${s//'<'/'&lt;'}
  s=${s//'>'/'&gt;'}
  s=${s//'"'/'&quot;'}
  printf '%s' "$s"
}

# WP6 bin/invoke-git-bash.ps1 로케이터를 호출한다. 탐색 순서를 여기 복제하지 않는다.
windows_resolve_bash() {
  local locator="$SCRIPT_DIR/bin/invoke-git-bash.ps1"
  [[ -f "$locator" ]] || { echo "bin/invoke-git-bash.ps1 이 없다. Git Bash 경로를 찾을 수 없다." >&2; exit 1; }
  command -v powershell.exe >/dev/null || { echo "powershell.exe 가 없다." >&2; exit 1; }

  local probe="$LOG_DIR/aside-locate-bash.ps1"
  cat > "$probe" <<'PS1'
$ErrorActionPreference = 'Stop'
$locator = $env:ASIDE_INVOKE_GIT_BASH
. "$locator"
if (-not (Get-Command Invoke-GitBash -ErrorAction SilentlyContinue)) {
  [Console]::Error.WriteLine('invoke-git-bash.ps1 에 Invoke-GitBash 가 없다.')
  exit 1
}
$text = ${function:Invoke-GitBash}.ToString()
if ($text -notmatch '& \$bash\b') {
  [Console]::Error.WriteLine('invoke-git-bash.ps1 에 bash 호출이 없다.')
  exit 1
}
$patched = [regex]::Replace($text, '& \$bash\b[^\r\n]*', 'Write-Output $bash')
$patched = $patched -replace 'exit \$LASTEXITCODE', 'exit 0'
${function:Invoke-GitBash} = [scriptblock]::Create($patched)
Invoke-GitBash $locator
PS1

  local locator_win bash_win ps_ec
  locator_win="$(cygpath -w "$locator")"
  set +e
  bash_win="$(ASIDE_INVOKE_GIT_BASH="$locator_win" MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$probe")")"
  ps_ec=$?
  set -e
  rm -f "$probe"
  [[ "$ps_ec" -eq 0 ]] || exit "$ps_ec"

  bash_win="${bash_win//$'\r'/}"
  bash_win="${bash_win##*$'\n'}"
  bash_win="${bash_win#"${bash_win%%[![:space:]]*}"}"
  bash_win="${bash_win%"${bash_win##*[![:space:]]}"}"
  [[ -n "$bash_win" ]] || { echo "Git Bash 경로를 얻지 못했다." >&2; exit 1; }
  printf '%s\n' "$bash_win"
}

windows_remove() {
  local name="${1:-AsideAutosync}"
  windows_schtasks /Delete /TN "$name" /F >/dev/null 2>&1 || true
  ok "Task Scheduler 등록을 해제했다."
}

# launchd 의 PATH/HOME 대응.
# Task Scheduler XML 은 EnvironmentVariables 노드를 거부한다 (unexpected node).
# 액션은 bash.exe --noprofile --norc autosync.sh --quiet 한 argv 벡터로 고정한다.
# InteractiveToken 이 사용자 환경을 물려 주고, Git Bash 런타임이 /usr/bin 과
# /mingw64/bin 을 PATH 앞에 붙이므로 git/ssh 가 잡힌다. WorkingDirectory 는
# 로케이터가 찾은 bash 에서 유도한 Git cmd (하드코딩하지 않는다).
windows_install() {
  local interval="$1" name="$2"
  local bash_win bash_mixed git_bin_dir git_root workdir_win autosync_mixed
  local xml_utf8 xml_utf16 xml_win start cmd_esc arg_esc wd_esc

  bash_win="$(windows_resolve_bash)"
  # cygpath -u 는 Git\\bin\\bash.exe 를 /bin/bash.exe 로 접어 Git 루트를 잃어버린다. -m 만 쓴다.
  bash_mixed="$(cygpath -m "$bash_win")"
  git_bin_dir="${bash_mixed%/*}"
  git_root="${git_bin_dir%/*}"
  if [[ -d "$git_root/cmd" ]]; then
    workdir_win="$(cygpath -w "$git_root/cmd")"
  else
    workdir_win="$(cygpath -w "$git_bin_dir")"
  fi
  autosync_mixed="$(cygpath -m "$SCRIPT_DIR/autosync.sh")"
  start="$(date +%Y-%m-%dT%H:%M:%S)"

  cmd_esc="$(windows_xml_escape "$bash_win")"
  arg_esc="$(windows_xml_escape "--noprofile --norc \"$autosync_mixed\" --quiet")"
  wd_esc="$(windows_xml_escape "$workdir_win")"

  xml_utf8="$LOG_DIR/${name}.utf8.xml"
  xml_utf16="$LOG_DIR/${name}.xml"
  cat > "$xml_utf8" <<EOF
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <URI>\\$name</URI>
  </RegistrationInfo>
  <Triggers>
    <TimeTrigger>
      <Repetition>
        <Interval>PT${interval}M</Interval>
      </Repetition>
      <StartBoundary>$start</StartBoundary>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>8</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$cmd_esc</Command>
      <Arguments>$arg_esc</Arguments>
      <WorkingDirectory>$wd_esc</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
EOF

  ASIDE_TASK_XML_UTF8="$(cygpath -w "$xml_utf8")"
  ASIDE_TASK_XML_UTF16="$(cygpath -w "$xml_utf16")"
  export ASIDE_TASK_XML_UTF8 ASIDE_TASK_XML_UTF16
  MSYS_NO_PATHCONV=1 powershell.exe -NoProfile -Command '[IO.File]::WriteAllText($env:ASIDE_TASK_XML_UTF16, [IO.File]::ReadAllText($env:ASIDE_TASK_XML_UTF8), [Text.Encoding]::Unicode)'
  xml_win="$ASIDE_TASK_XML_UTF16"
  windows_schtasks /Create /TN "$name" /XML "$xml_win" /F
  rm -f "$xml_utf8" "$xml_utf16"
  unset ASIDE_TASK_XML_UTF8 ASIDE_TASK_XML_UTF16
  ok "Task Scheduler 등록 완료 — ${interval}분마다 실행된다."
}

# --- 해제 ----------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    ok "launchd 등록을 해제했다."
  elif windows_uname; then
    windows_remove "${2:-AsideAutosync}"
  else
    crontab -l 2>/dev/null | grep -v 'autosync.sh' | crontab - || true
    ok "cron 등록을 해제했다."
  fi
  exit 0
fi

INTERVAL_MIN="${1:-15}"
[[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] || { echo "간격은 숫자(분)여야 한다."; exit 1; }

TASK_NAME="${2:-AsideAutosync}"
[[ -n "$TASK_NAME" ]] || { echo "태스크 이름이 비어 있다."; exit 1; }

[[ -f "$SCRIPT_DIR/repos.conf" ]] || {
  warn "repos.conf 가 없다. 예시를 복사해서 경로를 맞춰라:"
  echo "    cp $SCRIPT_DIR/repos.conf.example $SCRIPT_DIR/repos.conf"
  exit 1
}

chmod +x "$SCRIPT_DIR/autosync.sh"

# --- macOS: launchd ------------------------------------------------------
if [[ "$(uname)" == "Darwin" ]]; then
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SCRIPT_DIR/autosync.sh</string>
    <string>--quiet</string>
  </array>
  <key>StartInterval</key><integer>$((INTERVAL_MIN * 60))</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>$LOG_DIR/autosync.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/autosync.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:$HOME/.homebrew/bin</string>
    <key>HOME</key><string>$HOME</string>
  </dict>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
</dict>
</plist>
EOF

  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST"
  ok "launchd 등록 완료 — ${INTERVAL_MIN}분마다 실행된다."

# --- Windows: Task Scheduler ----------------------------------------------
elif windows_uname; then
  windows_install "$INTERVAL_MIN" "$TASK_NAME"

# --- Linux: cron ---------------------------------------------------------
else
  ( crontab -l 2>/dev/null | grep -v 'autosync.sh'
    echo "*/$INTERVAL_MIN * * * * /bin/bash $SCRIPT_DIR/autosync.sh --quiet >> $LOG_DIR/autosync.log 2>&1" ) | crontab -
  ok "cron 등록 완료 — ${INTERVAL_MIN}분마다 실행된다."
fi

echo
cat <<EOF
${DIM}로그:   tail -f $LOG_DIR/autosync.log
수동:   $SCRIPT_DIR/autosync.sh
상태:   $SCRIPT_DIR/autosync.sh --status
해제:   $SCRIPT_DIR/install-autosync.sh --remove

동기화는 저전력 우선순위(Nice 10, LowPriorityIO)로 돌고,
변경이 없으면 fetch 한 번으로 끝나 부담이 거의 없다.${RST}
EOF
