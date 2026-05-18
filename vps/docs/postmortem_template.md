# Postmortem - <one-line summary> (<YYYY-MM-DD>)

> Copy this template to `postmortem_YYYY-MM-DD_short-slug.md` for each new incident.

## TL;DR
One paragraph. The root cause, the impact, the fix.

## Facts
| Field | Value |
|-------|-------|
| Incident date(s) | YYYY-MM-DD HH:MM UTC -> YYYY-MM-DD HH:MM UTC |
| Detection date | YYYY-MM-DD HH:MM UTC |
| Severity | (critical / high / medium / low) |
| Component(s) | (e.g. coterie-webapp-alpha, argocd, postgres) |
| Detection source | (alert name, manual report, monitoring dashboard, customer report...) |
| User-facing impact | (e.g. alpha.macoterie.fr down for 48 days, 0% availability) |

## Timeline
- YYYY-MM-DD HH:MM - Event 1 (e.g. deploy of revision X)
- YYYY-MM-DD HH:MM - Event 2 (e.g. first pod restart)
- YYYY-MM-DD HH:MM - Event 3 (e.g. alert fired)
- YYYY-MM-DD HH:MM - Event 4 (e.g. SSH investigation started)
- YYYY-MM-DD HH:MM - Event 5 (e.g. root cause identified)
- YYYY-MM-DD HH:MM - Event 6 (e.g. fix deployed)

## Root cause
Explain *what* broke and *why*. Include code references with absolute paths if relevant, e.g. `helm/coterie-webapp/values-alpha.yaml:107`.

## Evidence
Quote logs, stacktraces, metrics screenshots. Reference the artifact bundle if applicable.

```text
<paste relevant log line(s) here>
```

## Why didn't we catch it earlier
Honest assessment. Was there a missing alert? A broken dashboard? Tribal knowledge that nobody acted on?

## Resolution
The steps taken to fix the problem (PR links, commit hashes, runbook references).

## Action items
For each item, attribute an owner and a due date. Distinguish "must do" from "nice to have".

- [ ] Action 1 (owner: @name, due: YYYY-MM-DD, status: open)
- [ ] Action 2 (owner: @name, due: YYYY-MM-DD, status: open)
- [ ] Action 3 (owner: @name, due: YYYY-MM-DD, status: open)

## Lessons learned
What classes of bugs does this surface? What process or tooling change would prevent the next one?

## References
- Runbook: `vps/docs/runbook_pod_crashes.md`
- Observability stack: `vps/docs/observability.md`
- Related postmortems: `postmortem_YYYY-MM-DD_...md`
