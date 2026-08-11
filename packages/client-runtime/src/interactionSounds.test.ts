import { EnvironmentId, ProjectId, ProviderInstanceId, RunId, ThreadId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";
import type { EnvironmentThreadShell, ThreadRunSummary } from "./state/models.ts";
import {
  captureThreadSoundState,
  deriveInteractionSoundCues,
  observeThreadSoundState,
  shouldPlayInteractionSound,
} from "./interactionSounds.ts";

function makeRun(overrides: Partial<ThreadRunSummary> = {}): ThreadRunSummary {
  return {
    runId: RunId.make("run-1"),
    status: "running",
    requestedAt: "2026-07-11T12:00:02.000Z",
    startedAt: "2026-07-11T12:00:03.000Z",
    completedAt: null,
    assistantMessageId: null,
    ...overrides,
  };
}

function makeThread(overrides: Partial<EnvironmentThreadShell> = {}): EnvironmentThreadShell {
  return {
    environmentId: EnvironmentId.make("environment-1"),
    id: ThreadId.make("thread-1"),
    projectId: ProjectId.make("project-1"),
    title: "Thread",
    providerInstanceId: ProviderInstanceId.make("provider-1"),
    modelSelection: {
      instanceId: ProviderInstanceId.make("provider-1"),
      model: "claude-sonnet",
    },
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
    lineage: {
      parentThreadId: null,
      relationshipToParent: null,
      rootThreadId: ThreadId.make("thread-1"),
    },
    forkedFrom: null,
    activeProviderThreadId: null,
    latestRun: null,
    runtime: null,
    latestUserMessageAt: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    hasActionableProposedPlan: false,
    pendingBackgroundTasks: [],
    itemCount: 0,
    visibleItemCount: 0,
    createdAt: "2026-07-11T12:00:00.000Z",
    updatedAt: "2026-07-11T12:00:00.000Z",
    archivedAt: null,
    settledOverride: null,
    settledOverrideAt: null,
    settledAt: null,
    snoozedUntil: null,
    snoozedAt: null,
    pinnedAt: null,
    pinOrderKey: null,
    titleRegeneration: null,
    deletedAt: null,
    source: {} as EnvironmentThreadShell["source"],
    ...overrides,
  };
}

function userRun(overrides: Partial<ThreadRunSummary> = {}): ThreadRunSummary {
  return makeRun({
    requestedAt: "2026-07-11T12:00:02.000Z",
    startedAt: "2026-07-11T12:00:03.000Z",
    ...overrides,
  });
}

describe("interaction sounds", () => {
  it("plays success when a run is associated with a nearby user message", () => {
    const running = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
      latestRun: userRun({ status: "running" }),
    });
    const completed = makeThread({
      latestUserMessageAt: running.latestUserMessageAt,
      latestRun: userRun({
        status: "completed",
        completedAt: "2026-07-11T12:00:05.000Z",
      }),
    });

    expect(deriveInteractionSoundCues(captureThreadSoundState([running]), [completed])).toEqual([
      "success",
    ]);
  });

  it("does not associate an old user message with later background work", () => {
    const beforeBackgroundWork = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
    });
    const completedBackgroundRun = makeThread({
      latestUserMessageAt: beforeBackgroundWork.latestUserMessageAt,
      latestRun: makeRun({
        runId: RunId.make("background-run"),
        status: "completed",
        requestedAt: "2026-07-11T12:05:00.000Z",
        startedAt: "2026-07-11T12:05:00.000Z",
        completedAt: "2026-07-11T12:05:05.000Z",
      }),
    });

    expect(
      deriveInteractionSoundCues(captureThreadSoundState([beforeBackgroundWork]), [
        completedBackgroundRun,
      ]),
    ).toEqual([]);
  });

  it("does not let a later steering message associate a background run", () => {
    const backgroundRunning = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
      latestRun: makeRun({
        runId: RunId.make("subagent-run"),
        status: "running",
        requestedAt: "2026-07-11T12:05:00.000Z",
        startedAt: "2026-07-11T12:05:00.000Z",
      }),
    });
    const steeredAfterStart = makeThread({
      latestUserMessageAt: "2026-07-11T12:05:30.000Z",
      latestRun: makeRun({
        runId: RunId.make("subagent-run"),
        status: "completed",
        requestedAt: "2026-07-11T12:05:00.000Z",
        startedAt: "2026-07-11T12:05:00.000Z",
        completedAt: "2026-07-11T12:06:00.000Z",
      }),
    });

    expect(
      deriveInteractionSoundCues(captureThreadSoundState([backgroundRunning]), [steeredAfterStart]),
    ).toEqual([]);
  });

  it("plays bloom when a thread starts waiting for user input", () => {
    const idle = makeThread();
    const waiting = makeThread({ hasPendingUserInput: true });
    expect(deriveInteractionSoundCues(captureThreadSoundState([idle]), [waiting])).toEqual([
      "bloom",
    ]);
  });

  it("keeps input-request cues enabled when completion sounds are disabled", () => {
    expect(shouldPlayInteractionSound("success", false)).toBe(false);
    expect(shouldPlayInteractionSound("bloom", false)).toBe(true);
  });

  it("freezes observation while settings hydrate then plays the completion cue", () => {
    const running = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
      latestRun: userRun({ status: "running" }),
    });
    const completed = makeThread({
      latestUserMessageAt: running.latestUserMessageAt,
      latestRun: userRun({
        status: "completed",
        completedAt: "2026-07-11T12:00:05.000Z",
      }),
    });

    const seeded = observeThreadSoundState(null, running, {
      environmentLive: true,
      environmentPreviouslyLive: false,
      settingsHydrated: false,
    });
    const frozen = observeThreadSoundState(seeded.state, completed, {
      environmentLive: true,
      environmentPreviouslyLive: true,
      settingsHydrated: false,
    });
    const hydrated = observeThreadSoundState(frozen.state, completed, {
      environmentLive: true,
      environmentPreviouslyLive: true,
      settingsHydrated: true,
    });

    expect(hydrated.cues).toEqual(["success"]);
  });

  it("preserves a thread baseline while its environment is synchronizing", () => {
    const running = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
      latestRun: userRun({ status: "running" }),
    });
    const completedDuringSync = makeThread({
      latestUserMessageAt: running.latestUserMessageAt,
      latestRun: userRun({
        status: "completed",
        completedAt: "2026-07-11T12:00:05.000Z",
      }),
    });
    const beforeSync = captureThreadSoundState([running]);
    const whileSynchronizing = observeThreadSoundState(beforeSync, completedDuringSync, {
      environmentLive: false,
      environmentPreviouslyLive: true,
      settingsHydrated: true,
    });
    const reconnected = observeThreadSoundState(whileSynchronizing.state, completedDuringSync, {
      environmentLive: true,
      environmentPreviouslyLive: true,
      settingsHydrated: true,
    });

    expect(reconnected.cues).toEqual(["success"]);
  });

  it("refreshes cached startup state until the environment first becomes live", () => {
    const staleRunning = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
      latestRun: userRun({ status: "running" }),
    });
    const refreshedCompleted = makeThread({
      latestUserMessageAt: staleRunning.latestUserMessageAt,
      latestRun: userRun({
        status: "completed",
        completedAt: "2026-07-11T12:00:05.000Z",
      }),
    });
    const seeded = observeThreadSoundState(null, staleRunning, {
      environmentLive: false,
      environmentPreviouslyLive: false,
      settingsHydrated: true,
    });
    const refreshed = observeThreadSoundState(seeded.state, refreshedCompleted, {
      environmentLive: false,
      environmentPreviouslyLive: false,
      settingsHydrated: true,
    });
    const firstLive = observeThreadSoundState(refreshed.state, refreshedCompleted, {
      environmentLive: true,
      environmentPreviouslyLive: false,
      settingsHydrated: true,
    });

    expect(firstLive.cues).toEqual([]);
  });

  it("plays later cues after the first live snapshot seeds the baseline", () => {
    const running = makeThread({
      latestUserMessageAt: "2026-07-11T12:00:00.000Z",
      latestRun: userRun({ status: "running" }),
    });
    const completed = makeThread({
      latestUserMessageAt: running.latestUserMessageAt,
      latestRun: userRun({
        status: "completed",
        completedAt: "2026-07-11T12:00:05.000Z",
      }),
    });
    let environmentObservedLive = false;
    const firstLive = observeThreadSoundState(null, running, {
      environmentLive: true,
      environmentPreviouslyLive: environmentObservedLive,
      settingsHydrated: true,
    });
    environmentObservedLive = true;
    const laterUpdate = observeThreadSoundState(firstLive.state, completed, {
      environmentLive: true,
      environmentPreviouslyLive: environmentObservedLive,
      settingsHydrated: true,
    });

    expect(firstLive.cues).toEqual([]);
    expect(laterUpdate.cues).toEqual(["success"]);
  });

  it("detects a user-input request received while its environment is synchronizing", () => {
    const idle = makeThread();
    const pendingInputDuringSync = makeThread({ hasPendingUserInput: true });
    const beforeSync = captureThreadSoundState([idle]);
    const whileSynchronizing = observeThreadSoundState(beforeSync, pendingInputDuringSync, {
      environmentLive: false,
      environmentPreviouslyLive: true,
      settingsHydrated: true,
    });
    const reconnected = observeThreadSoundState(whileSynchronizing.state, pendingInputDuringSync, {
      environmentLive: true,
      environmentPreviouslyLive: true,
      settingsHydrated: true,
    });

    expect(reconnected.cues).toEqual(["bloom"]);
  });

  it("compares a thread first discovered after reconnect with an idle baseline", () => {
    const discovered = observeThreadSoundState(null, makeThread({ hasPendingUserInput: true }), {
      environmentLive: true,
      environmentPreviouslyLive: true,
      settingsHydrated: true,
    });

    expect(discovered.cues).toEqual(["bloom"]);
  });

  it("plays completion for a thread first discovered after reconnect", () => {
    const discovered = observeThreadSoundState(
      null,
      makeThread({
        latestUserMessageAt: "2026-07-11T12:00:00.000Z",
        latestRun: userRun({
          runId: RunId.make("remote-run"),
          status: "completed",
          completedAt: "2026-07-11T12:00:05.000Z",
        }),
      }),
      {
        environmentLive: true,
        environmentPreviouslyLive: true,
        settingsHydrated: true,
      },
    );

    expect(discovered.cues).toEqual(["success"]);
  });

  it("seeds a thread from the first live hydration without playing a cue", () => {
    const discovered = observeThreadSoundState(null, makeThread({ hasPendingUserInput: true }), {
      environmentLive: true,
      environmentPreviouslyLive: false,
      settingsHydrated: true,
    });

    expect(discovered.cues).toEqual([]);
  });
});
