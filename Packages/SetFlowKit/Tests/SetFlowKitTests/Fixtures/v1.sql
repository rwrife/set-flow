-- Versioned v1 fixture: represents a database already at the v1-initial-schema migration
-- (legacy FK actions: routine cascade / session set-null / set_block set-null).
-- The migration test replays this SQL into a fresh file, records v1 as applied, then runs
-- the store migrator, which must rewrite those FK actions to RESTRICT and preserve data.
PRAGMA foreign_keys = ON;
CREATE TABLE exercise (id TEXT PRIMARY KEY, name TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL);
CREATE TABLE routine (id TEXT PRIMARY KEY, name TEXT NOT NULL, createdAt INTEGER NOT NULL, updatedAt INTEGER NOT NULL);
CREATE TABLE set_block (id TEXT PRIMARY KEY, routineId TEXT NOT NULL REFERENCES routine(id) ON DELETE CASCADE, exerciseId TEXT NOT NULL REFERENCES exercise(id) ON DELETE RESTRICT, position INTEGER NOT NULL, targetRepetitions INTEGER, targetLoadThousandths INTEGER, targetLoadUnit TEXT, note TEXT, UNIQUE(routineId, position));
CREATE TABLE session (id TEXT PRIMARY KEY, routineId TEXT REFERENCES routine(id) ON DELETE SET NULL, startedAt INTEGER NOT NULL, completedAt INTEGER, note TEXT);
CREATE TABLE set_entry (id TEXT PRIMARY KEY, sessionId TEXT NOT NULL REFERENCES session(id) ON DELETE CASCADE, exerciseId TEXT NOT NULL REFERENCES exercise(id) ON DELETE RESTRICT, setBlockId TEXT REFERENCES set_block(id) ON DELETE SET NULL, sequence INTEGER NOT NULL, completedAt INTEGER NOT NULL, repetitions INTEGER, loadThousandths INTEGER, loadUnit TEXT, side TEXT, asymmetryNote TEXT, UNIQUE(sessionId, sequence));
CREATE INDEX idx_set_block_routine ON set_block(routineId, position);
CREATE INDEX idx_set_entry_session ON set_entry(sessionId, sequence);
CREATE INDEX idx_set_entry_exercise ON set_entry(exerciseId, completedAt);
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
INSERT INTO grdb_migrations (identifier) VALUES ('v1-initial-schema');
INSERT INTO exercise VALUES ('00000000-0000-0000-0000-000000000021', 'Legacy squat', 1, 2);
INSERT INTO routine VALUES ('00000000-0000-0000-0000-000000000022', 'Legacy plan', 1, 2);
INSERT INTO set_block VALUES ('00000000-0000-0000-0000-000000000025', '00000000-0000-0000-0000-000000000022', '00000000-0000-0000-0000-000000000021', 0, 5, 60500, 'kilograms', 'Legacy tempo');
INSERT INTO session VALUES ('00000000-0000-0000-0000-000000000023', '00000000-0000-0000-0000-000000000022', 3, NULL, NULL);
INSERT INTO set_entry VALUES ('00000000-0000-0000-0000-000000000024', '00000000-0000-0000-0000-000000000023', '00000000-0000-0000-0000-000000000021', '00000000-0000-0000-0000-000000000025', 0, 4, 5, 60500, 'kilograms', 'left', 'Legacy asymmetry');
