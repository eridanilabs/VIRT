#!/usr/bin/env bash
# Source after beads-common.sh. Operator-enrolled, fixed-loopback RC route.
# No native init, lifecycle or raw SQL API.
# Functions are dispatched by beads-common.sh and the bounded runner.
# shellcheck disable=SC2329

die() { beads_error "$*"; exit 1; }
server_hash() {
  local value
  value=$(/usr/bin/openssl dgst -sha256 "$1") || return $?
  value=${value##* }
  [[ "$value" =~ ^[a-f0-9]{64}$ ]] || return 1
  printf '%s\n' "$value"
}
server_bounded() {
  local ticks=$1 now
  shift
  now=$(beads_now_ms) || return 1
  [ "$now" -lt "$BEADS_SERVER_DEADLINE" ] || {
    printf '%s\n' "Beads: server command exhausted the hook/operation deadline" >&2
    return 124
  }
  # The supervisor caps its absolute deadline against this same shared clock,
  # without rounding remaining time or resetting the budget between calls.
  beads_run_bounded "$ticks" "$@"
}
beads_server_init() {
BEADS_SERVER_DEADLINE=${BEADS_SERVER_DEADLINE:-$(beads_deadline_after 20)} || return 1
store=${BEADS_DIR:?selected store required}
actor=${BEADS_ACTOR:?actor required}
for tool in jq git dolt bd /usr/bin/openssl lsof; do beads_require "$tool"; done
enrollment="$store/server-enrollment.json"
for file in metadata.json config.yaml server-enrollment.json server-password; do
  [ -f "$store/$file" ] && [ ! -L "$store/$file" ] || die "server route requires a regular local $file"
done
for file in .env config.local.yaml redirect; do
  [ ! -e "$store/$file" ] && [ ! -L "$store/$file" ] || die "server route rejects $file"
done
for file in server-enrollment.json server-password; do
  git -C "$store" check-ignore -q "$store/$file" || die "$file must be gitignored and operator supplied"
  [ -z "$(git -C "$store" ls-files -- "$store/$file")" ] || die "$file must not be tracked"
done
[ "$(uname -s)" = Darwin ] || die "server route is supported only on macOS (requires BSD stat and lsof)"
[ "$(stat -f '%Lp:%u' "$store/server-password")" = "600:$(id -u)" ] ||
  die "server-password must be owned by this user with mode 600 (macOS harness)"

# Reject ambient routing aliases rather than letting native Viper reinterpret
# them. The password comes only from the local secret, never from inherited env.
overrides=$(env | sed -n -e '/^BD_/s/=.*//p' -e '/^BEADS_/s/=.*//p' |
  sed -e '/^BEADS_DIR$/d' -e '/^BEADS_ACTOR$/d' -e '/^BEADS_ROUTE$/d' -e '/^BEADS_SERVER_HELPER$/d' \
      -e '/^BD_DISABLE_METRICS$/d' -e '/^BD_DISABLE_EVENT_FLUSH$/d')
[ -z "$overrides" ] || die "unsupported server routing environment: $overrides"

umask 077
# Private captured inputs stay inside the consumer checkout. Atomic mkdir
# never reuses an existing path or follows a preplanted symlink.
scratch="$CONSUMER_GIT_COMMON_DIR/agent-harness-runtime-$$-$RANDOM"
mkdir "$scratch" || die "cannot allocate private runtime directory"
beads_server_cleanup() { rm -rf -- "$scratch"; }
trap beads_server_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir "$scratch/home" "$scratch/tmp" "$scratch/bin" "$scratch/store"
mkdir "$scratch/home/.dolt"
printf '%s\n' '{"versioncheck.disabled":"true","metrics.disabled":"true"}' > "$scratch/home/.dolt/config_global.json"
# Validate the exact captured inputs that will be used, not a second read.
cp "$enrollment" "$scratch/enrollment.json"
cp "$store/metadata.json" "$store/config.yaml" "$scratch/store/"
cp "$store/server-password" "$scratch/password"
for file in "$scratch/enrollment.json" "$scratch/store/metadata.json" "$scratch/store/config.yaml"; do
  if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$file" >/dev/null ||
    ! { jq --stream -c . "$file" |
      jq -e -s 'map(select(length == 2) | .[0]) | group_by(.) | all(.[]; length == 1)' >/dev/null; }; then
    die "server inputs must be single JSON objects without duplicate keys"
  fi
done
jq -e '
  type == "object" and
  (keys == ["commit_policy","database","host","password_file","port","project_id","server_pid","user","version"]) and
  .version == 1 and .commit_policy == "all-versioned-tables" and
  .host == "127.0.0.1" and .password_file == "server-password" and
  (.database | type == "string" and test("^[A-Za-z][A-Za-z0-9_]{0,62}$") and . != "beads_global") and
  (.project_id | type == "string" and test("^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$")) and
  (.user | type == "string" and test("^[A-Za-z][A-Za-z0-9_]{0,31}$")) and
  (.port | type == "number" and floor == . and . >= 1024 and . <= 65535) and
  (.server_pid | type == "number" and floor == . and . > 1)
' "$scratch/enrollment.json" >/dev/null || die "invalid or ambiguous server enrollment"
server_database=$(jq -r .database "$scratch/enrollment.json")
project=$(jq -r .project_id "$scratch/enrollment.json")
port=$(jq -r .port "$scratch/enrollment.json")
user=$(jq -r .user "$scratch/enrollment.json")
pid=$(jq -r .server_pid "$scratch/enrollment.json")
jq -e --slurpfile e "$scratch/enrollment.json" '
  (keys == ["backend","database","dolt_database","dolt_mode","dolt_server_host","dolt_server_port","dolt_server_user","project_id"]) and
  .backend == "dolt" and .database == "dolt" and .dolt_mode == "server" and
  .dolt_database == $e[0].database and .project_id == $e[0].project_id and
  .dolt_server_host == $e[0].host and .dolt_server_port == $e[0].port and
  .dolt_server_user == $e[0].user
' "$scratch/store/metadata.json" >/dev/null || die "local server metadata does not match enrollment"
# JSON is a YAML subset. Exact policy avoids another YAML parser, hidden nested
# overrides, native backup/push automation and commit exclusions.
jq -e '. == {
  "backup.enabled":false,"sync.auto-push":false,"dolt.auto-commit":"off",
  "dolt.auto-start":false,"dolt.shared-server":false,
  "routing.mode":"explicit","routing.default":"."
}' "$scratch/store/config.yaml" >/dev/null || die "server config.yaml must match the documented JSON policy"

for tool in bd dolt; do
  path=$(command -v "$tool")
  # type -P bypasses the shared bd function when finding the native executable.
  [ "$tool" != bd ] || path=$(type -P bd)
  [ -f "$path" ] && [ -x "$path" ] || die "missing native binary: $tool"
  while [ -L "$path" ]; do
    link=$(readlink "$path")
    case "$link" in /*) path=$link ;; *) path="$(dirname "$path")/$link" ;; esac
  done
  path="$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")"
  if [ "$tool" = bd ]; then server_bd=$path; else server_dolt=$path; fi
  hash=$(server_hash "$path") || die "cannot hash native binary: $tool"
  # Retain an inode/hash witness. Execute the resolved original path only after
  # rehashing, avoiding macOS cold execution checks on newly named binaries.
  # Never follow the original package-manager symlink again during this process.
  ln "$path" "$scratch/bin/$tool" 2>/dev/null || cp "$path" "$scratch/bin/$tool"
  copied=$(server_hash "$scratch/bin/$tool") || die "cannot hash captured binary: $tool"
  [ "$hash" = "$copied" ] || die "native binary changed during capture: $tool"
  printf '%s\n' "$copied" > "$scratch/$tool.sha256"
done
password=$(cat "$scratch/password")
[ -n "$password" ] && [[ "$password" != *$'\n'* ]] || die "server-password must be one nonempty line"
# Never pass a password on argv, log it, or load user/system credentials.
safe_env=(env -i
  "HOME=$scratch/home" "XDG_CONFIG_HOME=$scratch/home/config"
  "XDG_CACHE_HOME=$scratch/home/cache" "XDG_DATA_HOME=$scratch/home/data"
  "TMPDIR=$scratch/tmp" "PATH=$(dirname "$server_dolt"):$(dirname "$server_bd"):/usr/bin:/bin"
  "BEADS_DIR=$scratch/store" "BEADS_ACTOR=$actor"
  "BEADS_DOLT_SERVER_HOST=127.0.0.1" "BEADS_DOLT_SERVER_PORT=$port"
  "BEADS_DOLT_SERVER_USER=$user" "BEADS_DOLT_SERVER_MODE=1"
  "BEADS_DOLT_AUTO_START=0" "BEADS_DOLT_SHARED_SERVER=0"
  "BD_DISABLE_METRICS=1" "BD_DISABLE_EVENT_FLUSH=1" "DOLT_DISABLE_EVENT_FLUSH=1"
  "DO_NOT_TRACK=1" "NO_COLOR=1" "CI=true" "LANG=en_US.UTF-8"
  "USER=beads-wrapper" "LOGNAME=beads-wrapper"
  "GIT_CONFIG_NOSYSTEM=1" "GIT_CONFIG_GLOBAL=/dev/null" "GIT_TERMINAL_PROMPT=0"
  "GIT_CONFIG_COUNT=2" "GIT_CONFIG_KEY_0=core.hooksPath" "GIT_CONFIG_VALUE_0=/dev/null"
  "GIT_CONFIG_KEY_1=credential.helper" "GIT_CONFIG_VALUE_1=")
safe_run() {
  local current expected status
  if current=$(server_hash "$1") &&
    expected=$(cat "$scratch/$(basename "$1").sha256"); then :; else
    status=$?
    printf '%s\n' "Beads: cannot read captured executable hash before dispatch" >&2
    return "$status"
  fi
  [ "$current" = "$expected" ] || { beads_error "captured executable changed before dispatch"; return 1; }
  if [ "$1" = "$server_bd" ]; then
    if current=$(server_hash "$server_dolt") &&
      expected=$(cat "$scratch/dolt.sha256"); then :; else
      status=$?
      printf '%s\n' "Beads: cannot read captured Dolt child hash before dispatch" >&2
      return "$status"
    fi
    [ "$current" = "$expected" ] ||
      { beads_error "captured Dolt child executable changed before dispatch"; return 1; }
  fi
  # env's assignments are argv too. Load the secret inside the sanitized child,
  # not in env's argument list. The shell code is fixed, never evaluated input.
  # shellcheck disable=SC2016
  "${safe_env[@]}" /bin/bash -c '
    BEADS_DOLT_PASSWORD=$(cat "$1") || exit
    export BEADS_DOLT_PASSWORD
    export DOLT_CLI_PASSWORD="$BEADS_DOLT_PASSWORD"
    shift
    exec "$@"
  ' beads-native "$scratch/password" "$@"
}
native() { safe_run "$server_bd" --sandbox --dolt-auto-commit=off "$@"; }
direct() {
  # CWD is private too: the direct client never discovers any operator store.
  (cd "$scratch" && safe_run "$server_dolt" --host 127.0.0.1 --port "$port" \
    --user "$user" --use-db "$server_database" --no-tls sql -r json -q "$1")
}
version=$(server_bounded 40 safe_run "$server_bd" --version)
[[ "$version" = "bd version 1.3.0-rc.1 (9c6a69ec1)"* || "$version" = "bd version 1.3.0 "* ]] ||
  die "server routing requires pinned bd 1.3.0-rc.1 (9c6a69ec1) or bd 1.3.0 (stable)"
version=$(server_bounded 40 safe_run "$server_dolt" version)
[ "$version" = "dolt version 2.2.0" ] || die "server routing requires Dolt 2.2.0"
# PID is operator-supplied, never discovered/adopted from native .port files.
# Reject additional listeners (including a wildcard bind) on that process.
listener=$(server_bounded 20 lsof -nP -a -p "$pid" -iTCP -sTCP:LISTEN -Fn) ||
  die "enrolled server PID is unavailable"
[ "$(printf '%s\n' "$listener" | sed -n '/^n/p')" = "n127.0.0.1:$port" ] ||
  die "enrolled PID is not exclusively listening on the fixed loopback endpoint"
executable=$(ps -p "$pid" -o comm=)
[ -f "$executable" ] || die "cannot verify enrolled server executable"
hash=$(server_hash "$executable") || die "cannot hash enrolled server executable"
copied=$(server_hash "$scratch/bin/dolt") || die "cannot hash captured server executable"
[ "$hash" = "$copied" ] || die "server executable differs from captured Dolt"
identity=$(server_bounded 20 direct "SELECT DATABASE() AS db, value AS project_id FROM metadata WHERE \`key\` = '_project_id'") ||
  die "strict server identity SELECT failed; no bd operational command was run"
printf '%s\n' "$identity" | jq -e --arg db "$server_database" --arg id "$project" \
  '.rows == [{db:$db,project_id:$id}]' >/dev/null ||
  die "strict server identity is missing, ambiguous or mismatched"
policy=$(server_bounded 20 direct "SELECT pattern, ignored FROM dolt_ignore ORDER BY pattern")
printf '%s\n' "$policy" | jq -e '
  (.rows | map(.pattern) | sort) ==
  (["bd_events_journal","bd_events_seq","events","ignored_schema_migrations","leases","local_metadata","repo_mtimes","wisp_%","wisps"] | sort) and
  all(.rows[]; .ignored == "1")
' >/dev/null || die "unapproved Dolt ignore policy; refusing excluded or unexpectedly versioned tables"
context=$(server_bounded 20 native context --json 2>&1)
printf '%s\n' "$context" | jq -e --arg dir "$scratch/store" --arg db "$server_database" --argjson port "$port" '
  (.bd_version == "1.3.0-rc.1" or .bd_version == "1.3.0") and .beads_dir == $dir and .database == $db and
  .dolt_mode == "server" and .server_host == "127.0.0.1" and .server_port == $port and
  (has("proxied_dir") | not)
' >/dev/null || die "native context conflicts with captured server enrollment"
}

beads_server_dispatch() {
local mutation guarded arg command status remote identity flag value seen argc
local args=()
[ "${1:-}" != --preflight ] || { [ "$#" = 1 ] || die "invalid preflight"; return 0; }
# Every operational dispatch rechecks identity on the fixed endpoint. Config,
# credentials and binaries are the process-private copies attested at resolve.
identity=$(server_bounded 20 direct "SELECT DATABASE() AS db, value AS project_id FROM metadata WHERE \`key\` = '_project_id'") ||
  { beads_error "server is unavailable; no operational command was run"; return 1; }
printf '%s\n' "$identity" | jq -e --arg db "$server_database" --arg id "$project" \
  '.rows == [{db:$db,project_id:$id}]' >/dev/null ||
  { beads_error "server identity changed; refusing dispatch"; return 1; }
# Deliberately small command surface. No raw SQL, schema/config/remote/lifecycle
# changes, arbitrary nested RMW, global flags or native flag abbreviations.
mutation=0
case "${1:-}" in
  context|info|ready|show|list|recall|memories) ;;
  create|remember) mutation=1 ;;
  update)
    mutation=1
    ;;
  dolt)
    case "${2:-}" in
      commit|push|pull) ;;
      *) die "server route permits only dolt commit/push/pull, not lifecycle/config/remote operations" ;;
    esac ;;
  *) die "unsupported server command; use the documented distinct-owner subset" ;;
esac
command=$1
shift
argc=$#
args=("$@")
seen="|"
guarded=0
while [ "$#" -gt 0 ]; do
  arg=$1; shift
  flag=${arg%%=*}
  case "$flag" in
    --json|--claim)
      [ "$arg" = "$flag" ] || die "boolean overrides are unsupported"
      [ "$flag" != --claim ] || guarded=1
      ;;
    --key|--id|--title|--description|--type|--parent|--priority|--labels|--notes|--status|--if-assignee|--if-status|--limit|-m|--message|--metadata)
      if [ "$flag" = --metadata ] && [ "$command" != create ]; then
        die "shared metadata updates are unsupported: nested replacement has no revision CAS"
      fi
      if [ "$arg" != "$flag" ]; then value=${arg#*=}; else
        [ "$#" -gt 0 ] || die "missing value for $flag"
        value=$1; shift
      fi
      case "$value" in -*) die "flag-like option values are unsupported" ;; esac
      if [ "$flag" = --if-assignee ] && [ "$value" = "$actor" ]; then guarded=1; fi
      ;;
    -*) die "unsupported server flag: $arg" ;;
    *) continue ;;
  esac
  case "$seen" in *"|$flag|"*) die "duplicate server flag: $flag" ;; esac
  seen="$seen$flag|"
done
# Bash 3.2 treats an empty array expansion as unbound under nounset.
if [ "$argc" -gt 0 ]; then set -- "${args[@]}"; else set --; fi
if [ "$command" = update ] && [ "$guarded" != 1 ]; then
  die "server update requires --claim or --if-assignee matching BEADS_ACTOR; task ownership is required"
fi
commit_all() {
  # CommitAll intentionally includes config and all other versioned tables,
  # possibly containing other owners' accepted writes. Enrollment acknowledges
  # this store-wide boundary; it is not a per-command transaction or a lease.
  local status state
  if server_bounded 50 native dolt commit -m "bd wrapper: enrolled all-versioned-tables boundary" >&2; then
    status=0
  else
    status=$?
    printf '%s\n' "Beads: explicit commit failed; writes may already exist, inspect before retrying" >&2
    return "$status"
  fi
  if state=$(server_bounded 20 direct "SELECT * FROM dolt_status"); then :; else
    status=$?
    printf '%s\n' "Beads: postcommit status query failed; accepted writes may exist and durability is uncertain; inspect before retrying" >&2
    return "$status"
  fi
  printf '%s\n' "$state" | jq -e '. == {} or .rows == []' >/dev/null ||
    { beads_error "working set is not clean after explicit commit; durability is uncertain (possibly concurrent writes)"; return 1; }
}
if [ "$command" = dolt ] && { [ "${1:-}" = push ] || [ "${1:-}" = commit ]; }; then
  [ "$#" = 1 ] || die "enrolled dolt commit/push accept no extra arguments"
  commit_all || return $?
  [ "$1" != commit ] || return 0
fi
if [ "$command" = dolt ] && { [ "${1:-}" = push ] || [ "${1:-}" = pull ]; }; then
  # No native "no remote, skipping" success and no origin adoption/config write.
  remote=$(server_bounded 20 direct "SELECT name FROM dolt_remotes WHERE name = 'origin'") || return $?
  printf '%s\n' "$remote" | jq -e '.rows == [{name:"origin"}]' >/dev/null ||
    die "enrolled sync requires an existing origin Dolt remote; no remote was adopted"
  if [ "$1" = push ]; then
    server_bounded 50 native dolt push --remote origin --no-adopt
  else
    [ "$#" = 1 ] || die "enrolled dolt pull accepts no extra arguments"
    server_bounded 50 native dolt pull --remote origin
  fi
else
  if server_bounded 50 native "$command" "$@"; then status=0; else status=$?; fi
  if [ "$status" != 0 ]; then
    if [ "$mutation" = 1 ]; then
      printf '%s\n' "Beads: mutation outcome may be uncertain; preserve its key/ID and original error, inspect before retrying" >&2
    fi
    return "$status"
  fi
  if [ "$mutation" = 1 ]; then commit_all || return $?; fi
fi
}
