#!/usr/bin/env bash
#
# CymbalGoal Lab 3 (mkt015) — deadline-day workload control.
#
# WHERE: Cloud Shell.
#   bash workload/deadline-day.sh run       run in the FOREGROUND — what Task 0 does
#   bash workload/deadline-day.sh start     background it — recovery only
#   bash workload/deadline-day.sh status    is it running, and how fast
#   bash workload/deadline-day.sh report    latency percentiles by app tag
#   bash workload/deadline-day.sh stop      graceful stop
#
# ⚠️ `run` IS WHAT THE LAB USES, and the foreground is the entire point.
# Rewritten 2026-08-22, replacing a nohup-backgrounded design.
#
# Cloud Shell reclaims idle sessions. Tasks 1-4 are twenty to thirty minutes of
# console work each with nobody touching the terminal, so a backgrounded
# workload dies during exactly the tasks that need it — and it dies SILENTLY.
# The student reaches Task 3, runs the Index Advisor, and is told there is
# nothing to fix, which reads as the product being broken.
#
# A foreground process that prints a summary line every ten seconds fixes both
# halves: it keeps the session busy, and if it ever does stop, the student is
# looking at the tab where it stopped. `start` is kept for recovery from a
# second tab and for anyone scripting this outside the lab.
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
  run)
    if alive; then
      echo "Already running (pid $(cat "${PIDFILE}")) — probably in your other tab."
      echo "Stop it first with: bash ${BASH_SOURCE[0]} stop"
      exit 0
    fi
    rm -f "${STOPFILE}"
    # exec preserves this shell's PID, so `status` and `stop` from a second tab
    # still find the process. A stale pidfile is harmless — alive() checks ps.
    echo $$ > "${PIDFILE}"
    exec python3 "${HERE}/deadline_day.py" "${@:2}"
    ;;
  start)
    if alive; then
      echo "Already running (pid $(cat "${PIDFILE}")). Nothing to do."
      exit 0
    fi
    rm -f "${STOPFILE}"
    nohup python3 "${HERE}/deadline_day.py" "${@:2}" > "${LOG}" 2>&1 &
    echo $! > "${PIDFILE}"
    echo "deadline-day workload started in the background, pid $(cat "${PIDFILE}")"
    echo "  log:    ${LOG}"
    echo "  stop:   bash ${BASH_SOURCE[0]} stop"
    echo
    echo "  ⚠️ Backgrounding does NOT survive a Cloud Shell session timing out."
    echo "     Prefer 'run' in a tab you leave open."
    ;;
  status)
    if alive; then
      echo "running, pid $(cat "${PIDFILE}")"
      tail -3 "${LOG}" 2>/dev/null
    else
      echo "not running"
      echo "  restart it with: bash ${BASH_SOURCE[0]} run"
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
    echo "usage: $0 {run|start|status|report|stop}"
    exit 2
    ;;
esac
