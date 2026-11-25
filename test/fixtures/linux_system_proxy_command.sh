#!/bin/sh
set -eu

fixture=${PROXYPIN_LINUX_PROXY_FIXTURE:?}
command=${0##*/}
case "$command" in
  gsettings)
    [ "$1" = set ]
    case "$2" in
      org.gnome.system.proxy) key="gnome-$3" ;;
      org.gnome.system.proxy.*) key="gnome-${2##*.}-$3" ;;
      *) exit 64 ;;
    esac
    value=$4
    if [ "${PROXYPIN_TEST_NO_GSETTINGS_SCHEMA:-}" = 1 ]; then
      printf 'No such schema "%s"\n' "$2" >&2
      exit 1
    fi
    if [ -n "${PROXYPIN_TEST_SYSTEM_PROXY_LOG:-}" ]; then
      printf '%s\n' "$*" >> "$PROXYPIN_TEST_SYSTEM_PROXY_LOG"
    fi
    ;;
  kwriteconfig5|kwriteconfig6)
    [ "$2" = "$XDG_CONFIG_HOME/kioslaverc" ]
    [ "$4" = 'Proxy Settings' ]
    [ "$5" = --key ]
    key="kde-$6"
    value=$7
    ;;
  *) exit 64 ;;
esac

result=0
if [ -f "$fixture/failures" ] && /bin/grep -Fxq -- "$key=$value" "$fixture/failures"; then
  result=42
fi
printf '%s %s=%s exit=%s\n' "$command" "$key" "$value" "$result" >> "$fixture/commands.log"
if [ "$result" -ne 0 ]; then
  printf '%s\n' 'injected proxy write failure' >&2
  exit "$result"
fi
printf '%s\n' "$value" > "$fixture/$key"
