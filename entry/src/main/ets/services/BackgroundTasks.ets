import { taskpool } from '@kit.ArkTS';
import { LyricEngine, LyricDocument, LrcExportResult } from './LyricEngine';
import { MatchEngine, MatchCandidate, AudioMatchInput, LyricMatchInput } from './MatchEngine';

/**
 * 后台任务：将 CPU 密集型操作移至 TaskPool 子线程，避免阻塞 UI。
 *
 * @Concurrent 函数在 TaskPool 线程执行，参数和返回值通过结构化克隆传递。
 * 被调用的函数（LyricEngine.parse 等）是纯函数，不访问共享状态，线程安全。
 */

@Concurrent
function parseLyricTask(text: string, name: string): LyricDocument {
  return LyricEngine.parse(text, name);
}

@Concurrent
function convertToLrcTask(document: LyricDocument): LrcExportResult {
  return LyricEngine.toLrc(document);
}

@Concurrent
function matchTask(
  audioFiles: AudioMatchInput[],
  lyricFiles: LyricMatchInput[],
  maxComparisons: number
): MatchCandidate[] {
  return MatchEngine.match(audioFiles, lyricFiles, maxComparisons);
}

// ── 异步包装：供 UI 层 await 调用 ──

export async function parseLyricAsync(text: string, name: string): Promise<LyricDocument> {
  return await taskpool.execute(parseLyricTask, text, name) as LyricDocument;
}

export async function convertToLrcAsync(document: LyricDocument): Promise<LrcExportResult> {
  return await taskpool.execute(convertToLrcTask, document) as LrcExportResult;
}

export async function matchAsync(
  audioFiles: AudioMatchInput[],
  lyricFiles: LyricMatchInput[],
  maxComparisons: number
): Promise<MatchCandidate[]> {
  return await taskpool.execute(matchTask, audioFiles, lyricFiles, maxComparisons) as MatchCandidate[];
}
