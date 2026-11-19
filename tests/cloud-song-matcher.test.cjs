'use strict';
// Run with: LYRICFLOW_TYPESCRIPT_PATH=<typescript package> node --test tests/cloud-song-matcher.test.cjs
// Uses the real pure ETS module; no provider, network, or audio-writing code is mocked.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
let ts;
try { ts = require('typescript'); }
catch (error) {
  if (!process.env.LYRICFLOW_TYPESCRIPT_PATH) throw error;
  ts = require(process.env.LYRICFLOW_TYPESCRIPT_PATH);
}
const sourcePath = path.resolve(__dirname, '../entry/src/main/ets/services/CloudSongMatcher.ets');
const source = fs.readFileSync(sourcePath, 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
  reportDiagnostics: true
});
assert.equal((compiled.diagnostics || []).filter(d => d.category === ts.DiagnosticCategory.Error).length, 0);
const moduleValue = { exports: {} };
// Export only this internal pure boundary predicate to exercise 9/10 explicitly.
// Real 55/30/5/10 scoring produces multiples of five, so a nine-point gap cannot
// be obtained through metadata fixtures without altering the production policy.
vm.runInNewContext(compiled.outputText + '\nmodule.exports.testClearLead = hasClearLead;', {
  module: moduleValue, exports: moduleValue.exports, Map, Number, String, JSON, Math
});
const { CloudSongMatcher: matcher, testClearLead } = moduleValue.exports;
const local = (overrides = {}) => ({ title: '晴天', artist: '周杰伦', album: '叶惠美', durationMs: 269000, ...overrides });
const song = (overrides = {}) => ({ source: 'provider-a', id: '1', title: '晴天', artists: ['周杰伦'], album: '叶惠美', durationMs: 269000, ...overrides });
const first = (a = {}, b = {}) => matcher.rank(local(a), [song(b)]).candidates[0];

test('keyword trims fields and skips blanks', () => {
  assert.equal(matcher.buildKeyword(local({ title: ' 晴天 ', artist: ' 周杰伦 ' })), '晴天 周杰伦');
  assert.equal(matcher.buildKeyword(local({ title: ' ', artist: '周杰伦' })), '周杰伦');
  assert.equal(matcher.buildKeyword(local({ title: '', artist: '\t' })), '');
});

test('exact metadata yields score 100 and a recommendation', () => {
  const result = matcher.rank(local(), [song()]);
  assert.equal(result.candidates[0].score, 100);
  assert.equal(result.candidates[0].reliable, true);
  assert.equal(result.recommendedId, '1');
  assert.equal(result.automatic, true);
  assert.ok(result.candidates[0].evidence.length >= 4);
});

test('NFKC, Unicode letters/numbers, punctuation and case normalization', () => {
  const result = matcher.rank(local({ title: 'ＡＢＣ　晴天', artist: 'Ｂｅｙｏｎｃé', album: '专辑１' }), [
    song({ title: 'abc-晴天', artists: ['Beyonce\u0301'], album: '专辑1' })
  ]);
  assert.equal(result.automatic, true);
  assert.equal(result.candidates[0].score, 100);
  assert.equal(first({ title: '晴天' }, { title: '雨天' }).reliable, false);
});

test('combining marks distinguish letters in Indic scripts while canonical equivalents agree', () => {
  for (const [left, right] of [['क', 'का'], ['க', 'கி']]) {
    const candidate = first({ title: left }, { title: right });
    assert.equal(candidate.reliable, false, `${left} and ${right} are distinct`);
    assert.ok(candidate.warnings.some(w => w.includes('标题不一致')) ||
      candidate.evidence.some(e => e.includes('仅部分相同')));
    assert.equal(first({ artist: left }, { artists: [right] }).reliable, false);
  }
  assert.equal(first({ title: 'Cafe\u0301' }, { title: 'Café' }).reliable, true);
  assert.equal(first({ artist: '\u0301' }, { artists: ['\u0301'] }).reliable, false);
  assert.equal(first({ title: '\u0301' }, { title: '\u0301' }).reliable, false);
});

