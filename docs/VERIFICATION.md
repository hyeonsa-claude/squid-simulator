# 검증 결과 (ubuntu-26.04-squid-7.7: Ubuntu 26.04 / squid 7.7)

2026-10-31 기준, squid 7.7 이식 패치는 빌드, Squid 7.7 자체 단위 테스트, 시뮬레이터 기능 테스트를 모두 통과했습니다.
다만 아직 **Ubuntu 20.04 서버에서 7.7을 빌드해 확인한 결과**이고, 26.04 머신에서는 아직 확인하지 않았습니다.

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
| 기능 테스트 `scripts/test.sh` | 28개 검사 모두 통과. squid 4.10 브랜치와 같은 결과 |
| 패치 재현성 | 저장소의 패치를 새로 적용한 소스가 테스트한 소스와 17개 파일 모두 동일 |

## 2단계: Ubuntu 26.04 머신에서 확인 (대기)

26.04 머신에서 다음 한 줄로 전체를 확인합니다.

```bash
git clone -b ubuntu-26.04-squid-7.7 https://github.com/hyeonsa-claude/squid-simulator.git
cd squid-simulator && scripts/verify-target.sh
```

이 스크립트가 확인하는 것:

1. OS가 Ubuntu 26.04이고, 설치된 squid가 7.7인지 (`apt-get install squid` 후 `apt-get upgrade`로 7.7)
2. 26.04의 빌드 의존 패키지로 빌드 + `make check` (26.04의 g++과 라이브러리 버전)
3. 기능 테스트 28개
4. 배포판 squid 7.7과 패치한 squid 7.7이 테스트 설정과 `/etc/squid/squid.conf`에 같은 `-k parse` 결과를 내는지

추가로 확인할 것:

- `src all`의 `dump()` 출력 형식 (모든 요청에 매칭되는 ACL 판단). 1단계 테스트에서는 `all`을 이름으로 판단해 통과
- 7.7에서 새로 생긴 "겹치는 항목 병합" 경고가 `overlapping entries`로 보고되는지

## 한계

`main` 브랜치의 [VERIFICATION.md](https://github.com/hyeonsa-claude/squid-simulator/blob/main/docs/VERIFICATION.md#한계)와 같습니다.
7.7에서 `ident` ACL이 없어졌고, `annotate_client`, `annotate_transaction`, `squid_error`, `connections_encrypted`,
`snmp_community`가 로그로 판단할 수 없는 타입에 추가되었습니다.
