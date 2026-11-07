# 로컬 빌드의 고정 코드 서명

기본 빌드는 ad-hoc 서명입니다. ad-hoc designated requirement(DR)는 바이너리의 cdhash에 묶이므로, 코드가 바뀌면 기존 손쉬운 사용·전체 디스크 접근 승인을 다시 받아야 할 수 있습니다. Apple DTS도 이 동작을 확인했습니다. [Apple Developer Forums](https://developer.apple.com/forums/thread/819406)

같은 인증서로 계속 서명하면 앱의 bundle identifier와 인증서에 연결된 DR을 유지할 수 있습니다. Apple은 자체 서명 인증서가 코드의 DR을 검증하는 용도로 사용될 수 있다고 설명합니다. 이 로컬 설정은 Developer ID 서명·공증·배포를 제공하지 않습니다. [Code Signing Tasks](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)

## 이 Mac에 전용 인증서 준비

로그인한 사용자로 실행합니다. `sudo`는 사용하지 않습니다.

```sh
./scripts/prepare-local-signing.sh --trust-code-signing
./scripts/build-app.sh
```

준비 스크립트는 로그인 키체인에 `InstagramPet Local Code Signing` 인증서와 추출 불가능한 개인키를 만들거나 기존 것을 재사용합니다. 개인키 접근 허용 앱은 `/usr/bin/codesign`뿐입니다. 키체인이 잠겨 있거나 macOS가 키 사용 승인을 요구하면 사용자가 해당 시스템 대화상자에서 승인해야 합니다.

먼저 신뢰 설정을 바꾸지 않고 임시 실행 파일의 서명을 시도합니다. 실패했을 때 `--trust-code-signing`이 있으면 현재 사용자의 `codeSign` 정책과 `/usr/bin/codesign` 앱에만 한정하여 인증서를 신뢰합니다. 시스템 키체인, 관리자 신뢰, SSL 신뢰, allow-all 키 접근 권한, 다른 개인키의 접근 설정은 변경하지 않습니다. Apple TN3161은 서명 시 인증서의 신뢰 체인을 확인한다고 설명합니다. [TN3161](https://developer.apple.com/documentation/technotes/tn3161-inside-code-signing-certificates)

키를 만드는 동안의 PEM·PKCS#12 파일은 권한 700인 임시 폴더 안에 권한 600으로 두며 종료 시 삭제합니다. PKCS#12의 임시 랜덤 포장 비밀번호 파일도 권한 600으로 두고 함께 삭제합니다. 로그인 키체인 비밀번호는 읽거나 저장하지 않습니다. 준비가 성공하면 `~/Library/Application Support/InstagramPet/signing.plist`에 공개 인증서 지문과 키체인 경로만 권한 600으로 저장합니다. 개인키와 비밀번호는 저장소·로그·설정 파일에 쓰지 않습니다. 이전 실패에서 개인키 없이 남은 전용 이름의 인증서만 재시도 시 정리합니다. 인증서나 키를 삭제하거나 새로 만들면 서명 identity가 바뀝니다.

ad-hoc에서 인증서 서명으로 처음 전환한 설치본은 손쉬운 사용 권한을 **한 번 새로 허용**해야 합니다. 이후 빌드 간 승인이 유지되는지는 실제 설치본 두 개로 확인해야 합니다. 코드 서명의 DR이 안정적이어도 모든 macOS 버전의 권한 유지까지 보증하지는 않습니다.

## 빌드 설정

빌드 스크립트는 위 로컬 `signing.plist`를 자동으로 읽습니다. 설정된 identity를 사용할 수 없으면 서명 단계에서 실패하며 ad-hoc으로 자동 전환하지 않습니다.

필요할 때 환경변수로 선택할 수 있습니다.

```sh
INSTAGRAMPET_SIGN_IDENTITY='인증서 SHA-1 지문 또는 정확한 이름' ./scripts/build-app.sh
INSTAGRAMPET_SIGN_IDENTITY='-' ./scripts/build-app.sh
```

`INSTAGRAMPET_SIGN_KEYCHAIN`으로 특정 키체인을 지정하고, `INSTAGRAMPET_SIGN_CONFIG`로 다른 로컬 설정 plist를 선택할 수도 있습니다. 인증서로 서명된 앱의 권한을 계속 사용할 때는 `-`로 되돌리지 않습니다.

빌드는 앱과 네이티브 호스트의 서명을 검증하고 앱의 DR을 표시합니다. 두 버전의 DR을 비교하거나 이전 DR에 새 앱이 부합하는지 확인할 수 있습니다.

```sh
codesign --display --requirements - dist/InstagramPet.app
codesign --verify --deep --strict dist/InstagramPet.app
codesign --verify --strict -R='이전 designated requirement 표현식' dist/InstagramPet.app
```

DR 비교·검증은 개인정보 권한을 직접 부여하지 않습니다. 사용자가 시스템 설정에서 부여한 승인과 앱의 실제 AX/DB 접근을 따로 확인합니다.
