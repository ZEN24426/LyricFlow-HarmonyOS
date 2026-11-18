// SPDX-License-Identifier: GPL-3.0-only
/* Isolated bounded ASF metadata reader. GPL-3.0-only; see docs/WMA-ASF.md. */
import { image } from '@kit.ImageKit';
import { AudioMetadata } from './AudioMetadataTypes';
import { AsfEntry, AsfScan, AsfObject, AsfPicture, AsfHeaderEditor } from './AsfHeaderEditor';
import { AsfPrivateSource } from './AsfPrivateIO';
import { AsfAudioInfo } from './AsfStreamingExport';
import { AsfSystemAudioProbe } from './AsfSystemAudioProbe';
import { BoundedCoverVerification } from './BoundedCoverVerification';

export class AsfNumberPair {
  current: number; total: number;
  constructor(current: number, total: number) { this.current=current; this.total=total; }
}
export class AsfMetadataProjection {
  private static require(ok: boolean, reason: string): void { if (!ok) { throw new Error(reason); } }
  private static equal(a: Uint8Array, b: Uint8Array): boolean {
    if (a.length!==b.length) { return false; }
    for(let i: number=0;i<a.length;i++) { if(a[i]!==b[i]) { return false; } } return true;
  }
  static one(scan: AsfScan, name: string): AsfEntry|null {
    let found: AsfEntry|null=null;
    for(const item of scan.entries) {
      if(item.name.toLowerCase()===name.toLowerCase()) {
        let emptyContentSlot: boolean=false;
        if(item.size===0) {
          for(const object of scan.objects) { if(object.start===item.objectAt && object.id===AsfHeaderEditor.CONTENT) { emptyContentSlot=true; } }
        }
        if(emptyContentSlot) { continue; }
        AsfMetadataProjection.require(!item.scoped,'scoped metadata unsupported: '+name);
        if(found!==null) {
          AsfMetadataProjection.require(found.type===item.type && AsfMetadataProjection.equal(found.value,item.value),
            'conflicting duplicate metadata: '+name);
        } else { found=item; }
      }
    }
    return found;
  }
  static text(scan: AsfScan, name: string): string {
    const entry: AsfEntry|null=AsfMetadataProjection.one(scan,name);
    if(entry===null) { return ''; }
    AsfMetadataProjection.require(entry.type===0,'unsupported metadata type: '+name);
    return AsfHeaderEditor.textValue(entry);
  }
  static rejectAliases(scan: AsfScan): void {
    const names: string[]=['WM/GenreID','WM/Comments','WM/Lyrics_Synchronised','WM/Track',
      'WM/TrackTotal','WM/TotalTracks','WM/DiscNumber','WM/DiscTotal','WM/TotalDiscs'];
    for(const entry of scan.entries) {
      for(const name of names) {
        AsfMetadataProjection.require(entry.name.toLowerCase()!==name.toLowerCase(),'ambiguous alternate metadata: '+name);
      }
    }
  }
  private static integer(s: string, label: string): number {
    AsfMetadataProjection.require(s.length>0 && s.length<=16 && /^[0-9]+$/.test(s),'invalid numeric metadata: '+label);
    const n: number=Number(s); AsfMetadataProjection.require(Number.isSafeInteger(n) && n>=0,'numeric metadata overflow: '+label);
    return n;
  }
  static numberPair(scan: AsfScan, name: string, allowPair: boolean): AsfNumberPair {
    const entry: AsfEntry|null=AsfMetadataProjection.one(scan,name); if(entry===null) { return new AsfNumberPair(0,0); }
    if(entry.type===0) {
      const value: string=AsfHeaderEditor.textValue(entry); if(value.length===0) { return new AsfNumberPair(0,0); }
      const parts: string[]=value.split('/');
      AsfMetadataProjection.require(parts.length===1 || (allowPair && parts.length===2),'invalid numeric metadata: '+name);
      const current: number=AsfMetadataProjection.integer(parts[0],name);
      const total: number=parts.length===2 ? AsfMetadataProjection.integer(parts[1],name) : 0;
      AsfMetadataProjection.require(total===0 || current<=total,'numeric total is smaller: '+name);
      return new AsfNumberPair(current,total);
    }
    const data: Uint8Array=entry.value;
    if(entry.type===5) {
      AsfMetadataProjection.require(data.length===2,'invalid numeric metadata: '+name);
      return new AsfNumberPair(data[0]+data[1]*256,0);
    }
    if(entry.type===3 || entry.type===4) {
      AsfMetadataProjection.require(data.length===(entry.type===3?4:8),'invalid numeric metadata: '+name);
      const low: number=data[0]+256*data[1]+65536*data[2]+16777216*data[3]; let high: number=0;
      if(data.length===8) { high=data[4]+256*data[5]+65536*data[6]+16777216*data[7]; }
      AsfMetadataProjection.require(high<=2097151,'numeric metadata overflow: '+name);
      return new AsfNumberPair(low+4294967296*high,0);
    }
    throw new Error('unsupported numeric type: '+name);
  }
  static picture(scan: AsfScan): AsfPicture|null {
    let found: AsfEntry|null=null;
    for(const entry of scan.entries) {
      if(entry.name.toLowerCase()==='wm/picture') {
        AsfMetadataProjection.require(found===null && !entry.scoped,'multiple or scoped pictures unsupported'); found=entry;
      }
    }
    if(found===null) { return null; }
    const picture: AsfPicture=AsfHeaderEditor.pictureValue(found);
    AsfMetadataProjection.require(picture.pictureType===3 && (picture.mime==='image/jpeg' || picture.mime==='image/png') &&
      picture.bytes.length>0,'unsupported picture role or MIME');
    return picture;
  }
}

