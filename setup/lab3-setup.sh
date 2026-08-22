#!/usr/bin/env bash
#
# CymbalGoal Lab 3 (mkt015) — Task 0 setup and workload launcher.
#
# WHERE: Cloud Shell.
# RUN:   bash setup/lab3-setup.sh
#
# ⚠️ RUNS IN THE FOREGROUND AND NEVER RETURNS. Rewritten 2026-08-22.
#
# The previous version backgrounded the load with nohup, handed the prompt back
# in twenty seconds, and chained into a backgrounded workload. Two things killed
# that design:
#
#   1. The load takes about three minutes and the task the student reads while
#      it runs is about five minutes long. The parallelism bought almost
#      nothing, and it cost a log-tailing step to get the output back.
#
#   2. THE WORKLOAD HAS TO SURVIVE TASKS 1-4, which are console work. Cloud
#      Shell reclaims idle sessions, nohup does not survive VM reclaim, and the
#      terminal sits untouched for twenty to thirty minutes during exactly the
#      tasks that require load. It died three times in one prototype session.
#      A foreground process printing every ten seconds keeps the session busy
#      and makes a failure visible instead of silent.
#
# So: load in the foreground, tee to a log for troubleshooting, then hand off to
# the workload, which owns this tab for the rest of the lab. The student opens a
# SECOND Cloud Shell tab for everything else, and Task 0.2 tells them to.
#
# Safe to re-run: every step in lab3-setup.py is guarded by an existence check.
#
# Environment knobs, all optional:
#   CG_PROFILES=0        skip the profile/embedding pass (~22 s faster)
#                        ⚠️ also drops profile_text, which scout-search needs
#   CG_SYNTHETIC=25      also build a 25-million-row ticker table, server-side
#   CG_WORKLOAD=0        load only, do not start the workload

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
LOG="${HOME}/cymbalgoal-setup.log"
START_WORKLOAD="${CG_WORKLOAD:-1}"

echo "Installing client libraries..."
# --quiet keeps a wall of pip output off the projector. pandas is NOT needed —
# this is the load, not the analysis.
python3 -m pip install --quiet --upgrade \
  "google-cloud-alloydb-connector[pg8000]" 2>&1 | tail -2

echo
echo "Loading the CymbalGoal database. This takes about three minutes."
echo "  a copy of everything below is saved to ${LOG}"
echo

python3 "${HERE}/lab3-setup.py" 2>&1 | tee "${LOG}"
rc=${PIPESTATUS[0]}

if [ "${rc}" -ne 0 ]; then
  cat <<EOF

  ⚠️  The load did not finish cleanly (exit ${rc}).

  Re-run this script. Every step is guarded by an existence check, so it picks
  up where it left off rather than starting over:

      bash ${BASH_SOURCE[0]}

EOF
  exit "${rc}"
fi

if [ "${START_WORKLOAD}" = "0" ]; then
  echo
  echo "Load complete. Workload NOT started (CG_WORKLOAD=0)."
  echo "Start it yourself with: bash ${REPO}/workload/deadline-day.sh run"
  exit 0
fi

cat <<'EOF'

==============================================================
 ✅  LOAD FINISHED — you can stop watching this tab now.
==============================================================

 NEXT   This tab is about to become the deadline-day traffic
        simulator. It starts in a few seconds and keeps running
        until you stop it.

        You will see a few startup lines, then a summary line
        beginning "last 10s" every ten seconds. Once one of
        those appears, traffic is flowing and there is nothing
        left to watch here.

 DO     Open a SECOND Cloud Shell tab with the + button and
        carry on with Task 0.2. Every command from here on
        runs in that second tab.

 DO NOT close this tab or type in it. Press Ctrl+C here only
        when you have finished the entire lab.

==============================================================

EOF

for n in 5 4 3 2 1; do
  printf "\r starting the traffic simulator in %s... " "${n}"
  sleep 1
done
printf "\r starting the traffic simulator now.        \n\n"

exec bash "${REPO}/workload/deadline-day.sh" run
