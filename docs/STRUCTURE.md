# 프로젝트 구조(인스타그램펫) — 2026-11-25 기준

**확인 범위**
- git main 최신 커밋 `2411190`(11.24, `main.swift` 기능별 분리)을 기준으로 봤습니다.
- 깃허브에 올라가는 파일 기준입니다. 11.24 첫 정리 이후 바뀐 항목에는 (변경)·(신규)를 붙였습니다.

**위치**

| 위치 | 담긴 것 |
|---|---|
| `~/Documents/Codex/2026-11-06/referenced-chatgpt-conversation-this-is-an/outputs/InstagramPet` | 현재 코드의 기준. git 저장소(원격 `Ch00ngGeun/InstagramPet`, 공개)이고 main이 최신임. |
| `~/orca/workspaces/InstagramPet/grampus` | 11.06 첫 버전에서 멈춘 예전 작업 공간. 기준으로 삼으면 안 됨. |
| `~/Applications/InstagramPet.app` | 실제로 실행되는 설치본. `scripts/install.sh`가 `dist/`에서 복사함. |
| `~/Library/Application Support/InstagramPet/` | 개인 설정·메시지 대기열. 깃허브에 올라가지 않음(맨 아래 참고). |

**메시지 흐름**
- 인스타그램: 인스타 페이지 → `detector.js` → `service-worker.js` → `PetNativeHost` → `EventQueue` → 펫 앱 말풍선
- 카카오톡·메시지: 펫 앱이 `PetSources`로 직접 읽어 말풍선을 띄움.

