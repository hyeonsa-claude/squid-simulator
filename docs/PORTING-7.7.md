# squid 4.10 → 7.7 이식 내역

이 브랜치는 `main`(squid 4.10, Ubuntu 20.04)의 시뮬레이터를 squid 7.7(Ubuntu 26.04)로 옮긴 것입니다.
기능과 출력 형식은 같고, Squid 내부 API가 바뀐 곳만 다르게 연결했습니다.

## 대상 버전

| 항목 | 값 |
|---|---|
| Ubuntu 26.04 출시 시 squid | 7.2 (`7.2-2ubuntu2`, 2026-04-04) |
| Ubuntu 26.04 현재 squid | 7.7 (`7.7-0ubuntu0.26.04.1`, resolute-updates, 2026-10-22) |
| 소스 | 업스트림 `squid-7.7.tar.xz`. Ubuntu의 `squid_7.7.orig.tar.xz`와 SHA-256이 같음 |
| Ubuntu 자체 패치 | 기본 설정·`internal.cc` 수정 4개를 시뮬레이터 패치보다 먼저 적용 (`scripts/target.env`) |
| 빌드 변형 | `squid` 패키지(GnuTLS). `squid-openssl`은 별도 패키지라 대상 아님 |

## API 변경과 대응

| 영역 | 4.10 | 7.7 | 대응 |
|---|---|---|---|
| 판정 타입 | `allow_t` | `Acl::Answer` | 이름만 변경 |
| ACL 기본 클래스 | `ACL` (`char name[]`) | `Acl::Node` (`SBuf name`) | 이름을 `toStdString()`으로 변환 |
| 전체 ACL 목록 | `Config.aclList` 연결 리스트 | `Config.namedAcls` 비정렬 맵 (정의가 `Acl.cc` 내부) | 파싱 시 정의 순서를 `Acl::AclDefinitionOrder`에 기록하고 `FindByName()`으로 조회 |
| ACL 옵션 덤프 | `dumpOptions()` | 없음 | `dumpWhole()` 출력에서 이름을 뺀 문자열로 동일 ACL 비교 |
| `acl` 줄 파싱 | `ACL::ParseAclLine()` | `Acl::Node::ParseNamed()` (예외 발생 가능) | 같은 위치에 훅. 현재 파싱 중인 ACL은 RAII 객체로 관리 |
| 도메인·IP 중복 경고 | `DomainData.cc`, `Ip.cc`의 비교 함수 | `Acl::SplayInserter<T>::Merge()` 하나로 통합 | `Merge()`의 세 분기(포함, 동일, 겹침 병합)에 노트 기록. 7.7에서 생긴 "겹침 병합"은 `overlapping entries`로 보고 |
| `matchChild()` | `(parent, pos, child)` | `(parent, pos)` | 자식은 `*pos`에서 얻음 |
| `goAsync()` | `(AsyncState*)` | `(AsyncStarter, const Acl::Node &)` | 비동기 거절 지점에서 노드를 직접 전달 |
| `http_access` 트리 | `Acl::Tree *` | `RefCount<Acl::Tree> *` | `HttpAccessTree()` 도우미 |
| 체크리스트 생성 | `ACLFilledChecklist(tree, req, ident)` | `ACLFilledChecklist(acl_access*, req)` | ident 인자 제거 |
| 트랜잭션 | `new MasterXaction(initClient)` | 생성자 비공개, `MasterXaction::MakePortful(port)` | 로컬 포트에 맞는 `http_port`로 생성 |
| URL 포트 | `unsigned short` | `std::optional<uint16_t>` | `value_or(0)` |
| DNS 캐시 주소 | `ipcache_addrs` 구조체 배열 | `Dns::CachedIps` (`pushUnique()`) | 동기 조회 결과를 `pushUnique()`로 저장 |
| 설정 재파싱 | `parseConfigFile(path)`가 오류 수 반환 | `Configuration::Parse()`가 전역 `ConfigFile`을 읽고 예외 발생 | `--sim-compare`에서 `ConfigFile`을 바꾸고 try/catch |
| 시간 전역 | `SquidTime.h` | `time/gadgets.h` | include만 변경 |
| `external` ACL | 자유 함수 | `ACLExternal::aclMatchExternal()` 멤버 | 같은 NULL 검사 위치에 추가 |
| 컴파일 경고 | `-Wall -Wshadow -Werror` | `-Wextra -Wmissing-declarations -Wimplicit-fallthrough=5` 추가 | 새 함수는 모두 `static`이거나 헤더에 선언 |

## 로그로 판단할 수 없는 ACL 타입

7.7에서 `ident`, `ident_regex`가 제거되었고, 다음 타입이 `UNSURE` 목록에 추가되었습니다:
`annotate_client`, `annotate_transaction`, `squid_error`, `connections_encrypted`, `snmp_community`.

## 26.04 실기에서 확인한 것

Ubuntu 26.04.1 LTS에서 `scripts/verify-target.sh`로 모두 확인했고, 앞의 두 항목은 `tests/optimize-extra.conf`로 자동 테스트합니다.

- `src 0.0.0.0/0`을 모든 요청에 매칭되는 ACL로 인식함
- 7.7의 범위 병합이 `overlapping entries`로 보고됨
- Ubuntu 패치 적용 후 `-k parse` 결과가 배포판 squid 7.7과 같음 (테스트 설정 2개와 `/etc/squid/squid.conf`)
