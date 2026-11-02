# `.agents/` — the agents' operating manual

The reusable skills and operational knowledge that AI agents use to build Val Ark. Governed by
[`../AGENTS.md`](../AGENTS.md), which also defines how this folder is maintained and improved.

This is the **agent-operational** layer (how the pipeline is run). The **product** knowledge —
code gotchas, architecture decisions, git workflow — lives in
[`../docs/knowledge/`](../docs/knowledge/README.md). When in doubt: "how do I run a release?" →
here; "why does NodeBB burst-503?" → `docs/knowledge/`.

The git strategy in [`workflow.md`](../docs/knowledge/workflow.md) and the trust / CI / governance
model in [`governance.md`](../docs/knowledge/governance.md) are **implemented by the skills here** —
those docs state the rules; these skills carry them out (branch → PR → Gate 1 → release → Gate 2).

## Skills (`skills/`)

| Skill | Use it when |
|-------|-------------|
| [`worker-protocol.md`](skills/worker-protocol.md) | You are implementing one issue: branch → fix → test → PR. |
| [`review.md`](skills/review.md) | You are reviewing someone else's PR or a release diff (Gate 1 / Gate 2). |
| [`issue-discovery.md`](skills/issue-discovery.md) | You are hunting for real, confirmed issues to file. |
| [`release.md`](skills/release.md) | You are cutting a `dev → main` release and tagging it. |
| [`recovery.md`](skills/recovery.md) | A session restarted, a limit was hit, or a worker died — resume without losing work. |

## Knowledge (`knowledge/`)

| File | Contents |
|------|----------|
| [`pipeline-insights.md`](knowledge/pipeline-insights.md) | Hard-won operational insights about running the multi-agent pipeline. |

## Rules of the road (summary — full text in `../AGENTS.md`)

1. Public repo → **never** write host names, IPs, creds, or host paths anywhere.
2. Fail closed on safety; zero server deps; never push to `main`.
3. Save every reusable trick here in the same change that taught it; dedupe and prune.

---

↑ [Repo root](../README.md) · [Doc map](../docs/README.md) · [Agent manual](../AGENTS.md) · [Knowledge base](../docs/knowledge/README.md)
