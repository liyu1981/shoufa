//! Minimal SQLite C bindings used by the persistent metadata index.
//!
//! Only the handful of APIs the store needs are exposed. The vendored
//! amalgamation (`server/vendor/sqlite/sqlite3.c`) is compiled into the binary
//! by `build.zig`, so releases remain self-contained and cross-compile without
//! a system SQLite dependency.

const std = @import("std");

pub const Raw = opaque {};
pub const RawStmt = opaque {};

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_NULL: c_int = 5;

const SQLITE_OPEN_READWRITE: c_int = 0x0000_0002;
const SQLITE_OPEN_CREATE: c_int = 0x0000_0004;
const SQLITE_OPEN_NOMUTEX: c_int = 0x0000_8000;

extern "c" fn sqlite3_open_v2(
    filename: [*:0]const u8,
    pp_db: *?*Raw,
    flags: c_int,
    vfs: ?[*:0]const u8,
) c_int;
extern "c" fn sqlite3_close_v2(db: ?*Raw) c_int;
extern "c" fn sqlite3_errmsg(db: ?*Raw) [*:0]const u8;
extern "c" fn sqlite3_busy_timeout(db: ?*Raw, milliseconds: c_int) c_int;
extern "c" fn sqlite3_exec(
    db: ?*Raw,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, ?[*:0]u8, ?[*:0]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern "c" fn sqlite3_prepare_v2(
    db: ?*Raw,
    sql: [*:0]const u8,
    byte_count: c_int,
    stmt: *?*RawStmt,
    tail: ?*?[*:0]const u8,
) c_int;
extern "c" fn sqlite3_finalize(stmt: ?*RawStmt) c_int;
extern "c" fn sqlite3_bind_text(
    stmt: ?*RawStmt,
    index: c_int,
    value: [*c]const u8,
    byte_count: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;
extern "c" fn sqlite3_bind_int64(stmt: ?*RawStmt, index: c_int, value: i64) c_int;
extern "c" fn sqlite3_bind_null(stmt: ?*RawStmt, index: c_int) c_int;
extern "c" fn sqlite3_step(stmt: ?*RawStmt) c_int;
extern "c" fn sqlite3_column_text(stmt: ?*RawStmt, column: c_int) ?[*:0]const u8;
extern "c" fn sqlite3_column_bytes(stmt: ?*RawStmt, column: c_int) c_int;
extern "c" fn sqlite3_column_int64(stmt: ?*RawStmt, column: c_int) i64;
extern "c" fn sqlite3_column_type(stmt: ?*RawStmt, column: c_int) c_int;
extern "c" fn sqlite3_changes(db: ?*Raw) c_int;

pub const Error = error{SqliteError};

pub const Db = struct {
    raw: *Raw,

    /// Opens (or creates) a database file. `path` is copied by SQLite before
    /// this function returns.
    pub fn open(gpa: std.mem.Allocator, path: []const u8) !Db {
        const path_z = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(path_z);

        var raw: ?*Raw = null;
        const rc = sqlite3_open_v2(
            path_z,
            &raw,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX,
            null,
        );
        if (rc != SQLITE_OK) {
            if (raw) |db| _ = sqlite3_close_v2(db);
            return error.SqliteError;
        }
        if (raw == null) return error.SqliteError;

        _ = sqlite3_busy_timeout(raw, 5_000);
        return .{ .raw = raw.? };
    }

    pub fn close(self: *Db) void {
        _ = sqlite3_close_v2(self.raw);
        self.* = undefined;
    }

    pub fn errmsg(self: *const Db) []const u8 {
        return std.mem.span(sqlite3_errmsg(self.raw));
    }

    /// Executes one or more statements with no result rows.
    pub fn exec(self: *Db, sql: [:0]const u8) Error!void {
        const rc = sqlite3_exec(self.raw, sql, null, null, null);
        if (rc != SQLITE_OK) return error.SqliteError;
    }

    pub fn prepare(self: *Db, sql: [:0]const u8) Error!Stmt {
        var raw: ?*RawStmt = null;
        const rc = sqlite3_prepare_v2(self.raw, sql, -1, &raw, null);
        if (rc != SQLITE_OK) return error.SqliteError;
        if (raw == null) return error.SqliteError;
        return .{ .raw = raw.?, .db = self };
    }

    pub fn changes(self: *Db) c_int {
        return sqlite3_changes(self.raw);
    }
};

pub const Stmt = struct {
    raw: *RawStmt,
    db: *Db,

    pub fn finalize(self: *Stmt) void {
        _ = sqlite3_finalize(self.raw);
        self.* = undefined;
    }

    pub fn bindText(self: *Stmt, index: c_int, value: []const u8) Error!void {
        const rc = sqlite3_bind_text(self.raw, index, value.ptr, @intCast(value.len), null);
        if (rc != SQLITE_OK) return error.SqliteError;
    }

    pub fn bindInt(self: *Stmt, index: c_int, value: i64) Error!void {
        const rc = sqlite3_bind_int64(self.raw, index, value);
        if (rc != SQLITE_OK) return error.SqliteError;
    }

    pub fn bindNull(self: *Stmt, index: c_int) Error!void {
        const rc = sqlite3_bind_null(self.raw, index);
        if (rc != SQLITE_OK) return error.SqliteError;
    }

    /// Returns true when a row is available, false when the statement is done.
    pub fn step(self: *Stmt) Error!bool {
        const rc = sqlite3_step(self.raw);
        return switch (rc) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => error.SqliteError,
        };
    }

    pub fn columnNull(self: *Stmt, column: c_int) bool {
        return sqlite3_column_type(self.raw, column) == SQLITE_NULL;
    }

    pub fn columnInt(self: *Stmt, column: c_int) i64 {
        return sqlite3_column_int64(self.raw, column);
    }

    pub fn columnText(self: *Stmt, column: c_int) ?[]const u8 {
        const ptr = sqlite3_column_text(self.raw, column) orelse return null;
        const len = sqlite3_column_bytes(self.raw, column);
        if (len <= 0) return "";
        return ptr[0..@intCast(len)];
    }
};
