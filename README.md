# aside-memory-sync

여러 기기의 [Aside](https://asidehq.com) 메모리를 Git으로 동기화하는 스크립트 모음.

Aside의 클라우드 동기화는 **브라우저 데이터와 패스워드 볼트만** 다룬다. `~/.aside/u/<N>/memory/` 아래의 에이전트 기억(사용자 프로필, 일별 로그, 프로젝트/사이트 지식)은 **기기 로컬에만 남고 동기화되지 않는다.** 이 저장소는 그 빈틈을 메운다.

- 중앙 서버가 필요 없다. 기기끼리 SSH로 직접 주고받는다.
- 자동 실행하지 않는다. 원할 때만 `sync.sh` / `sync.ps1` 을 이 저장소 경로로 호출한다.
- 대부분의 충돌은 자동으로 해결되고, **사람의 판단이 필요한 것만** 남긴다.

구현은 `.sh` 하나다. `.ps1` 은 그 구현으로 들어가는 1급 진입점이다.

---

## 왜 rsync가 아니라 Git인가

`rsync`는 단방향 덮어쓰기다. 두 기기에서 각각 작업했다면 같은 날짜의 일별 로그가 양쪽에 생기고, rsync를 돌리는 순간 한쪽 기억이 통째로 사라진다.

Aside 메모리는 전부 마크다운이라 Git의 3-way 병합과 잘 맞는다. 게다가 파일 종류마다 성격이 달라서, 그 구조를 아는 병합 드라이버를 끼우면 대부분의 충돌이 자동으로 풀린다.

---

## 병합 전략

핵심은 `bin/aside-memory-merge`다. Git이 충돌을 만났을 때만 호출되며, 파일 종류를 보고 다르게 처리한다.

| 대상 | 성격 | 처리 |
|---|---|---|
| `episodic/*.md` | append-only 로그 | 양쪽 블록 **합집합 + 시간순 정렬**. 충돌 없음 |
| `MEMORY.md`, `USER.md` | L1 요약 | 같은 제목 아래 **줄 단위 합집합**, 중복 제거 |
| `projects/`, `sites/`, `people/` 등 | 시맨틱 페이지 | `## History`는 합집합, **`## Current`는 충돌로 남김** |
| `.moss-cache/`, `memory-index*.json` | 기기 로컬 캐시 | **동기화 대상 아님** (gitignore) |

`## Current`를 일부러 자동 병합하지 않는 이유는, 그 블록이 "현재 안정적인 이해"를 담기 때문이다. 두 기기가 서로 다른 결론을 적었다면 어느 쪽이 맞는지는 기계가 판단할 수 없다. 나머지는 다 합쳐놓고 이것만 남겨서, 판단해야 할 지점을 좁혀준다.

동작 순서:
1. 먼저 표준 `git merge-file`을 시도한다. 깨끗이 되면 그대로 쓴다.
2. 충돌했을 때만 위 규칙을 적용한다.
3. 규칙으로도 안 되면 충돌 마커를 남기고 종료 코드 1을 반환한다.

H1 아래 제목 없는 도입부(머리말)도 줄 단위 합집합이다. 예전에는 `ours` 쪽 머리말만 쓰고
상대 기기 것을 버렸는데, 스텁 L1 을 가진 새 기기가 합류하면 상대 기기의 도입부가 통째로
사라지는 결함이었다. 2026-09-12 에 고쳤다.

드라이버만 따로 검증하려면:

```bash
python3 tests/merge-driver-probe.py
```

```powershell
& "$env:USERPROFILE\.aside\runtime\bin\python3.cmd" tests\merge-driver-probe.py
```

머리말 합집합, 스텁 합류, LF 고정 세 가지를 확인한다. 인자로 드라이버 경로를 주면 그 파일을
대신 검사하므로, 옛 버전을 꺼내 이 테스트가 판별력이 있는지도 확인할 수 있다.

### 옛 버전(e7b39a2 이전)에서 올라올 때

그 시절엔 `repos.conf` 가 **추적 파일**이었다. 기기마다 자기 슬롯 경로로 고쳐 쓰기 때문에
`git pull` 이 이렇게 막힌다.

```
error: Your local changes to the following files would be overwritten by merge: repos.conf
```

`reset --hard` 로 밀면 그 기기의 슬롯 설정이 사라진다. 이렇게 한다.

```bash
cd ~/.aside/tools/aside-memory-sync
cp repos.conf ~/.aside/tools/repos.conf.bak
git checkout -- repos.conf
git merge --ff-only origin/main
cp ~/.aside/tools/repos.conf.bak repos.conf
```

지금은 `.gitignore` 가 `repos.conf` 를 잡으므로 한 번만 넘기면 끝이다.

---

## 설치

각 기기에서 한 번씩. 아래 두 줄은 같은 `install.sh` 에 도달한다.

```bash
git clone https://github.com/<you>/aside-memory-sync.git
cd aside-memory-sync
./install.sh
```

```powershell
git clone https://github.com/<you>/aside-memory-sync.git
cd aside-memory-sync
.\install.ps1
```

이후 `<경로>` 는 이 클론의 위치다.

`install.sh`가 하는 일:
- 메모리 폴더 탐지 (여러 슬롯이면 목록을 보여주고 고르게 한다)
- `git init` + `.gitignore` / `.gitattributes` 설치
- 병합 드라이버를 **해당 저장소에만** 등록 (전역 설정 안 건드림)
- 기기 간 직접 push를 위해 `receive.denyCurrentBranch=updateInstead` 설정
- 첫 커밋 생성

> **슬롯 번호는 기기마다 다를 수 있다.** 한쪽의 `u/1`이 다른 쪽에서도 `u/1`이라는 보장이 없다. 번호가 아니라 **내용**이 같은 슬롯끼리 연결해야 한다.

## 기기 연결

SSH로 서로를 remote로 등록한다. 중앙 저장소는 필요 없다.

```bash
# 맥북에서 (맥미니를 remote로)
cd ~/.aside/u/1/memory
git remote add other macmini:/Users/junny/.aside/u/1/memory
```

```powershell
# 맥북에서 (맥미니를 remote로)
cd ~/.aside/u/1/memory
git remote add other macmini:/Users/junny/.aside/u/1/memory
```

처음 한 번은 두 저장소의 뿌리가 달라 아래가 필요하다. `sync.sh`가 자동으로 감지해서 붙여준다:

```bash
git merge other/main --allow-unrelated-histories
```

```powershell
git merge other/main --allow-unrelated-histories
```

### 중앙 허브 방식 (기기 3대 이상이면 권장)

항상 켜져 있는 서버가 있다면 `hub-setup.sh` / `hub-setup.ps1` 한 번이면 끝난다:

```bash
cd ~/.aside/u/<슬롯>/memory
bash <경로>/hub-setup.sh <ssh호스트>
```

```powershell
cd ~/.aside/u/<슬롯>/memory
<경로>\hub-setup.ps1 <ssh호스트>
```

bare 저장소 생성, remote 등록, 첫 병합과 push 까지 알아서 한다. 나머지 기기에서도 같은 명령을 쓰면 된다.

P2P 와의 차이:

| | P2P | 중앙 허브 |
|---|---|---|
| 상대 기기 전원 | 켜져 있어야 함 | 무관 |
| 연결 수 (N대) | N×(N-1)/2 | N |
| 백업 | 없음 | 허브가 겸함 |

`sync.sh` 는 `hub` 라는 이름의 remote 가 있으면 자동으로 그걸 고른다.

수동으로 하려면:

```bash
ssh myserver 'git init --bare -b main ~/git/aside-memory.git'
git remote add hub myserver:~/git/aside-memory.git
git push -u hub main
```

```powershell
ssh myserver 'git init --bare -b main ~/git/aside-memory.git'
git remote add hub myserver:~/git/aside-memory.git
git push -u hub main
```

> 허브에는 개인 기억이 평문으로 올라간다. 신뢰하는 서버에만 두고,
> 여러 사람이 쓰는 서버라면 최소한 `chmod 700` 은 해두어라 (`hub-setup.sh` 가 자동으로 한다).

## 사용

`sync.sh` 는 어느 OS에서도 메모리 저장소에 복사되지 않는다. 메모리 폴더에서, 이 저장소 경로로 호출한다.

```bash
cd ~/.aside/u/<슬롯>/memory
bash <경로>/sync.sh --dry-run   # 뭐가 오갈지만 확인
bash <경로>/sync.sh             # 커밋 -> fetch -> 병합 -> push
bash <경로>/sync.sh --yes       # 확인 프롬프트 없이 (스케줄러/스크립트용)
```

```powershell
cd ~/.aside/u/<슬롯>/memory
<경로>\sync.ps1 --dry-run
<경로>\sync.ps1
<경로>\sync.ps1 --yes
```

충돌이 남으면 이렇게 멈춘다:

```
[!] 자동 병합이 끝나지 않았다. 판단이 필요한 파일:
    projects/omo-desktop-macos.md
```

해당 파일의 `<<<<<<<` 구간만 정리하고:

```bash
git add projects/omo-desktop-macos.md
git commit
bash <경로>/sync.sh
```

```powershell
git add projects/omo-desktop-macos.md
git commit
<경로>\sync.ps1
```

---

## 자동 동기화 (여러 저장소 한꺼번에)

메모리 말고도 같이 동기화할 저장소가 있다면 `autosync.sh` / `autosync.ps1` 을 쓴다.
손으로 돌려도 되고, 스케줄러에 올려두어도 된다.

```bash
cp repos.conf.example repos.conf   # 경로를 자기 기기에 맞게 수정
./autosync.sh --status             # 현재 상태
./autosync.sh --dry-run            # 무엇이 오갈지
./autosync.sh                      # 전부 병렬 동기화
./autosync.sh wiki                 # 하나만
```

```powershell
Copy-Item -LiteralPath repos.conf.example -Destination repos.conf
.\autosync.ps1 --status
.\autosync.ps1 --dry-run
.\autosync.ps1
.\autosync.ps1 wiki
```

`repos.conf` 형식은 `이름|경로|remote|충돌전략` 이다. 경로는 정슬래시만 쓴다. 슬롯은 기기마다 다르니 이 기기의 실제 경로를 적어라:

```
memory|~/.aside/u/0/memory|hub|driver
wiki|~/kim_wiki|clisu|manual
```

### 충돌 전략이 두 개인 이유

저장소마다 글의 성격이 다르다. Aside 메모리는 에이전트가 쌓는 append-only 기록이라
구조를 이용해 자동 병합할 수 있지만, 사람이 쓴 문서는 그러면 내용이 섞인다.

- `driver` — 구조 인식 병합을 거친다. 일별 로그나 History 는 자동으로 합쳤지고,
  그래도 남는 것만 보류된다.
- `manual` — 충돌이 나면 **병합을 되돌리고** 사람을 부른다.

둘 다 핵심은 같다: **자동 실행이 저장소를 충돌 상태로 방치하지 않는다.**
반쯤 병합된 채로 다음 실행이 돌면 피해가 누적된다.

### 주기 실행 등록

```bash
./install-autosync.sh 15      # 15분마다 (macOS launchd / Linux cron / Windows Task Scheduler)
./install-autosync.sh --remove
tail -f ~/.aside/tools/.autosync/autosync.log
```

```powershell
.\install-autosync.ps1 15
.\install-autosync.ps1 --remove
Get-Content -LiteralPath "$env:USERPROFILE\.aside\tools\.autosync\autosync.log" -Wait
```

부담이 거의 없다. 변경이 없으면 fetch 한 번으로 끝나고(실측 0.5초),
`Nice 10` + `LowPriorityIO` 로 돌아 전면 작업을 방해하지 않는다.
저장소당 잠금이 있어 실행이 겹쳐도 안전하며, 30분 넘은 잔류 잠금은 자동으로 정리된다.

GitHub 같은 보조 remote 에도 함께 보내려면:

```bash
git config aside.sync.mirror origin
```

```powershell
git config aside.sync.mirror origin
```

## 에이전트에게 충돌 해결 맡기기

남는 충돌은 대부분 "두 서술 중 무엇이 참인가" 문제라, 에이전트가 판단하기 좋은 형태다. `AGENT.md`에 그대로 붙여넣을 수 있는 프롬프트가 있다.

```bash
# 예: Claude Code / Codex 등에 넘기기
cat AGENT.md; git diff --diff-filter=U
```

```powershell
# 예: Claude Code / Codex 등에 넘기기
Get-Content -LiteralPath AGENT.md; git diff --diff-filter=U
```

## 주의

- **동기화는 에이전트가 작업 중이 아닐 때 하라.** `sync.sh`가 최근 1분 내 인덱스 갱신을 감지하면 경고한다.
- **`.history.jsonl`과 컨텍스트 인식 기록은 기본 제외다.** 화면 OCR/입력 캡처가 켜져 있었다면 민감한 내용이 들어있을 수 있다. 공유 전에 무엇이 올라가는지 확인하라.
- pull 후 Aside 데몬이 마크다운 변경을 감지해 벡터 인덱스를 자동 재생성한다. 별도 조치가 필요 없다.
- 저장소는 **비공개(private)로 두라.** 개인 기억이 그대로 들어있다.

## 요구사항

- Git 2.x, Python 3.8+, Bash 3.2+ (macOS 기본 bash 그대로 동작)
- macOS / Linux / Windows

## Windows 요구사항

- Git for Windows. bash 는 여기에 들어 있는 Git Bash 를 쓴다.
- 실제 CPython 3.8+, 또는 Aside 동봉 런타임. Microsoft Store 스텁은 안 된다.
- 주기 실행은 Task Scheduler.
- 구현은 `.sh` 하나다. `.ps1` 은 그 구현으로 들어가는 1급 진입점이다.
- `sync.sh` / `sync.ps1` 은 어느 OS에서도 메모리 저장소에 복사되지 않는다. 항상 이 저장소 경로로 호출한다.

## 실전 기록

맥북 2대 + 맥미니를 한 계정으로 묶어 본 결과와, 그 과정에서 알게 된 것들.

**슬롯 번호는 기기마다 다르다.** 같은 계정이 한쪽엔 `u/1`, 다른 쪽엔 `u/0` 이었다.
번호로 짐짓하지 말고 `userId` 로 확인해라:

```bash
jq -r '.accounts[] | "slot=\(.id)  \(.email)  \(.userId)"' ~/.aside/accounts.json
```

```powershell
(Get-Content -Raw -LiteralPath "$env:USERPROFILE\.aside\accounts.json" | ConvertFrom-Json).accounts |
  ForEach-Object { "slot=$($_.id)  $($_.email)  $($_.userId)" }
```

**용량은 겁낼 것 없다.** 한 기기의 메모리 폴더가 558MB 였지만, 그중 525MB 는
`.history.jsonl`, 27MB 는 `.moss-cache` 였다. 둘 다 gitignore 대상이라 실제 동기화된
마크다운은 2.6MB, `.git` 은 1.5MB 에 그쳤다.

**자동 병합이 거의 다 처리했다.** 세 기기를 합치는 데 남은 충돌은 `TAXONOMY.md` 하나뿐이었다.
같은 날짜의 일별 로그 3개와 `USER.md` / `MEMORY.md` 는 전부 자동으로 합쳐졌다.

**한쪽을 버리기 전에 상위집합인지 확인해라.** 고유 내용이 없는지 먼저 본 다음 결정하는 게 안전하다:

```bash
ours=$(mktemp)
theirs=$(mktemp)
git show :2:FILE > "$ours"
git show :3:FILE > "$theirs"
comm -23 <(sort -u "$ours") <(sort -u "$theirs")   # 비어있으면 theirs 가 상위집합
```

```powershell
$ours = New-TemporaryFile
$theirs = New-TemporaryFile
git show :2:FILE | Set-Content -LiteralPath $ours.FullName -Encoding utf8
git show :3:FILE | Set-Content -LiteralPath $theirs.FullName -Encoding utf8
Compare-Object (Get-Content -LiteralPath $ours.FullName | Sort-Object -Unique) (Get-Content -LiteralPath $theirs.FullName | Sort-Object -Unique) |
  Where-Object { $_.SideIndicator -eq '<=' }
# 결과가 비어 있으면 theirs 가 상위집합
```

**되돌릴 수 있게 해두어라.** 첫 동기화 전 세 기기에 태그를 박아두면 마음이 편하다:

```bash
git tag pre-sync-$(date +%Y%m%d-%H%M%S)
# 문제 생기면: git reset --hard pre-sync-<타임스탬프>
```

```powershell
git tag "pre-sync-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
# 문제 생기면: git reset --hard pre-sync-<타임스탬프>
```

## 라이선스

MIT
