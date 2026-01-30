default:
  just --list

# Run the shibuya example
example:
  cabal run shibuya-example

# --- Services ---

[group("services")]
process-up:
  process-compose --tui=false --unix-socket .dev/process-compose.sock up

[group("services")]
process-down:
  process-compose --unix-socket .dev/process-compose.sock down || true

# --- Database ---

[group("database")]
create-database:
  psql -lqt | cut -d \| -f 1 | grep -qw $PGDATABASE || createdb $PGDATABASE

[group("database")]
psql:
  psql $PGDATABASE

[group("database")]
drop-database:
  dropdb --if-exists $PGDATABASE

[group("database")]
reset-database: drop-database create-database
