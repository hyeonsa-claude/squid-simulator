# squid-simulator

Squid에 오프라인 `http_access` 시뮬레이터를 붙이는 패치입니다. squid.conf와 access.log를 넣으면 요청마다
**어떤 규칙이 허용/차단했는지**, **그 뒤에 매칭되는 다른 규칙은 무엇인지**를 보여줍니다. 그 밖에 두 squid.conf의
판정 차이, 불필요하거나 도달할 수 없는 ACL·규칙, 전체 HTML 리포트도 만듭니다.
판정은 Squid 자신의 파서와 ACL 엔진이 내리며, 소켓을 열거나 트래픽을 보내지 않습니다.

## 브랜치

Squid 내부 API가 버전마다 달라서, 배포판의 squid 버전마다 브랜치를 나눕니다.

| 브랜치 | 대상 OS | squid | 상태 |
|---|---|---|---|
| `main` | Ubuntu 20.04 LTS | 4.10 | 빌드·`make check`·기능 테스트 통과 ([docs/VERIFICATION.md](docs/VERIFICATION.md)) |
| `ubuntu-26.04-squid-7.7` | Ubuntu 26.04 LTS | 7.7 (26.04 업데이트 기준, 출시 시 7.2) | 이식 완료. 20.04에서 7.7 빌드·`make check`·기능 테스트 통과, 26.04 머신 검증 대기 |

## 빠른 시작 (Ubuntu 20.04)

```bash
git clone https://github.com/hyeonsa-claude/squid-simulator.git
cd squid-simulator
scripts/build.sh --deps          # 빌드 패키지 설치(sudo) → 소스 다운로드·검증 → 패치 → 빌드
scripts/test.sh                  # 시뮬레이터 기능 테스트
```

한 번에 전부 검증하려면 `scripts/verify-target.sh` (OS·버전 확인 → 빌드 + `make check` → 기능 테스트 → 배포판 squid와 비교).

`build/squid-4.10/src/squid`가 패치된 바이너리입니다. 설치는 하지 않습니다.

```bash
B=build/squid-4.10/src/squid
$B -f /etc/squid/squid.conf --simulate /var/log/squid/access.log                 # 요청별 판정
$B -f /etc/squid/squid.conf --simulate access.log --sim-compare new.conf         # 설정 비교
$B -f /etc/squid/squid.conf --optimize                                           # 불필요한 ACL·규칙
$B -f /etc/squid/squid.conf --simulate access.log --sim-compare new.conf \
   --optimize --report report.html                                               # 전체 리포트
```

로그 형식: `logformat custom %tl %la %>a  "%rm %ru HTTP/%rv" %>Hs %<st %Ss:%Sh`

## 문서

- [docs/USAGE.md](docs/USAGE.md): 옵션, 출력 읽는 법, 최적화 항목
- [docs/DESIGN.md](docs/DESIGN.md): 구조, 핵심 메커니즘, 소스 수정 내역
- [docs/VERIFICATION.md](docs/VERIFICATION.md): 검증 방법과 결과, 한계

## 구성

```
patches/squid-<버전>-acl-simulator.patch   Squid 소스에 적용하는 패치 (patch -p1)
scripts/target.env                          이 브랜치의 대상 OS, squid 버전, 체크섬, configure 옵션
scripts/build.sh                            다운로드 → sha256 확인 → 패치 → configure → make [--check]
scripts/test.sh                             tests/의 설정·로그로 기능 테스트
tests/                                      테스트용 squid.conf, 새 conf, access.log, 기대 결과
docs/                                       문서
```

## 정확도 요약

로그에 있는 정보만 쓰는 ACL(`src`, `dstdomain`, `url_regex`, `port`, `method`, `time` 등)은 운영 squid와 같은 엔진으로
판정합니다. 헤더·인증·helper·연결 상태를 보는 ACL은 로그에 정보가 없어 `UNSURE`로 표시하며,
DNS가 필요한 ACL은 `--sim-dns`에 따라 다릅니다. 자세한 내용은 [docs/VERIFICATION.md](docs/VERIFICATION.md)에 있습니다.

## 라이선스

패치는 Squid와 같은 GPLv2+입니다.
