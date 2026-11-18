'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

// This is an accident guard, not protection against hostile concurrent filesystem changes.
function cleanupFixtureDirectory(candidate) {
  const deny = () => { throw Error('refusing unsafe ASF fixture cleanup path'); };
  const equal = (a, b) => process.platform === 'win32' ? a.toLowerCase() === b.toLowerCase() : a === b;
  if (typeof candidate !== 'string' || !path.isAbsolute(candidate) || candidate !== path.resolve(candidate)) deny();
  const temp = path.resolve(os.tmpdir());
  const base = path.basename(candidate);
  if (!equal(path.dirname(candidate), temp) || !base.startsWith('lyricflow-asf-test-') ||
      base.length <= 'lyricflow-asf-test-'.length) deny();
  const stat = fs.lstatSync(candidate);
  if (stat.isSymbolicLink() || !stat.isDirectory()) deny();
  const canonicalTemp = fs.realpathSync(temp);
  const canonicalTarget = fs.realpathSync(candidate);
  if (!equal(canonicalTarget, path.join(canonicalTemp, base))) deny();
  fs.rmSync(candidate, { recursive: true, force: false });
}
module.exports = { cleanupFixtureDirectory };
