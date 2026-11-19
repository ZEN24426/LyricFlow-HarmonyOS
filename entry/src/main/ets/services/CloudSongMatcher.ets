/**
 * Pure, local ranking for explicitly requested cloud song searches.
 * Scoring policy inspired by 163MusicLyrics LocalSongMatcher (jitwxs):
 * https://github.com/jitwxs/163MusicLyrics/blob/master/cross-platform/MusicLyricApp/Core/Service/LocalMusic/LocalSongMatcher.cs
 * Independently implemented for LyricFlow, with conservative artist/version checks.
 * A recommendation never authorizes downloading lyrics or modifying an audio file.
 */

export interface LocalSongIdentity {
  title: string;
  artist: string;
  album: string;
  durationMs: number;
}

export interface CloudSong {
  source: string;
  id: string;
  title: string;
  artists: string[];
  album: string;
  durationMs: number;
}

export interface CloudSongCandidate {
  song: CloudSong;
  score: number;
  reliable: boolean;
  evidence: string[];
  warnings: string[];
}

export interface CloudMatchResult {
  candidates: CloudSongCandidate[];
  recommendedId: string;
  automatic: boolean;
}

interface ArtistComparison {
  exact: boolean;
  overlap: boolean;
  ambiguous: boolean;
  semanticConflict: boolean;
}

interface VersionMarker {
  name: string;
  pattern: RegExp;
}

const VERSION_MARKERS: VersionMarker[] = [
  { name: '现场', pattern: /(^|[^a-z0-9])(live|concert)([^a-z0-9]|$)|现场|演唱会/i },
  { name: '混音', pattern: /(^|[^a-z0-9])(remix|re-mix|extended mix|club mix)([^a-z0-9]|$)|混音|重混/i },
  { name: '伴奏', pattern: /(^|[^a-z0-9])(instrumental|karaoke|inst\.?|off[ -]vocal)([^a-z0-9]|$)|伴奏|卡拉\s*ok|纯音乐/i },
  { name: '不插电', pattern: /(^|[^a-z0-9])(acoustic|unplugged)([^a-z0-9]|$)|不插电/i },
  { name: '翻唱', pattern: /(^|[^a-z0-9])cover([^a-z0-9]|$)|翻唱|翻奏/i },
  { name: '小样', pattern: /(^|[^a-z0-9])demo([^a-z0-9]|$)|小样|试听版/i },
  { name: '剪辑版', pattern: /(^|[^a-z0-9])(radio edit|single edit)([^a-z0-9]|$)|电台剪辑|单曲剪辑/i },
  { name: '重制版', pattern: /(^|[^a-z0-9])(remaster|remastered)([^a-z0-9]|$)|重制版|重灌版/i },
  { name: '加速版', pattern: /(^|[^a-z0-9])(sped up|speed up)([^a-z0-9]|$)|加速版/i },
  { name: '慢速版', pattern: /(^|[^a-z0-9])(slowed|slowed down)([^a-z0-9]|$)|慢速版|降速版/i },
  { name: '钢琴版', pattern: /(^|[^a-z0-9])piano version([^a-z0-9]|$)|钢琴版/i }
];

// Combining marks carry essential vowel and other distinctions in many scripts.
function normalizeIdentity(value: string): string {
  const normalized: string = value.normalize('NFKC');
  if (!/[\p{L}\p{N}]/u.test(normalized)) return '';
  return normalized.replace(/[^\p{L}\p{N}\p{M}]/gu, '').toUpperCase();
}

