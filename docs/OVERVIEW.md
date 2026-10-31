# 전체 구조와 흐름

이 문서는 저장소의 모든 기능을 그림으로 정리합니다. 각 단계의 자세한 설명은 끝의 문서 목록에 있습니다.

## 1. 구성 요소

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart LR
    U(["사용자"]) --> S["scripts/squid-sim<br/>(Python, 진입점)"]
    C[/"squid-sim.conf<br/>squid_conf · access_log · logformat"/] --> S
    L[/"access.log<br/>(아무 형식, .gz)"/] --> S
    S -->|"simulformat 로그 + 옵션"| B["패치한 squid 바이너리<br/>build/squid-*/src/squid"]
    B --> O1[/"터미널 출력"/]
    B --> O2[/"report.html"/]
    S -->|"-m: 읽기 전용 GET"| R["실행 중인 squid<br/>/squid-internal-mgr/"]
    S --> O3[/"manager report.html<br/>summary.txt · snapshots.jsonl"/]
```

| 구성 요소 | 하는 일 |
|---|---|
| `scripts/squid-sim` | 설정 파일 읽기, 로그 형식 판별·변환, 패치한 squid 실행, 캐시 매니저 조회·기록 |
| `squid-sim.conf` | 대상 squid.conf, 로그 경로, 로그 형식, 매니저 주소 |
| 패치한 squid | 설정 파싱, 요청 재생, 판정, 비교, 최적화 분석, HTML 리포트 |
| `scripts/build.sh` · `test.sh` · `verify-target.sh` | 공식 소스 다운로드·패치·빌드, 기능 테스트, 대상 OS 전체 검증 |

## 2. 패치한 squid 안의 흐름

설정 파싱까지는 운영 squid와 같고, 데몬화·포트 열기·캐시 초기화 전에 시뮬레이터로 갈라집니다.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart TD
    M["main.cc: 옵션 파싱<br/>--simulate · --optimize면 opt_simulate = 1, 노트 수집 켜기"] --> P["squid.conf 파싱<br/>(Squid 원본 파서)"]
    P -. "경고 지점마다" .-> N["Acl::NoteConfig<br/>포함·중복·내장 재정의 노트"]
    P --> G{"--simulate 또는<br/>--optimize?"}
    G -- 아니오 --> D["원래 squid 동작<br/>(데몬, 포트, 캐시)"]
    G -- 예 --> R["AclSimulator::Run()"]
    R --> RL["ReadLog: 로그 → Record"]
    RL --> RC["RunConfig: 요청마다 Evaluate()"]
    RC --> AN{"--optimize?"}
    AN -- 예 --> AZ["Analyze(): 고칠 거리 찾기"]
    AN -- 아니오 --> CP
    AZ --> CP{"--sim-compare?"}
    CP -- 예 --> NP["노트 지우기 → 새 squid.conf 파싱<br/>→ RunConfig → Analyze"]
    CP -- 아니오 --> OUT
    NP --> OUT["출력: 요청별 결과, 요약, 비교, 최적화, report.html"]
```

## 3. 요청 하나의 판정 (Evaluate)

Squid는 첫 매칭 규칙에서 멈추므로, 뒤에서 매칭될 규칙을 찾으려고 같은 요청을 여러 번 평가합니다.

```mermaid
sequenceDiagram
    participant E as Evaluate()
    participant C as ACLChecklist::fastCheck()
    participant T as Acl::Tree::bannedAction()
    participant H as Tracer 훅
    E->>E: Record → HttpRequest (%>a, %la, URL, 메서드, 포트), TZ = 로그 오프셋
    loop 패스 0, 1, 2, ...
        E->>E: 로그 시각을 squid_curtime에 다시 넣기
        E->>C: fastCheck()
        C->>T: 규칙마다 "건너뛸까?"
        T-->>C: 위치 <= SkipRulesThrough면 건너뜀
        C->>H: 노드마다 (부모, 노드, 1/0/-1)
        H-->>E: Steps, Skipped
        E->>E: 승자 규칙 기록, SkipRulesThrough = 승자 위치
    end
    E->>E: 패스 0 = 실제 판정, 나머지 = 매칭 규칙 사슬<br/>패스 0의 Skipped = UNSURE, 로그 %Ss와 비교
```

