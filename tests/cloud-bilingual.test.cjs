'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');

const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/CloudBilingualLyrics.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
const mod = { exports: {} };
vm.runInNewContext(js, { module: mod, exports: mod.exports, Error });
const { combineCloudLyrics: combine } = mod.exports;

test('same millisecond outputs original above translation without changing either body', () => {
  const result = combine('[ti:Fixture]\n[00:01.10]first <00:01.11>word\n[00:02.250]second',
    '[ar:Singer]\n[00:01.100]翻译一\n[00:02.25]翻译二');
  assert.equal(result.error, '');
  assert.equal(result.text, '[ti:Fixture]\n[ar:Singer]\n[00:01.10]first <00:01.11>word\n[00:01.100]翻译一\n[00:02.250]second\n[00:02.25]翻译二');
  assert.match(result.warning, /播放器/);
});

test('unmatched timed lines are retained at their own times, never forced into an adjacent pair', () => {
  const result = combine('[00:01.000]original\n[00:03.000]only original',
    '[00:01.001]only translation\n[00:03.000]matched translation');
  assert.equal(result.error, '');
  assert.equal(result.text, '[00:01.000]original\n[00:01.001]only translation\n[00:03.000]only original\n[00:03.000]matched translation');
  assert.match(result.warning, /2 行没有同时间配对/);
});

test('offsets are unified without moving effective event times', () => {
  const result = combine('[offset:100]\n[00:01.200]original', '[offset:-50]\n[00:01.050]translation');
  assert.equal(result.error, '');
  assert.equal(result.text, '[offset:100]\n[00:01.200]original\n[00:01.200]translation');
  assert.match(result.warning, /offset/);
  const noOriginalOffset = combine('[00:00.200]original', '[offset:100]\n[00:00.300]translation');
  assert.equal(noOriginalOffset.text, '[00:00.200]original\n[00:00.200]translation');
});

test('multiple timestamps are expanded with every event and repeated body preserved', () => {
  const result = combine('[00:01.00][00:03.00]refrain', '[00:01.00][00:03.00]副歌');
  assert.equal(result.error, '');
  assert.equal(result.text, '[00:01.00]refrain\n[00:01.00]副歌\n[00:03.00]refrain\n[00:03.00]副歌');
});

test('rejects ambiguous or unsupported layouts instead of losing content or guessing', () => {
  const pairs = [
    ['[00:01]one\n[00:01]two', '[00:01]译'],
    ['[00:01]one', '[00:01]一\n[00:01]二'],
    ['[offset:0]\n[offset:2]\n[00:01]one', '[00:01]一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:00]一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:01]<00:01.20>一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:01]<00:00:01.20>一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:01]< 00:01.20>一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:01]<+00:01.20>一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:01]<-00 : 01.20>一'],
    ['[offset:0]\n[00:01]one', '[offset:50]\n[00:01]<0000:01.20>一'],
    ['[ti:one]\n[00:01]one', '[ti:other]\n[00:01]一'],
    ['[00:01]one', '没有时间的译文'],
    ['[00:01]one\n[chorus]', '[00:01]一'],
    ['[00:60.00]one', '[00:01]一'],
    ['[00:01:200]one', '[00:01]一'],
    ['[00:01]one [00:02]unexpected', '[00:01]一'],
    ['[00:01]one', ''],
  ];
  for (const [a, b] of pairs) {
    const result = combine(a, b);
    assert.equal(result.text, '', `${a} / ${b}`);
    assert.match(result.error, /无法安全合并/);
  }
});

test('ordinary angle-bracket text remains unchanged when translation offset is normalized', () => {
  const result = combine('[00:01.00]original', '[offset:50]\n[00:01.05]<note>译文');
  assert.equal(result.error, '');
  assert.equal(result.text, '[00:01.00]original\n[00:01.000]<note>译文');
});

test('input and expanded output are bounded', () => {
  assert.match(combine('[00:01]' + 'x'.repeat(256 * 1024), '[00:01]一').error, /过长/);
  assert.match(combine('[00:01]one\n'.repeat(10001), '[00:01]一').error, /时间点过多/);
  assert.match(combine('[00:01]'.repeat(2000) + 'x'.repeat(1000), '[00:02]一').error, /过长/);
});
