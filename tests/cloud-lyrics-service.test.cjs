'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const root = path.resolve(__dirname, '../entry/src/main/ets/services');

function compile(name, imports = {}, environment = {}) {
  const result = { exports: {} };
  const source = ts.transpileModule(fs.readFileSync(path.join(root, name + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  vm.runInNewContext(source, {
    module: result, exports: result.exports,
    require: key => imports[key] || {},
    setTimeout, clearTimeout, console, ...environment
  }, { filename: name + '.ets' });
  return result.exports;
}

const protocol = compile('CloudLyricsProtocol');
const song = { source: 'netease', id: '186016', title: 'Fixture', artists: ['Singer'], album: 'Album', durationMs: 120000 };
const searchBody = (id = '186016') => JSON.stringify({ code: 200, result: {
  songCount: 1, songs: [{ id, name: 'Fixture', artists: [{ name: 'Singer' }], album: { name: 'Album' }, duration: 120000 }]
} });
const lyricsBody = JSON.stringify({ code: 200, lrc: { lyric: '[00:01.00]synthetic fixture' }, tlyric: { lyric: '[00:01.00]合成测试' } });
const kind = expected => error => error.kind === expected;
const plain = value => JSON.parse(JSON.stringify(value));
const flush = async () => { for (let i = 0; i < 15; i++) await Promise.resolve(); };

function harness(respond = () => ({ responseCode: 200, result: searchBody() })) {
  let clock = 100000;
  let nextTimer = 0;
  const timers = new Map();
  const calls = [];
  const clients = [];
  class FakeDate extends Date { static now() { return clock; } }
  const http = {
    RequestMethod: { GET: 'GET' }, HttpDataType: { STRING: 0 },
    createHttp() {
      const client = {
        destroyed: 0,
        request(url, options) {
          calls.push({ url, options, at: clock });
          return Promise.resolve().then(() => respond({ url, options, client, index: calls.length - 1 }));
        },
        destroy() { this.destroyed++; }
      };
      clients.push(client);
      return client;
    }
  };
  const env = {
    Date: FakeDate,
    setTimeout(callback, ms) { const id = ++nextTimer; timers.set(id, { callback, due: clock + ms }); return id; },
    clearTimeout(id) { timers.delete(id); }
  };
  const systemDateTime = { TimeType: { STARTUP: 0 }, getUptime: () => clock };
  const Service = compile('CloudLyricsService', { '@kit.NetworkKit': { http }, '@kit.BasicServicesKit': { systemDateTime }, './CloudLyricsProtocol': protocol }, env).CloudLyricsService;
  async function advance(ms) {
    clock += ms;
    for (let i = 0; i < 20; i++) {
      for (const [id, timer] of [...timers]) {
        if (timer.due <= clock) { timers.delete(id); timer.callback(); }
      }
      await flush();
    }
  }
  return { service: new Service(), newService: () => new Service(), calls, clients, advance, timers };
}

test('separate services share the request interval and cancelling a waiter cannot bypass the active request', async () => {
  let releaseFirst;
  const h = harness(({ index }) => index === 0
    ? new Promise(resolve => { releaseFirst = resolve; })
    : { responseCode: 200, result: searchBody('2') });
  const first = h.service.searchDetailed('first');
  await flush();
  assert.equal(h.calls.length, 1);
  const cancelledService = h.newService();
  const cancelled = cancelledService.searchDetailed('cancelled');
  const cancellation = assert.rejects(cancelled, kind('CANCELLED'));
  const third = h.newService().searchDetailed('third');
  await flush();
  cancelledService.cancel();
  await cancellation;
  await flush();
  assert.equal(h.calls.length, 1);
  releaseFirst({ responseCode: 200, result: searchBody() });
  await first;
  await flush();
  assert.equal(h.calls.length, 1);
  await h.advance(499);
  assert.equal(h.calls.length, 1);
  await h.advance(1);
  await third;
  assert.equal(h.calls.length, 2);
  assert.ok(h.calls[1].at - h.calls[0].at >= 500);
});

test('a 429 response applies its cooldown across service instances', async () => {
  const h = harness(({ index }) => index === 0
    ? { responseCode: 429, result: '' }
    : { responseCode: 200, result: searchBody('2') });
  const retrying = h.service.searchDetailed('rate-limited');
  const cancelled = assert.rejects(retrying, kind('CANCELLED'));
  await flush();
  const other = h.newService().searchDetailed('other');
  await flush();
  await h.advance(999);
  assert.equal(h.calls.length, 1);
  await h.advance(1);
  await other;
  assert.equal(h.calls.length, 2);
  assert.ok(h.calls[1].at - h.calls[0].at >= 1000);
  h.service.cancel();
  await cancelled;
});

test('search maps anonymous API fields and preserves structured artist names', () => {
  const result = protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs: [{
    id: 186016, name: ' Fullwidth Ａ ', artists: [{ name: 'AC/DC' }], album: { name: ' Album ' }, duration: 269000
  }] } }));
  assert.deepEqual(plain(result), { songs: [{ source: 'netease', id: '186016', title: 'Fullwidth Ａ', artists: ['AC/DC'], album: 'Album', durationMs: 269000 }], incomplete: false });
});

