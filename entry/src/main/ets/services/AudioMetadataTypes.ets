import { image } from '@kit.ImageKit';

// Project-owned metadata contract; writable fields are explicitly selected.
export interface AudioMetadata {
  title: string; artist: string; album: string; year: number; track: number;
  genre: string; comment: string; lyrics: string; albumArtist: string; composer: string;
  disc: number; discTotal: number; trackTotal: number; bpm: number; grouping: string;
  isrc: string; copyright: string; duration: number; durationMs: number; bitrate: number;
  sampleRate: number; channels: number; coverImage: image.PixelMap | undefined;
  fileType: string; fileSize: number; creationTime: number; modifyTime: number;
}
export interface AudioMetadataWriter {
  title?: string; artist?: string; album?: string; year?: number; track?: number;
  genre?: string; comment?: string; lyrics?: string; albumArtist?: string; composer?: string;
  disc?: number; discTotal?: number; trackTotal?: number; bpm?: number; grouping?: string;
  isrc?: string; copyright?: string; coverImage?: image.PixelMap;
}
