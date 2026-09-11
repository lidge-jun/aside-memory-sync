#!/usr/bin/env bash
#
# pull-strategy-probe.sh - pull 전략이 정말로 아무것도 보내지 않는지 확인한다.
#
# 라이브 저장소로 시험하면 실패할 때 상류가 오염된다. 그래서 임시 bare 저장소와
# 임시 워킹 복사본을 만들어 거기서만 돌린다. 같은 시나리오를 manual 로도 돌려서
# 이 테스트가 실제로 둘을 구분하는지(판별력) 함께 확인한다.
#
#   bash tests/pull-strategy-probe.sh
#
# 종료 코드 0 이면 통과.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
AUTOSYNC="$ROOT/autosync.sh"

FAIL=0
check() {
  local label="$1" ok="$2" detail="${3:-}"
  if [[ "$ok" == "1" ]]; then
    printf 'PASS  %s\n' "$label"
  else
    printf 'FAIL  %s%s\n' "$label" "${detail:+  :: $detail}"
    FAIL=$((FAIL+1))
  fi
}

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=probe GIT_AUTHOR_EMAIL=probe@example.invalid
export GIT_COMMITTER_NAME=probe GIT_COMMITTER_EMAIL=probe@example.invalid

# 상류 bare 저장소 하나와 워킹 복사본 두 개(피시험용, 상류를 움직이는 용)
git init -q --bare "$TMP/upstream.git"
git clone -q "$TMP/upstream.git" "$TMP/seed" 2>/dev/null
( cd "$TMP/seed" && git checkout -q -b main 2>/dev/null
  printf 'line one\n' > note.md
  git add -A && git commit -q -m "seed" && git push -q -u origin main )

run_case() {
  local strategy="$1" dir="$TMP/$1"
  rm -rf "$dir"
  git clone -q "$TMP/upstream.git" "$dir" 2>/dev/null
  ( cd "$dir" && git checkout -q main 2>/dev/null )
  printf '%s|%s|origin|%s\n' "probe" "$dir" "$strategy" > "$TMP/repos.$strategy.conf"
  printf 'local edit by %s\n' "$strategy" >> "$dir/note.md"
  ASIDE_SYNC_CONF="$TMP/repos.$strategy.conf" bash "$AUTOSYNC" probe > "$TMP/out.$strategy" 2>&1
  printf '%s' "$?"
}

upstream_head() { git --git-dir="$TMP/upstream.git" rev-parse main; }

BEFORE="$(upstream_head)"

# --- pull: 커밋하지도, 보내지도 않아야 한다 ------------------------------
run_case pull >/dev/null
PULL_LOCAL_COMMITS="$(git -C "$TMP/pull" rev-list --count main)"
PULL_DIRTY="$(git -C "$TMP/pull" status --porcelain | wc -l | tr -d ' ')"
AFTER_PULL="$(upstream_head)"

check "pull: 상류가 그대로다" "$([[ "$AFTER_PULL" == "$BEFORE" ]] && echo 1 || echo 0)" "upstream moved"
check "pull: 로컬 커밋을 만들지 않았다" "$([[ "$PULL_LOCAL_COMMITS" == "1" ]] && echo 1 || echo 0)" "commits=$PULL_LOCAL_COMMITS"
check "pull: 로컬 변경을 그대로 남겨뒀다" "$([[ "$PULL_DIRTY" == "1" ]] && echo 1 || echo 0)" "dirty=$PULL_DIRTY"

# --- manual 컨트롤: 같은 상황에서 커밋하고 보내야 한다 --------------------
run_case manual >/dev/null
MANUAL_LOCAL_COMMITS="$(git -C "$TMP/manual" rev-list --count main)"
AFTER_MANUAL="$(upstream_head)"

check "manual 컨트롤: 상류가 움직였다 (판별력 확인)" "$([[ "$AFTER_MANUAL" != "$BEFORE" ]] && echo 1 || echo 0)" "upstream unchanged - this test cannot tell the two apart"
check "manual 컨트롤: 로컬 커밋을 만들었다" "$([[ "$MANUAL_LOCAL_COMMITS" == "2" ]] && echo 1 || echo 0)" "commits=$MANUAL_LOCAL_COMMITS"

# --- pull 은 받기는 해야 한다 ---------------------------------------------
rm -rf "$TMP/recv"
git clone -q "$TMP/upstream.git" "$TMP/recv" 2>/dev/null
( cd "$TMP/recv" && git checkout -q main 2>/dev/null )
printf 'probe|%s|origin|pull\n' "$TMP/recv" > "$TMP/repos.recv.conf"
( cd "$TMP/seed" && git pull -q --ff-only origin main >/dev/null 2>&1
  printf 'upstream addition\n' >> note.md
  git add -A && git commit -q -m "upstream moves" && git push -q origin main )
RECV_BEFORE="$(git -C "$TMP/recv" rev-parse main)"
ASIDE_SYNC_CONF="$TMP/repos.recv.conf" bash "$AUTOSYNC" probe > "$TMP/out.recv" 2>&1
RECV_AFTER="$(git -C "$TMP/recv" rev-parse main)"
check "pull: 상류 변경은 받아온다" "$([[ "$RECV_BEFORE" != "$RECV_AFTER" ]] && echo 1 || echo 0)" "did not fast-forward"
RECV_TEXT="$(cat "$TMP/recv/note.md")"
check "pull: 받아온 내용이 실제로 들어왔다" "$([[ "$RECV_TEXT" == *"upstream addition"* ]] && echo 1 || echo 0)" "content missing"

echo
if [[ $FAIL -gt 0 ]]; then
  echo "pull-strategy checks: $FAIL FAILED"
  echo "--- pull output ---";   cat "$TMP/out.pull"   2>/dev/null
  echo "--- manual output ---"; cat "$TMP/out.manual" 2>/dev/null
  echo "--- recv output ---";   cat "$TMP/out.recv"   2>/dev/null
  exit 1
fi
echo "pull-strategy checks: all passed"
exit 0