test('identical duplicate IDs are preserved for ranking without hiding completeness', () => {
  const item = { id: '23', name: 'Song', ar: [{ name: 'Singer' }], al: { name: 'Album' }, dt: 1000 };
  const result = protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs: [item, item] } }));
  assert.equal(result.songs.length, 2);
  assert.equal(result.songs[0].durationMs, 1000);
  assert.equal(result.incomplete, false);
});

test('no result is distinct from a missing result schema', () => {
  assert.deepEqual(plain(protocol.parseCloudSearch('{"code":200,"result":{"songCount":0}}')), { songs: [], incomplete: false });
  assert.throws(() => protocol.parseCloudSearch('{"code":200}'), kind('FORMAT_CHANGED'));
});

test('partially malformed results keep good songs and mark the result incomplete', () => {
  const good = { id: 1, name: 'Song', artists: [{ name: 'Singer' }], album: { name: 'Album' }, duration: 120000 };
  const bad = { id: 2, name: 'Broken', artists: [] };
  const parsed = protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs: [bad, good] } }));
  assert.equal(parsed.incomplete, true);
  assert.equal(parsed.songs.length, 1);
  assert.equal(parsed.songs[0].id, '1');
  assert.throws(() => protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs: [bad] } })), kind('FORMAT_CHANGED'));
});

test('conflicting duplicates remain available to rank but cannot enable automatic selection', () => {
  const matcher = compile('CloudSongMatcher').CloudSongMatcher;
  const base = { id: 23, name: 'Song', artists: [{ name: 'Singer' }], album: { name: 'Album' }, duration: 120000 };
  const conflict = { ...base, name: 'Song (Live)' };
  const result = protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs: [conflict, base] } }));
  assert.equal(result.incomplete, true);
  assert.equal(result.songs.length, 2);
  const ranked = matcher.rank({ title: 'Song', artist: 'Singer', album: 'Album', durationMs: 120000 }, result.songs, !result.incomplete);
  assert.equal(ranked.candidates.length, 1);
  assert.equal(ranked.candidates[0].song.title, 'Song');
  assert.equal(ranked.automatic, false);
  assert.equal(ranked.recommendedId, '');
});

test('response entries beyond the requested 20 are not ranked and force review', () => {
  const songs = Array.from({ length: 21 }, (_, i) => ({ id: i + 1, name: 'Song ' + i, artists: [{ name: 'Singer' }] }));
  const parsed = protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs } }));
  assert.equal(parsed.songs.length, 20);
  assert.equal(parsed.incomplete, true);
  assert.equal(parsed.songs.some(s => s.id === '21'), false);
});

