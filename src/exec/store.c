#define _GNU_SOURCE

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <sqlite3.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct {
    void *handle;
    int (*open_v2)(const char *, sqlite3 **, int, const char *);
    int (*close)(sqlite3 *);
    int (*exec)(sqlite3 *, const char *, int (*)(void *, int, char **, char **), void *, char **);
    void (*free_fn)(void *);
    int (*prepare_statement)(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
    int (*bind_text)(sqlite3_stmt *, int, const char *, int, void (*)(void *));
    int (*bind_int64)(sqlite3_stmt *, int, sqlite3_int64);
    int (*step)(sqlite3_stmt *);
    sqlite3_int64 (*column_int64)(sqlite3_stmt *, int);
    const unsigned char *(*column_text)(sqlite3_stmt *, int);
    int (*finalize)(sqlite3_stmt *);
} choir_sqlite_api;

static choir_sqlite_api choir_sqlite;
static pthread_once_t choir_sqlite_once = PTHREAD_ONCE_INIT;
static int choir_sqlite_load_result = -1;

static void choir_sqlite_load_once(void) {
    void *handle = dlopen("libsqlite3.so.0", RTLD_NOW | RTLD_LOCAL);
    if (handle == NULL) {
        handle = dlopen("libsqlite3.so", RTLD_NOW | RTLD_LOCAL);
    }
    if (handle == NULL) {
        return;
    }
#define CHOIR_SQLITE_LOAD(field, symbol)                                      \
    do {                                                                       \
        *(void **)(&choir_sqlite.field) = dlsym(handle, symbol);               \
        if (choir_sqlite.field == NULL) {                                      \
            dlclose(handle);                                                   \
            memset(&choir_sqlite, 0, sizeof(choir_sqlite));                    \
            return;                                                            \
        }                                                                      \
    } while (0)
    CHOIR_SQLITE_LOAD(open_v2, "sqlite3_open_v2");
    CHOIR_SQLITE_LOAD(close, "sqlite3_close");
    CHOIR_SQLITE_LOAD(exec, "sqlite3_exec");
    CHOIR_SQLITE_LOAD(free_fn, "sqlite3_free");
    CHOIR_SQLITE_LOAD(prepare_statement, "sqlite3_prepare_v2");
    CHOIR_SQLITE_LOAD(bind_text, "sqlite3_bind_text");
    CHOIR_SQLITE_LOAD(bind_int64, "sqlite3_bind_int64");
    CHOIR_SQLITE_LOAD(step, "sqlite3_step");
    CHOIR_SQLITE_LOAD(column_int64, "sqlite3_column_int64");
    CHOIR_SQLITE_LOAD(column_text, "sqlite3_column_text");
    CHOIR_SQLITE_LOAD(finalize, "sqlite3_finalize");
#undef CHOIR_SQLITE_LOAD
    choir_sqlite.handle = handle;
    choir_sqlite_load_result = 0;
}

static int choir_sqlite_load(void) {
    if (pthread_once(&choir_sqlite_once, choir_sqlite_load_once) != 0) {
        return -1;
    }
    return choir_sqlite_load_result;
}

static char *choir_store_copy_string(const char *value, int len) {
    if (value == NULL || len < 0) {
        return NULL;
    }
    char *copy = (char *)malloc((size_t)len + 1U);
    if (copy == NULL) {
        return NULL;
    }
    memcpy(copy, value, (size_t)len);
    copy[len] = '\0';
    return copy;
}

static int choir_sqlite_exec_rc(sqlite3 *db, const char *sql) {
    char *error = NULL;
    int rc = choir_sqlite.exec(db, sql, NULL, NULL, &error);
    if (error != NULL) {
        choir_sqlite.free_fn(error);
    }
    return rc;
}

static int choir_sqlite_exec(sqlite3 *db, const char *sql) {
    return choir_sqlite_exec_rc(db, sql) == SQLITE_OK ? 0 : -1;
}

/*
 * Connection cache. Each store entry point used to open and close a fresh
 * connection, discarding the page cache per call and — because no busy
 * handler was ever installed — turning any cross-process write collision
 * between choird and the goal worker into an immediate hard failure.
 * Connections are cached per path for the process lifetime; entries are
 * recycled round-robin so test binaries touching many temp stores stay
 * bounded. Handles are opened FULLMUTEX and every FFI call runs a complete
 * operation, so sharing a cached handle is safe.
 */
#define CHOIR_SQLITE_CACHE_SLOTS 8

typedef struct {
    char *path;
    sqlite3 *db;
    /* Whether the schema batch has already run on this connection. Connections
     * are pooled, so re-executing PRAGMAs and CREATE TABLE IF NOT EXISTS on an
     * already-prepared one is pure per-tick work. A connection evicted from
     * the pool loses the flag with the slot, which is correct: the replacement
     * genuinely has not been prepared. */
    int schema_ready;
} choir_sqlite_cached;

static choir_sqlite_cached choir_sqlite_cache[CHOIR_SQLITE_CACHE_SLOTS];
static unsigned choir_sqlite_cache_next = 0;
static pthread_mutex_t choir_sqlite_cache_mutex = PTHREAD_MUTEX_INITIALIZER;

static int choir_sqlite_configure(sqlite3 *db) {
    return choir_sqlite_exec(
        db,
        "PRAGMA busy_timeout=5000;"
        "PRAGMA synchronous=FULL;"
        "PRAGMA foreign_keys=ON;"
    );
}

static int choir_sqlite_acquire(const char *path, int path_len, sqlite3 **db) {
    if (choir_sqlite_load() != 0) {
        return -1;
    }
    char *copy = choir_store_copy_string(path, path_len);
    if (copy == NULL) {
        return -1;
    }
    pthread_mutex_lock(&choir_sqlite_cache_mutex);
    for (int i = 0; i < CHOIR_SQLITE_CACHE_SLOTS; ++i) {
        if (choir_sqlite_cache[i].path != NULL &&
            strcmp(choir_sqlite_cache[i].path, copy) == 0) {
            *db = choir_sqlite_cache[i].db;
            pthread_mutex_unlock(&choir_sqlite_cache_mutex);
            free(copy);
            return 0;
        }
    }
    sqlite3 *opened = NULL;
    int rc = choir_sqlite.open_v2(
        copy,
        &opened,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        NULL
    );
    if (rc != SQLITE_OK || choir_sqlite_configure(opened) != 0) {
        if (opened != NULL) {
            choir_sqlite.close(opened);
        }
        pthread_mutex_unlock(&choir_sqlite_cache_mutex);
        free(copy);
        return -1;
    }
    choir_sqlite_cached *slot =
        &choir_sqlite_cache[choir_sqlite_cache_next % CHOIR_SQLITE_CACHE_SLOTS];
    choir_sqlite_cache_next += 1;
    if (slot->path != NULL) {
        choir_sqlite.close(slot->db);
        free(slot->path);
    }
    slot->path = copy;
    slot->db = opened;
    /* A replaced slot must not inherit the evicted connection's readiness: this
     * connection has had nothing applied to it. */
    slot->schema_ready = 0;
    pthread_mutex_unlock(&choir_sqlite_cache_mutex);
    *db = opened;
    return 0;
}

/* Drop any pooled connection for this path.
 *
 * The control-state reset deletes and recreates workflow.db at the same path
 * inside one daemon process. A pooled connection would still refer to the
 * unlinked inode, so everything after the reset would read and write a file
 * nothing else can see. Callers that replace a store must forget it first. */
int choir_state_store_forget(const char *path, int path_len) {
    char *copy = choir_store_copy_string(path, path_len);
    if (copy == NULL) {
        return -1;
    }
    pthread_mutex_lock(&choir_sqlite_cache_mutex);
    for (int i = 0; i < CHOIR_SQLITE_CACHE_SLOTS; ++i) {
        if (choir_sqlite_cache[i].path != NULL &&
            strcmp(choir_sqlite_cache[i].path, copy) == 0) {
            if (choir_sqlite.close != NULL) {
                choir_sqlite.close(choir_sqlite_cache[i].db);
            }
            free(choir_sqlite_cache[i].path);
            choir_sqlite_cache[i].path = NULL;
            choir_sqlite_cache[i].db = NULL;
            choir_sqlite_cache[i].schema_ready = 0;
        }
    }
    pthread_mutex_unlock(&choir_sqlite_cache_mutex);
    free(copy);
    return 0;
}

/* Whether this connection has already had the schema applied. */
static int choir_sqlite_schema_ready(sqlite3 *db) {
    int ready = 0;
    pthread_mutex_lock(&choir_sqlite_cache_mutex);
    for (int i = 0; i < CHOIR_SQLITE_CACHE_SLOTS; ++i) {
        if (choir_sqlite_cache[i].db == db) {
            ready = choir_sqlite_cache[i].schema_ready;
            break;
        }
    }
    pthread_mutex_unlock(&choir_sqlite_cache_mutex);
    return ready;
}

static void choir_sqlite_mark_schema_ready(sqlite3 *db) {
    pthread_mutex_lock(&choir_sqlite_cache_mutex);
    for (int i = 0; i < CHOIR_SQLITE_CACHE_SLOTS; ++i) {
        if (choir_sqlite_cache[i].db == db) {
            choir_sqlite_cache[i].schema_ready = 1;
            break;
        }
    }
    pthread_mutex_unlock(&choir_sqlite_cache_mutex);
}

/* The version of the DDL below.
 *
 * Bump this in the same edit that changes any statement in
 * `choir_state_store_schema`. It is the only signal that says the tables on
 * disk were built by a different DDL than the one this build's SQL is written
 * against, and there is no other: the durable-value generation digests the
 * record VALUES, which say nothing about table shape, and `CREATE TABLE IF NOT
 * EXISTS` silently accepts a table whose columns are not these. Without it,
 * adding a column here leaves every existing store reporting Current and
 * failing every query at runtime.
 *
 * It is stamped into `PRAGMA user_version` when the tables are created, so the
 * DDL and the number describing it are written together or not at all. Nothing
 * at runtime can check that: digesting the schema and comparing would mean a
 * reformatting authorized destroying every store. What holds the two together
 * is `choir_state_store_ddl_text`, which hands the DDL out so a test can pin
 * its digest against this number and fail the build when one moved without the
 * other.
 *
 * 0 is reserved and means "created before this was stamped at all". It is
 * adopted rather than reset, because every store that can hold 0 was created by
 * this exact DDL; from the first adoption on, the number is load-bearing. */
#define CHOIR_STATE_STORE_DDL_VERSION 1
#define CHOIR_STRINGIFY_INNER(value) #value
#define CHOIR_STRINGIFY(value) CHOIR_STRINGIFY_INNER(value)

/* The statements that build the control store, beside the version describing
 * them so neither can be edited without the other in view. */
static const char choir_state_store_schema[] =
    "PRAGMA journal_mode=WAL;"
    "PRAGMA synchronous=FULL;"
    "PRAGMA foreign_keys=ON;"
    "CREATE TABLE IF NOT EXISTS state_records("
    " record_key TEXT PRIMARY KEY NOT NULL,"
    " version INTEGER NOT NULL CHECK(version > 0),"
    " fencing_epoch INTEGER NOT NULL CHECK(fencing_epoch > 0),"
    " value_digest TEXT NOT NULL CHECK(length(value_digest) = 64)"
    ") STRICT;"
    "CREATE TABLE IF NOT EXISTS completion_outbox("
    " semantic_key TEXT PRIMARY KEY NOT NULL,"
    " payload_digest TEXT NOT NULL CHECK(length(payload_digest) = 64),"
    " record_key TEXT NOT NULL,"
    " state_version INTEGER NOT NULL CHECK(state_version > 0),"
    " fencing_epoch INTEGER NOT NULL CHECK(fencing_epoch > 0),"
    " state_value_digest TEXT NOT NULL CHECK(length(state_value_digest) = 64)"
    ") STRICT;"
    /* The schema generation lives in the store it describes. A sibling
     * marker file could be lost on its own, and its absence used to
     * authorize deleting the whole control store. */
    "CREATE TABLE IF NOT EXISTS control_metadata("
    " id INTEGER PRIMARY KEY CHECK(id = 1),"
    " generation TEXT NOT NULL"
    ") STRICT;";

int choir_state_store_ddl_version(void) {
    return CHOIR_STATE_STORE_DDL_VERSION;
}

/* Copy the DDL text into `buf`, returning the byte count written or -1 when
 * the buffer cannot hold it.
 *
 * The only caller is the test that digests it and refuses a DDL edit the
 * version did not follow. Nothing decides anything from this at runtime: a
 * digest over SQL text moves for whitespace, and this number authorizes
 * destroying the store. */
int choir_state_store_ddl_text(char *buf, int max_size) {
    size_t len = sizeof(choir_state_store_schema) - 1;
    if (buf == NULL || max_size < 0 || (size_t)max_size < len) {
        return -1;
    }
    memcpy(buf, choir_state_store_schema, len);
    return (int)len;
}

/* Whether this database holds no schema objects at all, i.e. the tables the
 * DDL above names are about to be created rather than found. Returns 1 for
 * empty, 0 for populated, -1 when the file is not a usable database. */
static int choir_sqlite_database_empty(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    int empty = -1;
    if (choir_sqlite.prepare_statement(
            db, "SELECT count(*) FROM sqlite_master", -1, &stmt, NULL
        ) == SQLITE_OK &&
        choir_sqlite.step(stmt) == SQLITE_ROW) {
        empty = choir_sqlite.column_int64(stmt, 0) == 0 ? 1 : 0;
    }
    if (stmt != NULL) {
        choir_sqlite.finalize(stmt);
    }
    return empty;
}

int choir_state_store_init(const char *path, int path_len) {
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    /* The Goal tick calls this every second. The statements are idempotent, so
     * repeating them is harmless but not free: each one is parsed and run
     * against the pooled connection. */
    if (choir_sqlite_schema_ready(db)) {
        return 0;
    }
    /* Asked before the schema runs, because afterwards every database looks
     * populated. Only a database this call creates the tables in may be
     * stamped; stamping one that already had them would overwrite the very
     * evidence that its DDL is older than this build's. */
    int empty = choir_sqlite_database_empty(db);
    if (empty < 0) {
        return -1;
    }
    if (choir_sqlite_exec(db, choir_state_store_schema) != 0) {
        return -1;
    }
    if (empty == 1 &&
        choir_sqlite_exec(
            db,
            "PRAGMA user_version = " CHOIR_STRINGIFY(
                CHOIR_STATE_STORE_DDL_VERSION
            )
        ) != 0) {
        return -1;
    }
    choir_sqlite_mark_schema_ready(db);
    return 0;
}

/* Read the DDL version the store's tables were created under. Returns the
 * recorded version, 0 when the store predates the stamp, or -1 when the file
 * is not a usable database — the same three-way answer the generation read
 * gives, and for the same reason: an unreadable store and an older one call for
 * opposite decisions.
 *
 * `user_version` is a signed 32-bit field and sqlite accepts a negative one,
 * which nothing here can have written. Such a store reads as unreadable rather
 * than as some version, because a number this build's writer cannot produce is
 * not evidence about this build's DDL. */
int choir_state_store_read_ddl_version(const char *path, int path_len) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    int version = -1;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    /* `PRAGMA user_version` prepares against a file that is not a database at
     * all and only fails when stepped, so the same sqlite_master probe the
     * generation read uses decides readability first. */
    if (choir_sqlite_database_empty(db) < 0) {
        return -1;
    }
    if (choir_sqlite.prepare_statement(
            db, "PRAGMA user_version", -1, &stmt, NULL
        ) == SQLITE_OK &&
        choir_sqlite.step(stmt) == SQLITE_ROW) {
        sqlite3_int64 read = choir_sqlite.column_int64(stmt, 0);
        version = read < 0 ? -1 : (int)read;
    }
    if (stmt != NULL) {
        choir_sqlite.finalize(stmt);
    }
    return version;
}