| 결과 | 뜻 |
|---|---|
| `ALLOW` / `DENY` | 판정과 판정 규칙(`http_access#N`) 또는 `implicit`(어느 규칙도 안 맞아 마지막 규칙의 반대) |
| `matching` | 그 요청에 매칭되는 규칙 전부, 판정 규칙이 없었다면의 결과 |
| `UNSURE` | 로그에 없는 정보(헤더, 인증 등)나 DNS가 필요한 ACL이 판정에 관여 |
| `same` / `DIFF` | 실제 로그의 `%Ss`(TCP_DENIED 여부)와 같은지 |
| `SKIP` | 읽을 수 없는 줄이나 URL |

## 4. 설정 비교 (--sim-compare)

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart LR
    REC[/"Records<br/>(한 번 읽음)"/] --> A["현재 squid.conf로 재생<br/>Runs[0]"]
    REC --> B["새 squid.conf로 재생<br/>Runs[1]"]
    A --> CMP{"판정이나 판정 규칙의<br/>줄 텍스트가 다른가"}
    B --> CMP
    CMP -- 판정 다름 --> V["VERDICT 변경<br/>(newly denied / allowed)"]
    CMP -- 규칙만 다름 --> RU["rule 변경"]
    CMP -- 같음 --> SAME["출력하지 않음"]
```

규칙이 추가되면 번호가 밀리므로 번호가 아니라 규칙 줄 텍스트로 비교합니다.

## 5. 최적화 (--optimize)

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart TD
    N["① 파서 노트<br/>내장 ACL 재정의 · 포함된 값 · 중복 값 · 모든 값에 매칭되는 정규식"] --> A
    A["② ACL 정의<br/>참조 없음 · 같은 타입·옵션·값"] --> V
    V["③ ACL 값 비교 (같은 타입끼리)<br/>ValuesOf → Covers / Shared<br/>동일 · 겹침 · 다른 ACL 안에 포함"] --> R
    R["④ 규칙 한 줄<br/>반복 ACL · X와 !X · !all · 불필요한 all"] --> RC
    RC["⑤ 규칙 포함 판단<br/>앞 규칙이 뒤 규칙을 덮으면 중복(같은 동작) / 도달 불가(반대 동작)"] --> PS
    PS["⑥ 일부 가려진 규칙<br/>반대 동작의 앞 규칙과 ACL 값이 겹침"] --> LG
    LG["⑦ 로그 기반 (--simulate와 함께)<br/>매칭 없음 · 판정한 적 없음"] --> SORT["심각도 순 정렬 → 출력"]
```

### 규칙 포함 판단

앞 규칙의 조건 하나하나가, 뒤 규칙의 어떤 조건으로 보장되면 뒤 규칙은 판정할 기회가 없습니다.

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart TD
    S(["앞 규칙 조건 W, 뒤 규칙 조건 N"]) --> Q1{"N과 W가<br/>같은 조건?"}
    Q1 -- 예 --> YES(["N이면 W"])
    Q1 -- 아니오 --> Q2{"둘 다 긍정이고<br/>N의 값이 모두 W에 있음?"}
    Q2 -- 예 --> YES
    Q2 -- 아니오 --> Q3{"둘 다 부정(!N, !W)이고<br/>W의 값이 모두 N에 있음?"}
    Q3 -- 예 --> YES
    Q3 -- 아니오 --> Q4{"N 긍정, W 부정이고<br/>공통 값이 없음?<br/>(dst · srcdomain 제외)"}
    Q4 -- 예 --> YES
    Q4 -- 아니오 --> NO(["보장 안 됨"])