```
InstagramPet/
│
├─ README.md                             ← 프로젝트 소개·설치 방법.
│
├─ macos/                                ← 맥 앱 전체. Swift 패키지 하나에 실행 파일 2개와 공용 모듈 2개가 들어 있음.
│  ├─ Package.swift                      ← 빌드 설정. 어떤 폴더가 어떤 프로그램이 되는지 정함. Swift가 정한 파일명임.
│  ├─ Info.plist                         ← 앱 이름·권한 안내 문구 등 앱 정보. macOS가 정한 파일명임.
│  ├─ Resources/pet.png                  ← 기본 펫 그림. 사용자가 캐릭터를 추가하지 않았을 때 쓰임.
│  │
│  ├─ Sources/
│  │  ├─ InstagramPet/                   ← 화면에 떠 있는 펫 앱. 같은 폴더 파일끼리는 import 없이 서로 보임.
│  │  │  ├─ main.swift            (변경) ← 앱 시작 몇 줄만 남음(2,936줄 → 15줄). 나머지는 아래 파일로 나눔.
│  │  │  │
│  │  │  │  [화면 조각]
│  │  │  ├─ PetPanel.swift        (신규) ← 항상 맨 위에 뜨는 투명 창. panel은 맥에서 떠 있는 보조 창을 뜻함.
│  │  │  ├─ CatView.swift         (신규) ← 펫 그림·눌림·드래그. 처음 펫이 고양이여서 붙은 이름임.
│  │  │  ├─ BubbleView.swift      (신규) ← 말풍선 하나. 출처별 네온 테두리를 그림.
│  │  │  ├─ BubbleField.swift     (신규) ← 말풍선 여러 개의 배치. field는 말풍선이 놓이는 영역이라는 의미임.
│  │  │  ├─ HideArrow.swift       (신규) ← 펫을 화면 끝에 숨겼을 때 보이는 화살표.
│  │  │  │
│  │  │  │  [배치 계산]
│  │  │  ├─ Orbit.swift           (신규) ← 펫 주변 말풍선 위치 계산. orbit은 궤도라는 뜻임.
│  │  │  ├─ Slime.swift           (신규) ← Wall·Slime. 말풍선이 벽·펫에 눌려 찌그러지는 계산. 말랑한 느낌이라 slime임.
│  │  │  │
│  │  │  │  [앱 총괄 PetController — "+기능" 이름은 같은 총괄에 기능을 덧붙인 파일이라는 Swift 관례임]
│  │  │  ├─ PetController.swift   (신규) ← 저장 값·앱 시작·창 만들기. 저장 값은 Swift 규칙상 이 파일에만 둘 수 있음.
│  │  │  ├─ PetController+Menu.swift         (신규) ← 오른쪽 클릭 메뉴, 캐릭터 추가·선택·삭제.
│  │  │  ├─ PetController+Settings.swift     (신규) ← 설정 창 열기·저장·적용, 메뉴의 상태 표시.
│  │  │  ├─ PetController+Messages.swift     (신규) ← 새 메시지 확인, 읽음 처리, 말풍선 띄우기·지우기.
│  │  │  ├─ PetController+Conversation.swift (신규) ← 말풍선 클릭 → 인스타·카톡·메시지 대화방 열기.
│  │  │  ├─ PetController+Movement.swift     (신규) ← 드래그, 잠깐 숨기기, 화면 끝에 넣기, 화살표, 위치 저장.
│  │  │  │
│  │  │  │  [개발용 — 실행 옵션으로만 돌고 평소에는 쓰이지 않음]
│  │  │  ├─ PetController+GeometryChecks.swift (신규) ← 설정 창·펫·말풍선 위치 검사.
│  │  │  ├─ PetController+SourceChecks.swift   (신규) ← 카톡·메시지 읽기 검사. FixtureReader(가짜 출처)가 여기 있음.
│  │  │  ├─ PetController+Previews.swift       (신규) ← 미리보기 그림 만들기(--render-scenarios).
│  │  │  │
│  │  │  └─ SettingsWindow.swift         ← 설정 창. 볼 사람·대화방을 입력함.
│  │  │      · SourcesSettingsWindowController ← 설정 창 관리. sources는 인스타·카톡·메시지 세 출처를 뜻함.
│  │  │      · SettingsDraft / SettingsFormError ← 저장 전 입력값과 입력 오류.
│  │  │
│  │  ├─ PetCore/                        ← 앱과 연결 프로그램이 함께 쓰는 기본 기능. core는 핵심 공용 부분이라는 의미임.
│  │  │  ├─ PetCore.swift
│  │  │  │   · PetEvent                  ← 메시지 한 건. event는 "새 메시지가 왔다"는 사건을 뜻함.
│  │  │  │   · EventQueue                ← 파일로 된 메시지 대기열. 앱이 꺼져 있어도 메시지가 사라지지 않게 함.
│  │  │  │   · PetPaths                  ← 저장 폴더 경로 모음.
│  │  │  │   · NativeFrame               ← 크롬과 주고받는 데이터 형식. native messaging은 크롬의 외부 프로그램 연결 방식임.
│  │  │  │   · BridgeConfig              ← 연결 프로그램 설정. bridge는 크롬과 앱을 잇는 다리라는 의미임.
│  │  │  │   · PetSource / PetError / ConversationKey ← 출처 종류, 오류, 대화방 구분값.
│  │  │  └─ SourcesConfig.swift          ← 누구의 메시지를 볼지 설정. 내 맥의 sources.json을 읽음.
│  │  │      · SourcesConfig             ← 설정 전체.
│  │  │      · Instagram / Kakao / Messages ← 출처별 설정.
│  │  │      · ConversationDestination   ← 말풍선을 누르면 열릴 대화방. destination은 목적지라는 뜻임.
│  │  │
│  │  ├─ PetNativeHost/                  ← 크롬 ↔ 앱 연결 프로그램. native host는 크롬이 정한 용어임.
│  │  │  └─ main.swift            (변경) ← 크롬 요청 4가지 처리: 연결 확인, 설정, 새 메시지, 읽음.
│  │  │                                    11.20 메모리 누수 수정(오래 연결돼도 약 3MB 유지).
│  │  │
│  │  └─ PetSources/                     ← 카카오톡·메시지 읽기. 크롬을 거치지 않고 앱이 직접 읽는 출처들임.
│  │     ├─ MessagesReader.swift         ← 메시지 앱 대화 읽기. 원본은 읽기만 하고 절대 고치지 않음.
│  │     ├─ KakaoReader.swift            ← 카톡 창 내용 읽기. 맥의 손쉬운 사용 권한을 씀.
│  │     ├─ NotificationReader.swift     ← 카톡 알림 기록 읽기. 카톡 창이 닫혀 있어도 새 메시지를 알 수 있음.
│  │     │   · KakaoCombinedReader       ← 창 읽기와 알림 읽기를 합침. combined는 합친다는 뜻임.
│  │     ├─ ContactReaders.swift         ← 연락처에서 이름 찾기.
│  │     └─ SourcePoll.swift             ← 주기적으로 확인하는 공통 틀. poll은 정기적으로 물어본다는 뜻임.
│  │
│  └─ Tests/                             ← 맥 앱 테스트. Checks는 직접 만든 간단한 검사 프로그램이라는 의미임.
│     ├─ PetCoreChecks/                  ← 메시지 대기열·설정 검사(18묶음).
│     └─ PetSourcesChecks/               ← 카톡·메시지·알림·연락처 읽기 검사(74묶음). 출처별로 파일을 나눔.
│
├─ extension/                            ← 크롬 확장 프로그램. 인스타 웹에서 새 DM을 감지함. 변화 없음.
│  ├─ manifest.json                      ← 확장 프로그램 정보·권한. 크롬이 정한 파일명임.
│  ├─ content.js                         ← 인스타 페이지 안에서 실행됨. content script는 페이지에 들어가는 코드라는 크롬 용어임.
│  ├─ detector.js                        ← 인스타 화면에서 새 메시지 찾기. detector는 감지기라는 뜻임.
│  ├─ service-worker.js                  ← 백그라운드 담당. 연결 프로그램과 통신함. 크롬이 정한 역할명임.
│  ├─ worker-core.js                     ← 보낼 메시지 대기열·재시도·중복 제거. service-worker의 핵심 로직만 떼어 테스트하기 쉽게 함.
│  ├─ config-sync.js                     ← 앱 설정과 확장 설정 맞추기. sync는 동기화라는 뜻임.
│  ├─ tab-retention.js                   ← 인스타 탭이 꺼지지 않게 유지. retention은 유지라는 뜻임.
│  ├─ common.js                          ← 여러 파일이 쓰는 공용 함수. 아이디·주소 검사 등.
│  ├─ numeric-probe.js                   ← 화면 구조 점검용. probe는 탐침, 즉 살펴보는 도구라는 의미임.
│  ├─ options.html / .js / .css          ← 확장 프로그램 설정 화면. options는 크롬이 정한 설정 페이지 이름임.
│  ├─ popup.html / .js                   ← 아이콘을 누르면 뜨는 작은 창.
│  ├─ package.json                       ← 테스트 실행 설정. 확장 프로그램 자체는 외부 라이브러리를 쓰지 않음.
│  └─ tests/                             ← 확장 프로그램 테스트 9개 파일, 90개 항목. 파일명 = 검사 대상 + .test.cjs.
│     ├─ fixtures/                       ← 가짜 인스타 화면 HTML. 실제 계정 없이 감지 로직을 검사함.
│     └─ helpers/                        ← 테스트용 보조 코드.
│
├─ scripts/                              ← 빌드·설치·테스트 명령. 사람이 터미널에서 직접 실행함. 변화 없음.
│  ├─ build-app.sh                       ← 앱·연결 프로그램 빌드. 결과는 dist/에 생김.
│  ├─ install.sh / uninstall.sh          ← 내 맥에 설치·제거. 크롬 연결 등록까지 함.
│  ├─ prepare-local-signing.sh           ← 내 맥 전용 앱 서명 준비. 권한이 재설치 후에도 유지되게 함.
│  ├─ test-app.py                        ← 앱 테스트(11개).
│  ├─ test-native.py                     ← 연결 프로그램 테스트(16개). 메모리 누수 검사 포함.
│  ├─ test-install.py                    ← 설치 스크립트 테스트(4개).
│  ├─ benchmark-*.py / .cjs              ← 메시지 전달 속도 측정. benchmark는 성능 측정이라는 뜻임.
│  ├─ measure-chrome-latency.py          ← 크롬 알림 지연 측정. latency는 지연 시간이라는 뜻임.
│  ├─ create-chrome-timer-profile.py     ← 크롬 백그라운드 탭 지연을 줄이는 설정 파일 생성.
│  ├─ manage-chrome-observation.py       ← 크롬 관찰 설정 켜고 끄기.
│  └─ dom-probe.js                       ← 인스타 화면 구조 점검. DOM은 웹 페이지의 구조를 뜻함.
│
├─ docs/                                 ← 설명 문서.
│  ├─ STRUCTURE.md          (신규) ← 이 문서.
│  ├─ PROTOCOL.md                        ← 크롬 ↔ 앱 통신 규칙. protocol은 주고받는 약속이라는 뜻임.
│  ├─ SECURITY.md                        ← 보안·개인정보 원칙.
│  ├─ TESTING.md                         ← 테스트 방법.
│  ├─ VALIDATION.md                      ← 검증 결과 기록.
│  ├─ CHROME-LATENCY.md                  ← 크롬 알림 지연 대응.
│  ├─ DOM-DRIFT.md                       ← 인스타 화면 구조가 바뀔 때 대응. drift는 조금씩 바뀐다는 뜻임.
│  ├─ SIGNING.md                         ← 앱 서명 방법.
│  └─ preview.png                        ← README에 쓰는 미리보기 그림.
│
└─ dist/                                 ← 빌드 결과물. dist는 배포본(distribution)의 줄임말임.
   ├─ InstagramPet.app                   ← 펫 앱.
   └─ PetNativeHost                      ← 크롬 연결 프로그램.
```