/* Stamp the DDL version onto a store whose tables this build has decided it
 * can serve. Used by the adoption path, which finds an unstamped store and
 * records what it answers to from now on. */
int choir_state_store_write_ddl_version(
    const char *path, int path_len, int version
) {
    sqlite3 *db = NULL;
    char statement[64];
    if (version < 0) {
        return -1;
    }
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    /* `PRAGMA user_version = ?` does not accept a bound parameter, so the
     * value is formatted in. It is an int by the signature, so there is nothing
     * here to inject. */
    if (snprintf(statement, sizeof(statement), "PRAGMA user_version = %d", version) < 0) {
        return -1;
    }
    return choir_sqlite_exec(db, statement);
}

/* Read the recorded schema generation. Returns the byte count written to buf,
 * 0 when the store records none, or -1 when the store cannot be opened. The
 * two are deliberately distinguishable: an unreadable store and one that
 * simply predates recording its generation call for opposite decisions. */
int choir_state_store_read_generation(
    const char *path, int path_len, char *buf, int max_size
) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    int written = 0;
    if (buf == NULL || max_size <= 0) {
        return -1;
    }
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    /* Distinguish "not a usable database" from "no metadata table yet". Both
     * fail to prepare the SELECT, and conflating them would adopt a corrupt
     * store as if it were simply an older one. */
    if (choir_sqlite.prepare_statement(
            db, "SELECT count(*) FROM sqlite_master", -1, &stmt, NULL
        ) != SQLITE_OK ||
        choir_sqlite.step(stmt) != SQLITE_ROW) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        return -1;
    }
    choir_sqlite.finalize(stmt);
    stmt = NULL;
    if (choir_sqlite.prepare_statement(
            db,
            "SELECT generation FROM control_metadata WHERE id = 1",
            -1,
            &stmt,
            NULL
        ) != SQLITE_OK) {
        /* The store is usable and simply predates the metadata table, which is
         * not an error and must not read as one. */
        return 0;
    }
    if (choir_sqlite.step(stmt) == SQLITE_ROW) {
        const unsigned char *text = choir_sqlite.column_text(stmt, 0);
        if (text != NULL) {
            int length = (int)strlen((const char *)text);
            if (length > max_size) {
                length = max_size;
            }
            memcpy(buf, text, (size_t)length);
            written = length;
        }
    }
    choir_sqlite.finalize(stmt);
    return written;
}

