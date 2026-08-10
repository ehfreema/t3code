// @effect-diagnostics nodeBuiltinImport:off
import type { OpenCode2Settings } from "@t3tools/contracts";
import * as NodeCrypto from "node:crypto";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeSqlite from "node:sqlite";

export const OPENCODE2_BACKGROUND_SUBAGENTS_ENV = "OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS";

const OPENCODE2_AUTH_FILES = ["account.json", "auth-v2.json", "auth.json"] as const;
const fallbackStateRoots = new Map<string, string>();

/**
 * Session/runtime tables pruned from a seeded host DB so we keep credentials
 * without reusing host chat sessions in the managed instance.
 */
const OPENCODE2_SESSION_TABLES = [
  "event",
  "event_sequence",
  "instruction_blob",
  "instruction_entry",
  "instruction_state",
  "message",
  "part",
  "permission",
  "session",
  "session_message",
  "session_pending",
  "session_share",
  "session_v2",
  "todo",
] as const;

/**
 * Self-spawned 2.x servers get an isolated data/state tree so they do not share
 * a live `opencode.db` with a desktop `opencode2 serve --service`. Host auth is
 * bridged in: next-line stores provider credentials in the sqlite `credential`
 * table (not only auth.json), and without that seed only free models appear.
 */
export function openCode2ManagedStateRoot(
  environment: NodeJS.ProcessEnv = process.env,
  instanceId?: string,
): string {
  const home = environment.HOME?.trim() || NodeOS.homedir();
  const identity = instanceId?.trim();
  const userKey = NodeCrypto.createHash("sha256")
    .update(identity === undefined ? home : `${home}\u0000${identity}`)
    .digest("hex")
    .slice(0, 12);
  return NodePath.join(
    environment.TMPDIR?.trim() || NodeOS.tmpdir(),
    `t3-opencode2-state-${userKey}`,
  );
}

function legacyOpenCode2ManagedStateRoot(environment: NodeJS.ProcessEnv = process.env): string {
  return NodePath.join(environment.TMPDIR?.trim() || NodeOS.tmpdir(), "t3-opencode2-state");
}

export function openCode2HostDataHome(environment: NodeJS.ProcessEnv = process.env): string {
  return (
    environment.XDG_DATA_HOME?.trim() ||
    NodePath.join(environment.HOME?.trim() || NodeOS.homedir(), ".local", "share")
  );
}

