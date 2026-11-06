# Instagram Pet — macOS + Chrome MVP

실제 실행 가능한 **Swift/AppKit 플로팅 펫**, **Chrome Manifest V3 확장 프로그램**, **Swift Native Messaging 호스트**입니다. 상대의 정확한 Instagram 계정명을 필터링해 새로 DOM에 나타난 DM 텍스트를 펫 말풍선으로 전달합니다. 서버, API 키, Instagram 비밀번호 입력은 없습니다.

![실제 AppKit 뷰로 렌더링한 펫](docs/preview.png)

**감지 조건:** Chrome에서 로그인한 Instagram **DM 페이지**가 열려 있고, 해당 메시지가 지원하는 DOM에 렌더링되어야 합니다. 탭 닫힘·탭 폐기·Chrome 종료·Mac 잠자기 중 DM을 실시간으로 가져오지 않습니다. 다른 앱이나 다른 탭을 사용하는 동안도 Instagram 페이지 렌더링과 연결이 유지되어야 하며 지연·누락될 수 있습니다. 처음 로드한 과거 내용과 복원 직후 내용은 알림으로 재생하지 않습니다.

이 소스의 자동화 테스트는 개인정보 없는 **합성 DOM fixture**를 사용합니다. 현재 로그인된 실제 Instagram 계정에서 실수신을 검증한 결과는 아닙니다. Instagram의 DOM은 계정·언어·A/B 실험별로 달라서, 기본 휴리스틱이 발신자나 수신 방향을 확인하지 못하면 **전송하지 않습니다**. 그때는 설정의 명시적인 1:1 대화 매핑과 검증된 선택자로 조정해야 합니다. [DOM 변경 대응](docs/DOM-DRIFT.md)을 확인하세요.

## 포함된 기능

- 배경이 투명한 AppKit `NSPanel`과 코드로 그린 애니메이션 고양이, 드래그 위치 저장, 메뉴 막대 제어.
- 말풍선 12초 표시, 여러 메시지 순차 표시, 최근 말풍선 다시 보기, 클릭하면 Chrome에서 대화 열기.
- 펫 숨김·메시지 표시 일시정지·로컬 데모·대기 메시지 삭제.
- 정확한 username 허용 목록. 표시 이름만 일치하는 사람은 통과하지 않음. 기본 허용 목록은 비어 있음.
- MutationObserver + 제한된 재검사, SPA/초기 로드 기준 상태, 수신·발신 구분, 미리보기와 본문 구분.
- 확장 프로그램 재시도 큐와 중복 기록, Native Messaging 프레이밍·입력 검증, 로컬 Swift 큐와 수락 기록.
- 계정 없이 가능한 연결 테스트와 개인정보를 제외한 진단 정보.

카카오톡·iMessage·iPhone 앱·답장 전송·Instagram 비공개 API 조회는 이번 MVP의 구현 범위에 포함되지 않습니다. 그룹 대화, 사진·음성의 원문 복원, DOM에 없는 메시지 전체 이력은 지원하지 않습니다.

## 1. 필요한 환경

- macOS 13 이상, 일반 **Google Chrome 120 이상**.
- Apple Command Line Tools 또는 Xcode의 Swift 도구. 최초 설치는 `xcode-select --install`.
- Node.js 20 이상과 npm: 확장 프로그램 **테스트에만** 필요. Chrome에 로드할 때 빌드나 npm이 필요하지 않습니다.
- Python 3: 설치 스크립트와 Native Messaging 통합 테스트. 이 Mac에서는 Apple Command Line Tools의 Python으로 검증했습니다.

`dist/`에는 검증한 Mac의 **Apple Silicon arm64** 실행 파일이 있습니다. Intel Mac에서는 아래 빌드 명령으로 다시 빌드하세요. 개인 개발용 ad-hoc 서명이며, Apple 공증 배포본은 아닙니다. 소스는 Swift Package라 Xcode에서 `macos/Package.swift`를 열어 살펴볼 수 있습니다.

## 2. 앱 빌드와 로컬 데모

터미널에서 압축을 푼 프로젝트 폴더로 이동합니다. 경로에 공백이 있으면 따옴표로 감싸세요.