test('significant title symbols veto recommendation without changing ranking weights', () => {
  for (const [left, right] of [['A+B', 'AB'], ['A/B', 'AB'], ['A&B', 'AB'], ['C#', 'C'], ['A+B', 'AB+']]) {
    const result = matcher.rank(local({ title: left }), [song({ title: right })]);
    assert.equal(result.candidates[0].score, 100, `${left} vs ${right}`);
    assert.equal(result.candidates[0].reliable, false, `${left} vs ${right}`);
    assert.equal(result.automatic, false, `${left} vs ${right}`);
    assert.ok(result.candidates[0].warnings.some(w => w.includes('标题中') && w.includes('差异')));
  }
  assert.equal(first({ title: 'Ａ＋Ｂ' }, { title: 'A+B' }).reliable, true);
  assert.equal(first({ title: 'C＃' }, { title: 'C#' }).reliable, true);
  assert.equal(first({ title: 'A-B' }, { title: 'A B' }).reliable, true);
});

test('significant symbols in structured artist names are checked without treating duet separators as part of an artist', () => {
  const mismatch = first({ artist: 'AC/DC' }, { artists: ['ACDC'] });
  assert.equal(mismatch.score, 100);
  assert.equal(mismatch.reliable, false);
  assert.ok(mismatch.warnings.some(w => w.includes('歌手名中') && w.includes('差异')));
  assert.equal(first({ artist: 'AC/DC' }, { artists: ['AC/DC'] }).reliable, true);
  assert.equal(first({ artist: 'A / B' }, { artists: ['B', 'A'] }).reliable, true);
  assert.equal(first({ artist: 'AC/DC / Bob' }, { artists: ['Bob', 'AC/DC'] }).reliable, true);
  const duet = first({ artist: 'ACDC / Bob' }, { artists: ['Bob', 'AC/DC'] });
  assert.equal(duet.reliable, false);
  assert.ok(duet.warnings.some(w => w.includes('歌手名中')));
  assert.equal(first({ artist: 'AC/DC' }, { artists: ['AC/DC', 'ACDC'] }).reliable, false);
  assert.equal(first({ artist: 'A＆B' }, { artists: ['A&B'] }).reliable, true);
  assert.equal(first({ artist: 'A&B' }, { artists: ['AB'] }).reliable, false);
});

test('empty title or artist is never reliable despite album and duration', () => {
  for (const empty of ['', ' ', '()']) {
    assert.equal(first({ title: empty }, { title: empty }).reliable, false);
    assert.equal(first({ artist: empty }, { artists: [empty] }).reliable, false);
  }
  assert.equal(first({}, { artists: [] }).reliable, false);
  const result = matcher.rank(local({ title: '', artist: '', album: '', durationMs: 0 }), []);
  assert.equal(result.automatic, false);
  assert.equal(result.recommendedId, '');
});

test('partial title and partial singer only create review candidates', () => {
  assert.equal(first({}, { title: '晴天纪念版' }).score, 65);
  assert.equal(first({}, { title: '晴天纪念版' }).reliable, false);
  assert.equal(first({ title: '晴天纪念版' }).reliable, false);
  const duet = first({}, { artists: ['周杰伦', '另一位歌手'] });
  assert.equal(duet.score, 80);
  assert.equal(duet.reliable, false);
});

test('structured artist set tolerates order and repeated names', () => {
  const candidate = first({ artist: '周杰伦 / 费玉清' }, { artists: ['费玉清', '周杰伦', '周杰伦'] });
  assert.equal(candidate.score, 100);
  assert.equal(candidate.reliable, true);
  assert.equal(first({ artist: '周杰伦 feat. 费玉清' }, { artists: ['费玉清', '周杰伦'] }).reliable, true);
  assert.equal(first({ artist: '周杰伦、费玉清' }, { artists: ['费玉清', '周杰伦'] }).reliable, true);
});

