#!/usr/bin/env bash
#
# autosync.sh - 여러 저장소를 한 번에, 사람 손 없이 동기화한다.
#
#   ./autosync.sh                  # 등록된 저장소 전부 (병렬)
#   ./autosync.sh --dry-run        # 무엇이 오갈지만
#   ./autosync.sh wiki             # 하나만
#   ./autosync.sh --status         # 현재 상태 요약
#
# 설계 원칙
#   - **부담이 없어야 한다**: 변경이 없으면 네트워크 왕복 한 번으로 끝난다.
#   - **충돌로 멈추지 않는다**: 해결 가능한 것은 자동으로 처리하고,
#     정말 판단이 필요한 것만 남긴 뒤 저장소를 깨끗한 상태로 되돌린다.
#     자동 실행이 사람을 기다리는 상태로 방치되면 안 된다.
#   - **잠금**: 같은 저장소에 두 번 겹쳐 돌지 않는다.
#   - **조용하다**: 바뀐 게 있을 때만 말한다. cron/launchd 에 적합하다.
#
# 설정: ~/.aside/tools/aside-memory-sync/repos.conf
#   이름|경로|remote|충돌전략
#     충돌전략 = driver  : 구조 인식 병합 드라이버에 맡긴다 (Aside 메모리)
#                manual : 충돌 시 되돌리고 사람을 부른다 (일반 문서 저장소)
#                pull   : 받기만 한다. 커밋하지 않고, 절대 push 하지 않는다.
#
#   driver 와 manual 은 **둘 다 push 한다.** 이름만 보면 manual 이 사람 손을 거칠 것
#   같지만, 전략이 갈리는 지점은 '충돌이 났을 때 뭘 하나' 하나뿐이다. 로컬에 변경이
#   있으면 어느 쪽이든 자동 커밋하고 보낸다. 상류를 바꾸면 안 되는 기기에는 pull 을 써라.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONF="${ASIDE_SYNC_CONF:-$SCRIPT_DIR/repos.conf}"
STATE_DIR="$HOME/.aside/tools/.autosync"
mkdir -p "$STATE_DIR"

# MSYS hostname 에는 -s 가 없다. 도메인을 직접 잘라 짧은 이름을 만든다.
HOST="$(hostname)"; HOST="${HOST%%.*}"

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
QUIET=0; DRY_RUN=0; ONLY=""; STATUS_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --quiet|-q) QUIET=1 ;;
    --status) STATUS_ONLY=1 ;;
    -*) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
    *) ONLY="$arg" ;;
  esac
done

