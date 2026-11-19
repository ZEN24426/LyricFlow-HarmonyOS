'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');

const root = path.resolve(__dirname, '..');
function load(name, imports, shortTimeout = false) {
  const m = { exports: {} };
  const code = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services', name + '.ets'), 'utf8'),
    { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  vm.runInNewContext(code, { module: m, exports: m.exports, require: n => {
    if (!(n in imports)) throw Error('unexpected import ' + n); return imports[n];
  }, Error, Number, String, Math, Uint8Array, ArrayBuffer,
  setTimeout: shortTimeout ? (fn, ms) => setTimeout(fn, Math.min(ms, 10)) : setTimeout, clearTimeout });
  return m.exports;
}
function harness(shortTimeout = false) {
  const offsets = new Map(); const opened = []; const events = []; let onFetch = () => {}, onRelease = () => {}, onStat = () => {}, onClose = () => {};
  let result = { duration: '1000', sampleRate: '44100', tracks: [{ type: 1, codec: 'audio/mpeg', channels: 2 }] };
  const io = {
    OpenMode: { READ_ONLY: 0 }, WhenceType: { SEEK_SET: 0 },
    async open(p) { const fd = fs.openSync(p, 'r'); offsets.set(fd, 0); opened.push(fd); return { fd }; },
    statSync(fd) { onStat(fd); const s = fs.fstatSync(fd, { bigint: true }); return { isFile: () => s.isFile(), ino: s.ino,
      size: Number(s.size), mtime: Number(s.mtimeMs), ctime: Number(s.ctimeMs), mtimeNs: s.mtimeNs, ctimeNs: s.ctimeNs }; },
    lseek(fd, off) { offsets.set(fd, off); return off; },
    async read(fd, buffer, options) { const n = fs.readSync(fd, Buffer.from(buffer), 0, options.length, offsets.get(fd)); offsets.set(fd, offsets.get(fd) + n); return n; },
    closeSync(fd) { events.push(['closeAttempt', fd]); onClose(fd); fs.closeSync(fd); offsets.delete(fd); events.push(['close', fd]); }
  };
  const media = { MediaDescriptionKey: { MD_KEY_TRACK_TYPE: 'type', MD_KEY_CODEC_MIME: 'codec', MD_KEY_AUD_CHANNEL_COUNT: 'channels' },
    MediaType: { MEDIA_TYPE_AUD: 1 }, CodecMimeType: { AUDIO_MP3: 'audio/mpeg' },
    async createAVMetadataExtractor() { return { set fdSrc(x) { this.fd = x.fd; events.push(['extract', x.fd]); },
      async fetchMetadataWithTimeout() { await onFetch(); return result; }, async release() { events.push(['release', this.fd]); await onRelease(); } }; } };
  const bare = load('BareMp3', { '@kit.CoreFileKit': { fileIo: io } });
  const api = load('MissingLyricsMp3Evidence', { '@kit.CoreFileKit': { fileIo: io }, '@kit.MediaKit': { media }, './BareMp3': bare }, shortTimeout);
  return { api, events, opened, offsets, setFetch: f => { onFetch = f; }, setResult: r => { result = r; }, setRelease: f => { onRelease = f; },
    setStat: f => { onStat = f; }, setClose: f => { onClose = f; } };
}
// Two complete MPEG-1 Layer III 128 kbps / 44.1 kHz frames; system recognition is mocked.
function frames() { const f = Buffer.alloc(417); f.set([0xff, 0xfb, 0x90, 0x00]); return Buffer.concat([f, f]); }
async function withFile(data, run) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lyricflow-mp3-evidence-'));
  const file = path.join(dir, 'song.mp3');
  try { fs.writeFileSync(file, data); await run(file); }
  finally { fs.rmSync(dir, { recursive: true, force: true }); }
}
async function observe(h, file) { return h.api.endMp3SourceObservation(await h.api.beginMp3SourceObservation(file)); }

test('real synthetic bare frame bytes require complete scan plus same-fd mocked system MP3 recognition', async () => {
  await withFile(frames(), async file => {
    const h = harness(), id = await observe(h, file);
    assert.equal(await h.api.proveBareMp3HasNoTags(file, id), true);
    assert.equal(h.offsets.size, 0);
    const extract = h.events.findIndex(e => e[0] === 'extract'), fd = h.events[extract][1];
    assert.ok(h.events.findIndex((e, i) => i > extract && e[0] === 'release' && e[1] === fd) <
      h.events.findIndex((e, i) => i > extract && e[0] === 'close' && e[1] === fd));
  });
});

