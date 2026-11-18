// SPDX-License-Identifier: GPL-3.0-only
/* Independent, bounded ASF stage verification; GPL-3.0-only.
 * Reads two app-private files only. Does not modify or publish either one.
 * Snapshot/stat checks are not a proof against noncooperating concurrent writes. */
import { AsfPrivateSource } from './AsfPrivateIO';
import { AsfHeaderEditor, AsfScan, AsfObject, AsfEntry } from './AsfHeaderEditor';
import { AsfReadStream, AsfAudioInfo, AsfAudioProbe } from './AsfStreamingExport';
import { AsfSystemAudioProbe } from './AsfSystemAudioProbe';

export class AsfStagedIntegrity {
  static readonly CHUNK: number = 64 * 1024;
  static readonly MAX_PARTIAL_READS: number = 128;
  private static ok(condition: boolean, reason: string): void { if (!condition) { throw new Error(reason); } }
  private static u32(a: Uint8Array, p: number): number {
    return a[p] + 256*a[p+1] + 65536*a[p+2] + 16777216*a[p+3];
  }
  private static u64(a: Uint8Array, p: number): number {
    const high: number=AsfStagedIntegrity.u32(a,p+4);
    AsfStagedIntegrity.ok(high<=2097151,'oversized integer');
    return AsfStagedIntegrity.u32(a,p)+high*4294967296;
  }
  private static id(a: Uint8Array, p: number): string {
    let out: string='';
    for(let i: number=0;i<16;i++) { out+=a[p+i].toString(16).padStart(2,'0'); }
    return out;
  }
  private static exact(stream: AsfReadStream, offset: number, length: number): Uint8Array {
    AsfStagedIntegrity.ok(Number.isSafeInteger(offset) && offset>=0 && Number.isInteger(length) &&
      length>=0 && length<=AsfHeaderEditor.MAX_HEADER,'read bound exceeded');
    const out: Uint8Array=new Uint8Array(length); let pos: number=0; let attempts: number=0;
    while(pos<length) {
      AsfStagedIntegrity.ok(++attempts<=AsfStagedIntegrity.MAX_PARTIAL_READS,'read retry budget exceeded');
      const part: Uint8Array=stream.readAt(offset+pos,length-pos);
      AsfStagedIntegrity.ok(part.length>0 && part.length<=length-pos,'invalid short read');
      out.set(part,pos); pos+=part.length;
    }
    return out;
  }
  private static equal(a: Uint8Array, b: Uint8Array): boolean {
    if(a.length!==b.length) { return false; }
    for(let i: number=0;i<a.length;i++) { if(a[i]!==b[i]) { return false; } }
    return true;
  }
  private static mutable(id: string): boolean {
    return id===AsfHeaderEditor.CONTENT || id===AsfHeaderEditor.EXTENDED ||
      id===AsfHeaderEditor.EXTENSION || id===AsfHeaderEditor.PADDING;
  }
  private static extensionPadding(header: Uint8Array, scan: AsfScan): Uint8Array[] {
    const result: Uint8Array[]=[];
    for(const object of scan.objects) {
      if(object.id!==AsfHeaderEditor.EXTENSION) { continue; }
      // Preserve the reserved GUID and WORD; the enclosing sizes can change.
      result.push(header.slice(object.start+24,object.start+42));
      let pos: number=object.start+46; const end: number=object.start+object.size;
      while(pos<end) {
        AsfStagedIntegrity.ok(pos<=end-24,'truncated extension object');
        const length: number=AsfStagedIntegrity.u64(header,pos+16);
        AsfStagedIntegrity.ok(length>=24 && length<=end-pos,'invalid extension object');
        result.push(header.slice(pos,pos+16));
        if(AsfStagedIntegrity.id(header,pos)===AsfHeaderEditor.PADDING) { result.push(header.slice(pos,pos+length)); }
        pos+=length;
      }
      AsfStagedIntegrity.ok(pos===end,'invalid extension size');
    }
    return result;
  }
  private static compareFixedHeader(before: Uint8Array, after: Uint8Array, a: AsfScan, b: AsfScan): void {
    AsfStagedIntegrity.ok(a.objects.length===b.objects.length,'header object count changed');
    for(let i: number=0;i<a.objects.length;i++) {
      AsfStagedIntegrity.ok(a.objects[i].id===b.objects[i].id,'header object type or order changed');
    }
    const left: AsfObject[]=[]; const right: AsfObject[]=[];
    for(const object of a.objects) { if(!AsfStagedIntegrity.mutable(object.id)) { left.push(object); } }
    for(const object of b.objects) { if(!AsfStagedIntegrity.mutable(object.id)) { right.push(object); } }
    AsfStagedIntegrity.ok(left.length===right.length,'nonmetadata object count changed');
    for(let i: number=0;i<left.length;i++) {
      AsfStagedIntegrity.ok(left[i].id===right[i].id && left[i].size===right[i].size &&
        AsfStagedIntegrity.equal(before.subarray(left[i].start,left[i].start+left[i].size),
          after.subarray(right[i].start,right[i].start+right[i].size)), 'nonmetadata header object changed');
    }
    const ap: Uint8Array[]=AsfStagedIntegrity.extensionPadding(before,a);
    const bp: Uint8Array[]=AsfStagedIntegrity.extensionPadding(after,b);
    AsfStagedIntegrity.ok(ap.length===bp.length,'header extension structure changed');
    for(let i: number=0;i<ap.length;i++) {
      AsfStagedIntegrity.ok(AsfStagedIntegrity.equal(ap[i],bp[i]),'nonmetadata extension object changed');
    }
  }
  private static compareUnedited(a: AsfScan, b: AsfScan, names: string[]): void {
    AsfStagedIntegrity.ok(names.length<=17,'too many edited fields');
    const left: AsfEntry[]=[]; const right: AsfEntry[]=[];
    for(const e of a.entries) { let edited: boolean=false; for(const name of names) { if(e.name.toLowerCase()===name.toLowerCase()) edited=true; } if(!edited) left.push(e); }
    for(const e of b.entries) { let edited: boolean=false; for(const name of names) { if(e.name.toLowerCase()===name.toLowerCase()) edited=true; } if(!edited) right.push(e); }
    AsfStagedIntegrity.ok(left.length===right.length,'unedited metadata count changed');
    for(let i: number=0;i<left.length;i++) {
      AsfStagedIntegrity.ok(left[i].name===right[i].name && left[i].type===right[i].type && left[i].scoped===right[i].scoped &&
        AsfStagedIntegrity.equal(left[i].raw,right[i].raw),'unedited metadata changed');
    }
  }
  private static compareEdited(beforeHeader: Uint8Array, afterHeader: Uint8Array, a: AsfScan, b: AsfScan, names: string[]): void {
    for(const name of names) {
      const left: AsfEntry[]=[]; const right: AsfEntry[]=[];
      for(const e of a.entries) if(e.name.toLowerCase()===name.toLowerCase()) left.push(e);
      for(const e of b.entries) if(e.name.toLowerCase()===name.toLowerCase()) right.push(e);
      AsfStagedIntegrity.ok(left.length<=8 && right.length===(left.length===0?1:left.length),'edited metadata multiplicity changed');
      if(left.length===0) {
        AsfStagedIntegrity.ok(!right[0].scoped && right[0].type===(name.toLowerCase()==='wm/picture'?1:0),'invalid new metadata type');
      } else {
        let hasPresent: boolean=false;
        for(const entry of left) if(!AsfHeaderEditor.isAbsentContent(beforeHeader,entry)) hasPresent=true;
        for(let i: number=0;i<left.length;i++) {
          AsfStagedIntegrity.ok(!left[i].scoped && !right[i].scoped && left[i].name===right[i].name && left[i].type===right[i].type &&
            AsfStagedIntegrity.id(beforeHeader,left[i].objectAt)===AsfStagedIntegrity.id(afterHeader,right[i].objectAt),
            'edited metadata type or scope changed');
          const wasAbsent: boolean=AsfHeaderEditor.isAbsentContent(beforeHeader,left[i]);
          const nowAbsent: boolean=AsfHeaderEditor.isAbsentContent(afterHeader,right[i]);
          AsfStagedIntegrity.ok(wasAbsent && hasPresent ? nowAbsent : !nowAbsent,'edited metadata presence changed');
        }
      }
    }
  }
  private static validAudio(info: AsfAudioInfo): boolean {
    return Number.isSafeInteger(info.durationMs) && info.durationMs>0 &&
      Number.isInteger(info.channels) && info.channels>0 && info.channels<=8 &&
      Number.isInteger(info.sampleRate) && info.sampleRate>0 && info.sampleRate<=384000;
  }
  /** Testable stream core; caller must own and close both handles. */
  static async verifyStreams(before: AsfReadStream, after: AsfReadStream, probe: AsfAudioProbe, editedNames: string[] = []): Promise<void> {
    const beforeSize: number=before.size(); const afterSize: number=after.size();
    const beforeToken: string=before.snapshotToken(); const afterToken: string=after.snapshotToken();
    AsfStagedIntegrity.ok(Number.isSafeInteger(beforeSize) && beforeSize>=80 && beforeSize<=AsfHeaderEditor.MAX_FILE &&
      beforeSize===afterSize && beforeToken.length>0 && afterToken.length>0,'invalid file size or identity');
    AsfStagedIntegrity.ok(beforeToken!==afterToken,'source and staged file identities may alias');
    const prefixA: Uint8Array=AsfStagedIntegrity.exact(before,0,30); const prefixB: Uint8Array=AsfStagedIntegrity.exact(after,0,30);
    const headSize: number=AsfStagedIntegrity.u64(prefixA,16);
    AsfStagedIntegrity.ok(headSize>=30 && headSize<=AsfHeaderEditor.MAX_HEADER && headSize<=beforeSize-50 &&
      AsfStagedIntegrity.u64(prefixB,16)===headSize,'header size changed or invalid');
    const headerA: Uint8Array=AsfStagedIntegrity.exact(before,0,headSize);
    const headerB: Uint8Array=AsfStagedIntegrity.exact(after,0,headSize);
    const dataA: Uint8Array=AsfStagedIntegrity.exact(before,headSize,50);
    const dataB: Uint8Array=AsfStagedIntegrity.exact(after,headSize,50);
    const scanA: AsfScan=AsfHeaderEditor.scan(headerA,beforeSize,dataA); const scanB: AsfScan=AsfHeaderEditor.scan(headerB,afterSize,dataB);
    AsfStagedIntegrity.compareFixedHeader(headerA,headerB,scanA,scanB);
    AsfStagedIntegrity.compareUnedited(scanA,scanB,editedNames);
    AsfStagedIntegrity.compareEdited(headerA,headerB,scanA,scanB,editedNames);
    const audioA: AsfAudioInfo=await probe.inspect(before); const audioB: AsfAudioInfo=await probe.inspect(after);
    AsfStagedIntegrity.ok(AsfStagedIntegrity.validAudio(audioA) && AsfStagedIntegrity.validAudio(audioB) &&
      audioA.durationMs===audioB.durationMs && audioA.channels===audioB.channels && audioA.sampleRate===audioB.sampleRate &&
      audioA.channels===scanA.channels && audioB.channels===scanB.channels &&
      audioA.sampleRate===scanA.sampleRate && audioB.sampleRate===scanB.sampleRate,'media attributes changed or invalid');
    for(let pos: number=headSize;pos<beforeSize;) {
      const size: number=Math.min(AsfStagedIntegrity.CHUNK,beforeSize-pos);
      AsfStagedIntegrity.ok(AsfStagedIntegrity.equal(AsfStagedIntegrity.exact(before,pos,size),
        AsfStagedIntegrity.exact(after,pos,size)),'Data object bytes differ'); pos+=size;
    }
    AsfStagedIntegrity.ok(AsfStagedIntegrity.equal(headerA,AsfStagedIntegrity.exact(before,0,headSize)) &&
      AsfStagedIntegrity.equal(headerB,AsfStagedIntegrity.exact(after,0,headSize)) &&
      before.size()===beforeSize && after.size()===afterSize && before.snapshotToken()===beforeToken &&
      after.snapshotToken()===afterToken,'file changed during verification');
  }
}

/** Reopens files independently. Metadata-value validation remains an outer responsibility. */
export async function verifyAsfStagedIntegrity(beforePath: string, afterPath: string, editedNames: string[] = []): Promise<void> {
  if(beforePath===afterPath) { throw new Error('source and staged path must differ'); }
  let before: AsfPrivateSource | undefined = undefined; let after: AsfPrivateSource | undefined = undefined;
  let failure: string='';
  try {
    before=new AsfPrivateSource(beforePath); after=new AsfPrivateSource(afterPath);
    await AsfStagedIntegrity.verifyStreams(before,after,new AsfSystemAudioProbe(),editedNames);
  } catch (error) { failure=String(error); }
  let closeFailure: string='';
  if(after!==undefined) { try { after.close(); } catch(error) { closeFailure+='; staged close failed: '+String(error); } }
  if(before!==undefined) { try { before.close(); } catch(error) { closeFailure+='; source close failed: '+String(error); } }
  if(failure.length>0 || closeFailure.length>0) { throw new Error('ASF integrity verification failed: '+failure+closeFailure); }
}




