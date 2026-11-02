#!/usr/bin/env bash
# Smoke test for the locally running system: routing, auth, roles, events, isolation.
# Run from anywhere inside WSL/Linux after scripts/local-up.sh.
cd "$(dirname "$0")/.." || exit 1
set -a; . infra/.env; . .env.local; set +a
DC="docker compose --env-file infra/.env --env-file .env.local -f docker-compose.local.yaml"
B=${1:-http://localhost:${WEB_PORT:-80}}
T_USER=$ADMIN_USER;    T_PASS=$ADMIN_PASSWORD
S_USER=$STUDENT_USER;  S_PASS=$STUDENT_PASSWORD
TJ=$(mktemp); SJ=$(mktemp)
trap 'rm -f "$TJ" "$SJ"' EXIT
JSON='Content-Type: application/json'
FAIL=0
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
login() { code -c "$1" -X POST $B/api/login -H "$JSON" -d "{\"role\":\"$2\",\"username\":\"$3\",\"password\":\"$4\"}"; }
check() { # label actual expected
  if [ "$2" = "$3" ]; then printf '  ok    %-38s %s\n' "$1" "$2"
  else printf '  FAIL  %-38s got %s, expected %s\n' "$1" "$2" "$3"; FAIL=1; fi
}
redis() { $DC exec -T redis redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"; }

echo "== public =="
check "landing /"            "$(code $B/)" 200
check "healthz"              "$(code $B/healthz)" 200
check "login.html"           "$(code $B/login.html)" 200
check "reg.html (no login)"  "$(code $B/reg.html)" 302
check "api studdetails"      "$(code $B/api/studdetails)" 401
check "forged cookie"        "$(code -H 'Cookie: edupulse_session=abc' $B/api/studdetails)" 401
check "forged session id"    "$(code -H "Cookie: edupulse_session=$(printf 'a%.0s' {1..64})" $B/api/studdetails)" 401
check "spoofed X-User-Role"  "$(code -H 'X-User-Role: teacher' $B/api/studdetails)" 401
check "wrong password"       "$(login /dev/null teacher admin nope)" 401
check "student creds as teacher" "$(login /dev/null teacher $S_USER $S_PASS)" 401

echo "== teacher =="
check "login"                "$(login $TJ teacher $T_USER $T_PASS)" 200
check "home.html"            "$(code -b $TJ $B/home.html)" 200
check "add student"          "$(curl -s -b $TJ -X POST $B/api/addStudent -H "$JSON" -d '{"rollNo":9001,"name":"Smoke Test","age":20,"marks":88,"image_url":""}')" "Student added successfully"
check "list"                 "$(curl -s -b $TJ $B/api/studdetails | grep -c 'Smoke Test')" 1
check "csv"                  "$(code -b $TJ $B/api/downloadAllStudents)" 200
check "audit log"            "$(code -b $TJ $B/api/audit)" 200

echo "== student (read-only) =="
check "login"                "$(login $SJ student $S_USER $S_PASS)" 200
check "student-portal"       "$(code -b $SJ $B/student-portal.html)" 200
check "dashboard.html"       "$(code -b $SJ $B/dashboard.html)" 200
check "list"                 "$(code -b $SJ $B/api/studdetails)" 200
check "reg.html"             "$(code -b $SJ $B/reg.html)" 302
check "add student"          "$(code -b $SJ -X POST $B/api/addStudent -H "$JSON" -d '{}')" 403
check "edit student"         "$(code -b $SJ -X PUT $B/api/editStudent/9001 -H "$JSON" -d '{}')" 403
check "delete student"       "$(code -b $SJ -X DELETE $B/api/deleteStudent/9001)" 403
check "csv download"         "$(code -b $SJ $B/api/downloadAllStudents)" 403
check "audit log"            "$(code -b $SJ $B/api/audit)" 403

echo "== events (RabbitMQ -> audit-service) =="
check "teacher delete"       "$(curl -s -b $TJ -X DELETE $B/api/deleteStudent/9001)" "Student deleted successfully"
sleep 2
AUDIT=$(curl -s -b $TJ $B/api/audit)
for ev in auth.login auth.login_failed student.added student.deleted; do
  check "audit has $ev" "$(echo "$AUDIT" | grep -q "\"event_type\":\"$ev\"" && echo yes || echo no)" yes
done

echo "== sessions live in Redis =="
check "sessions stored in redis" "$([ "$(redis --scan --pattern 'sess:*' | wc -l)" -ge 2 ] && echo yes || echo no)" yes
check "logout"               "$(code -b $TJ -c $TJ -X POST $B/api/logout)" 200
check "after logout"         "$(code -b $TJ $B/api/studdetails)" 401

echo "== brute-force lockout =="
last=0
for i in 1 2 3 4 5 6 7 8; do   # each attempt claims to come from a different IP
  last=$(code -X POST $B/api/login -H "$JSON" -H "X-Forwarded-For: 203.0.113.$i" -d '{"role":"teacher","username":"admin","password":"bad"}')
done
check "lockout despite spoofed XFF" "$last" 429
for k in $(redis --scan --pattern 'fail:*' | tr -d '\r'); do redis del "$k" >/dev/null; done

echo "== isolation =="
published=$($DC ps --format '{{.Service}}|{{.Ports}}' | grep -- '0.0.0.0' | cut -d'|' -f1 | sort -u | tr '\n' ' ')
check "only frontend is public"     "${published% }" frontend
check "frontend cannot reach db"    "$($DC exec -T frontend sh -c 'getent hosts db >/dev/null 2>&1 && echo reachable || echo blocked')" blocked
check "frontend cannot reach redis" "$($DC exec -T frontend sh -c 'getent hosts redis >/dev/null 2>&1 && echo reachable || echo blocked')" blocked
check "frontend cannot reach rabbitmq" "$($DC exec -T frontend sh -c 'getent hosts rabbitmq >/dev/null 2>&1 && echo reachable || echo blocked')" blocked
check "frontend runs as non-root"   "$($DC exec -T frontend id -u | grep -qv '^0$' && echo yes || echo no)" yes
check "audit user cannot touch student_db" "$($DC exec -T db mysql -uaudit -p"$AUDIT_DB_PASSWORD" -N -e 'SELECT COUNT(*) FROM student_db.students' 2>&1 | grep -q 'denied' && echo denied || echo allowed)" denied

echo
[ $FAIL = 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