/* Smallest string strictly greater than every string starting with `prefix`,
 * for a half-open range scan. Increments the last byte that can be
 * incremented and drops the trailing 0xFF run; returns NULL when the prefix is
 * entirely 0xFF, which has no upper bound and must scan to the end. */
static char *choir_prefix_upper_bound(const char *prefix) {
    if (prefix == NULL) return NULL;
    size_t length = strlen(prefix);
    while (length > 0 && (unsigned char)prefix[length - 1] == 0xFF) {
        length--;
    }
    if (length == 0) return NULL;
    char *upper = (char *)malloc(length + 1);
    if (upper == NULL) return NULL;
    memcpy(upper, prefix, length);
    upper[length - 1] = (char)((unsigned char)upper[length - 1] + 1);
    upper[length] = '\0';
    return upper;
}

static int choir_sqlite_bind_text(sqlite3_stmt *stmt, int index, const char *value) {
    return choir_sqlite.bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK
               ? 0
               : -1;
}

/* Record the schema generation transactionally. */
int choir_state_store_write_generation(
    const char *path, int path_len, const char *generation
) {
    sqlite3 *db = NULL;
    if (generation == NULL) {
        return -1;
    }
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    if (choir_sqlite_exec(
            db,
            "CREATE TABLE IF NOT EXISTS control_metadata("
            " id INTEGER PRIMARY KEY CHECK(id = 1),"
            " generation TEXT NOT NULL"
            ") STRICT;"
        ) != 0 ||
        choir_sqlite_exec(db, "BEGIN IMMEDIATE") != 0) {
        return -1;
    }
    sqlite3_stmt *stmt = NULL;
    int failed = choir_sqlite.prepare_statement(
                     db,
                     "INSERT INTO control_metadata(id, generation) VALUES(1, ?) "
                     "ON CONFLICT(id) DO UPDATE SET generation = excluded.generation",
                     -1,
                     &stmt,
                     NULL
                 ) != SQLITE_OK;
    if (!failed) {
        failed = choir_sqlite_bind_text(stmt, 1, generation) != 0 ||
                 choir_sqlite.step(stmt) != SQLITE_DONE;
        choir_sqlite.finalize(stmt);
    }
    if (failed || choir_sqlite_exec(db, "COMMIT") != 0) {
        choir_sqlite_exec(db, "ROLLBACK");
        return -1;
    }
    return 0;
}

