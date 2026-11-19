export type LyricFormat = 'lrc' | 'enhanced-lrc' | 'srt' | 'vtt' | 'sbv' | 'ass' | 'txt' | 'unknown';

export interface LyricSegment {
  startMs: number;
  text: string;
}

export interface LyricLine {
  startMs?: number;
  endMs?: number;
  text: string;
  segments?: LyricSegment[];
}

export interface LyricDocument {
  format: LyricFormat;
  metadata: Record<string, string>;
  lines: LyricLine[];
  warnings: string[];
  /** A parsed subtitle had malformed events that could otherwise be silently dropped. */
  conversionBlocked?: boolean;
}

export interface LrcExportResult {
  text: string;
  warnings: string[];
}

function decodeEntities(value: string): string {
  return value
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

export function parseTimestamp(value: string): number | undefined {
  let source: string = value.trim().replace(',', '.');
  if (source.length === 0) return undefined;

  if (/^\d+(?:\.\d+)?ms$/i.test(source)) {
    return Number(source.replace(/ms$/i, ''));
  }
  if (/^\d+(?:\.\d+)?s$/i.test(source)) {
    return Math.round(Number(source.replace(/s$/i, '')) * 1000);
  }
  if (!/^\d+(?::\d+){1,2}(?:\.\d+)?$/.test(source)) return undefined;

  const parts: string[] = source.split(':');
  const last: string = parts[parts.length - 1];
  const secParts: string[] = last.split('.');
  const seconds: number = Number(secParts[0]);
  const fractionText: string = secParts.length > 1 ? secParts[1] : '0';
  const fraction: number = Number(('0.' + fractionText)) * 1000;
  let wholeSeconds: number = seconds;
  if (parts.length === 2) {
    wholeSeconds += Number(parts[0]) * 60;
  } else if (parts.length === 3) {
    wholeSeconds += Number(parts[1]) * 60 + Number(parts[0]) * 3600;
  }
  return Math.round(wholeSeconds * 1000 + fraction);
}

function makeLineText(lines: string[], startIndex: number): string {
  const parts: string[] = [];
  for (let i: number = startIndex; i < lines.length; i++) {
    const value: string = lines[i].trim();
    if (value.length === 0) break;
    if (subtitleCue(value) !== undefined) break;
    parts.push(value);
  }
  return parts.join(' ');
}

interface SubtitleCue {
  startMs: number;
  endMs: number;
}

/** A bare arrow in lyric text is not a subtitle cue. */
function subtitleCue(row: string): SubtitleCue | undefined {
  const match: RegExpMatchArray | null = row.match(/^\s*((?:\d+:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?)\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}(?:[.,]\d{1,3})?)(?:\s+[^\r\n]*)?\s*$/);
  if (match === null || row.indexOf('-->') !== row.lastIndexOf('-->')) return undefined;
  for (let i: number = 1; i <= 2; i++) {
    const parts: string[] = match[i].replace(',', '.').split(':');
    const seconds: number = Number(parts[parts.length - 1].split('.')[0]);
    if (seconds >= 60 || (parts.length === 3 && Number(parts[1]) >= 60)) return undefined;
  }
  const start: number | undefined = parseTimestamp(match[1]);
  const end: number | undefined = parseTimestamp(match[2]);
  if (start === undefined || end === undefined || !Number.isSafeInteger(start) ||
      !Number.isSafeInteger(end) || end < start) return undefined;
  return { startMs: start, endMs: end };
}

function looksLikeSubtitleCue(row: string): boolean {
  return (/^\s*\d+:\d/.test(row) && /(?:-->|->|→)/.test(row)) ||
    (/-->/.test(row) && /-->\s*\d+:\d/.test(row));
}

function malformedCueAt(rows: string[], index: number): boolean {
  const row: string = rows[index].trim();
  if (looksLikeSubtitleCue(row)) return true;
  const prior: string = index > 0 ? rows[index - 1].trim() : '';
  const beforePrior: string = index > 1 ? rows[index - 2].trim() : '';
  const atBlockStart: boolean = index === 0 || prior.length === 0;
  const afterIdentifier: boolean = prior.length > 0 && subtitleCue(prior) === undefined &&
    (index === 1 || beforePrior.length === 0);
  return (atBlockStart || afterIdentifier) &&
    (row.indexOf('-->') >= 0 || /^\d+:\d/.test(row));
}

