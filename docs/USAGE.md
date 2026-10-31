# 사용법

빌드한 `build/squid-<버전>/src/squid` 하나에 옵션으로 붙어 있습니다. `scripts/squid-sim`으로 실행하면 이 바이너리를 찾아
인자를 그대로 넘기므로, 아래 예시의 `./squid` 자리에 `scripts/squid-sim`을 써도 됩니다. `-f`로 준 squid.conf가 "현재" 설정입니다.
실행 중인 squid의 캐시 매니저를 조회·기록하는 `scripts/squid-sim -m`은 [MANAGER.md](MANAGER.md)에 있습니다.
설치(`make install`)는 필요 없고, 실행 중인 squid와 동시에 돌려도 됩니다 (포트를 열지 않음).

## 로그 준비

squid 바이너리(`--simulate`)는 아래 `simulformat` 한 가지를 필드 **위치로** 읽습니다. `scripts/squid-sim`으로 실행하면
다른 형식(squid 기본 `squid` 형식, `combined`, 사이트별 `logformat`, `.gz`)도 시뮬레이터 설정 파일 `squid-sim.conf`에 따라
판별·변환해 넣으므로, 운영 squid.conf를 바꿀 필요는 없습니다. 형식 정의와 판별 규칙은 [LOGFORMAT.md](LOGFORMAT.md)에 있습니다.
아래 형식은 시뮬레이터가 쓰는 필드를 모두 담고 있어 가장 정확합니다.

```
logformat simulformat %tl %la %>a  "%rm %ru HTTP/%rv" %>Hs %<st %Ss:%Sh
access_log daemon:/var/log/squid/access.log simulformat
```

| 필드 | 뜻 | 시뮬레이터에서의 쓰임 |
|---|---|---|
| `%tl` | 프록시 현지 시각 (`31/Oct/2026:09:59:01 +0900`) | `acl time` 평가 시각, 타임존 |
| `%la` | 프록시의 로컬 IP | `localip`/`myip` |
| `%>a` | 클라이언트 IP | `src`, `srcdomain` |
| `%rm %ru HTTP/%rv` | 메서드, URL, HTTP 버전 | `method`, `dstdomain`, `dst`, `port`, `url_regex` 등 |
| `%>Hs %<st` | 응답 상태, 크기 | 출력에만 사용 |
| `%Ss:%Sh` | Squid 결과 코드 (`TCP_DENIED` 등) | 시뮬레이션 결과와 비교 (`same`/`DIFF`) |

## 옵션

| 옵션 | 인자 | 하는 일 |
|---|---|---|
| `--simulate` | 로그 파일 또는 `-`(stdin) | 로그 전체를 `http_access`에 재생 |
| `--sim-compare` | 새 squid.conf 경로 | 같은 로그를 새 설정으로도 재생해 달라진 요청만 출력 |
| `--report` | HTML 출력 경로 | 단일 HTML 리포트 작성 (요청별 터미널 출력은 생략) |
| `--optimize` | 없음 | 설정 정적 분석. `--simulate`가 있으면 로그 기반 분석 추가 |
| `--sim-trace` | 없음 | 요청마다 규칙·ACL별 평가 과정 출력 |
| `--sim-dns` | `off`(기본) 또는 `system` | DNS가 필요한 ACL 처리. off는 `hosts_file`만, system은 OS 리졸버로 동기 조회 |
| `--sim-port` | 포트 | 가짜 요청의 로컬 포트 (기본: 첫 `http_port`) |

## 1. 요청별 판정

```bash
./squid -f /etc/squid/squid.conf --simulate /var/log/squid/access.log
```

```
      4  DENY   http_access#3     10.0.0.5  GET http://x.ads.example.com/a.js  (log TCP_DENIED/403: same)
           decided by: http_access deny blocked
           matching:   #3 deny > #5 allow > #10 deny   | without #3: ALLOW by http_access#5
```

