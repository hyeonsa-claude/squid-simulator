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
| HTML 리포트 | 〃 [report] | 필수 섹션 모두 포함 |

`scripts/test.sh`의 28개 검사가 모두 통과했습니다. 테스트 로그는 시간 ACL(`02/Nov/2026` 월요일 10:00 +0900과
`31/Oct/2026` 토요일), CONNECT, 비표준 포트, 헤더가 필요한 ACL(UNSURE), 파싱 불가 줄, 로그와 다른 판정(DIFF)을 포함합니다.
테스트 서버의 타임존은 UTC여서, 시간 ACL 테스트는 로그의 +0900 오프셋을 따르는지도 함께 확인합니다.

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

- 최적화의 도달 불가·중복 규칙 판단은 ACL 이름 집합 기준입니다. 서로 다른 ACL의 값이 겹치는 경우는 찾지 않습니다.
- 운영 squid.conf와 실제 운영 로그로 `DIFF` 비율을 확인하는 검증은 아직 하지 않았습니다. 테스트는 합성 설정과 로그로 했습니다.
