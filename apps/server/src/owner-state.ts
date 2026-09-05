import { D1Client } from "@effect/sql-d1";
import { Effect, Option, Schema } from "effect";
import * as Reactivity from "effect/unstable/reactivity/Reactivity";

const Sha256Digest = Schema.String.check(Schema.isPattern(/^[0-9a-f]{64}$/));
const AuthorizationHeader = Schema.String.check(Schema.isPattern(/^Bearer trigo_v1_[0-9a-f]{64}$/));
const CanonicalUuidV4 = Schema.String.check(
  Schema.isPattern(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
);
const ArchiveId = CanonicalUuidV4.pipe(Schema.brand("ArchiveId"));
const OwnerOperationId = CanonicalUuidV4.pipe(Schema.brand("OwnerOperationId"));
const PositiveGeneration = Schema.Finite.check(Schema.isInt(), Schema.isGreaterThanOrEqualTo(1));
const decodeSha256Digest = Schema.decodeUnknownOption(Sha256Digest);
const decodeAuthorizationHeader = Schema.decodeUnknownOption(AuthorizationHeader);

export interface InitializeOwnerOperation {
  readonly kind: "initialize";
  readonly operationId: string;
  readonly archiveId: string;
  readonly verifierSha256: string;
  readonly now: string;
}

export interface RotateOwnerOperation {
  readonly kind: "rotate";
  readonly operationId: string;
  readonly expectedGeneration: number;
  readonly verifierSha256: string;
  readonly now: string;
}

export interface RevokeOwnerOperation {
  readonly kind: "revoke";
  readonly operationId: string;
  readonly expectedGeneration: number;
  readonly now: string;
}

export type OwnerOperation = InitializeOwnerOperation | RotateOwnerOperation | RevokeOwnerOperation;

export interface OwnerOperationResult {
  readonly archiveId: string;
  readonly generation: number;
  readonly operationId: string;
  readonly state: "active" | "revoked";
}

export class OwnerOperationConflict extends Schema.TaggedError<OwnerOperationConflict>()(
  "OwnerState.OwnerOperationConflict",
  {
    operationId: Schema.String,
    message: Schema.String,
  },
) {}

export class OwnerPersistenceError extends Schema.TaggedError<OwnerPersistenceError>()(
  "OwnerState.OwnerPersistenceError",
  {
    operation: Schema.String,
    cause: Schema.Defect(),
  },
) {}

export class OwnerAuthenticationError extends Schema.TaggedError<OwnerAuthenticationError>()(
  "OwnerState.OwnerAuthenticationError",
  {
    message: Schema.String,
  },
) {}

export interface OwnerContext {
  readonly archiveId: string;
  readonly credentialGeneration: number;
}

export const hashOwnerToken = Effect.fn("OwnerState.hashToken")(function* (token: string) {
  const bytes = new TextEncoder().encode(token);
  const digest = yield* Effect.promise(() => crypto.subtle.digest("SHA-256", bytes));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
});

const OwnerAuthenticationRow = Schema.Struct({
  archive_id: ArchiveId,
  generation: PositiveGeneration,
});

const decodeOwnerAuthenticationRow = Schema.decodeUnknownEffect(OwnerAuthenticationRow);

export const authenticateOwner = Effect.fn("OwnerState.authenticateOwner")(function* (
  db: Pick<D1Database, "prepare">,
  request: Request,
) {
  const authorization = decodeAuthorizationHeader(request.headers.get("authorization"));
  if (Option.isNone(authorization))
    return yield* new OwnerAuthenticationError({
      message: "Provide the current Trigo owner token.",
    });
  const token = authorization.value.slice("Bearer ".length);
  const verifierSha256 = yield* hashOwnerToken(token);
  const result = yield* Effect.tryPromise({
    try: () =>
      db
        .prepare(
          `SELECT identity.archive_id, state.generation
           FROM trigo_archive_identity AS identity
           JOIN trigo_owner_credential_state AS state USING (singleton)
           WHERE identity.singleton = 1
             AND state.revoked = 0
             AND state.verifier_sha256 = ?`,
        )
        .bind(verifierSha256)
        .all(),
    catch: (cause) =>
      new OwnerPersistenceError({
        operation: "OwnerState.authenticateOwner",
        cause,
      }),
  });
  const persisted = result.results[0];
  if (persisted === undefined)
    return yield* new OwnerAuthenticationError({
      message: "Provide the current Trigo owner token.",
    });
  const row = yield* decodeOwnerAuthenticationRow(persisted).pipe(
    Effect.mapError(
      (cause) =>
        new OwnerPersistenceError({
          operation: "OwnerState.authenticateOwner.decode",
          cause,
        }),
    ),
  );
  return {
    archiveId: row.archive_id,
    credentialGeneration: row.generation,
  } satisfies OwnerContext;
});

const OwnerStateRow = Schema.Struct({
  archive_id: ArchiveId,
  generation: PositiveGeneration,
  operation_id: OwnerOperationId,
  revoked: Schema.Finite.check(Schema.isInt(), Schema.isBetween({ minimum: 0, maximum: 1 })),
});

const decodeOwnerStateRow = Schema.decodeUnknownEffect(OwnerStateRow);

export interface OwnerOperationQuery {
  readonly sql: string;
  readonly params: ReadonlyArray<string>;
}

export function ownerOperationQueries(input: OwnerOperation): ReadonlyArray<OwnerOperationQuery> {
  if (input.kind === "initialize")
    return [
      {
        sql: `INSERT OR IGNORE INTO trigo_archive_identity
          (singleton, archive_id, created_at)
        VALUES (1, ?, ?)`,
        params: [input.archiveId, input.now],
      },
      {
        sql: `INSERT OR IGNORE INTO trigo_owner_credential_state
          (singleton, generation, verifier_sha256, revoked, current_operation_id, updated_at)
        SELECT 1, 1, ?, 0, ?, ?
        FROM trigo_archive_identity
        WHERE singleton = 1 AND archive_id = ?`,
        params: [input.verifierSha256, input.operationId, input.now, input.archiveId],
      },
      {
        sql: `INSERT OR IGNORE INTO trigo_owner_credential_operations
          (operation_id, kind, archive_id, generation, verifier_sha256, created_at)
        SELECT ?, 'initialize', archive_id, 1, ?, ?
        FROM trigo_archive_identity
        JOIN trigo_owner_credential_state USING (singleton)
        WHERE singleton = 1
          AND archive_id = ?
          AND generation = 1
          AND verifier_sha256 = ?
          AND revoked = 0
          AND current_operation_id = ?`,
        params: [
          input.operationId,
          input.verifierSha256,
          input.now,
          input.archiveId,
          input.verifierSha256,
          input.operationId,
        ],
      },
      {
        sql: `SELECT identity.archive_id, state.generation,
          state.current_operation_id AS operation_id, state.revoked
        FROM trigo_archive_identity AS identity
        JOIN trigo_owner_credential_state AS state USING (singleton)
        JOIN trigo_owner_credential_operations AS operation
          ON operation.operation_id = state.current_operation_id
        WHERE identity.singleton = 1
          AND operation.kind = 'initialize'
          AND operation.archive_id = ?
          AND operation.verifier_sha256 = ?
          AND operation.operation_id = ?`,
        params: [input.archiveId, input.verifierSha256, input.operationId],
      },
    ];

  const nextGeneration = input.expectedGeneration + 1;
  if (input.kind === "rotate")
    return [
      {
        sql: `UPDATE trigo_owner_credential_state
          SET generation = ?,
              verifier_sha256 = ?,
              revoked = 0,
              current_operation_id = ?,
              updated_at = ?
          WHERE singleton = 1
            AND (
              (
                generation = ?
                AND NOT EXISTS (
                  SELECT 1 FROM trigo_owner_credential_operations
                  WHERE operation_id = ?
                )
              )
              OR (
                generation = ?
                AND verifier_sha256 = ?
                AND revoked = 0
                AND current_operation_id = ?
              )
            )`,
        params: [
          String(nextGeneration),
          input.verifierSha256,
          input.operationId,
          input.now,
          String(input.expectedGeneration),
          input.operationId,
          String(nextGeneration),
          input.verifierSha256,
          input.operationId,
        ],
      },
      {
        sql: `INSERT OR IGNORE INTO trigo_owner_credential_operations
          (operation_id, kind, archive_id, generation, verifier_sha256, created_at)
        SELECT ?, 'rotate', identity.archive_id,
               state.generation, state.verifier_sha256, ?
        FROM trigo_archive_identity AS identity
        JOIN trigo_owner_credential_state AS state USING (singleton)
        WHERE identity.singleton = 1
          AND state.generation = ?
          AND state.verifier_sha256 = ?
          AND state.revoked = 0
          AND state.current_operation_id = ?`,
        params: [
          input.operationId,
          input.now,
          String(nextGeneration),
          input.verifierSha256,
          input.operationId,
        ],
      },
      {
        sql: `SELECT identity.archive_id, state.generation,
          state.current_operation_id AS operation_id, state.revoked
        FROM trigo_archive_identity AS identity
        JOIN trigo_owner_credential_state AS state USING (singleton)
        JOIN trigo_owner_credential_operations AS operation
          ON operation.operation_id = state.current_operation_id
        WHERE identity.singleton = 1
          AND operation.kind = 'rotate'
          AND operation.generation = ?
          AND operation.verifier_sha256 = ?
          AND operation.operation_id = ?`,
        params: [String(nextGeneration), input.verifierSha256, input.operationId],
      },
    ];

  return [
    {
      sql: `UPDATE trigo_owner_credential_state
        SET generation = ?,
            verifier_sha256 = NULL,
            revoked = 1,
            current_operation_id = ?,
            updated_at = ?
        WHERE singleton = 1
          AND (
            (
              generation = ?
              AND NOT EXISTS (
                SELECT 1 FROM trigo_owner_credential_operations
                WHERE operation_id = ?
              )
            )
            OR (
              generation = ?
              AND verifier_sha256 IS NULL
              AND revoked = 1
              AND current_operation_id = ?
            )
          )`,
      params: [
        String(nextGeneration),
        input.operationId,
        input.now,
        String(input.expectedGeneration),
        input.operationId,
        String(nextGeneration),
        input.operationId,
      ],
    },
    {
      sql: `INSERT OR IGNORE INTO trigo_owner_credential_operations
        (operation_id, kind, archive_id, generation, verifier_sha256, created_at)
      SELECT ?, 'revoke', identity.archive_id,
             state.generation, NULL, ?
      FROM trigo_archive_identity AS identity
      JOIN trigo_owner_credential_state AS state USING (singleton)
      WHERE identity.singleton = 1
        AND state.generation = ?
        AND state.verifier_sha256 IS NULL
        AND state.revoked = 1
        AND state.current_operation_id = ?`,
      params: [input.operationId, input.now, String(nextGeneration), input.operationId],
    },
    {
      sql: `SELECT identity.archive_id, state.generation,
        state.current_operation_id AS operation_id, state.revoked
      FROM trigo_archive_identity AS identity
      JOIN trigo_owner_credential_state AS state USING (singleton)
      JOIN trigo_owner_credential_operations AS operation
        ON operation.operation_id = state.current_operation_id
      WHERE identity.singleton = 1
        AND operation.kind = 'revoke'
        AND operation.generation = ?
        AND operation.verifier_sha256 IS NULL
        AND operation.operation_id = ?`,
      params: [String(nextGeneration), input.operationId],
    },
  ];
}

export const applyOwnerOperation = Effect.fn("OwnerState.applyOperation")(function* (
  db: D1Database,
  input: OwnerOperation,
) {
  if (input.kind !== "revoke" && Option.isNone(decodeSha256Digest(input.verifierSha256)))
    return yield* new OwnerOperationConflict({
      operationId: input.operationId,
      message: "Owner verifier must be a lowercase SHA-256 digest",
    });

  const program = Effect.gen(function* () {
    const sql = yield* D1Client.make({ db });
    const persistenceError = (cause: unknown) =>
      new OwnerPersistenceError({
        operation: "OwnerState.applyOperation",
        cause,
      });
    const queries = ownerOperationQueries(input);
    const results = yield* sql
      .batch(queries.map((query) => sql.unsafe(query.sql, query.params)))
      .pipe(Effect.mapError(persistenceError));
    const rows = results[results.length - 1] ?? [];
    const persisted = rows[0];
    if (persisted === undefined)
      return yield* new OwnerOperationConflict({
        operationId: input.operationId,
        message: "Owner operation conflicts with the current credential generation or content",
      });
    const row = yield* decodeOwnerStateRow(persisted).pipe(Effect.mapError(persistenceError));
    return {
      archiveId: row.archive_id,
      generation: row.generation,
      operationId: row.operation_id,
      state: row.revoked === 0 ? ("active" as const) : ("revoked" as const),
    };
  }).pipe(Effect.provide(Reactivity.layer));

  return yield* Effect.scoped(program);
});
