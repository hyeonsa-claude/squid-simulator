# 검증 결과 (main: Ubuntu 20.04 / squid 4.10)

2026-10-31 기준, 이 브랜치의 패치는 공식 squid 4.10 릴리스에서 `-Werror` 빌드, Squid 자체 단위 테스트, 시뮬레이터 기능 테스트를 모두 통과했습니다.

## 환경

| 항목 | 값 |
|---|---|
| OS | Ubuntu 20.04.6 LTS (커널 5.4.0-216), 4코어, 메모리 3 GB |
| 배포판 squid | 4.10 (Ubuntu 패키지, 실행 중인 서비스는 건드리지 않음) |
| 컴파일러 | g++ 9.4.0 |
| 소스 | `squid-4.10.tar.gz` (SHA-256 `df0685e8…a1c8f`) |
| configure | Ubuntu 패키지의 핵심 옵션 (`scripts/target.env`), Squid 기본값인 `-Wall -Wshadow -Werror` |

## 결과

| 단계 | 명령 | 결과 |
|---|---|---|
| 패치 적용 | `patch -p1` (공식 tarball) | 18개 파일, 오프셋·퍼지 없이 적용 |
| 빌드 | `scripts/build.sh` | 성공, 경고 0 (`-Werror`) |
| Squid 단위 테스트 | `make check` | 테스트 프로그램 94개 PASS, FAIL 0, ERROR 0 (헤더 단독 컴파일 테스트 포함) |
| 설정 파싱 | `squid -k parse` | 패치 전과 같이 성공 |
| 요청별 판정 | `scripts/test.sh` [simulate] | 12줄 모두 기대한 판정·판정 규칙·로그 비교 결과 |
| 매칭 규칙 목록 | 〃 | 차단 요청에서 뒤의 allow 규칙까지 표시 |
| 설정 비교 | 〃 [compare] | 기대한 3줄(판정 변경 2, 규칙만 변경 1)만 변경으로 보고 |
| 최적화 | 〃 [optimize] | 기대한 8개 항목 모두 보고 |
| ACL 값 비교 | 〃 [optimize] (`tests/optimize-overlap.conf`) | 도메인·주소 포함으로 가려진 규칙, `!A` 뒤의 공통 값 없는 규칙, 부정 조건 포함, 일부 가려진 규칙, 겹치는 ACL, 표기만 다른 동일 ACL, 포함된 ACL 등 기대한 10개 항목 모두 보고 |
| HTML 리포트 | 〃 [report] | 필수 섹션 모두 포함 |
| 로그 형식 | 〃 [logformat] | `squid` 형식(자동 판별), gzip, squid-sim.conf에 정의한 형식으로 같은 요청을 재생해 simulformat과 판정이 한 줄도 다르지 않음 |

`scripts/test.sh`의 43개 검사가 모두 통과했습니다. 테스트 로그는 시간 ACL(`02/Nov/2026` 월요일 10:00 +0900과
`31/Oct/2026` 토요일), CONNECT, 비표준 포트, 헤더가 필요한 ACL(UNSURE), 파싱 불가 줄, 로그와 다른 판정(DIFF)을 포함합니다.
테스트 서버의 타임존은 UTC여서, 시간 ACL 테스트는 로그의 +0900 오프셋을 따르는지도 함께 확인합니다.
실제 squid(기본 설정, `squid` 형식 로그 179줄)도 설정 파일 없이 `sudo scripts/squid-sim`으로 형식을 자동 판별해 재생했고,
실제 로그와 판정이 다른 요청은 0건이었습니다.

## 검증 중 발견해 고친 결함

| 발견 단계 | 결함 | 수정 |
|---|---|---|
| 코드 검토 | `.h` 파일이 `make check` 헤더 테스트에서 `-Werror` 실패 | `AclSimulator.cci`로 변경 |
| 코드 검토 | `external` ACL이 초기화 안 된 helper를 역참조해 크래시 | `external_acl.cc`에 NULL 검사 |
| 코드 검토 | 파싱 노트가 항상 기록되어 운영 squid의 reconfigure마다 메모리 증가 | `--simulate`/`--optimize`에서만 기록 |
| 코드 검토 | 그 밖의 판정·분석 로직 10건 (UNSURE 범위, AUTH 집계, 보편 ACL 오판 등) | 수정 |
| 실행 테스트 | 시뮬레이터 실행 머신에 `mime.conf` 등 설정이 가리키는 파일이 없으면 FATAL 종료 | `-k parse`처럼 경고만 하도록 `opt_simulate` 추가 |
| 실행 테스트 | 기록되는 debug 메시지가 `squid_curtime`을 현재 시각으로 되돌려 `acl time` 재생이 틀릴 수 있음 | 매 판정 직전에 로그 시각 재설정 |
| 실행 테스트 | `deny all` 뒤의 마지막 규칙에 "기본값을 정하므로 유지하라"는 잘못된 권고 | 앞에 무조건 규칙이 있으면 기본값이 쓰이지 않으므로 일반 중복으로 보고 |
| 영향 검증 (strace) | root로 실행하면 설정 파싱 중 운영 `cache_log`를 열고 한 줄을 씀 | 시뮬레이터 모드에서는 `cache_log`를 열지 않고 stderr로만 출력 |

