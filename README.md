# Minimal fullsend on the OKD single-node cluster

Status: **deployed and green.** A triage run completes end-to-end inside the
cluster: Job → OpenShell gateway → sandbox pod → OpenCode → local Ollama →
GitHub tools → schema-validated result.

First successful run (`fullsend-triage-7kgg8`, 2026-11-09):

```
✓ Validation passed: output/agent-result.json against triage-result.schema.json
    Agent exit code: 0   Agent runs: 1   Validation: passed
    Sandbox deleted
fullsend exit=0
```

15 turns, 18 tool calls, 1 iteration; result `action: insufficient` with
clarity scores and label actions.

Post-script pass (`fullsend-triage` on the same issue) also green:

```
✓ Agent exited with code 0 (293.4s)
✓ Validation passed
✓ Sandbox deleted (1.4s)
• Running post-script: /harness/scripts/post-triage.sh
::warning::Refused to add control label 'bug' -- control labels are managed by the triage pipeline
Posting comment...
Post-triage complete.
✓ Post-script completed (4.8s)
fullsend exit=0
```

The pipeline applied `needs-info` and posted the clarifying comment
(comment 6754741457). It refused the agent's suggested `bug` label by design:
control labels belong to the triage pipeline. Comments, labels and commits are
authored by the `fullsend-code` GitHub App bot (see below).

## Topology actually deployed

```
Job (ns fullsend)  image fullsend-runner-okd:dev
  fullsend run triage --runtime opencode --model ollama/Qwen3.8-27B
    └─ openshell CLI ── HTTPS/OIDC ──► openshell-gateway (ns <openshell-namespace>)
         └─ sandbox pod + supervisor pod + PVC (ns <openshell-namespace>-default)
              └─ OpenCode 1.19.1 ── L7 proxy ──► http://<model-host>:8080 (llama)
```

* The cluster already runs OpenShell `v0.1.6-rhaiv.4` with the **kubernetes**
  compute driver, so no Podman, no nested containers, no privileged SCC.
* The runner image is `ghcr.io/fullsend-ai/fullsend-runner:latest` plus the
  `openshell` 0.1.6-rhaiv.4 binary, the `fullsend` binary built from this
  checkout, and the patched agents harness at `/harness`.

## GitHub App identity

The dispatcher and every agent Job authenticate as the `fullsend-code` GitHub
App (App id `$GH_APP_ID`, installation `$GH_INSTALLATION_ID`), not as a PAT. Commits, PRs,
comments and labels are therefore attributed to `fullsend-code[bot]`, which keeps
agent work separable from human work on GitHub.

- `Secret/fullsend-github-app` holds `app-id`, `installation-id` and
  `private-key`; it is mounted read-only at `/var/run/secrets/github-app`.
- The dispatcher and `scripts/run-agent.sh` mint a 1-hour installation token at
  container start with `scripts/mint-app-token.sh` (RS256 JWT signed with
  `openssl`; the OKD image installs the openssl CLI for this).
- `run-agent.sh` resolves the bot user's `databaseId` through GraphQL `viewer`
  (installation tokens cannot call REST `GET /user`) and exports
  `GIT_BOT_EMAIL=<id>+fullsend-code[bot]@users.noreply.github.com`, which
  `harness/code.yaml` expands into `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL`.
- Installation tokens are fixed at 1 hour, so code Jobs run with
  `activeDeadlineSeconds: 3300` (55 min): the post-script push must happen
  before the token expires.
- The cutover changed the dispatcher's identity, so `eyes` reaction markers left
  by the PAT no longer count as "already dispatched".
  `scripts/fix-cutover-comment-markers.sh` backfills them once.
- Ad-hoc Jobs that still inject `GH_TOKEN` from `Secret/fullsend-github` keep
  working: without `GITHUB_APP_ID` the scripts skip minting. Only the CronJob
  and the Jobs it creates use the App.

Verify the App path end to end:

```sh
bash .opencode/scripts/app-discover.sh $GH_APP_ID .opencode/tmp/fullsend-code.private-key.pem
bash .opencode/scripts/verify-github-app.sh $GH_APP_ID $GH_INSTALLATION_ID \
  .opencode/tmp/fullsend-code.private-key.pem RoddieKieley/fs-scratch-0
```

## Multiple projects

Projects are declared in `ConfigMap/fullsend-projects` (`projects.json`) and the
dispatcher loops them. Adding a project does not touch code:

```json
{ "key": "fs1", "repo": "RoddieKieley/fs-scratch-1",
  "installation_id": "<your-installation-id>", "enabled": true,
  "poll_seconds": 300, "deadline_seconds": 3300,
  "max_code": 1, "max_triage": 1, "triage_max_age_days": 14,
  "model_code": "gateway/qwen38", "model_triage": "ollama/Qwen3.8-27B" }
```

| Field | Meaning |
|---|---|
| `key` | short id used in Job labels (`fullsend/repo=<key>`), Job names and logs. Must be a valid label value (no `/`) |
| `installation_id` | GitHub App installation for that repo; same account ⇒ same id. Defaults to `GITHUB_APP_INSTALLATION_ID` |
| `poll_seconds` | scan cadence for this project (detection latency), gated by `ConfigMap/fullsend-dispatch-state` |
| `deadline_seconds` | code Job `activeDeadlineSeconds`; **capped at 3300** because the installation token is minted at container start and lives one hour |
| `triage_deadline_seconds` | triage Job deadline, default 2400 |
| `max_code` / `max_triage` | per-project concurrency; a global ceiling (`FULLSEND_MAX_CONCURRENT_*`) applies on top |
| `triage_max_age_days` | discovery window for new issues |
| `model_code` / `model_triage` / `image` | per-project overrides |
| `code_order` | `newest` (default) or `oldest` — scan order for `ready-to-code` issues. `oldest` sorts by issue creation, which is not the same as when the label was applied |

Two CronJobs, because the timings differ:

| CronJob | Schedule | Work |
|---|---|---|
| `fullsend-reconcile` | `*/2` | flips `fullsend/<stage>-running` to `-succeeded`/`-failed` using Job state. No discovery, no gate — a project's poll interval never delays stage labels |
| `fullsend-scan` | `*/5` | discovery, only for projects whose `poll_seconds` has elapsed |

The dispatcher creates the Job **before** writing the running label, so the
fast reconcile loop can never see a running label with no Job behind it.

Adding project #2:

```sh
bash .opencode/scripts/ensure-labels.sh RoddieKieley/fs-scratch-1
# add the entry to k8s/projects-config.yaml, then:
bash .opencode/scripts/deploy-multiproject.sh
bash .opencode/scripts/verify-github-app.sh $GH_APP_ID $GH_INSTALLATION_ID \
  .opencode/tmp/fullsend-code.private-key.pem RoddieKieley/fs-scratch-1
```

Offline check of the manifest logic (no cluster needed):

```sh
bash .opencode/scripts/test-dispatch-manifest.sh
```

## Remote model providers (EnMaaS)

Remote models are **not** called by agents directly. They are model groups on the
in-cluster LiteLLM, so one pod holds the remote credential and one pod needs
egress; agents keep using the gateway key they already have.

| Piece | Value |
|---|---|
| Secret | `Secret/enmaas-api-key` in `fullsend-inference`, key `api-key` (never in the ConfigMap, never in `fullsend`) |
| Config | `scripts/deploy-litellm.sh` → `ConfigMap/litellm-config` |
| Deployment env | `ENMAAS_API_KEY` from that Secret; LiteLLM reads it as `os.environ/ENMAAS_API_KEY` |
| Aliases | `enmaas-glm-5-3` → `openai/rits/zai-org/glm-5-3`, `enmaas-deepseek-v4-1` → `openai/rits/deepseek-ai/DeepSeek-V4.1-Flash-1017` |
| Agent-facing id | `gateway/<alias>` (e.g. `gateway/enmaas-deepseek-v4-1`) |
| Job label | `fullsend/model=gateway-enmaas-deepseek-v4-1` |

Run the probes (model list, text, **tool call**, TLS) after any change:

```sh
bash .opencode/scripts/probe-enmaas.sh
```

Tool calling matters: the pi/opencode runtimes drive tools through it, so a model
that answers prose instead of `tool_calls` cannot run an agent.

**Runtime constraint:** `gateway/` models are only valid on `pi`, `codex` and
`claude` runtimes (`validateGatewayRuntime`). Triage runs `opencode`, so EnMaaS
is a *code/fix/review* model here, not a triage model. Switching triage to a
`gateway/` model needs a harness runtime change.

No image change is required: an alias absent from `inference.gateway.models`
still resolves, so `models` only matters for non-default API types
(`openai-responses`, `anthropic-messages`). Verified with a real code run on
`gateway/enmaas-glm-5-3`.