// Some symbols distinguish titles or artist names (A+B vs AB, AC/DC vs ACDC).
// Keep them for the recommendation veto while leaving the ranking weights intact.
function normalizeSemanticIdentity(value: string): string {
  return value.normalize('NFKC').replace(/[^\p{L}\p{N}\p{M}+\/#&]/gu, '').toUpperCase();
}

function normalizedNames(values: string[]): string[] {
  const names: string[] = [];
  for (let i: number = 0; i < values.length; i++) {
    const name: string = normalizeIdentity(values[i]);
    if (name.length > 0 && names.indexOf(name) < 0) names.push(name);
  }
  return names;
}

function semanticNames(values: string[]): string[] {
  const names: string[] = [];
  for (let i: number = 0; i < values.length; i++) {
    if (normalizeIdentity(values[i]).length === 0) continue;
    const name: string = normalizeSemanticIdentity(values[i]);
    if (names.indexOf(name) < 0) names.push(name);
  }
  return names;
}

function sameNames(left: string[], right: string[]): boolean {
  if (left.length === 0 || left.length !== right.length) return false;
  for (let i: number = 0; i < left.length; i++) {
    if (right.indexOf(left[i]) < 0) return false;
  }
  return true;
}

function namesOverlap(left: string[], right: string[]): boolean {
  for (let i: number = 0; i < left.length; i++) {
    if (right.indexOf(left[i]) >= 0) return true;
  }
  return false;
}

function compareArtists(localArtist: string, cloudArtists: string[]): ArtistComparison {
  const whole: string = normalizeIdentity(localArtist);
  // Provider arrays are authoritative boundaries. Do not split AC/DC or band names.
  const cloud: string[] = normalizedNames(cloudArtists);
  if (whole.length === 0 || cloud.length === 0) {
    return { exact: false, overlap: false, ambiguous: false, semanticConflict: false };
  }
  if (cloud.length === 1 && cloud[0] === whole) {
    return {
      exact: true, overlap: true, ambiguous: false,
      semanticConflict: !sameNames(semanticNames([localArtist]), semanticNames(cloudArtists))
    };
  }
  const localText: string = localArtist.normalize('NFKC');
  // Whitespace around slash is required: AC/DC is an indivisible artist name.
  const explicitParts: string[] = localText.split(/\s+\/\s+|[、;；]|\s+(?:feat\.?|ft\.?)\s+/i);
  const explicit: string[] = normalizedNames(explicitParts);
  if (sameNames(explicit, cloud)) {
    return {
      exact: true, overlap: true, ambiguous: false,
      semanticConflict: !sameNames(semanticNames(explicitParts), semanticNames(cloudArtists))
    };
  }
  // Commas and ampersands can be part of one band's name. They only aid review.
  const ambiguous: string[] = normalizedNames(localText.split(/\s+\/\s+|[、;；,&，/]|\s+(?:feat\.?|ft\.?)\s+/i));
  return {
    exact: false,
    overlap: namesOverlap(explicit, cloud) || namesOverlap(ambiguous, cloud),
    ambiguous: ambiguous.length > explicit.length,
    semanticConflict: false
  };
}

function versionNames(title: string): string[] {
  const names: string[] = [];
  const source: string = title.normalize('NFKC');
  for (let i: number = 0; i < VERSION_MARKERS.length; i++) {
    if (VERSION_MARKERS[i].pattern.test(source)) names.push(VERSION_MARKERS[i].name);
  }
  return names;
}

function versionsConflict(local: string[], cloud: string[]): boolean {
  if (local.length !== cloud.length) return true;
  for (let i: number = 0; i < local.length; i++) {
    if (cloud.indexOf(local[i]) < 0) return true;
  }
  return false;
}

function mergeVersions(title: string[], album: string[]): string[] {
  const versions: string[] = title.slice();
  for (let i: number = 0; i < album.length; i++) {
    if (versions.indexOf(album[i]) < 0) versions.push(album[i]);
  }
  return versions;
}

function describeVersions(title: string[], album: string[]): string {
  const evidence: string[] = [];
  if (title.length > 0) evidence.push('标题含' + title.join('、'));
  if (album.length > 0) evidence.push('专辑含' + album.join('、'));
  return evidence.length > 0 ? evidence.join('，') : '未标明';
}

// Kept separate from scoring so the strict 10-point boundary stays explicit.
function hasClearLead(firstScore: number, secondScore: number): boolean {
  return Number.isFinite(firstScore) && Number.isFinite(secondScore) && firstScore - secondScore >= 10;
}

function scoreSong(local: LocalSongIdentity, song: CloudSong): CloudSongCandidate {
  const evidence: string[] = [];
  const warnings: string[] = [];
  let score: number = 0;
  const localTitle: string = normalizeIdentity(local.title);
  const cloudTitle: string = normalizeIdentity(song.title);
  const exactTitle: boolean = localTitle.length > 0 && localTitle === cloudTitle;
  const titleSymbolConflict: boolean = exactTitle &&
    normalizeSemanticIdentity(local.title) !== normalizeSemanticIdentity(song.title);
  if (exactTitle) {
    score += 55;
    evidence.push(titleSymbolConflict ? '忽略符号后标题相同（+55）' : '标题标准化后相同（+55）');
  } else if (localTitle.length > 0 && cloudTitle.length > 0 &&
    (cloudTitle.indexOf(localTitle) >= 0 || localTitle.indexOf(cloudTitle) >= 0)) {
    score += 20;
    evidence.push('标题仅部分相同（+20，仅供人工确认）');
  } else {
    warnings.push(localTitle.length === 0 || cloudTitle.length === 0 ? '标题信息缺失' : '标题不一致');
  }
  if (titleSymbolConflict) warnings.push('标题中的 +、/、& 或 # 存在差异，需人工确认');

  const artists: ArtistComparison = compareArtists(local.artist, song.artists);
  if (artists.exact) {
    score += 30;
    evidence.push(artists.semanticConflict ? '忽略符号后歌手集合相同（+30）' : '歌手集合完整对应（+30）');
  } else if (artists.overlap) {
    score += 10;
    evidence.push('歌手仅部分对应（+10，仅供人工确认）');
  } else {
    warnings.push(normalizeIdentity(local.artist).length === 0 || normalizedNames(song.artists).length === 0 ?
      '歌手信息缺失' : '歌手不一致');
  }
  if (artists.ambiguous) warnings.push('歌手分隔符可能属于艺名，需人工确认');
  if (artists.semanticConflict) warnings.push('歌手名中的 +、/、& 或 # 存在差异，需人工确认');

  const localAlbum: string = normalizeIdentity(local.album);
  const albumIdentityMatches: boolean = localAlbum.length > 0 && localAlbum === normalizeIdentity(song.album);
  const albumSymbolConflict: boolean = albumIdentityMatches &&
    normalizeSemanticIdentity(local.album) !== normalizeSemanticIdentity(song.album);
  const sameAlbum: boolean = albumIdentityMatches && !albumSymbolConflict;
  if (sameAlbum) {
    score += 5;
    evidence.push('专辑相同（+5）');
  }
  if (albumSymbolConflict) warnings.push('专辑名中的 +、/、& 或 # 存在差异，不能作为同专辑佐证');

  const invalidDuration: boolean = !Number.isFinite(local.durationMs) || local.durationMs < 0 ||
    !Number.isFinite(song.durationMs) || song.durationMs < 0;
  const bothDurations: boolean = !invalidDuration && local.durationMs > 0 && song.durationMs > 0;
  const delta: number = bothDurations ? Math.abs(local.durationMs - song.durationMs) : 0;
  const closeDuration: boolean = bothDurations && delta <= 2000;
  const conflictingDuration: boolean = bothDurations && delta > 5000;
  if (closeDuration) {
    score += 10;
    evidence.push('时长差不超过2秒（+10）');
  } else if (conflictingDuration) {
    warnings.push('时长差超过5秒，不自动推荐');
  } else if (invalidDuration) {
    warnings.push('时长字段无效，需人工确认');
  } else if (bothDurations) {
    evidence.push('时长差在2至5秒之间，需专辑信息佐证');
  }

  const localTitleVersions: string[] = versionNames(local.title);
  const localAlbumVersions: string[] = versionNames(local.album);
  const cloudTitleVersions: string[] = versionNames(song.title);
  const cloudAlbumVersions: string[] = versionNames(song.album);
  const localVersions: string[] = mergeVersions(localTitleVersions, localAlbumVersions);
  const cloudVersions: string[] = mergeVersions(cloudTitleVersions, cloudAlbumVersions);
  const conflictingVersion: boolean = versionsConflict(localVersions, cloudVersions);
  if (conflictingVersion) {
    warnings.push('版本标记不一致：本地' + describeVersions(localTitleVersions, localAlbumVersions) +
      '；云端' + describeVersions(cloudTitleVersions, cloudAlbumVersions));
  }

  return {
    song,
    score,
    reliable: exactTitle && !titleSymbolConflict && artists.exact && !artists.ambiguous &&
      !artists.semanticConflict && !invalidDuration &&
      !conflictingDuration && !conflictingVersion && (closeDuration || sameAlbum),
    evidence,
    warnings
  };
}

export class CloudSongMatcher {
  static buildKeyword(local: LocalSongIdentity): string {
    const parts: string[] = [];
    if (local.title.trim().length > 0) parts.push(local.title.trim());
    if (local.artist.trim().length > 0) parts.push(local.artist.trim());
    return parts.join(' ');
  }

  static rank(local: LocalSongIdentity, songs: CloudSong[], allowRecommendation: boolean = true): CloudMatchResult {
    const unique: Map<string, CloudSongCandidate> = new Map<string, CloudSongCandidate>();
    for (let i: number = 0; i < songs.length; i++) {
      const song: CloudSong = songs[i];
      if (song.source.trim().length === 0 || song.id.trim().length === 0) continue;
      const candidate: CloudSongCandidate = scoreSong(local, song);
      const key: string = JSON.stringify([song.source, song.id]);
      const previous: CloudSongCandidate | undefined = unique.get(key);
      if (previous === undefined || candidate.score > previous.score ||
        (candidate.score === previous.score && candidate.reliable && !previous.reliable)) {
        unique.set(key, candidate);
      }
    }
    const candidates: CloudSongCandidate[] = Array.from(unique.values());
    candidates.sort((left: CloudSongCandidate, right: CloudSongCandidate) => right.score - left.score);
    const automatic: boolean = allowRecommendation && candidates.length > 0 && candidates[0].reliable &&
      (candidates.length === 1 || hasClearLead(candidates[0].score, candidates[1].score));
    return { candidates, recommendedId: automatic ? candidates[0].song.id : '', automatic };
  }
}
