#!/system/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Yudharn
# HyperCool - touch-only refresh rate keeper: <active Hz> <idle Hz> <hold s> [miui 0|1]
# Peak refresh rate = idle Hz (so screen content can't raise it); a touch or a key press sets the
# active Hz, and the idle Hz comes back <hold s> after the last finger is lifted. It sleeps in a
# blocking read on getevent (touch down/up and key lines only), so it uses no CPU while idle.
# HyperOS / MIUI ignore peak_refresh_rate: their own limit is secure miui_refresh_rate, set too.
#   rr_watch.sh <active Hz> <idle Hz> <hold s> <miui 0|1> [app Hz, 0 = none] [adapt|app]
# Lower rate for chosen apps (rr_app.list, one package per line): while one of them is the app on
# screen (cpuset top-app, checked at a touch and after it), every rate is capped at <app Hz>.
# app mode (Adaptive refresh rate off): active and idle are 0 = the rate the ROM had; only the app cap
# changes it, and the ROM values (rr_app.save: <peak>|<miui>|<Hz written>) come back when the app is closed.
#   rr_watch.sh restore   puts back what a killed app-mode keeper left (boot, Revert, uninstall)
export PATH=/system/bin:/system/xbin:/vendor/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/data/adb/magisk:"$PATH"
HC_DATA=/data/adb/hypercool
MODDIR=/data/adb/modules/hypercool
HC_DATA=${HC_DATA_RR:-$HC_DATA}
ACT=$1; IDL=$2; HOLD=${3:-1}; MIUI=${4:-0}; APPHZ=${5:-0}; MODE=${6:-adapt}
PIDF=$HC_DATA/rr_watch.pid
ASAVE=$HC_DATA/rr_app.save
TOPF=${HC_TOPAPP:-/dev/cpuset/top-app/cgroup.procs}
F1=$HC_DATA/rr_watch.raw
F2=$HC_DATA/rr_watch.fifo
[ -f "$MODDIR/common/klog.sh" ] && . "$MODDIR/common/klog.sh" || { klog() { :; }; kstop() { :; }; }

sget() { _sg=$(settings get "$1" "$2" 2>/dev/null); case "$_sg" in ''|null) echo null ;; *) echo "$_sg" ;; esac; }
# put back <ns> <key> <value or null>
sback() {
  if [ "$3" = null ]; then
    cmd settings delete "$1" "$2" </dev/null >/dev/null 2>&1 || settings delete "$1" "$2" </dev/null >/dev/null 2>&1
  else
    cmd settings put "$1" "$2" "$3" </dev/null >/dev/null 2>&1 || settings put "$1" "$2" "$3" </dev/null >/dev/null 2>&1
  fi
  [ "$(sget "$1" "$2")" = "$3" ]
}
# the ROM values from rr_app.save, only while the rate is still the one this keeper wrote
app_back() {
  [ -s "$ASAVE" ] || { rm -f "$ASAVE"; return 0; }
  IFS='|' read -r _ap0 _am0 _aw < "$ASAVE"
  _ok=1
  _an=$(sget system peak_refresh_rate); _an=${_an%%.*}
  if [ "$_an" = "$_aw" ]; then sback system peak_refresh_rate "$_ap0" || _ok=0; fi
  if [ -n "$_am0" ] && [ "$(sget secure miui_refresh_rate)" = "$_aw" ]; then sback secure miui_refresh_rate "$_am0" || _ok=0; fi
  [ "$_ok" = 1 ] && rm -f "$ASAVE"
  [ "$_ok" = 1 ]
}
if [ "$1" = restore ]; then app_back; exit $?; fi
for _a in "$ACT" "$IDL" "$HOLD" "$APPHZ"; do case "$_a" in ''|*[!0-9]*) exit 1 ;; esac; done
case "$MODE" in adapt|app) ;; *) MODE=adapt ;; esac
APPL=""
[ "$APPHZ" -gt 0 ] && APPL=" $(grep -E '^[A-Za-z0-9_]+(\.[A-Za-z0-9_]+)+$' "$HC_DATA/rr_app.list" 2>/dev/null | tr '\n' ' ')"
[ "$APPL" = " " ] && APPL=""
[ "$MODE" = app ] && [ -z "$APPL" ] && exit 1

_old=$(cat "$PIDF" 2>/dev/null)
case "$_old" in ''|*[!0-9]*) ;; *)
  [ "$_old" != "$$" ] && grep -q rr_watch "/proc/$_old/cmdline" 2>/dev/null && kill "$_old" 2>/dev/null; sleep 1 ;;
esac
echo $$ > "$PIDF"