Caps live in `models.json`; `validate_registry` fails the scan if a project names a
model with no cap, or with no `locality`.

Rotating the EnMaaS key:

```sh
host/rotate-enmaas-key.sh /secure/enmaas.key    # or: ENMAAS_API_KEY=... host/rotate-enmaas-key.sh
```

A Secret update alone is not enough: LiteLLM reads `ENMAAS_API_KEY` at container
start. The script updates `Secret/enmaas-api-key`, rolls the Deployment, and
verifies the running pod carries the new key (hash comparison, never printing
it), then runs the probe.


### Privacy: local-only projects

Every model declares a locality and every project may declare a privacy
requirement. Both are enforced at scan time, closed:

```json
"models.json": {
  "gateway/qwen38":               { "max_concurrent": 2, "locality": "local" },
  "gateway/enmaas-deepseek-v4-1": { "max_concurrent": 1, "locality": "remote" }
}
```

```json
{ "key": "fs0", "privacy": "local",
  "model_code": "gateway/qwen38", "model_triage": "ollama/Qwen3.8-27B" }
```

The scan refuses to dispatch anything when:

- a referenced model has no `locality` (so a new model cannot be added silently), or
- a `privacy: local` project references a `locality: remote` model.

```text
[dispatch:scan] ERROR: registry rejected: fs0 is privacy=local but uses
                gateway/enmaas-glm-5-3 (locality=remote)
```

Jobs carry `fullsend/locality=local|remote` as well as `fullsend/model`, so
local-only work is auditable:

```sh
oc -n fullsend get jobs -l fullsend/locality=remote   # must never contain a privacy=local project
```

Do not configure LiteLLM `router_settings.fallbacks`: a fallback that crosses
localities would defeat the mapping. If fallbacks are ever added, keep them
within one locality.

## Sub-issues and tracking issues

Two paths create parent/child structure:

- **Triage split** (`action: split`): the post-script creates each child, labels it
  `ready-for-triage`, comments "Split into:", and closes the parent as completed.
  The scan then triages each child normally, so N concerns become N PRs. Children
  are same-repo only unless `tracker.github.allowed_targets` is configured.
- **Native sub-issues** filed by a human: the dispatcher refuses to spend a Job
  on a parent. Before dispatching code it reads `subIssuesSummary.total`; when
  non-zero it removes `ready-to-code`, adds `fullsend/tracking`, and returns.

```text
[dispatch:scan] fs0#21 is a tracking issue (2 sub-issues); skipping code
```

`/fs-code --force` is the documented override, and the dispatcher passes the
whole comment as `COMMENT_BODY` so the pre-script's second-token rule still sees
the flag. `fullsend/tracking` is excluded from new-issue discovery, so a
tracking parent is not re-triaged.

Consequences worth knowing: the parent is not implemented (children are), there
is no dependency ordering between children, no rollup that closes the parent
after children land (a split parent is already closed at split time), and all
children inherit the project's model mapping and caps.

## Portability

Cluster-specific values are not baked into the scripts. They live in two files
with a fixed precedence:

| Precedence | File | Committed |
|---|---|---|
| 1 (wins) | process environment | — |
| 2 | `values.local.env` | no (git-ignored) |
| 3 | `values.example.env` | yes, placeholders |

```sh
cp values.example.env values.local.env && chmod 600 values.local.env
$EDITOR values.local.env        # CLUSTER_DOMAIN, OPENSHELL_NAMESPACE, KEYCLOAK_*, models, App ids
```

- `scripts/lib/values.sh` loads them, derives the common values (Keycloak URLs,
  registry, gateway service URL, image refs) and exports everything.
- Manifests that need values are templates: `k8s/*.tmpl`. `host/render-manifests.sh`
  writes `k8s/rendered/*.yaml` (git-ignored) and the deploy scripts apply those.
- Host-side deployment lives in `host/`: `deploy-litellm.sh`,
  `build-runner-image.sh`, `push-runner-image.sh`, `rebuild-runner.sh`,
  `litellm-route.sh`, `render-manifests.sh`, `rotate-enmaas-key.sh`, plus the
  promoted helpers `deploy-multiproject.sh`, `deploy-app-identity.sh`,
  `deploy-dispatcher*.sh`, `run-job.sh`, `watch-job.sh`, `view-*`,
  `gh-*`, `pi-code-*`, `forgejo-*` and the smoke/debug runners. All are
  values-driven: no cluster hostnames, account ids, repo slugs or absolute
  workspace paths are baked in.