test('AC/DC remains one artist and cannot match split AC and DC automatically', () => {
  assert.equal(first({ artist: 'AC/DC' }, { artists: ['AC/DC'] }).reliable, true);
  const split = first({ artist: 'AC/DC' }, { artists: ['AC', 'DC'] });
  assert.equal(split.reliable, false);
  assert.ok(split.warnings.some(w => w.includes('艺名')));
});

test('Earth, Wind & Fire and ampersand band names do not become automatic duets', () => {
  assert.equal(first({ artist: 'Earth, Wind & Fire' }, { artists: ['Earth, Wind & Fire'] }).reliable, true);
  assert.equal(first({ artist: 'Earth, Wind & Fire' }, { artists: ['Earth', 'Wind', 'Fire'] }).reliable, false);
  assert.equal(first({ artist: 'Simon & Garfunkel' }, { artists: ['Simon', 'Garfunkel'] }).reliable, false);
});

test('2 second duration boundary adds ten points inclusively', () => {
  assert.equal(first({}, { durationMs: 271000 }).score, 100);
  assert.equal(first({}, { durationMs: 271001 }).score, 90);
  assert.equal(first({}, { durationMs: 267000 }).score, 100);
});

test('duration gray zone needs same album; over 5 seconds is a veto', () => {
  assert.equal(first({}, { durationMs: 274000 }).reliable, true);
  assert.equal(first({}, { durationMs: 274001 }).reliable, false);
  assert.ok(first({}, { durationMs: 274001 }).warnings.includes('时长差超过5秒，不自动推荐'));
  assert.equal(first({}, { durationMs: 272000, album: '别的专辑' }).reliable, false);
  assert.equal(first({}, { durationMs: 272000, album: '叶惠美' }).reliable, true);
});

test('missing duration can use album, invalid duration never earns time points or recommendation', () => {
  assert.equal(first({ durationMs: 0 }).score, 90);
  assert.equal(first({ durationMs: 0 }).reliable, true);
  assert.equal(first({ durationMs: 0 }, { album: '' }).reliable, false);
  for (const invalid of [NaN, Infinity, -1]) {
    for (const candidate of [first({ durationMs: invalid }), first({}, { durationMs: invalid })]) {
      assert.equal(candidate.score, 90);
      assert.equal(candidate.reliable, false);
      assert.ok(candidate.warnings.some(w => w.includes('时长字段无效')));
    }
  }
});

test('significant album symbols cannot provide album points or corroborate a missing duration', () => {
  for (const [left, right] of [['C#', 'C'], ['A+B', 'AB'], ['A/B', 'AB'], ['A&B', 'AB']]) {
    for (const [localAlbum, cloudAlbum] of [[left, right], [right, left]]) {
      const missing = first({ album: localAlbum, durationMs: 0 }, { album: cloudAlbum, durationMs: 0 });
      assert.equal(missing.score, 85, `${localAlbum} vs ${cloudAlbum}`);
      assert.equal(missing.reliable, false, `${localAlbum} vs ${cloudAlbum}`);
      assert.ok(missing.warnings.some(w => w.includes('专辑名中') && w.includes('差异')));
      assert.ok(!missing.evidence.some(e => e.includes('专辑相同')));
      const near = first({ album: localAlbum }, { album: cloudAlbum });
      assert.equal(near.score, 95);
      assert.equal(near.reliable, true, 'an independently close duration still corroborates the match');
      assert.ok(near.warnings.some(w => w.includes('专辑名中')));
      assert.equal(first({ album: localAlbum }, { album: cloudAlbum, durationMs: 272000 }).reliable, false);
    }
  }
  assert.equal(first({ album: 'Ａ＋Ｂ', durationMs: 0 }, { album: 'A+B', durationMs: 0 }).reliable, true);
  assert.equal(first({ album: 'C＃', durationMs: 0 }, { album: 'C#', durationMs: 0 }).reliable, true);
  assert.equal(first({ album: 'A-B', durationMs: 0 }, { album: 'A B', durationMs: 0 }).reliable, true);
});

