#!/usr/bin/env bash
# Sourced by restore-from-duplicator.sh after SQL path validation.
# -------- 5. SQL pre-processing for MariaDB -> MySQL 8.0 --------
log "Step 5/12: Pre-processing SQL dump for MariaDB -> MySQL 8.0 compatibility"

# Operate on a copy so the original stays intact
SQL_PROC="${SQL_FILE%.sql}.processed.sql"
rm -f "$SQL_PROC"  # wipe any half-baked previous run
cp -f "$SQL_FILE" "$SQL_PROC"

# 5a. MariaDB 10.10+ uca1400 collations -> MySQL 8.0 0900 equivalents
sed -i \
  -e 's/utf8mb4_uca1400_ai_ci/utf8mb4_0900_ai_ci/g' \
  -e 's/utf8mb4_uca1400_as_cs/utf8mb4_0900_as_cs/g' \
  -e 's/utf8mb4_uca1400_as_ci/utf8mb4_0900_as_ci/g' \
  "$SQL_PROC"

# 5b. Old utf8 (3-byte, deprecated) -> utf8mb4
sed -i -E \
  -e 's/CHARSET=utf8([^m])/CHARSET=utf8mb4\1/g' \
  -e 's/CHARSET=utf8$/CHARSET=utf8mb4/g' \
  -e 's/COLLATE=utf8_/COLLATE=utf8mb4_/g' \
  -e 's/COLLATE utf8_/COLLATE utf8mb4_/g' \
  -e 's/DEFAULT CHARACTER SET utf8([^m])/DEFAULT CHARACTER SET utf8mb4\1/g' \
  "$SQL_PROC"

# 5c. Strip MariaDB JSON CHECK constraints (MySQL 8.0 has native JSON)
#     Pattern: ,? `?CONSTRAINT`? `name` CHECK (json_valid(`col`))
sed -i -E \
  -e 's/,[[:space:]]*CONSTRAINT[[:space:]]+`[^`]+`[[:space:]]+CHECK[[:space:]]*\(json_valid\(`[^`]+`\)\)//g' \
  -e '/^[[:space:]]*CONSTRAINT[[:space:]]+`[^`]+`[[:space:]]+CHECK[[:space:]]*\(json_valid\(`[^`]+`\)\)[[:space:]]*,?[[:space:]]*$/d' \
  "$SQL_PROC"

# 5d. Prepend a relaxed SQL_MODE so older dumps don't trip strict checks
TMP_HEAD=$(mktemp)
cat >"$TMP_HEAD" <<'EOSQL'
SET sql_mode='NO_ENGINE_SUBSTITUTION';
SET FOREIGN_KEY_CHECKS=0;
SET UNIQUE_CHECKS=0;
SET @OLD_TIME_ZONE=@@TIME_ZONE;
SET TIME_ZONE='+00:00';
EOSQL
cat "$TMP_HEAD" "$SQL_PROC" > "${SQL_PROC}.new" && mv "${SQL_PROC}.new" "$SQL_PROC"
rm -f "$TMP_HEAD"

# Quick sanity check: count INSERT statements (Duplicator uses INSERT IGNORE)
INSERT_COUNT=$(grep -cE '^INSERT (IGNORE )?INTO' "$SQL_PROC" || true)
TABLE_COUNT=$(grep -cE '^CREATE TABLE' "$SQL_PROC" || true)
log "Pre-processed SQL ready: $SQL_PROC ($TABLE_COUNT tables, $INSERT_COUNT INSERT statements)"
