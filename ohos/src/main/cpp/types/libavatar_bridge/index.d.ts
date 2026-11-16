export interface AvatarStats {
  loaded: boolean;
  frames: number;
  renderMs: number;
  paused: boolean;
  speaking: boolean;
  expression: string;
  error: string;
}
export const load: (surfaceId: string, path: string, bytes: ArrayBuffer) => Promise<void>;
export const dispose: () => void;
export const command: (method: string, value: string) => void;
export const stats: () => AvatarStats;

export const control: (request: string) => string;
