#!/usr/bin/env node
// 과거 git ref의 extension/content.js와 현재 작업 트리의 것을 비교하는 합성 타이머 정렬 모델.
// 실제 Chrome이나 실제 Instagram 수신을 측정하는 것이 아니다.
// 실행: node scripts/benchmark-content-latency.cjs [git ref, 기본값 6892cc4]
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { contentHarness } = require('../extension/tests/helpers/content-harness.cjs');

async function measure(source, quantum) {
  const samples = [];
  for (let index = 0; index < 20; index++) {
    const f = contentHarness({ source, timerQuantum: quantum });
    const baseline = quantum ? Math.ceil(10250 / quantum) * quantum : 10250;
    await f.advance(baseline);
    const at = baseline + 100 + index * 37;
    await f.advance(at);
    f.mutate();
    await f.drain();
    if (!f.observations.length) await f.advance(quantum ? Math.ceil((at + 250) / quantum) * quantum : at + 250);
    if (f.observations.length !== 1) throw new Error('Synthetic message was not delivered exactly once');
    samples.push(f.observations[0].at - at);
  }
  samples.sort((a, b) => a - b);
  return { samples: samples.length, minMs: samples[0], medianMs: samples[Math.floor(samples.length / 2)],
    p95Ms: samples[Math.ceil(samples.length * 0.95) - 1], maxMs: samples.at(-1) };
}

(async () => {
  const root = path.resolve(__dirname, '..');
  const beforeRef = process.argv[2] || '6892cc4';
  const before = execFileSync('git', ['show', beforeRef + ':extension/content.js'], { cwd: root, encoding: 'utf8' });
  const after = fs.readFileSync(path.join(root, 'extension/content.js'), 'utf8');
  const scenarios = [];
  for (const timerQuantumMs of [0, 1000, 60000]) scenarios.push({ timerQuantumMs,
    before: await measure(before, timerQuantumMs), after: await measure(after, timerQuantumMs) });
  console.log(JSON.stringify({ measurement: 'synthetic-timer-alignment-model', realChrome: false, beforeRef, scenarios }, null, 2));
})().catch(() => { console.error('Synthetic latency benchmark failed'); process.exitCode = 1; });