/*
 * Fencing generation counter. `choir serve` mints (increments) the epoch once
 * per daemon generation while holding the instance lock; the goal worker it
 * spawns reads the same value. Records written by a generation carry its
 * epoch, so a surviving process from an older generation is rejected by the
 * stale-fence gate as soon as the new generation adopts a record.
 */
static long long choir_state_store_epoch_row(sqlite3 *db) {
    sqlite3_stmt *stmt = NULL;
    long long epoch = -1;
    if (choir_sqlite.prepare_statement(
            db,
            "SELECT epoch FROM fencing_generation WHERE id = 1",
            -1,
            &stmt,
            NULL
        ) == SQLITE_OK &&
        choir_sqlite.step(stmt) == SQLITE_ROW) {
        epoch = (long long)choir_sqlite.column_int64(stmt, 0);
    }
    if (stmt != NULL) choir_sqlite.finalize(stmt);
    return epoch;
}

long long choir_state_store_mint_epoch(const char *path, int path_len) {
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    if (choir_sqlite_exec(
            db,
            "CREATE TABLE IF NOT EXISTS fencing_generation("
            " id INTEGER PRIMARY KEY CHECK(id = 1),"
            " epoch INTEGER NOT NULL CHECK(epoch > 0)"
            ") STRICT;"
        ) != 0 ||
        choir_sqlite_exec(db, "BEGIN IMMEDIATE") != 0) {
        return -1;
    }
    if (choir_sqlite_exec(
            db,
            "INSERT INTO fencing_generation(id, epoch) VALUES(1, 1) "
            "ON CONFLICT(id) DO UPDATE SET epoch = epoch + 1"
        ) != 0) {
        choir_sqlite_exec(db, "ROLLBACK");
        return -1;
    }
    long long epoch = choir_state_store_epoch_row(db);
    if (epoch <= 0 || choir_sqlite_exec(db, "COMMIT") != 0) {
        choir_sqlite_exec(db, "ROLLBACK");
        return -1;
    }
    return epoch;
}

