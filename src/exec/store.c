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

static int choir_sqlite_open_path(const char *path, int path_len, sqlite3 **db) {
    if (choir_sqlite_load() != 0) {
        return -1;
    }
    char *copy = choir_store_copy_string(path, path_len);
    if (copy == NULL) {
        return -1;
    }
    int rc = choir_sqlite.open_v2(
        copy,
        db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
        NULL
    );
    free(copy);
    if (rc != SQLITE_OK) {
        if (*db != NULL) {
            choir_sqlite.close(*db);
            *db = NULL;
        }
        return -1;
    }
    return 0;
}

static int choir_sqlite_exec(sqlite3 *db, const char *sql) {
    char *error = NULL;
    int rc = choir_sqlite.exec(db, sql, NULL, NULL, &error);
    if (error != NULL) {
        choir_sqlite.free_fn(error);
    }
    return rc == SQLITE_OK ? 0 : -1;
}

int choir_state_store_init(const char *path, int path_len) {
    sqlite3 *db = NULL;
    if (choir_sqlite_open_path(path, path_len, &db) != 0) {
        return -1;
    }
    const char *schema =
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
        ") STRICT;";
    int rc = choir_sqlite_exec(db, schema);
    choir_sqlite.close(db);
    return rc;
}

static int choir_sqlite_bind_text(sqlite3_stmt *stmt, int index, const char *value) {
    return choir_sqlite.bind_text(stmt, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK
               ? 0
               : -1;
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
 * 8 guarded precondition conflict.
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
    if (choir_sqlite_open_path(path, path_len, &db) != 0 ||
        choir_sqlite_exec(db, "BEGIN IMMEDIATE") != 0) {
        if (db != NULL) choir_sqlite.close(db);
        free(key); free(value); free(semantic); free(payload);
        free(guard_key); free(guard_digest);
        return 6;
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
    if (choir_sqlite_exec(db, "COMMIT") != 0) {
        goto rollback_without_tx;
    }
    result = fault_point == 3 ? 7 : 0;
    goto done;

rollback:
    choir_sqlite_exec(db, "ROLLBACK");
rollback_without_tx:
done:
    choir_sqlite.close(db);
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
    if (choir_sqlite_open_path(path, path_len, &db) != 0) {
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
    choir_sqlite.close(db);
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
    if (choir_sqlite_open_path(path, path_len, &db) != 0) {
        free(prefix);
        return -1;
    }
    sqlite3_stmt *stmt = NULL;
    const char *sql =
        "SELECT record_key, version, fencing_epoch, value_digest "
        "FROM state_records WHERE substr(record_key, 1, length(?1)) = ?1 "
        "ORDER BY record_key";
    if (choir_sqlite.prepare_statement(db, sql, -1, &stmt, NULL) != SQLITE_OK ||
        choir_sqlite_bind_text(stmt, 1, prefix) != 0) {
        if (stmt != NULL) choir_sqlite.finalize(stmt);
        choir_sqlite.close(db);
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
    choir_sqlite.close(db);
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
    if (choir_sqlite_open_path(path, path_len, &db) != 0) {
        free(key);
        return -1;
    }
    int result = choir_sqlite_read_outbox_digest(
        db, key, output, (size_t)output_size
    );
    if (result == 1) result = 64;
    choir_sqlite.close(db);
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
