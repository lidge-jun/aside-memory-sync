#!/usr/bin/env bash
#
# hub-setup.sh - 항상 켜져 있는 서버에 중앙 허브(bare 저장소)를 두고 연결한다.
#
#   ./hub-setup.sh <ssh호스트> [메모리폴더] [허브경로]
#
# 예:
#   ./hub-setup.sh myserver
#   ./hub-setup.sh myserver ~/.aside/u/0/memory /home/ubuntu/git/aside-memory.git
#
# P2P(기기끼리 직접) 방식과의 차이
#   - 기기가 서로 켜져 있을 필요가 없다. 각자 편할 때 허브와 주고받는다.
#   - 기기가 3대 이상이면 연결 수가 N개로 끝난다 (P2P 는 N*(N-1)/2).
#   - 서버가 자연스러운 백업본이 된다.
#
# 주의: 허브에는 개인 기억이 그대로 올라간다. 신뢰하는 서버에만 두어라.

set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

HOST="${1:-}"
[[ -n "$HOST" ]] || die "사용법: ./hub-setup.sh <ssh호스트> [메모리폴더] [허브경로]"

MEMORY_DIR="${2:-$PWD}"
HUB_PATH="${3:-}"

# --- 메모리 폴더 확인 ----------------------------------------------------
MEMORY_DIR="$(cd "$MEMORY_DIR" 2>/dev/null && pwd)" || die "폴더가 없다: ${2:-$PWD}"
cd "$MEMORY_DIR"
git rev-parse --git-dir >/dev/null 2>&1 || die "여기는 git 저장소가 아니다. install.sh 를 먼저 실행해라."
info "저장소: ${MEMORY_DIR/#$HOME/~}"

# --- SSH 연결 확인 -------------------------------------------------------
info "$HOST 접속 확인 중..."
ssh -o ConnectTimeout=10 -o BatchMode=yes "$HOST" 'echo ok' >/dev/null 2>&1 \
  || die "$HOST 에 접속할 수 없다. ~/.ssh/config 와 키 등록을 확인해라."

REMOTE_HOME="$(ssh -o BatchMode=yes "$HOST" 'echo $HOME')"
[[ -n "$HUB_PATH" ]] || HUB_PATH="$REMOTE_HOME/git/aside-memory.git"
info "허브 경로: $HOST:$HUB_PATH"

# --- 허브 생성 (없을 때만) ----------------------------------------------
if ssh -o BatchMode=yes "$HOST" "[ -d '$HUB_PATH' ]"; then
  info "허브가 이미 있다. 재사용한다."
else
  ssh -o BatchMode=yes "$HOST" "mkdir -p \$(dirname '$HUB_PATH') && git init --bare -b main '$HUB_PATH' >/dev/null && git -C '$HUB_PATH' config core.sharedRepository group"
  info "허브를 만들었다."
fi

# 소유자만 접근하도록 조인다. 서버를 여럿이 쓰면 이게 최소한의 방어선이다.
ssh -o BatchMode=yes "$HOST" "chmod 700 '$HUB_PATH'" 2>/dev/null || true

# --- remote 등록 ---------------------------------------------------------
git remote remove hub 2>/dev/null || true
git remote add hub "$HOST:$HUB_PATH"
info "remote 'hub' 등록 완료."

# --- 첫 동기화 -----------------------------------------------------------
git fetch -q hub 2>/dev/null || true

BRANCH="$(git rev-parse --abbrev-ref HEAD)"

if git rev-parse --verify -q "hub/$BRANCH" >/dev/null; then
  # 허브에 이미 내용이 있다. 받아서 합친다.
  if [[ -z "$(git log --oneline "HEAD..hub/$BRANCH" 2>/dev/null)" ]]; then
    info "허브와 이미 같은 상태다."
  else
    MERGE_ARGS=(--no-edit)
    git merge-base HEAD "hub/$BRANCH" >/dev/null 2>&1 || MERGE_ARGS+=(--allow-unrelated-histories)
    if git merge "${MERGE_ARGS[@]}" "hub/$BRANCH"; then
      info "허브 내용을 병합했다."
    else
      warn "충돌이 남았다. 해결 후 'git commit' 하고 ./sync.sh 를 실행해라."
      git diff --name-only --diff-filter=U | sed 's/^/    /'
      exit 1
    fi
  fi
fi

git push -q -u hub "$BRANCH"
info "허브에 push 하고 추적 설정을 마쳤다."

echo
cat <<EOF
${DIM}이제 각 기기에서 아래만 실행하면 된다:

    cd ${MEMORY_DIR/#$HOME/~}
    ./sync.sh

다른 기기를 연결할 때도 같은 명령을 쓴다:

    ./hub-setup.sh $HOST <그 기기의 메모리폴더>

허브는 bare 저장소라 작업트리가 없고, 여러 기기가 동시에 push 해도 안전하다.${RST}
EOF
