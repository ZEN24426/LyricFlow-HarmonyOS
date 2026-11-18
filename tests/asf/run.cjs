'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const vm = require('node:vm');
const ts = require('typescript');
const { cleanupFixtureDirectory } = require('./safe-cleanup.cjs');

if (!process.env.ASF_TEST_FFMPEG || !process.env.ASF_TEST_FFPROBE) {
  throw Error('Set ASF_TEST_FFMPEG and ASF_TEST_FFPROBE to FFmpeg and FFprobe executables');
}
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'lyricflow-asf-test-'));
const env = { ...process.env, ASF_FIXTURE_DIR: dir };
function run(script) {
  console.log(`\n--- ${script} ---`);
  const result = spawnSync(process.execPath, [path.join(__dirname, script)], { env, stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw Error(`${script} exited ${result.status}`);
}
try {
  run('ffmpeg-fixtures.cjs');
  // Produce the edited fixture with the actual candidate header editor.
  const source = path.join(__dirname, '../../entry/src/main/ets/services/AsfHeaderEditor.ets');
  const js = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const mod = { exports: {} };
  vm.runInThisContext(`(function(exports,module,require){${js}\n})`)(mod.exports, mod, require);
  const input = fs.readFileSync(path.join(dir, 'wmav2-picture-padding.wma'));
  const size = Number(input.readBigUInt64LE(16));
  const header = mod.exports.AsfHeaderEditor.replaceText(input.subarray(0, size), 'Title',
    'Edited fixture title', input.length, input.subarray(size, size + 50));
  fs.writeFileSync(path.join(dir, 'editor-output.wma'), Buffer.concat([Buffer.from(header), input.subarray(size)]));
  for (const script of ['test-safe-cleanup.cjs', 'test-asf-reader.cjs', 'test-audio-probe-mocked.cjs', 'test-cover-mocked.cjs',
    'test-invalid-audio.cjs', 'test-pixelmap-encoder.cjs', 'test-private-export.cjs', 'test-private-io.cjs',
    'test-staged-integrity.cjs', 'test-staged-integrity-live.cjs', 'test-streaming.cjs', 'test-streaming-live.cjs',
    'test-wma-media-routing.cjs', 'test-working-save.cjs', 'test-writer-mapping.cjs']) run(script);
  console.log('\nPASS ASF portable suite');
} finally {
  cleanupFixtureDirectory(dir);
}
