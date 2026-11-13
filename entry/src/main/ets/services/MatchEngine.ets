import {
  analyzeSongName,
  normalizeSongName,
  normalizeText,
  sameVersionTags,
  versionTagDifference,
  SongNameVariant,
  SongNameAnalysis
} from './SongNameAnalyzer';

export interface AudioMatchInput {
  id: string;
  name: string;
  uri?: string;
  title?: string;
  artist?: string;
}

export interface LyricMatchInput {
  id: string;
  name: string;
  uri?: string;
  title?: string;
  artist?: string;
}

export type MatchReviewState = 'pending' | 'confirmed' | 'rejected' | 'deferred';

export interface MatchCandidate {
  key: string;
  audioId: string;
  audioName: string;
  audioUri?: string;
  lyricId: string;
  lyricName: string;
  lyricUri?: string;
  confidence: number;
  strength: 'high' | 'review';
  strategy: string;
  evidence: string[];
  warnings: string[];
  audioTitle: string;
  audioArtist: string;
  lyricTitle: string;
  lyricArtist: string;
  state: MatchReviewState;
}

interface ScoredReason {
  score: number;
  strategy: string;
  evidence: string;
}

interface VariantMatchResult {
  matched: boolean;
  ambiguous: boolean;
  title: string;
  artist: string;
}

function chooseBest(current: ScoredReason | null, next: ScoredReason): ScoredReason {
  return current === null || next.score > current.score ? next : current;
}

function metadataTitle(audio: AudioMatchInput): string {
  return audio.title === undefined ? '' : normalizeText(audio.title);
}

function metadataArtist(audio: AudioMatchInput): string {
  return audio.artist === undefined ? '' : normalizeText(audio.artist);
}

function lyricTitle(lyric: LyricMatchInput, info: SongNameAnalysis): string {
  if (lyric.title !== undefined && lyric.title.trim().length > 0) {
    return normalizeText(lyric.title);
  }
  return info.title;
}

function lyricArtist(lyric: LyricMatchInput): string {
  if (lyric.artist !== undefined && lyric.artist.trim().length > 0) {
    return normalizeText(lyric.artist);
  }
  return '';
}

function hasMatchingVariant(
  audioInfo: SongNameAnalysis,
  lyricInfo: SongNameAnalysis
): VariantMatchResult {
  const audioVariants: SongNameVariant[] = audioInfo.variants;
  const lyricVariants: SongNameVariant[] = lyricInfo.variants;
  for (let i: number = 0; i < audioVariants.length; i++) {
    for (let j: number = 0; j < lyricVariants.length; j++) {
      const left: SongNameVariant = audioVariants[i];
      const right: SongNameVariant = lyricVariants[j];
      if (normalizeText(left.title) !== normalizeText(right.title)) continue;
      if (normalizeText(left.artist) !== normalizeText(right.artist)) continue;
      return {
        matched: true,
        ambiguous: left.pattern.indexOf('ambiguous') >= 0 || right.pattern.indexOf('ambiguous') >= 0,
        title: left.title,
        artist: left.artist
      };
    }
  }
  return { matched: false, ambiguous: false, title: '', artist: '' };
}