function firstSubtitleCue(source: string): number {
  const rows: string[] = source.split('\n');
  let offset: number = 0;
  for (let i: number = 0; i < rows.length; i++) {
    if (subtitleCue(rows[i]) !== undefined || looksLikeSubtitleCue(rows[i])) return offset;
    offset += rows[i].length + 1;
  }
  return -1;
}

function firstSbvCue(source: string): number {
  const rows: string[] = source.split('\n');
  let offset: number = 0;
  for (let i: number = 0; i < rows.length; i++) {
    if (/^\s*((?:\d+:)?\d+:\d+\.\d+),((?:\d+:)?\d+:\d+\.\d+)\s*$/.test(rows[i])) return offset;
    offset += rows[i].length + 1;
  }
  return -1;
}

function parseEnhancedSegments(text: string): LyricSegment[] {
  const segments: LyricSegment[] = [];
  const pattern: RegExp = /<((?:\d{1,2}:)?\d{1,2}:\d{2}(?:[.:]\d{1,3})?)>/g;
  let cursor: number = 0;
  let currentStart: number | undefined = undefined;
  let match: RegExpExecArray | null = pattern.exec(text);

  while (match !== null) {
    // The text following one timestamp belongs to that timestamp, up to the next marker.
    const segmentText: string = text.substring(cursor, match.index);
    if (currentStart !== undefined && segmentText.length > 0) {
      segments.push({ startMs: currentStart, text: segmentText });
    }
    currentStart = parseTimestamp(match[1]);
    cursor = match.index + match[0].length;
    match = pattern.exec(text);
  }

  const finalText: string = text.substring(cursor);
  if (currentStart !== undefined && finalText.length > 0) {
    segments.push({ startMs: currentStart, text: finalText });
  }
  return segments;
}

function parseLrc(source: string): LyricDocument {
  const metadata: Record<string, string> = {};
  const lines: LyricLine[] = [];
  let hasEnhanced: boolean = false;
  const rows: string[] = source.split(/\r?\n/);
  const timePattern: RegExp = /\[(\d{1,3}:\d{2}(?:[.:]\d{1,3})?)\]/g;
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    if (row.length === 0) continue;
    const meta: RegExpMatchArray | null = row.match(/^\[(ti|ar|al|by|re|ve|offset):([^\]]*)\]$/i);
    if (meta !== null && meta.length >= 3) {
      metadata[meta[1].toLowerCase()] = meta[2].trim();
      continue;
    }
    const times: number[] = [];
    let hit: RegExpExecArray | null = timePattern.exec(row);
    while (hit !== null) {
      const milliseconds: number | undefined = parseTimestamp(hit[1]);
      if (milliseconds !== undefined) times.push(milliseconds);
      hit = timePattern.exec(row);
    }
    timePattern.lastIndex = 0;
    if (times.length === 0) {
      if (row.charAt(0) !== '[') lines.push({ text: row });
      continue;
    }
    const text: string = row.replace(timePattern, '').trim();
    timePattern.lastIndex = 0;
    const segments: LyricSegment[] = parseEnhancedSegments(text);
    if (segments.length > 0) hasEnhanced = true;
    for (let j: number = 0; j < times.length; j++) {
      const line: LyricLine = { startMs: times[j], text: text.replace(/<\d{1,2}:\d{2}(?:[.:]\d{1,3})?>/g, '').trim() };
      if (segments.length > 0) line.segments = segments;
      lines.push(line);
    }
  }
  lines.sort((a: LyricLine, b: LyricLine) =>
    (a.startMs === undefined ? Number.MAX_SAFE_INTEGER : a.startMs) -
    (b.startMs === undefined ? Number.MAX_SAFE_INTEGER : b.startMs));
  return {
    format: hasEnhanced ? 'enhanced-lrc' : 'lrc',
    metadata,
    lines,
    warnings: []
  };
}

