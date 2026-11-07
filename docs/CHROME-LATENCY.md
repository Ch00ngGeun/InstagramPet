# Chrome DM 관측 지연 측정 (2026-11-07)

기존 Chrome의 DM 탭 두 개에서 `hidden=1`, `focus=0`인 상태로 측정했습니다. **실제 새 DM의 도착 시간 측정은 아닙니다.** 페이지의 메시지 DOM을 읽거나 바꾸지 않고, 문서에 붙이지 않은 테스트 TextNode에 독립 MutationObserver를 달아 타이머와 microtask 지연만 비교했습니다. 이름·본문·탭 제목·URL·대화 ID는 프로브 결과에 포함하지 않았으며, 측정 후 observer·타이머·임시 메모리 상태를 정리했습니다.

## 실제 Chrome에서 측정한 독립 프로브

각 탭에서 8개 표본을 얻었습니다. MutationObserver가 받은 변경을 microtask로 넘긴 경로와, 같은 callback에서 요청한 250ms 타이머를 비교한 값입니다.

| 항목 | 탭 A | 탭 B |
| --- | --- | --- |
| 변경 → MutationObserver → microtask | 0.1~0.3ms | 0.0~0.2ms |
| 변경 → 250ms 타이머, 중앙값 | 1,000.2ms | 1,000.5ms |
| 타이머 7번째 표본 | 11,001.7ms | 11,000.7ms |
| 타이머 8번째 표본 | 59,999.3ms | 59,999.2ms |

이 결과는 hidden 페이지에서 짧은 타이머가 약 1초 또는 1분까지 밀리는 현상을 확인합니다. Instagram이 네트워크에서 메시지를 받기까지의 시간, 페이지가 DOM을 갱신하기까지의 시간, 실제 Swift 말풍선까지의 전체 전달 시간을 측정한 것은 아닙니다. DOM 변경 전에 페이지 자체가 멈추거나 지연되는 문제는 별도로 확인해야 합니다.

프로브를 다시 사용할 때는 `start`, 충분한 관측 뒤 `read`, 마지막에 `clear`를 실행합니다. Chrome의 Apple Events JavaScript 실행 허용이 필요합니다. 자동화 오류는 고정된 오류 코드만 반환합니다.

```sh
python3 scripts/measure-chrome-latency.py start
python3 scripts/measure-chrome-latency.py read
python3 scripts/measure-chrome-latency.py clear
```

## 코드 수정과 자동 검사

`content.js`는 실제 DOM 변경을 처리할 때 250ms `setTimeout`을 기다리던 단계를 제거하고 microtask 한 번으로 변경 묶음을 스캔합니다. 이미 worker ACK를 기다리는 중이면 새 변경을 기억했다가 완료 직후 한 번 더 스캔합니다. 5초 간격 검사는 SPA 이동·놓친 변경·재시도의 보조 경로로 남기며, 이것을 실시간 전달 보장으로 간주하지 않습니다. `resume`도 즉시 스캔 신호로 처리합니다.

즉시 스캔에서 텍스트와 발신자 정보가 서로 다른 DOM 변경으로 붙는 경우를 확인했습니다. 발신 방향·계정·내용이 준비되지 않은 행은 대화 끝 기준을 앞당기지 않도록 보완했고, 준비된 상대 메시지는 한 번만 전달하며 본인 답장은 계속 제외합니다.