function scorePair(
  audio: AudioMatchInput,
  lyric: LyricMatchInput,
  audioInfo: SongNameAnalysis,
  lyricInfo: SongNameAnalysis
): MatchCandidate | null {
  const leftName: string = audioInfo.rawName;
  const rightName: string = lyricInfo.rawName;
  const leftNormalized: string = normalizeSongName(leftName);
  const rightNormalized: string = normalizeSongName(rightName);
  let best: ScoredReason | null = null;
  const evidence: string[] = [];
  const warnings: string[] = [];

  if (leftName === rightName) {
    best = chooseBest(best, {
      score: 100,
      strategy: '文件名完全匹配',
      evidence: '忽略扩展名后文件名完全相同'
    });
  } else if (leftNormalized.length > 0 && leftNormalized === rightNormalized) {
    best = chooseBest(best, {
      score: 94,
      strategy: '标准化文件名匹配',
      evidence: '大小写、空白和常见标点标准化后相同'
    });
  }

  if (audioInfo.title.length > 0 && audioInfo.title === lyricInfo.title &&
      audioInfo.title !== leftNormalized) {
    const sameVersion: boolean = sameVersionTags(audioInfo.versionTags, lyricInfo.versionTags);
    best = chooseBest(best, {
      score: sameVersion ? 82 : 70,
      strategy: '版本与附加标记分析',
      evidence: '移除用于比较的版本词后歌曲名相同；版本标记仍单独核验'
    });
  } else if (audioInfo.title.length > 0 && audioInfo.title === lyricInfo.title &&
      (audioInfo.versionTags.length > 0 || lyricInfo.versionTags.length > 0)) {
    best = chooseBest(best, {
      score: sameVersionTags(audioInfo.versionTags, lyricInfo.versionTags) ? 80 : 68,
      strategy: '版本与附加标记分析',
      evidence: '歌曲主标题相同，但不能仅凭标题认定版本一致'
    });
  }

  const trackTitle: string = metadataTitle(audio);
  const trackArtist: string = metadataArtist(audio);
  const candidateTitle: string = lyricTitle(lyric, lyricInfo);
  const candidateArtist: string = lyricArtist(lyric);
  let metadataPairMatched: boolean = false;
  if (trackTitle.length > 0 && trackArtist.length > 0) {
    if (candidateTitle.length > 0 && candidateTitle === trackTitle &&
        candidateArtist.length > 0 && candidateArtist === trackArtist) {
      metadataPairMatched = true;
    }
    const lyricVariants: SongNameVariant[] = lyricInfo.variants;
    for (let i: number = 0; i < lyricVariants.length; i++) {
      if (normalizeText(lyricVariants[i].title) === trackTitle &&
          normalizeText(lyricVariants[i].artist) === trackArtist) {
        metadataPairMatched = true;
      }
    }
  }
  if (trackTitle.length > 0 && candidateTitle.length > 0 && trackTitle === candidateTitle) {
    if (trackArtist.length > 0 && candidateArtist.length > 0 && trackArtist === candidateArtist) {
      best = chooseBest(best, {
        score: 98,
        strategy: '音频元数据辅助匹配',
        evidence: '音频标签中的标题与歌手均和歌词侧可解析信息对应'
      });
    } else if (metadataPairMatched) {
      best = chooseBest(best, {
        score: 98,
        strategy: '音频元数据辅助匹配',
        evidence: '音频标签的标题与歌手和歌词文件名拆分结果对应'
      });
    } else {
      best = chooseBest(best, {
        score: 86,
        strategy: '音频元数据辅助匹配',
        evidence: '音频标签标题与歌词文件信息相同；歌手信息不足以完成交叉验证'
      });
    }
  } else if (metadataPairMatched) {
    best = chooseBest(best, {
      score: 98,
      strategy: '音频元数据辅助匹配',
      evidence: '音频标签的标题与歌手和歌词文件名拆分结果对应'
    });
  }

  const splitMatch = hasMatchingVariant(audioInfo, lyricInfo);
  if (splitMatch.matched) {
    best = chooseBest(best, {
      score: splitMatch.ambiguous ? 74 : 89,
      strategy: '歌曲名与歌手名拆分匹配',
      evidence: '拆分得到相同的歌曲名与歌手名：' + splitMatch.title + ' / ' + splitMatch.artist
    });
  }

  if (best === null || best.score < 55) return null;

  const versionDifference: string = versionTagDifference(audioInfo.versionTags, lyricInfo.versionTags);
  let score: number = best.score;
  if (versionDifference.length > 0) {
    warnings.push(versionDifference);
    // Preserve a useful candidate for manual review, but lower confidence.
    score = Math.min(score, 64);
  }
  if (splitMatch.matched && splitMatch.ambiguous) {
    warnings.push('文件名分隔符存在多种解释，歌曲名与歌手顺序可能有歧义');
  }
  if (best.strategy === '版本与附加标记分析') {
    warnings.push('版本词仅用于提示差异，没有被当作无关文本直接删除');
  }

  evidence.push(best.evidence);
  if (audio.title !== undefined && audio.title.trim().length > 0) {
    evidence.push('可用音频标题字段：' + audio.title);
  }
  if (audio.artist !== undefined && audio.artist.trim().length > 0) {
    evidence.push('可用音频歌手字段：' + audio.artist);
  }

  const key: string = audio.id + '::' + lyric.id;
  return {
    key,
    audioId: audio.id,
    audioName: audio.name,
    audioUri: audio.uri,
    lyricId: lyric.id,
    lyricName: lyric.name,
    lyricUri: lyric.uri,
    confidence: score,
    strength: score >= 85 && warnings.length === 0 ? 'high' : 'review',
    strategy: best.strategy,
    evidence,
    warnings,
    audioTitle: audio.title === undefined ? audioInfo.title : audio.title,
    audioArtist: audio.artist === undefined ? '' : audio.artist,
    lyricTitle: lyricTitle(lyric, lyricInfo),
    lyricArtist: lyricArtist(lyric),
    state: 'pending'
  };
}