test('stat then close failure during observation is reported once and blocks further opens', async () => {
  await withFile(frames(), async file => {
    const h = harness(); h.setStat(() => { throw Error('stat failed'); }); h.setClose(() => { throw Error('close failed'); });
    await assert.rejects(h.api.beginMp3SourceObservation(file), /资源未能安全释放/);
    const fd = h.opened[0];
    for (let i = 0; i < 4; i++) await assert.rejects(h.api.beginMp3SourceObservation(file), /重启/);
    assert.equal(h.opened.length, 1); assert.equal(h.events.filter(e => e[0] === 'closeAttempt' && e[1] === fd).length, 1);
    fs.closeSync(fd);
  });
});

test('verification descriptor close failure is reported and blocks later observations', async () => {
  await withFile(frames(), async file => {
    const h = harness(), observation = await h.api.beginMp3SourceObservation(file), sourceFd = observation.file.fd;
    h.setClose(fd => { if (fd !== sourceFd) throw Error('check close failed'); });
    await assert.rejects(h.api.endMp3SourceObservation(observation), /资源未能安全释放/);
    const checkFd = h.opened[1];
    assert.equal(h.events.filter(e => e[0] === 'closeAttempt' && e[1] === checkFd).length, 1);
    assert.ok(h.events.some(e => e[0] === 'close' && e[1] === sourceFd));
    const count = h.opened.length; await assert.rejects(h.api.beginMp3SourceObservation(file), /重启/);
    assert.equal(h.opened.length, count); fs.closeSync(checkFd);
  });
});

test('both verification and observation close failures are retained without retries', async () => {
  await withFile(frames(), async file => {
    const h = harness(), observation = await h.api.beginMp3SourceObservation(file);
    h.setClose(() => { throw Error('close failed'); });
    await assert.rejects(h.api.endMp3SourceObservation(observation), /资源未能安全释放/);
    const fds = [...h.opened]; assert.equal(fds.length, 2);
    for (const fd of fds) assert.equal(h.events.filter(e => e[0] === 'closeAttempt' && e[1] === fd).length, 1);
    for (let i = 0; i < 4; i++) await assert.rejects(h.api.beginMp3SourceObservation(file), /重启/);
    assert.equal(h.opened.length, 2); for (const fd of fds) fs.closeSync(fd);
  });
});

test('proof verification close failure retains check fd and still closes its separate source fd', async () => {
  await withFile(frames(), async file => {
    const h = harness(), id = await observe(h, file);
    h.setClose(fd => { const event = h.events.find(e => e[0] === 'extract'); if (event && fd !== event[1]) throw Error('check close failed'); });
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /资源未能安全释放/);
    const extractIndex = h.events.findIndex(e => e[0] === 'extract'), sourceFd = h.events[extractIndex][1];
    const checkFd = h.opened[h.opened.length - 1];
    assert.ok(h.events.some((e, i) => i > extractIndex && e[0] === 'close' && e[1] === sourceFd));
    assert.equal(h.events.filter((e, i) => i > extractIndex && e[0] === 'closeAttempt' && e[1] === checkFd).length, 1);
    const count = h.opened.length; await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /重启/);
    assert.equal(h.opened.length, count); fs.closeSync(checkFd);
  });
});

test('ID3, trailing tags, junk and truncated or corrupt frames cannot prove absence', async () => {
  const bad = [Buffer.concat([Buffer.from('ID3\x04\x00\x00\x00\x00\x00\x00'), frames()]),
    Buffer.concat([frames(), Buffer.from('TAG' + 'x'.repeat(125))]),
    Buffer.concat([frames(), Buffer.from('LYRICS200')]), Buffer.concat([frames(), Buffer.from([0])]),
    frames().subarray(0, 800), Buffer.concat([frames().subarray(0, 417), Buffer.alloc(417)])];
  for (const bytes of bad) await withFile(bytes, async file => {
    const h = harness(), id = await observe(h, file);
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id));
    assert.equal(h.offsets.size, 0);
  });
});

test('changed source while metadata or proof is in progress, and replaced URI, are rejected', async () => {
  await withFile(frames(), async file => {
    const h = harness();
    const observation = await h.api.beginMp3SourceObservation(file);
    fs.appendFileSync(file, 'x');
    await assert.rejects(h.api.endMp3SourceObservation(observation));
    fs.writeFileSync(file, frames());
    let id = await observe(h, file);
    h.setFetch(() => fs.appendFileSync(file, 'x'));
    assert.equal(await h.api.proveBareMp3HasNoTags(file, id), false);
    fs.writeFileSync(file, frames()); h.setFetch(() => {}); id = await observe(h, file);
    const replacement = file + '.replacement'; fs.writeFileSync(replacement, frames()); fs.renameSync(replacement, file);
    assert.equal(await h.api.proveBareMp3HasNoTags(file, id), false);
    assert.equal(h.offsets.size, 0);
  });
});

