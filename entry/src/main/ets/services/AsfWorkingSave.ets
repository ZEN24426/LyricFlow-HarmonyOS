// SPDX-License-Identifier: GPL-3.0-only
/* Experimental WMA private working-copy integration; does not write user source. */
import { fileIo } from '@kit.CoreFileKit';
import { AudioMetadata, AudioMetadataWriter } from './AudioMetadataTypes';
import { AsfMetadataReader } from './AsfMetadataReader';
import { AsfPrivateExport, AsfPrivateResult } from './AsfPrivateExport';
import { AsfPrivateSource } from './AsfPrivateIO';
import { AsfPixelMapEncoder } from './AsfPixelMapEncoder';
import { AsfWriterMapping, AsfWriterPlan } from './AsfWriterMapping';
import { verifyAsfStagedIntegrity } from './AsfStagedIntegrity';
import { verifyWrittenMetadata, verifyPreservedMetadata } from './MetadataVerification';

class AsfWorkingGuard { static readonly active: Set<string> = new Set<string>(); }
function copyIntent(f: AudioMetadataWriter): AudioMetadataWriter {
  const x: AudioMetadataWriter={};
  x.title=f.title; x.artist=f.artist; x.album=f.album; x.year=f.year; x.track=f.track;
  x.genre=f.genre; x.comment=f.comment; x.lyrics=f.lyrics; x.albumArtist=f.albumArtist; x.composer=f.composer;
  x.disc=f.disc; x.discTotal=f.discTotal; x.trackTotal=f.trackTotal; x.bpm=f.bpm; x.grouping=f.grouping;
  x.isrc=f.isrc; x.copyright=f.copyright; x.coverImage=f.coverImage;
  return x;
}
function delta(f: AudioMetadataWriter, b: AudioMetadata): AudioMetadataWriter {
  const x: AudioMetadataWriter={};
  if(f.title!==undefined && f.title!==b.title) x.title=f.title;
  if(f.artist!==undefined && f.artist!==b.artist) x.artist=f.artist;
  if(f.album!==undefined && f.album!==b.album) x.album=f.album;
  if(f.genre!==undefined && f.genre!==b.genre) x.genre=f.genre;
  if(f.comment!==undefined && f.comment!==b.comment) x.comment=f.comment;
  if(f.lyrics!==undefined && f.lyrics!==b.lyrics) x.lyrics=f.lyrics;
  if(f.albumArtist!==undefined && f.albumArtist!==b.albumArtist) x.albumArtist=f.albumArtist;
  if(f.composer!==undefined && f.composer!==b.composer) x.composer=f.composer;
  if(f.grouping!==undefined && f.grouping!==b.grouping) x.grouping=f.grouping;
  if(f.isrc!==undefined && f.isrc!==b.isrc) x.isrc=f.isrc;
  if(f.copyright!==undefined && f.copyright!==b.copyright) x.copyright=f.copyright;
  if(f.year!==undefined && f.year!==b.year) x.year=f.year;
  if(f.bpm!==undefined && f.bpm!==b.bpm) x.bpm=f.bpm;
  if(f.track!==undefined && f.track!==b.track) x.track=f.track;
  if(f.trackTotal!==undefined && f.trackTotal!==b.trackTotal) x.trackTotal=f.trackTotal;
  if(f.disc!==undefined && f.disc!==b.disc) x.disc=f.disc;
  if(f.discTotal!==undefined && f.discTotal!==b.discTotal) x.discTotal=f.discTotal;
  if(f.coverImage!==undefined) x.coverImage=f.coverImage;
  return x;
}
async function verifyCover(intent: AudioMetadataWriter, before: AudioMetadata, after: AudioMetadata): Promise<void> {
  if(intent.coverImage!==undefined) {
    if(after.coverImage===undefined) throw new Error('written cover missing');
    await AsfPixelMapEncoder.comparePixels(intent.coverImage,after.coverImage); return;
  }
  if(before.coverImage===undefined && after.coverImage===undefined) return;
  if(before.coverImage===undefined || after.coverImage===undefined) throw new Error('unmodified cover presence changed');
  await AsfPixelMapEncoder.comparePixels(before.coverImage,after.coverImage);
}
export async function writeAsfWorkingCopy(root: string, workingPath: string, fields: AudioMetadataWriter): Promise<void> {
  const segments: string[]=workingPath.split('/');
  if(!root.startsWith('/') || !workingPath.startsWith(root+'/') || root.indexOf('\\')>=0 ||
    workingPath.indexOf('\\')>=0 || segments.indexOf('..')>=0 || segments.indexOf('.')>=0 ||
    workingPath.indexOf(String.fromCharCode(0))>=0) { throw new Error('private working path required'); }
  if(AsfWorkingGuard.active.has(workingPath)) { throw new Error('WMA working copy is already being edited'); }
  AsfWorkingGuard.active.add(workingPath);
  let intent: AudioMetadataWriter={};
  let before: AudioMetadata|undefined=undefined; let after: AudioMetadata|undefined=undefined;
  let result: AsfPrivateResult|undefined=undefined; let sourceGuard: AsfPrivateSource|undefined=undefined;
  let stageGuard: AsfPrivateSource|undefined=undefined; let failure: string=''; let replaced: boolean=false;
  try {
    intent=copyIntent(fields);
    sourceGuard=new AsfPrivateSource(workingPath); const sourceToken: string=sourceGuard.snapshotToken(); const sourceSize: number=sourceGuard.size();
    before=await AsfMetadataReader.read(workingPath);
    if(sourceGuard.snapshotToken()!==sourceToken || sourceGuard.size()!==sourceSize) throw new Error('working copy changed during read');
    const changed: AudioMetadataWriter=delta(intent,before);
    if(intent.coverImage!==undefined && before.coverImage!==undefined &&
      await AsfPixelMapEncoder.samePixels(intent.coverImage,before.coverImage)) changed.coverImage=undefined;
    const plan: AsfWriterPlan=AsfWriterMapping.plan(changed);
    if(plan.edits.length>0 || plan.needsCover) {
      result=await AsfPrivateExport.exportWorkingFields(workingPath,root,changed);
      stageGuard=new AsfPrivateSource(result.path); const stageToken: string=stageGuard.snapshotToken(); const stageSize: number=stageGuard.size();
      after=await AsfMetadataReader.read(result.path);
      await verifyWrittenMetadata(intent,after,false);
      await verifyPreservedMetadata(changed,before,after,true,false);
      await verifyCover(intent,before,after);
      const names: string[]=[]; for(const edit of plan.edits) names.push(edit.name); if(plan.needsCover) names.push('WM/Picture');
      await verifyAsfStagedIntegrity(workingPath,result.path,names);
      if(sourceGuard.snapshotToken()!==sourceToken || sourceGuard.size()!==sourceSize ||
        stageGuard.snapshotToken()!==stageToken || stageGuard.size()!==stageSize) throw new Error('source or stage changed before replacement');
      fileIo.renameSync(result.path,workingPath); replaced=true;
    } else {
      await verifyWrittenMetadata(intent,before,false);
      if(sourceGuard.snapshotToken()!==sourceToken || sourceGuard.size()!==sourceSize) throw new Error('working copy changed during verification');
    }
  } catch(error) { failure=String(error); }
  if(stageGuard!==undefined) { try { stageGuard.close(); } catch(error) { failure+='; stage close failed: '+String(error); } }
  if(sourceGuard!==undefined) { try { sourceGuard.close(); } catch(error) { failure+='; source close failed: '+String(error); } }
  if(before!==undefined && before.coverImage!==undefined) {
    try { await before.coverImage.release(); } catch(error) { failure+='; original cover cleanup failed: '+String(error); }
  }
  if(after!==undefined && after.coverImage!==undefined) {
    try { await after.coverImage.release(); } catch(error) { failure+='; output cover cleanup failed: '+String(error); }
  }
  if(result!==undefined) {
    try { result.cleanup(); } catch(error) { failure+='; private stage cleanup failed: '+String(error)+'; stage path: '+result.path; }
  }
  AsfWorkingGuard.active.delete(workingPath);
  if(failure.length>0) throw new Error('ASF private working copy operation failed'+(replaced?' after working copy replacement':'')+': '+failure);
}



