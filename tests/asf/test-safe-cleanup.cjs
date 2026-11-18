'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { cleanupFixtureDirectory } = require('./safe-cleanup.cjs');
const temp = path.resolve(os.tmpdir());
const dir = fs.mkdtempSync(path.join(temp, 'lyricflow-asf-test-'));
const nested = path.join(dir, 'lyricflow-asf-test-nested');
const marker = path.join(dir, 'marker');
const link = path.join(temp, 'lyricflow-asf-test-link-' + path.basename(dir).slice(-6));
let createdLink = false;
try {
  fs.mkdirSync(nested);
  fs.writeFileSync(marker, 'keep');
  for (const bad of ['relative', temp, path.join(temp, 'wrong-prefix'), nested,
    path.join(temp, 'lyricflow-asf-test-'), temp + path.sep + '..' + path.sep + path.basename(temp) + path.sep + path.basename(dir)]) {
    assert.throws(() => cleanupFixtureDirectory(bad));
    assert.equal(fs.readFileSync(marker, 'utf8'), 'keep');
  }
  fs.symlinkSync(dir, link, process.platform === 'win32' ? 'junction' : 'dir');
  createdLink = true;
  assert.throws(() => cleanupFixtureDirectory(link), /refusing unsafe/);
  assert.equal(fs.readFileSync(marker, 'utf8'), 'keep');
  fs.unlinkSync(link);
  createdLink = false;
  cleanupFixtureDirectory(dir);
  assert.equal(fs.existsSync(dir), false);
  console.log('PASS guarded cleanup: invalid, nested and symlink/junction paths refused');
} finally {
  if (createdLink) fs.unlinkSync(link);
  if (fs.existsSync(dir)) cleanupFixtureDirectory(dir);
}
