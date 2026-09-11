#!/usr/bin/env bash
#
# sync.sh - 수동 트리거 방식의 양방향 메모리 동기화.
#
#   ./sync.sh                # 기본 remote(other) 와 동기화
#   ./sync.sh macmini        # 지정한 remote 와 동기화
#   ./sync.sh --dry-run      # 무엇이 오갈지만 보여준다
#
# 설계 의도
#   - 자동 실행하지 않는다. 사용자가 원할 때만 돈다.
#   - rebase 대신 merge 를 쓴다. 병합 드라이버는 merge 에서만 동작한다.
#   - 충돌이 남으면 멈추고, 무엇을 판단해야 하는지 알려준다.

set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

DRY_RUN=0
FORCE=0
REMOTE=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -y|--yes|--force) FORCE=1 ;;
    -*) die "알 수 없는 옵션: $arg" ;;
    *) REMOTE="$arg" ;;
  esac
done

# 스크립트 위치가 아니라, 실행 위치 기준으로 저장소를 찾는다.
git rev-parse --git-dir >/dev/null 2>&1 || die "여기는 git 저장소가 아니다. 메모리 폴더에서 실행해라."
cd "$(git rev-parse --show-toplevel)"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# MSYS hostname 에는 -s 가 없다. 도메인을 직접 잘라 짧은 이름을 만든다.
HOST="$(hostname)"; HOST="${HOST%%.*}"

