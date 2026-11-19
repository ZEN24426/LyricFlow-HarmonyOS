'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const { test } = require('node:test');
const ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/LrcPreservingExport.ets'), 'utf8');
const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS } }).outputText;
const mod = { exports: {} };
vm.runInNewContext(compiled, { module: mod, exports: mod.exports, Error, Number, RegExp });
const { hasInlineLrcTiming, plainLrcFromEnhanced } = mod.exports;

test('ordinary export removes only valid inline timestamps and preserves metadata, CRLF and repeated lines', () => {
  const original = '[ti:歌]\r\n[offset:-20]\r\n[x-private:abc]\r\n\r\n' +
    '[00:01.234][00:02.345]<00:01.234>你<00:01.567>好 <love>\r\n' +
    '[00:01.234]译文\r\n[00:01.234]译文\r\n';
  assert.equal(hasInlineLrcTiming(original), true);
  assert.equal(plainLrcFromEnhanced(original), '[ti:歌]\r\n[offset:-20]\r\n[x-private:abc]\r\n\r\n' +
    '[00:01.234][00:02.345]你好 <love>\r\n[00:01.234]译文\r\n[00:01.234]译文\r\n');
  assert.ok(original.includes('<00:01.234>'));
});

test('ordinary LRC stays unchanged, including its blank lines and offset', () => {
  const text = '[offset:123]\n[00:01.00]one\n\n[00:02.00]two\n';
  assert.equal(hasInlineLrcTiming(text), false);
  assert.equal(plainLrcFromEnhanced(text), text);
});

test('ambiguous inline timing and non-timed lines fail closed', () => {
  for (const text of ['[00:01.00]<00:61.00>x', '[00:01.00]<00:01:00>x',
    '[00:01.00]<00:01.00x', '[00:99.00]<00:01.00>x', 'plain <00:01.00>x',
    '[00:01:20]<00:01.00>x', '[00:01]<00:01>a<+00:01>b', '[00:01]<1234:01>b']) {
    assert.throws(() => plainLrcFromEnhanced(text));
  }
});
