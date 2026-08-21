#!/usr/bin/env bash
#
# CymbalGoal Lab 3 (mkt015) — Task 0 setup launcher.
#
# WHERE: Cloud Shell.
# RUN:   bash setup/lab3-setup.sh
#
# Installs the client library, then BACKGROUNDS the load and returns you to the
# prompt immediately. When the load finishes it starts the deadline-day
# workload, so by the time anyone opens a monitoring surface there is something
# to see.
#
# ⚠️ WHY THE WORKLOAD STARTS HERE AND NOT IN THE TASK THAT USES IT.
# Query Insights shows HISTORY, and history takes time to accumulate. A student
# who starts the workload at the top of Task 2 spends the first minutes of Task
# 2 looking at an empty chart and concluding the product is broken. Starting it
# in Task 0 buys twenty minutes of history for free — the same trick Lab 2 uses
# to hide its data load behind the reading of Task 1.
#
# Safe to re-run: every step in lab3-setup.py is guarded by an existence check,
# and the workload launcher refuses to start a second copy.
#
# Environment knobs, all optional:
#   CG_PROFILES=0        skip the profile/embedding pass (~22 s faster)
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
echo "Starting the CymbalGoal load in the background."
echo "  log: ${LOG}"
echo

nohup bash -c "
  python3 '${HERE}/lab3-setup.py'
  rc=\$?
  if [ \"\$rc\" -eq 0 ] && [ '${START_WORKLOAD}' != '0' ]; then
    echo
    echo '### Starting the deadline-day workload ###'
    bash '${REPO}/workload/deadline-day.sh' start
  fi
  exit \$rc
" > "${LOG}" 2>&1 &
PID=$!
echo "  pid: ${PID}"

cat <<EOF

  This takes a few minutes. You do not need to wait for it — carry on with the
  next task and it will be finished by the time you need the data.

  Watch it:         tail -f ${LOG}
  Check it's alive: ps -p ${PID}

  ⚠️ If you close this Cloud Shell tab the process keeps running (nohup), but a
  Cloud Shell session that TIMES OUT entirely will kill it. Re-run this script
  if that happens — it picks up where it left off.

EOF
