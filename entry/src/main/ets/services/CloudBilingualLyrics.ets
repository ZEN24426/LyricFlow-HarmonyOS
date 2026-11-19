/** Conservative combination of two timed LRC documents. */
export interface BilingualLyricsResult {
  text: string;
  warning: string;
  error: string;
}

interface TimedLine {
  timeMs: number;
  tag: string;
  body: string;
  order: number;
  translated: boolean;
}

interface ParsedLrc {
  offset: number;
  hasOffset: boolean;
  headers: string[];
  headerValues: Map<string, string>;
  lines: TimedLine[];
  enhanced: boolean;
}

const MAX_INPUT: number = 256 * 1024;
const MAX_OUTPUT: number = 1024 * 1024;
const MAX_EVENTS: number = 10000;
const MAX_TIME: number = 999 * 60000 + 59999;

function parseTime(tag: string): number {
  const match: RegExpMatchArray | null = tag.match(/^\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]$/);
  if (match === null || Number(match[2]) >= 60) throw new Error('歌词时间格式不受支持');
  const fraction: string = (match[3] || '').padEnd(3, '0');
  const value: number = Number(match[1]) * 60000 + Number(match[2]) * 1000 + Number(fraction || '0');
  if (!Number.isSafeInteger(value) || value > MAX_TIME) throw new Error('歌词时间超出范围');
  return value;
}

function formatTime(value: number): string {
  if (!Number.isSafeInteger(value) || value < 0 || value > MAX_TIME) throw new Error('偏移换算后的时间超出范围');
  const minutes: number = Math.floor(value / 60000);
  const seconds: number = Math.floor((value % 60000) / 1000);
  const fraction: number = value % 1000;
  return '[' + minutes.toString().padStart(2, '0') + ':' + seconds.toString().padStart(2, '0') +
    '.' + fraction.toString().padStart(3, '0') + ']';
}

function parseLrc(source: string, translated: boolean): ParsedLrc {
  if (source.trim().length === 0) throw new Error('原文或译文为空');
  if (source.length > MAX_INPUT) throw new Error('歌词过长');
  const result: ParsedLrc = { offset: 0, hasOffset: false, headers: [], headerValues: new Map<string, string>(),
    lines: [], enhanced: false };
  const rows: string[] = source.replace(/^\uFEFF/, '').split(/\r\n|\r|\n/);
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i];
    if (row.trim().length === 0) continue;
    const header: RegExpMatchArray | null = row.match(/^\s*\[([a-zA-Z][a-zA-Z0-9_-]*):([^\]]*)\]\s*$/);
    if (header !== null) {
      const key: string = header[1].toLowerCase();
      const value: string = header[2].trim();
      if (key === 'offset') {
        if (result.hasOffset || !/^[+-]?\d+$/.test(value)) throw new Error('歌词 offset 无效或重复');
        result.offset = Number(value);
        if (!Number.isSafeInteger(result.offset) || Math.abs(result.offset) > MAX_TIME) throw new Error('歌词 offset 超出范围');
        result.hasOffset = true;
        result.headers.push(row);
      } else {
        const previous: string | undefined = result.headerValues.get(key);
        if (previous !== undefined && previous !== value) throw new Error('歌词元数据存在冲突');
        result.headerValues.set(key, value);
        result.headers.push(row);
      }
      continue;
    }
    const timed: RegExpMatchArray | null = row.match(/^((?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\])+)(.*)$/);
    if (timed === null) throw new Error('存在无时间戳或无法识别的歌词行');
    const tags: RegExpMatchArray | null = timed[1].match(/\[\d{1,3}:\d{2}(?:\.\d{1,3})?\]/g);
    if (tags === null) throw new Error('歌词时间格式不受支持');
    if (/\[\d{1,3}:\d{2}/.test(timed[2])) throw new Error('歌词正文含有不确定的时间标记');
    // A time-like angle marker need not be valid enhanced LRC. Treat uncertain
    // variants conservatively too: changing only its line timestamp while
    // leaving a possible word timestamp untouched could desynchronize lyrics.
    if (/<\s*[+-]?\d+\s*:/.test(timed[2])) result.enhanced = true;
    for (let j: number = 0; j < tags.length; j++) {
      if (result.lines.length >= MAX_EVENTS) throw new Error('歌词时间点过多');
      result.lines.push({ timeMs: parseTime(tags[j]), tag: tags[j], body: timed[2],
        order: result.lines.length, translated: translated });
    }
  }
  if (result.lines.length === 0) throw new Error('缺少带时间戳的歌词');
  return result;
}

