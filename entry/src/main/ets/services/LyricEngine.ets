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
    if (value.indexOf('-->') >= 0) break;
    parts.push(value);
  }
  return parts.join(' ');
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
  const timePattern: RegExp = /\[(\d{1,2}:\d{2}(?:[.:]\d{1,3})?)\]/g;
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
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    if (row.indexOf('-->') < 0) continue;
    const timing: string[] = row.split('-->');
    const startMs: number | undefined = parseTimestamp(timing[0].trim().split(' ')[0]);
    const endMs: number | undefined = timing.length > 1 ?
      parseTimestamp(timing[1].trim().split(' ')[0]) : undefined;
    let text: string = makeLineText(rows, i + 1);
    text = text.replace(/<[^>]+>/g, '').trim();
    if (startMs !== undefined && text.length > 0) {
      const line: LyricLine = { startMs, text };
      if (endMs !== undefined) line.endMs = endMs;
      lines.push(line);
    }
  }
  lines.sort((a: LyricLine, b: LyricLine) =>
    (a.startMs === undefined ? 0 : a.startMs) - (b.startMs === undefined ? 0 : b.startMs));
  return {
    format,
    metadata: {},
    lines,
    warnings: ['转为 LRC 时字幕样式、位置及部分格式控制信息无法保留']
  };
}

function parseSbv(source: string): LyricDocument {
  const rows: string[] = source.replace(/\r/g, '').split('\n');
  const lines: LyricLine[] = [];
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
    const timing: RegExpMatchArray | null = row.match(/^((?:\d+:)?\d+:\d+\.\d+),((?:\d+:)?\d+:\d+\.\d+)$/);
    if (timing === null || timing.length < 3) continue;
    const startMs: number | undefined = parseTimestamp(timing[1]);
    const endMs: number | undefined = parseTimestamp(timing[2]);
    const text: string = makeLineText(rows, i + 1);
    if (startMs !== undefined && text.length > 0) {
      const line: LyricLine = { startMs, text };
      if (endMs !== undefined) line.endMs = endMs;
      lines.push(line);
    }
  }
  return {
    format: 'sbv',
    metadata: {},
    lines,
    warnings: ['SBV 的结束时间将不会写入标准 LRC']
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
  for (let i: number = 0; i < rows.length; i++) {
    const row: string = rows[i].trim();
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
      }
      continue;
    }
    if (!/^dialogue:/i.test(row)) continue;
    const body: string = row.substring(row.indexOf(':') + 1).trim();
    const fragments: string[] = body.split(',');
    if (fragments.length < expectedColumns) continue;
    // ASS 的 Text 字段可能包含逗号；即使 Format 声明中 Text 不是最后一列，
    // 也能按前后固定字段数正确拼回文本，而不是悄悄跳过整条字幕。
    const suffixCount: number = expectedColumns - textColumn - 1;
    const textEnd: number = fragments.length - suffixCount;
    const fields: string[] = fragments.slice(0, textColumn);
    fields.push(fragments.slice(textColumn, textEnd).join(','));
    for (let j: number = textEnd; j < fragments.length; j++) {
      fields.push(fragments[j]);
    }
    const startMs: number | undefined = parseTimestamp(fields[startColumn].trim());
    const endMs: number | undefined = parseTimestamp(fields[endColumn].trim());
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
    warnings: ['ASS/SSA 的起止时间和文本会被提取，但样式、说话人、卡拉 OK 效果和定位信息不会完整保留']
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

    if (lowerName.endsWith('.ass') || lowerName.endsWith('.ssa') ||
        /^\s*\[Script Info\]/im.test(trimmed) || /^\s*Dialogue:/im.test(trimmed)) {
      return parseAss(source);
    }
    if (lowerName.endsWith('.vtt') || /^WEBVTT\b/im.test(trimmed) || /-->/.test(trimmed)) {
      return parseSubRipOrVtt(source, lowerName.endsWith('.vtt') || /^WEBVTT\b/im.test(trimmed) ? 'vtt' : 'srt');
    }
    if (lowerName.endsWith('.sbv') || /^\d{1,2}:\d{2}:\d{2}\.\d+,\d{1,2}:\d{2}:\d{2}\.\d+/m.test(trimmed)) {
      return parseSbv(source);
    }
    if (lowerName.endsWith('.lrc') || /^\s*\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]/m.test(trimmed)) {
      return parseLrc(source);
    }
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