- In-cluster scripts (`scripts/openshell-auth.sh`, `smoke.sh`, `run-agent.sh`)
  take every cluster reference from the environment; the dispatcher passes them
  into each Job from the rendered CronJob.
- EnMaaS is optional: the model entries are emitted only when `ENMAAS_API_BASE`
  and both model ids are set, and its Secret reference is `optional: true`.
- The harness `config.yaml` gateway URL is a literal (that field is not
  environment-expanded at run time). `host/rebuild-runner.sh` rewrites it from
  `LITELLM_ROUTE` while assembling the image context, so one harness fork builds
  for any cluster.

Still local for now: `k8s/projects-config.yaml` (repos, installation id, model
choices), the one-off diagnostic manifests, and the harness `config.yaml` +
local-llm profile on the agents fork.

## Verified

| Check | Result |
|---|---|
| Pod egress to ghcr.io / api.github.com / Keycloak / <model-host>:8080 | OK |
| Gateway gRPC reachable from a pod via route and service | OK |
| Keycloak service-account client `fullsend-runner` → OpenShell roles | `openshell whoami` shows `openshell-user, openshell-admin` |
| Sandbox pod creation (kubernetes driver) | OK |
| Harness sandbox image pull (4.8 GB, ghcr.io digest) | OK |
| Managed workspace PVC (topolvm, 2 Gi) | Bound |
| Policy load in supervisor | `status=loaded, version=1` |
| `openshell sandbox exec` | OK — OpenCode 1.19.1, gh 2.93.0, jsonschema |
| `fullsend lint triage --fullsend-dir <worktree>` | exit 0 (warnings only) |

## Decisions taken

* Model endpoint: `ollama` provider at `http://<model-host>:8080`, model
  **`ollama/Qwen3.8-27B`**. fullsend's model-spec regex rejects `:`, so the
  served tag `Qwen3.8-27B:UD_8_K_XL` cannot be used verbatim; the endpoint is
  name-lenient and accepts the tagless name (verified with chat completions).
* Runtime: `opencode`, **read-only agents only** (`triage`). The harness sets
  `security.enabled: false`, which disables content scanning and secret
  redaction — upstream restricts this runtime to read-only agents until
  #7824 lands.
* Gateway auth: Keycloak client `fullsend-runner`, client_credentials, with a
  hardcoded `hypershell.roles` claim and an audience mapper for
  `3LsRBMo5qVmeYhe0BdXOBiVtO66`. Tokens are minted by the runner and refreshed
  every 4 minutes (Keycloak lifespan is 5).
* Profile attachment: a profile listed only under `openshell.profiles:` is
  imported but not bound; `providers/local-llm.yaml` (`type:
  fullsend-local-llm`, no credentials) binds it to the sandbox.
* Local harness registration: `<--fullsend-dir>/config.yaml` is required,
  otherwise fullsend fetches `harness/triage.yaml` from the upstream agents
  repo and silently ignores the local patches.

## Forgejo

The forge abstraction names Forgejo but has no `forge.Client` implementation;
`forgejo` was added to `validForgeKeys` and the integration is harness-driven,
which is sufficient for `fullsend run` (the Go client is only used for the
agents-repo fallback and the opt-in status notifier).

Working pieces (agents worktree):

| Piece | Purpose |
|---|---|
| `harness/triage.yaml` overlay `runtime.forge == "forgejo"` | selects scripts/skills/profile/provider |
| `scripts/pre-triage-forgejo.sh` | removes all `fullsend/*` control labels via `DELETE /api/v1/.../issues/N/labels/ID` |
| `scripts/post-triage-forgejo.sh` | action→control label (`TRIAGE_AUTO_CODE` promotion logic), comment, existing content labels only |
| `skills/forgejo-forge` | curl recipes for `/api/v1`; forbids `gh`/GraphQL |
| `skills/issue-labels/forgejo` | label discovery + `Kind/`/`Priority/`/`Reviewed/`/`Status/` taxonomy |
| `providers/forgejo.yaml` | injects `FORGEJO_TOKEN` as a sandbox placeholder |
| `profiles/fullsend-forgejo.yaml` | egress to `forgejo.apps.<cluster-domain>:443`, binaries `**/curl`, `**/node`, `**/opencode` |

