'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/AudioMetadataService.ets'), 'utf8');
const js = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
function harness() {
  let unlinkFails = false, releaseCount = 0, marked = false, alias = false, unlinks = 0, flushFails = false;
  const io = { OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2 },
    unlinkSync() { unlinks++; if (unlinkFails) throw Error('permission denied'); },
    async open(p) { return { fd: p === 'content://source' ? 1 : 2 }; },
    statSync(fd) { return { ino: alias ? 1 : fd }; }, truncateSync() {}, closeSync() {},
    async read() { if (!flushFails) throw Error('copy failed'); return 0; },
    async fsync() { await Promise.resolve(); throw Error('flush failed'); } };
  const mod = { exports: {} };
  vm.runInNewContext(js, { module: mod, exports: mod.exports, Error, ArrayBuffer, Number, String,
    require(name) { return name === '@kit.CoreFileKit' ? { fileIo: io, fileUri: { FileUri: class { constructor() { this.path = '/unavailable'; } } } } : {}; } });
  const S = mod.exports.AudioMetadataService;
  return { S, E: mod.exports.WorkingFileCleanupError, setUnlinkFail(v) { unlinkFails = v; },
    mockImport() { S.importToSandbox = async () => ({ workingPath: '/private/tmp', metadata: {
      coverImage: { async release() { releaseCount++; } } } }); },
    releases() { return releaseCount; }, mark() { marked = true; }, marked() { return marked; },
    setAlias(v) { alias = v; }, setFlushFail() { flushFails = true; }, unlinkCount() { return unlinks; } };
}
test('checked cleanup reports failure while legacy cleanup remains best effort', async () => {
  const h = harness(); h.setUnlinkFail(true);
  await h.S.removeWorkingFile('/private/tmp');
  await assert.rejects(h.S.removeWorkingFileChecked('/private/tmp'), h.E);
  h.setUnlinkFail(false); await h.S.removeWorkingFileChecked('/private/tmp');
});
test('strict matching cleanup releases decoded cover and reports retained copy', async () => {
  const h = harness(); h.mockImport(); h.setUnlinkFail(true);
  await assert.rejects(h.S.readForMatching('content://source', 'song.mp3', '/private', true, h.mark, true), h.E);
  assert.equal(h.marked(), true); assert.equal(h.releases(), 1);
});
test('strict import reports cleanup failure even if the copy itself failed', async () => {
  const h = harness(); h.setUnlinkFail(true);
  await assert.rejects(h.S.importToSandbox('content://source', 'song.mp3', '/private', true), h.E);
});
test('ambiguous destination identity is never unlinked and is reported as uncertain cleanup', async () => {
  const h = harness(); h.setAlias(true);
  await assert.rejects(h.S.importToSandbox('content://source', 'song.mp3', '/private', true), h.E);
  assert.equal(h.unlinkCount(), 0);
});

for (const shortWrite of [false, true]) {
  test('import reuses the read buffer and preserves bytes with shortWrite=' + shortWrite, async () => {
    const expected = Buffer.alloc(2 * 1024 * 1024 + 7);
    for (let i = 0; i < expected.length; i++) expected[i] = i % 251;
    let cursor = 0;
    const readBuffers = new Set(), chunks = [], events = [];
    const io = { OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2 },
      async open(p) { return { fd: p === 'content://source' ? 1 : 2 }; },
      statSync(fd) { return { ino: fd }; },
      truncateSync(fd, size) { assert.equal(fd, 2); assert.equal(size, 0); events.push('truncate'); },
      async read(fd, bytes, options) {
        assert.equal(fd, 1);
        readBuffers.add(bytes);
        const count = Math.min(options.length, expected.length - cursor);
        new Uint8Array(bytes).set(expected.subarray(cursor, cursor + count));
        cursor += count;
        return count;
      },
      async write(fd, bytes, options) {
        assert.equal(fd, 2);
        const count = shortWrite ? Math.min(options.length, 600000) : options.length;
        await Promise.resolve();
        if (!shortWrite) assert.ok(readBuffers.has(bytes), 'common path writes without slicing the buffer');
        chunks.push(Buffer.from(new Uint8Array(bytes, 0, count)));
        return count;
      },
      async fsync(fd) { assert.equal(fd, 2); await Promise.resolve(); events.push('flush'); },
      closeSync(fd) { events.push('close' + fd); }
    };
    const mod = { exports: {} };
    vm.runInNewContext(js, { module: mod, exports: mod.exports, Error, ArrayBuffer, Number, String,
      require(name) { return name === '@kit.CoreFileKit' ? { fileIo: io, fileUri: { FileUri: class {
        constructor() { this.path = '/unavailable'; }
      } } } : {}; } });
    const S = mod.exports.AudioMetadataService;
    S.readForDirect = async () => { events.push('metadata'); return {}; };
    await S.importToSandbox('content://source', 'song.mp3', '/private');
    assert.equal(readBuffers.size, 1);
    assert.deepEqual(Buffer.concat(chunks), expected);
    assert.deepEqual(events, ['truncate', 'flush', 'close1', 'close2', 'metadata']);
  });
}

test('import does not read metadata or return a partial copy after an asynchronous flush failure', async () => {
  const h = harness();
  h.setFlushFail();
  h.S.readForDirect = async () => { assert.fail('metadata must not run after flush failure'); };
  await assert.rejects(h.S.importToSandbox('content://source', 'song.mp3', '/private', true), /flush failed/);
  assert.equal(h.unlinkCount(), 1);
});
