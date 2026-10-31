# 캐시 매니저 (`squid-sim --manager`)

`scripts/squid-sim --manager`(줄여서 `-m`)는 **실행 중인 squid의 캐시 매니저**를 읽어 보여주거나, 정해진 시간 동안
기록해 리포트를 만듭니다. `curl http://127.0.0.1:8090/squid-internal-mgr/ipcache`로 하던 일을 한 명령으로 하되,
localhost처럼 의미 없는 항목은 빼고 보여줍니다. squid에는 읽기 전용 HTTP GET만 보내며, 설정이나 상태를 바꾸는
매니저 동작(`shutdown`, `reconfigure`, `rotate`, `offline_toggle`)은 호출하지 않습니다.

## 준비

| 항목 | 내용 |
|---|---|
| 실행 위치 | squid와 같은 서버 (매니저는 기본적으로 localhost에서만 허용) |
| squid.conf | `http_access allow localhost manager` (Ubuntu 기본 설정에 이미 있음) |
| 주소 | 기본은 `/etc/squid/squid.conf`의 첫 `http_port`. 다르면 `--url http://127.0.0.1:8090`, 또는 [squid-sim.conf](LOGFORMAT.md)의 `manager_url`에 적어 둠 |
| 비밀번호 | `cachemgr_passwd`를 쓰면 환경 변수에 넣고 `--password-env 변수명` (명령줄에 비밀번호를 쓰지 않음) |
| 필요한 것 | Python 3.8 이상 (표준 라이브러리만 사용). 패치한 squid 빌드는 필요 없음 |

## 사용법

```bash
scripts/squid-sim -m                                    # 주요 페이지 요약 (필터 적용)
scripts/squid-sim -m --page ipcache                     # 한 페이지만 (curl …/squid-internal-mgr/ipcache 대신)
scripts/squid-sim -m --page ipcache --raw               # squid가 주는 원문 그대로
scripts/squid-sim -m --url http://127.0.0.1:8090        # 다른 포트의 squid
scripts/squid-sim -m --report 60m                       # 60분 동안 60초마다 기록 → 리포트
scripts/squid-sim -m --report 2h --interval 30s --out /var/tmp/squid-report
SQUID_MGR_PW='…' scripts/squid-sim -m --password-env SQUID_MGR_PW --report 60m
```

| 옵션 | 기본값 | 뜻 |
|---|---|---|
| `--manager`, `-m` | | 매니저 모드 (없으면 나머지 인자를 패치한 squid로 넘겨 시뮬레이터 실행) |
| `--url` | `--conf`의 첫 `http_port` | squid 주소 |
| `--conf` | squid-sim.conf의 `squid_conf` (기본 `/etc/squid/squid.conf`) | `--url`을 추측할 설정 파일 |
| `--page` | info, counters, client_list, ipcache, fqdncache, active_requests | 볼 페이지 (쉼표로 여러 개) |
| `--raw` | | 필터 없이 원문 출력 |
| `--report` | | 기록 시간. `60m`, `1h`, `30s`, `1h30m`, 숫자만 쓰면 분 |
| `--interval` | `60s` | 기록 중 조회 간격 |
| `--out` | `./manager-report-YYYYmmdd-HHMMSS` | 리포트 폴더 |
| `--include-local` | | 아래의 제외 규칙을 끔 |
| `--password-env` | squid-sim.conf의 `manager_password_env` | `cachemgr_passwd` 비밀번호가 든 환경 변수 이름 |

기록은 Ctrl-C로 일찍 끝낼 수 있고, 그때까지 모은 데이터로 리포트를 씁니다. 조회 결과는 매번 `snapshots.jsonl`에
바로 저장되므로 중간에 끊겨도 데이터가 남습니다.

## 제외하는 항목