- `decided by`: 판정한 규칙의 squid.conf 원문. 어떤 규칙도 매칭되지 않으면 `implicit`(마지막 규칙의 반대 동작).
- `matching`: 이 요청에 매칭되는 **모든** 규칙을 순서대로. DENY라면 뒤쪽의 `allow`가 "막히지 않았다면 허용했을 규칙"입니다.
- `without #3`: 판정 규칙을 지웠을 때의 결과.
- `(log …)`: 로그의 `%Ss`와 비교. `same`, `DIFF`, `UNSURE`(오프라인 판정 불가 ACL 포함), `n/a`(비교 불가).
- `not evaluable offline`: 로그에 없는 정보(헤더, 인증, helper, DNS)가 필요한 ACL 목록.

끝에 규칙별 `decided`(판정 수), `also-matched`(매칭됐지만 앞 규칙이 먼저 판정), `never decides`가 요약됩니다.

## 2. 설정 비교

```bash
./squid -f /etc/squid/squid.conf --simulate access.log --sim-compare /tmp/squid.new.conf
```

```
      9  ALLOW -> DENY   VERDICT  10.0.0.5  GET http://www.facebook.com/
           current: #5       http_access allow localnet
           new:     #4       http_access deny social
```

`VERDICT` = 허용/차단 자체가 바뀜, `rule` = 판정은 같고 판정 규칙만 바뀜. 규칙 번호는 밀릴 수 있으므로 원문 기준으로 비교합니다.
마지막에 `ALLOW #5 -> DENY #4` 같은 전이 유형별 건수가 나옵니다.

## 3. HTML 리포트

```bash
./squid -f /etc/squid/squid.conf --simulate access.log --sim-compare /tmp/squid.new.conf --optimize --report report.html
```

외부 파일이 필요 없는 HTML 한 파일(라이트/다크). 요약 카드, 최적화 결과, 변경 내역, 규칙별 판정 막대,
차단 규칙별 상위 목적지·클라이언트·대신 허용했을 규칙, 검색·필터가 되는 요청 표(규칙 클릭 시 trace), 로그와의 불일치 목록.

## 4. 최적화

```bash
./squid -f /etc/squid/squid.conf --optimize
./squid -f /etc/squid/squid.conf --optimize --simulate access.log   # 로그 기반 항목 추가
```

| 심각도 | 항목 | 판단 근거 |
|---|---|---|
| HIGH | `unreachable rule` | 앞 규칙의 ACL 집합이 이 규칙 ACL 집합의 부분집합이고 동작이 반대 |
| HIGH | `rule never matches` | `X`와 `!X`를 함께 요구, 또는 `!all` |
| MEDIUM | `redundant rule` | 위와 같되 동작이 같음 (마지막 규칙이라 기본값을 바꾸면 LOW + "유지") |
| MEDIUM | `built-in ACL redefined` | `all`, `manager`, `localhost`, `to_localhost`, `ssl::*` 재선언 |
| MEDIUM | `matches everything` | `.*`, `.`, `^` 정규식 |
| MEDIUM | `never decides in the log` | 로그에서 매칭은 됐지만 항상 앞 규칙이 판정 |
| LOW | `covered by a wider entry` | `.example.com`이 `www.example.com`을, `10.0.0.0/8`이 `10.1.0.0/16`을 포함 |
| LOW | `duplicate entry` | 같은 도메인·IP·정규식이 두 번 |
| LOW | `unused ACL` | 어떤 지시어나 ACL도 참조하지 않음 |
| LOW | `identical ACLs` | 타입·옵션·값이 같은 다른 이름 |
| LOW | `repeated ACL in rule`, `redundant 'all'` | 한 규칙 안 반복, 다른 조건과 함께 쓴 `all` |
| LOW | `no logged request matches` | 로그의 어떤 요청에도 매칭되지 않음 |

## 정확도를 높이려면

- `dst` 계열을 쓰면 squid.conf 사본에 `hosts_file`을 지정해 이름→IP를 고정하세요.
- 포트별로 `localport`/`myportname`을 쓰면 로그를 포트별로 나눠 `--sim-port`를 주세요.
- 운영 cache.log에 파싱 경고가 섞이지 않게 하려면 사본 설정에서 `cache_log`를 바꾸세요.
