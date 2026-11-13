export interface SongNameVariant {
  title: string;
  artist: string;
  versionTags: string[];
  pattern: string;
  confidence: number;
}

export interface SongNameAnalysis {
  rawName: string;
  normalizedName: string;
  title: string;
  artist: string;
  versionTags: string[];
  variants: SongNameVariant[];
}

interface VersionPattern {
  tag: string;
  pattern: RegExp;
}

const VERSION_PATTERNS: VersionPattern[] = [
  { tag: 'live', pattern: /\b(live|concert|live at)\b/i },
  { tag: 'remix', pattern: /\b(remix|re.?mix|extended mix|club mix|dance mix)\b/i },
  { tag: 'acoustic', pattern: /\b(acoustic|unplugged)\b/i },
  { tag: 'instrumental', pattern: /\b(instrumental|karaoke|inst\.?|伴奏|纯音乐)\b/i },
  { tag: 'cover', pattern: /\b(cover|翻唱)\b/i },
  { tag: 'demo', pattern: /\b(demo|试听版)\b/i },
  { tag: 'radio-edit', pattern: /\b(radio edit|single edit)\b/i },
  { tag: 'remastered', pattern: /\b(remaster(ed)?|anniversary edition)\b/i },
  { tag: 'sped-up', pattern: /\b(sped up|speed up|加速版)\b/i },
  { tag: 'slowed', pattern: /\b(slowed|slowed down|慢速版)\b/i },
  { tag: 'piano', pattern: /\b(piano version|piano)\b/i },
  { tag: 'orchestral', pattern: /\b(orchestral|symphonic)\b/i }
];

function fileBaseName(value: string): string {
  const chunks: string[] = value.replace(/\\/g, '/').split('/');
  const leaf: string = chunks.length > 0 ? chunks[chunks.length - 1] : value;
  return leaf.replace(/\.(mp3|flac|wav|m4a|aac|ogg|opus|aiff|aif|wma|lrc|txt|srt|vtt|sbv|ass|ssa|ttml)$/i, '').trim();
}

