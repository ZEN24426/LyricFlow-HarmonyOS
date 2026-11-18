// SPDX-License-Identifier: GPL-3.0-only
/* Pure AudioMetadataWriter-to-ASF preflight; no filesystem or image I/O. */
import { AudioMetadataWriter } from './AudioMetadataTypes';
export type AsfWriterFields = AudioMetadataWriter;
export class AsfPlannedText {
  name: string; value: string;
  constructor(name: string, value: string) { this.name=name; this.value=value; }
}
export class AsfWriterPlan {
  edits: AsfPlannedText[]=[]; forbiddenAliases: string[]=[]; needsCover: boolean=false;
}
export class AsfWriterMapping {
  private static number(value: number | undefined, min: number, max: number, field: string): string | null {
    if(value===undefined) { return null; }
    if(!Number.isSafeInteger(value) || value<min || value>max) { throw new Error('unsupported numeric value: '+field); }
    return value.toString();
  }
  private static add(plan: AsfWriterPlan, name: string, value: string | undefined): void {
    if(value!==undefined) {
      if(value.length>32766 || value.indexOf(String.fromCharCode(0))>=0) { throw new Error('invalid string value: '+name); }
      plan.edits.push(new AsfPlannedText(name,value));
    }
  }
  /** Undefined leaves unchanged. Empty string requests an empty text value, not record deletion. */
  static plan(fields: AsfWriterFields): AsfWriterPlan {
    const p: AsfWriterPlan=new AsfWriterPlan();
    if(fields.track!==undefined || fields.trackTotal!==undefined || fields.disc!==undefined || fields.discTotal!==undefined) {
      throw new Error('track/disc number and total edits are not yet representable without ambiguity');
    }
    p.needsCover=fields.coverImage!==undefined;
    AsfWriterMapping.add(p,'Title',fields.title); AsfWriterMapping.add(p,'Author',fields.artist);
    AsfWriterMapping.add(p,'WM/AlbumTitle',fields.album); AsfWriterMapping.add(p,'WM/Genre',fields.genre);
    AsfWriterMapping.add(p,'Description',fields.comment); AsfWriterMapping.add(p,'WM/Lyrics',fields.lyrics);
    AsfWriterMapping.add(p,'WM/AlbumArtist',fields.albumArtist); AsfWriterMapping.add(p,'WM/Composer',fields.composer);
    AsfWriterMapping.add(p,'WM/ContentGroupDescription',fields.grouping); AsfWriterMapping.add(p,'WM/ISRC',fields.isrc);
    AsfWriterMapping.add(p,'Copyright',fields.copyright);
    const year: string | null=AsfWriterMapping.number(fields.year,1,9999,'year');
    const bpm: string | null=AsfWriterMapping.number(fields.bpm,1,9999,'bpm');
    if(year!==null) { p.edits.push(new AsfPlannedText('WM/Year',year)); }
    if(bpm!==null) { p.edits.push(new AsfPlannedText('WM/BeatsPerMinute',bpm)); }
    // Avoid leaving known alternate semantic representations stale.
    if(fields.genre!==undefined) { p.forbiddenAliases.push('WM/GenreID'); }
    if(fields.comment!==undefined) { p.forbiddenAliases.push('WM/Comments'); }
    if(fields.lyrics!==undefined) { p.forbiddenAliases.push('WM/Lyrics_Synchronised'); }
    if(p.edits.length>16) { throw new Error('too many ASF edits in one transaction'); }
    return p;
  }
}