## 깃허브에 올라가지 않는 파일

```
~/Library/Application Support/InstagramPet/   ← 맥이 앱 자료를 두라고 정한 위치.
├─ sources.json                          ← 개인 설정(볼 사람·대화방). 개인정보라 저장소에 넣지 않음.
├─ config.json              (추가 기재) ← 연결 프로그램 설정(확장 프로그램 ID·앱 위치·자동 실행).
├─ signing.plist            (추가 기재) ← 내 맥 전용 서명 정보.
├─ bin/PetNativeHost        (추가 기재) ← 크롬이 실제로 실행하는 연결 프로그램 설치본.
├─ characters/                           ← 추가한 캐릭터 그림. 지금은 비어 있음(기본 펫 사용 중).
└─ inbox / receipts / reads              ← 메시지 대기열·중복 기록·읽음 기록.

~/Library/Application Support/Google/Chrome/NativeMessagingHosts/
└─ com.instagrampet.bridge.json (추가 기재) ← 크롬에 연결 프로그램 위치를 알려주는 등록 파일.

프로젝트 폴더 안(.gitignore로 제외)
├─ work/                    (추가 기재) ← 점검·검증 때 만든 임시 결과물.
├─ macos/.build/ · .swiftpm/            ← Swift 빌드 중간 파일.
├─ extension/node_modules/              ← 테스트 도구.
└─ dist/InstagramPet Chrome Timer Policy.mobileconfig ← 이 맥 전용 크롬 정책 파일.
```

## 11.24 첫 정리 이후 달라진 점

1. **`main.swift` 분리:** 2,936줄 한 파일을 기능별 17개 파일로 나눴습니다. 가장 큰 파일은 305줄입니다. 코드 내용·동작은 그대로이고 위치만 옮겼습니다.
2. **500줄 기준:** 프로젝트 전체에서 500줄 넘는 파일이 없습니다. 가장 큰 파일은 `KakaoChecks.swift`(테스트, 493줄)입니다.
3. **테스트:** 앱 11개, 연결 프로그램 16개, 설치 4개, 확장 프로그램 90개, `PetCoreChecks` 18묶음, `PetSourcesChecks` 74묶음, 모두 통과했습니다.
4. **주의할 점**
   - `~/orca/workspaces/InstagramPet/grampus`는 11.06 첫 버전 상태입니다. 여기서 작업하면 최신 코드와 어긋납니다.
   - 저장소가 공개 상태입니다. 커밋 전에 실제 이름·아이디·대화방 번호가 없는지 계속 검사해야 합니다.