test('a non-MP3 codec, missing properties, and extra audio track do not prove absence', async () => {
  await withFile(frames(), async file => {
    const h = harness(), id = await observe(h, file);
    for (const raw of [{ duration: '1000', sampleRate: '44100', tracks: [{ type: 1, codec: 'audio/aac', channels: 2 }] },
      { duration: '0', sampleRate: '44100', tracks: [{ type: 1, codec: 'audio/mpeg', channels: 2 }] },
      { duration: '1000', sampleRate: '44100', tracks: [{ type: 1, codec: 'audio/mpeg', channels: 2 }, { type: 1, codec: 'audio/mpeg', channels: 2 }] }]) {
      h.setResult(raw); assert.equal(await h.api.proveBareMp3HasNoTags(file, id), false);
    }
    assert.equal(h.offsets.size, 0);
  });
});

test('failed extractor release retains the fd and blocks all later proof attempts', async () => {
  await withFile(frames(), async file => {
    const h = harness(), id = await observe(h, file);
    h.setRelease(() => { throw Error('release failed'); });
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /资源未能安全释放/);
    const extractIndex = h.events.findIndex(e => e[0] === 'extract'), fd = h.events[extractIndex][1];
    assert.equal(h.events.filter(e => e[0] === 'release' && e[1] === fd).length, 1);
    assert.equal(h.events.some((e, i) => i > extractIndex && e[0] === 'close' && e[1] === fd), false);
    const openCount = h.opened.length;
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /重启/);
    assert.equal(h.opened.length, openCount);
    // The real process retains this descriptor until restart; the test owns it.
    fs.closeSync(fd);
  });
});

test('a pending extractor release blocks reentry until it actually finishes', async () => {
  await withFile(frames(), async file => {
    const h = harness(), id = await observe(h, file); let finish, started;
    const waiting = new Promise(resolve => { started = resolve; });
    h.setRelease(() => { started(); return new Promise(resolve => { finish = resolve; }); });
    const first = h.api.proveBareMp3HasNoTags(file, id); await waiting;
    const before = h.opened.length;
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /仍在进行/);
    assert.equal(h.opened.length, before); finish(); assert.equal(await first, true);
    assert.equal(h.offsets.size, 0);
  });
});

test('extractor release timeout retains resources and blocks further attempts', async () => {
  await withFile(frames(), async file => {
    const h = harness(true), id = await observe(h, file);
    h.setRelease(() => new Promise(() => {}));
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /资源未能安全释放/);
    const extractIndex = h.events.findIndex(e => e[0] === 'extract'), fd = h.events[extractIndex][1];
    assert.equal(h.events.some((e, i) => i > extractIndex && e[0] === 'close' && e[1] === fd), false);
    await assert.rejects(h.api.proveBareMp3HasNoTags(file, id), /重启/); fs.closeSync(fd);
  });
});

test('queue marks only a directly read and identity-bound bare stream missing; sidecar remains unknown', async () => {
  await withFile(frames(), async file => {
    const h = harness(); let usedSandboxCopy = false; let mutate = false;
    const matcher = load('CloudSongMatcher', {});
    const bilingual = load('CloudBilingualLyrics', {});
    const scanner = { MAX_SANDBOX_COPIES: 300, async scan() { return {
      audioFiles: [{ id: 'a', name: 'song.mp3', uri: file }], lyricFiles: [], imageFiles: [], warnings: [], visitedFiles: 1
    }; } };
    const metadata = { title: '', artist: '', album: '', durationMs: 1000, lyrics: '', fileSize: frames().length };
    const audio = { canReadDirectly: () => true, async readForMatching() {
      if (mutate) { const f = fs.openSync(file, 'r+'); try { fs.writeSync(f, Buffer.from([1]), 0, 1, 40); } finally { fs.closeSync(f); } }
      return { metadata: { ...metadata }, usedSandboxCopy };
    } };
    class Cloud { cancel() {} }
    const { MissingLyricsQueue } = load('MissingLyricsQueue', {
      './FolderScanner': { FolderScanner: scanner }, './AudioMetadataService': { AudioMetadataService: audio, WorkingFileCleanupError: class extends Error {} },
      './FileSelectionService': { FileSelectionService: {} }, './CloudLyricsService': { CloudLyricsService: Cloud },
      './CloudSongMatcher': matcher, './CloudBilingualLyrics': bilingual, './MissingLyricsMp3Evidence': h.api
    });
    const q = new MissingLyricsQueue(); await q.scan('/folder', '/private');
    assert.equal(q.snapshot().rows[0].embedded, 'missing');
    assert.equal(q.snapshot().rows[0].sidecar, 'unknown');
    usedSandboxCopy = true; await q.scan('/folder', '/private');
    assert.equal(q.snapshot().rows[0].embedded, 'unknown');
    usedSandboxCopy = false; mutate = true; await q.scan('/folder', '/private');
    assert.equal(q.snapshot().rows[0].embedded, 'unknown');
    assert.equal(h.offsets.size, 0);
  });
});