function parseSubRipOrVtt(source: string, format: 'srt' | 'vtt'): LyricDocument {
  const rows: string[] = source.replace(/\r/g, '').split('\n');
  const lines: LyricLine[] = [];
  // Track every nonempty input row accounted for by a cue, its optional
  // identifier, or the VTT signature. Otherwise a separate LRC/plain block
  // can silently disappear when this document is converted.
  const consumed: boolean[] = rows.map((_row: string): boolean => false);
  let malformed: boolean = false;
  if (format === 'vtt' && rows.length > 0 && /^WEBVTT(?:[ \t].*)?$/.test(rows[0].trim())) consumed[0] = true;
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    const cue: SubtitleCue | undefined = subtitleCue(row);
    if (cue === undefined) {
      if (malformedCueAt(rows, i)) malformed = true;
      continue;
    }
    consumed[i] = true;
    // SRT uses numeric sequence numbers; WebVTT permits an arbitrary single
    // cue identifier. A standalone LRC line is never treated as an identifier.
    if (i > 0 && rows[i - 1].trim().length > 0 && (i === 1 || rows[i - 2].trim().length === 0)) {
      const identifier: string = rows[i - 1].trim();
      if ((format === 'vtt' || /^\d+$/.test(identifier)) &&
          !/^\[\s*[+-]?\d+[:.,]/.test(identifier) && identifier.indexOf('-->') < 0) consumed[i - 1] = true;
    }
    for (let j: number = i + 1; j < rows.length; j++) {
      if (rows[j].trim().length === 0 || subtitleCue(rows[j]) !== undefined) break;
      consumed[j] = true;
    }
    let text: string = makeLineText(rows, i + 1);
    // A time-like inline marker may carry word timing or be literal text;
    // the generic subtitle tag stripper cannot safely decide which.
    if (/<\s*[+-]?\d+\s*[:.,]/.test(text)) malformed = true;
    text = text.replace(/<[^>]+>/g, '').trim();
    if (text.length > 0) {
      const line: LyricLine = { startMs: cue.startMs, endMs: cue.endMs, text };
      lines.push(line);
    }
  }
  for (let i: number = 0; i < rows.length; i++) {
    if (rows[i].trim().length > 0 && !consumed[i]) malformed = true;
  }
  lines.sort((a: LyricLine, b: LyricLine) =>
    (a.startMs === undefined ? 0 : a.startMs) - (b.startMs === undefined ? 0 : b.startMs));
  return {
    format,
    metadata: {},
    lines,
    warnings: malformed ? ['字幕包含未识别内容或无效时间，已禁止转换以免丢失内容'] :
      ['转为 LRC 时字幕样式、位置及部分格式控制信息无法保留'],
    conversionBlocked: malformed
  };
}

function safeSubtitleTime(value: string): number | undefined {
  const normalized: string = value.trim().replace(',', '.');
  if (!/^\d+(?::\d+){1,2}(?:\.\d+)?$/.test(normalized)) return undefined;
  const parts: string[] = normalized.split(':');
  const seconds: number = Number(parts[parts.length - 1].split('.')[0]);
  if (seconds >= 60 || (parts.length === 3 && Number(parts[1]) >= 60)) return undefined;
  const result: number | undefined = parseTimestamp(normalized);
  return result !== undefined && Number.isSafeInteger(result) ? result : undefined;
}

function parseSbv(source: string): LyricDocument {
  const rows: string[] = source.replace(/\r/g, '').split('\n');
  const lines: LyricLine[] = [];
  const consumed: boolean[] = rows.map((_row: string): boolean => false);
  let malformed: boolean = false;
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    const timing: RegExpMatchArray | null = row.match(/^((?:\d+:)?\d+:\d+\.\d+),((?:\d+:)?\d+:\d+\.\d+)$/);
    if (timing === null || timing.length < 3) {
      // An isolated malformed cue is rejected below as an unconsumed row.
      // Do not mistake time-like words within a valid cue for another cue.
      continue;
    }
    const startMs: number | undefined = safeSubtitleTime(timing[1]);
    const endMs: number | undefined = safeSubtitleTime(timing[2]);
    if (startMs === undefined || endMs === undefined || endMs < startMs) {
      malformed = true;
      continue;
    }
    consumed[i] = true;
    const body: string[] = [];
    for (let j: number = i + 1; j < rows.length; j++) {
      const value: string = rows[j].trim();
      if (value.length === 0 || /^((?:\d+:)?\d+:\d+\.\d+),((?:\d+:)?\d+:\d+\.\d+)$/.test(value)) break;
      consumed[j] = true;
      body.push(value);
    }
    const text: string = body.join(' ');
    if (startMs !== undefined && text.length > 0) {
      const line: LyricLine = { startMs, text };
      if (endMs !== undefined) line.endMs = endMs;
      lines.push(line);
    }
  }
  for (let i: number = 0; i < rows.length; i++) {
    if (rows[i].trim().length > 0 && !consumed[i]) malformed = true;
  }
  return {
    format: 'sbv',
    metadata: {},
    lines,
    warnings: malformed ? ['SBV 包含未识别内容或无效时间，已禁止转换以免丢失内容'] :
      ['SBV 的结束时间将不会写入标准 LRC'],
    conversionBlocked: malformed
  };
}