```

| 타입 | 값 비교 방법 |
|---|---|
| `src`, `dst`, `localip` | IPv4/IPv6 주소 범위 (128비트, 병합 후 이분 탐색) |
| `port`, `localport` | 포트 범위 |
| `dstdomain`, `srcdomain` | `.example.com` = 그 도메인과 하위 도메인 (접미사 조회) |
| `method`, `proto`, `myportname` | 값 집합 |

## 6. 로그 형식 판별과 변환

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart TD
    A["squid-sim.conf 찾기<br/>--sim-conf → $SQUID_SIM_CONF → /etc/squid/squid-sim.conf → 저장소"] --> B["squid.conf 읽기<br/>(include 따라감)"]
    B --> C{"--simulate 있음?"}
    C -- 아니오 --> D["access_log 설정 → squid.conf의 access_log<br/>→ 없으면 /var/log/squid/access.log"]
    C -- 예 --> E
    D --> E{"log_format이 auto?"}
    E -- 아니오 --> F["지정한 형식"]
    E -- 예 --> G["처음 50줄을 후보에 맞춰 봄<br/>squid.conf가 쓰는 형식 → 설정 파일 logformat<br/>→ squid.conf logformat → squid · common · combined · referrer · simulformat"]
    F --> H{"simulformat이고<br/>압축 아님?"}
    G --> H
    H -- 예 --> I["그대로 squid에 전달"]
    H -- 아니오 --> J["임시 폴더에 simulformat으로 변환<br/>줄 번호·주석 유지, 안 맞는 줄은 SKIP"]
    J --> I
```

| 형식에 없을 때 | 대신 쓰는 값 |
|---|---|
| `%la` | `local_ip`, 없으면 주소 없음 (localip ACL이 있으면 경고) |
| `%tl` | `%tg`·`%ts`를 `log_timezone`으로 현지 시각으로, 셋 다 없으면 현재 시각 (경고) |
| `%rm` | URL에 `://`가 있으면 GET, 없으면 CONNECT |

## 7. 캐시 매니저 (squid-sim -m)

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart TD
    A["주소: --url → manager_url → squid.conf의 첫 일반 http_port"] --> B{"--report 기간?"}
    B -- 아니오 --> C["한 번 조회: info · counters · client_list<br/>ipcache · fqdncache · active_requests"]
    C --> F["잡음 제거<br/>loopback 클라이언트 · /etc/hosts · localhost 이름 · 매니저 조회 자신"]
    F --> P["터미널 요약 (--raw면 원문)"]
    B -- 예 --> L["interval마다 counters부터 조회 → 잡음 제거 → snapshots.jsonl에 추가"]
    L --> L2{"기간 끝 또는 Ctrl-C?"}
    L2 -- 아니오 --> L
    L2 -- 예 --> S["구간별 차이 계산<br/>요청 수에서 자기 조회 수를 뺌, 재시작 구간 제외"]
    S --> W[/"report.html · summary.txt"/]
```

`shutdown`, `reconfigure` 같은 상태를 바꾸는 페이지는 보내지 않고 거부합니다.

## 8. 빌드와 검증

```mermaid
%%{init: {"flowchart": {"wrappingWidth": 420}}}%%
flowchart LR
    T["target.env<br/>버전 · SHA-256 · configure 옵션"] --> BU["build.sh<br/>다운로드 → 체크섬 → (26.04: Ubuntu 패치) → 시뮬레이터 패치 → 빌드"]
    BU --> TE["test.sh<br/>판정 · 비교 · 최적화 · ACL 값 비교 · 리포트 · 로그 형식"]
    BU --> MC["make check<br/>Squid 단위 테스트"]
    TE --> VT["verify-target.sh<br/>OS·버전 확인, 배포판 squid와 -k parse 비교,<br/>운영 squid 무영향, 캐시 매니저"]
    MC --> VT
```

## 문서

| 문서 | 내용 |
|---|---|
| [USAGE.md](USAGE.md) | 옵션, 출력 읽는 법, 최적화 항목 전체 |
| [LOGFORMAT.md](LOGFORMAT.md) | squid-sim.conf, 로그 형식 판별과 변환 |
| [MANAGER.md](MANAGER.md) | 캐시 매니저 조회·기록 |
| [DESIGN-VERIFICATION.md](DESIGN-VERIFICATION.md) | 설계·검증 문서 전체 (재검토 결과 포함) |
| [DESIGN.md](DESIGN.md) | 핵심 메커니즘, 소스 수정 내역 |
| [VERIFICATION.md](VERIFICATION.md) | 검증 환경과 결과 |
