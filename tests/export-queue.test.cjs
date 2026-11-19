'use strict';
const { test } = require('node:test'), assert = require('node:assert/strict');
const os = require('node:os'), crypto = require('node:crypto');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), ts = require('typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/services/ExportService.ets'), 'utf8');
function harness(t) {
    const parent = fs.realpathSync(os.tmpdir());
    const root = fs.mkdtempSync(path.join(parent, 'lyricflow-export-test-'));
    t.after(() => {
        const ownedRoot = fs.realpathSync(root);
        assert.equal(path.dirname(ownedRoot), parent);
        fs.rmSync(ownedRoot, { recursive: true });
    });
    const out = path.join(root, 'download');
    fs.mkdirSync(out);
    let fault = false, hook, uriCount = 0, unlinks = 0;
    const positions = new Map();
    const map = p => p.startsWith('content://qa') ? out + p.slice(12) : p.startsWith('file://') ? p.slice(7) : p;
    const stat = p => {
        try {
            return fs.statSync(map(p));
        }
        catch (e) {
            if (e.code === 'ENOENT')
                e.code = 13900002;
            throw e;
        }
    };
    const io = { OpenMode: { READ_ONLY: 0, WRITE_ONLY: 1, CREATE: 64, DIR: 65536, NOFOLLOW: 131072 }, statSync: stat,
        listFileSync: p => fs.readdirSync(map(p)),
        async open(p, flags) {
            await new Promise(r => setImmediate(r));
            const fd = fs.openSync(map(p), (flags & 64) ? 'a+' : 'r');
            positions.set(fd, 0);
            return { fd };
        },
        async read(fd, b, o) {
            const n = fs.readSync(fd, new Uint8Array(b), 0, o.length, positions.get(fd));
            positions.set(fd, positions.get(fd) + n);
            return n;
        },
        async write(fd, b, o) {
            await new Promise(r => setImmediate(r));
            if (hook) {
                const fn = hook;
                hook = undefined;
                fn();
            }
            if (fault) {
                fault = false;
                throw Error('synthetic write failure');
            }
            const n = fs.writeSync(fd, Buffer.from(b), 0, Math.min(o.length, 3), positions.get(fd));
            positions.set(fd, positions.get(fd) + n);
            return n;
        },
        fsyncSync: fd => fs.fsyncSync(fd), closeSync: x => {
            const fd = typeof x === 'number' ? x : x.fd;
            positions.delete(fd);
            fs.closeSync(fd);
        }, unlinkSync: p => {
            unlinks++;
            fs.unlinkSync(map(p));
        } };
    const picker = { DocumentSaveOptions: class {
        }, DocumentPickerMode: { DOWNLOAD: 1 }, DocumentViewPicker: class {
            async save() {
                return [++uriCount % 2 ? 'content://qa' : 'file://' + out];
            }
        } };
    const m = { exports: {} };
    const deps = { '@kit.CoreFileKit': { fileIo: io, picker, fileUri: { FileUri: class {
                    constructor(p) {
                        this.path = map(p);
                    }
                } } }, '@kit.ArkTS': { util: { TextEncoder: { create: () => ({ encodeInto: s => new TextEncoder().encode(s) }) } } } };
    vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText, { module: m, exports: m.exports, require: n => deps[n] || {}, ArrayBuffer, Uint8Array, Error, Number, String, Math });
    return { s: m.exports.ExportService, root, out, read: n => fs.readFileSync(path.join(out, n), 'utf8'), fault: () => fault = true, hook: f => hook = f, unlinks: () => unlinks };
}
test('same-name simultaneous exports preserve both payloads and existing sentinel across URI aliases', async (t) => {
    const h = harness(t);
    fs.writeFileSync(path.join(h.out, 'same.lrc'), 'sentinel');
    const r = await Promise.all([h.s.saveTextToDownload({}, 'same.lrc', 'AAA'), h.s.saveTextToDownload({}, 'same.lrc', 'BBBBB')]);
    assert.notEqual(r[0].name, r[1].name);
    assert.equal(h.read(r[0].name), 'AAA');
    assert.equal(h.read(r[1].name), 'BBBBB');
    assert.equal(h.read('same.lrc'), 'sentinel');
});
test('text audio and sandbox batch share one name-allocation transaction', async (t) => {
    const h = harness(t);
    const src = path.join(h.root, 'audio');
    fs.writeFileSync(src, 'audio-payload');
    const exp = path.join(h.root, 'export');
    fs.mkdirSync(exp);
    fs.writeFileSync(path.join(exp, 'mixed.lrc'), 'batch-payload');
    const [a, b, c] = await Promise.all([h.s.saveTextToDownload({}, 'mixed.lrc', 'text-payload'), h.s.saveAudioToDownload({}, 'mixed.lrc', src), h.s.copySandboxToDownload({ filesDir: h.root })]);
    const names = [a.name, b.name, c.copied[0]];
    assert.equal(new Set(names).size, 3);
    assert.deepEqual(names.map(n => h.read(n)), ['text-payload', 'audio-payload', 'batch-payload']);
    assert.equal(fs.readFileSync(src, 'utf8'), 'audio-payload');
    assert.equal(fs.readFileSync(path.join(exp, 'mixed.lrc'), 'utf8'), 'batch-payload');
});
test('failure releases the queue, retains uncertain output and preserves the following payload', async (t) => {
    const h = harness(t);
    h.fault();
    const r = await Promise.allSettled([h.s.saveTextToDownload({}, 'fail.lrc', 'first'), h.s.saveTextToDownload({}, 'fail.lrc', 'second')]);
    assert.equal(r[0].status, 'rejected');
    assert.equal(r[1].status, 'fulfilled');
    assert.equal(h.read(r[1].value.name), 'second');
    assert.equal(h.unlinks(), 0);
});
test('invalid allocation does not wedge subsequent export', async (t) => {
    const h = harness(t);
    const r = await Promise.allSettled([h.s.saveTextToDownload({}, '', 'bad'), h.s.saveTextToDownload({}, 'good.lrc', 'good')]);
    assert.equal(r[0].status, 'rejected');
    assert.equal(r[1].status, 'fulfilled');
    assert.equal(h.read('good.lrc'), 'good');
});
test('failed write never removes an externally replaced path', async (t) => {
    const h = harness(t);
    h.hook(() => {
        fs.renameSync(path.join(h.out, 'swap.lrc'), path.join(h.out, 'old-owned'));
        fs.writeFileSync(path.join(h.out, 'swap.lrc'), 'external');
    });
    h.fault();
    await assert.rejects(h.s.saveTextToDownload({}, 'swap.lrc', 'ours'));
    assert.equal(h.read('swap.lrc'), 'external');
    assert.equal(h.unlinks(), 0);
});
test('direct backup method is unchanged', () => {
    const normalized = source.replace(/\r\n?/g, '\n');
    const method = normalized.match(/^  static async saveDirectBackup\([\s\S]*?^  \}/m);
    assert.ok(method, 'Expected the saveDirectBackup method');
    // SHA-256 of the original method, using LF line endings and no trailing newline.
    assert.equal(crypto.createHash('sha256').update(method[0]).digest('hex'), '536f0ee93f2d55cba8d32ab9fdafb809c436dd3c7fc60d0567e5be3e9da4a92f');
});