long long choir_state_store_read_epoch(const char *path, int path_len) {
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        return -1;
    }
    return choir_state_store_epoch_row(db);
}

static int choir_sqlite_read_outbox_digest(
    sqlite3 *db,
    const char *semantic_key,
    char *digest,
    size_t digest_size
) {
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT payload_digest FROM completion_outbox WHERE semantic_key = ?1";
    if (choir_sqlite.prepare_statement(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, semantic_key) != 0) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        return -1;
    }
    int step = choir_sqlite.step(stmt);
    int result = 0;
    if (step == SQLITE_ROW) {
        const unsigned char *value = choir_sqlite.column_text(stmt, 0);
        if (value == NULL || strlen((const char *)value) + 1U > digest_size) {
            result = -1;
        } else {
            strcpy(digest, (const char *)value);
            result = 1;
        }
    } else if (step != SQLITE_DONE) {
        result = -1;
    }
    choir_sqlite.finalize(stmt);
    return result;
}

static int choir_sqlite_read_outbox_transition(
    sqlite3 *db,
    const char *semantic_key,
    char *payload_digest,
    size_t payload_digest_size,
    char *record_key,
    size_t record_key_size,
    sqlite3_int64 *state_version,
    sqlite3_int64 *fence,
    char *state_digest,
    size_t state_digest_size
) {
    sqlite3_stmt *stmt = NULL;
    const char *sql =
        "SELECT payload_digest, record_key, state_version, fencing_epoch, "
        "state_value_digest FROM completion_outbox WHERE semantic_key = ?1";
    if (choir_sqlite.prepare_statement(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, semantic_key) != 0) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        return -1;
    }
    int step = choir_sqlite.step(stmt);
    int result = 0;
    if (step == SQLITE_ROW) {
        const unsigned char *payload = choir_sqlite.column_text(stmt, 0);
        const unsigned char *key = choir_sqlite.column_text(stmt, 1);
        const unsigned char *value = choir_sqlite.column_text(stmt, 4);
        if (payload == NULL || key == NULL || value == NULL ||
            strlen((const char *)payload) + 1U > payload_digest_size ||
            strlen((const char *)key) + 1U > record_key_size ||
            strlen((const char *)value) + 1U > state_digest_size) {
            result = -1;
        } else {
            strcpy(payload_digest, (const char *)payload);
            strcpy(record_key, (const char *)key);
            *state_version = choir_sqlite.column_int64(stmt, 2);
            *fence = choir_sqlite.column_int64(stmt, 3);
            strcpy(state_digest, (const char *)value);
            result = 1;
        }
    } else if (step != SQLITE_DONE) {
        result = -1;
    }
    choir_sqlite.finalize(stmt);
    return result;
}

static int choir_sqlite_read_state_values(
    sqlite3 *db,
    const char *record_key,
    sqlite3_int64 *version,
    sqlite3_int64 *fence,
    char *digest,
    size_t digest_size
) {
    sqlite3_stmt *stmt = NULL;
    const char *sql =
        "SELECT version, fencing_epoch, value_digest FROM state_records WHERE record_key = ?1";
    if (choir_sqlite.prepare_statement(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, record_key) != 0) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        return -1;
    }
    int step = choir_sqlite.step(stmt);
    int result = 0;
    if (step == SQLITE_ROW) {
        const unsigned char *value = choir_sqlite.column_text(stmt, 2);
        if (value == NULL || strlen((const char *)value) + 1U > digest_size) {
            result = -1;
        } else {
            *version = choir_sqlite.column_int64(stmt, 0);
            *fence = choir_sqlite.column_int64(stmt, 1);
            strcpy(digest, (const char *)value);
            result = 1;
        }
    } else if (step != SQLITE_DONE) {
        result = -1;
    }
    choir_sqlite.finalize(stmt);
    return result;
}

/*
 * Result codes:
 * 0 committed, 1 idempotent replay, 2 version conflict, 3 stale fence,
 * 4 semantic conflict, 5 fault rollback, 6 storage failure,
 * 7 committed but acknowledgment was deliberately lost,
 * 8 guarded precondition conflict,
 * 9 lock acquisition timed out (SQLITE_BUSY after busy_timeout; retryable).
 */
