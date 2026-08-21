import { IosBuildStartError } from "@t3tools/contracts";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as Schema from "effect/Schema";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { ChildProcessSpawner } from "effect/unstable/process";

import * as WorkspacePaths from "../workspace/WorkspacePaths.ts";
import { startIOSBuild, writeFailedStatusIfActive } from "./runner.ts";

const spawnerStub = ChildProcessSpawner.make(() =>
  Effect.die("ChildProcessSpawner used unexpectedly in test"),
);

const testLayer = Layer.mergeAll(
  WorkspacePaths.layer,
  Layer.succeed(ChildProcessSpawner.ChildProcessSpawner, spawnerStub),
).pipe(Layer.provideMerge(NodeServices.layer));

const TestBuildStatus = Schema.Struct({
  phase: Schema.String,
  message: Schema.String,
  updatedAt: Schema.String,
});
const TestBuildStatusJson = Schema.fromJsonString(TestBuildStatus);
const encodeTestBuildStatus = Schema.encodeUnknownEffect(TestBuildStatusJson);
const decodeTestBuildStatus = Schema.decodeUnknownEffect(TestBuildStatusJson);

describe("startIOSBuild", () => {
  it.effect("rejects a workspace root that does not exist", () =>
    Effect.gen(function* () {
      const result = yield* Effect.result(
        startIOSBuild({
          workspaceRoot: "/definitely/not/a/real/workspace/root",
          threadId: "thread-1",
        }).pipe(Effect.provide(testLayer)),
      );
      expect(Result.isFailure(result)).toBe(true);
      if (Result.isFailure(result)) {
        const error = result.failure as IosBuildStartError;
        expect(error._tag).toBe("IosBuildStartError");
        expect(error.message).toContain("Workspace root is not valid");
      }
    }),
  );

  it.effect("accepts an existing workspace root and starts the build", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const tempRoot = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "t3-ios-build-test-",
      });
      const result = yield* Effect.result(
        startIOSBuild({
          workspaceRoot: tempRoot,
          threadId: "thread-1",
        }).pipe(Effect.provide(testLayer)),
      );
      expect(Result.isSuccess(result)).toBe(true);
    }).pipe(Effect.provide(testLayer)),
  );

  it.effect("reuses a fresh active build instead of starting a duplicate", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const tempRoot = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "t3-ios-active-build-test-",
      });
      yield* fileSystem.makeDirectory(`${tempRoot}/.t3`, { recursive: true });
      yield* fileSystem.writeFileString(
        `${tempRoot}/.t3/ios-build-status.json`,
        yield* encodeTestBuildStatus({
          phase: "building",
          message: "Building with Xcode",
          updatedAt: new Date().toISOString(),
        }),
      );

      const result = yield* startIOSBuild({
        workspaceRoot: tempRoot,
        threadId: "thread-1",
      });

      expect(result.started).toBe(false);
    }).pipe(Effect.provide(testLayer)),
  );

  it.effect("marks an interrupted active build as failed", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const tempRoot = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "t3-ios-status-test-",
      });
      yield* fileSystem.makeDirectory(`${tempRoot}/.t3`, { recursive: true });
      yield* fileSystem.writeFileString(
        `${tempRoot}/.t3/ios-build-status.json`,
        yield* encodeTestBuildStatus({
          phase: "building",
          message: "Building with Xcode",
          updatedAt: "2026-08-20T00:00:00.000Z",
        }),
      );

      yield* writeFailedStatusIfActive(tempRoot, "Build interrupted");

      const status = yield* decodeTestBuildStatus(
        yield* fileSystem.readFileString(`${tempRoot}/.t3/ios-build-status.json`),
      );
      expect(status.phase).toBe("failed");
      expect(status.message).toBe("Build interrupted");
    }).pipe(Effect.provide(NodeServices.layer)),
  );

  it.effect("does not replace a terminal build status", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const tempRoot = yield* fileSystem.makeTempDirectoryScoped({
        prefix: "t3-ios-status-test-",
      });
      yield* fileSystem.makeDirectory(`${tempRoot}/.t3`, { recursive: true });
      const completed = yield* encodeTestBuildStatus({
        phase: "done",
        message: "Build complete",
        updatedAt: "2026-08-20T00:00:00.000Z",
      });
      yield* fileSystem.writeFileString(`${tempRoot}/.t3/ios-build-status.json`, completed);

      yield* writeFailedStatusIfActive(tempRoot, "Build interrupted");

      expect(yield* fileSystem.readFileString(`${tempRoot}/.t3/ios-build-status.json`)).toBe(
        completed,
      );
    }).pipe(Effect.provide(NodeServices.layer)),
  );
});