// 将歌曲标题、元数据标题和可能的「歌曲 - 歌手」拆分标题索引一次。
function matchKeys(name: SongNameAnalysis, metadataTitle: string): string[] {
  const keys: string[] = [];
  const rawKeys: string[] = [name.normalizedName, name.title, metadataTitle];
  for (let i: number = 0; i < name.variants.length; i++) {
    rawKeys.push(normalizeText(name.variants[i].title));
  }
  for (let i: number = 0; i < rawKeys.length; i++) {
    const key: string = rawKeys[i];
    if (key.length > 0 && keys.indexOf(key) < 0) keys.push(key);
  }
  return keys;
}

function appendIndex(index: Map<string, number[]>, key: string, position: number): void {
  const entry: number[] | undefined = index.get(key);
  if (entry === undefined) index.set(key, [position]);
  else entry.push(position);
}

export class MatchEngine {
  static lastWarning: string = '';

  static match(
    audioFiles: AudioMatchInput[],
    lyricFiles: LyricMatchInput[],
    maxComparisons: number = 200000
  ): MatchCandidate[] {
    const candidates: MatchCandidate[] = [];
    MatchEngine.lastWarning = '';

    // 预分析每个文件一次；旧实现为每次两两比较重新解析文件名。
    const lyricInfo: SongNameAnalysis[] = lyricFiles.map((item: LyricMatchInput) => analyzeSongName(item.name));
    const audioInfo: SongNameAnalysis[] = audioFiles.map((item: AudioMatchInput) => analyzeSongName(item.name));
    const index: Map<string, number[]> = new Map<string, number[]>();
    for (let j: number = 0; j < lyricFiles.length; j++) {
      const keys: string[] = matchKeys(lyricInfo[j], lyricTitle(lyricFiles[j], lyricInfo[j]));
      for (let k: number = 0; k < keys.length; k++) appendIndex(index, keys[k], j);
    }

    let comparisons: number = 0;
    let capped: boolean = false;
    for (let i: number = 0; i < audioFiles.length; i++) {
      const keys: string[] = matchKeys(audioInfo[i], metadataTitle(audioFiles[i]));
      const possible: Set<number> = new Set<number>();
      for (let k: number = 0; k < keys.length; k++) {
        const indices: number[] | undefined = index.get(keys[k]);
        if (indices === undefined) continue;
        for (let x: number = 0; x < indices.length; x++) possible.add(indices[x]);
      }
      const ordered: number[] = Array.from(possible).sort((a: number, b: number) => a - b);
      for (let k: number = 0; k < ordered.length; k++) {
        if (comparisons >= maxComparisons) {
          capped = true;
          break;
        }
        const j: number = ordered[k];
        comparisons++;
        const candidate: MatchCandidate | null = scorePair(audioFiles[i], lyricFiles[j], audioInfo[i], lyricInfo[j]);
        if (candidate !== null) candidates.push(candidate);
      }
      if (capped) break;
    }
    if (capped) {
      MatchEngine.lastWarning = '已达到 ' + maxComparisons + ' 次候选比较上限；建议缩小目录，分批检查。';
    }
    candidates.sort((left: MatchCandidate, right: MatchCandidate) => right.confidence - left.confidence);
    return candidates;
  }
}
