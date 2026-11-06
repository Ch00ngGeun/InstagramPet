# 권한과 로컬 데이터

이 MVP는 개인 Mac에서 빌드해 사용하는 개발용 프로젝트입니다. Instagram 로그인은 Chrome 페이지에서 유지하고, 확장 프로그램은 페이지가 표시한 DOM에서 후보 메시지를 찾습니다. 메시지 내용은 이 Mac의 확장 프로그램과 앱 사이에서만 전달합니다. 서버·분석 SDK·원격 수집 서비스는 없습니다.

## 요청하는 권한

실제 권한의 기준은 `extension/manifest.json`입니다.

- `storage`: 발신자 허용 목록, 설정, 중복 기록 및 제한된 전달 대기 상태.
- `nativeMessaging`: 설치한 Swift 호스트와 Chrome의 표준 통신.
- 재시도용 `alarms`가 선언되어 있다면 그 용도는 로컬 대기 이벤트 재전송이며 Instagram 조회가 아닙니다.
- `content_scripts.matches`: HTTPS `instagram.com`과 `www.instagram.com`에만 삽입. 페이지 안에서 경로를 추가 검사합니다.
- `scripting` + 같은 두 주소의 `host_permissions`: 확장을 다시 로드하거나 업데이트할 때 이미 열린 Instagram 탭에 같은 content script를 다시 넣는 용도로만 씁니다. 대상 사이트는 늘어나지 않습니다.

전체 웹사이트, Chrome 쿠키, 방문 기록, 접근성, 화면 녹화, 전체 디스크 접근 권한은 이 기능에 필요하지 않습니다. 권한과 웹사이트 범위를 최소화하는 것은 Chrome의 권장 방식입니다. [Chrome permissions](https://developer.chrome.com/docs/extensions/develop/concepts/declare-permissions), [Chrome extension security](https://developer.chrome.com/docs/extensions/develop/security-privacy/stay-secure)

## 경계에서 검증하는 것

웹페이지 DOM과 content script 메시지를 신뢰하지 않습니다. 서비스 워커는 메시지 보낸 확장 ID, 페이지 출처, 최상위 프레임, 이벤트 형식, sender 허용 목록을 확인합니다. 테스트 이벤트는 사용자가 확장 프로그램 설정에서 명시적으로 실행하는 별도 동작입니다.

Swift 호스트에서도 버전, 타입, 문자열 길이, username, eventId, 타임스탬프, Instagram 대화 URL을 다시 검증합니다. 수신한 문자열을 셸 명령으로 실행하지 않습니다. 앱은 표시할 내용을 평문으로 처리하고 허용한 HTTPS 대화 URL만 엽니다. Chrome도 content script 입력과 메시지 보낸 주체를 검증하도록 권장합니다. [Chrome extension security](https://developer.chrome.com/docs/extensions/develop/security-privacy/stay-secure)

Native Messaging 호스트 등록은 정확한 한 확장 프로그램 ID를 허용하며 와일드카드가 없습니다. 실행 파일은 절대 경로로 지정됩니다. 이 프로젝트는 일반 Google Chrome의 사용자별 등록 경로를 사용합니다. 브라우저 종류나 별도 user-data-dir를 바꾸면 등록 경로도 확인해야 합니다. 프로토콜은 길이 헤더와 UTF-8 JSON을 사용하며 일반 로그를 stdout에 출력하면 연결이 깨집니다. [Chrome Native Messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)

## 메시지가 저장되는 곳

본문은 전달을 위해 제한된 대기 큐에 잠시 남을 수 있습니다. 확장 프로그램 대기 큐는 최대 100개, 최대 5분이며 초과 시 가장 오래된 항목을 버리고 진단 정보를 남깁니다. Chrome이 종료되어도 로컬 저장소에 대기 이벤트가 남을 수 있습니다. 호스트가 수락한 이벤트는 `~/Library/Application Support/InstagramPet/inbox/`에 최대 200개, 24시간 보관하며 큐가 가득 차면 새 이벤트를 거부합니다. 시간 만료 정리는 다음 큐 접근 시 이루어지므로, 종료된 프로그램이 정각에 디스크 파일을 지우는 방식은 아닙니다.

호스트의 ACK는 로컬 큐 수락입니다. 사용자가 화면에서 봤다는 보증이 아닙니다. 앱은 표시 전까지 이벤트를 디스크 큐에 유지하고 말풍선을 표시할 때 파일을 삭제합니다. 실행 중 메모리에는 최근 말풍선과 대기 메시지가 남을 수 있습니다. 본문 없는 중복 식별 기록은 Chrome 최대 500개, 호스트 최대 4,096개이며 24시간의 제한을 둡니다.

일반 진단 로그에는 본문과 실제 계정명을 쓰지 않습니다. 메시지 미리보기는 펫 말풍선에 표시되므로 화면을 공유할 때는 숨기기 또는 표시 중단 기능을 사용합니다. 로컬 파일 접근 제한은 다른 macOS 사용자와의 분리를 위한 것으로, 같은 사용자 권한으로 실행되는 악성 프로그램까지 막는 암호화 경계가 아닙니다.

## 제거 및 초기화

루트 README의 제거 절차로 Native Messaging 등록과 앱·호스트를 지우고, Chrome에서 확장 프로그램을 제거합니다. 보관 데이터 삭제를 선택하면 Application Support 아래 프로젝트 전용 데이터도 삭제합니다. 재설치는 허용 목록·대화 매핑·전달 대기 상태를 다시 확인한 뒤 사용합니다.

실제 메시지, 계정명, 대화 URL, 쿠키·토큰, 전체 DOM 또는 HAR를 버그 보고에 넣지 않습니다. 구조 변경 보고는 [DOM-DRIFT.md](DOM-DRIFT.md)의 가짜 값 fixture 절차를 사용합니다.
