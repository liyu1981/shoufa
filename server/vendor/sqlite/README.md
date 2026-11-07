# SQLite amalgamation

Vendored SQLite 3.45.1 amalgamation (`sqlite3.c`, `sqlite3.h`) from
<https://www.sqlite.org/2024/sqlite-amalgamation-3450100.zip>.

SQLite is in the public domain. See <https://www.sqlite.org/copyright.html>.

The amalgamation is compiled into `shoufad` so release builds remain
self-contained and can cross-compile for musl targets without a system
SQLite dependency.
