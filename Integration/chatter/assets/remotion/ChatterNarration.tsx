import React from 'react';
import {Audio} from '@remotion/media';
import {Sequence, staticFile, useVideoConfig} from 'remotion';

export type ChatterScene = {
  id: string;
  title: string;
  src: string;
  from: number;
  audioFrames: number;
  durationInFrames: number;
  text?: string;
  voice?: string;
  tone?: string;
  pace?: number;
  language?: string;
  instruction?: string;
  quality?: string;
  sampleID?: string;
  referenceSampleIDs?: string[];
  voiceName?: string;
  // JSON imports infer plain strings; keep the manifest directly assignable without casts.
  voiceConfiguration?: {kind: string; language: string; speaker?: string; description?: string};
  engineName?: string;
  modelID?: string;
  warnings?: string[];
  dialogue?: {
    cast: Record<string, string>;
    turns: {actor: string; text: string; tone?: string; language?: string; instruction?: string}[];
    gapSeconds?: number;
  };
  /** Post-pace seconds and frames relative to this scene, not the composition. */
  dialogueTiming?: {
    actor: string; voice: string; start: number; duration: number; modelID?: string;
    from: number; durationInFrames: number;
  }[];
};

export type ChatterManifest = {
  fps: number;
  durationInFrames: number;
  scenes: ChatterScene[];
};

/** Add to a composition whose fps/duration come from chatter-narration.json. */
export const ChatterNarration: React.FC<{manifest: ChatterManifest}> = ({manifest}) => {
  const {fps} = useVideoConfig();
  if (fps !== manifest.fps) {
    throw new Error('Chatter narration FPS differs from the composition; restage the handoff at this FPS.');
  }
  return <>
    {manifest.scenes.map((scene) => (
      <Sequence key={scene.id} name={`${scene.title} — narration`}
        from={scene.from} durationInFrames={scene.audioFrames} layout="none">
        <Audio src={staticFile(scene.src)} />
      </Sequence>
    ))}
  </>;
};