function parseAss(source: string): LyricDocument {
  const rows: string[] = source.replace(/\r/g, '').split('\n');
  const lines: LyricLine[] = [];
  let inEvents: boolean = false;
  let startColumn: number = 1;
  let endColumn: number = 2;
  let textColumn: number = 9;
  let expectedColumns: number = 10;
  let malformed: boolean = false;
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    // Standalone LRC-timed rows mixed with ASS dialogue would otherwise be
    // ignored by the subtitle parser, losing text during conversion.
    if (/^\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]/.test(row)) malformed = true;
    if (row.startsWith('[') && row.endsWith(']')) {
      inEvents = row.toLowerCase() === '[events]';
      continue;
    }
    if (inEvents && /^format:/i.test(row)) {
      const columns: string[] = row.substring(row.indexOf(':') + 1).split(',').map((v: string) => v.trim().toLowerCase());
      const start: number = columns.indexOf('start');
      const end: number = columns.indexOf('end');
      const text: number = columns.indexOf('text');
      if (start >= 0 && end >= 0 && text >= 0) {
        startColumn = start;
        endColumn = end;
        textColumn = text;
        expectedColumns = columns.length;
      } else malformed = true;
      continue;
    }
    if (!/^dialogue:/i.test(row)) continue;
    const body: string = row.substring(row.indexOf(':') + 1).trim();
    const fragments: string[] = body.split(',');
    if (fragments.length < expectedColumns) { malformed = true; continue; }
    // ASS 的 Text 字段可能包含逗号；即使 Format 声明中 Text 不是最后一列，
    // 也能按前后固定字段数正确拼回文本，而不是悄悄跳过整条字幕。
    const suffixCount: number = expectedColumns - textColumn - 1;
    const textEnd: number = fragments.length - suffixCount;
    const fields: string[] = fragments.slice(0, textColumn);
    fields.push(fragments.slice(textColumn, textEnd).join(','));
    for (let j: number = textEnd; j < fragments.length; j++) {
      fields.push(fragments[j]);
    }
    const startMs: number | undefined = safeSubtitleTime(fields[startColumn].trim());
    const endMs: number | undefined = safeSubtitleTime(fields[endColumn].trim());
    if (startMs === undefined || endMs === undefined || endMs < startMs) { malformed = true; continue; }
    const text: string = decodeEntities(fields[textColumn])
      .replace(/\{[^}]*\}/g, '').replace(/\\N/g, '\n').replace(/\\n/g, '\n').trim();
    if (startMs !== undefined && text.length > 0) {
      const line: LyricLine = { startMs, text };
      if (endMs !== undefined) line.endMs = endMs;
      lines.push(line);
    }
  }
  return {
    format: 'ass',
    metadata: {},
    lines,
    warnings: malformed ? ['ASS/SSA 包含未识别内容或无效时间，已禁止转换以免丢失内容'] :
      ['ASS/SSA 的起止时间和文本会被提取，但样式、说话人、卡拉 OK 效果和定位信息不会完整保留'],
    conversionBlocked: malformed
  };
}