## 실행 중인 squid에 주는 영향

테스트 서버의 실행 중인 squid 4.10(배포판 서비스) 옆에서, 실제 `/etc/squid/squid.conf`로 `--simulate`와 `--optimize`를
일반 사용자와 root로 실행하며 `strace -f`로 네트워크·시그널·프로세스·파일 시스템 호출을 기록했습니다.

| 확인 항목 | 일반 사용자 | root |
|---|---|---|
| squid 서비스 PID·시작 시각·재시작 횟수 | 변화 없음 | 변화 없음 |
| cache.log 크기, access.log 줄 수 | 변화 없음 | 변화 없음 (수정 후) |
| 시그널 전송 (`kill`, `tgkill`) | 0 | 0 |
| TCP/UDP connect·listen | 0 | 0 |
| 그 밖의 소켓 | `[::1]:0` IPv6 확인 1개, netlink 인터페이스 조회, nscd·systemd userdb 사용자 조회 | 같음 |
| 쓰기로 연 파일 | 0 | 0 (수정 전: `/var/log/squid/cache.log` 1개) |
| 공유 메모리, 자식 프로세스 | 0 | 0 |

`scripts/verify-target.sh`는 시뮬레이터 단계 전후의 서비스 PID·시작 시각·재시작 횟수와 cache.log 크기를 비교해
이 결과를 매번 다시 확인합니다.

## 캐시 매니저 (`scripts/squid-sim -m`)

테스트 서버의 squid를 3분 동안 20초 간격으로 기록하면서 트래픽을 보냈습니다.

| 보낸 트래픽 | 리포트 결과 |
|---|---|
| 로컬 요청 40개 (외부 사이트 3곳, 없는 도메인 8개, HTTPS 8개) + 다른 서버에서 온 요청 32개 | 요청 72개 (매니저 조회 자신은 빠짐) |
| 다른 서버(192.168.50.28)의 요청 32개, 기본 설정이라 모두 차단 | 클라이언트 1개, `TCP_DENIED 32`. localhost는 목록에 없음 |
| 실제 도메인 4개, 없는 도메인 8개 | DNS 12개, 그중 실패 8개. 모두 "기록 중 새로 생김"으로 표시. `/etc/hosts` 항목은 없음 |

상태를 바꾸는 페이지(`--page shutdown` 등)는 요청하지 않고 거부하는 것도 확인했습니다.

## 재현 방법

```bash
scripts/verify-target.sh        # OS·버전 확인 → 빌드 + make check → 기능 테스트 → 배포판 squid와 -k parse 비교
```

## 한계

| 종류 | 해당 ACL | 시뮬레이터 표시 |
|---|---|---|
| 로그에 없는 요청 헤더 | `browser`, `referer_regex`, `req_header`, `req_mime_type` | UNSURE |
| 사용자 인증 | `proxy_auth`, `proxy_auth_regex`, `max_user_ip` | AUTH, UNSURE |
| helper·연결 상태 | `external`, `ident`, `maxconn`, `note`, `tag` 등 | UNSURE |
| DNS | `dst`, `srcdomain`, IP URL의 `dstdomain` | `--sim-dns off`: UNSURE, `system`: 현재 DNS 결과 |
| 다른 지시어 | `miss_access`, `adapted_http_access`, `ssl_bump`, `http_reply_access` | 대상 아님. 로그의 `TCP_DENIED`가 여기서 왔다면 DIFF |

- 최적화의 ACL 값 비교는 주소·포트·도메인·메서드·프로토콜·포트 이름 타입만 다룹니다. 정규식·`time`·헤더 계열은 이름이 같을 때만 같은 조건으로 봅니다.
- 운영 squid.conf와 실제 운영 로그로 `DIFF` 비율을 확인하는 검증은 아직 하지 않았습니다. 테스트는 합성 설정과 로그로 했습니다.
