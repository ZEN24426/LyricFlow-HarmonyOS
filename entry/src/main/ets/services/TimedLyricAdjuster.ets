/**
 * Conservative, text-preserving adjustments for LRC and enhanced LRC.
 *
 * Row numbers are zero-based physical text rows, including metadata and empty
 * rows. Times and calibration anchors are integer milliseconds on the raw LRC
 * timeline. In particular [offset:...] is retained verbatim and is NOT applied
 * by this service: the caller must convert player positions to the same raw
 * timeline before passing calibration targets. No source is modified on error.
 */
export interface TimedLyricRow {
  rowIndex: number;
  startMs: number;
  text: string;
}

export interface TimedLyricAnchor {
  sourceRawMs: number;
  targetRawMs: number;
}

/** A player time is not a raw LRC time when a global offset is present. */
export interface TimedLyricPlaybackAnchor {
  sourceRawMs: number;
  playbackMs: number;
}

interface TimestampToken {
  whole: string;
  minuteWidth: number;
  fractionWidth: number;
  fractionSeparator: string;
  ms: number;
}

interface ParsedRow {
  rowIndex: number;
  prefix: string;
  stamp: TimestampToken;
  body: string;
}

interface ParsedInput {
  parts: string[];
  rows: ParsedRow[];
}

const MAX_INPUT_BYTES: number = 4 * 1024 * 1024;
const MAX_ROWS: number = 100000;
const MAX_TIME_MS: number = (999 * 60 + 59) * 1000 + 999;

/** Count UTF-8 without allocating a second full-size representation. */
function requireInput(text: string): void {
  let bytes: number = 0;
  for (let i: number = 0; i < text.length; i++) {
    const c: number = text.charCodeAt(i);
    if (c === 0) throw new Error('歌词包含 NUL 字符，无法安全调整。');
    if (c < 0x80) bytes++;
    else if (c < 0x800) bytes += 2;
    else if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= text.length) throw new Error('歌词包含无效 Unicode，无法安全调整。');
      const next: number = text.charCodeAt(++i);
      if (next < 0xDC00 || next > 0xDFFF) throw new Error('歌词包含无效 Unicode，无法安全调整。');
      bytes += 4;
    } else if (c >= 0xDC00 && c <= 0xDFFF) throw new Error('歌词包含无效 Unicode，无法安全调整。');
    else bytes += 3;
    if (bytes > MAX_INPUT_BYTES) throw new Error('歌词超过 4 MiB，无法安全调整。');
  }
}

function parseToken(value: string): TimestampToken | undefined {
  const hit: RegExpMatchArray | null = value.match(/^(\d{1,3}):([0-5]\d)(?:([.:])(\d{1,3}))?$/);
  if (hit === null) return undefined;
  const fraction: string = hit[4] === undefined ? '' : hit[4];
  const milliseconds: number = (Number(hit[1]) * 60 + Number(hit[2])) * 1000 +
    (fraction.length === 0 ? 0 : Number((fraction + '00').substring(0, 3)));
  return { whole: value, minuteWidth: hit[1].length, fractionWidth: fraction.length,
    fractionSeparator: hit[3] === undefined ? '.' : hit[3], ms: milliseconds };
}

function renderToken(stamp: TimestampToken, value: number): string {
  if (!Number.isSafeInteger(value) || value < 0 || value > MAX_TIME_MS) {
    throw new Error('调整后时间超出支持范围，歌词未修改。');
  }
  if (value === stamp.ms) return stamp.whole;
  const minutes: number = Math.floor(value / 60000);
  const seconds: number = Math.floor(value % 60000 / 1000);
  const milliseconds: number = value % 1000;
  let width: number = stamp.fractionWidth;
  if ((width === 0 && milliseconds !== 0) || (width === 1 && milliseconds % 100 !== 0) ||
      (width === 2 && milliseconds % 10 !== 0)) width = 3;
  let fraction: string = '';
  if (width > 0) fraction = stamp.fractionSeparator + String(milliseconds).padStart(3, '0').substring(0, width);
  return String(minutes).padStart(stamp.minuteWidth, '0') + ':' + String(seconds).padStart(2, '0') + fraction;
}