export class LyricEngine {
  static parse(sourceText: string, fileName: string = ''): LyricDocument {
    const source: string = sourceText.replace(/^\uFEFF/, '').replace(/\r/g, '');
    const lowerName: string = fileName.toLowerCase();
    const trimmed: string = source.trim();
    if (trimmed.length === 0) {
      return { format: 'unknown', metadata: {}, lines: [], warnings: ['歌词内容为空'] };
    }

    // Explicit extensions are authoritative; a subtitle's text can itself contain LRC-looking tags.
    if (lowerName.endsWith('.lrc')) return parseLrc(source);
    if (lowerName.endsWith('.ass') || lowerName.endsWith('.ssa')) return parseAss(source);
    if (lowerName.endsWith('.vtt') || lowerName.endsWith('.srt')) {
      return parseSubRipOrVtt(source, lowerName.endsWith('.vtt') ? 'vtt' : 'srt');
    }
    if (lowerName.endsWith('.sbv')) return parseSbv(source);
    if (/^\s*\[Script Info\]/im.test(trimmed) || /^\s*Dialogue:/im.test(trimmed)) return parseAss(source);
    if (/^WEBVTT\b/i.test(trimmed)) return parseSubRipOrVtt(source, 'vtt');
    // For extensionless text, use the first structural cue. A later LRC-like
    // string inside an SRT subtitle must not reclassify the entire document.
    const lrcMatch: RegExpExecArray | null = /^\s*\[\d{1,3}:\d{2}(?:[.:]\d{1,3})?\]/m.exec(source);
    const lrcAt: number = lrcMatch === null ? -1 : lrcMatch.index;
    const subtitleAt: number = firstSubtitleCue(source);
    const sbvAt: number = firstSbvCue(source);
    if (lrcAt >= 0 && (subtitleAt < 0 || lrcAt < subtitleAt) && (sbvAt < 0 || lrcAt < sbvAt)) return parseLrc(source);
    if (subtitleAt >= 0 && (sbvAt < 0 || subtitleAt <= sbvAt)) return parseSubRipOrVtt(source, 'srt');
    if (sbvAt >= 0) return parseSbv(source);
    const plainLines: LyricLine[] = [];
    const rows: string[] = source.split('\n');
    for (let i: number = 0; i < rows.length; i++) {
      const text: string = rows[i].trim();
      if (text.length > 0) plainLines.push({ text });
    }
    if (lowerName.endsWith('.txt') || plainLines.length > 0) {
      return { format: 'txt', metadata: {}, lines: plainLines, warnings: ['纯文本不包含可靠的逐行时间信息'] };
    }
    return { format: 'unknown', metadata: {}, lines: [], warnings: ['无法识别歌词格式'] };
  }

  static toLrc(document: LyricDocument): LrcExportResult {
    if (document.conversionBlocked === true) throw new Error('字幕存在未识别内容或无效时间，已停止转换，避免丢失内容。');
    const warnings: string[] = document.warnings.slice();
    if (document.format === 'ass' ||
        document.format === 'srt' || document.format === 'vtt' || document.format === 'sbv') {
      warnings.push('导出为 LRC 会丢失部分原格式信息（例如样式、说话人或结束时间）');
    }
    if (document.format === 'enhanced-lrc') {
      warnings.push('导出为标准 LRC 会丢失部分行内逐字/逐词时间标记');
    }
    if (document.format === 'txt') {
      warnings.push('纯文本没有可靠的逐行时间戳；导出为 LRC 后仍然是无时间戳文本行');
    }
    let output: string = '';
    if (document.metadata['ti'] !== undefined) output += '[ti:' + document.metadata['ti'] + ']\n';
    if (document.metadata['ar'] !== undefined) output += '[ar:' + document.metadata['ar'] + ']\n';
    const lines: LyricLine[] = document.lines.slice().sort((a: LyricLine, b: LyricLine) =>
      (a.startMs === undefined ? Number.MAX_SAFE_INTEGER : a.startMs) -
      (b.startMs === undefined ? Number.MAX_SAFE_INTEGER : b.startMs));
    for (let i: number = 0; i < lines.length; i++) {
      const line: LyricLine = lines[i];
      if (line.startMs === undefined) {
        output += line.text + '\n';
        continue;
      }
      const totalHundredths: number = Math.floor(line.startMs / 10);
      const minutes: number = Math.floor(totalHundredths / 6000);
      const seconds: number = Math.floor((totalHundredths % 6000) / 100);
      const hundredths: number = totalHundredths % 100;
      output += '[' + String(minutes).padStart(2, '0') + ':' +
        String(seconds).padStart(2, '0') + '.' + String(hundredths).padStart(2, '0') +
        ']' + line.text + '\n';
    }
    return { text: output, warnings };
  }
}
