#!/usr/bin/env bash
set +x
set -Eeuo pipefail
umask 077

test_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
backup_dir=$(dirname -- "$test_dir")
project_root=$(cd -- "${backup_dir}/../.." && pwd)
test_root=$(mktemp -d /tmp/inat-mysql-backup-test.XXXXXXXX)
test_project="inat-backup-test-${test_root##*.}"
test_project=${test_project,,}
export MYSQL_BACKUP_TEST_IMAGE="inat-mysql-backup:test-${test_project##*-}"
export MYSQL_BACKUP_TEST_DATA_DIR="$test_root/backups"
export MYSQL_BACKUP_TEST_CRONTAB="$test_root/crontab"
compose=(docker compose --env-file "$test_root/.env" --project-name "$test_project" -f "$test_dir/compose.yml")

cleanup_test() {
    local status=$?
    trap - EXIT
    set +e
    "${compose[@]}" down --volumes --remove-orphans --timeout 5 >/dev/null 2>&1
    docker image rm "$MYSQL_BACKUP_TEST_IMAGE" >/dev/null 2>&1
    rm -rf -- "$test_root"
    exit "$status"
}
trap cleanup_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
test_error() {
    local line=$1 file message
    printf 'FAIL: integration test stopped at line %s\n' "$line" >&2
    for file in backup restore refusal long-retention cron; do
        [[ ! -f "$test_root/$file.log" ]] || while IFS= read -r message; do
            message=${message//"${test_password:-no-password}"/[redacted]}
            printf '%s\n' "${message//"${test_root_password:-no-password}"/[redacted]}" >&2
        done <"$test_root/$file.log"
    done
}
trap 'test_error "$LINENO"' ERR

pass() { printf 'PASS: %s\n' "$1"; }
sql() {
    "${compose[@]}" exec -T mysql sh -ec \
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql --no-defaults --user=root --batch --skip-column-names "$@"' sh "$@"
}
run_tool() { "${compose[@]}" run --rm --no-deps -T mysql-backup "$@"; }
container_shell() { "${compose[@]}" run --rm --no-deps -T --entrypoint bash mysql-backup -ceu "$1"; }
expect_refusal() {
    local label=$1
    shift
    if "$@" >"$test_root/refusal-current.log" 2>&1; then
        printf 'FAIL: %s unexpectedly succeeded\n' "$label" >&2
        exit 1
    fi
    cat "$test_root/refusal-current.log" >>"$test_root/refusal.log"
    grep -q '\[ERROR\]' "$test_root/refusal-current.log"
    pass "$label refused"
}

mkdir -m 0700 "$test_root/backups"
test_root_password=$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')
test_password="$test_root_password"' #$"quote"`tick`\slash'
# Single-quoted dotenv values preserve $, spaces, quotes, backticks and backslashes.
printf "MYSQL_BACKUP_TEST_PASSWORD='%s'\n" "$test_password" >"$test_root/.env"
printf "MYSQL_BACKUP_TEST_ROOT_PASSWORD='%s'\n" "$test_root_password" >>"$test_root/.env"
[[ "$(stat -c %a "$test_root/.env")" == 600 ]]
test_password_sql=${test_password//\\/\\\\}
# No production file or clock is changed. Only this disposable service runs every minute.
sed 's/^15 2 /\* \* /' "$backup_dir/crontab" >"$test_root/crontab"
chmod 0644 "$test_root/crontab"

printf 'Building isolated backup image...\n'
default_services=$(COMPOSE_PROFILES= docker compose --env-file "$project_root/.env.example" -f "$project_root/docker-compose.yml" config --services)
grep -qx mysql-backup <<<"$default_services"
default_images=$(COMPOSE_PROFILES= docker compose --env-file "$project_root/.env.example" -f "$project_root/docker-compose.yml" config --images)
grep -qx ghcr.io/inat-instituto-nacional-do-trabalhador/inat-mysql-backup <<<"$default_images"
pass 'default Compose includes backup service and GHCR image without a profile'
docker build --quiet --tag "$MYSQL_BACKUP_TEST_IMAGE" "$backup_dir" >/dev/null
# Cron refuses a crontab owned by an unprivileged host user.
docker run --rm --network none --entrypoint chown \
    --mount "type=bind,source=$test_root/crontab,target=/crontab" \
    "$MYSQL_BACKUP_TEST_IMAGE" 0:0 /crontab
run_tool check >"$test_root/check.log" 2>&1
pass 'deploy preflight validates .env settings with MySQL still offline'
printf 'Starting disposable MySQL (no published ports, tmpfs data)...\n'
"${compose[@]}" up --detach --wait --wait-timeout 150 mysql >/dev/null
sql <"$test_dir/fixture.sql" >/dev/null
sql <<EOF
CREATE USER 'backup_reader'@'%' IDENTIFIED BY '$test_password_sql';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON app_test.* TO 'backup_reader'@'%';
GRANT SHOW_ROUTINE ON *.* TO 'backup_reader'@'%';
EOF
pass 'fixture and read-only backup account created'

run_tool backup >"$test_root/backup.log" 2>&1
archive=$(container_shell 'find /backups -name "app_test_*.sql.gz" -printf "%f\n"' 2>/dev/null)
[[ "$archive" =~ ^app_test_[0-9]{8}T[0-9]{6}Z_[A-Za-z0-9]{8}\.sql\.gz$ ]]
container_shell "gzip -t /backups/$archive; test \"\$(stat -c %a /backups/$archive)\" = 600; test \"\$(stat -c %a /backups)\" = 700" >/dev/null 2>&1
pass 'backup uses UTC filename, private permissions and valid gzip'

# Generate retention fixtures from a genuine archive; only mtime defines age.
container_shell "
    cp /backups/$archive /backups/app_test_20000101T000000Z_OLDTEST1.sql.gz
    cp /backups/$archive /backups/app_test_20000102T000000Z_KEEPME01.sql.gz
    cp /backups/$archive /backups/other_20000101T000000Z_OLDTEST1.sql.gz
    cp /backups/$archive /backups/unrelated.sql.gz
    touch -d '40 days ago' /backups/app_test_20000101T000000Z_OLDTEST1.sql.gz /backups/other_20000101T000000Z_OLDTEST1.sql.gz /backups/unrelated.sql.gz
    touch -d '29 days ago' /backups/app_test_20000102T000000Z_KEEPME01.sql.gz
    touch /backups/app_test_20000101T000000Z_STALE001.sql.gz.partial
" >/dev/null 2>&1
expect_refusal 'invalid credentials' "${compose[@]}" run --rm --no-deps -T \
    -e MYSQL_BACKUP_USERNAME=nonexistent_test_user mysql-backup backup
container_shell 'test -f /backups/app_test_20000101T000000Z_OLDTEST1.sql.gz; test -z "$(find /backups -name "*.partial" -print)"' >/dev/null 2>&1
pass 'failed dump preserves expired backups and cleans partial files'
expect_refusal 'retention below 30 days' "${compose[@]}" run --rm --no-deps -T \
    -e MYSQL_BACKUP_RETENTION_DAYS=29 mysql-backup backup
expect_refusal 'missing password' "${compose[@]}" run --rm --no-deps -T \
    -e MYSQL_BACKUP_PASSWORD= mysql-backup check
expect_refusal 'invalid port' "${compose[@]}" run --rm --no-deps -T \
    -e MYSQL_BACKUP_PORT=invalid mysql-backup check
"${compose[@]}" run --rm --no-deps -T -e MYSQL_BACKUP_RETENTION_DAYS=45 \
    mysql-backup backup >"$test_root/long-retention.log" 2>&1
container_shell 'test -f /backups/app_test_20000101T000000Z_OLDTEST1.sql.gz' >/dev/null 2>&1
pass 'custom 45-day retention preserves a 40-day-old backup'
run_tool backup >>"$test_root/backup.log" 2>&1
container_shell '
    test ! -f /backups/app_test_20000101T000000Z_OLDTEST1.sql.gz
    test -f /backups/app_test_20000102T000000Z_KEEPME01.sql.gz
    test -f /backups/other_20000101T000000Z_OLDTEST1.sql.gz
    test -f /backups/unrelated.sql.gz
' >/dev/null 2>&1
pass '30-day retention runs after success and preserves recent/foreign files'

# Hold the same flock inode from an independent container sharing the bind mount.
"${compose[@]}" run --detach --no-deps --name "$test_project-lock" --entrypoint bash mysql-backup \
    -ceu 'exec 9>/backups/.mysql-backup.lock; flock 9; touch /backups/lock-ready; sleep 90' >/dev/null
for attempt in {1..15}; do
    [[ ! -f "$test_root/backups/lock-ready" ]] || break
    sleep 1
done
test -f "$test_root/backups/lock-ready"
expect_refusal 'concurrent backup' run_tool backup
expect_refusal 'concurrent restore' run_tool restore "/backups/$archive" restored
docker rm --force "$test_project-lock" >/dev/null
run_tool backup >>"$test_root/backup.log" 2>&1
pass 'lock is released when its holder exits'

for target in app_test APP_TEST mysql sys information_schema performance_schema nonexistent has_table has_routine has_event 'bad-name'; do
    expect_refusal "destination $target" run_tool restore "/backups/$archive" "$target"
done
container_shell "
    printf 'corrupt' >/backups/broken.sql.gz
    { printf -- '-- inat-mysql-backup-v1\\n-- source-database: app_test\\nUSE app_test;\\n'; } | gzip >/backups/wrong-schema.sql.gz
" >/dev/null 2>&1
expect_refusal 'corrupt gzip' run_tool restore /backups/broken.sql.gz restored
expect_refusal 'SQL selecting operational database' run_tool restore /backups/wrong-schema.sql.gz restored
[[ "$(sql --execute="SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='restored'")" == 0 ]]

# Event workers must not start executing newly restored events.
sql --execute='SET GLOBAL event_scheduler=ON'
expect_refusal 'active event scheduler' run_tool restore "/backups/$archive" restored
sql --execute='SET GLOBAL event_scheduler=OFF'

run_tool restore "/backups/$archive" restored >"$test_root/restore.log" 2>&1
[[ "$(sql --execute='SELECT COUNT(*) FROM restored.items')" == 2 ]]
[[ "$(sql --execute='SELECT quantity FROM restored.items WHERE id=1')" == 3 ]]
[[ "$(sql --execute='SELECT label FROM restored.items WHERE id=1')" == 'áéí — teste' ]]
[[ "$(sql --execute='SELECT COUNT(*) FROM restored.available_items')" == 1 ]]
[[ "$(sql --execute='SELECT restored.double_quantity(4)')" == 8 ]]
sql --execute="CALL restored.add_item('restored procedure')"
[[ "$(sql --execute='SELECT COUNT(*) FROM restored.item_audit')" == 3 ]]
[[ "$(sql --execute="SELECT COUNT(*) FROM information_schema.EVENTS WHERE EVENT_SCHEMA='restored' AND EVENT_NAME='daily_item'")" == 1 ]]
[[ "$(sql --execute='SELECT COUNT(*) FROM app_test.items')" == 2 ]]
pass 'restored structure, data, UTF-8, view, function, procedure, event and working trigger; source unchanged'

# Prove the documented partial-import behavior and refusal of a blind retry.
container_shell "
    printf -- '-- inat-mysql-backup-v1\\n-- source-database: app_test\\nCREATE TABLE partly_imported (id INT);\\nINVALID SQL;\\n' | gzip >/backups/import-failure.sql.gz
" >/dev/null 2>&1
expect_refusal 'SQL import error' run_tool restore /backups/import-failure.sql.gz partial_target
grep -q 'may be partially populated' "$test_root/refusal.log"
[[ "$(sql --execute="SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='partial_target'")" == 1 ]]
expect_refusal 'retry into partially populated destination' run_tool restore "/backups/$archive" partial_target
pass 'import failure leaves an explicit warning and blocks reuse of the partial destination'

# Cron runs in the actual backup image, with the same read-only filesystem and TZ mount.
grep -q '^15 2 \* \* \* root /usr/local/bin/mysql-backup cron-backup' "$backup_dir/crontab"
"${compose[@]}" up --detach --wait --wait-timeout 30 mysql-backup >/dev/null
[[ "$("${compose[@]}" exec -T mysql-backup date +%z)" == "$(date +%z)" ]]
printf 'Checking an actual cron invocation (up to 75 seconds)...\n'
cron_completed=false
for attempt in {1..38}; do
    "${compose[@]}" logs --no-color mysql-backup >"$test_root/cron.log" 2>&1
    if grep -q 'backup completed:' "$test_root/cron.log"; then
        cron_completed=true
        break
    fi
    sleep 2
done
[[ "$cron_completed" == true ]]
pass 'production schedule is 02:15; real cron job executes and logs using host timezone'
expect_refusal 'failed dump within running scheduler container' "${compose[@]}" exec -T \
    -e MYSQL_BACKUP_USERNAME=nonexistent_test_user mysql-backup mysql-backup backup
"${compose[@]}" exec -T mysql-backup bash -ceu \
    'test -z "$(find /tmp -name "mysql-backup.*" -print)"; test -z "$(find /backups -name "*.partial" -print)"'
"${compose[@]}" stop --timeout 5 mysql-backup >/dev/null

if grep -Fq -e "$test_password" -e "$test_root_password" "$test_root/check.log" "$test_root/backup.log" "$test_root/restore.log" "$test_root/refusal.log" "$test_root/long-retention.log" "$test_root/cron.log"; then
    printf 'FAIL: credentials appeared in logs\n' >&2
    exit 1
fi
container_shell 'test -z "$(find /backups -name "*.partial" -print)"; test -z "$(find /tmp -name "mysql-backup.*" -print)"' >/dev/null 2>&1
pass 'no credentials in captured logs and no partial archives left behind'
printf 'Integration suite passed. All containers, temporary credentials and data will be removed.\n'