int choir_state_store_commit(
    const char *path,
    int path_len,
    const char *record_key,
    int record_key_len,
    int has_expected_version,
    int expected_version,
    int next_version,
    int64_t fencing_epoch,
    const char *value_digest,
    int value_digest_len,
    const char *semantic_key,
    int semantic_key_len,
    const char *payload_digest,
    int payload_digest_len,
    int fault_point,
    int has_precondition,
    const char *precondition_key,
    int precondition_key_len,
    int precondition_version,
    int64_t precondition_fencing_epoch,
    const char *precondition_digest,
    int precondition_digest_len
) {
    char *key = choir_store_copy_string(record_key, record_key_len);
    char *value = choir_store_copy_string(value_digest, value_digest_len);
    char *semantic = choir_store_copy_string(semantic_key, semantic_key_len);
    char *payload = choir_store_copy_string(payload_digest, payload_digest_len);
    char *guard_key = has_precondition
        ? choir_store_copy_string(precondition_key, precondition_key_len)
        : NULL;
    char *guard_digest = has_precondition
        ? choir_store_copy_string(precondition_digest, precondition_digest_len)
        : NULL;
    if (key == NULL || value == NULL || semantic == NULL || payload == NULL ||
        (has_precondition && (guard_key == NULL || guard_digest == NULL))) {
        free(key); free(value); free(semantic); free(payload);
        free(guard_key); free(guard_digest);
        return 6;
    }
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        free(key); free(value); free(semantic); free(payload);
        free(guard_key); free(guard_digest);
        return 6;
    }
    int begin_rc = choir_sqlite_exec_rc(db, "BEGIN IMMEDIATE");
    if (begin_rc != SQLITE_OK) {
        free(key); free(value); free(semantic); free(payload);
        free(guard_key); free(guard_digest);
        return begin_rc == SQLITE_BUSY ? 9 : 6;
    }

    int result = 6;
    char existing_payload[65] = {0};
    char existing_key[1025] = {0};
    char existing_value[65] = {0};
    sqlite3_int64 existing_version = 0;
    sqlite3_int64 existing_fence = 0;
    int outbox_found = choir_sqlite_read_outbox_transition(
        db,
        semantic,
        existing_payload,
        sizeof(existing_payload),
        existing_key,
        sizeof(existing_key),
        &existing_version,
        &existing_fence,
        existing_value,
        sizeof(existing_value)
    );
    if (outbox_found < 0) goto rollback;
    if (outbox_found == 1) {
        if (strcmp(existing_payload, payload) == 0 &&
            strcmp(existing_key, key) == 0 &&
            existing_version == next_version &&
            existing_fence == fencing_epoch &&
            strcmp(existing_value, value) == 0) {
            result = 1;
        } else {
            result = 4;
        }
        goto rollback;
    }

    if (has_precondition) {
        sqlite3_int64 guard_version = 0;
        sqlite3_int64 guard_fence = 0;
        char observed_guard_digest[65] = {0};
        int guard_found = choir_sqlite_read_state_values(
            db,
            guard_key,
            &guard_version,
            &guard_fence,
            observed_guard_digest,
            sizeof(observed_guard_digest)
        );
        if (guard_found < 0) goto rollback;
        if (guard_found == 0 ||
            guard_version != precondition_version ||
            guard_fence != precondition_fencing_epoch ||
            strcmp(observed_guard_digest, guard_digest) != 0) {
            result = 8;
            goto rollback;
        }
    }

    sqlite3_int64 current_version = 0;
    sqlite3_int64 current_fence = 0;
    char current_digest[65] = {0};
    int state_found = choir_sqlite_read_state_values(
        db, key, &current_version, &current_fence, current_digest, sizeof(current_digest)
    );
    if (state_found < 0) goto rollback;
    if ((!has_expected_version && state_found == 1) ||
        (has_expected_version &&
         (state_found == 0 || current_version != expected_version))) {
        result = 2;
        goto rollback;
    }
    if (state_found == 1 && fencing_epoch < current_fence) {
        result = 3;
        goto rollback;
    }

    sqlite3_stmt *stmt = NULL;
    const char *mutation_sql = state_found == 0
        ? "INSERT INTO state_records(record_key, version, fencing_epoch, value_digest) VALUES(?1, ?2, ?3, ?4)"
        : "UPDATE state_records SET version = ?2, fencing_epoch = ?3, value_digest = ?4 WHERE record_key = ?1";
    if (choir_sqlite.prepare_statement(db, mutation_sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, key) != 0 ||
        choir_sqlite.bind_int64(stmt, 2, next_version) != SQLITE_OK ||
        choir_sqlite.bind_int64(stmt, 3, fencing_epoch) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 4, value) != 0 ||
        choir_sqlite.step(stmt) != SQLITE_DONE) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        goto rollback;
    }
    choir_sqlite.finalize(stmt);
    if (fault_point == 1) {
        result = 5;
        goto rollback;
    }

    stmt = NULL;
    const char *outbox_sql =
        "INSERT INTO completion_outbox(semantic_key, payload_digest, record_key, "
        "state_version, fencing_epoch, state_value_digest) "
        "VALUES(?1, ?2, ?3, ?4, ?5, ?6)";
    if (choir_sqlite.prepare_statement(db, outbox_sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, semantic) != 0 ||
        choir_sqlite_bind_text(stmt, 2, payload) != 0 ||
        choir_sqlite_bind_text(stmt, 3, key) != 0 ||
        choir_sqlite.bind_int64(stmt, 4, next_version) != SQLITE_OK ||
        choir_sqlite.bind_int64(stmt, 5, fencing_epoch) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 6, value) != 0 ||
        choir_sqlite.step(stmt) != SQLITE_DONE) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        goto rollback;
    }
    choir_sqlite.finalize(stmt);
    if (fault_point == 2) {
        result = 5;
        goto rollback;
    }
    int commit_rc = choir_sqlite_exec_rc(db, "COMMIT");
    if (commit_rc != SQLITE_OK) {
        result = commit_rc == SQLITE_BUSY ? 9 : 6;
        goto rollback;
    }
    result = fault_point == 3 ? 7 : 0;
    goto done;

rollback:
    /* The connection outlives this call, so a failed transaction must be
     * rolled back explicitly rather than discarded with the handle. */
    choir_sqlite_exec(db, "ROLLBACK");
done:
    free(key); free(value); free(semantic); free(payload);
    free(guard_key); free(guard_digest);
    return result;
}

int choir_state_store_read_state(
    const char *path,
    int path_len,
    const char *record_key,
    int record_key_len,
    char *output,
    int output_size
) {
    char *key = choir_store_copy_string(record_key, record_key_len);
    if (key == NULL || output == NULL || output_size <= 0) {
        free(key);
        return -1;
    }
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        free(key);
        return -1;
    }
    sqlite3_int64 version = 0;
    sqlite3_int64 fence = 0;
    char digest[65] = {0};
    int found = choir_sqlite_read_state_values(
        db, key, &version, &fence, digest, sizeof(digest)
    );
    int result = found;
    if (found == 1) {
        int written = snprintf(
            output, (size_t)output_size, "%lld|%lld|%s",
            (long long)version, (long long)fence, digest
        );
        if (written < 0 || written >= output_size) {
            result = -1;
        } else {
            result = written;
        }
    }
    free(key);
    return result;
}