```sh
cd "/path/to/InstagramPet"
./scripts/build-app.sh
open dist/InstagramPet.app
```

오른쪽 아래에 고양이가 나타나고 메뉴 막대에 발바닥 아이콘이 생깁니다. 아이콘 메뉴의 **Show Demo Bubble**로 로그인 없이 말풍선을 확인합니다. 고양이를 드래그해 이동하고, 우클릭이나 메뉴 막대에서 **Hide Pet**, **Pause Message Display**, **Quit Instagram Pet**를 사용할 수 있습니다. 숨김/일시정지 중에는 대기 메시지를 표시하지 않습니다. 메시지 원문은 콘솔에 출력하지 않습니다.

잠금 화면이나 macOS의 모든 시스템 화면 위에 표시되는 앱은 아닙니다. 전체 화면 앱과 Spaces의 동작은 실제 환경에서 확인하세요. 기본 투명 영역은 아래 앱의 클릭을 통과시킵니다.

## 3. Chrome 확장 프로그램 로드

1. Chrome 주소창에서 `chrome://extensions`를 엽니다.
2. **개발자 모드**를 켭니다.
3. **압축해제된 확장 프로그램을 로드합니다**를 누르고 이 프로젝트의 `extension/` 폴더를 선택합니다.
4. 표시된 **32자 확장 프로그램 ID**를 복사합니다. 설정 페이지에도 ID가 보입니다.
5. 이미 열려 있던 Instagram 탭은 새로고침합니다. 확장 프로그램을 다시 로드한 뒤에도 페이지를 새로고침하세요.

권한은 `storage`, `nativeMessaging`, 재시도용 `alarms`, 그리고 두 HTTPS Instagram 호스트의 content script 범위입니다. 모든 사이트·쿠키·방문 기록·화면 녹화·접근성·전체 디스크 접근 권한을 요구하지 않습니다. `alarms`는 이미 발견한 이벤트를 재전송하며 Instagram을 백그라운드 조회하지 않습니다.

## 4. Native Messaging 호스트 등록

펫을 종료한 뒤, 복사한 실제 ID를 다음 명령의 예시 대신 넣습니다.

```sh
./scripts/install.sh YOUR_32_CHARACTER_EXTENSION_ID
open "$HOME/Applications/InstagramPet.app"
```

`sudo`는 필요 없습니다. 설치 스크립트는 이 사용자 계정 안에 다음을 배치합니다.

```text
~/Applications/InstagramPet.app
~/Library/Application Support/InstagramPet/bin/PetNativeHost
~/Library/Application Support/InstagramPet/config.json
~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.instagrampet.bridge.json
```

호스트 매니페스트는 실제 설치 경로와 **지정한 확장 ID 한 개**만 허용합니다. 수신 이벤트가 새로 수락되면 설치된 펫을 열도록 설정됩니다. 로그인 시 자동 실행이나 상시 백그라운드 수신 서비스를 설치하지 않습니다. 앱을 종료해도 새 이벤트가 도착하면 다시 열릴 수 있으므로 수신을 멈추려면 확장 설정의 **Enable observation**을 끄세요. 자동 실행을 원하지 않으면 `config.json`의 `autoLaunch`를 `false`로 바꿉니다. 호스트는 시작할 때 설정을 읽으므로 `chrome://extensions`에서 확장 프로그램을 다시 로드하고 Instagram 탭도 새로고침한 뒤 연결을 확인합니다.

Chrome의 확장 아이콘 → **Settings & diagnostics**에서 **Check bridge**를 누릅니다. `connected`, `appInstalled: true`를 확인하고 **Send test bubble**을 누릅니다. 테스트용 말풍선이 나타나면 Chrome → Swift 호스트 → 로컬 큐 → 펫 연결을 확인한 것입니다. **이 시험은 Instagram 감지 성공을 의미하지 않습니다.** ACK는 호스트가 큐에 수락했다는 뜻입니다.

설치는 일반 Google Chrome용입니다. Chrome for Testing·Chromium·다른 브라우저는 등록 위치가 다를 수 있습니다. 다른 프로필/폴더에서 확장 ID가 달라졌다면 새 ID로 설치 명령을 다시 실행하세요. 소스를 수정한 뒤에는 다시 빌드하고 설치해야 설치된 복사본도 갱신됩니다.