Control labels are the `fullsend/*` family (created on the repo):
`ready-for-triage`, `needs-info`, `ready-to-code`, `duplicate`, `blocked`,
`triaged`, `question`, `not-planned`, `completed`, `pr-open`. Content labels
(`Kind/*`, `Priority/*`, ...) are agent-recommended and applied only when they
already exist.

Forgejo has **no** `/api/v3` and **no** GraphQL, so the GitHub `gh`-based
scripts and skills cannot be reused. The agent runs with
`FULLSEND_FORGE=forgejo`, `FORGEJO_URL`, and a `FORGEJO_TOKEN` placeholder.

## Gateway lifecycle (important)

The hypershell controller reprovisions the OpenShell gateway with a **new ID**.
On 2026-11-10 the namespace changed from `<openshell-namespace>` to
`<openshell-namespace>`, which changes:

- the gRPC hostname (`gw-openshell-<id>.gw.<cluster-domain>`)
- the in-cluster Service (`openshell-gateway.openshell-<id>.svc:8080`)
- the OIDC audience (the per-gateway Keycloak client ID)
- the gateway CA

The old hostname keeps resolving to the same Envoy load balancer but has no
GRPCRoute, so every call returns `route_not_found`, which the CLI reports as
`Operation is not implemented or not supported` (i.e. an API mismatch, not an
auth failure). Re-run:

```sh
.opencode/scripts/gw-discover.sh
```

It discovers the namespace/host/audience from the `grpcroute`, updates the
`fullsend-runner` audience mapper in Keycloak (via the `hypershell-provisioner`
service account in `Secret/hypershell-keycloak-admin`), refreshes
`ConfigMap/fullsend-gateway-ca`, and rewrites the local gateway metadata.
`openshell-auth.sh` now prefers the endpoint recorded in that metadata, so only
the discovery script needs the new values; the in-cluster Job takes the Service
URL from its own env.

## Dispatcher (CronJob)

Triage promotes `sufficient` results to `ready-to-code` for the categories in
`TRIAGE_AUTO_CODE_CATEGORIES` — now `bug,documentation,performance,feature` —
so feature issues flow straight into the code track. Other categories stop at
`triaged` and need a human (or `/fs-code`).

`CronJob/fullsend-dispatch` (`*/10 * * * *`, `concurrencyPolicy: Forbid`)
watches one repo (`FULLSEND_REPO`) and starts a code Job per work item.

Triggers:
- an open issue labelled `ready-to-code`;
- an issue comment beginning with `/fs-code` (the rest becomes
  `COMMENT_BODY` for the code agent).

Dedup and bookkeeping:
- an open PR with head `agent/<n>-*` means done: the watcher removes
  `ready-to-code` and adds `fullsend/pr-open`;
- `fullsend/code-running` plus a running `fullsend-code-*` Job blocks a second
  dispatch;
- each `/fs-code` comment gets an `eyes` reaction from the token identity, so a
  comment is dispatched once;
- every tick reconciles `fullsend/code-running` against Job status and replaces
  it with `fullsend/code-succeeded` or `fullsend/code-failed`.

Jobs are `fullsend-code-<n>-<suffix>` with labels `fullsend/stage=code` and
`fullsend/issue=<n>`, 75 min deadline, 2 h TTL. RBAC is
`Role/fullsend-dispatcher` (jobs create/get/list/watch/delete; pods
get/list/watch) bound to `fullsend-runner`.

`DRY_RUN=1` logs decisions without mutating anything (used to validate).

Gotchas: the CronJob's `OPENSHELL_GATEWAY_URL` is baked at deploy time — update
it after a gateway reprovision (or extend `gw-discover.sh` to patch the
CronJob). One CronJob per repo.

## Known quirks

* **`OPENSHELL_GATEWAY_INSECURE` breaks `list-profiles`.** The CLI prints its
  TLS warning to **stdout**, so `provider list-profiles -o json` no longer
  parses and `ProfileExists` reports the profile missing right after import.
  Trust the gateway CA instead: the CA lives in the `openshell-ca-tls` secret
  in the OpenShell namespace (cross-namespace mounts are impossible), so it is
  copied into `ConfigMap/fullsend-gateway-ca` and `run-agent.sh` builds
  `$HOME/ca-bundle.crt` from the system bundle plus that CA before setting
  `SSL_CERT_FILE`. Rotate the copy when the gateway CA rotates.