int choir_state_store_list_state(
    const char *path,
    int path_len,
    const char *record_prefix,
    int record_prefix_len,
    char *output,
    int output_size
) {
    char *prefix = choir_store_copy_string(record_prefix, record_prefix_len);
    if (prefix == NULL || output == NULL || output_size <= 0) {
        free(prefix);
        return -1;
    }
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        free(prefix);
        return -1;
    }
    sqlite3_stmt *stmt = NULL;
    /* A half-open key range rather than substr(record_key,1,n)=prefix. The
     * function form is not sargable: SQLite has to evaluate it per row, so it
     * SCANs the primary key index and the cost grows with total Goal history
     * rather than with the number of matches. The range form SEARCHes. */
    char *upper = choir_prefix_upper_bound(prefix);
    const char *sql =
        upper != NULL
            ? "SELECT record_key, version, fencing_epoch, value_digest "
              "FROM state_records WHERE record_key >= ?1 AND record_key < ?2 "
              "ORDER BY record_key"
            : "SELECT record_key, version, fencing_epoch, value_digest "
              "FROM state_records WHERE record_key >= ?1 "
              "ORDER BY record_key";
    if (choir_sqlite.prepare_statement(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, prefix) != 0 ||
        (upper != NULL && choir_sqlite_bind_text(stmt, 2, upper) != 0)) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        free(upper);
        free(prefix);
        return -1;
    }
    int used = 0;
    int result = 0;
    for (;;) {
        int step = choir_sqlite.step(stmt);
        if (step == SQLITE_DONE) break;
        if (step != SQLITE_ROW) {
            result = -1;
            break;
        }
        const unsigned char *key = choir_sqlite.column_text(stmt, 0);
        const unsigned char *digest = choir_sqlite.column_text(stmt, 3);
        if (key == NULL || digest == NULL) {
            result = -1;
            break;
        }
        int written = snprintf(
            output + used,
            (size_t)(output_size - used),
            "%s|%lld|%lld|%s\n",
            (const char *)key,
            (long long)choir_sqlite.column_int64(stmt, 1),
            (long long)choir_sqlite.column_int64(stmt, 2),
            (const char *)digest
        );
        if (written < 0 || written >= output_size - used) {
            result = -2;
            break;
        }
        used += written;
    }
    if (result == 0) result = used;
    choir_sqlite.finalize(stmt);
    free(upper);
    free(prefix);
    return result;
}

int choir_state_store_read_outbox(
    const char *path,
    int path_len,
    const char *semantic_key,
    int semantic_key_len,
    char *output,
    int output_size
) {
    char *key = choir_store_copy_string(semantic_key, semantic_key_len);
    if (key == NULL || output == NULL || output_size < 65) {
        free(key);
        return -1;
    }
    sqlite3 *db = NULL;
    if (choir_sqlite_acquire(path, path_len, &db) != 0) {
        free(key);
        return -1;
    }
    int result = choir_sqlite_read_outbox_digest(
        db, key, output, (size_t)output_size
    );
    if (result == 1) result = 64;
    free(key);
    return result;
}

static int choir_artifact_checked_dir(const char *path, mode_t mode) {
    struct stat st;
    if (lstat(path, &st) == 0) {
        return S_ISDIR(st.st_mode) && !S_ISLNK(st.st_mode) ? 0 : -1;
    }
    if (errno != ENOENT || mkdir(path, mode) != 0) {
        return -1;
    }
    if (lstat(path, &st) != 0 || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) {
        return -1;
    }
    return 0;
}