say()  { [[ $QUIET -eq 1 ]] || printf '%s\n' "$1"; }
ok()   { [[ $QUIET -eq 1 ]] || printf '%s==>%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
err()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$1" >&2; }

[[ -f "$CONF" ]] || { err "설정 파일이 없다: $CONF"; exit 1; }

# --------------------------------------------------------------------------
# 저장소 하나를 동기화한다. 출력은 임시파일에 모았다가 마지막에 한 번에 낸다.
# --------------------------------------------------------------------------
sync_one() {
  local name="$1" dir="$2" remote="$3" strategy="$4" out="$5"
  local branch changed=0

  {
    dir="${dir/#\~/$HOME}"
    if [[ ! -d "$dir/.git" ]]; then
      echo "SKIP|$name|저장소가 없다: $dir"
      return 0
    fi

    cd "$dir" || { echo "FAIL|$name|접근 불가"; return 1; }

    # 잠금. 이전 실행이 아직 돌고 있으면 조용히 빠진다.
    local lock="$STATE_DIR/$name.lock"
    if ! mkdir "$lock" 2>/dev/null; then
      # 30분 넘은 잠금은 죽은 것으로 본다.
      if [[ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]]; then
        rmdir "$lock" 2>/dev/null && mkdir "$lock" 2>/dev/null || { echo "SKIP|$name|잠김"; return 0; }
      else
        echo "SKIP|$name|이미 실행 중"
        return 0
      fi
    fi
    trap 'rmdir "$lock" 2>/dev/null' RETURN

    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo "FAIL|$name|브랜치 확인 실패"; return 1; }
    git remote get-url "$remote" >/dev/null 2>&1 || { echo "SKIP|$name|remote '$remote' 없음"; return 0; }

    # --- dry-run -------------------------------------------------------
    if [[ $DRY_RUN -eq 1 ]]; then
      git fetch -q "$remote" 2>/dev/null
      local ahead behind dirty
      ahead=$(git rev-list --count "$remote/$branch..HEAD" 2>/dev/null || echo 0)
      behind=$(git rev-list --count "HEAD..$remote/$branch" 2>/dev/null || echo 0)
      dirty=$(git status --porcelain | wc -l | tr -d ' ')
      echo "DRY|$name|보낼 $ahead · 받을 $behind · 미커밋 $dirty"
      return 0
    fi

    # --- 1. 로컬 변경 커밋 ----------------------------------------------
    # pull 전략은 커밋하지 않는다. 받기만 하는 기기다.
    if [[ "$strategy" != "pull" && -n "$(git status --porcelain)" ]]; then
      local n
      n=$(git status --porcelain | wc -l | tr -d ' ')
      git add -A
      # 훅이 자동 실행을 막지 않도록 우회한다. 게이트는 사람이 커밋할 때 돈다.
      git commit -q --no-verify -m "autosync: $HOST $(date '+%Y-%m-%d %H:%M') (파일 ${n}개)" 2>/dev/null
      changed=1
    fi

    # --- 2. fetch ------------------------------------------------------
    if ! git fetch -q "$remote" 2>/dev/null; then
      echo "FAIL|$name|fetch 실패 (네트워크/SSH 확인)"
      return 1
    fi

    if ! git rev-parse --verify -q "$remote/$branch" >/dev/null; then
      if [[ "$strategy" == "pull" ]]; then
        echo "SKIP|$name|remote 에 $branch 가 없다 (pull 전략은 만들지 않는다)"
        return 0
      fi
      git push -q -u "$remote" "$branch" 2>/dev/null && echo "OK|$name|첫 push" || echo "FAIL|$name|첫 push 실패"
      return 0
    fi

    # --- 3. 병합 -------------------------------------------------------
    local behind
    behind=$(git rev-list --count "HEAD..$remote/$branch" 2>/dev/null || echo 0)

    if [[ "$behind" -gt 0 ]]; then
      # pull 전략은 fast-forward 만 받는다. 로컬에 뭐가 쌓여 있으면 사람을 부른다.
      if [[ "$strategy" == "pull" ]]; then
        if git merge --ff-only "$remote/$branch" >/dev/null 2>&1; then
          changed=1
        else
          echo "HOLD|$name|로컬 변경이 있어 받지 못했다 (pull 전략, 사람이 처리한다)"
          return 2
        fi
      else
      local margs=(--no-edit)
      git merge-base HEAD "$remote/$branch" >/dev/null 2>&1 || margs+=(--allow-unrelated-histories)

      if git merge "${margs[@]}" "$remote/$branch" >/dev/null 2>&1; then
        changed=1
      else
        # 충돌. 전략에 따라 갈린다.
        local conflicts
        conflicts=$(git diff --name-only --diff-filter=U | tr '\n' ' ')

        if [[ "$strategy" == "driver" ]]; then
          # 드라이버가 이미 최선을 다한 뒤 남은 것이다. 사람 판단이 필요하다.
          git merge --abort 2>/dev/null
          echo "CONFLICT|$name|판단 필요: $conflicts"
          return 2
        else
          # manual: 자동 실행이 저장소를 충돌 상태로 두면 안 된다. 되돌린다.
          git merge --abort 2>/dev/null
          echo "CONFLICT|$name|충돌로 보류: $conflicts"
          return 2
        fi
      fi
      fi
    fi

    # --- 4. push -------------------------------------------------------
    # pull 전략은 절대 보내지 않는다. 이 기기가 상류를 바꿀 수 없어야 하는 경우에 쓴다.
    local ahead
    ahead=$(git rev-list --count "$remote/$branch..HEAD" 2>/dev/null || echo 0)
    if [[ "$strategy" == "pull" && "$ahead" -gt 0 ]]; then
      echo "HOLD|$name|보낼 것이 $ahead 개 있지만 pull 전략이라 보내지 않는다"
      return 2
    fi
    if [[ "$ahead" -gt 0 ]]; then
      if git push -q "$remote" "$branch" 2>/dev/null; then
        changed=1
      else
        echo "FAIL|$name|push 실패"
        return 1
      fi
    fi

    # 추가 remote(예: GitHub 미러)가 설정돼 있으면 함께 보낸다. 실패해도 무시.
    local mirror
    mirror=$(git config --get "aside.sync.mirror" 2>/dev/null || true)
    if [[ "$strategy" != "pull" && -n "$mirror" ]] && git remote get-url "$mirror" >/dev/null 2>&1; then
      git push -q "$mirror" "$branch" 2>/dev/null || true
    fi

    if [[ $changed -eq 1 ]]; then
      echo "SYNCED|$name|$(git rev-parse --short HEAD)"
    else
      echo "CLEAN|$name|변경 없음"
    fi
  } > "$out" 2>&1
}

