# 구현 검증 결과

검증일: **2026-11-06 (Asia/Seoul)**. 환경: macOS 26.2, Apple Silicon arm64, Apple Swift 6.3.2 / Swift 5 언어 모드, Apple Command Line Tools, Node.js 24.18.0, Python 3.9.6.

## 실행한 검증

| 대상 | 실행 | 결과 |
| --- | --- | --- |
| Chrome 확장 프로그램 | `cd extension && npm test` | **42/42 통과** (실계정 구조 기반 fixture·프로브 개인정보 검사 포함) |
| 공유 Swift 모델·큐·프레이밍 | `cd macos && swift run PetCoreChecks` | **8/8 검사 그룹 통과** |
| 실제 Swift Native Messaging 실행 파일 | `./scripts/test-native.py` | **6/6 통과** |
| 임시 경로에서 설치·갱신·제거 | `./scripts/test-install.py` | **4/4 통과** |
| 실제 Swift 호스트 → AppKit 말풍선 → 큐 소비 | `./scripts/test-app.py` | **1/1 통과** |
| release 앱/호스트 빌드 | `./scripts/build-app.sh` | 성공, arm64 앱과 호스트 생성 |
| 앱/호스트 서명 | `codesign --verify --deep --strict` (앱), `codesign --verify --strict` (호스트) | 통과, 개발용 ad-hoc 서명 |
| 설정·구문 | Info.plist lint, 확장 JS 구문 검사, 설치/제거/빌드 shell 구문 검사 | 통과 |
| UI 렌더링 | 실제 AppKit 뷰를 offscreen PNG로 생성하고 확인 | 말풍선 줄바꿈·타이틀·힌트·고양이 확인 |

위 항목은 서로 다른 범위의 테스트와 검사 그룹입니다. fixture 테스트 개수만으로 실서비스의 DM 수신 정확도를 추정하지 않습니다. 전체 Xcode 없이 실행하도록 Swift 검사는 XCTest 대신 실행형 검사 도구로 구성했습니다.

확장 테스트에는 최초 기준 상태, username 허용 목록, 불명확한 신원 거부, 본문 프로필 링크 오인 방지, 본인 발신 레이블, 과거 내역 추가, hydration 대기, 반복 메시지, SPA 이동, 미리보기 중복 억제, 선택자 오류, 큐 재시도·만료·초과, 워커 재시작 및 메시지 보낸 주체 검증을 포함합니다.

Native Messaging 검사는 실제 호스트 프로세스의 표준 입력/출력에 Chrome 형식의 프레임을 넣어 UTF-8 한글·이모지, 프레임 분할, 중복 이벤트, 잘못된 링크·username·스키마·발신 확장 ID, 깨진 JSON·크기 초과·잘린 프레임의 처리를 확인합니다. stdout에는 프로토콜 응답만 남고 본문은 로그에 남지 않는지 확인했습니다.

설치 검사는 공백과 한글이 있는 임시 사용자 경로를 사용합니다. 정확한 allowed_origins, 절대 경로, 파일 권한, 앱 서명, 재설치, 잘못된 ID 거부, 관계없는 앱 보존, 데이터 보존/삭제 동작을 확인했습니다. **사용자의 실제 Chrome 프로필에 확장 프로그램을 설치하거나 호스트를 등록하지 않았습니다.**

앱 smoke test는 임시 큐에 실제 Swift 호스트가 이벤트를 수락한 뒤, 앱의 실제 시작·poll·present·consume 경로를 실행합니다. 창과 메뉴 아이콘을 표시하지 않고 `displayedEventId`, `bubbleVisible`, `remainingQueueCount`를 확인했습니다. 이는 로컬 Swift 전달 경로 검증입니다.

## 실계정 검증 (2026-11-06, Chrome 157, Instagram 한국어 UI)

자동 테스트와 별개로, 사용자의 실제 Chrome·로그인된 Instagram에서 수행했습니다. 본문·계정명은 기록하지 않았습니다.

| 단계 | 결과 |
| --- | --- |
| unpacked 확장 로드, `install.sh <ID>`, **Check bridge**/**Send test bubble** | 성공 (사용자가 말풍선 확인) |
| 기존 adapter로 실제 DM 페이지 | **실패**: `role=row`·메시지 ID·`time` 없음 → `unsupported-dom`, 메시지 목록이 `column-reverse` 라 `atBottom` 오판 |
| 수정 adapter, 열린 1:1 대화에서 상대 계정이 새로 보낸 메시지 | 텍스트·사진 `(이미지)`·동영상 `(동영상)`·게시물 `(게시물)`·스토리 `(스토리)`·이모지 **수신 성공** (호스트 수락 기록과 사용자 확인 일치) |
| 본인 답장 | 표시 안 됨 (정상) |
| 릴스 `(릴스)` | 1회 성공, 1회 누락 → 로딩 중 빈 말풍선이 기준 상태를 흔든 문제 수정. 수정본에서 **수신 성공** (2026-11-07) |
| 같은 릴스 재전송 | 수정본에서 **수신 성공** (2026-11-07). 같은 문구 재전송은 자동 테스트만 |
| 허용 계정 2개 (계정별 1:1 대화 탭 각 1개) | 두 번째 계정에서 텍스트·릴스·같은 릴스 재전송·다른 릴스 4건 **수신 성공**: 호스트 수락 기록 4건과 사용자 확인 일치 (2026-11-07) |
| 상시 수신 설정 | 펫 앱·Chrome 로그인 항목, Chrome 이전 탭 복원, `instagram.com` 메모리 절약 예외, 전원 연결 시 잠자기 방지 설정 확인. **재시동 후 자동 복원은 미검증** |

실제 DOM 구조 근거와 한계는 [DOM-DRIFT.md](DOM-DRIFT.md)의 "2026-11 실측 구조"를 참고하세요.

## 검증하지 않은 범위

- 위 실계정 검증 외의 환경: 다른 계정·다른 Chrome 버전·한국어 외 UI·A/B 화면. 자동 테스트 fixture는 합성 HTML입니다.
- 허용 목록에 없는 다른 발신자의 실수신 거부, 같은 문구 재전송의 실수신, 읽지 않은 미리보기(inbox) 감지(현재 미지원).
- 드래그·대화 클릭·숨김·일시정지 등 상호작용의 수동 사용성 시험, 모든 Spaces/전체 화면 앱/멀티 모니터 환경.
- 장시간 백그라운드 렌더링, Chrome 메모리 절약 탭 폐기, 네트워크 단절, 잠자기 복귀.
- Intel Mac, macOS 13~25에서의 실제 실행. 소스의 배포 대상은 macOS 13 이상이나 포함된 바이너리는 이 arm64 환경에서 빌드했습니다.
- Apple Developer ID 서명·공증·Chrome Web Store 배포.

실계정 검증은 [TESTING.md](TESTING.md)의 절차를 따릅니다. 지원하지 않는 DOM은 선택자/fixture 보완이 필요합니다. 탭 닫힘·Chrome 종료·Mac 잠자기 중의 실시간 DM 감지는 이 MVP의 기능이 아닙니다. 이미 관측한 전달 대기 이벤트는 다시 실행한 뒤 표시될 수 있습니다.
