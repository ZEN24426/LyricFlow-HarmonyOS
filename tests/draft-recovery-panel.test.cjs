'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');
const ts = require('typescript');

function harness() {
  const service = {
    summary: { revision: 'revision-one', sourceName: 'song.mp3', savedAt: 1000, coverNeedsReselection: true },
    corrupt: { token: 'corrupt-one', size: 17 },
    inspectError: false, corruptError: false, restoreValue: undefined, discarded: [], abandoned: [], failDiscard: false,
    async inspect() { if (this.inspectError) throw new Error('inspect failed'); return this.summary; },
    async inspectCorrupt() { if (this.corruptError) throw new Error('not confirmed corrupt'); return this.corrupt; },
    async restore(_ctx, revision) { this.requestedRevision = revision; return await this.restoreValue; },
    async commitRestore(_ctx, _session, accept) {
      let claimed = false;
      try { const accepted = accept(() => { claimed = true; });
        return { state: claimed ? 'committed' : accepted === false ? 'rejected' : 'uncertain', editorAccepted: claimed && accepted === true, warning: '' };
      } catch { return { state: claimed ? 'committed' : 'uncertain', editorAccepted: false, warning: '接收状态异常，副本已保留。' }; }
    },
    abandonRestore(session) { this.abandoned.push(session.token); },
    async discard(_ctx, revision) { if (this.failDiscard) throw new Error('stale'); this.discarded.push(['valid', revision]); },
    async discardCorrupt(_ctx, token) { if (this.failDiscard) throw new Error('stale'); this.discarded.push(['corrupt', token]); }
  };
  const removed = [];
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/components/DraftRecoveryPanel.ets'), 'utf8');
  const marker = 'struct DraftRecoveryPanel {';
  const start = source.indexOf(marker), build = source.indexOf('\n  build() {', start);
  assert.ok(start >= 0 && build > start);
  const body = source.slice(start + marker.length, build).replace(/@(Prop|State|Link)\b/g, '');
  const code = ts.transpileModule('class DraftRecoveryPanel {' + body + '\n}', {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const Panel = vm.runInNewContext(code + '\nDraftRecoveryPanel', { Error, DraftService: service,
    AudioMetadataService: { async removeWorkingFile(p) { removed.push(p); } } });
  const panel = new Panel();
  panel.getUIContext = () => ({ getHostContext: () => ({ filesDir: '/sandbox' }) });
  panel.visible = true;
  let releaseCount = 0;
  const result = { session: { token: 'session' }, audio: { workingPath: '/sandbox/lyricflow_work_selected.mp3',
    metadata: { coverImage: { async release() { releaseCount++; } } } },
    content: { lyricText: 'private text', coverNeedsReselection: true } };
  return { panel, service, removed, result, releases: () => releaseCount };
}

test('valid draft requires fresh verification and a separate explicit confirmation before parent callback', async () => {
  const h = harness();
  let accepted = 0, closed = 0;
  h.panel.onRestore = (result, editGeneration, claim) => {
    assert.equal(result, h.result); assert.equal(editGeneration, 7); claim(); accepted++; return true;
  };
  h.panel.onLater = () => { closed++; };
  h.panel.editGeneration = 7;
  await h.panel.refresh();
  assert.equal(h.panel.mode, 'available');
  h.service.restoreValue = h.result;
  await h.panel.beginRestore();
  assert.equal(h.service.requestedRevision, 'revision-one');
  assert.equal(accepted, 0);
  assert.equal(h.panel.pendingReady, true);
  await h.panel.confirmRestore();
  assert.equal(accepted, 1);
  assert.equal(closed, 1);
  assert.equal(h.removed.length, 0);
  assert.equal(h.releases(), 0);
});

test('canceling verified restore cleans private copy and leaves parent untouched', async () => {
  const h = harness();
  let calls = 0;
  h.panel.onRestore = () => { calls++; return true; };
  await h.panel.refresh();
  h.service.restoreValue = h.result;
  await h.panel.beginRestore();
  await h.panel.cancelRestore();
  assert.equal(calls, 0);
  assert.deepEqual(h.removed, ['/sandbox/lyricflow_work_selected.mp3']);
  assert.equal(h.releases(), 1);
  assert.deepEqual(h.service.abandoned, ['session']);
  assert.equal(h.panel.pendingReady, false);
});

test('changed editor or parent rejection never applies the result and cleans it', async () => {
  const h = harness();
  let calls = 0;
  h.panel.onRestore = () => { calls++; return true; };
  await h.panel.refresh();
  h.service.restoreValue = h.result;
  await h.panel.beginRestore();
  h.panel.editGeneration++;
  await h.panel.confirmRestore();
  assert.equal(calls, 0);
  assert.equal(h.removed.length, 1);

  const h2 = harness();
  await h2.panel.refresh();
  h2.service.restoreValue = h2.result;
  h2.panel.onRestore = () => false;
  await h2.panel.beginRestore();
  await h2.panel.confirmRestore();
  assert.equal(h2.removed.length, 1);
  assert.match(h2.panel.status, /当前编辑保持不变/);
});

test('a late verification result after panel closes is released and never delivered', async () => {
  const h = harness();
  await h.panel.refresh();
  let resolve;
  h.service.restoreValue = new Promise(r => { resolve = r; });
  let calls = 0;
  h.panel.onRestore = () => { calls++; return true; };
  const pending = h.panel.beginRestore();
  h.panel.aboutToDisappear();
  resolve(h.result);
  await pending;
  assert.equal(calls, 0);
  assert.equal(h.removed.length, 1);
  assert.equal(h.releases(), 1);
});

test('closing while commit is queued makes its acceptance callback refuse and clean up', async () => {
  const h = harness();
  await h.panel.refresh();
  h.service.restoreValue = h.result;
  await h.panel.beginRestore();
  let releaseCommit;
  h.service.commitRestore = async (_ctx, _session, accept) => {
    await new Promise(resolve => { releaseCommit = resolve; });
    let claimed = false;
    const accepted = accept(() => { claimed = true; });
    return { state: claimed ? 'committed' : accepted === false ? 'rejected' : 'uncertain', editorAccepted: claimed && accepted === true, warning: '' };
  };
  let parentCalls = 0;
  h.panel.onRestore = () => { parentCalls++; return true; };
  const committing = h.panel.confirmRestore();
  h.panel.aboutToDisappear();
  releaseCommit();
  await committing;
  assert.equal(parentCalls, 0);
  assert.equal(h.removed.length, 1);
  assert.deepEqual(h.service.abandoned, ['session']);
});

test('deletion of valid and corrupt drafts requires separate confirmation and uses displayed identifier', async () => {
  for (const isCorrupt of [false, true]) {
    const h = harness();
    h.service.inspectError = isCorrupt;
    await h.panel.refresh();
    assert.equal(h.panel.mode, isCorrupt ? 'corrupt' : 'available');
    h.panel.askDelete();
    assert.equal(h.service.discarded.length, 0);
    await h.panel.confirmDelete();
    assert.deepEqual(h.service.discarded, [[isCorrupt ? 'corrupt' : 'valid', isCorrupt ? 'corrupt-one' : 'revision-one']]);
    assert.equal(h.panel.mode, 'empty');
  }
});

test('unconfirmed read errors are not treated as corruption and stale deletion failure is shown', async () => {
  const h = harness();
  h.service.inspectError = true; h.service.corruptError = true;
  await h.panel.refresh();
  assert.equal(h.panel.mode, 'error');
  h.panel.askDelete();
  await h.panel.confirmDelete();
  assert.equal(h.service.discarded.length, 0);

  const h2 = harness();
  await h2.panel.refresh();
  h2.panel.askDelete(); h2.service.failDiscard = true;
  await h2.panel.confirmDelete();
  assert.equal(h2.panel.mode, 'available');
  assert.match(h2.panel.status, /草稿可能已变化/);
});
