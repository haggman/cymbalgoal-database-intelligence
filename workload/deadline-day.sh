#!/usr/bin/env bash
#
# CymbalGoal Lab 3 (mkt015) — deadline-day workload control.
#
# WHERE: Cloud Shell.
#   bash workload/deadline-day.sh start     background the workload
#   bash workload/deadline-day.sh status    is it running, and how fast
#   bash workload/deadline-day.sh report    latency percentiles by app tag
#   bash workload/deadline-day.sh stop      graceful stop
#
# `report` is the one that matters pedagogically: run it before a fix and after
# a fix, and the difference is the lesson. It reads the generator's own samples
# rather than the console, so it works even when a console surface is lagging.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIDFILE="${HERE}/.pids"
STOPFILE="${HERE}/.stop"
LOG="${HOME}/cymbalgoal-workload.log"

alive() { [ -f "${PIDFILE}" ] && ps -p "$(cat "${PIDFILE}")" >/dev/null 2>&1; }

case "${1:-status}" in
  start)
    if alive; then
      echo "Already running (pid $(cat "${PIDFILE}")). Nothing to do."
      exit 0
    fi
    rm -f "${STOPFILE}"
    nohup python3 "${HERE}/deadline_day.py" "${@:2}" > "${LOG}" 2>&1 &
    echo $! > "${PIDFILE}"
    echo "deadline-day workload started, pid $(cat "${PIDFILE}")"
    echo "  log:    ${LOG}"
    echo "  stop:   bash ${BASH_SOURCE[0]} stop"
    ;;
  status)
    if alive; then
      echo "running, pid $(cat "${PIDFILE}")"
      tail -3 "${LOG}" 2>/dev/null
    else
      echo "not running"
    fi
    ;;
  report)
    python3 "${HERE}/deadline_day.py" --report
    ;;
  stop)
    touch "${STOPFILE}"
    echo "stop requested; workers finish their current statement and exit"
    sleep 3
    if alive; then kill "$(cat "${PIDFILE}")" 2>/dev/null; fi
    rm -f "${PIDFILE}"
    ;;
  *)
    echo "usage: $0 {start|status|report|stop}"
    exit 2
    ;;
esac