# --- remote 결정 ---------------------------------------------------------
if [[ -z "$REMOTE" ]]; then
  # bash 3.2 호환 (mapfile 없음)
  REMOTES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && REMOTES+=("$line")
  done < <(git remote)
  [[ ${#REMOTES[@]} -gt 0 ]] || die "remote 가 없다. 먼저 'git remote add other <호스트>:<경로>' 를 해라."
  if [[ ${#REMOTES[@]} -eq 1 ]]; then
    REMOTE="${REMOTES[0]}"
  else
    # 중앙 허브(hub)가 있으면 우선, 그다음 P2P 관습명(other), 없으면 첫 번째.
    REMOTE="$(printf '%s\n' "${REMOTES[@]}" | grep -x hub \
              || printf '%s\n' "${REMOTES[@]}" | grep -x other \
              || echo "${REMOTES[0]}")"
  fi
fi
git remote get-url "$REMOTE" >/dev/null 2>&1 || die "remote '$REMOTE' 가 없다."

info "저장소: $(pwd | sed "s|^$HOME|~|")"
info "remote: $REMOTE ($(git remote get-url "$REMOTE"))  브랜치: $BRANCH"

# --- 병합 드라이버 확인 --------------------------------------------------
if ! git config merge.aside.driver >/dev/null 2>&1; then
  warn "병합 드라이버가 등록돼 있지 않다. install.sh 를 먼저 실행해라."
  warn "이대로 진행하면 충돌이 훨씬 자주 난다."
fi

# --- 데몬이 쓰기 중인지 확인 --------------------------------------------
# 인덱스 캐시가 방금 바뀌었다면 에이전트가 작업 중일 가능성이 높다.
# dry-run 은 아무것도 바꾸지 않으므로 검사를 건너뛴다.
if [[ $DRY_RUN -eq 0 && -e .moss-cache ]]; then
  RECENT=$(find .moss-cache -newermt '-60 seconds' 2>/dev/null | head -1)
  if [[ -n "$RECENT" ]]; then
    warn "최근 1분 내 메모리 인덱스가 갱신됐다. 에이전트가 작업 중일 수 있다."
    if [[ $FORCE -eq 1 ]]; then
      warn "--yes 가 지정돼 그대로 진행한다."
    elif [[ -t 0 ]]; then
      read -rp "그래도 계속할까? [y/N] " ans
      [[ "$ans" =~ ^[Yy]$ ]] || exit 0
    else
      die "대화형 터미널이 아니다. 확인 없이 진행하려면 --yes 를 붙여라."
    fi
  fi
fi

# --- dry-run -------------------------------------------------------------
if [[ $DRY_RUN -eq 1 ]]; then
  info "fetch 중 (변경은 하지 않는다)..."
  git fetch -q "$REMOTE" || die "fetch 실패."
  echo
  echo "${DIM}--- 로컬에만 있는 커밋 (보낼 것) ---${RST}"
  git log --oneline "$REMOTE/$BRANCH..HEAD" 2>/dev/null || echo "  (없음)"
  echo
  echo "${DIM}--- 원격에만 있는 커밋 (받을 것) ---${RST}"
  git log --oneline "HEAD..$REMOTE/$BRANCH" 2>/dev/null || echo "  (없음)"
  echo
  echo "${DIM}--- 커밋되지 않은 로컬 변경 ---${RST}"
  git status --short || true
  exit 0
fi

# --- 1. 로컬 변경 커밋 ---------------------------------------------------
git add -A
if ! git diff --cached --quiet; then
  CHANGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
  git commit -q -m "memory: $HOST $(date '+%Y-%m-%d %H:%M') (파일 $CHANGED개)"
  info "로컬 변경 $CHANGED개를 커밋했다."
else
  info "커밋할 로컬 변경이 없다."
fi

# --- 2. fetch + merge ----------------------------------------------------
info "$REMOTE 에서 가져오는 중..."
git fetch -q "$REMOTE" || die "fetch 실패. SSH 연결을 확인해라."

if ! git rev-parse --verify -q "$REMOTE/$BRANCH" >/dev/null; then
  warn "원격에 $BRANCH 브랜치가 없다. 첫 push 로 진행한다."
  git push -u "$REMOTE" "$BRANCH" && info "첫 push 완료." || die "push 실패."
  exit 0
fi

if [[ -z "$(git log --oneline "HEAD..$REMOTE/$BRANCH" 2>/dev/null)" ]]; then
  info "받을 새 커밋이 없다."
else
  # git merge 에는 --no-rebase 가 없다. pull 이 아니라 merge 를 직접 부르므로
  # 어찌피 rebase 는 일어나지 않고, 병합 드라이버가 그대로 동작한다.
  MERGE_ARGS=(--no-edit)
  # 뿌리가 다른 저장소를 처음 합칠 때만 필요한 옵션.
  if ! git merge-base HEAD "$REMOTE/$BRANCH" >/dev/null 2>&1; then
    warn "두 저장소의 히스토리가 무관하다. 최초 연결로 보고 --allow-unrelated-histories 를 쓴다."
    MERGE_ARGS+=(--allow-unrelated-histories)
  fi

  if git merge "${MERGE_ARGS[@]}" "$REMOTE/$BRANCH"; then
    info "병합 완료."
  else
    echo
    warn "자동 병합이 끝나지 않았다. 판단이 필요한 파일:"
    git diff --name-only --diff-filter=U | sed 's/^/    /'
    echo
    cat <<EOF
${DIM}대부분은 시맨틱 페이지의 '## Current' 블록이다. 어느 쪽 서술이 맞는지는
사람이나 에이전트가 판단해야 한다. History 와 일별 로그는 이미 자동으로 합쳐졌다.

  1) 충돌 파일을 열어 <<<<<<< ======= >>>>>>> 구간을 정리한다
  2) git add <파일>
  3) git commit
  4) ./sync.sh 를 다시 실행한다

되돌리려면: git merge --abort${RST}
EOF
    exit 1
  fi
fi

# --- 3. push -------------------------------------------------------------
if [[ -z "$(git log --oneline "$REMOTE/$BRANCH..HEAD" 2>/dev/null)" ]]; then
  info "보낼 커밋이 없다."
else
  git push -q "$REMOTE" "$BRANCH" && info "push 완료." || die "push 실패. 상대가 bare 저장소가 아니면 거부될 수 있다."
fi

echo
info "동기화 완료. Aside 데몬이 변경된 마크다운을 감지해 인덱스를 다시 만든다."
