import { IosBuildStartError } from "@t3tools/contracts";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Result from "effect/Result";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { ChildProcessSpawner } from "effect/unstable/process";

import * as WorkspacePaths from "../workspace/WorkspacePaths.ts";
import { startIOSBuild } from "./runner.ts";

const spawnerStub = ChildProcessSpawner.make(() =>
  Effect.die("ChildProcessSpawner used unexpectedly in test"),
);

const testLayer = Layer.mergeAll(
  WorkspacePaths.layer,
  Layer.succeed(ChildProcessSpawner.ChildProcessSpawner, spawnerStub),
).pipe(Layer.provideMerge(NodeServices.layer));

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
});