CUR=""; WANT=""; HGP=""; APPCAP=""; ALAST=-9; PEND=0; ANUM=0
# the ROM values in app mode (read once: nothing else of HyperCool writes these while it runs)
P0=""; M0=""
if [ "$MODE" = app ]; then
  app_back
  P0=$(sget system peak_refresh_rate)
  [ "$MIUI" = 1 ] && M0=$(sget secure miui_refresh_rate)
fi
# is one of the chosen apps on screen? (top-app cpuset: the app in front; at most once a second)
app_check() {
  [ -n "$APPL" ] || return 0
  # shellcheck disable=SC3028
  [ $((SECONDS - ALAST)) -ge 1 ] || return 0
  # shellcheck disable=SC3028
  ALAST=$SECONDS
  _ac=""
  while read -r _apd; do
    _apn=""
    # shellcheck disable=SC3045
    { read -d '' -r _apn < "/proc/$_apd/cmdline"; } 2>/dev/null
    _apn=${_apn%%:*}
    case "$APPL" in *" $_apn "*) _ac=$APPHZ; break ;; esac
  done 2>/dev/null < "$TOPF"
  # counted for Keeper status (no log line for every app switch)
  if [ "$_ac" != "$APPCAP" ]; then
    [ -n "$_ac" ] && ANUM=$((ANUM + 1))
    APPCAP=$_ac; rr_state
  fi
}
# the value is read back: a rejected write is not counted, so it is tried again
_hz_now() { # -> the peak rate that is really set right now (Hz, without decimals)
  _hz=$(settings get system peak_refresh_rate 2>/dev/null)
  case "$_hz" in ''|null) return 1 ;; esac
  _hz=${_hz%%.*}
  case "$_hz" in ''|*[!0-9]*) return 1 ;; esac
  echo "$_hz"
}
# put <Hz> [raw]: raw = no Heat guard / app cap (used when the keeper stops, so Heat guard records the
# real value). 0 = the ROM value (app mode) unless a cap applies.
put() {
  _pv=$1
  # Heat guard: while the battery is hot every rate is capped at its value
  _hg=$(cat "$HC_DATA/heat.rr" 2>/dev/null)
  case "$_hg" in ''|*[!0-9]*) _hg="" ;; esac
  # Heat guard came or went: it may have written the rate itself, so write again
  [ "$_hg" != "$HGP" ] && { HGP=$_hg; CUR=""; }
  _cap=$APPCAP
  [ -n "$_hg" ] && { [ -z "$_cap" ] || [ "$_hg" -lt "$_cap" ]; } && _cap=$_hg
  [ "$2" = raw ] && _cap=""
  if [ "$_pv" = 0 ]; then
    _pv=${_cap:-rom}
  elif [ -n "$_cap" ] && [ "$_pv" -gt "$_cap" ]; then
    _pv=$_cap
  fi
  [ "$CUR" = "$_pv" ] && { WANT=$1; return 0; }
  if [ "$_pv" = rom ]; then
    _ok=1
    sback system peak_refresh_rate "$P0" || _ok=0
    [ -n "$M0" ] && { sback secure miui_refresh_rate "$M0" || _ok=0; }
    [ "$_ok" = 1 ] || return 1
    rm -f "$ASAVE"
    CUR=rom; WANT=$1
    return 0
  fi
  # app mode: the ROM values are recorded before the first write
  [ "$MODE" = app ] && echo "$P0|$M0|$_pv" > "$ASAVE"
  cmd settings put system peak_refresh_rate "$_pv.0" </dev/null >/dev/null 2>&1 ||
    settings put system peak_refresh_rate "$_pv.0" </dev/null >/dev/null 2>&1
  _ok=0
  [ "$(_hz_now)" = "$_pv" ] && _ok=1
  if [ "$MIUI" = 1 ] && [ "$_ok" = 1 ]; then
    cmd settings put secure miui_refresh_rate "$_pv" </dev/null >/dev/null 2>&1 ||
      settings put secure miui_refresh_rate "$_pv" </dev/null >/dev/null 2>&1
    [ "$(settings get secure miui_refresh_rate 2>/dev/null)" = "$_pv" ] || _ok=0
  fi
  [ "$_ok" = 1 ] || return 1
  CUR=$_pv; WANT=$1
  return 0
}
PIDS=""
WHY=""
stop() {
  # why it stopped by itself (empty = asked to stop by a signal)
  [ -n "$WHY" ] && kstop refresh "$WHY, back to the normal rate range"
  # shellcheck disable=SC2086
  [ -n "$PIDS" ] && kill $PIDS 2>/dev/null
  rm -f "$F1" "$F2"
  # back to the normal adaptive range (the boot apply or the restore takes it from here)
  put "$ACT" raw || { sleep 1; put "$ACT" raw; }
  [ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"
  exit 0
}
trap stop TERM INT HUP

# input devices with a touchscreen or keys (power / volume); getevent watches only those
DEVS=$(getevent -pl 2>/dev/null | awk '/^add device/ { d = $NF } /BTN_TOUCH|ABS_MT_POSITION_X|KEY_POWER|KEY_VOLUMEDOWN/ { if (d != "" && !(d in s)) { s[d] = 1; print d } }')
[ -n "$DEVS" ] || { echo "no touch / key input device" > "$HC_DATA/rr_watch.state"; rm -f "$PIDF"; klog refresh "Not started" "no touch or key input device found (getevent)"; exit 1; }

rm -f "$F1" "$F2"
mkfifo "$F1" "$F2" || { rm -f "$PIDF"; klog refresh "Not started" "could not create its event pipe in $HC_DATA"; exit 1; }
exec 3<>"$F2"
GPID=""
if echo BTN_TOUCH | grep --line-buffered -qE 'BTN_TOUCH' 2>/dev/null; then
  # getevent output is unbuffered; grep passes on only touch down/up and key lines
  grep --line-buffered -E 'BTN_TOUCH|ABS_MT_TRACKING_ID|EV_KEY +KEY_' < "$F1" >&3 2>/dev/null &
  PIDS=$!
  GPID=$!
  exec 4<>"$F1"
else
  # no line-buffered grep: every event line comes to the loop (a bit more CPU while touching)
  exec 4>&3
fi
for _d in $DEVS; do
  getevent -ql "$_d" >&4 2>/dev/null &
  PIDS="$PIDS $!"
done
exec 4>&-
rr_state() {
  # shellcheck disable=SC2086
  echo "devices=$(echo $DEVS) mode=$MODE active=$ACT idle=$IDL hold=${HOLD}s miui=$MIUI$([ -n "$APPL" ] && echo " app_hz=$APPHZ apps=$(echo $APPL | wc -w) app_now=${APPCAP:+on}${APPCAP:-off} app_times=$ANUM")" > "$HC_DATA/rr_watch.state"
}
rr_state

app_check
put "$IDL"
down=0; btn=0
while :; do
  # at most a minute without an event, so that a disabled module is noticed quickly; after a touch
  # the chosen apps are looked for again <hold s> later (an app opened by that touch is in front then)
  if [ "$down" = 0 ] && [ "$WANT" = "$IDL" ] && [ "$PEND" = 0 ]; then _t=60; elif [ "$down" = 1 ]; then _t=60; else _t=$HOLD; fi
  # shellcheck disable=SC3045
  if read -r -t "$_t" _l <&3; then
    case "$_l" in
      *BTN_TOUCH*DOWN*) btn=1; down=1; app_check; put "$ACT" ;;
      *BTN_TOUCH*UP*) btn=1; down=0; [ -n "$APPL" ] && PEND=1 ;;
      *ABS_MT_TRACKING_ID*)
        # touchscreens that never send BTN_TOUCH: a tracking id starts a touch, ffffffff ends it
        [ "$btn" = 1 ] && continue
        case "$_l" in *ffffffff*) down=0; [ -n "$APPL" ] && PEND=1 ;; *) down=1; app_check; put "$ACT" ;; esac ;;
      *KEY_*DOWN*) app_check; put "$ACT"; [ -n "$APPL" ] && PEND=1 ;;
    esac
    continue
  fi
  # timeout: no touch for <hold s> -> idle rate (and the app in front looked at again)
  PEND=0
  [ "$down" = 0 ] && { app_check; put "$IDL"; }
  [ -f "$MODDIR/disable" ] || [ -f "$MODDIR/remove" ] || [ ! -d "$MODDIR" ] && { WHY="module disabled or removed"; stop; }
  if [ "$MODE" = app ]; then
    grep -q '^rr_app=1' "$HC_DATA/config.conf" 2>/dev/null || { WHY="Lower rate for chosen apps turned off in the settings"; stop; }
  else
    grep -q '^rr_adapt=1' "$HC_DATA/config.conf" 2>/dev/null || { WHY="Adaptive refresh rate turned off in the settings"; stop; }
    grep -q '^rr_app=1' "$HC_DATA/config.conf" 2>/dev/null || { APPL=""; APPCAP=""; }
  fi
  # the event feed died (all getevent gone): nothing more to watch
  _alive=0
  for _p in $PIDS; do [ -d "/proc/$_p" ] && _alive=1; done
  [ "$_alive" = 1 ] || { WHY="touch events stopped coming (getevent ended)"; stop; }
  # the filter process died: the touch events would no longer come through, so stop instead of
  # keeping a rate that never changes again
  [ -n "$GPID" ] && { kill -0 "$GPID" 2>/dev/null || { WHY="the touch event filter ended"; stop; }; }
done