확장은 관측을 켜고 허용 목록을 설정한 **Instagram DM 탭만** `autoDiscardable=false`로 유지합니다. 초기 실행·탭 이동·설정 변경 때 다시 적용하며, DM을 벗어나거나 관측을 끄면 각 탭의 원래 값을 복원합니다. worker가 재시작해도 복원할 수 있도록 session storage에 탭 ID와 원래 boolean만 보관하며 URL·제목·메시지는 저장하지 않습니다. 이 설정은 자동 메모리 폐기를 막는 것이며 timer throttling이나 freeze를 해제하는 API는 아닙니다. [Chrome Tabs API](https://developer.chrome.com/docs/extensions/reference/api/tabs#method-update)

`cd extension && npm test` **60/60 통과**: 타이머를 진행하지 않아도 hidden DOM 변경이 worker로 전달됨, 여러 변경의 한 번 스캔과 순서, ACK 대기 중 변경, resume, 확장 무효화 정리, 지연된 발신자 정보, DM만 자동 폐기 방지 및 원래 값 복원·worker 재시작 복구를 포함합니다. 추가한 숫자 진단 검사는 탭 URL·제목·ID·계정명을 반환하지 않는지, 명시적인 명령에서만 확장을 다시 로드하는지, 조회 오류가 고정된 숫자로만 반환되는지도 확인합니다.

추가 벤치는 실제 content 스크립트의 수정 전(`6892cc4`)·수정 후 코드를 결정적인 타이머 정렬 모델에서 실행합니다. **아래 수치는 실제 Chrome 성능이 아닌 합성 모델**이며, 수정 후 0ms는 모델에서 타이머 대기 단계를 없앴다는 뜻입니다.

| 타이머 정렬 모델 | 표본 수 | 수정 전 p95 | 수정 후 p95 |
| --- | --- | --- | --- |
| 정렬 없음 | 20 | 250ms | 0ms |
| 1초 단위 정렬 | 20 | 1,197ms | 0ms |
| 1분 단위 정렬 | 20 | 59,863ms | 0ms |

```sh
node scripts/benchmark-content-latency.cjs
```

## 지속 설정의 범위와 검증

현재 사용자 프로필에는 Instagram Memory Saver 예외가 있음을 확인했습니다. Memory Saver 예외와 탭의 `autoDiscardable=false`는 폐기 방지 설정이며, 짧은 타이머를 면제하는 설정은 아닙니다. [Chrome 성능 설정](https://support.google.com/chrome/answer/12929150?hl=en)

Chrome은 hidden 페이지의 연쇄 타이머를 제한하며, 공식 문서도 DOM 변경에는 MutationObserver 같은 이벤트를 사용하도록 권장합니다. Chromium의 loaded-page 유예 시간은 버전에 따라 다를 수 있으므로 항상 5분 뒤부터 시작한다고 가정하지 않습니다. [타이머 제한 설명](https://developer.chrome.com/blog/timer-throttling-in-chrome-88), [loaded-page 유예 변경](https://groups.google.com/a/chromium.org/g/blink-dev/c/5SZB2CFFGqE)

`IntensiveWakeUpThrottlingEnabled=false`는 intensive 제한을 끄는 공식 정책입니다. renderer가 시작할 때 적용하므로 기존 모든 탭에 일관 적용하려면 Chrome을 완전히 종료하고 다시 열어야 합니다. 일반 hidden 타이머 제한·freeze·discard·Mac 잠자기까지 해제하는 정책은 아닙니다. frozen 페이지는 타이머와 callback을 실행하지 못하고, discarded 페이지는 JavaScript 자체가 실행되지 않습니다. [Chromium 정책 정의](https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/IntensiveWakeUpThrottlingEnabled.yaml), [Page Lifecycle](https://developer.chrome.com/docs/web-platform/page-lifecycle-api)

`dist/InstagramPet Chrome Timer Policy.mobileconfig`는 현재 사용자 범위의 managed preferences `Forced` payload로 이 정책 한 키만 `false`로 설정하도록 준비한 파일입니다. 이 정책은 해당 사용자의 Chrome 전체에 적용됩니다. 생성 자체는 설치나 적용이 아닙니다. Apple의 managed preferences는 사용자 채널과 수동 설치를 지원합니다. 일반 `defaults write`는 Recommended 수준이므로 강제 정책 적용의 증거로 사용하지 않습니다. [Apple Managed Preferences](https://developer.apple.com/documentation/devicemanagement/managedpreferences), [Chromium Mac Quick Start](https://www.chromium.org/administrators/mac-quick-start/)

```sh
python3 scripts/create-chrome-timer-profile.py
python3 scripts/create-chrome-timer-profile.py --check
```

macOS 시스템 설정에서 이 profile을 설치했습니다. `--check`에서 `present=true`, `boolean=true`, `value=false`, `forced=true`를 확인했고, Chrome `chrome://policy`의 실제 표시에서도 `false`·Mandatory·Platform·오류 0·경고 0·무시 0·대체 0을 확인했습니다.

확장 프로그램을 다시 로드해 기존 Instagram 탭에 수정한 content script를 재삽입했습니다. 그 직전에는 DM 탭 2개의 `autoDiscardable=false`가 0개였고, 재로드 후 2개 모두 적용됐습니다. 이후 `chrome://restart`로 Chrome을 재시작했습니다. 기존 전체 탭 7개와 고정한 DM 탭 2개가 복원됐고, DM 2개 모두 `autoDiscardable=false`, discarded 0·frozen 0·최근 `observing` 진단 2개를 확인했습니다. 허용 목록과 사용자 설정은 수정하지 않았습니다. 사용자 프로필의 Instagram Memory Saver 예외도 유지됐습니다.

아래 재측정은 **동일한 독립 프로브**로 각 탭에서 8개 표본을 수집한 결과입니다. 정책을 적용하기 전 renderer와, 정책 설치 후 Chrome을 재시작한 renderer를 비교합니다. 두 측정 모두 `hidden=1`, `focus=0`이었습니다.

| 항목 | 재시작 전 탭 A / B | 정책 적용·재시작 후 탭 A / B |
| --- | --- | --- |
| 변경 → MutationObserver → microtask | 0.0~0.2ms / 0.0~0.2ms | 0.0~0.2ms / 0.0~0.2ms |
| 변경 → 250ms 타이머, 중앙값 | 1,000.2ms / 1,000.2ms | 999.5ms / 1,000.0ms |
| 변경 → 250ms 타이머, 최댓값 | 59,997.4ms / 59,999.1ms | 1,087.6ms / 1,010.7ms |

이번 재시작 후 표본에서는 1분 지연이 재현되지 않았고, 일반 hidden 타이머의 약 1초 정렬은 남았습니다. 재시작으로 renderer의 경과 시간도 달라졌으므로 이 짧은 표본만으로 모든 장시간 백그라운드 동작을 보장하지 않습니다. 실제 detector는 DOM 변경에서 이 타이머를 기다리지 않고 microtask로 스캔합니다. **실제 새 DM 수신부터 말풍선까지의 전체 지연은 아직 미검증**이며 네트워크·Instagram 자체 렌더링·잠자기 동안의 지연은 이 숫자에 포함되지 않습니다. 측정 후 두 탭의 프로브를 정리했습니다.

검증 도구는 임시 정책/확장 설정 탭을 닫고 기존 활성 탭을 복원합니다. Apple Events의 JavaScript는 격리된 실행 환경이므로 custom element의 `dataModel`이나 확장 `chrome.runtime`에 직접 접근할 수 없습니다. 정책은 렌더된 shadow DOM에서 해당 한 행만 확인하고, 확장 상태는 설정 페이지의 제한된 DOM 이벤트를 통해 숫자만 돌려받도록 수정했습니다. [Chromium 정책 행 구조](https://raw.githubusercontent.com/chromium/chromium/main/components/policy/resources/webui/policy_row.html.ts)

```sh
python3 scripts/manage-chrome-observation.py policy
python3 scripts/manage-chrome-observation.py tabs
```

기존 worker는 실제 Swift Native Messaging 포트를 유지·재사용합니다. 공식 `connectNative()` 포트는 worker 수명을 유지하지만 페이지의 timer/freeze 제한을 해제한다는 뜻은 아닙니다. 소리 없는 오디오·가짜 통신·주기적인 무의미한 ping은 추가하지 않았습니다. Mac에 Windows 전용 `WindowOcclusionEnabled` 정책도 적용하지 않았습니다. [worker 수명](https://developer.chrome.com/docs/extensions/develop/concepts/service-workers/lifecycle#chrome-105), [WindowOcclusionEnabled 지원 범위](https://chromium.googlesource.com/chromium/src/+/HEAD/components/policy/resources/templates/policy_definitions/Miscellaneous/WindowOcclusionEnabled.yaml)
