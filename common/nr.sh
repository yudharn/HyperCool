#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - 5G off (sourced by soff_watch.sh, heat_watch.sh, functions.sh, restore.sh and uninstall.sh)
# Two keepers can ask for it: the screen-off keeper (owner soff) and Heat guard (owner heat).
#   nr_want <owner> 1|0  ask for / drop 5G off    nr_sync  apply what the owners want now
# 5G off = NR is taken out of the allowed network types of every SIM (Android 12+, telephony shell
# command, "user" reason, the same setting as the network type in Settings). 4G stays allowed.
# nr.save: <slot>|<types before, binary>|<types written, binary>. A slot goes back only while it
# still has the types HyperCool wrote: a network type you change yourself in the meantime is kept.
# Nothing is switched during a phone call or while the hotspot / USB tethering is on (return 2).
NRD=${HC_DATA:-/data/adb/hypercool}
NRSAVE=$NRD/nr.save
NRUNSUP=$NRD/nr.unsup
NRBIT=$((1 << 19))

# allowed network types of a slot as a number (empty = no SIM there or not readable)
nr_get() {
  _ng=$(cmd phone get-allowed-network-types-for-users -s "$1" </dev/null 2>/dev/null | tr -d '\r' | head -n 1)
  case "$_ng" in ''|*rror*|*xception*|*"No valid"*|*nknown*|UNKNOWN) return 1 ;; esac
  # names of TelephonyManager.getNetworkTypeName joined by "|"; compared without spaces, "_" and "-"
  echo "$_ng" | awk -F'|' '
    BEGIN {
      n = "GPRS:1 EDGE:2 UMTS:3 CDMA:4 CDMAEVDOREV.0:5 EVDO0:5 CDMAEVDOREV.A:6 EVDOA:6 CDMA1XRTT:7 1XRTT:7 HSDPA:8 HSUPA:9 HSPA:10 IDEN:11 CDMAEVDOREV.B:12 EVDOB:12 LTE:13 CDMAEHRPD:14 EHRPD:14 HSPA+:15 HSPAP:15 GSM:16 TDSCDMA:17 IWLAN:18 LTECA:19 NR:20"
      c = split(n, a, " ")
      for (i = 1; i <= c; i++) { split(a[i], kv, ":"); id[kv[1]] = kv[2] }
    }
    {
      m = 0
      for (i = 1; i <= NF; i++) {
        t = toupper($i); gsub(/[ \t_-]/, "", t)
        if (t == "") continue
        if (!(t in id)) exit 1
        if (!(t in seen)) { m += 2 ^ (id[t] - 1); seen[t] = 1 }
      }
      if (m == 0) exit 1
      printf "%d\n", m
    }'
}
nr_bin() { # number -> 20-digit binary
  _nb=""; _ni=19
  while [ "$_ni" -ge 0 ]; do _nb="$_nb$(( ($1 >> _ni) & 1 ))"; _ni=$((_ni - 1)); done
  echo "$_nb"
}
nr_num() { # binary -> number
  _nn=0; _ns=$1
  while [ -n "$_ns" ]; do _nn=$(( _nn * 2 + ${_ns%"${_ns#?}"} )); _ns=${_ns#?}; done
  echo "$_nn"
}
nr_set() { cmd phone set-allowed-network-types-for-users -s "$1" "$(nr_bin "$2")" </dev/null >/dev/null 2>&1; }
# a call on any SIM, or tethering: leave the network alone now (a call state that cannot be read = busy)
nr_busy() {
  _ncs=$(dumpsys telephony.registry </dev/null 2>/dev/null | grep 'mCallState=')
  [ -n "$_ncs" ] || return 0
  printf '%s\n' "$_ncs" | grep -qvE 'mCallState=0([^0-9]|$)' && return 0
  dumpsys tethering </dev/null 2>/dev/null | grep -qE '^[[:space:]]*[A-Za-z0-9_.-]+ - TetheredState' && return 0
  for _nt in /sys/class/net/ap* /sys/class/net/swlan* /sys/class/net/rndis* /sys/class/net/ncm* /sys/class/net/bt-pan*; do
    [ "$(cat "$_nt/operstate" 2>/dev/null)" = up ] && return 0
  done
  return 1
}
nr_want() { if [ "$2" = 1 ]; then : > "$NRD/nr.want.$1"; else rm -f "$NRD/nr.want.$1"; fi; }
nr_wanted() { ls "$NRD"/nr.want.* >/dev/null 2>&1; }
nr_lock() {
  _nw=0
  while ! mkdir "$NRD/nr.lock" 2>/dev/null; do
    # left by a keeper that was killed: the pid in it is gone (or it is older than 2 min)
    _nlp=$(cat "$NRD/nr.lock/pid" 2>/dev/null)
    # (a zombie that nobody reaped yet has an empty command line)
    if { [ -n "$_nlp" ] && ! grep -q . "/proc/$_nlp/cmdline" 2>/dev/null; } || [ -n "$(find "$NRD/nr.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ]; then
      rm -rf "$NRD/nr.lock"; continue
    fi
    _nw=$((_nw + 1)); [ "$_nw" -ge 20 ] && return 1
    sleep 1
  done
  echo $$ > "$NRD/nr.lock/pid"
}
nr_unlock() { rm -rf "$NRD/nr.lock"; }

# 0 done (or nothing to do), 2 busy (call / tethering, try again later), 3 not possible on this phone
# nr.unsup: <slot>|<why> for a SIM that did not accept the change (left alone until the next boot)
nr_off() {
  nr_busy && return 2
  [ -e "$NRSAVE" ] || : > "$NRSAVE"
  _nok=0
  for _sl in 0 1; do
    grep -q "^$_sl|" "$NRSAVE" 2>/dev/null && { _nok=1; continue; }
    grep -q "^$_sl|" "$NRUNSUP" 2>/dev/null && continue
    _cur=$(nr_get "$_sl") || continue
    # 5G is not allowed on this SIM anyway
    [ $((_cur & NRBIT)) -ne 0 ] || { _nok=1; continue; }
    _new=$((_cur & ~NRBIT))
    # recorded first: a keeper killed right after the switch can still put it back
    echo "$_sl|$(nr_bin "$_cur")|$(nr_bin "$_new")" >> "$NRSAVE"
    nr_set "$_sl" "$_new"
    _rb=$(nr_get "$_sl")
    # the modem can answer a moment later
    [ "$_rb" = "$_new" ] || { sleep 2; _rb=$(nr_get "$_sl"); }
    if [ "$_rb" = "$_new" ]; then
      _nok=1
    else
      # not taken: nothing changed, so nothing to put back (a different value is left to nr_on)
      [ "$_rb" = "$_cur" ] && sed -i "/^$_sl|/d" "$NRSAVE" 2>/dev/null
      if [ "$_rb" = "$_cur" ]; then
        echo "$_sl|SIM $((_sl + 1)) kept 5G: the ROM did not take the new network type" >> "$NRUNSUP"
      else
        echo "$_sl|SIM $((_sl + 1)): the network type read back is not the one written (${_rb:-not readable})" >> "$NRUNSUP"
      fi
    fi
  done
  [ "$_nok" = 0 ] && [ -s "$NRUNSUP" ] && return 3
  return 0
}
# 0 all back, 2 later (call / tethering or not accepted yet)
nr_on() {
  [ -s "$NRSAVE" ] || return 0
  nr_busy && return 2
  _nk=""
  while IFS='|' read -r _sl _ob _wb; do
    case "$_sl" in [0-9]) ;; *) continue ;; esac
    _cur=$(nr_get "$_sl") || { _nk="$_nk$_sl|$_ob|$_wb
"; continue; }
    # changed by you or the ROM in the meantime: keep that
    [ "$_cur" = "$(nr_num "$_wb")" ] || continue
    nr_set "$_sl" "$(nr_num "$_ob")"
    [ "$(nr_get "$_sl")" = "$(nr_num "$_ob")" ] && continue
    sleep 2
    [ "$(nr_get "$_sl")" = "$(nr_num "$_ob")" ] || _nk="$_nk$_sl|$_ob|$_wb
"
  done < "$NRSAVE"
  if [ -n "$_nk" ]; then printf '%s' "$_nk" > "$NRSAVE"; return 2; fi
  : > "$NRSAVE"
  return 0
}
# apply what the owners want: off while one of them asks for it, back on when none does
nr_sync() {
  nr_lock || return 2
  if nr_wanted; then
    if [ -f "$NRD/nr.applied" ]; then _nrc=0; else nr_off; _nrc=$?; [ "$_nrc" = 0 ] && : > "$NRD/nr.applied"; fi
  else
    rm -f "$NRD/nr.applied"
    nr_on; _nrc=$?
  fi
  nr_unlock
  return $_nrc
}