* **Long agent streams die on the public route.** `gw-...` fronts Envoy, which
  resets an idle gRPC stream (the agent stream is silent while the model
  thinks). Use the gateway Service endpoint
  (`https://openshell-gateway.<openshell-namespace>.svc.cluster.local:8080`)
  with the CA above.
* **OpenCode is classified as Vertex.** `runInferenceProvider`
  (`internal/cli/run.go`) returns `vertex` for every OpenCode parent unless the
  model is `openai` or `gateway/`. Two consequences: a mount sourced from
  `${GOOGLE_APPLICATION_CREDENTIALS}` must resolve, and Bootstrap refuses to
  start when the sandbox `.env` has an empty `GOOGLE_APPLICATION_CREDENTIALS`
  (`internal/runtime/opencode_integrity.go`). The overlay mounts a dummy
  credential at a **literal** path (which the first check skips) and points
  `env.sandbox.GOOGLE_APPLICATION_CREDENTIALS` at it.
* **The egress profile must allowlist the runtime binary.** The supervisor
  denies per-binary: `binary '/usr/local/bin/opencode' not allowed in policy
  '_provider_local_llm'`. OpenCode is a native binary in fullsend's image, so
  the profile lists both `**/node` and `**/opencode`.
* **Result writes are `external_directory`.** OpenCode treats
  `/sandbox/workspace/output` as outside the project; the permission policy
  allows that path explicitly.
* `openshell sandbox create` intermittently returns `h2 protocol error …
  Reset(StreamId(5))` even though the gateway logs `CreateSandbox … 200` and
  the sandbox becomes Ready. fullsend tolerates this (`internal/sandbox/
  sandbox.go` re-checks `openshell sandbox get` before failing).
* The baked harness under `/harness` is root-owned, so the pod's arbitrary UID
  cannot `chmod` the scripts. The notice is harmless: they are already
  executable in the image.
* Sandbox creation takes ~20–40 s after the image is cached; first pull of the
  4.8 GB sandbox image took ~1 m 37 s.

## Runbook

Host-side run (Phase 4 proof of life):

```sh
export OPENCODE_CONFIG_CONTENT="$(cat .opencode/okd-deploy/opencode-config.json)"
cat > .opencode/tmp/host-run-issue.env <<'ENV'
GITHUB_ISSUE_URL=https://github.com/OWNER/REPO/issues/N
FULLSEND_WORK_ITEM_URL=https://github.com/OWNER/REPO/issues/N
ENV

./.opencode/tmp/fullsend run triage \
  --fullsend-dir /wip/worktrees/github.com/fullsend-ai/agents-okd \
  --target-repo /wip/src/github.com/fullsend-ai/fullsend \
  --forge github --runtime opencode --model ollama/Qwen3.8-27B \
  --env-file .opencode/tmp/gh.env \
  --env-file .opencode/tmp/host-run-issue.env \
  --no-post-script --keep-sandbox
```

Everything lives in this directory:

```
okd-deploy/
  image/Dockerfile            derivative runner image
  opencode-config.json        OPENCODE_CONFIG_CONTENT (provider + permissions)
  k8s/job-triage.yaml         the Job
  scripts/openshell-auth.sh   Keycloak token + gateway credential file
  scripts/run-agent.sh        clone target repo, invoke fullsend
  scripts/smoke.sh            gateway/sandbox smoke test
```

Rebuild the image after harness changes:

```sh
bash <org>/.opencode/scripts/rebuild-runner.sh
```

Apply the Job (replace OWNER/REPO and the issue number first):

```sh
oc -n fullsend create secret generic fullsend-github-app \
  --from-literal=app-id=$GH_APP_ID --from-literal=installation-id=$GH_INSTALLATION_ID \
  --from-file=private-key=<app>.private-key.pem \
  --dry-run=client -o yaml | oc apply -f -
oc -n fullsend apply -f k8s/job-triage.yaml
oc -n fullsend logs -f job/fullsend-triage
```

## Pending

1. ~~GitHub scratch repo + fine-grained PAT~~ — replaced by the `fullsend-code`
   GitHub App (see "GitHub App identity").
2. Set `FULLSEND_REPO_SLUG` / `FULLSEND_ISSUE_URL` in `job-triage.yaml`.
3. Run triage with `--no-post-script`; then flip `FULLSEND_RUN_POST=1` and
   verify labels/comments.
4. After that: CronJob sweep, `prioritize` harness, tracing.
