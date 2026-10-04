#!/usr/bin/env bash
# Collect diagnostics for "Access denied" / "Sender is not authorized" errors
# from `nixos-rebuild switch` on exe.dev. Needs no TTY: no pagers, no colors,
# every command time-limited, all output written to a file.
#
#   sudo bash scripts/debug-dbus.sh            # writes /tmp/dbus-debug.txt
#   sudo bash scripts/debug-dbus.sh out.txt    # custom output path

out="${1:-/tmp/dbus-debug.txt}"
export SYSTEMD_PAGER=cat PAGER=cat SYSTEMD_COLORS=0 NO_COLOR=1 TERM=dumb LC_ALL=C

run() {
  echo "### $*"
  timeout 15 "$@" </dev/null 2>&1
  local rc=$?
  echo
  echo "### rc=$rc"
  echo
}

{
  echo "=== dbus debug $(date -u +%FT%TZ) ==="
  echo

  echo "===== identity / kernel ====="
  run id
  run uname -a
  run ps -o args= -p 1
  run cat /proc/self/cgroup
  run cat /proc/self/loginuid
  run cat /sys/kernel/security/lsm
  run cat /sys/fs/selinux/enforce
  run cat /sys/module/apparmor/parameters/enabled

  echo "===== system generations ====="
  run readlink -f /init /run/current-system /run/booted-system /nix/var/nix/profiles/system

  echo "===== systemd state ====="
  run systemctl is-system-running
  run systemctl --failed --no-pager --no-legend
  run systemctl status dbus.service dbus-broker.service dbus.socket --no-pager -l

  echo "===== bus processes ====="
  run ps -eo pid,user,args --no-headers -C dbus-broker,dbus-broker-launch,dbus-daemon
  run ls -la /run/dbus

  echo "===== dbus journal ====="
  run journalctl -b --no-pager -o short-monotonic -u dbus -u dbus-broker -u dbus.socket

  echo "===== users / nss ====="
  run getent passwd root messagebus exedev
  run getent group messagebus
  run ls -la /etc/passwd /etc/group /etc/shadow /etc/nsswitch.conf
  run cat /etc/nsswitch.conf

  echo "===== dbus config on disk ====="
  run ls -la /etc/dbus-1
  conf="$(readlink -f /etc/dbus-1/system.conf)"
  run echo "system.conf -> $conf"
  for d in $(grep -o 'includedir>[^<]*' "$conf" 2>/dev/null | cut -d'>' -f2); do
    run ls -la "$d"
  done
  for d in $(grep -o 'includedir>[^<]*' "$conf" 2>/dev/null | cut -d'>' -f2); do
    [ -f "$d/org.freedesktop.systemd1.conf" ] && run grep -n -A3 'policy user="root"' "$d/org.freedesktop.systemd1.conf"
  done
  run ls -la /etc/dbus-1/system.d /usr/share/dbus-1/system.d

  echo "===== bus calls as root ====="
  run busctl --no-pager call org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus GetConnectionCredentials s org.freedesktop.systemd1
  run busctl --no-pager get-property org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager Version
  run busctl --no-pager call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager Subscribe
  run busctl --no-pager call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit s dbus.service
  run systemd-run --quiet --wait --collect --no-ask-password /run/current-system/sw/bin/true

  echo "===== bus calls as exedev (for comparison) ====="
  run runuser -u exedev -- busctl --no-pager call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager GetUnit s dbus.service

  echo "===== recent warnings ====="
  run journalctl -b --no-pager -p warning -n 80 -o short-monotonic
} >"$out" 2>&1

echo "wrote $out ($(wc -l <"$out") lines)"
