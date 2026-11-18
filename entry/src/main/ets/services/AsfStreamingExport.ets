// SPDX-License-Identifier: GPL-3.0-only
/* Isolated bounded streaming experiment; not connected to a product filesystem.
 * Production must supply independently verified exclusive-create, safe cleanup,
 * source snapshot, image validation, and system media-probe adapters. */
import { AsfHeaderEditor, AsfScan, AsfEntry, AsfPicture } from './AsfHeaderEditor';
import { BusinessError } from '@kit.BasicServicesKit';

export interface AsfReadStream {
  readAt(offset: number, maxLength: number): Uint8Array;
  size(): number;
  snapshotToken(): string;
}
export interface AsfStageStream extends AsfReadStream {
  writeAt(offset: number, data: Uint8Array): number;
  flush(): void;
}
// These are capability contracts, not implemented by CoreFileKit CREATE/rename.
export interface AsfExclusiveStage {
  stream: AsfStageStream;
  finishPrivateStage(): void;
  recoveryPath(): string;
  discardPrivateStage(): void;
  close(): void;
}
export interface AsfStageFactory { createExclusivePrivateStage(): AsfExclusiveStage; }
export class AsfAudioInfo {
  durationMs: number; channels: number; sampleRate: number;
  constructor(durationMs: number, channels: number, sampleRate: number) {
    this.durationMs=durationMs; this.channels=channels; this.sampleRate=sampleRate;
  }
}
export interface AsfAudioProbe { inspect(stream: AsfReadStream): Promise<AsfAudioInfo>; }
export interface AsfCoverVerifier {
  validateCover(encoded: Uint8Array, mime: string): Promise<Uint8Array>;
  assertCoverRoundTrip(expected: Uint8Array, written: Uint8Array, mime: string): Promise<void>;
}
export class AsfTextEdit {
  name: string; value: string;
  constructor(name: string, value: string) { this.name=name; this.value=value; }
}
export class AsfCoverEdit {
  bytes: Uint8Array; mime: string;
  constructor(bytes: Uint8Array, mime: string) { this.bytes=bytes; this.mime=mime; }
}
export class AsfStreamingExport {
  static readonly CHUNK: number = 64 * 1024;
  static readonly MAX_PARTIAL_IO: number = 128;
  static readonly MAX_EDITS: number = 16;
  static readonly MAX_COVER: number = 128 * 1024;
  private static ok(x: boolean, message: string): void { if (!x) { throw new Error(message); } }
  private static u32(a: Uint8Array, p: number): number { return a[p]+a[p+1]*256+a[p+2]*65536+a[p+3]*16777216; }
  private static u64(a: Uint8Array, p: number): number {
    const hi: number=AsfStreamingExport.u32(a,p+4); AsfStreamingExport.ok(hi<=2097151,'integer too large');
    return AsfStreamingExport.u32(a,p)+4294967296*hi;
  }
  private static readExact(source: AsfReadStream, offset: number, length: number): Uint8Array {
    AsfStreamingExport.ok(length>=0 && length<=AsfHeaderEditor.MAX_HEADER,'read bound');
    const out: Uint8Array=new Uint8Array(length); let done: number=0; let attempts: number=0;
    while(done<length) {
      AsfStreamingExport.ok(++attempts<=AsfStreamingExport.MAX_PARTIAL_IO,'read retry budget exceeded');
      const next: Uint8Array=source.readAt(offset+done,length-done);
      AsfStreamingExport.ok(next.length>0 && next.length<=length-done,'short or invalid read');
      out.set(next,done); done+=next.length;
    } return out;
  }
  private static writeAll(out: AsfStageStream, offset: number, data: Uint8Array): void {
    let done: number=0; let attempts: number=0;
    while(done<data.length) {
      AsfStreamingExport.ok(++attempts<=AsfStreamingExport.MAX_PARTIAL_IO,'write retry budget exceeded');
      const count: number=out.writeAt(offset+done,data.subarray(done));
      AsfStreamingExport.ok(Number.isInteger(count) && count>0 && count<=data.length-done,'short or invalid write'); done+=count;
    }
  }
  private static equal(a: Uint8Array, b: Uint8Array): boolean {
    if(a.length!==b.length) { return false; }
    for(let i: number=0;i<a.length;i++) { if(a[i]!==b[i]) { return false; } } return true;
  }
  private static validInfo(a: AsfAudioInfo): boolean {
    return Number.isFinite(a.durationMs) && a.durationMs>0 && Number.isInteger(a.channels) && a.channels>0 && a.channels<=8 &&
      Number.isInteger(a.sampleRate) && a.sampleRate>0 && a.sampleRate<=384000;
  }
  static async exportCopy(source: AsfReadStream, factory: AsfStageFactory, probe: AsfAudioProbe,
    verifier: AsfCoverVerifier, edits: AsfTextEdit[], cover: AsfCoverEdit|null, forbiddenAliases: string[] = []): Promise<void> {
    const size: number=source.size(); const token: string=source.snapshotToken();
    AsfStreamingExport.ok(Number.isSafeInteger(size) && size>=80 && size<=AsfHeaderEditor.MAX_FILE && token.length>0,'source size or identity');
    AsfStreamingExport.ok(edits.length<=AsfStreamingExport.MAX_EDITS,'too many edits');
    const editSnapshot: AsfTextEdit[]=[];
    for(let i: number=0;i<edits.length;i++) {
      AsfStreamingExport.ok(edits[i].name.length>0 && edits[i].name.length<=1023 && edits[i].value.length<=32766 && edits[i].name.toLowerCase()!=='wm/picture','invalid text edit');
      for(let j: number=0;j<i;j++) { AsfStreamingExport.ok(edits[i].name.toLowerCase()!==edits[j].name.toLowerCase(),'duplicate edit'); }
      editSnapshot.push(new AsfTextEdit(edits[i].name,edits[i].value));
    }
    let coverInput: Uint8Array|null=null; let coverMime: string='';
    if(cover!==null) {
      AsfStreamingExport.ok(cover.bytes.length>0 && cover.bytes.length<=AsfStreamingExport.MAX_COVER,'cover size outside limit');
      coverInput=cover.bytes.slice(); coverMime=cover.mime;
    }
    const prefix: Uint8Array=AsfStreamingExport.readExact(source,0,30); const headerSize: number=AsfStreamingExport.u64(prefix,16);
    AsfStreamingExport.ok(headerSize>=30 && headerSize<=AsfHeaderEditor.MAX_HEADER && headerSize<=size-50,'header size outside limit');
    const original: Uint8Array=AsfStreamingExport.readExact(source,0,headerSize);
    const dataHead: Uint8Array=AsfStreamingExport.readExact(source,headerSize,50);
    const sourceScan: AsfScan=AsfHeaderEditor.scan(original,size,dataHead);
    AsfStreamingExport.ok(forbiddenAliases.length<=16,'too many alias checks');
    for(const alias of forbiddenAliases) {
      for(const existing of sourceScan.entries) {
        AsfStreamingExport.ok(existing.name.toLowerCase()!==alias.toLowerCase(),'conflicting alternate metadata: '+alias);
      }
    }
    const sourceInfo: AsfAudioInfo=await probe.inspect(source); AsfStreamingExport.ok(AsfStreamingExport.validInfo(sourceInfo) && sourceInfo.channels===sourceScan.channels && sourceInfo.sampleRate===sourceScan.sampleRate,'invalid source audio info');
    let checkedCover: Uint8Array|null=null;
    if(coverInput!==null) {
      checkedCover=await verifier.validateCover(coverInput,coverMime);
      AsfStreamingExport.ok(AsfStreamingExport.equal(coverInput,checkedCover),'validated cover bytes changed');
    }
    let candidate: Uint8Array=original;
    for(const e of editSnapshot) { candidate=AsfHeaderEditor.replaceText(candidate,e.name,e.value,size,dataHead); }
    if(coverInput!==null && checkedCover!==null) { candidate=AsfHeaderEditor.replacePicture(candidate,checkedCover,coverMime,size,dataHead); }
    AsfStreamingExport.ok(source.size()===size && source.snapshotToken()===token,'source changed before staging');
    const stage: AsfExclusiveStage=factory.createExclusivePrivateStage();
    let phase: string='write_header';
    try {
      AsfStreamingExport.writeAll(stage.stream,0,candidate);
      phase='copy_data';
      for(let pos: number=headerSize;pos<size;) {
        const n: number=Math.min(AsfStreamingExport.CHUNK,size-pos); const bytes: Uint8Array=AsfStreamingExport.readExact(source,pos,n);
        AsfStreamingExport.writeAll(stage.stream,pos,bytes); pos+=n;
      }
      phase='flush';
      AsfStreamingExport.ok(stage.stream.size()===size,'staged size mismatch'); stage.stream.flush();
      phase='readback_header';
      const stagedHeader: Uint8Array=AsfStreamingExport.readExact(stage.stream,0,headerSize);
      AsfStreamingExport.ok(AsfStreamingExport.equal(stagedHeader,candidate),'header readback mismatch');
      const writtenHead: Uint8Array=AsfStreamingExport.readExact(stage.stream,headerSize,50);
      const parsed: AsfScan=AsfHeaderEditor.scan(stagedHeader,size,writtenHead);
      for(const edit of editSnapshot) {
        let matches: number=0;
        for(const entry of parsed.entries) {
          if(entry.name.toLowerCase()===edit.name.toLowerCase() && !AsfHeaderEditor.isAbsentContent(stagedHeader,entry)) {
            AsfStreamingExport.ok(entry.type===0 && !entry.scoped && AsfHeaderEditor.textValue(entry)===edit.value,'edited text readback mismatch'); matches++;
          }
        }
        AsfStreamingExport.ok(matches>0,'edited text missing after write');
      }
      // Unedited metadata values and declared types retain their original order and bytes.
      let nextUnedited: number=0;
      for(const previous of sourceScan.entries) {
        let touched: boolean=coverInput!==null && previous.name.toLowerCase()==='wm/picture';
        for(const edit of editSnapshot) { if(previous.name.toLowerCase()===edit.name.toLowerCase()) { touched=true; } }
        if(touched) { continue; }
        let matched: boolean=false;
        while(nextUnedited<parsed.entries.length) {
          const current: AsfEntry=parsed.entries[nextUnedited++]; let skip: boolean=coverInput!==null && current.name.toLowerCase()==='wm/picture';
          for(const edit of editSnapshot) { if(current.name.toLowerCase()===edit.name.toLowerCase()) { skip=true; } }
          if(skip) { continue; }
          AsfStreamingExport.ok(previous.name===current.name && previous.type===current.type && previous.scoped===current.scoped &&
            AsfStreamingExport.equal(previous.raw,current.raw),'unmodified metadata changed'); matched=true; break;
        }
        AsfStreamingExport.ok(matched,'unmodified metadata missing');
      }
      if(coverInput!==null) {
        phase='verify_cover';
        let found: AsfEntry|null=null;
        for(const e of parsed.entries) { if(e.name.toLowerCase()==='wm/picture') { AsfStreamingExport.ok(found===null,'multiple pictures'); found=e; } }
        AsfStreamingExport.ok(found!==null,'picture missing after write');
        if(found===null) { throw new Error('picture missing after write'); }
        const pic: AsfPicture=AsfHeaderEditor.pictureValue(found);
        AsfStreamingExport.ok(pic.pictureType===3 && pic.description==='' && pic.mime===coverMime,'picture readback mismatch');
        AsfStreamingExport.ok(checkedCover!==null,'validated cover missing');
        if(checkedCover===null) { throw new Error('validated cover missing'); }
        await verifier.assertCoverRoundTrip(checkedCover,pic.bytes,coverMime);
      }
      phase='compare_data';
      for(let pos: number=headerSize;pos<size;) {
        const n: number=Math.min(AsfStreamingExport.CHUNK,size-pos);
        const oldChunk: Uint8Array=AsfStreamingExport.readExact(source,pos,n); const newChunk: Uint8Array=AsfStreamingExport.readExact(stage.stream,pos,n);
        AsfStreamingExport.ok(AsfStreamingExport.equal(oldChunk,newChunk),'audio data changed'); pos+=n;
      }
      phase='probe_output';
      const outputInfo: AsfAudioInfo=await probe.inspect(stage.stream);
      AsfStreamingExport.ok(AsfStreamingExport.validInfo(outputInfo) && sourceInfo.durationMs===outputInfo.durationMs &&
        sourceInfo.channels===outputInfo.channels && sourceInfo.sampleRate===outputInfo.sampleRate &&
        outputInfo.channels===parsed.channels && outputInfo.sampleRate===parsed.sampleRate,'audio properties changed');
      phase='source_recheck';
      AsfStreamingExport.ok(source.size()===size && source.snapshotToken()===token &&
        AsfStreamingExport.equal(AsfStreamingExport.readExact(source,0,headerSize),original),'source changed during staging');
      phase='close_stage'; stage.close();
      phase='finish_private_stage'; stage.finishPrivateStage();
    } catch (e) {
      let cleanupOk: boolean=true;
      try { stage.close(); } catch (closeError) { cleanupOk=false; }
      try { stage.discardPrivateStage(); } catch (cleanupError) { cleanupOk=false; }
      if(!cleanupOk) { throw new Error('transaction failed; private stage cleanup incomplete; recovery directory: '+stage.recoveryPath()); }
      let code: number = NaN;
      if (e !== null && e !== undefined) { code = (e as BusinessError).code; }
      const suffix: string = Number.isSafeInteger(code) ? ' code=' + code.toString() : '';
      throw new Error('ASF_STAGE_' + phase + ' failed' + suffix);
    }

  }
}














