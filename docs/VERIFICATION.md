# 검증 결과 (ubuntu-26.04-squid-7.7: Ubuntu 26.04 / squid 7.7)

2026-10-31 기준, squid 7.7 이식 패치는 **Ubuntu 26.04.1 LTS 실기**에서 `scripts/verify-target.sh` 전체를 통과했습니다.
빌드, Squid 7.7 자체 단위 테스트, 기능 테스트 37개, 배포판 squid 7.7과의 `-k parse` 비교가 모두 통과입니다.

## 2단계: Ubuntu 26.04 실기 검증 (완료)

| 항목 | 값 |
|---|---|
| OS | Ubuntu 26.04.1 LTS (커널 7.0.0-42), 4코어, 메모리 3 GB |
| 배포판 squid | `7.7-0ubuntu0.26.04.1` (`--with-gnutls`), `apt-get install squid`로 설치 |
| 컴파일러 | g++ 15.2.0 (Ubuntu 15.2.0-16ubuntu1) |
| 절차 | GitHub에서 이 브랜치를 새로 clone → `scripts/verify-target.sh` (빌드 패키지 설치 포함) |

| 단계 | 결과 |
|---|---|
| OS·버전 확인 | Ubuntu 26.04, 설치된 squid 7.7 — 브랜치 대상과 일치 |
| 소스·패치 | 업스트림 tarball SHA-256 일치, Ubuntu 패치 4개와 시뮬레이터 패치 충돌 없음 |
| 빌드 | 성공, squid 7.7 기본 플래그(`-Wall -Wextra -Wshadow -Wmissing-declarations -Werror`) 경고 0 |
| `make check` | 테스트 프로그램 103개 PASS, FAIL 0, ERROR 0 |
| 기능 테스트 | 37개 모두 통과 (공통 33개 + 7.x 전용 최적화 검사 4개). 공통 33개에는 로그 형식 변환 검사 5개(`squid` 형식 자동 판별, gzip, squid-sim.conf에 정의한 형식)가 포함 |
| 실제 로그 | 기본 설정 squid의 `squid` 형식 access.log 176줄을 설정 파일 없이 `sudo scripts/squid-sim`으로 자동 판별·재생, 실제 로그와 다른 판정 0건 |
| `-k parse` 비교 | `tests/squid.conf`, `tests/squid-new.conf`, `/etc/squid/squid.conf` 모두 배포판 squid와 같은 결과(0) |
| 기본 설정 최적화 | 배포판 `/etc/squid/squid.conf`의 `localnet`을 "사용하지 않는 ACL"로 보고. 기본 설정은 `http_access allow localnet`이 주석 처리되어 있어 정확한 결과 |

1단계에서 남겨둔 두 가지도 26.04에서 확인했고, 그 내용을 `tests/optimize-extra.conf` 자동 테스트로 고정했습니다.

- `src 0.0.0.0/0`을 모든 요청에 매칭되는 ACL로 인식해, 뒤 규칙을 중복(MEDIUM)·도달 불가(HIGH)로 보고
- squid 7의 범위 병합(`10.1.0.0-10.1.0.100` + `10.1.0.50-10.1.0.200`)을 `overlapping entries`로, 병합 결과 `10.1.0.0-10.1.0.200`과 함께 보고
- `10.0.0.128/24`가 마스크 적용 후 `10.0.0.0/24`와 같은 값이 되는 것을 중복으로 보고

## 실행 중인 squid에 주는 영향

26.04 머신의 실행 중인 배포판 squid 7.7 옆에서, 실제 `/etc/squid/squid.conf`로 `--simulate`와 `--optimize`를 일반 사용자와
root로 실행하며 `strace -f`로 네트워크·시그널·프로세스·파일 시스템 호출을 기록했습니다.

