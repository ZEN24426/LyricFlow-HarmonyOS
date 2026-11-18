// SPDX-License-Identifier: GPL-3.0-only
import { BusinessError } from '@kit.BasicServicesKit';
import { AsfPixelMapEncoder } from './AsfPixelMapEncoder';
import { AsfWriterFields, AsfWriterPlan, AsfWriterMapping } from './AsfWriterMapping';
/* Isolated app-private ASF staged export experiment; no user-file replacement. */
import { AsfStreamingExport, AsfTextEdit, AsfCoverEdit, AsfCoverVerifier } from './AsfStreamingExport';
import { AsfPrivateSource, AsfPrivateStageFactory } from './AsfPrivateIO';
import { AsfSystemAudioProbe } from './AsfSystemAudioProbe';
import { BoundedCoverVerification } from './BoundedCoverVerification';

function safeReason(error: Object): string {
  if(error===null || error===undefined) return 'unavailable';
  const message: string = error instanceof Error ? error.message : '';
  const stages: string[]=['CREATE_MKDTEMP','write_header','copy_data','flush','readback_header',
    'verify_cover','compare_data','probe_output','source_recheck','close_stage','finish_private_stage'];
  for(const phase of stages) {
    const prefix: string='ASF_STAGE_'+phase+' failed';
    if(message===prefix) return prefix;
    if(message.startsWith(prefix+' code=')) {
      const value: string=message.substring((prefix+' code=').length);
      if(/^[0-9]{1,9}$/.test(value)) return prefix+' code='+value;
    }
  }
  const known: string[]=['insufficient reserved padding','ambiguous target','unsupported target type or scope',
    'unknown or protected object','nonempty header extension unsupported','unsupported data or trailer',
    'header size outside limit','invalid source audio info','source changed before staging','cover size outside limit',
    'no top-level padding','multiple pictures unsupported','existing picture role or description unsupported',
    'value too large','unknown extension object','unexpected temporary directory; untrusted path retained'];
  for(const item of known) if(message===item) return item;
  const code: number=(error as BusinessError).code;
  return Number.isSafeInteger(code) ? 'code='+code.toString() : 'unavailable';
}
class ImageKitCoverVerifier implements AsfCoverVerifier {
  async validateCover(encoded: Uint8Array, mime: string): Promise<Uint8Array> {
    return await BoundedCoverVerification.validateCover(encoded,mime);
  }
  async assertCoverRoundTrip(expected: Uint8Array, written: Uint8Array, mime: string): Promise<void> {
    await BoundedCoverVerification.assertCoverRoundTrip(expected,written,mime);
  }
}
/** Ownership handle for a private stage. Dispose after the outer transaction. */
export class AsfPrivateResult {
  readonly path: string;
  private factory: AsfPrivateStageFactory;
  constructor(path: string, factory: AsfPrivateStageFactory) { this.path=path; this.factory=factory; }
  cleanup(): void { this.factory.cleanupReadyPrivateStage(); }
}
export class AsfPrivateExport {
  static readonly PROTOTYPE_VERSION: number = 1;
  /** Preflight all app writer fields; unsupported fields are explicitly rejected. */
  static async exportWorkingFields(sourcePath: string, filesDir: string, fields: AsfWriterFields): Promise<AsfPrivateResult> {
    const plan: AsfWriterPlan=AsfWriterMapping.plan(fields); const edits: AsfTextEdit[]=[];
    for(const entry of plan.edits) { edits.push(new AsfTextEdit(entry.name,entry.value)); }
    let cover: AsfCoverEdit|null=null;
    if(plan.needsCover) {
      if(fields.coverImage===undefined) { throw new Error('cover missing'); }
      cover=new AsfCoverEdit(await AsfPixelMapEncoder.encode(fields.coverImage),'image/png');
    }
    return await AsfPrivateExport.exportWorking(sourcePath,filesDir,edits,cover,plan.forbiddenAliases);
  }
  /** Returns a retained private stage path only; caller owns further verification and cleanup. */
  static async exportWorking(sourcePath: string, filesDir: string, edits: AsfTextEdit[], cover: AsfCoverEdit|null, forbiddenAliases: string[] = []): Promise<AsfPrivateResult> {
    const source: AsfPrivateSource = new AsfPrivateSource(sourcePath);
    let path: string = '';
    let factory: AsfPrivateStageFactory | null = null; let stageFinished: boolean=false; let phase: string='stage_factory';
    try {
      factory = new AsfPrivateStageFactory(filesDir);
      phase='stream_export';
      await AsfStreamingExport.exportCopy(source, factory, new AsfSystemAudioProbe(), new ImageKitCoverVerifier(), edits, cover, forbiddenAliases);
      stageFinished=true; phase='stage_ready'; path = factory.readyPrivatePath();
    } catch (error) {
      let detail: string='';
      if(stageFinished && factory!==null) {
        try { factory.cleanupReadyPrivateStage(); }
        catch (cleanupError) { detail='; cleanup failed, recovery directory: '+factory.recoveryPrivateDir(); }
      }
      try { source.close(); } catch (closeError) { detail+='; source close failed'; }
      if(factory!==null && !stageFinished) {
        const pending: string=factory.recoveryPrivateDir();
        if(pending.length>0) { detail+='; private stage retained, recovery directory: '+pending; }
      }
      throw new Error('private export failed ['+phase+']: '+safeReason(error as Object)+detail);
    }
    try { source.close(); }
    catch (error) {
      let detail: string='';
      if(factory!==null) {
        try { factory.cleanupReadyPrivateStage(); }
        catch (cleanupError) { detail='; cleanup failed, recovery directory: '+factory.recoveryPrivateDir(); }
      } else { detail='; private result retained at '+path; }
      throw new Error('source close failed'+detail);
    }
    if (factory === null) { throw new Error('private stage factory unavailable'); }
    return new AsfPrivateResult(path,factory);
  }
}