test('live, accompaniment, remix and acoustic disagreements block recommendation', () => {
  for (const suffix of ['Live', '现场版', '伴奏', 'Instrumental', 'Remix', 'Acoustic', 'off vocal']) {
    const candidate = first({}, { title: `晴天 (${suffix})` });
    assert.equal(candidate.reliable, false, suffix);
    assert.ok(candidate.warnings.some(w => w.includes('版本标记不一致')), suffix);
  }
  assert.equal(first({ title: '晴天 (Live)' }, { title: '晴天-Live' }).reliable, true);
  assert.equal(first({ title: '晴天 (Live)' }, { title: '晴天' }).reliable, false);
});

test('album version markers require review when the titles alone hide a version difference', () => {
  for (const album of ['周杰伦演唱会', 'Live at Taipei', '晴天伴奏精选', 'Remix Collection']) {
    const candidate = first({}, { title: '晴天', album });
    assert.equal(candidate.score, 95, album);
    assert.equal(candidate.reliable, false, album);
    assert.ok(candidate.warnings.some(w => w.includes('版本标记不一致') && w.includes('专辑含')), album);
  }
  const localLive = first({ album: '演唱会现场' }, { album: '普通专辑' });
  assert.equal(localLive.reliable, false);
  assert.ok(localLive.warnings.some(w => w.includes('本地专辑含')));
  assert.equal(first({ album: '演唱会现场' }, { album: '演唱会现场' }).reliable, true);
  assert.equal(first({ title: '晴天 (Live)', album: '普通专辑' },
    { title: '晴天-Live', album: 'Live at Taipei' }).reliable, true);
  assert.equal(first({ album: '叶惠美' }, { album: '精选集' }).reliable, true);
});

test('deduplicate by platform and id, preserving the better evidence', () => {
  const result = matcher.rank(local(), [
    song({ title: '雨天' }), song(), song({ source: 'provider-b' }), song({ id: '2', title: '雨天' })
  ]);
  assert.equal(result.candidates.length, 3);
  assert.equal(result.candidates[0].score, 100);
  assert.equal(result.candidates[1].score, 100);
  assert.equal(result.automatic, false);
  assert.equal(result.recommendedId, '');
});

test('empty provider identifiers are not selectable candidates', () => {
  assert.equal(matcher.rank(local(), [song({ id: '' }), song({ source: ' ' })]).candidates.length, 0);
});

test('real ranking requires a full ten-point lead', () => {
  const five = matcher.rank(local(), [song(), song({ id: '2', album: '精选' })]);
  assert.equal(five.candidates[0].score - five.candidates[1].score, 5);
  assert.equal(five.automatic, false);
  const ten = matcher.rank(local(), [song(), song({ id: '2', durationMs: 272000 })]);
  assert.equal(ten.candidates[0].score - ten.candidates[1].score, 10);
  assert.equal(ten.automatic, true);
});

test('recommendation gap boundary rejects 9 and accepts 10', () => {
  assert.equal(testClearLead(100, 91), false);
  assert.equal(testClearLead(100, 90), true);
  assert.equal(testClearLead(100, 100), false);
  assert.equal(testClearLead(100, NaN), false);
});

test('editing a keyword disables recommendation without altering candidate scores', () => {
  const result = matcher.rank(local(), [song()], false);
  assert.equal(result.candidates[0].reliable, true);
  assert.equal(result.candidates[0].score, 100);
  assert.equal(result.automatic, false);
  assert.equal(result.recommendedId, '');
});

test('inputs and structured artist order remain unchanged', () => {
  const identity = local({ artist: 'A / B' });
  const songs = [song({ artists: ['B', 'A'] })];
  const before = JSON.stringify({ identity, songs });
  matcher.rank(identity, songs);
  assert.equal(JSON.stringify({ identity, songs }), before);
});
