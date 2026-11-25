#!/usr/bin/env python3
"""대상 정책/DM 탭 상태를 확인하거나, 이 프로젝트의 확장 프로그램을 다시 로드하거나, Chrome을 재시작한다. 출력은 숫자뿐이다.

실행: python3 scripts/manage-chrome-observation.py policy|tabs|reload|restart

기존 탭은 절대 이동시키지 않는다. 임시로 연 정책/옵션 탭은 다시 닫는다.
확장 프로그램 ID는 로컬 브리지 설정에서만 읽고 출력하지 않는다.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

APPLESCRIPT = r'''
on run argv
    set targetAddress to item 1 of argv
    set probeCode to item 2 of argv
    set terminalAnswer to "{\"probeError\":1}"
    tell application "Google Chrome"
        if (count of windows) is 0 then return "{\"windowError\":1}"
        set browserWindow to front window
        set originalIndex to active tab index of browserWindow
        set temporaryTab to make new tab at end of tabs of browserWindow with properties {URL:targetAddress}
        try
            set active tab index of browserWindow to originalIndex
            repeat 30 times
                delay 0.2
                try
                    with timeout of 10 seconds
                        set terminalAnswer to execute temporaryTab javascript probeCode
                    end timeout
                    if terminalAnswer does not contain "\"ready\":0" then exit repeat
                on error number errorCode
                    set terminalAnswer to "{\"automationError\":" & errorCode & "}"
                    exit repeat
                end try
            end repeat
        on error number errorCode
            set terminalAnswer to "{\"automationError\":" & errorCode & "}"
        end try
        delay 0.3
        try
            close temporaryTab
        end try
        try
            set active tab index of browserWindow to originalIndex
        end try
    end tell
    return terminalAnswer
end run
'''

RESTART_APPLESCRIPT = r'''
tell application "Google Chrome"
    if (count of windows) is 0 then return "{\"windowError\":1}"
    set browserWindow to front window
    set originalIndex to active tab index of browserWindow
    set previousTabs to 0
    repeat with existingWindow in windows
        set previousTabs to previousTabs + (count of tabs of existingWindow)
    end repeat
    set restartTab to make new tab at end of tabs of browserWindow with properties {URL:"about:blank"}
    set active tab index of browserWindow to originalIndex
    set URL of restartTab to "chrome://restart"
end tell
return "{\"ready\":1,\"restartRequested\":1,\"previousTabs\":" & previousTabs & "}"
'''

POLICY = r'''(() => {
  const app = document.querySelector('policy-app');
  const scope = app?.shadowRoot || document;
  const button = scope.querySelector('#reload-policies');
  if (!button) return JSON.stringify({ready:0});
  const key = Symbol.for('InstagramPet.policyCheckReloaded');
  if (!globalThis[key]) { globalThis[key]=1; button.click(); return JSON.stringify({ready:0}); }
  if (button.disabled) return JSON.stringify({ready:0});
  const tables = [...scope.querySelectorAll('policy-table')];
  for (const table of tables) {
    const rows = [...(table.shadowRoot?.querySelectorAll('policy-row') || [])];
    // Apple Events는 격리된 실행 환경(isolated world)에서 돌아 커스텀 요소의 JavaScript 속성은
    // 쓸 수 없지만, 렌더링된 shadow DOM은 공유된다.
    const row = rows.find(r => r.shadowRoot?.querySelector('#name')?.textContent?.trim()
      === 'IntensiveWakeUpThrottlingEnabled');
    if (!row) continue;
    const text = selector => row?.shadowRoot?.querySelector(selector)?.textContent?.trim() || '';
    const value = text('.policy.row .value');
    const status = text('.policy.row .messages');
    return JSON.stringify({ready:1, present:value?1:0, valueFalse:value==='false'?1:0,
      mandatory:/mandatory|필수/i.test(text('.policy.row .level'))?1:0,
      platform:/platform|플랫폼/i.test(text('.policy.row .source'))?1:0,
      errors:text('.errors.row .value')?1:0, warnings:text('.warnings.row .value')?1:0,
      ignored:/ignored|무시/i.test(status)?1:0, superseded:/supersed|대체/i.test(status)?1:0});
  }
  return JSON.stringify({ready:1,present:0,valueFalse:0,mandatory:0,platform:0,errors:0});
})()'''

TABS = r'''(() => {
  if (location.protocol!=='chrome-extension:' || location.hostname!==__EXTENSION_ID__)
    return JSON.stringify({wrongExtension:1});
  const root=document.documentElement;
  root.setAttribute('data-pet-numeric-command','tabs');
  root.dispatchEvent(new Event('pet-numeric-probe'));
  return root.getAttribute('data-pet-numeric-result') || JSON.stringify({ready:0});
})()'''

RELOAD = r'''(() => {
  if (location.protocol!=='chrome-extension:' || location.hostname!==__EXTENSION_ID__)
    return JSON.stringify({wrongExtension:1});
  const root=document.documentElement;
  root.setAttribute('data-pet-numeric-command','reload');
  root.dispatchEvent(new Event('pet-numeric-probe'));
  return root.getAttribute('data-pet-numeric-result') || JSON.stringify({ready:0});
})()'''


def numeric(value):
    if value is None or isinstance(value, (int, float)):
        return True
    if isinstance(value, list):
        return all(numeric(x) for x in value)
    if isinstance(value, dict):
        return all(isinstance(k, str) and numeric(v) for k, v in value.items())
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('policy', 'tabs', 'reload', 'restart'))
    args = parser.parse_args()
    if args.mode == 'restart':
        address, code = '', ''
    elif args.mode == 'policy':
        address, code = 'chrome://policy/', POLICY
    else:
        try:
            config = json.loads((Path.home() / 'Library/Application Support/InstagramPet/config.json').read_text())
            extension_id = config['extensionId']
            if not re.fullmatch('[a-p]{32}', extension_id):
                raise ValueError()
        except (OSError, ValueError, KeyError, TypeError):
            print(json.dumps({'bridgeConfigError': 1}))
            return 1
        address = 'chrome-extension://' + extension_id + '/options.html'
        code = (TABS if args.mode == 'tabs' else RELOAD).replace('__EXTENSION_ID__', json.dumps(extension_id))
    try:
        arguments = ['osascript', '-e', RESTART_APPLESCRIPT] if args.mode == 'restart' else ['osascript', '-e', APPLESCRIPT, address, code]
        process = subprocess.run(arguments, capture_output=True, text=True, timeout=40)
        if process.returncode:
            print(json.dumps({'automationError': process.returncode}))
            return 1
        try:
            result = json.loads(process.stdout)
        except ValueError:
            print(json.dumps({'probeError': 1, 'resultLength': len(process.stdout), 'missingValue': int(process.stdout.strip() == 'missing value')}))
            return 1
        if not numeric(result):
            raise ValueError()
        print(json.dumps(result, indent=2))
        return int(not isinstance(result, dict) or result.get('ready') != 1
                   or any(result.get(key) for key in ('queryError', 'automationError', 'wrongExtension')))
    except (OSError, subprocess.TimeoutExpired, ValueError):
        print(json.dumps({'probeError': 1}))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
