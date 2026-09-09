#!/usr/bin/env bash
#
# install-autosync.sh - 주기 자동 동기화를 이 기기에 등록한다.
#
#   ./install-autosync.sh            # 15분마다
#   ./install-autosync.sh 30         # 30분마다
#   ./install-autosync.sh --remove   # 해제
#
# macOS 는 launchd, 리눅스는 cron 을 쓴다.
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

# --- 해제 ----------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
  if [[ "$(uname)" == "Darwin" ]]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    ok "launchd 등록을 해제했다."
  else
    crontab -l 2>/dev/null | grep -v 'autosync.sh' | crontab - || true
    ok "cron 등록을 해제했다."
  fi
  exit 0
fi

INTERVAL_MIN="${1:-15}"
[[ "$INTERVAL_MIN" =~ ^[0-9]+$ ]] || { echo "간격은 숫자(분)여야 한다."; exit 1; }

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
