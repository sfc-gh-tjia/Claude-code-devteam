PY ?= python3
REF = $(PY) harness/referee.py

.PHONY: doctor verify status ledger reap tokens harness-test

doctor:            ## preflight: deps, ports, credentials, git state
	$(REF) --strict doctor

verify:            ## every gate on the current tree (the definition of done)
	$(REF) --strict --inline gate

status:            ## task states, small JSON
	$(REF) status

ledger:            ## regenerate work/ledger.md
	$(REF) ledger

reap:              ## remove merged worktrees, branches and logs
	$(REF) reap

tokens:            ## token/cost telemetry from Claude Code transcripts
	$(PY) harness/tokens.py

harness-test:      ## test the harness itself
	$(PY) -m pytest -q -p no:cacheprovider harness/tests