test('reject malformed JSON, HTML, null, array, wrong code type and unsafe IDs', () => {
  for (const body of ['<html>blocked</html>', '{', 'null', '[]', '{"code":"200","result":{}}', searchBody('12/../../evil'),
    searchBody('0'), searchBody(9007199254740992)]) {
    assert.throws(() => protocol.parseCloudSearch(body), kind('FORMAT_CHANGED'), body.slice(0, 40));
  }
});

test('check artists, duration and string boundaries', () => {
  const invalid = [
    { id: 1, name: 'x', artists: 'Singer' },
    { id: 1, name: 'x', artists: [null] },
    { id: 1, name: 'x', artists: [{ name: 'Singer' }], duration: -1 },
    { id: 1, name: 'x', artists: [{ name: 'Singer' }], duration: '1000' },
    { id: 1, name: 'x'.repeat(513), artists: [{ name: 'Singer' }] }
  ];
  for (const item of invalid) assert.throws(() => protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songs: [item] } })), kind('FORMAT_CHANGED'));
});

test('2 MiB limit counts UTF-8 bytes, including Chinese and surrogate pairs', () => {
  assert.equal(protocol.cloudBodyWithinLimit('a'.repeat(2 * 1024 * 1024)), true);
  assert.equal(protocol.cloudBodyWithinLimit('中'.repeat(699051)), false);
  assert.equal(protocol.cloudBodyWithinLimit('😀'.repeat(524289)), false);
  assert.throws(() => protocol.parseCloudSearch('x'.repeat(2 * 1024 * 1024 + 1)), kind('TOO_LARGE'));
});

test('lyrics retain separate translation and decode common HTML entities once', () => {
  const result = protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: '[00:01]a &amp; b &#39; &#x1F600; &amp;lt;' }, tlyric: { lyric: '译文' } }), '23');
  assert.deepEqual(plain(result), { source: 'netease', songId: '23', text: '[00:01]a & b \' 😀 &lt;', translation: '译文', translationWarning: '' });
});

test('valid translation can be selected when original is explicitly unavailable, with strict rejection boundaries', () => {
  for (const lrc of [undefined, { lyric: '' }, { lyric: '[00:00]暂无歌词' }]) {
    const result = protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc, tlyric: { lyric: '[00:01]译文' } }), '23');
    assert.equal(result.text, ''); assert.equal(result.translation, '[00:01]译文');
  }
  for (const body of [
    { code: 200, nolyric: true, tlyric: { lyric: '译文' } },
    { code: 200, lrc: { lyric: '[00:00]纯音乐 请欣赏' }, tlyric: { lyric: '译文' } }
  ]) assert.throws(() => protocol.parseCloudLyrics(JSON.stringify(body), '23'), kind('PURE_MUSIC'));
  assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, uncollected: true, tlyric: { lyric: '译文' } }), '23'), kind('NO_LYRICS'));
  for (const lrc of [null, { lyric: '<html>bad</html>' }, { lyric: null }, 'bad']) {
    assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc, tlyric: { lyric: '译文' } }), '23'), kind('FORMAT_CHANGED'));
  }
  assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: '' }, tlyric: { lyric: null } }), '23'), kind('FORMAT_CHANGED'));
  assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: '' }, tlyric: { lyric: '[00:00]暂无歌词' } }), '23'), kind('NO_LYRICS'));
});

