#!/bin/sh
# ctl — call the dsh-ctl control plane on the host that runs it.
#
# Designed to run ON the DSH host and talk to loopback, so remote use is just:
#     ssh <host> ctl sessions --running
# That keeps JSON out of two layers of shell quoting.
#
# Environment:
#   DSH_CTL_PORT   port of the dsh web server (default 17390)
#   DSH_CTL_BASE   full base URL override, e.g. http://127.0.0.1:17390
#   DSH_CTL_SECRET shared secret, when the plugin config sets one
set -eu

BASE="${DSH_CTL_BASE:-http://127.0.0.1:${DSH_CTL_PORT:-17390}}"

json_escape() {
  # Escape backslash, double quote, CR, and LF for a JSON string literal.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} {gsub(/\r/,""); if (NR>1) printf "\\n"; printf "%s", $0}'
}

auth_args() {
  if [ -n "${DSH_CTL_SECRET:-}" ]; then
    printf '%s' "-H"
    printf ' %s' "Authorization: Bearer ${DSH_CTL_SECRET}"
  fi
}

need_curl() {
  command -v curl >/dev/null 2>&1 || { echo "ctl: curl is required" >&2; exit 1; }
}

usage() {
  cat <<'EOF'
usage: ctl <command> [args]

  health
  sessions [--limit N] [--running]
  session <session-id>
  create [--cwd PATH] [--preset NAME]
  prompt <session-id> <text...>
  cancel <session-id>
  rename <session-id> <title...>
  tail <session-id> [--frames N] [--ms N]
  shape <session-id> [--type RECORD_TYPE]

Environment: DSH_CTL_PORT (default 17390), DSH_CTL_BASE, DSH_CTL_SECRET
EOF
}

cmd="${1:-}"
[ -n "$cmd" ] || { usage; exit 1; }
shift || true

need_curl

case "$cmd" in
  health)
    curl -sS -H "Accept: application/json" $(auth_args) "$BASE/ctl/health"; echo
    ;;

  sessions)
    limit=50; running=0
    while [ $# -gt 0 ]; do
      case "$1" in
        --limit) limit="$2"; shift 2 ;;
        --running) running=1; shift ;;
        *) echo "ctl: unknown flag $1" >&2; exit 1 ;;
      esac
    done
    curl -sS $(auth_args) "$BASE/ctl/sessions?limit=$limit&running=$running"; echo
    ;;

  session)
    [ $# -ge 1 ] || { echo "ctl: session <session-id>" >&2; exit 1; }
    curl -sS $(auth_args) "$BASE/ctl/session?id=$(printf '%s' "$1" | sed 's/ /%20/g')"; echo
    ;;

  create)
    cwd=""; preset=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --cwd) cwd="$2"; shift 2 ;;
        --preset) preset="$2"; shift 2 ;;
        *) echo "ctl: unknown flag $1" >&2; exit 1 ;;
      esac
    done
    body="{"
    sep=""
    if [ -n "$cwd" ]; then body="$body$sep\"cwd\":\"$(json_escape "$cwd")\""; sep=","; fi
    if [ -n "$preset" ]; then body="$body$sep\"agentPreset\":\"$(json_escape "$preset")\""; sep=","; fi
    body="$body}"
    curl -sS -X POST -H "content-type: application/json" $(auth_args) -d "$body" "$BASE/ctl/create"; echo
    ;;

  prompt)
    [ $# -ge 2 ] || { echo "ctl: prompt <session-id> <text...>" >&2; exit 1; }
    sid="$1"; shift
    text="$*"
    body="{\"sessionId\":\"$(json_escape "$sid")\",\"text\":\"$(json_escape "$text")\"}"
    curl -sS -X POST -H "content-type: application/json" $(auth_args) -d "$body" "$BASE/ctl/prompt"; echo
    ;;

  cancel)
    [ $# -ge 1 ] || { echo "ctl: cancel <session-id>" >&2; exit 1; }
    body="{\"sessionId\":\"$(json_escape "$1")\"}"
    curl -sS -X POST -H "content-type: application/json" $(auth_args) -d "$body" "$BASE/ctl/cancel"; echo
    ;;

  rename)
    [ $# -ge 2 ] || { echo "ctl: rename <session-id> <title...>" >&2; exit 1; }
    sid="$1"; shift
    title="$*"
    body="{\"sessionId\":\"$(json_escape "$sid")\",\"title\":\"$(json_escape "$title")\"}"
    curl -sS -X POST -H "content-type: application/json" $(auth_args) -d "$body" "$BASE/ctl/rename"; echo
    ;;

  tail)
    [ $# -ge 1 ] || { echo "ctl: tail <session-id> [--frames N] [--ms N]" >&2; exit 1; }
    sid="$1"; shift
    frames=40; ms=3000
    while [ $# -gt 0 ]; do
      case "$1" in
        --frames) frames="$2"; shift 2 ;;
        --ms) ms="$2"; shift 2 ;;
        *) echo "ctl: unknown flag $1" >&2; exit 1 ;;
      esac
    done
    curl -sS $(auth_args) "$BASE/ctl/tail?sessionId=$(printf '%s' "$sid" | sed 's/ /%20/g')&frames=$frames&ms=$ms"; echo
    ;;

  shape)
    [ $# -ge 1 ] || { echo "ctl: shape <session-id> [--type RECORD_TYPE]" >&2; exit 1; }
    sid="$1"; shift
    type="assistant/message"
    while [ $# -gt 0 ]; do
      case "$1" in
        --type) type="$2"; shift 2 ;;
        *) echo "ctl: unknown flag $1" >&2; exit 1 ;;
      esac
    done
    curl -sS $(auth_args) "$BASE/ctl/debug/shape?sessionId=$(printf '%s' "$sid" | sed 's/ /%20/g')&type=$(printf '%s' "$type" | sed 's#/#%2F#g')"; echo
    ;;

  -h|--help|help)
    usage
    ;;

  *)
    echo "ctl: unknown command $cmd" >&2
    usage
    exit 1
    ;;
esac