## 5. 발신자 필터와 실제 DM 시험

1. Chrome에서 Instagram에 로그인하고 `https://www.instagram.com/direct/inbox/`를 엽니다.
2. 확장 설정 **Choose the sender**에 상대방의 **정확한 username**을 한 줄에 하나씩 입력합니다. 표시 이름은 사용하지 않습니다. `@`는 생략해도 됩니다.
3. 상대방과의 **1:1 대화**를 열어 프로필 계정명을 확인합니다. URL이 `/direct/t/123456789/`라면 **Thread bindings**에 `123456789 = partner.username`처럼 입력하고 본인이 확인했다는 체크를 켭니다. DOM이 username을 명확히 노출하지 않을 때 사용하는 신원 정보이므로 그룹 대화를 개인 계정에 매핑하지 마세요.
4. **Save settings & rebaseline**을 누르고 **최소 5초** 기다립니다. 이 구간의 메시지는 초기 기준 상태로 처리될 수 있습니다.
5. 진단에서 `messageRows`, `unknownSender`, `ambiguousText`, `unsupported-dom` 등을 확인합니다. `observing`은 후보 구조를 인식했다는 뜻이며 실수신 보증은 아닙니다.
6. 상대 계정에서 **새 텍스트 DM 한 개**를 보내 봅니다. 본인 답장은 알림으로 표시되지 않아야 합니다. 다른 계정과 기존 내역도 전송되지 않아야 합니다.

기본 파서는 role·메시지 ID·접근성 레이블·프로필 링크·텍스트 구조를 조합합니다. 수신 방향을 확인할 수 없는 화면에서는 설정의 **Advanced: calibrate after Instagram changes its DOM**에 해당 화면에서 확인한 `threadRoot`, `messageRow`, `incomingMessage`, `outgoingMessage`, `messageText` 선택자를 등록할 수 있습니다. 예시 클래스는 실제 Instagram 클래스가 아닙니다. 잘못된 선택자는 본인 메시지를 상대 메시지로 오인할 수 있으므로 [검증 절차](docs/TESTING.md)의 수신·발신·다른 사람 시험을 모두 수행해야 합니다.

inbox에서는 새로 바뀐 **읽지 않은 대화 미리보기**만 보낼 수 있고 말풍선에 **Inbox preview**로 표시합니다. 여러 DM이 한 미리보기로 합쳐지면 중간 메시지를 복구하지 못합니다. 타임스탬프/메시지 ID가 없는 동일 미리보기는 24시간 중복으로 억제될 수 있습니다. ID 없는 대화 본문의 동일 문구 반복도 구분하지 못할 수 있습니다. 페이지를 새로 열거나 긴 중단에서 돌아오면 이전 메시지는 기준 상태로 처리해 재알림을 억제하므로 그 사이 도착한 DM을 놓칠 수 있습니다.

## 6. 테스트

프로젝트 루트에서:

```sh
cd extension
npm ci
npm test
cd ../macos
swift run PetCoreChecks
cd ..
./scripts/build-app.sh
./scripts/test-native.py
./scripts/test-install.py
./scripts/test-app.py
```

`PetCoreChecks`는 Foundation만 사용하는 실행형 테스트입니다. 전체 Xcode의 XCTest가 없는 Command Line Tools 환경에서도 실행되도록 만들었습니다. 확장 프로그램은 fixture 파싱과 상태 전이/필터/워커 큐를, Swift 검사는 입력 검증·디스크 큐·만료·파일 권한·중복·프레이밍을, Python 통합 검사는 **실제 Swift 호스트 실행 파일**을 검증합니다. 설치 테스트는 임시 폴더에서 수행하며 사용자 Chrome 설정을 바꾸지 않습니다. 앱 smoke test는 로그인된 macOS 데스크톱 세션에서 창을 표시하지 않고 실제 큐 수신→말풍선 생성→큐 소비를 확인합니다.

검증 당시 결과와 한계는 [VALIDATION.md](docs/VALIDATION.md), 실제 계정 확인 목록은 [TESTING.md](docs/TESTING.md)에 있습니다.

