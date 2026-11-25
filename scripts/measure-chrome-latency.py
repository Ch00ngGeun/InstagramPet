#!/usr/bin/env python3
"""열려 있는 Chrome DM 탭에서 도는 독립적인 숫자 전용 타이밍 측정기. 메시지 DOM은 읽지 않는다.

탭을 고를 때 AppleScript 안에서 URL 접두사만 확인하며, URL·제목·탭 ID·메시지 데이터는
반환하지 않는다. MutationObserver는 문서에 붙지 않은 TextNode를 감시하므로
실제 Instagram 감지기는 이 합성 변경을 볼 수 없다.

실행: python3 scripts/measure-chrome-latency.py start|read|clear
"""
import argparse
import json
import subprocess

APPLESCRIPT = r'''
on run argv
    set probeCode to item 1 of argv
    set answers to {}
    tell application "Google Chrome"
        repeat with browserWindow in windows
            repeat with browserTab in tabs of browserWindow
                try
                    set pageAddress to URL of browserTab
                    if pageAddress starts with "https://www.instagram.com/direct/" or pageAddress starts with "https://instagram.com/direct/" then
                        try
                            with timeout of 15 seconds
                                set end of answers to execute browserTab javascript probeCode
                            end timeout
                        on error number errorCode
                            set end of answers to "{\"errorCode\":" & errorCode & "}"
                        end try
                    end if
                on error number errorCode
                    set end of answers to "{\"errorCode\":" & errorCode & "}"
                end try
            end repeat
        end repeat
    end tell
    set AppleScript's text item delimiters to ","
    set encodedAnswers to answers as text
    set AppleScript's text item delimiters to ""
    return "[" & encodedAnswers & "]"
end run
'''

START = r'''(() => {
  const key = Symbol.for("InstagramPet.numericLatencyProbe.v1");
  globalThis[key]?.clear();
  const state = { samples: [], timers: [], observers: [], interval: null };
  state.clear = () => { clearInterval(state.interval); state.timers.forEach(clearTimeout); state.observers.forEach(o => o.disconnect()); delete globalThis[key]; };
  globalThis[key] = state;
  const sample = () => {
    const at = performance.now();
    const row = { hidden: document.hidden ? 1 : 0, focus: document.hasFocus() ? 1 : 0,
      observerMs: null, microtaskMs: null, timerMs: null };
    state.samples.push(row);
    const detached = document.createTextNode("fixture-0");
    const observer = new MutationObserver(() => {
      row.observerMs = performance.now() - at;
      queueMicrotask(() => { row.microtaskMs = performance.now() - at; observer.disconnect(); });
      state.timers.push(setTimeout(() => { row.timerMs = performance.now() - at; }, 250));
    });
    state.observers.push(observer);
    observer.observe(detached, { characterData: true });
    detached.data = "fixture-1";
  };
  sample();
  state.interval = setInterval(() => { if (state.samples.length >= 8) clearInterval(state.interval); else sample(); }, 1000);
  return JSON.stringify({ started: 1, hidden: document.hidden ? 1 : 0, focus: document.hasFocus() ? 1 : 0 });
})()'''

READ = r'''(() => {
  const state = globalThis[Symbol.for("InstagramPet.numericLatencyProbe.v1")];
  return JSON.stringify(state ? { samples: state.samples } : { absent: 1 });
})()'''

CLEAR = r'''(() => {
  globalThis[Symbol.for("InstagramPet.numericLatencyProbe.v1")]?.clear();
  return JSON.stringify({ cleared: 1 });
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
    parser.add_argument("mode", choices=("start", "read", "clear"))
    args = parser.parse_args()
    try:
        process = subprocess.run(["osascript", "-e", APPLESCRIPT, {"start": START, "read": READ, "clear": CLEAR}[args.mode]],
                                 capture_output=True, text=True, timeout=40)
        if process.returncode:
            print(json.dumps({"automationError": process.returncode}))
            return 1
        result = json.loads(process.stdout)
        if not numeric(result):
            print(json.dumps({"invalidResult": 1}))
            return 1
        print(json.dumps({"tabs": result}, indent=2))
        return 0
    except (OSError, subprocess.TimeoutExpired, ValueError):
        print(json.dumps({"probeError": 1}))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