# --------------------------------------------------------------------------
# 설정 읽기
# --------------------------------------------------------------------------
REPOS=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [[ -z "$line" ]] && continue
  REPOS+=("$line")
done < "$CONF"

[[ ${#REPOS[@]} -gt 0 ]] || { err "설정에 저장소가 없다."; exit 1; }

# --- 상태만 보기 ---------------------------------------------------------
if [[ $STATUS_ONLY -eq 1 ]]; then
  printf '%-14s %-10s %6s %6s %8s  %s\n' "저장소" "HEAD" "보낼" "받을" "미커밋" "경로"
  for entry in "${REPOS[@]}"; do
    IFS='|' read -r name dir remote strategy <<< "$entry"
    dir="${dir/#\~/$HOME}"
    [[ -d "$dir/.git" ]] || { printf '%-14s %s\n' "$name" "(없음)"; continue; }
    ( cd "$dir" || exit
      b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
      git fetch -q "$remote" 2>/dev/null
      printf '%-14s %-10s %6s %6s %8s  %s\n' "$name" "$(git rev-parse --short HEAD)" \
        "$(git rev-list --count "$remote/$b..HEAD" 2>/dev/null || echo -)" \
        "$(git rev-list --count "HEAD..$remote/$b" 2>/dev/null || echo -)" \
        "$(git status --porcelain | wc -l | tr -d ' ')" \
        "${dir/#$HOME/~}" )
  done
  exit 0
fi

# --------------------------------------------------------------------------
# 병렬 실행
# --------------------------------------------------------------------------
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

PIDS=()
COUNT=0
for entry in "${REPOS[@]}"; do
  IFS='|' read -r name dir remote strategy <<< "$entry"
  [[ -n "$ONLY" && "$name" != "$ONLY" ]] && continue
  COUNT=$((COUNT+1))
  sync_one "$name" "$dir" "$remote" "${strategy:-manual}" "$TMPD/$name.out" &
  PIDS+=($!)
done

[[ $COUNT -gt 0 ]] || { err "'$ONLY' 에 해당하는 저장소가 없다."; exit 1; }

for pid in "${PIDS[@]}"; do wait "$pid"; done

# --------------------------------------------------------------------------
# 결과 정리
# --------------------------------------------------------------------------
EXIT=0
CHANGED_ANY=0
for f in "$TMPD"/*.out; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    IFS='|' read -r kind name msg <<< "$line"
    case "$kind" in
      SYNCED)   ok "$name: 동기화됨 ($msg)"; CHANGED_ANY=1 ;;
      CLEAN)    say "${DIM}    $name: 변경 없음${RST}" ;;
      DRY)      say "    $name: $msg" ;;
      SKIP)     say "${DIM}    $name: $msg${RST}" ;;
      HOLD)     warn "$name: $msg"; EXIT=2; CHANGED_ANY=1 ;;
      CONFLICT) warn "$name: $msg"; EXIT=2; CHANGED_ANY=1 ;;
      FAIL)     err "$name: $msg"; EXIT=1; CHANGED_ANY=1 ;;
      *)        [[ -n "$line" ]] && say "    $line" ;;
    esac
  done < "$f"
done

if [[ $EXIT -eq 2 ]]; then
  echo
  warn "충돌이 난 저장소는 건드리지 않고 되돌려 뒀다. 아래로 직접 처리해라:"
  echo "${DIM}    cd <저장소> && git merge <remote>/main${RST}"
fi

exit $EXIT