## 문제 해결

| 증상 | 확인할 곳 |
| --- | --- |
| Native messaging host not found | 실제 확장 ID로 `install.sh` 실행 여부, 일반 Chrome의 등록 경로, `path`의 실행 파일 존재 여부 |
| Access forbidden / caller check failed | 확장 ID가 호스트 allowed_origins 및 config.json과 모두 같은지 |
| connected인데 말풍선 없음 | appInstalled, 설치된 앱 실행, 숨김/일시정지 상태, native queue depth 확인 |
| heartbeat 없음 | Instagram 탭 새로고침, 로그인된 DM 페이지인지, Chrome의 사이트 접근 허용 여부 |
| unsupported-dom / unknownSender | 정확한 허용 목록, 검증된 1:1 binding, DOM 선택자 조정 및 fixture 회귀 시험 |
| 기존 메시지가 안 옴 | 최초/재개 기준 상태 처리가 정상일 수 있음. 기다린 뒤 새 DM으로 시험 |
| 같은 메시지 반복 / 누락 | 잘못된 선택자, DOM 노드 재활용, preview 집계, ID 부재와 백그라운드 중단 여부 확인 |

설정에서 **Log metadata**를 켜면 Instagram 탭 개발자 도구 콘솔에 상태와 개수만 기록합니다. 서비스 워커 오류는 `chrome://extensions`의 **service worker** 검사에서 확인합니다. 메시지 본문·계정명·전체 DOM·쿠키·HAR를 보고서에 붙이지 마세요. Chrome의 Native Messaging 로그와 일반 로그가 프로토콜 stdout에 섞이면 연결이 깨집니다.

로컬 큐 검사와 삭제:

```sh
"$HOME/Library/Application Support/InstagramPet/bin/PetNativeHost" --status
"$HOME/Library/Application Support/InstagramPet/bin/PetNativeHost" --clear
```

확장 대기 큐는 최대 100개/5분, Swift 대기 큐는 최대 200개/24시간입니다. 만료 파일의 실제 삭제는 다음 큐 접근 때 이뤄집니다. 펫은 표시한 이벤트 파일을 지우고, 중복 확인용 내용 없는 기록만 제한적으로 보관합니다. 자세한 데이터 위치와 한계는 [SECURITY.md](docs/SECURITY.md)를 참고하세요.

## 제거

펫을 종료한 뒤 실행합니다.

```sh
./scripts/uninstall.sh --delete-data
```

앱·호스트 등록·프로젝트 전용 로컬 큐와 설정을 제거합니다. 로컬 데이터를 남기려면 `--delete-data`를 생략합니다. Chrome의 `chrome://extensions`에서 확장 프로그램도 제거하세요. 앱의 위치 설정까지 초기화하려면 `defaults delete com.instagrampet.app`을 사용할 수 있습니다.

## 구조

```text
extension/                  MV3, DOM adapter/tracker, 설정, 전달 큐, fixture 테스트
macos/Package.swift         Swift Package (PetCore / PetNativeHost / InstagramPet / PetCoreChecks)
macos/Sources/PetCore/      이벤트 검증, 원자적 private 큐, 중복 수락 기록, framing
macos/Sources/PetNativeHost/ Chrome stdio 호스트 + 명시적인 로컬 demo/status/clear 명령
macos/Sources/InstagramPet/ AppKit 펫과 말풍선, 메뉴, 큐 소비
scripts/                    빌드·설치·제거·네이티브/설치 통합 테스트
dist/                       빌드한 앱과 Swift 호스트 (이 빌드는 arm64)
docs/                       프로토콜, 테스트 결과, DOM 변경 대응, 개인정보 처리
```

이 통신은 Chrome이 호스트 프로세스를 시작해 표준 입력/출력으로 교환하는 방식입니다. 로컬 HTTP 서버나 포트를 열지 않습니다. 등록 경로와 프레이밍은 [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), 감지 가능한 페이지 범위는 [content scripts](https://developer.chrome.com/docs/extensions/develop/concepts/content-scripts), 재시작 내구성은 [service worker lifecycle](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle)을 기준으로 구현했습니다.
