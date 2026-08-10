import type { EnvironmentThreadShell } from "./state/models.ts";

export type InteractionSoundCue = "bloom" | "success";

interface ThreadSoundState {
  readonly completedRun: string | null;
  readonly userInitiatedRun: string | null;
  readonly hasPendingUserInput: boolean;
  readonly hasPendingApprovals: boolean;
}

export type ThreadSoundStateByKey = ReadonlyMap<string, ThreadSoundState>;

export function shouldPlayInteractionSound(
  cue: InteractionSoundCue,
  completionSoundEnabled: boolean,
): boolean {
  return cue !== "success" || completionSoundEnabled;
}

function threadKey(thread: EnvironmentThreadShell): string {
  return `${thread.environmentId}:${thread.id}`;
}

function completedRun(thread: EnvironmentThreadShell): string | null {
  const latestRun = thread.latestRun;
  if (latestRun === null || latestRun.completedAt === null) {
    return null;
  }
  if (latestRun.status !== "completed") {
    return null;
  }
  return latestRun.runId;
}

const USER_RUN_START_WINDOW_MS = 2 * 60 * 1_000;

function userInitiatedRun(thread: EnvironmentThreadShell): string | null {
  const latestRun = thread.latestRun;
  if (latestRun === null) {
    return null;
  }

  // V2 shells do not yet expose initiatingUserMessageId on latestRun. Associate
  // a completed run with a nearby user message so synthetic background work
  // does not fire success cues. A later steering message falls after
  // requestedAt and is excluded by the positive startup delay check.
  if (thread.latestUserMessageAt === null || latestRun.requestedAt === null) {
    return null;
  }

  const requestedAt = Date.parse(latestRun.requestedAt);
  const latestUserMessageAt = Date.parse(thread.latestUserMessageAt);
  if (!Number.isFinite(requestedAt) || !Number.isFinite(latestUserMessageAt)) {
    return null;
  }

  // A normal prompt is recorded before provider startup, while synthetic
  // background work has no nearby initiating message. Keep the same bounded
  // adoption window used for queued turn starts so an old prompt cannot claim
  // unrelated background work.
  const startupDelay = requestedAt - latestUserMessageAt;
  if (startupDelay < 0 || startupDelay > USER_RUN_START_WINDOW_MS) {
    return null;
  }

  return latestRun.runId;
}

export function captureThreadSoundState(
  threads: ReadonlyArray<EnvironmentThreadShell>,
): ThreadSoundStateByKey {
  return new Map(
    threads.map((thread) => [
      threadKey(thread),
      {
        completedRun: completedRun(thread),
        userInitiatedRun: userInitiatedRun(thread),
        hasPendingUserInput: thread.hasPendingUserInput,
        hasPendingApprovals: thread.hasPendingApprovals,
      },
    ]),
  );
}

export function deriveInteractionSoundCues(
  previous: ThreadSoundStateByKey,
  threads: ReadonlyArray<EnvironmentThreadShell>,
): InteractionSoundCue[] {
  const cues: InteractionSoundCue[] = [];

  for (const thread of threads) {
    const prior = previous.get(threadKey(thread));
    const nextCompletedRun = completedRun(thread);
    const nextUserInitiatedRun = userInitiatedRun(thread);

    if (
      prior &&
      nextCompletedRun !== null &&
      prior.completedRun !== nextCompletedRun &&
      nextUserInitiatedRun === nextCompletedRun
    ) {
      cues.push("success");
    }
    if (
      prior &&
      ((thread.hasPendingUserInput && !prior.hasPendingUserInput) ||
        (thread.hasPendingApprovals && !prior.hasPendingApprovals))
    ) {
      cues.push("bloom");
    }
  }

  return cues;
}

export interface ThreadSoundObservation {
  readonly state: ThreadSoundStateByKey;
  readonly cues: ReadonlyArray<InteractionSoundCue>;
}

/**
 * Advance one thread's sound state. Coordinators subscribe to individual
 * thread atoms so streaming updates only revisit the thread that changed.
 *
 * Port of Jake's observeThreadSoundState (fix/sounds: preserve incremental
 * cues / suppress stale startup / retain per-thread live) onto V2 shells that
 * use latestRun instead of latestTurn.
 */
export function observeThreadSoundState(
  previous: ThreadSoundStateByKey | null,
  thread: EnvironmentThreadShell,
  options: {
    readonly environmentLive: boolean;
    readonly environmentPreviouslyLive: boolean;
    readonly settingsHydrated: boolean;
  },
): ThreadSoundObservation {
  const current = [thread];
  // First observation for an environment: establish baseline only, no cues.
  // Suppresses stale startup completion/input cues when reconnecting.
  if (!options.environmentPreviouslyLive) {
    return { state: captureThreadSoundState(current), cues: [] };
  }
  const baseline =
    previous ??
    new Map([
      [
        threadKey(thread),
        {
          completedRun: null,
          userInitiatedRun: null,
          hasPendingUserInput: false,
          hasPendingApprovals: false,
        },
      ],
    ]);

  // While offline or settings still hydrating, retain the last live baseline
  // without advancing state or firing cues.
  if (!options.environmentLive || !options.settingsHydrated) {
    return { state: baseline, cues: [] };
  }

  return {
    state: captureThreadSoundState(current),
    cues: deriveInteractionSoundCues(baseline, current),
  };
}
