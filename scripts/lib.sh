#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for scripts/*.sh (state-surface registry, generated docs).
# Sourced, never run. Needs bash 4+ and jq (the kit already requires jq).

# read_file <var> <path> — the file's exact bytes in the variable <var>,
# trailing newlines included (a plain `x=$(cat f)` would eat them, and the
# generators compare exact bytes).
read_file() {
  local c
  c=$(
    cat "$2"
    printf x
  )
  printf -v "$1" '%s' "${c%x}"
}

# replace_block <var> <text> <start-marker> <end-marker> <block> — sets <var>
# to <text> with everything from the first <start-marker> through the first
# <end-marker> replaced by <block> (which carries its own markers). Returns 1
# when either marker is missing. Sets a variable rather than printing, so the
# text's trailing newlines survive.
replace_block() {
  local var=$1 text=$2 start=$3 end=$4 block=$5
  case $text in
    *"$start"*"$end"*) ;;
    *) return 1 ;;
  esac
  printf -v "$var" '%s%s%s' "${text%%"$start"*}" "$block" "${text#*"$end"}"
}

# day_number <YYYY-MM-DD> — days since 1970-01-01 on stdout; returns 1 when the
# argument is not a real calendar day (so 2026-02-30 is rejected). Pure
# arithmetic: no GNU/BSD `date` differences.
day_number() {
  local y m d dim leap
  [[ $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
  y=$((10#${BASH_REMATCH[1]}))
  m=$((10#${BASH_REMATCH[2]}))
  d=$((10#${BASH_REMATCH[3]}))
  ((m >= 1 && m <= 12 && d >= 1)) || return 1
  leap=0
  if ((y % 4 == 0 && y % 100 != 0 || y % 400 == 0)); then leap=1; fi
  case $m in
    2) dim=$((28 + leap)) ;;
    4 | 6 | 9 | 11) dim=30 ;;
    *) dim=31 ;;
  esac
  ((d <= dim)) || return 1
  local era yoe doy doe
  if ((m <= 2)); then y=$((y - 1)); fi
  era=$(((y >= 0 ? y : y - 399) / 400))
  yoe=$((y - era * 400))
  doy=$(((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1))
  doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  echo $((era * 146097 + doe - 719468))
}

# today_utc — today's date, YYYY-MM-DD, UTC.
today_utc() { date -u +%Y-%m-%d; }