test('pure music, no lyrics, platform rejection and format change remain separate', () => {
  assert.throws(() => protocol.parseCloudLyrics('{"code":200,"nolyric":true}', '23'), kind('PURE_MUSIC'));
  assert.throws(() => protocol.parseCloudLyrics('{"code":200,"lrc":{"lyric":"[00:00.00]纯音乐，请欣赏"}}', '23'), kind('PURE_MUSIC'));
  assert.throws(() => protocol.parseCloudLyrics('{"code":200,"uncollected":true}', '23'), kind('NO_LYRICS'));
  assert.throws(() => protocol.parseCloudLyrics('{"code":200,"lrc":{"lyric":""}}', '23'), kind('NO_LYRICS'));
  assert.throws(() => protocol.parseCloudLyrics('{"code":50000005}', '23'), kind('REJECTED'));
  assert.throws(() => protocol.parseCloudLyrics('{"code":200}', '23'), kind('FORMAT_CHANGED'));
  assert.throws(() => protocol.parseCloudLyrics('{"code":200,"lrc":{"lyric":7}}', '23'), kind('FORMAT_CHANGED'));
});

test('reject HTML and error JSON masquerading as lyric content', () => {
  for (const text of ['<!doctype html><html>blocked</html>', '{"code":403,"error":"blocked"}']) {
    assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: text } }), '23'), kind('FORMAT_CHANGED'));
  }
});

test('metadata only, timestamp only and no-lyrics placeholders are not usable lyrics', () => {
  for (const text of ['[by:someone]', '[ti:Fixture]\n[00:01.00]\n[00:02.00]', '暂无歌词', '[00:00]暂无歌词，敬请期待', 'No lyrics found.']) {
    assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: text } }), '23'), kind('NO_LYRICS'));
  }
});

test('corrupt optional translations warn without hiding usable original lyrics', () => {
  for (const translation of [{ lyric: '[00:00]<html>blocked</html>' }, { lyric: '{"error":"denied"}' }, { lyric: null }, 'malformed']) {
    const result = protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: '[00:00]fixture' }, tlyric: translation }), '23');
    assert.equal(result.text, '[00:00]fixture');
    assert.equal(result.translation, '');
    assert.notEqual(result.translationWarning, '');
  }
  for (const text of ['', '[by:test]', '[00:00]', '暂无歌词', '[00:00]纯音乐，请欣赏']) {
    const result = protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: '[00:00]fixture' }, tlyric: { lyric: text } }), '23');
    assert.equal(result.translation, '');
    assert.equal(result.translationWarning, '');
    assert.equal(result.text, '[00:00]fixture');
  }
});

test('instrumental notices with only credits are not returned as lyrics', () => {
  const examples = [
    '[by:test]\n[00:00.00]作曲 : 某\n[00:01.00]编曲：某\n[00:02.00]制作人 : 甲\n[00:03.00]纯音乐，请欣赏',
    '[00:00]Composed: Person\n[00:02]Instrumental, please enjoy.',
    '[00:00][00:01][ti:测试]\n[00:03]此歌曲为没有填词的纯音乐，请您欣赏！',
    '[00:00]作曲: 甲\r[00:01]纯音乐，请欣赏'
  ];
  for (const text of examples) {
    assert.throws(() => protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: text } }), '23'), kind('PURE_MUSIC'));
  }
});

test('lyrics with ordinary lines are preserved even near an instrumental notice', () => {
  const examples = [
    '[00:00]作曲：甲\n[00:02]纯音乐，请欣赏\n[00:03]这是实际歌词',
    '[00:00]纯音乐，请欣赏\n[00:03]作词不容易',
    '[00:00]纯音乐，请欣赏\n[00:03]Lyrics: this is real text',
    '[00:00]纯音乐，请欣赏\n[00:01][合唱]',
    '[00:00][合唱]'
  ];
  for (const text of examples) {
    const result = protocol.parseCloudLyrics(JSON.stringify({ code: 200, lrc: { lyric: text } }), '23');
    assert.equal(result.text, text);
  }
});

