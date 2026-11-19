/** Export LRC text without parsing and rebuilding its metadata or line order. */
const MAX_LRC_EXPORT_CHARS: number = 1024 * 1024;

/** True also for a malformed time-like marker so the user can choose preservation. */
export function hasInlineLrcTiming(text: string): boolean {
  return /<\s*[+-]?\d+\s*[:.,]/.test(text);
}

/**
 * Remove recognized enhanced-LRC inline timestamps from timed lyric lines only.
 * Refuse ambiguous time-like markup rather than silently discard or reinterpret it.
 * The input is a decoded string; this preserves line endings and text, not file encoding.
 */
export function plainLrcFromEnhanced(text: string): string {
  if (text.length > MAX_LRC_EXPORT_CHARS) throw new Error('歌词过长，无法安全转换。');
  const parts: string[] = text.split(/(\r\n|\r|\n)/);
  for (let i: number = 0; i < parts.length; i += 2) {
    const row: string = parts[i];
    if (!/<\s*[+-]?\d+\s*[:.,]/.test(row)) continue;
    const leading: RegExpMatchArray | null = row.match(/^\s*((?:\[\d{1,3}:\d{2}(?:\.\d{1,3})?\])+)/);
    if (leading === null) {
      throw new Error('逐字时间标记所在行缺少可识别的行首时间，无法安全转换。');
    }
    const starts: RegExpMatchArray | null = leading[1].match(/\[\d{1,3}:\d{2}(?:\.\d{1,3})?\]/g);
    if (starts === null) throw new Error('行首时间格式不受支持。');
    for (let j: number = 0; j < starts.length; j++) {
      const seconds: string = starts[j].substring(starts[j].indexOf(':') + 1, starts[j].indexOf(':') + 3);
      if (Number(seconds) >= 60) throw new Error('行首时间超出范围。');
    }
    let output: string = '';
    let cursor: number = 0;
    const candidate: RegExp = /<\s*[+-]?\d+\s*[:.,]/g;
    let hit: RegExpExecArray | null = candidate.exec(row);
    while (hit !== null) {
      const end: number = row.indexOf('>', hit.index);
      if (end < 0) throw new Error('逐字时间标记不完整，无法安全转换。');
      const marker: string = row.substring(hit.index, end + 1);
      const parsed: RegExpMatchArray | null = marker.match(/^<(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?>$/);
      if (parsed === null || Number(parsed[2]) >= 60) throw new Error('逐字时间格式不受支持，无法安全转换。');
      output += row.substring(cursor, hit.index);
      cursor = end + 1;
      candidate.lastIndex = cursor;
      hit = candidate.exec(row);
    }
    parts[i] = output + row.substring(cursor);
  }
  return parts.join('');
}
