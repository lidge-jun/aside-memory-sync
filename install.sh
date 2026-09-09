#!/usr/bin/env bash
#
# install.sh - 이 기기의 Aside 메모리 폴더를 git 저장소로 준비한다.
#
#   ./install.sh                 # 자동 탐지된 메모리 폴더 사용
#   ./install.sh ~/.aside/u/1/memory
#
# 하는 일
#   1. 메모리 폴더 확인
#   2. git init (이미 저장소면 건너뜀)
#   3. .gitignore / .gitattributes 설치
#   4. 병합 드라이버를 이 저장소의 로컬 설정에 등록
#   5. 첫 커밋 생성
#
# 원격 저장소는 건드리지 않는다. 기기 간 연결은 sync.sh 참고.

set -euo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; DIM=$'\033[2m'; RST=$'\033[0m'
info() { printf '%s==>%s %s\n' "$GRN" "$RST" "$1"; }
warn() { printf '%s[!]%s %s\n' "$YLW" "$RST" "$1"; }
die()  { printf '%s[x]%s %s\n' "$RED" "$RST" "$1" >&2; exit 1; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. 메모리 폴더 결정 -------------------------------------------------
MEMORY_DIR="${1:-}"

if [[ -z "$MEMORY_DIR" ]]; then
  mapfile -t CANDIDATES < <(find "$HOME/.aside/u" -maxdepth 2 -type d -name memory 2>/dev/null | sort)

  if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    die "메모리 폴더를 찾지 못했다. 경로를 직접 넘겨라: ./install.sh ~/.aside/u/1/memory"
  elif [[ ${#CANDIDATES[@]} -eq 1 ]]; then
    MEMORY_DIR="${CANDIDATES[0]}"
  else
    echo "여러 계정 슬롯이 있다. 동기화할 것을 골라라:"
    echo
    for i in "${!CANDIDATES[@]}"; do
      d="${CANDIDATES[$i]}"
      n=$(find "$d" -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
      s=$(du -sh "$d" 2>/dev/null | cut -f1)
      printf '  %2d) %s  %s(md %s개, %s)%s\n' "$((i+1))" "${d/#$HOME/~}" "$DIM" "$n" "$s" "$RST"
    done
    echo
    read -rp "번호: " choice
    [[ "$choice" =~ ^[0-9]+$ ]] || die "숫자를 입력해라."
    MEMORY_DIR="${CANDIDATES[$((choice-1))]}"
    [[ -n "$MEMORY_DIR" ]] || die "잘못된 선택이다."
  fi
fi

MEMORY_DIR="$(cd "$MEMORY_DIR" && pwd)"
[[ -d "$MEMORY_DIR" ]] || die "폴더가 없다: $MEMORY_DIR"
info "대상: ${MEMORY_DIR/#$HOME/~}"

# 슬롯 번호가 기기마다 다를 수 있음을 알려준다.
SLOT="$(basename "$(dirname "$MEMORY_DIR")")"
warn "이 기기의 슬롯 번호는 u/$SLOT 다. 다른 기기의 슬롯 번호와 다를 수 있으니,"
warn "같은 '내용'을 담은 슬롯끼리 연결해야 한다. 번호를 맞출 필요는 없다."

# --- 2. git init ---------------------------------------------------------
cd "$MEMORY_DIR"
if [[ -d .git ]]; then
  info "이미 git 저장소다. init 을 건너뛴다."
else
  git init -q -b main
  info "git 저장소를 만들었다 (브랜치: main)."
fi

# --- 3. 템플릿 설치 ------------------------------------------------------
install_template() {
  local src="$1" dst="$2"
  if [[ -f "$dst" ]]; then
    if cmp -s "$src" "$dst"; then
      info "$dst 는 이미 최신이다."
    else
      cp "$dst" "$dst.bak.$(date +%s)"
      cp "$src" "$dst"
      warn "$dst 를 갱신했다 (이전 파일은 .bak 으로 보관)."
    fi
  else
    cp "$src" "$dst"
    info "$dst 를 설치했다."
  fi
}

install_template "$SCRIPT_DIR/templates/gitignore"    .gitignore
install_template "$SCRIPT_DIR/templates/gitattributes" .gitattributes

# --- 4. 병합 드라이버 등록 ----------------------------------------------
DRIVER="$SCRIPT_DIR/bin/aside-memory-merge"
[[ -f "$DRIVER" ]] || die "병합 드라이버가 없다: $DRIVER"
chmod +x "$DRIVER"

command -v python3 >/dev/null 2>&1 || die "python3 가 필요하다."

# 저장소 로컬 설정에만 기록한다. 전역 설정은 건드리지 않는다.
git config merge.aside.name "Aside memory structure-aware merge"
git config merge.aside.driver "$DRIVER %O %A %B %P"
git config merge.aside.recursive binary
info "병합 드라이버를 등록했다 (이 저장소 한정)."

# 중앙 서버 없이 기기끼리 직접 push 할 수 있게 한다.
# 기본값은 "체크아웃된 브랜치로는 push 불가" 이라 P2P 구성에서 막힌다.
# updateInstead 는 작업트리가 깨끗할 때만 받아서 안전하다.
git config receive.denyCurrentBranch updateInstead
info "상대 기기가 이곳으로 바로 push 할 수 있게 설정했다."

# 커밋 identity 가 없으면 저장소 로컬로 채운다.
if ! git config user.email >/dev/null 2>&1; then
  git config user.email "aside-memory@$(hostname -s)"
  git config user.name "$(whoami)@$(hostname -s)"
  warn "git identity 가 없어 저장소 로컬 값으로 채웠다."
fi

# --- 5. 첫 커밋 ----------------------------------------------------------
# 이미 추적 중인데 gitignore 에 걸린 캐시가 있으면 인덱스에서 제거한다.
git rm -r --cached . -q 2>/dev/null || true
git add -A

if git diff --cached --quiet 2>/dev/null; then
  info "커밋할 변경이 없다."
else
  git commit -q -m "aside memory: $(hostname -s) 초기 스냅샷"
  info "첫 커밋을 만들었다."
fi

echo
info "완료. 추적 중인 파일:"
git ls-files | sed 's/^/    /'
echo
cat <<EOF
${DIM}다음 단계
  1) 다른 기기에서도 이 install.sh 를 실행한다.
  2) 두 기기를 연결한다 (SSH 로 직접, 중앙 서버 불필요):

     이 기기에서:
       git remote add other <상대>:$(printf '%q' "${MEMORY_DIR/#$HOME/\$HOME}")
       git fetch other

     처음 한 번은 두 저장소의 뿌리가 달라 아래 옵션이 필요하다:
       git merge other/main --allow-unrelated-histories

  3) 이후에는 ./sync.sh 만 실행하면 된다.${RST}
EOF
