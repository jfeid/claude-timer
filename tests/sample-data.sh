#!/usr/bin/env bash
# Sample timer data for trying the plugin or reviewing it: three days of
# made-up ABC-* tasks in a project named acme-shop, one of them running.
#   bash tests/sample-data.sh [DIR]      (DIR defaults to a new temp folder)
# Then, in the same shell:
#   export TIMER_HOME=DIR TIMER_PROJECT=acme-shop
#   bin/timer.sh status; bin/timer.sh day; bin/timer.sh month
# or start `claude` there to see /timer and the footer.
set -euo pipefail

dir="${1:-$(mktemp -d)}"
mkdir -p "$dir/logs"
now=$(date +%s); m=60; d=86400
day2=$((now - 2 * d - 4 * 3600))
day1=$((now - d - 5 * 3600))
row() { printf '%s\t%s\t%s\t-\n' "$@"; }
{
    row ABC-110 START $day2;               row ABC-110 STOP $((day2 + 190 * m))
    row ABC-118 START $((day2 + 210 * m)); row ABC-118 STOP $((day2 + 300 * m))
    row ABC-118 START $day1;               row ABC-118 PAUSE $((day1 + 150 * m))
    row ABC-118 RESUME $((day1 + 210 * m)); row ABC-118 STOP $((day1 + 320 * m))
    row ABC-120 START $((now - 160 * m));  row ABC-120 PAUSE $((now - 128 * m))
    row ABC-123 START $((now - 118 * m));  row ABC-123 PAUSE $((now - 75 * m))
    row ABC-123 RESUME $((now - 62 * m))
} > "$dir/logs/acme-shop.tsv"

echo "Sample data in $dir/logs/acme-shop.tsv"
echo "export TIMER_HOME='$dir' TIMER_PROJECT=acme-shop"
