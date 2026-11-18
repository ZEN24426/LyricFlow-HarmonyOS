// SPDX-License-Identifier: GPL-3.0-only
/* ASF reserved-header editor research prototype. GPL-3.0-only.
 * Independently designed after reference to GPL-2.0-or-later Mutagen and
 * LGPL-2.1-or-later FFmpeg. See docs/WMA-ASF.md.
 * No disk I/O. Not a production transaction. */
export class AsfEntry {
  name: string; type: number; value: Uint8Array; start: number; size: number;
  lengthAt: number; lengthBytes: number; objectAt: number; parentAt: number;
  scoped: boolean; raw: Uint8Array;
  constructor(name: string, type: number, value: Uint8Array, start: number, size: number,
    lengthAt: number, lengthBytes: number, objectAt: number, parentAt: number, scoped: boolean, raw: Uint8Array) {
    this.name = name; this.type = type; this.value = value; this.start = start; this.size = size;
    this.lengthAt = lengthAt; this.lengthBytes = lengthBytes; this.objectAt = objectAt;
    this.parentAt = parentAt; this.scoped = scoped; this.raw = raw;
  }
}
export class AsfObject {
  id: string; start: number; size: number;
  constructor(id: string, start: number, size: number) { this.id = id; this.start = start; this.size = size; }
}
export class AsfScan {
  entries: AsfEntry[] = []; objects: AsfObject[] = []; headerSize: number = 0; channels: number = 0; sampleRate: number = 0;
  padding: AsfObject | null = null; extended: AsfObject | null = null;
}
export class AsfPicture {
  pictureType: number; mime: string; description: string; bytes: Uint8Array;
  constructor(pictureType: number, mime: string, description: string, bytes: Uint8Array) {
    this.pictureType=pictureType; this.mime=mime; this.description=description; this.bytes=bytes;
  }
}
export class AsfHeaderEditor {
  static readonly MAX_FILE: number = 8 * 1024 * 1024 * 1024;
  static readonly MAX_HEADER: number = 256 * 1024;
  static readonly HEADER: string = '3026b2758e66cf11a6d900aa0062ce6c';
  static readonly DATA: string = '3626b2758e66cf11a6d900aa0062ce6c';
  static readonly FILE: string = 'a1dcab8c47a9cf118ee400c00c205365';
  static readonly STREAM: string = '9107dcb7b7a9cf118ee600c00c205365';
  static readonly CONTENT: string = '3326b2758e66cf11a6d900aa0062ce6c';
  static readonly EXTENDED: string = '40a4d0d207e3d21197f000a0c95ea850';
  static readonly PADDING: string = '74d40618dfca0945a4ba9aabcb96aae8';
  static readonly CODECS: string = '4052d1861d31d011a3a400a0c90348f6';
  static readonly BITRATE: string = 'ce75f87b8d46d1118d82006097c9a2b2';
  static readonly EXTENSION: string = 'b503bf5f2ea9cf118ee300c00c205365';
  static readonly META: string = 'eacbf8c5af5b77488467aa8c44fa4cca';
  static readonly LIBRARY: string = '941c23449894d149a1411d134e457054';
  static readonly AUDIO: string = '409e69f84d5bcf11a8fd00805f5c442b';
  private static ok(v: boolean, m: string): void { if (!v) { throw new Error(m); } }
  private static u16(a: Uint8Array, p: number): number { return a[p] + 256 * a[p + 1]; }
  private static u32(a: Uint8Array, p: number): number { return a[p] + 256*a[p+1] + 65536*a[p+2] + 16777216*a[p+3]; }
  private static u64(a: Uint8Array, p: number): number {
    const hi: number = AsfHeaderEditor.u32(a,p+4); AsfHeaderEditor.ok(hi <= 2097151,'large integer');
    return AsfHeaderEditor.u32(a,p) + hi * 4294967296;
  }
  private static w16(a: Uint8Array, p: number, n: number): void {
    AsfHeaderEditor.ok(n >= 0 && n <= 65535,'16-bit size overflow'); a[p]=n&255; a[p+1]=(n>>>8)&255;
  }
  private static w32(a: Uint8Array, p: number, n: number): void {
    AsfHeaderEditor.ok(n >= 0 && n <= 4294967295,'32-bit size overflow');
    a[p]=n&255; a[p+1]=(n>>>8)&255; a[p+2]=(n>>>16)&255; a[p+3]=(n>>>24)&255;
  }
  private static w64(a: Uint8Array, p: number, n: number): void {
    AsfHeaderEditor.w32(a,p,n % 4294967296); AsfHeaderEditor.w32(a,p+4,Math.floor(n/4294967296));
  }
  private static id(a: Uint8Array, p: number): string {
    let s: string=''; for (let i: number=0;i<16;i++) { s += a[p+i].toString(16).padStart(2,'0'); } return s;
  }
  private static text(a: Uint8Array, p: number, n: number): string {
    AsfHeaderEditor.ok(n>=2 && n%2===0 && a[p+n-2]===0 && a[p+n-1]===0,'invalid text');
    let s: string='';
    for (let i: number=0;i<n-2;i+=2) {
      const c: number=AsfHeaderEditor.u16(a,p+i); AsfHeaderEditor.ok(c!==0,'embedded NUL');
      if(c>=0xd800 && c<=0xdbff) {
        AsfHeaderEditor.ok(i+2<n-2,'unpaired surrogate'); const d: number=AsfHeaderEditor.u16(a,p+i+2);
        AsfHeaderEditor.ok(d>=0xdc00 && d<=0xdfff,'unpaired surrogate'); s+=String.fromCharCode(c,d); i+=2;
      } else { AsfHeaderEditor.ok(c<0xdc00 || c>0xdfff,'unpaired surrogate'); s+=String.fromCharCode(c); }
    } return s;
  }
  private static encode(s: string): Uint8Array {
    AsfHeaderEditor.ok(s.length <= 32766,'text too long'); const a: Uint8Array=new Uint8Array(s.length*2+2);
    for(let i: number=0;i<s.length;i++) {
      const c: number=s.charCodeAt(i); AsfHeaderEditor.ok(c!==0,'embedded NUL');
      if(c>=0xd800 && c<=0xdbff) {
        AsfHeaderEditor.ok(i+1<s.length,'unpaired surrogate'); const d: number=s.charCodeAt(i+1);
        AsfHeaderEditor.ok(d>=0xdc00 && d<=0xdfff,'unpaired surrogate');
      } else if(c>=0xdc00 && c<=0xdfff) {
        AsfHeaderEditor.ok(i>0 && s.charCodeAt(i-1)>=0xd800 && s.charCodeAt(i-1)<=0xdbff,'unpaired surrogate');
      }
      a[2*i]=c&255; a[2*i+1]=c>>>8;
    } return a;
  }
  private static descriptors(a: Uint8Array, scan: AsfScan, start: number, size: number, parent: number, extended: boolean): void {
    const p: number=start+24; const end: number=start+size; AsfHeaderEditor.ok(size>=26,'short metadata object');
    const count: number=AsfHeaderEditor.u16(a,p); AsfHeaderEditor.ok(count<=1024 && scan.entries.length+count<=2048,'too many descriptors'); let q: number=p+2;
    for(let i: number=0;i<count;i++) {
      const recordStart: number=q; let nameLen: number=0; let type: number=0; let n: number=0; let lengthAt: number=0; let scoped: boolean=false; let name: string='';
      if(extended) {
        AsfHeaderEditor.ok(q<=end-2,'short name length'); nameLen=AsfHeaderEditor.u16(a,q); q+=2;
        AsfHeaderEditor.ok(nameLen>=2 && nameLen<=2048 && nameLen<=end-q,'bad name length'); name=AsfHeaderEditor.text(a,q,nameLen); q+=nameLen;
        AsfHeaderEditor.ok(q<=end-4,'short descriptor'); type=AsfHeaderEditor.u16(a,q); lengthAt=q+2; n=AsfHeaderEditor.u16(a,q+2); q+=4;
      } else {
        AsfHeaderEditor.ok(q<=end-12,'short metadata descriptor'); scoped=AsfHeaderEditor.u16(a,q)!==0 || AsfHeaderEditor.u16(a,q+2)!==0;
        nameLen=AsfHeaderEditor.u16(a,q+4); type=AsfHeaderEditor.u16(a,q+6); lengthAt=q+8; n=AsfHeaderEditor.u32(a,q+8); q+=12;
        AsfHeaderEditor.ok(nameLen>=2 && nameLen<=2048 && nameLen<=end-q,'bad name length'); name=AsfHeaderEditor.text(a,q,nameLen); q+=nameLen;
      }
      AsfHeaderEditor.ok(n<=end-q,'bad value length');
      const low: string=name.toLowerCase(); AsfHeaderEditor.ok(low.indexOf('drm')<0 && low!=='is_protected','protection attribute');
      if(type===0 && n>0) { AsfHeaderEditor.text(a,q,n); }
      scan.entries.push(new AsfEntry(name,type,a.slice(q,q+n),q,n,lengthAt,extended?2:4,start,parent,scoped,a.slice(recordStart,q+n))); q+=n;
    }
    AsfHeaderEditor.ok(q===end,'metadata trailing bytes');
  }
  static scan(a: Uint8Array, totalSize: number, dataHead: Uint8Array): AsfScan {
    AsfHeaderEditor.ok(a.length>=30 && a.length<=AsfHeaderEditor.MAX_HEADER && totalSize>=a.length+50 && totalSize<=AsfHeaderEditor.MAX_FILE && dataHead.length===50,'file or header size outside limit');
    AsfHeaderEditor.ok(AsfHeaderEditor.id(a,0)===AsfHeaderEditor.HEADER,'not ASF');
    const end: number=AsfHeaderEditor.u64(a,16); const count: number=AsfHeaderEditor.u32(a,24);
    AsfHeaderEditor.ok(end===a.length && count<=1024 && a[28]===1 && a[29]===2,'invalid header');
    const scan: AsfScan=new AsfScan(); scan.headerSize=end;
    let p: number=30; let fileAt: number=-1; let streams: number=0; let contents: number=0; let extensions: number=0;
    const names: string[]=['Title','Author','Copyright','Description','Rating'];
    for(let i: number=0;i<count;i++) {
      AsfHeaderEditor.ok(p<=end-24,'truncated object'); const id: string=AsfHeaderEditor.id(a,p);
      const n: number=AsfHeaderEditor.u64(a,p+16); AsfHeaderEditor.ok(n>=24 && n<=end-p,'bad object length');
      const ob: AsfObject=new AsfObject(id,p,n); scan.objects.push(ob); const x: number=p+24; const limit: number=p+n;
      if(id===AsfHeaderEditor.FILE) {
        AsfHeaderEditor.ok(fileAt<0 && n>=104,'invalid file properties'); fileAt=x;
        AsfHeaderEditor.ok(AsfHeaderEditor.u64(a,x+16)===totalSize && (AsfHeaderEditor.u32(a,x+64)&1)===0,'file size or streaming');
      } else if(id===AsfHeaderEditor.STREAM) {
        streams++; AsfHeaderEditor.ok(n>=96 && AsfHeaderEditor.id(a,x)===AsfHeaderEditor.AUDIO,'unsupported stream');
        const flags: number=AsfHeaderEditor.u16(a,x+48); const ts: number=AsfHeaderEditor.u32(a,x+40); const es: number=AsfHeaderEditor.u32(a,x+44);
        AsfHeaderEditor.ok((flags&0x8000)===0 && (flags&0x7f)!==0 && ts>=18 && 54+ts+es===n-24,'invalid stream');
        const codec: number=AsfHeaderEditor.u16(a,x+54); AsfHeaderEditor.ok(codec>=0x160 && codec<=0x163,'unsupported codec');
        const channels: number=AsfHeaderEditor.u16(a,x+56); const rate: number=AsfHeaderEditor.u32(a,x+58);
        const avgBytes: number=AsfHeaderEditor.u32(a,x+62); const align: number=AsfHeaderEditor.u16(a,x+66);
        const bits: number=AsfHeaderEditor.u16(a,x+68); const extra: number=AsfHeaderEditor.u16(a,x+70);
        AsfHeaderEditor.ok(channels>0 && channels<=8 && rate>0 && rate<=384000 && avgBytes>0 && align>0 && bits>0 && extra<=ts-18,'invalid audio format');
        scan.channels=channels; scan.sampleRate=rate;
      } else if(id===AsfHeaderEditor.CONTENT) {
        contents++; AsfHeaderEditor.ok(contents===1 && n>=34,'duplicate content'); let q: number=x+10;
        for(let k: number=0;k<5;k++) {
          const len: number=AsfHeaderEditor.u16(a,x+2*k); AsfHeaderEditor.ok(len<=limit-q,'bad content length');
          if(len>0) { AsfHeaderEditor.text(a,q,len); }
          scan.entries.push(new AsfEntry(names[k],0,a.slice(q,q+len),q,len,x+2*k,2,p,-1,false,a.slice(q,q+len))); q+=len;
        } AsfHeaderEditor.ok(q===limit,'content trailing bytes');
      } else if(id===AsfHeaderEditor.EXTENDED) {
        AsfHeaderEditor.ok(scan.extended===null,'duplicate extended content'); scan.extended=ob;
        AsfHeaderEditor.descriptors(a,scan,p,n,-1,true);
      } else if(id===AsfHeaderEditor.EXTENSION) {
        extensions++; AsfHeaderEditor.ok(extensions===1 && n>=46 && AsfHeaderEditor.id(a,x)==='11d2d3abbaa9cf118ee600c00c205365' && AsfHeaderEditor.u16(a,x+16)===6 && AsfHeaderEditor.u32(a,x+18)===n-46,'invalid extension');
        let q: number=x+22; while(q<limit) {
          AsfHeaderEditor.ok(q<=limit-24,'short extension object'); const kind: string=AsfHeaderEditor.id(a,q); const size: number=AsfHeaderEditor.u64(a,q+16);
          AsfHeaderEditor.ok(size>=24 && size<=limit-q,'bad extension object');
          AsfHeaderEditor.ok(kind===AsfHeaderEditor.META || kind===AsfHeaderEditor.LIBRARY || kind===AsfHeaderEditor.PADDING,'unknown extension object');
          if(kind!==AsfHeaderEditor.PADDING) { AsfHeaderEditor.descriptors(a,scan,q,size,p,false); } q+=size;
        } AsfHeaderEditor.ok(q===limit,'extension length');
      } else if(id===AsfHeaderEditor.PADDING) {
        AsfHeaderEditor.ok(scan.padding===null,'duplicate padding');
        for(let k: number=x;k<limit;k++) { AsfHeaderEditor.ok(a[k]===0,'nonzero padding'); } scan.padding=ob;
      } else { AsfHeaderEditor.ok(id===AsfHeaderEditor.CODECS || id===AsfHeaderEditor.BITRATE,'unknown or protected object'); }
      p=limit;
    }
    AsfHeaderEditor.ok(p===end && fileAt>=0 && streams===1,'missing objects');
    AsfHeaderEditor.ok(AsfHeaderEditor.id(dataHead,0)===AsfHeaderEditor.DATA && AsfHeaderEditor.u64(dataHead,16)===totalSize-end,'unsupported data or trailer');
    for(let i: number=0;i<16;i++) { AsfHeaderEditor.ok(a[fileAt+i]===dataHead[24+i],'file ID mismatch'); }
    for(let i: number=0;i<8;i++) { AsfHeaderEditor.ok(a[fileAt+32+i]===dataHead[40+i],'packet count mismatch'); }
    AsfHeaderEditor.ok(dataHead[48]===1 && dataHead[49]===1,'invalid data reserved bytes');
    return scan;
  }
  static isAbsentContent(a: Uint8Array, entry: AsfEntry): boolean { return entry.size===0 && AsfHeaderEditor.id(a,entry.objectAt)===AsfHeaderEditor.CONTENT; }
  static textValue(entry: AsfEntry): string { return entry.size===0 ? '' : AsfHeaderEditor.text(entry.value,0,entry.size); }
  static pictureValue(entry: AsfEntry): AsfPicture {
    AsfHeaderEditor.ok(entry.name.toLowerCase()==='wm/picture' && entry.type===1 && entry.size>=9, 'invalid picture field');
    const a: Uint8Array=entry.value; const bytesLength: number=AsfHeaderEditor.u32(a,1);
    let q: number=5; let firstEnd: number=-1;
    for(let i: number=q;i+1<a.length && i-q<=512;i+=2) { if(a[i]===0 && a[i+1]===0) { firstEnd=i+2; break; } }
    AsfHeaderEditor.ok(firstEnd>=0,'unterminated picture MIME'); const mime: string=AsfHeaderEditor.text(a,q,firstEnd-q); q=firstEnd;
    let secondEnd: number=-1;
    for(let i: number=q;i+1<a.length && i-q<=8192;i+=2) { if(a[i]===0 && a[i+1]===0) { secondEnd=i+2; break; } }
    AsfHeaderEditor.ok(secondEnd>=0,'unterminated picture description'); const desc: string=AsfHeaderEditor.text(a,q,secondEnd-q); q=secondEnd;
    AsfHeaderEditor.ok(bytesLength===a.length-q,'picture size mismatch'); return new AsfPicture(a[0],mime,desc,a.slice(q));
  }
  static picture(jpegOrPng: Uint8Array, mime: string): Uint8Array {
    AsfHeaderEditor.ok((mime==='image/jpeg' && jpegOrPng.length>=4 && jpegOrPng[0]===255 && jpegOrPng[1]===216 && jpegOrPng[jpegOrPng.length-2]===255 && jpegOrPng[jpegOrPng.length-1]===217) ||
      (mime==='image/png' && jpegOrPng.length>=8 && jpegOrPng[0]===137 && jpegOrPng[1]===80 && jpegOrPng[2]===78 && jpegOrPng[3]===71 && jpegOrPng[4]===13 && jpegOrPng[5]===10 && jpegOrPng[6]===26 && jpegOrPng[7]===10),'unsupported image signature');
    const mt: Uint8Array=AsfHeaderEditor.encode(mime); const out: Uint8Array=new Uint8Array(5+mt.length+2+jpegOrPng.length);
    out[0]=3; AsfHeaderEditor.w32(out,1,jpegOrPng.length); out.set(mt,5); out.set(jpegOrPng,7+mt.length); return out;
  }
  static replaceText(a: Uint8Array, name: string, value: string, totalSize: number, dataHead: Uint8Array): Uint8Array {
    const encoded: Uint8Array=AsfHeaderEditor.encode(value); const scan: AsfScan=AsfHeaderEditor.scan(a,totalSize,dataHead);
    let populated: boolean=false;
    for(const e of scan.entries) {
      if(e.name.toLowerCase()===name.toLowerCase() && !AsfHeaderEditor.isAbsentContent(a,e)) { populated=true; }
    }
    let ordinal: number=0; let count: number=0; let first: string=''; const positions: number[]=[];
    for(const e of scan.entries) {
      if(e.name.toLowerCase()===name.toLowerCase()) {
        const selected: boolean=!(populated && AsfHeaderEditor.isAbsentContent(a,e));
        if(selected) {
          AsfHeaderEditor.ok(e.type===0 && !e.scoped,'unsupported target type or scope');
          const current: string=AsfHeaderEditor.textValue(e);
          if(count===0) { first=current; } else { AsfHeaderEditor.ok(first===current,'ambiguous target'); }
          positions.push(ordinal); count++;
        }
        ordinal++;
      }
    }
    AsfHeaderEditor.ok(count<=8,'too many duplicate targets');
    if(count===0) { return AsfHeaderEditor.replace(a,name,0,encoded,-1,totalSize,dataHead); }
    let candidate: Uint8Array=a;
    for(const index of positions) { candidate=AsfHeaderEditor.replace(candidate,name,0,encoded,index,totalSize,dataHead); }
    return candidate;
  }
  static replacePicture(a: Uint8Array, image: Uint8Array, mime: string, totalSize: number, dataHead: Uint8Array): Uint8Array {
    const scan: AsfScan=AsfHeaderEditor.scan(a,totalSize,dataHead); let found: AsfEntry|null=null;
    for(const entry of scan.entries) {
      if(entry.name.toLowerCase()==='wm/picture') { AsfHeaderEditor.ok(found===null,'multiple pictures unsupported'); found=entry; }
    }
    if(found!==null) {
      AsfHeaderEditor.ok(!found.scoped,'scoped picture unsupported');
      const old: AsfPicture=AsfHeaderEditor.pictureValue(found);
      AsfHeaderEditor.ok(old.pictureType===3 && old.description==='' && (old.mime==='image/jpeg' || old.mime==='image/png'),'existing picture role or description unsupported');
    }
    return AsfHeaderEditor.replace(a,'WM/Picture',1,AsfHeaderEditor.picture(image,mime),-1,totalSize,dataHead);
  }
  private static replace(a: Uint8Array, name: string, type: number, data: Uint8Array, ordinal: number, totalSize: number, dataHead: Uint8Array): Uint8Array {
    const scan: AsfScan=AsfHeaderEditor.scan(a,totalSize,dataHead); let found: AsfEntry|null=null; let seen: number=0;
    for(const e of scan.entries) {
      if(e.name.toLowerCase()===name.toLowerCase()) {
        if(ordinal<0) { AsfHeaderEditor.ok(found===null,'ambiguous target'); found=e; }
        else if(seen===ordinal) { found=e; }
        seen++;
      }
    }
    if(ordinal>=0) { AsfHeaderEditor.ok(found!==null,'target disappeared'); }
    AsfHeaderEditor.ok(scan.padding!==null,'no top-level padding'); const padding: AsfObject=scan.padding as AsfObject;
    let objectAt: number=-1; let parentAt: number=-1; let oldSize: number=0; let editOffset: number=0; let editSize: number=0;
    let payload: Uint8Array=data; let countAt: number=-1;
    if(found!==null) {
      AsfHeaderEditor.ok(found.type===type && !found.scoped,'unsupported target type or scope');
      AsfHeaderEditor.ok(found.lengthBytes!==2 || data.length<=65535,'value too large');
      objectAt=found.objectAt; parentAt=found.parentAt; oldSize=AsfHeaderEditor.u64(a,objectAt+16);
      editOffset=found.start; editSize=found.size;
    } else {
      AsfHeaderEditor.ok(scan.extended!==null,'no extended content object for new field'); const ext: AsfObject=scan.extended as AsfObject;
      AsfHeaderEditor.ok(data.length<=65535,'value too large'); const key: Uint8Array=AsfHeaderEditor.encode(name);
      payload=new Uint8Array(2+key.length+4+data.length); AsfHeaderEditor.w16(payload,0,key.length); payload.set(key,2);
      AsfHeaderEditor.w16(payload,2+key.length,type); AsfHeaderEditor.w16(payload,4+key.length,data.length); payload.set(data,6+key.length);
      objectAt=ext.start; oldSize=ext.size; editOffset=ext.start+ext.size; editSize=0; countAt=ext.start+24;
    }
    const delta: number=payload.length-editSize; const newPad: number=padding.size-delta;
    AsfHeaderEditor.ok(newPad>=24 && newPad<=AsfHeaderEditor.MAX_FILE,'insufficient reserved padding');
    const leaf: Uint8Array=new Uint8Array(oldSize+delta); const split: number=editOffset-objectAt;
    leaf.set(a.subarray(objectAt,editOffset),0); leaf.set(payload,split); leaf.set(a.subarray(editOffset+editSize,objectAt+oldSize),split+payload.length);
    AsfHeaderEditor.w64(leaf,16,leaf.length);
    if(found!==null) {
      const loc: number=found.lengthAt-objectAt;
      if(found.lengthBytes===2) { AsfHeaderEditor.w16(leaf,loc,data.length); } else { AsfHeaderEditor.w32(leaf,loc,data.length); }
    } else { const c: number=AsfHeaderEditor.u16(a,countAt); AsfHeaderEditor.ok(c<65535,'too many descriptors'); AsfHeaderEditor.w16(leaf,countAt-objectAt,c+1); }
    let replaceAt: number=objectAt; let replacement: Uint8Array=leaf;
    if(parentAt>=0) {
      const parentSize: number=AsfHeaderEditor.u64(a,parentAt+16); const inner: number=objectAt-parentAt;
      replacement=new Uint8Array(parentSize+delta); replacement.set(a.subarray(parentAt,objectAt),0); replacement.set(leaf,inner);
      replacement.set(a.subarray(objectAt+oldSize,parentAt+parentSize),inner+leaf.length);
      AsfHeaderEditor.w64(replacement,16,replacement.length); AsfHeaderEditor.w32(replacement,42,replacement.length-46); replaceAt=parentAt;
    }
    const out: Uint8Array=new Uint8Array(a.length); out.set(a.subarray(0,30),0); let pos: number=30;
    for(const ob of scan.objects) {
      if(ob.start===replaceAt) { out.set(replacement,pos); pos+=replacement.length; }
      else if(ob.start===padding.start) { out.set(a.subarray(ob.start,ob.start+16),pos); AsfHeaderEditor.w64(out,pos+16,newPad); pos+=newPad; }
      else { out.set(a.subarray(ob.start,ob.start+ob.size),pos); pos+=ob.size; }
    }
    AsfHeaderEditor.ok(pos===scan.headerSize,'header reconstruction mismatch'); out.set(a.subarray(scan.headerSize),pos);
    AsfHeaderEditor.scan(out,totalSize,dataHead);
    return out;
  }
}