export function normalizeText(value: string): string {
  return value
    .toLowerCase()
    .replace(/[\u3000\s]+/g, ' ')
    .replace(/[._–—|()[\]{}（）【】「」『』,，。!！?？:：;；]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function normalizeSongName(value: string): string {
  return normalizeText(fileBaseName(value));
}

export function extractVersionTags(value: string): string[] {
  const source: string = fileBaseName(value).toLowerCase();
  const tags: string[] = [];
  for (let i: number = 0; i < VERSION_PATTERNS.length; i++) {
    const entry = VERSION_PATTERNS[i];
    if (entry.pattern.test(source)) {
      tags.push(entry.tag);
    }
  }
  if (source.indexOf('现场') >= 0 || source.indexOf('演唱会') >= 0) tags.push('live');
  if (source.indexOf('混音') >= 0 || source.indexOf('重混') >= 0) tags.push('remix');
  if (source.indexOf('不插电') >= 0) tags.push('acoustic');
  if (source.indexOf('伴奏') >= 0 || source.indexOf('纯音乐') >= 0 || source.indexOf('卡拉ok') >= 0) tags.push('instrumental');
  if (source.indexOf('翻唱') >= 0 || source.indexOf('翻奏') >= 0) tags.push('cover');
  if (source.indexOf('试听版') >= 0 || source.indexOf('小样') >= 0) tags.push('demo');
  if (source.indexOf('电台剪辑') >= 0 || source.indexOf('单曲剪辑') >= 0) tags.push('radio-edit');
  if (source.indexOf('重制') >= 0 || source.indexOf('重灌') >= 0) tags.push('remastered');
  if (source.indexOf('加速版') >= 0 || source.indexOf('加速') >= 0) tags.push('sped-up');
  if (source.indexOf('慢速版') >= 0 || source.indexOf('降速') >= 0) tags.push('slowed');
  if (source.indexOf('钢琴版') >= 0) tags.push('piano');
  if (source.indexOf('管弦乐') >= 0 || source.indexOf('交响版') >= 0) tags.push('orchestral');
  const unique: string[] = [];
  for (let i: number = 0; i < tags.length; i++) {
    if (unique.indexOf(tags[i]) < 0) unique.push(tags[i]);
  }
  return unique;
}

function withoutVersionText(value: string): string {
  let result: string = fileBaseName(value);
  for (let i: number = 0; i < VERSION_PATTERNS.length; i++) {
    result = result.replace(VERSION_PATTERNS[i].pattern, ' ');
  }
  result = result.replace(/现场|演唱会|混音|重混|不插电|伴奏|纯音乐|卡拉OK|翻唱|翻奏|试听版|小样|电台剪辑|单曲剪辑|重制|重灌|加速版|加速|慢速版|降速|钢琴版|管弦乐|交响版/g, ' ');
  return normalizeSongName(result);
}

function addVariant(
  variants: SongNameVariant[],
  title: string,
  artist: string,
  pattern: string,
  confidence: number
): void {
  const cleanTitle: string = title.trim();
  const cleanArtist: string = artist.trim();
  if (cleanTitle.length === 0 || cleanArtist.length === 0) return;
  const titleTags: string[] = extractVersionTags(cleanTitle);
  const artistTags: string[] = extractVersionTags(cleanArtist);
  const normalizedTitle: string = normalizeText(cleanTitle);
  const normalizedArtist: string = normalizeText(cleanArtist);
  for (let i: number = 0; i < variants.length; i++) {
    if (normalizeText(variants[i].title) === normalizedTitle &&
        normalizeText(variants[i].artist) === normalizedArtist) return;
  }
  variants.push({
    title: cleanTitle,
    artist: cleanArtist,
    versionTags: titleTags.concat(artistTags),
    pattern,
    confidence
  });
}

export function analyzeSongName(value: string): SongNameAnalysis {
  const rawName: string = fileBaseName(value);
  const versionTags: string[] = extractVersionTags(rawName);
  const variants: SongNameVariant[] = [];

  // Parenthetical artist format: "Song Title (Artist)".
  const parenthetical: RegExpMatchArray | null = rawName.match(/^(.+?)[（(]\s*([^()（）]+)\s*[）)]$/);
  if (parenthetical !== null && parenthetical.length >= 3) {
    const inner: string = parenthetical[2].trim();
    if (extractVersionTags(inner).length === 0) {
      addVariant(variants, parenthetical[1], inner, 'title (artist)', 0.88);
    }
  }

  // Common separators appear in both "title - artist" and "artist - title";
  // record both readings rather than silently guessing the order.
  const separator: RegExp = /\s+-\s+|\s*[–—|_]\s*|\s+-\s*/;
  const delimiterMatch: RegExpMatchArray | null = rawName.match(separator);
  if (delimiterMatch !== null && delimiterMatch.index !== undefined) {
    const pos: number = delimiterMatch.index;
    const delimiter: string = delimiterMatch[0];
    const left: string = rawName.substring(0, pos).trim();
    const right: string = rawName.substring(pos + delimiter.length).trim();
    if (left.length > 0 && right.length > 0) {
      addVariant(variants, left, right, 'title - artist (ambiguous order)', 0.68);
      addVariant(variants, right, left, 'artist - title (ambiguous order)', 0.68);
    }
  }

  return {
    rawName,
    normalizedName: normalizeSongName(rawName),
    title: withoutVersionText(rawName),
    artist: '',
    versionTags,
    variants
  };
}

export function sameVersionTags(left: string[], right: string[]): boolean {
  if (left.length !== right.length) return false;
  for (let i: number = 0; i < left.length; i++) {
    if (right.indexOf(left[i]) < 0) return false;
  }
  return true;
}

export function versionTagDifference(left: string[], right: string[]): string {
  const onlyLeft: string[] = [];
  const onlyRight: string[] = [];
  for (let i: number = 0; i < left.length; i++) {
    if (right.indexOf(left[i]) < 0) onlyLeft.push(left[i]);
  }
  for (let i: number = 0; i < right.length; i++) {
    if (left.indexOf(right[i]) < 0) onlyRight.push(right[i]);
  }
  if (onlyLeft.length === 0 && onlyRight.length === 0) return '';
  if (onlyLeft.length > 0 && onlyRight.length > 0) {
    return '音频文件版本标记：' + onlyLeft.join(', ') + '；歌词文件版本标记：' + onlyRight.join(', ');
  }
  if (onlyLeft.length > 0) return '音频文件含版本标记：' + onlyLeft.join(', ') + '；歌词文件未标出该版本';
  return '歌词文件含版本标记：' + onlyRight.join(', ') + '；音频文件未标出该版本';
}