export function combineCloudLyrics(original: string, translation: string): BilingualLyricsResult {
  try {
    const main: ParsedLrc = parseLrc(original, false);
    const translated: ParsedLrc = parseLrc(translation, true);
    for (const entry of translated.headerValues.entries()) {
      const existing: string | undefined = main.headerValues.get(entry[0]);
      if (existing !== undefined && existing !== entry[1]) throw new Error('原文与译文的元数据冲突');
    }
    const delta: number = main.offset - translated.offset;
    if (delta !== 0 && translated.enhanced) throw new Error('译文含逐字时间，不能安全换算不同 offset');
    const all: TimedLine[] = main.lines.slice();
    for (let i: number = 0; i < translated.lines.length; i++) {
      const line: TimedLine = translated.lines[i];
      const shifted: number = line.timeMs + delta;
      all.push({ timeMs: shifted, tag: delta === 0 ? line.tag : formatTime(shifted), body: line.body,
        order: line.order, translated: true });
    }
    if (all.length > MAX_EVENTS) throw new Error('歌词时间点过多');
    all.sort((a: TimedLine, b: TimedLine): number => a.timeMs - b.timeMs ||
      (a.translated === b.translated ? a.order - b.order : (a.translated ? 1 : -1)));
    const headers: string[] = main.headers.slice();
    for (let i: number = 0; i < translated.headers.length; i++) {
      if (!/^\s*\[offset:/i.test(translated.headers[i])) headers.push(translated.headers[i]);
    }
    const output: string[] = headers;
    let outputLength: number = 0;
    for (let i: number = 0; i < headers.length; i++) outputLength += headers[i].length + 1;
    if (outputLength > MAX_OUTPUT) throw new Error('合并后的歌词过长');
    let unmatched: number = 0;
    for (let i: number = 0; i < all.length;) {
      let end: number = i + 1;
      while (end < all.length && all[end].timeMs === all[i].timeMs) end++;
      let originals: number = 0;
      for (let j: number = i; j < end; j++) if (!all[j].translated) originals++;
      const translations: number = end - i - originals;
      if (originals > 0 && translations > 0 && (originals > 1 || translations > 1)) {
        throw new Error('同一时间有多行歌词，无法确定原文和译文的对应关系');
      }
      if (originals === 0 || translations === 0) unmatched += end - i;
      for (let j: number = i; j < end; j++) {
        outputLength += all[j].tag.length + all[j].body.length + 1;
        if (outputLength > MAX_OUTPUT) throw new Error('合并后的歌词过长');
        output.push(all[j].tag + all[j].body);
      }
      i = end;
    }
    const text: string = output.join('\n');
    if (text.length > MAX_OUTPUT) throw new Error('合并后的歌词过长');
    let warning: string = '同一时间先显示原文、再显示译文；不同播放器的同时间多行显示可能不同。空白排版和元数据顺序会整理。';
    if (delta !== 0) warning += ' 已按各自 offset 换算译文时间。';
    if (unmatched > 0) warning += ' 有 ' + unmatched.toString() + ' 行没有同时间配对，已按各自时间保留。';
    return { text: text, warning: warning, error: '' };
  } catch (error) {
    return { text: '', warning: '', error: '无法安全合并：' +
      (error instanceof Error ? error.message : '歌词格式不受支持') + '。仍可单独使用原文或译文。' };
  }
}