function sqlQuoteLiteral(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

function currentUserId(): number | undefined {
  return typeof process.getuid === "function" ? process.getuid() : undefined;
}

function isOwnedDirectory(stat: NodeFS.Stats): boolean {
  if (!stat.isDirectory()) return false;
  const uid = currentUserId();
  return uid === undefined || stat.uid === uid;
}

function isOwnedFile(stat: NodeFS.Stats): boolean {
  if (!stat.isFile()) return false;
  const uid = currentUserId();
  return uid === undefined || stat.uid === uid;
}

function hardenManagedPath(path: string, directory: boolean, mode: number): boolean {
  let fd: number | undefined;
  try {
    const flags =
      NodeFS.constants.O_RDONLY |
      (NodeFS.constants.O_NOFOLLOW ?? 0) |
      (directory ? (NodeFS.constants.O_DIRECTORY ?? 0) : 0);
    fd = NodeFS.openSync(path, flags);
    const stat = NodeFS.fstatSync(fd);
    if (directory ? !isOwnedDirectory(stat) : !isOwnedFile(stat)) return false;
    NodeFS.fchmodSync(fd, mode);
    return true;
  } catch {
    // Windows does not support all POSIX open flags. Fall back to the existing
    // ownership check there; POSIX hosts use the descriptor-based path above.
    if (NodeOS.platform() !== "win32") return false;
    try {
      const stat = NodeFS.lstatSync(path);
      if (directory ? !isOwnedDirectory(stat) : !isOwnedFile(stat)) return false;
      NodeFS.chmodSync(path, mode);
      return true;
    } catch {
      return false;
    }
  } finally {
    if (fd !== undefined) {
      try {
        NodeFS.closeSync(fd);
      } catch {
        // Descriptor cleanup is best effort after the mode change.
      }
    }
  }
}

/**
 * Create or validate a directory that T3 writes to. `lstat` is intentional:
 * following a pre-existing symlink here would let a different local process
 * redirect provider credentials outside the managed tree.
 */
function ensureManagedDirectory(path: string): boolean {
  try {
    const existing = NodeFS.lstatSync(path);
    if (!isOwnedDirectory(existing)) return false;
    return hardenManagedPath(path, true, 0o700);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return false;
  }

  try {
    NodeFS.mkdirSync(path, { recursive: true, mode: 0o700 });
    return hardenManagedPath(path, true, 0o700);
  } catch {
    return false;
  }
}

function migrateLegacyManagedStateRoot(
  stateRoot: string,
  environment: NodeJS.ProcessEnv,
  instanceId?: string,
): void {
  try {
    NodeFS.lstatSync(stateRoot);
    return;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") return;
  }
  const legacyRoots = [legacyOpenCode2ManagedStateRoot(environment)];
  // The user-scoped root was the current format before instance isolation.
  // Migrate it only for the built-in instance. Moving it to every custom
  // instance would copy one provider's live database into all instances.
  if (instanceId?.trim() === "opencode2") {
    legacyRoots.push(openCode2ManagedStateRoot(environment));
  }
  for (const legacyRoot of legacyRoots) {
    if (legacyRoot === stateRoot) continue;
    let legacy: NodeFS.Stats;
    try {
      legacy = NodeFS.lstatSync(legacyRoot);
    } catch {
      continue;
    }
    if (!isOwnedDirectory(legacy)) continue;
    try {
      NodeFS.renameSync(legacyRoot, stateRoot);
      return;
    } catch {
      // Another provider startup may have adopted or created the target first.
    }
  }
}

function prepareManagedStateRoot(stateRoot: string):
  | {
      readonly dataHome: string;
      readonly stateHome: string;
    }
  | undefined {
  if (!ensureManagedDirectory(stateRoot)) return undefined;
  const stateHome = NodePath.join(stateRoot, "state");
  const dataHome = NodePath.join(stateRoot, "data");
  if (!ensureManagedDirectory(stateHome) || !ensureManagedDirectory(dataHome)) return undefined;
  return { dataHome, stateHome };
}

function fallbackManagedStateRoot(
  stateRoot: string,
  environment: NodeJS.ProcessEnv,
): string | undefined {
  const existing = fallbackStateRoots.get(stateRoot);
  if (existing !== undefined && prepareManagedStateRoot(existing) !== undefined) return existing;
  const temporaryRoot = environment.TMPDIR?.trim() || NodeOS.tmpdir();
  const fallbackKey = NodeCrypto.createHash("sha256").update(stateRoot).digest("hex").slice(0, 12);
  const persistentFallback = NodePath.join(
    temporaryRoot,
    `t3-opencode2-state-fallback-${fallbackKey}`,
  );
  if (prepareManagedStateRoot(persistentFallback) !== undefined) {
    fallbackStateRoots.set(stateRoot, persistentFallback);
    return persistentFallback;
  }
  try {
    const fallback = NodeFS.mkdtempSync(
      NodePath.join(temporaryRoot, "t3-opencode2-state-fallback-random-"),
    );
    if (prepareManagedStateRoot(fallback) === undefined) return undefined;
    fallbackStateRoots.set(stateRoot, fallback);
    return fallback;
  } catch {
    return undefined;
  }
}

type ManagedFileState = "missing" | "safe" | "unsafe";

function managedFileState(path: string): ManagedFileState {
  let stat: NodeFS.Stats;
  try {
    stat = NodeFS.lstatSync(path);
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === "ENOENT" ? "missing" : "unsafe";
  }
  return isOwnedFile(stat) ? "safe" : "unsafe";
}

function copyManagedFile(source: string, target: string): void {
  if (managedFileState(target) === "unsafe") return;
  const temporary = `${target}.${process.pid}.${NodeCrypto.randomBytes(8).toString("hex")}.tmp`;
  try {
    // COPYFILE_EXCL prevents a pre-created temporary symlink from redirecting
    // copyFileSync before the atomic rename replaces the destination.
    NodeFS.copyFileSync(source, temporary, NodeFS.constants.COPYFILE_EXCL);
    NodeFS.chmodSync(temporary, 0o600);
    NodeFS.renameSync(temporary, target);
  } finally {
    try {
      NodeFS.unlinkSync(temporary);
    } catch {
      // The rename normally removed it.
    }
  }
}

/**
 * Copy host auth files and seed a private DB copy that retains credentials but
 * drops host sessions. Safe to call repeatedly: existing managed DB is kept.
 * Auth files that disappear and an existing host DB's empty credential table
 * revoke authority for the isolated instance too.
 *
 * @internal exported for tests
 */
export function seedOpenCode2ManagedDataHome(
  managedDataHome: string,
  hostDataHome: string = openCode2HostDataHome(),
): void {
  const hostOpenCode = NodePath.join(hostDataHome, "opencode");
  const managedOpenCode = NodePath.join(managedDataHome, "opencode");
  if (!ensureManagedDirectory(managedDataHome) || !ensureManagedDirectory(managedOpenCode)) {
    return;
  }

  for (const name of OPENCODE2_AUTH_FILES) {
    const source = NodePath.join(hostOpenCode, name);
    const target = NodePath.join(managedOpenCode, name);
    if (!NodeFS.existsSync(source)) {
      try {
        if (managedFileState(target) === "safe") NodeFS.unlinkSync(target);
      } catch {
        // Best-effort revoke: a locked managed auth file should not block spawn.
      }
      continue;
    }
    try {
      copyManagedFile(source, target);
    } catch {
      // Best-effort: a locked or unreadable host auth file should not block spawn.
    }
  }

  const hostDb = NodePath.join(hostOpenCode, "opencode.db");
  const managedDb = NodePath.join(managedOpenCode, "opencode.db");
  const managedState = managedFileState(managedDb);
  if (managedState === "unsafe") return;
  // A missing host database can be transient during an upgrade or migration.
  // Preserve the last known credential snapshot; an existing, readable host DB
  // with an empty credential table remains the authoritative logout signal.
  if (!NodeFS.existsSync(hostDb)) return;

  let temporaryDb: string | undefined;
  const removeTemporaryDb = () => {
    if (temporaryDb === undefined) return;
    try {
      NodeFS.unlinkSync(temporaryDb);
    } catch {
      // The file may already have been published or cleaned up.
    }
    temporaryDb = undefined;
  };
  try {
    if (managedState === "missing") {
      // First managed spawn: take a transactionally consistent host snapshot
      // (VACUUM INTO, not a live main-db file copy without WAL companions),
      // then prune sessions so we keep credentials without replaying host chats.
      temporaryDb = `${managedDb}.${process.pid}.${NodeCrypto.randomBytes(8).toString("hex")}.tmp`;
      const hostSnapshot = new NodeSqlite.DatabaseSync(hostDb, { readOnly: true });
      try {
        hostSnapshot.exec(`VACUUM INTO ${sqlQuoteLiteral(temporaryDb)}`);
      } finally {
        hostSnapshot.close();
      }
      if (!hardenManagedPath(temporaryDb, false, 0o600)) {
        removeTemporaryDb();
        return;
      }
      const db = new NodeSqlite.DatabaseSync(temporaryDb);
      try {
        for (const table of OPENCODE2_SESSION_TABLES) {
          try {
            db.exec(`DELETE FROM ${table}`);
          } catch {
            // Table may not exist on older schemas.
          }
        }
        try {
          db.exec("VACUUM");
        } catch {
          // Optional.
        }
      } finally {
        db.close();
      }
      if (!hardenManagedPath(temporaryDb, false, 0o600)) {
        removeTemporaryDb();
        return;
      }
      if (managedFileState(managedDb) === "missing") {
        try {
          // A hard link publishes the complete, pruned database without
          // replacing a database another startup created first.
          NodeFS.linkSync(temporaryDb, managedDb);
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        }
      }
      removeTemporaryDb();
      return;
    }

    // Subsequent spawns: refresh credential rows from the host DB so new API
    // keys / oauth tokens land without wiping managed sessions. Empty host
    // rows clear managed credentials so host logout revokes them.
    if (!hardenManagedPath(managedDb, false, 0o600)) return;
    const host = new NodeSqlite.DatabaseSync(hostDb, { readOnly: true });
    const managed = new NodeSqlite.DatabaseSync(managedDb);
    try {
      const rows = host.prepare("SELECT * FROM credential").all() as Array<
        Record<string, NodeSqlite.SQLInputValue>
      >;
      const columns = rows.length > 0 ? Object.keys(rows[0] ?? {}) : [];
      managed.exec("BEGIN IMMEDIATE");
      try {
        managed.exec("DELETE FROM credential");
        if (rows.length > 0 && columns.length > 0) {
          const placeholders = columns.map(() => "?").join(", ");
          const insert = managed.prepare(
            `INSERT INTO credential (${columns.join(", ")}) VALUES (${placeholders})`,
          );
          for (const row of rows) {
            insert.run(...columns.map((column) => row[column] ?? null));
          }
        }
        managed.exec("COMMIT");
      } catch (error) {
        try {
          managed.exec("ROLLBACK");
        } catch {
          // Connection may already be aborted.
        }
        throw error;
      }
    } finally {
      host.close();
      managed.close();
    }
  } catch {
    removeTemporaryDb();
    // If seed fails, leave auth.json bridge only; free models still work.
    if (!NodeFS.existsSync(managedDb)) return;
  }
}

export function applyOpenCode2ProviderEnvironment(
  settings: Pick<OpenCode2Settings, "backgroundSubagents" | "serverUrl">,
  environment: NodeJS.ProcessEnv,
  instanceId?: string,
): NodeJS.ProcessEnv {
  if (settings.serverUrl.trim().length > 0) {
    return environment;
  }

  const hostDataHome = openCode2HostDataHome(environment);
  const preferredStateRoot = openCode2ManagedStateRoot(environment, instanceId);
  migrateLegacyManagedStateRoot(preferredStateRoot, environment, instanceId);
  const preferredHomes = prepareManagedStateRoot(preferredStateRoot);
  const stateRoot =
    preferredHomes === undefined
      ? fallbackManagedStateRoot(preferredStateRoot, environment)
      : preferredStateRoot;
  if (stateRoot === undefined) {
    throw new Error("Unable to create a private OpenCode 2 managed-state root.");
  }
  const managedHomes =
    stateRoot === preferredStateRoot ? preferredHomes : prepareManagedStateRoot(stateRoot);
  if (managedHomes === undefined) {
    throw new Error("Unable to secure the private OpenCode 2 managed-state directories.");
  }
  seedOpenCode2ManagedDataHome(managedHomes.dataHome, hostDataHome);

  // Keep the host XDG_CONFIG_HOME so user provider config (e.g. llama.cpp)
  // still applies. Isolate only state (server password) and data (db/auth).
  return {
    ...environment,
    [OPENCODE2_BACKGROUND_SUBAGENTS_ENV]: settings.backgroundSubagents ? "true" : "false",
    XDG_DATA_HOME: managedHomes.dataHome,
    XDG_STATE_HOME: managedHomes.stateHome,
  };
}