test('service applies host, TLS, timeout, redirect and response limits without credentials', async () => {
  const h = harness();
  await h.service.search('title & artist');
  const call = h.calls[0];
  assert.equal(new URL(call.url).origin, 'https://music.163.com');
  assert.equal(new URL(call.url).searchParams.get('s'), 'title & artist');
  assert.equal(call.options.maxRedirects, 0);
  assert.equal(call.options.maxLimit, 2 * 1024 * 1024);
  assert.equal(call.options.connectTimeout, 10000);
  assert.equal(call.options.readTimeout, 10000);
  assert.equal(call.options.remoteValidation, 'system');
  assert.equal(call.options.usingCache, false);
  assert.equal(Object.keys(call.options.header).some(k => /cookie|authorization/i.test(k)), false);
  assert.equal(h.clients[0].destroyed, 1);
});

test('search cache is cloned and bounded to 24 entries; empty results cached', async () => {
  const h = harness();
  const first = await h.service.search('song');
  first[0].artists[0] = 'mutated';
  assert.equal((await h.service.search('song'))[0].artists[0], 'Singer');
  assert.equal(h.calls.length, 1);
  for (let i = 0; i < 24; i++) { const p = h.service.search('song' + i); await h.advance(500); await p; }
  const p = h.service.search('song'); await h.advance(500); await p;
  assert.equal(h.calls.length, 26);
  const empty = harness(() => ({ responseCode: 200, result: '{"code":200,"result":{"songCount":0}}' }));
  await empty.service.search('empty'); await empty.service.search('empty');
  assert.equal(empty.calls.length, 1);
});

test('partial-search safety flag and song copies survive cache hits and the legacy wrapper', async () => {
  const raw = { code: 200, result: { songs: [
    { id: 23, name: 'Song', artists: [{ name: 'Singer' }], album: { name: 'Album' }, duration: 120000 },
    { id: 24, name: 'Broken', artists: [] }
  ] } };
  const h = harness(() => ({ responseCode: 200, result: JSON.stringify(raw) }));
  const first = await h.service.searchDetailed('song');
  assert.equal(first.incomplete, true);
  first.incomplete = false;
  first.songs[0].artists[0] = 'mutated';
  const cached = await h.service.searchDetailed('song');
  assert.equal(cached.incomplete, true);
  assert.equal(cached.songs[0].artists[0], 'Singer');
  const legacy = await h.service.search('song');
  legacy[0].title = 'changed';
  assert.equal((await h.service.searchDetailed('song')).songs[0].title, 'Song');
  assert.equal(h.calls.length, 1);
});

test('lyrics cache retains identity, is cloned, and is bounded to 8 entries', async () => {
  const h = harness(() => ({ responseCode: 200, result: lyricsBody }));
  const result = await h.service.lyrics(song); result.text = 'mutated';
  const cached = await h.service.lyrics(song);
  assert.equal(cached.text, '[00:01.00]synthetic fixture');
  assert.equal(cached.songId, song.id);
  for (let i = 1; i <= 8; i++) { const p = h.service.lyrics({ ...song, id: String(i) }); await h.advance(500); await p; }
  const p = h.service.lyrics(song); await h.advance(500); await p;
  assert.equal(h.calls.length, 10);
});

test('translation warnings persist through cached copies without losing original lyrics', async () => {
  const body = JSON.stringify({ code: 200, lrc: { lyric: '[00:01]valid original' }, tlyric: { lyric: null } });
  const h = harness(() => ({ responseCode: 200, result: body }));
  const first = await h.service.lyrics(song);
  assert.notEqual(first.translationWarning, '');
  first.translationWarning = '';
  first.text = 'mutated';
  const cached = await h.service.lyrics(song);
  assert.equal(cached.text, '[00:01]valid original');
  assert.notEqual(cached.translationWarning, '');
  assert.equal(cached.translation, '');
  assert.equal(h.calls.length, 1);
});