| 확인 항목 | 일반 사용자 | root |
|---|---|---|
| squid 서비스 PID·시작 시각·재시작 횟수 | 변화 없음 | 변화 없음 |
| cache.log 크기, access.log 줄 수 | 변화 없음 | 변화 없음 |
| 시그널 전송 (`kill`, `tgkill`) | 0 | 0 |
| TCP/UDP connect·listen | 0 | 0 |
| 그 밖의 소켓 | `[::1]:0` IPv6 확인 1개, netlink 인터페이스 조회, nscd 사용자 조회 | 같음 |
| 쓰기로 연 파일 | 0 | 0 |
| 공유 메모리, 자식 프로세스 | 0 | 0 |

squid 7.7은 `cache_log`를 시뮬레이터가 갈라진 뒤 단계(`mainInitialize`)에서 열기 때문에 root로 실행해도 cache.log를 열지
않습니다. `scripts/verify-target.sh`가 이 결과를 매번 다시 확인합니다.

## 캐시 매니저 (`scripts/squid-sim -m`)

26.04 머신의 squid 7.7을 3분 동안 20초 간격으로 기록하면서 트래픽을 보냈습니다.

| 보낸 트래픽 | 리포트 결과 |
|---|---|
| 로컬 요청 40개 + 다른 서버에서 온 요청 32개 | 요청 72개 (매니저 조회 자신은 빠짐) |
| 다른 서버(192.168.50.25)의 요청 32개, 기본 설정이라 모두 차단 | 클라이언트 1개, `TCP_DENIED 32`. localhost는 목록에 없음 |
| 실제 도메인 4개, 없는 도메인 8개 | DNS 12개, 그중 실패 8개. 모두 "기록 중 새로 생김"으로 표시 |

squid 7의 워커별 출력(`by kid1 { … } by kid1`)도 squid 4.10과 같은 결과로 합쳐지는 것을 확인했습니다.

## 1단계: Ubuntu 20.04에서 7.7 이식 확인 (완료)

| 항목 | 값 |
|---|---|
| OS | Ubuntu 20.04.6 LTS, 4코어, 메모리 3 GB |
| 컴파일러 | g++ 9.4.0, `-std=c++17` |
| 소스 | `squid-7.7.tar.xz` (SHA-256 `e3bd613b…5da9b`, Ubuntu `squid_7.7.orig.tar.xz`와 동일) |
| Ubuntu 패치 | `7.7-0ubuntu0.26.04.1`의 0001, 0006, 90, 99 적용 |
| 경고 플래그 | squid 7.7 기본값 `-Wall -Wextra -Wimplicit-fallthrough=5 -Wshadow -Wmissing-declarations -Werror` |

| 단계 | 결과 |
|---|---|
| 패치 적용 (Ubuntu 패치 4개 다음) | 17개 파일, 충돌 없음 |
| 빌드 | 첫 빌드에서 7.7에서 쓰지 않게 된 함수 1개가 `-Werror` 오류. 제거 후 성공 |
| Squid 단위 테스트 `make check` | 테스트 프로그램 103개 PASS, FAIL 0, ERROR 0 |
| 기능 테스트 `scripts/test.sh` | 공통 검사 모두 통과. squid 4.10 브랜치와 같은 결과 |
| 패치 재현성 | 저장소의 패치를 새로 적용한 소스가 테스트한 소스와 17개 파일 모두 동일 |

## 재현 방법

```bash
sudo apt-get install squid          # 배포판 squid 7.7 (비교 대상)
git clone -b ubuntu-26.04-squid-7.7 https://github.com/hyeonsa-claude/squid-simulator.git
cd squid-simulator && scripts/verify-target.sh
```

스크립트는 OS·squid 버전 확인 → 빌드 패키지 설치(sudo) → 빌드 + `make check` → 기능 테스트 → 배포판 squid와
`-k parse` 비교 순으로 실행하고, 마지막 줄에 `VERIFICATION PASSED`를 출력합니다.

## 한계

`main` 브랜치의 [VERIFICATION.md](https://github.com/hyeonsa-claude/squid-simulator/blob/main/docs/VERIFICATION.md#한계)와 같습니다.
7.7에서 `ident` ACL이 없어졌고, `annotate_client`, `annotate_transaction`, `squid_error`, `connections_encrypted`,
`snmp_community`가 로그로 판단할 수 없는 타입에 추가되었습니다.
