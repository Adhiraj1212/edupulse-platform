#!/bin/bash
# Runs once, on first start of an empty data volume. Passwords come from the container
# environment, never from the repo.
set -euo pipefail

mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE TABLE IF NOT EXISTS \`${MYSQL_DATABASE}\`.students (
  roll_no INT PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  age INT NOT NULL,
  marks INT NOT NULL,
  image_url VARCHAR(255)
);

-- The audit service owns a separate database and a least-privilege user:
-- it only creates its table, appends events and reads them back.
CREATE DATABASE IF NOT EXISTS audit_db;
CREATE USER IF NOT EXISTS 'audit'@'%' IDENTIFIED BY '${AUDIT_DB_PASSWORD}';
GRANT SELECT, INSERT, CREATE ON audit_db.* TO 'audit'@'%';
SQL