export class AsfMetadataReader {
  private static readonly MAX_IO_ATTEMPTS: number=128;
  private static require(ok: boolean, reason: string): void { if(!ok) { throw new Error(reason); } }
  private static readExactly(source: AsfPrivateSource, offset: number, length: number): Uint8Array {
    AsfMetadataReader.require(length>=0 && length<=AsfHeaderEditor.MAX_HEADER,'read size outside limit');
    const out: Uint8Array=new Uint8Array(length); let done: number=0; let attempts: number=0;
    while(done<length) {
      AsfMetadataReader.require(++attempts<=AsfMetadataReader.MAX_IO_ATTEMPTS,'read retry budget exceeded');
      const part: Uint8Array=source.readAt(offset+done,length-done);
      AsfMetadataReader.require(part.length>0 && part.length<=length-done,'invalid short read');
      out.set(part,done); done+=part.length;
    } return out;
  }
  private static u32(a: Uint8Array, p: number): number { return a[p]+a[p+1]*256+a[p+2]*65536+a[p+3]*16777216; }
  private static headerSize(a: Uint8Array): number {
    const high: number=AsfMetadataReader.u32(a,20); AsfMetadataReader.require(high<=2097151,'header integer too large');
    return AsfMetadataReader.u32(a,16)+4294967296*high;
  }
  private static async decodeCover(picture: AsfPicture): Promise<image.PixelMap> {
    const encoded: Uint8Array=await BoundedCoverVerification.validateCover(picture.bytes,picture.mime);
    const buffer: ArrayBuffer=new ArrayBuffer(encoded.length); new Uint8Array(buffer).set(encoded);
    const source: image.ImageSource=image.createImageSource(buffer); let result: image.PixelMap|undefined=undefined;
    let completed: boolean=false; let releaseFailed: boolean=false;
    try {
      result=await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.BGRA_8888 });
      const info: image.ImageInfo=await result.getImageInfo();
      AsfMetadataReader.require(Number.isInteger(info.size.width) && Number.isInteger(info.size.height) &&
        info.size.width>0 && info.size.height>0 && info.size.width<=1024 && info.size.height<=1024 &&
        info.size.width*info.size.height<=1024*1024 && !info.isHdr && info.pixelFormat===image.PixelMapFormat.BGRA_8888,
        'unsupported decoded picture');
      completed=true;
    } finally {
      try { await source.release(); } catch (_error) { releaseFailed=true; }
      if((!completed || releaseFailed) && result!==undefined) {
        try { await result.release(); } catch (_error) { releaseFailed=true; }
      }
      if(releaseFailed) { throw new Error('picture resource cleanup failed'); }
    }
    if(result===undefined) { throw new Error('picture decode failed'); }
    return result;
  }
  static async read(path: string): Promise<AudioMetadata> {
    const source: AsfPrivateSource=new AsfPrivateSource(path); let cover: image.PixelMap|undefined=undefined;
    let result: AudioMetadata|null=null; let failure: string='';
    try {
      const size: number=source.size(); const token: string=source.snapshotToken();
      AsfMetadataReader.require(Number.isSafeInteger(size) && size>=80 && size<=AsfHeaderEditor.MAX_FILE && token.length>0,'invalid source size or identity');
      const prefix: Uint8Array=AsfMetadataReader.readExactly(source,0,30); const headLen: number=AsfMetadataReader.headerSize(prefix);
      AsfMetadataReader.require(headLen>=30 && headLen<=AsfHeaderEditor.MAX_HEADER && headLen<=size-50,'header size outside limit');
      const header: Uint8Array=AsfMetadataReader.readExactly(source,0,headLen);
      const dataHead: Uint8Array=AsfMetadataReader.readExactly(source,headLen,50);
      const scan: AsfScan=AsfHeaderEditor.scan(header,size,dataHead); AsfMetadataProjection.rejectAliases(scan);
      const media: AsfAudioInfo=await new AsfSystemAudioProbe().inspect(source);
      AsfMetadataReader.require(Number.isSafeInteger(media.durationMs) && media.durationMs>0 && media.channels===scan.channels &&
        media.sampleRate===scan.sampleRate,'audio properties differ');
      const track: AsfNumberPair=AsfMetadataProjection.numberPair(scan,'WM/TrackNumber',true);
      const disc: AsfNumberPair=AsfMetadataProjection.numberPair(scan,'WM/PartOfSet',true);
      const year: AsfNumberPair=AsfMetadataProjection.numberPair(scan,'WM/Year',false);
      const bpm: AsfNumberPair=AsfMetadataProjection.numberPair(scan,'WM/BeatsPerMinute',false);
      const picture: AsfPicture|null=AsfMetadataProjection.picture(scan); if(picture!==null) { cover=await AsfMetadataReader.decodeCover(picture); }
      let bitrate: number=0;
      for(const object of scan.objects) {
        if(object.id===AsfHeaderEditor.STREAM) { bitrate=Math.round(AsfMetadataReader.u32(header,object.start+24+62)*8/1000); }
      }
      result={ title:AsfMetadataProjection.text(scan,'Title'), artist:AsfMetadataProjection.text(scan,'Author'),
        album:AsfMetadataProjection.text(scan,'WM/AlbumTitle'), genre:AsfMetadataProjection.text(scan,'WM/Genre'),
        comment:AsfMetadataProjection.text(scan,'Description'), lyrics:AsfMetadataProjection.text(scan,'WM/Lyrics'),
        albumArtist:AsfMetadataProjection.text(scan,'WM/AlbumArtist'), composer:AsfMetadataProjection.text(scan,'WM/Composer'),
        grouping:AsfMetadataProjection.text(scan,'WM/ContentGroupDescription'), isrc:AsfMetadataProjection.text(scan,'WM/ISRC'),
        copyright:AsfMetadataProjection.text(scan,'Copyright'), year:year.current, track:track.current, trackTotal:track.total,
        disc:disc.current, discTotal:disc.total, bpm:bpm.current, durationMs:media.durationMs,
        duration:Math.floor(media.durationMs/1000), bitrate:bitrate, sampleRate:media.sampleRate, channels:media.channels,
        coverImage:cover, fileType:'audio/x-ms-wma', fileSize:size, creationTime:0, modifyTime:0 };
      AsfMetadataReader.require(source.size()===size && source.snapshotToken()===token,'source changed during metadata read');
    } catch (error) { failure=String(error); }
    try { source.close(); } catch (error) { failure+=(failure.length>0?'; ':'')+'source close failed: '+String(error); }
    if(failure.length>0 || result===null) {
      if(cover!==undefined) { try { await cover.release(); } catch (error) { failure+='; cover release failed: '+String(error); } }
      throw new Error('ASF metadata read failed: '+failure);
    }
    return result;
  }
}