test('translation-only result stays intact and independent on cache hits', async () => {
  const body = JSON.stringify({ code: 200, lrc: { lyric: '' }, tlyric: { lyric: '[00:01]译文' } });
  const h = harness(() => ({ responseCode: 200, result: body }));
  const first = await h.service.lyrics(song);
  assert.equal(first.text, ''); assert.equal(first.translation, '[00:01]译文');
  first.translation = 'mutated';
  const cached = await h.service.lyrics(song);
  assert.equal(cached.text, ''); assert.equal(cached.translation, '[00:01]译文'); assert.equal(h.calls.length, 1);
});

test('expired cache refetches', async () => {
  const h = harness(); await h.service.search('song'); await h.advance(600001); await h.service.search('song');
  assert.equal(h.calls.length, 2);
});

test('requests serialize and start at least 500 ms apart', async () => {
  let resolveFirst;
  const h = harness(({ index }) => index === 0 ? new Promise(resolve => { resolveFirst = resolve; }) : ({ responseCode: 200, result: searchBody() }));
  const a = h.service.search('a'); const b = h.service.search('b');
  await flush(); assert.equal(h.calls.length, 1);
  resolveFirst({ responseCode: 200, result: searchBody() }); await a; await flush();
  assert.equal(h.calls.length, 1);
  await h.advance(500); await b;
  assert.ok(h.calls[1].at - h.calls[0].at >= 500);
});

test('HTTP 429 and 503 retry twice with bounded backoff', async () => {
  const h = harness(({ index }) => ({ responseCode: index < 2 ? (index === 0 ? 429 : 503) : 200, result: searchBody() }));
  const pending = h.service.search('song'); await flush(); assert.equal(h.calls.length, 1);
  await h.advance(1000); assert.equal(h.calls.length, 2);
  await h.advance(2000); await pending; assert.equal(h.calls.length, 3);
  const rejected = harness(() => ({ responseCode: 429, result: '' }));
  const p = assert.rejects(rejected.service.search('song'), kind('RATE_LIMIT'));
  await flush(); await rejected.advance(1000); await rejected.advance(2000); await p;
  assert.equal(rejected.calls.length, 3);
});

test('transient network failures retry, certificate and schema failures do not', async () => {
  const h = harness(({ index }) => { if (index < 2) throw Object.assign(new Error('timeout'), { code: 2300028 }); return { responseCode: 200, result: searchBody() }; });
  const p = h.service.search('song'); await flush(); await h.advance(1000); await h.advance(2000); await p;
  assert.equal(h.calls.length, 3);
  for (const [code, expected] of [[2300060, 'NETWORK'], [2300047, 'REJECTED'], [2300063, 'TOO_LARGE']]) {
    const bad = harness(() => { throw Object.assign(new Error('failure'), { code }); });
    await assert.rejects(bad.service.search('song'), kind(expected)); assert.equal(bad.calls.length, 1);
  }
  const badJson = harness(() => ({ responseCode: 200, result: '<html>' }));
  await assert.rejects(badJson.service.search('song'), kind('FORMAT_CHANGED')); assert.equal(badJson.calls.length, 1);
});

test('active cancellation destroys HTTP immediately and rejects without waiting for transport', async () => {
  let oldResponse;
  const h = harness(({ index }) => index === 0 ? new Promise(resolve => { oldResponse = resolve; }) : ({ responseCode: 200, result: searchBody('42') }));
  const old = assert.rejects(h.service.search('old'), kind('CANCELLED'));
  await flush(); h.service.cancel();
  assert.ok(h.clients[0].destroyed >= 1); await old;
  const fresh = h.service.search('fresh'); await h.advance(500);
  assert.equal((await fresh)[0].id, '42');
  oldResponse({ responseCode: 200, result: searchBody('99') }); await flush();
  assert.equal((await h.service.search('fresh'))[0].id, '42');
  assert.equal(h.clients[1].destroyed, 1);
});

