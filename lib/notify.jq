# CI-state classifier for notify.sh: takes `gh pr view --json statusCheckRollup`
# and emits a "STATE\tHUMAN STATUS" line, STATE in pending/pass/fail; on fail,
# followed by one line per failed check name.
# Known limitation: a PR with no CI checks configured stays "pending" forever.

include "common";

# ciFail, ciPending and latestChecks (a check that ran twice counts by its latest run) come from common.jq.
latestChecks as $checks
| ($checks | length) as $total
| ($checks | map(select(ciFail(.))) | length) as $failed
| ($checks | map(select(ciPending(.))) | length) as $pending
| if $total == 0 then "pending\tno checks reported yet…"
  elif $failed > 0 then
    ( "fail\t\($failed)/\($total) checks failed",
      # CheckRuns have .name (+ .workflowName for Actions jobs — render
      # "workflow / job" like the GitHub UI); StatusContexts have .context
      ($checks[] | select(ciFail(.))
        | if (.workflowName // "") != "" then "  ✗ \(.workflowName) / \(.name)"
          else "  ✗ \(.name // .context // "(unnamed check)")"
          end) )
  elif $pending > 0 then "pending\t\($total - $failed - $pending)/\($total) checks done…"
  else "pass\tall \($total) checks passed"
  end
