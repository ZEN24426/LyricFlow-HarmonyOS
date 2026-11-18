// In-memory IO and ImageKit stubs exercise parser/writer/verifier logic only.
// These structural fixtures contain synthetic box data, not valid AAC frames.
const ts = require('typescript');
const fs = require('fs');
const vm = require('vm');
const assert = require('assert/strict');
const path = require('path');
const files = new Map();
const fds = new Map();
let nextFd = 10, nextDirectory = 0, failWrite = false, deleted = 0, removed = 0;
const fileIo = {
  OpenMode: { READ_ONLY: 1, CREATE: 2, READ_WRITE: 4 },
  WhenceType: { SEEK_SET: 0 },
  openSync(p, mode) {
    if (!files.has(p)) {
      if (!(mode & 2)) throw Error('missing file ' + p);
      files.set(p, Buffer.alloc(0));
    }
    const fd = nextFd++;
    fds.set(fd, { path: p, pos: 0 });
    return { fd };
  },
  async open(p, mode) { return this.openSync(p, mode); },
  closeSync(fd) { fds.delete(fd); },
  statSync(fd) { const data = files.get(fds.get(fd).path); return { size: data.length, isFile: () => true }; },
  lseek(fd, position) { fds.get(fd).pos = position; return position; },
  async read(fd, output, { length }) {
    const state = fds.get(fd), data = files.get(state.path);
    const count = Math.min(length, data.length - state.pos);
    new Uint8Array(output).set(data.subarray(state.pos, state.pos + count));
    state.pos += count;
    return count;
  },
  async write(fd, input, { length }) {
    if (failWrite) throw Error('simulated write failure');
    const state = fds.get(fd);
    let data = files.get(state.path);
    if (state.pos + length > data.length) {
      const next = Buffer.alloc(state.pos + length);
      data.copy(next);
      data = next;
      files.set(state.path, data);
    }
    Buffer.from(input, 0, length).copy(data, state.pos);
    state.pos += length;
    return length;
  },
  mkdtempSync(p) { return p.replace('XXXXXX', String(++nextDirectory)); },
  fsyncSync() {},
  unlinkSync(p) { deleted++; files.delete(p); },
  rmdirSync() { removed++; }
};
let encodeCalls = 0;
const util = {
  TextEncoder: { create: () => ({ encodeInto: s => { encodeCalls++; return new Uint8Array(Buffer.from(s, 'utf8')); } }) },
  TextDecoder: { create: (_, options) => ({ decodeToString: b => new TextDecoder('utf-8', options).decode(b) }) }
};
let bomb = false, decodeCalls = 0, pixelReleases = 0;
const image = {
  createImagePacker: () => ({ async packToData(cover) { return Uint8Array.from(cover.encoded).buffer; }, async release() {} }),
  createImageSource: data => ({
    async getImageInfo() { return { size: { width: bomb ? 100000 : 2, height: 3 }, isHdr: false }; },
    async createPixelMap() {
      decodeCalls++;
      return { encoded: Buffer.from(data), async getImageInfo() { return { size: { width: 2, height: 3 }, isHdr: false }; }, async release() { pixelReleases++; } };
    },
    async release() {}
  })
};
function loadModule(file) {
  const source = fs.readFileSync(file, 'utf8');
  const compiled = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } }).outputText;
  const sandbox = { module: { exports: {} }, exports: {}, require: n => n === '@kit.CoreFileKit' ? { fileIo } : n === '@kit.ArkTS' ? { util } : n === '@kit.ImageKit' ? { image } : n === './MetadataVerification' ? { verifyWrittenMetadata: async (fields, actual) => { if (fields.coverImage === undefined) return realVerification.verifyWrittenMetadata(fields, actual); const textFields = { ...fields }; delete textFields.coverImage; await realVerification.verifyWrittenMetadata(textFields, actual); assert.deepEqual(actual.coverImage.encoded, fields.coverImage.encoded); }, verifyPreservedMetadata: async (fields, before, after) => { if (before.coverImage === undefined && after.coverImage === undefined) return realVerification.verifyPreservedMetadata(fields, before, after); for (const k of ['title','artist','album','genre','comment','lyrics','albumArtist','composer','grouping','copyright','year','track','trackTotal','disc','discTotal','bpm']) if (fields[k] === undefined) assert.equal(after[k], before[k], k); if (fields.coverImage === undefined) { assert.equal(after.coverImage === undefined, before.coverImage === undefined); if (before.coverImage !== undefined) assert.deepEqual(after.coverImage.encoded, before.coverImage.encoded); } } } : {} };
  sandbox.exports = sandbox.module.exports;
  vm.runInNewContext(compiled, sandbox);
  return sandbox.module.exports;
}
const realVerification = loadModule(path.resolve(__dirname, '../entry/src/main/ets/services/MetadataVerification.ets'));
const api = loadModule(path.resolve(__dirname, '../entry/src/main/ets/services/OwnM4aMetadata.ets'));
const u16 = n => { const b = Buffer.alloc(2); b.writeUInt16BE(n); return b; };
const u32 = n => { const b = Buffer.alloc(4); b.writeUInt32BE(n); return b; };
const atom = (type, ...parts) => { const payload = Buffer.concat(parts); return Buffer.concat([u32(payload.length + 8), Buffer.from(type, 'latin1'), payload]); };
const zero = n => Buffer.alloc(n);
const full = atomName => atom(atomName, zero(4));
const data = (value, type = 1, locale = 0) => atom('data', u32(type), u32(locale), Buffer.isBuffer(value) ? value : Buffer.from(value, 'utf8'));
const item = (tag, value, type = 1, locale = 0) => atom(tag, data(value, type, locale));
const numberPair = (value, total, disk = false) => Buffer.concat([u16(0), u16(value), u16(total), ...(disk ? [] : [u16(0)])]);
const handler = name => atom('hdlr', zero(8), Buffer.from(name, 'latin1'), zero(12), Buffer.from([0]));
const png = Buffer.from('89504e470d0a1a0a0000000d4948445200000002000000030806000000b9eade810000000b49444154789c6360400700001b0001d559c6f20000000049454e44ae426082', 'hex');
const cover = { encoded: png, async getImageInfo() { return { size: { width: 2, height: 3 }, isHdr: false }; } };
const defaultItems = () => [
  item('©nam', '原名'), item('©ART', '原歌手'), item('©alb', '专辑'), item('©lyr', '原歌词'),
  item('trkn', numberPair(2, 10), 0), item('disk', numberPair(1, 2, true), 0),
  item('tmpo', u16(120), 21), item('©xyz', 'KEEP-UNKNOWN')
];
function fixture(options = {}) {
  const entries = options.items || defaultItems();
  const ftyp = atom('ftyp', Buffer.from('M4A '), u32(0), Buffer.from('isomM4A '));
  const mdat = atom('mdat', Buffer.from('synthetic compressed audio'));
  const offset = ftyp.length + 8;
  const esds = atom('esds', zero(4), Buffer.from('0319000100041140150000000000000000000005021210060102', 'hex'));
  const mp4a = atom(options.codec || 'mp4a', zero(6), u16(1), zero(8), u16(2), u16(16), zero(4), u32(44100 * 65536), esds, ...(options.protected ? [atom('sinf', atom('frma', Buffer.from('mp4a')))] : []));
  const stsd = atom('stsd', zero(4), u32(1), mp4a);
  const offsetAtom = atom('stco', zero(4), u32(1), u32(options.badOffset ? 4 : offset));
  const stts = atom('stts', zero(4), u32(1), u32(1), u32(1024));
  const stsc = atom('stsc', zero(4), u32(1), u32(options.badFirstChunk ? 2 : 1), u32(1), u32(1));
  const stsz = atom('stsz', zero(4), u32(options.overlap ? 65535 : mdat.length - 8), u32(options.badSampleCount ? 2 : 1));
  const stbl = atom('stbl', stsd, stts, stsc, stsz, offsetAtom, ...(options.sampleGroups ? [atom('sgpd', zero(4), Buffer.from('seig'), zero(8)), atom('sbgp', zero(4), Buffer.from('seig'), zero(4))] : []), ...(options.roll || options.badRollCount || options.badRollIndex ? [atom('sgpd', u32(0x01000000), Buffer.from('roll'), u32(2), u32(1), u16(65535)), atom('sbgp', zero(4), Buffer.from('roll'), u32(1), u32(options.badRollCount ? 2 : 1), u32(options.badRollIndex ? 2 : 1))] : []));
  const ref = atom('url ', u32(options.external ? 0 : 1));
  const dref = atom('dref', zero(4), u32(1), ref);
  const dinf = atom('dinf', dref);
  const minf = atom('minf', atom('smhd', zero(8)), dinf, stbl);
  const mdhd = atom('mdhd', zero(12), u32(44100), u32(441000), zero(4));
  const mdia = atom('mdia', mdhd, handler(options.handler || 'soun'), minf);
  const trak = atom('trak', mdia);
  const ilst = atom('ilst', ...entries);
  const available = options.noFree ? Buffer.alloc(0) : atom('free', zero(options.freeBytes === undefined ? 2048 : options.freeBytes));
  const meta = atom('meta', zero(4), handler(options.metaHandler || 'mdir'), ilst, available);
  const moov = atom('moov', trak, atom('udta', meta));
  return Buffer.concat([ftyp, mdat, moov]);
}
function windowBytes(input) {
  // This structural fixture has one ilst and one immediately following free atom.
  const ilst = input.indexOf(Buffer.from('ilst')) - 4;
  assert.ok(ilst >= 0);
  const ilstEnd = ilst + input.readUInt32BE(ilst);
  const hasFree = input.subarray(ilstEnd + 4, ilstEnd + 8).equals(Buffer.from('free'));
  return [ilst, ilstEnd + (hasFree ? input.readUInt32BE(ilstEnd) : 0)];
}
(async () => {
  const inputPath = '/app/test.m4a';
  let before = fixture();
  files.set(inputPath, before);
  let original = await api.readM4aMetadata(inputPath);
  assert.equal(original.title, '原名');
  assert.equal(original.artist, '原歌手');
  assert.equal(original.album, '专辑');
  assert.equal(original.lyrics, '原歌词');
  assert.equal(original.track, 2); assert.equal(original.trackTotal, 10);
  assert.equal(original.disc, 1); assert.equal(original.discTotal, 2); assert.equal(original.bpm, 120);
  const fields = { title: '修改后的歌名🎵', lyrics: '[00:01.00] 新歌词', track: 3, discTotal: 3, bpm: 125 };
  let outputPath = await api.writeM4aMetadata('/app', inputPath, fields);
  const output = files.get(outputPath);
  assert.deepEqual(files.get(inputPath), before, 'input must remain unmodified');
  assert.equal(output.length, before.length);
  const [start, end] = windowBytes(before);
  assert.deepEqual(output.subarray(0, start), before.subarray(0, start));
  assert.deepEqual(output.subarray(end), before.subarray(end));
  assert.ok(output.includes(Buffer.from('KEEP-UNKNOWN')));
  let result = await api.readM4aMetadata(outputPath);
  assert.equal(result.title, fields.title); assert.equal(result.lyrics, fields.lyrics);
  assert.equal(result.track, 3); assert.equal(result.trackTotal, 10);
  assert.equal(result.disc, 1); assert.equal(result.discTotal, 3); assert.equal(result.bpm, 125);
  await api.verifyM4aIntegrity(inputPath, outputPath, fields);
  const bounds = windowBytes(before); const ilstLength = before.readUInt32BE(bounds[0]);
  const lyricAt = before.indexOf(Buffer.from('©lyr', 'latin1')) - 4; assert.ok(lyricAt >= 0);
  const oldLyricLength = before.readUInt32BE(lyricAt);
  for (const spare of [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
    const length = bounds[1] - bounds[0] - ilstLength + oldLyricLength - 24 - spare;
    const f = { lyrics: 'z'.repeat(length) };
    if (spare > 0 && spare < 8) await assert.rejects(api.writeM4aMetadata('/app', inputPath, f));
    else { const target = await api.writeM4aMetadata('/app', inputPath, f); await api.verifyM4aIntegrity(inputPath, target, f); }
  }
  const damaged = Buffer.from(output); damaged[15] ^= 1; files.set('/app/damaged.m4a', damaged);
  await assert.rejects(api.verifyM4aIntegrity(inputPath, '/app/damaged.m4a', fields));
  const changedUnknown = Buffer.from(output); const unknownAt = changedUnknown.indexOf(Buffer.from('KEEP-UNKNOWN')); assert.ok(unknownAt > 0); changedUnknown[unknownAt] ^= 1; files.set('/app/changed-unknown.m4a', changedUnknown);
  await assert.rejects(api.verifyM4aIntegrity(inputPath, '/app/changed-unknown.m4a', fields));
  before = fixture({ roll: true }); files.set(inputPath, before);
  outputPath = await api.writeM4aMetadata('/app', inputPath, { lyrics: 'roll-safe' });
  await api.verifyM4aIntegrity(inputPath, outputPath, { lyrics: 'roll-safe' });
  before = fixture(); files.set(inputPath, before);
  const allFields = { title: '标题', artist: '艺人', album: '专辑', genre: '流派', comment: '备注', lyrics: '歌词', albumArtist: '专辑歌手', composer: '作曲', grouping: '分组', copyright: '版权', year: 2023, track: 4, trackTotal: 9, disc: 1, discTotal: 2, bpm: 160 };
  outputPath = await api.writeM4aMetadata('/app', inputPath, allFields); result = await api.readM4aMetadata(outputPath);
  for (const [key, value] of Object.entries(allFields)) assert.equal(result[key], value, key);
  await api.verifyM4aIntegrity(inputPath, outputPath, allFields);
  before = fixture(); files.set(inputPath, before);
  outputPath = await api.writeM4aMetadata('/app', inputPath, { coverImage: cover });
  result = await api.readM4aMetadata(outputPath);
  assert.deepEqual(result.coverImage.encoded, cover.encoded);
  await api.verifyM4aIntegrity(inputPath, outputPath, { coverImage: cover });
  before = fixture({ items: [...defaultItems(), item('covr', png, 14)] }); files.set(inputPath, before);
  outputPath = await api.writeM4aMetadata('/app', inputPath, { lyrics: '保留原封面' });
  result = await api.readM4aMetadata(outputPath); assert.deepEqual(result.coverImage.encoded, png);
  await api.verifyM4aIntegrity(inputPath, outputPath, { lyrics: '保留原封面' });
  before = fixture(); files.set(inputPath, before);
  const combined = { coverImage: cover, title: '组合标题', lyrics: '组合歌词', track: 8 };
  outputPath = await api.writeM4aMetadata('/app', inputPath, combined);
  result = await api.readM4aMetadata(outputPath);
  assert.equal(result.title, combined.title); assert.equal(result.lyrics, combined.lyrics); assert.equal(result.track, 8);
  await api.verifyM4aIntegrity(inputPath, outputPath, combined);
  for (const options of [{ external: true }, { codec: 'enca' }, { protected: true }, { sampleGroups: true }, { badRollCount: true }, { badRollIndex: true }, { overlap: true }, { badFirstChunk: true }, { badSampleCount: true }, { handler: 'vide' }, { metaHandler: 'mdta' }, { badOffset: true }]) {
    files.set(inputPath, fixture(options));
    await assert.rejects(api.writeM4aMetadata('/app', inputPath, { lyrics: 'reject' }), undefined, JSON.stringify(options));
  }
  files.set(inputPath, fixture({ noFree: true }));
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { lyrics: 'will not fit without padding' }));
  files.set(inputPath, fixture({ items: [...defaultItems(), item('©lyr', '第二个值')] }));
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { lyrics: 'ambiguous' }));
  files.set(inputPath, fixture({ items: [item('©lyr', 'localized', 1, 1)] }));
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { lyrics: 'localized conflict' }));
  files.set(inputPath, fixture({ items: [item('©lyr', 'unsupported UTF16', 2)] }));
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { lyrics: 'unsupported encoding' }));
  files.set(inputPath, fixture({ items: [item('©nam', 'bad UTF16', 2), item('covr', png, 14)] }));
  const made = decodeCalls, released = pixelReleases;
  await assert.rejects(api.readM4aMetadata(inputPath));
  assert.equal(decodeCalls - made, pixelReleases - released, 'failed reads must release decoded cover');
  files.set(inputPath, fixture({ items: [item('tmpo', u16(65535), 21)] }));
  await assert.rejects(api.readM4aMetadata(inputPath), /BPM/);
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { bpm: 120 }), /BPM/);
  files.set(inputPath, fixture());
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { bpm: 32768 }), /BPM/);
  for (const [tag, field] of [['gnre', 'genre'], ['©cpy', 'copyright']]) {
    files.set(inputPath, fixture({ items: [item(tag, 'old')] }));
    await assert.rejects(api.readM4aMetadata(inputPath));
    await assert.rejects(api.writeM4aMetadata('/app', inputPath, { [field]: 'new' }));
  }
  files.set(inputPath, fixture());
  for (const value of ['\uD800', '\uDC00']) await assert.rejects(api.writeM4aMetadata('/app', inputPath, { title: value }), /Unicode/);
  const noIdat = Buffer.concat([png.subarray(0,33), png.subarray(png.length-12)]);
  const brokenCover = { encoded: noIdat, async getImageInfo() { return { size: { width: 2, height: 3 }, isHdr: false }; } };
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { coverImage: brokenCover }), /图像数据/);
  files.set(inputPath, fixture());
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { isrc: '' }));
  const encodes = encodeCalls;
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { title: 'a'.repeat(1200), lyrics: 'b'.repeat(1200) }));
  assert.equal(encodeCalls, encodes, 'reject aggregate excess before allocating encoded fields');
  files.set(inputPath, fixture());
  const saved = files.get(inputPath), deleteCount = deleted, removeCount = removed;
  failWrite = true;
  await assert.rejects(api.writeM4aMetadata('/app', inputPath, { lyrics: 'write failure' }));
  failWrite = false;
  assert.deepEqual(files.get(inputPath), saved);
  assert.ok(deleted > deleteCount); assert.ok(removed > removeCount);
  assert.equal(fds.size, 0);
  if (process.env.LYRICFLOW_M4A_FIXTURE) {
    const actualInput = fs.readFileSync(process.env.LYRICFLOW_M4A_FIXTURE);
    const livePath = '/app/actual-m4a.m4a'; files.set(livePath, actualInput);
    const parsed = await api.readM4aMetadata(livePath);
    const change = { lyrics: '[00:01.00] synthetic lyric for codec interoperability' };
    const liveOutput = await api.writeM4aMetadata('/app', livePath, change);
    const after = await api.readM4aMetadata(liveOutput);
    assert.equal(after.lyrics, change.lyrics); assert.equal(after.title, parsed.title);
    await api.verifyM4aIntegrity(livePath, liveOutput, change);
    assert.deepEqual(files.get(livePath), actualInput);
    if (process.env.LYRICFLOW_M4A_RESULT) fs.writeFileSync(process.env.LYRICFLOW_M4A_RESULT, files.get(liveOutput), { flag: 'wx' });
    console.log('PASS requested M4A fixture parser, fixed-window copy and byte-preservation test (IO stubbed)');
  }
  console.log('PASS M4A synthetic fixed-window read/write, media preservation, verifier and rejection cases (IO/ImageKit stubbed)');
})().catch(error => { console.error(error); process.exitCode = 1; });