test('cancel clears queued work while a platform cooldown still protects new requests', async () => {
  const h = harness(({ index }) => ({ responseCode: index === 0 ? 503 : 200, result: searchBody() }));
  const first = assert.rejects(h.service.search('first'), kind('CANCELLED'));
  const queued = assert.rejects(h.service.search('queued'), kind('CANCELLED'));
  await flush(); assert.equal(h.calls.length, 1); h.service.cancel();
  await first; await queued; assert.equal(h.timers.size, 0);
  const fresh = h.service.search('fresh'); await h.advance(999); assert.equal(h.calls.length, 1);
  await h.advance(1); await fresh;
  assert.equal(h.calls.length, 2);
});

test('reject wrong source and invalid ID before issuing HTTP; empty keyword is a no-op', async () => {
  const h = harness();
  await assert.rejects(h.service.lyrics({ ...song, source: 'other' }), kind('INVALID_REQUEST'));
  await assert.rejects(h.service.lyrics({ ...song, id: '186016&url=evil' }), kind('INVALID_REQUEST'));
  assert.equal((await h.service.search('  ')).length, 0);
  assert.equal(h.calls.length, 0);
});

test('live anonymous small-sample endpoints (opt in)', { skip: process.env.LYRICFLOW_LIVE_CLOUD !== '1' }, async () => {
  const headers = { Referer: 'https://music.163.com/', Accept: 'application/json' };
  const response = await fetch('https://music.163.com/api/search/get/web?s=' + encodeURIComponent('晴天 周杰伦') + '&type=1&limit=3&offset=0', { headers, redirect: 'error', signal: AbortSignal.timeout(10000) });
  assert.equal(response.status, 200);
  const results = protocol.parseCloudSearch(await response.text());
  assert.ok(results.songs.length > 0 && results.songs.length <= 3);
  assert.equal(results.incomplete, false);
  const lyricsResponse = await fetch('https://music.163.com/api/song/lyric?id=186016&lv=-1&kv=-1&tv=-1&rv=-1', { headers, redirect: 'error', signal: AbortSignal.timeout(10000) });
  assert.equal(lyricsResponse.status, 200);
  const result = protocol.parseCloudLyrics(await lyricsResponse.text(), '186016');
  assert.equal(result.songId, '186016'); assert.ok(result.text.length > 0);
});

test('live credited instrumental placeholders are not confused with mixed lyrics (opt in)', { skip: process.env.LYRICFLOW_LIVE_CLOUD !== '1' }, async () => {
  const headers = { Referer: 'https://music.163.com/', Accept: 'application/json' };
  for (const [id, expected] of [['139774', 'PURE_MUSIC'], ['478507889', 'PURE_MUSIC'], ['2038191895', 'lyrics']]) {
    const response = await fetch('https://music.163.com/api/song/lyric?id=' + id + '&lv=-1&kv=-1&tv=-1&rv=-1', { headers, redirect: 'error', signal: AbortSignal.timeout(10000) });
    assert.equal(response.status, 200);
    const body = await response.text();
    if (expected === 'PURE_MUSIC') assert.throws(() => protocol.parseCloudLyrics(body, id), kind(expected));
    else assert.ok(protocol.parseCloudLyrics(body, id).text.length > 0);
  }
});

test('inconsistent provider counts never make a truncated or contradictory result look complete', () => {
  const good = { id: 1, name: 'Song', artists: [{ name: 'Singer' }] };
  for (const result of [
    { songCount: 0, songs: [good] },
    { songCount: 1, songs: [good, { ...good, id: 2 }] },
    { songCount: 1, songs: [] }
  ]) {
    const parsed = protocol.parseCloudSearch(JSON.stringify({ code: 200, result }));
    assert.equal(parsed.incomplete, true);
    assert.equal(parsed.songs.length, result.songs.length);
  }
  const fullPage = Array.from({ length: 20 }, (_, i) => ({ ...good, id: i + 1 }));
  assert.equal(protocol.parseCloudSearch(JSON.stringify({ code: 200, result: { songCount: 100, songs: fullPage } })).incomplete, false);
});