| 대상 | 제외 기준 | 이유 |
|---|---|---|
| 클라이언트 (`client_list`) | 127.0.0.0/8, `::1`, 그리고 이 스크립트가 squid에 연결할 때 쓰는 주소 | 매니저 조회 자신과 서버 내부 점검 (IP를 지정한 `http_port`로 조회해도 자기 조회가 섞이지 않도록) |
| DNS (`ipcache`) | `H` 플래그(`/etc/hosts` 고정 항목), `localhost`·`ip6-*` 이름, IP 리터럴 | 조회 결과가 아니라 고정값 |
| 역방향 DNS (`fqdncache`) | `H` 플래그, loopback 주소 | 같은 이유 |
| 진행 중 요청 (`active_requests`) | `/squid-internal-mgr/` URL, loopback 클라이언트 | 매니저 조회 자신 |
| 요청 수 (`counters`) | 이 스크립트가 보낸 매니저 요청 수와 전송량을 구간마다 뺌 | 기록 자체가 트래픽으로 잡히지 않도록 |

localhost에서 프록시를 거친 요청이라도 그 요청이 만든 **DNS 항목은 남깁니다.** 어떤 도메인을 조회했는지는
의미 있는 정보이기 때문입니다.

## 리포트

`--report`가 끝나면 `--out` 폴더에 세 파일이 생깁니다.

| 파일 | 내용 |
|---|---|
| `report.html` | 외부 파일 없이 열리는 HTML 한 파일 (라이트/다크) |
| `summary.txt` | 같은 내용의 텍스트 요약 |
| `snapshots.jsonl` | 조회마다 한 줄씩, 필터를 적용한 원자료 (JSON) |

| 섹션 | 계산 방법 |
|---|---|
| 요약 카드 | 요청 수, 분당 평균·최대, 오류, 클라이언트 수, DNS 이름 수, DNS 실패 수 |
| 분당 요청 | `counters`의 `client_http.requests` 차이를 구간 길이로 나눔 (매니저 요청 제외). squid가 재시작한 구간(가동 시간이나 요청 수가 줄어듦)은 빼고 요약에 재시작 횟수를 적음 |
| 클라이언트 | 이웃한 조회 사이에 늘어난 요청 수와 결과 코드 (`TCP_DENIED` 등)를 더함. 새로 나타났거나 재시작 등으로 수가 줄어든 클라이언트는 0부터 계산 |
| DNS | 기록 중 캐시에 있던 이름과 주소. **new** = 기록 시작 때 없던 이름, **failed** = 조회 실패로 음성 캐시된 이름 |
| 역방향 DNS | `fqdncache`의 주소 → 이름 |
| 진행 중 요청 | 조회 순간마다 진행 중이던 요청 중 가장 오래된 것 (긴 다운로드, 멈춘 연결 찾기) |
| 자원 | 최대 메모리, 파일 디스크립터, 저장 메모리, CPU의 최소·최대·마지막 값 |

`errors`는 Squid의 `client_http.errors`로, 차단(`TCP_DENIED`)과 DNS 실패 같은 오류 응답을 모두 셉니다.

## 실행 중인 squid에 주는 영향

| 항목 | 내용 |
|---|---|
| 보내는 요청 | 조회마다 페이지 수(기본 6개)만큼 HTTP GET. 60분·60초 간격이면 약 360개 |
| squid 상태 | 바꾸지 않음. 읽기 전용 페이지만 요청 |
| access.log | 매니저 요청이 127.0.0.1의 요청으로 기록됨. 남기기 싫으면 `access_log daemon:/var/log/squid/access.log simulformat !manager` |
| 부하 | 페이지 생성은 캐시 크기에 비례. `ipcache`가 수만 개 항목이면 조회 간격을 늘리세요 |

시뮬레이터(`--simulate`, `--optimize`) 쪽의 영향 검증 결과는 [VERIFICATION.md](VERIFICATION.md)에 있습니다.

## 버전별 차이

squid 5 이후의 SMP 대응 페이지는 `by kid1 { … } by kid1`처럼 워커별 블록으로 나뉩니다. 스크립트는 블록을 모두 읽어
합치므로(클라이언트 요청 수는 더하고, DNS 항목은 합집합) squid 4.10과 7.7에서 같은 형식의 결과를 냅니다.