function validateInline(body: string): void {
  const markers: RegExp = /<([^>\r\n]*)>/g;
  let hit: RegExpExecArray | null = markers.exec(body);
  while (hit !== null) {
    if (/^\s*[+-]?\d+[:.,]/.test(hit[1]) && parseToken(hit[1]) === undefined) {
      throw new Error('存在无法识别的逐字时间标记，歌词未修改。');
    }
    hit = markers.exec(body);
  }
  if (/<\s*[+-]?\d+[:.,][^>\r\n]*$/.test(body)) throw new Error('逐字时间标记不完整，歌词未修改。');
}

function parseInput(text: string): ParsedInput {
  requireInput(text);
  const parts: string[] = text.split(/(\r\n|\r|\n)/);
  if (Math.ceil(parts.length / 2) > MAX_ROWS) throw new Error('歌词行数过多，无法安全调整。');
  const rows: ParsedRow[] = [];
  for (let i: number = 0; i < parts.length; i += 2) {
    const row: string = parts[i];
    if (/^\s*\d+:\d[^\r\n]*(?:-->|→)/.test(row)) throw new Error('包含字幕时间格式，不能按 LRC 调整。');
    // Preserve a BOM and whitespace as part of the original row.
    const match: RegExpMatchArray | null = row.match(/^([\uFEFF \t]*)\[([^\]\r\n]+)\]/);
    // Time-like brackets anywhere except the one leading timestamp are
    // ambiguous, including malformed or unterminated markers and markers
    // hidden after metadata or in lyric text.
    const possibleTimes: RegExp = /\[\s*[+-]?\d+[:.,]/g;
    let possible: RegExpExecArray | null = possibleTimes.exec(row);
    while (possible !== null) {
      if (match === null || possible.index !== match[1].length || parseToken(match[2]) === undefined) {
        throw new Error('存在隐藏或不支持的行时间标记，歌词未修改。');
      }
      possible = possibleTimes.exec(row);
    }
    if (match === null) {
      if (/^[\uFEFF \t]*\[\d+[:.,]/.test(row)) throw new Error('无法识别的行时间标记，歌词未修改。');
      if (/<\s*[+-]?\d+[:.,]/.test(row)) throw new Error('逐字时间没有对应行时间，歌词未修改。');
      continue;
    }
    const stamp: TimestampToken | undefined = parseToken(match[2]);
    if (stamp === undefined) {
      if (/^\d+[:.,]/.test(match[2])) throw new Error('不支持的行时间标记，歌词未修改。');
      if (/<\s*[+-]?\d+[:.,]/.test(row)) throw new Error('逐字时间没有对应行时间，歌词未修改。');
      continue;
    }
    const body: string = row.substring(match[0].length);
    validateInline(body);
    rows.push({ rowIndex: i / 2, prefix: match[1], stamp, body });
  }
  if (rows.length === 0) throw new Error('没有可调整的 LRC 时间行。');
  return { parts, rows };
}

function applyMap(parsed: ParsedInput, selected: Set<number>, map: (timeMs: number) => number): string {
  const result: string[] = parsed.parts.slice();
  const mappedGroups: Map<number, number> = new Map<number, number>();
  for (const row of parsed.rows) {
    const times: number[] = [row.stamp.ms];
    const markers: RegExp = /<([^>\r\n]*)>/g;
    let hit: RegExpExecArray | null = markers.exec(row.body);
    while (hit !== null) {
      const inline: TimestampToken | undefined = parseToken(hit[1]);
      if (inline !== undefined) times.push(inline.ms);
      hit = markers.exec(row.body);
    }
    for (const time of times) {
      const target: number = selected.has(row.rowIndex) ? map(time) : time;
      if (!Number.isSafeInteger(target) || target < 0 || target > MAX_TIME_MS) {
        throw new Error('调整后时间超出支持范围，歌词未修改。');
      }
      const previous: number | undefined = mappedGroups.get(target);
      if (previous !== undefined && previous !== time) {
        throw new Error('调整会使不同歌词时间重合，请选择其他偏移或校准点。');
      }
      mappedGroups.set(target, time);
    }
  }
  for (const row of parsed.rows) {
    if (!selected.has(row.rowIndex)) continue;
    const lineTime: string = renderToken(row.stamp, map(row.stamp.ms));
    const body: string = row.body.replace(/<([^>\r\n]*)>/g, (whole: string, token: string): string => {
      const stamp: TimestampToken | undefined = parseToken(token);
      return stamp === undefined ? whole : '<' + renderToken(stamp, map(stamp.ms)) + '>';
    });
    result[row.rowIndex * 2] = row.prefix + '[' + lineTime + ']' + body;
  }
  return result.join('');
}

function requireInteger(value: number, name: string): void {
  if (!Number.isSafeInteger(value)) throw new Error(name + '必须是整数毫秒。');
}

export class TimedLyricAdjuster {
  /** Inspect physical rows without rewriting or applying global LRC offset. */
  static inspect(text: string): TimedLyricRow[] {
    const parsed: ParsedInput = parseInput(text);
    return parsed.rows.map((row: ParsedRow): TimedLyricRow => ({
      rowIndex: row.rowIndex, startMs: row.stamp.ms, text: row.body
    }));
  }

  static shiftAll(text: string, deltaMs: number): string {
    requireInteger(deltaMs, '偏移');
    const parsed: ParsedInput = parseInput(text);
    const selected: Set<number> = new Set<number>();
    for (const row of parsed.rows) selected.add(row.rowIndex);
    return applyMap(parsed, selected, (time: number): number => time + deltaMs);
  }

  /** Select one physical row or an inclusive range. Same-time rows move together. */
  static shiftRows(text: string, firstRow: number, lastRow: number, deltaMs: number): string {
    requireInteger(firstRow, '起始行'); requireInteger(lastRow, '结束行'); requireInteger(deltaMs, '偏移');
    const parsed: ParsedInput = parseInput(text);
    if (firstRow < 0 || lastRow < firstRow || lastRow >= Math.ceil(parsed.parts.length / 2)) {
      throw new Error('选择的行范围无效。');
    }
    const groupTimes: Set<number> = new Set<number>();
    for (const row of parsed.rows) if (row.rowIndex >= firstRow && row.rowIndex <= lastRow) groupTimes.add(row.stamp.ms);
    if (groupTimes.size === 0) throw new Error('选择范围中没有带时间戳的歌词行。');
    const selected: Set<number> = new Set<number>();
    for (const row of parsed.rows) if (groupTimes.has(row.stamp.ms)) selected.add(row.rowIndex);
    return applyMap(parsed, selected, (time: number): number => time + deltaMs);
  }

  /** Map two increasing raw LRC timeline anchors; interpolate/extrapolate all markers. */
  static correctDrift(text: string, first: TimedLyricAnchor, second: TimedLyricAnchor): string {
    requireInteger(first.sourceRawMs, '第一原始时间'); requireInteger(first.targetRawMs, '第一目标时间');
    requireInteger(second.sourceRawMs, '第二原始时间'); requireInteger(second.targetRawMs, '第二目标时间');
    if (first.sourceRawMs < 0 || first.targetRawMs < 0 || second.sourceRawMs > MAX_TIME_MS ||
        second.targetRawMs > MAX_TIME_MS || second.sourceRawMs <= first.sourceRawMs || second.targetRawMs <= first.targetRawMs) {
      throw new Error('两个校准点必须依次递增且位于支持范围内。');
    }
    const parsed: ParsedInput = parseInput(text);
    const selected: Set<number> = new Set<number>();
    for (const row of parsed.rows) selected.add(row.rowIndex);
    const sourceSpan: number = second.sourceRawMs - first.sourceRawMs;
    const targetSpan: number = second.targetRawMs - first.targetRawMs;
    return applyMap(parsed, selected, (time: number): number =>
      Math.round(first.targetRawMs + (time - first.sourceRawMs) * targetSpan / sourceSpan));
  }

  /**
   * Calibrate against player positions only when there is no effective offset.
   * Conflicting, malformed, duplicate or nonzero offset tags are rejected.
   */
  static correctDriftFromPlayback(text: string, first: TimedLyricPlaybackAnchor,
    second: TimedLyricPlaybackAnchor): string {
    const parsed: ParsedInput = parseInput(text);
    let seen: boolean = false;
    for (let i: number = 0; i < parsed.parts.length; i += 2) {
      const row: string = parsed.parts[i];
      if (!/\[\s*offset\b/i.test(row)) continue;
      const match: RegExpMatchArray | null = row.match(/^[\uFEFF \t]*\[offset:([+-]?\d+)\][ \t]*$/i);
      if (match === null || seen || !Number.isSafeInteger(Number(match[1])) || Number(match[1]) !== 0) {
        throw new Error('歌词含非零或不明确的 offset，不能直接使用播放器时间校准。');
      }
      seen = true;
    }
    return TimedLyricAdjuster.correctDrift(text,
      { sourceRawMs: first.sourceRawMs, targetRawMs: first.playbackMs },
      { sourceRawMs: second.sourceRawMs, targetRawMs: second.playbackMs });
  }
}