static int choir_artifact_existing_matches(
    const char *path,
    const unsigned char *content,
    int content_len
) {
    struct stat st;
    if (lstat(path, &st) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    if (!S_ISREG(st.st_mode) || S_ISLNK(st.st_mode) || st.st_size != content_len) {
        return -1;
    }
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    unsigned char buffer[8192];
    int offset = 0;
    while (offset < content_len) {
        int wanted = content_len - offset;
        if (wanted > (int)sizeof(buffer)) wanted = (int)sizeof(buffer);
        ssize_t n = read(fd, buffer, (size_t)wanted);
        if (n <= 0 || memcmp(buffer, content + offset, (size_t)n) != 0) {
            close(fd);
            return -1;
        }
        offset += (int)n;
    }
    unsigned char extra;
    ssize_t trailing = read(fd, &extra, 1);
    close(fd);
    return trailing == 0 ? 1 : -1;
}

/* 0 adopted, 1 already present with exact bytes, -1 I/O, -2 corruption. */
int choir_artifact_store_adopt(
    const char *root,
    int root_len,
    const char *digest,
    int digest_len,
    const unsigned char *content,
    int content_len
) {
    char *root_path = choir_store_copy_string(root, root_len);
    char *digest_text = choir_store_copy_string(digest, digest_len);
    if (root_path == NULL || digest_text == NULL || digest_len != 64 ||
        content == NULL || content_len < 0) {
        free(root_path); free(digest_text);
        return -1;
    }
    char objects[4096], shard[4096], staging[4096], target[4096], temp[4096];
    if (snprintf(objects, sizeof(objects), "%s/sha256", root_path) >= (int)sizeof(objects) ||
        snprintf(shard, sizeof(shard), "%s/%.2s", objects, digest_text) >= (int)sizeof(shard) ||
        snprintf(staging, sizeof(staging), "%s/staging", root_path) >= (int)sizeof(staging) ||
        snprintf(target, sizeof(target), "%s/%s", shard, digest_text) >= (int)sizeof(target)) {
        free(root_path); free(digest_text);
        return -1;
    }
    if (choir_artifact_checked_dir(root_path, 0700) != 0 ||
        choir_artifact_checked_dir(objects, 0700) != 0 ||
        choir_artifact_checked_dir(shard, 0700) != 0 ||
        choir_artifact_checked_dir(staging, 0700) != 0) {
        free(root_path); free(digest_text);
        return -1;
    }
    int existing = choir_artifact_existing_matches(target, content, content_len);
    if (existing != 0) {
        free(root_path); free(digest_text);
        return existing == 1 ? 1 : -2;
    }
    static unsigned long sequence = 0;
    int fd = -1;
    for (int attempt = 0; attempt < 32; ++attempt) {
        unsigned long value = __atomic_add_fetch(&sequence, 1, __ATOMIC_RELAXED);
        int written = snprintf(
            temp, sizeof(temp), "%s/%ld-%lu.tmp", staging, (long)getpid(), value
        );
        if (written < 0 || written >= (int)sizeof(temp)) break;
        fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd >= 0 || errno != EEXIST) break;
    }
    if (fd < 0) {
        free(root_path); free(digest_text);
        return -1;
    }
    int offset = 0;
    while (offset < content_len) {
        ssize_t n = write(fd, content + offset, (size_t)(content_len - offset));
        if (n <= 0) {
            close(fd); unlink(temp);
            free(root_path); free(digest_text);
            return -1;
        }
        offset += (int)n;
    }
    if (fsync(fd) != 0 || fchmod(fd, 0444) != 0 || close(fd) != 0) {
        unlink(temp);
        free(root_path); free(digest_text);
        return -1;
    }
    if (link(temp, target) != 0) {
        int link_error = errno;
        unlink(temp);
        if (link_error == EEXIST) {
            existing = choir_artifact_existing_matches(target, content, content_len);
            free(root_path); free(digest_text);
            return existing == 1 ? 1 : -2;
        }
        free(root_path); free(digest_text);
        return -1;
    }
    unlink(temp);
    int dir_fd = open(shard, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
    if (dir_fd >= 0) {
        (void)fsync(dir_fd);
        close(dir_fd);
    }
    free(root_path); free(digest_text);
    return 0;
}

int choir_artifact_store_contains(
    const char *root,
    int root_len,
    const char *digest,
    int digest_len
) {
    char *root_path = choir_store_copy_string(root, root_len);
    char *digest_text = choir_store_copy_string(digest, digest_len);
    if (root_path == NULL || digest_text == NULL || digest_len != 64) {
        free(root_path); free(digest_text);
        return -1;
    }
    char target[4096];
    int written = snprintf(
        target, sizeof(target), "%s/sha256/%.2s/%s", root_path, digest_text, digest_text
    );
    struct stat st;
    int result;
    if (written < 0 || written >= (int)sizeof(target)) {
        result = -1;
    } else if (lstat(target, &st) != 0) {
        result = errno == ENOENT ? 0 : -1;
    } else {
        result = S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode) ? 1 : -2;
    }
    free(root_path); free(digest_text);
    return result;
}

static int choir_artifact_path(
    const char *root,
    int root_len,
    const char *digest,
    int digest_len,
    char *target,
    size_t target_size
) {
    char *root_path = choir_store_copy_string(root, root_len);
    char *digest_text = choir_store_copy_string(digest, digest_len);
    if (root_path == NULL || digest_text == NULL || digest_len != 64) {
        free(root_path); free(digest_text);
        return -1;
    }
    int written = snprintf(
        target, target_size, "%s/sha256/%.2s/%s", root_path, digest_text, digest_text
    );
    free(root_path); free(digest_text);
    return written < 0 || (size_t)written >= target_size ? -1 : 0;
}

/* Remove one artifact by digest. Returns 1 when this call unlinked the
 * content, 0 when it was already absent, and -1 on any other failure.
 *
 * Already-absent is a success, because a sweep that reruns after a crash has to
 * converge rather than fail on work it already did — but it is reported apart
 * from a real removal, so a caller counting released content counts what it
 * released rather than what it was asked to release. */
int choir_artifact_store_remove(
    const char *root, int root_len, const char *digest, int digest_len
) {
    char target[4096];
    if (choir_artifact_path(root, root_len, digest, digest_len, target, sizeof(target)) != 0) {
        return -1;
    }
    if (unlink(target) == 0) {
        return 1;
    }
    return errno == ENOENT ? 0 : -1;
}

int choir_artifact_store_size(
    const char *root,
    int root_len,
    const char *digest,
    int digest_len
) {
    char target[4096];
    if (choir_artifact_path(
            root, root_len, digest, digest_len, target, sizeof(target)
        ) != 0) {
        return -1;
    }
    int fd = open(target, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat st;
    int result = -1;
    if (fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 &&
        st.st_size <= INT32_MAX) {
        result = (int)st.st_size;
    }
    close(fd);
    return result;
}

int choir_artifact_store_read(
    const char *root,
    int root_len,
    const char *digest,
    int digest_len,
    unsigned char *output,
    int output_size
) {
    if (output_size < 0 || (output == NULL && output_size != 0)) return -1;
    char target[4096];
    if (choir_artifact_path(
            root, root_len, digest, digest_len, target, sizeof(target)
        ) != 0) {
        return -1;
    }
    int fd = open(target, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
        st.st_size != output_size) {
        close(fd);
        return -1;
    }
    int offset = 0;
    while (offset < output_size) {
        ssize_t n = read(fd, output + offset, (size_t)(output_size - offset));
        if (n <= 0) {
            close(fd);
            return -1;
        }
        offset += (int)n;
    }
    unsigned char trailing = 0;
    ssize_t extra = read(fd, &trailing, 1);
    close(fd);
    return extra == 0 ? offset : -1;
}
