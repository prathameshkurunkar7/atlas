# Code-review action checklist (2026-05-26)

Derived from [`plan/code-review.md`](./code-review.md). Organised by the four
tiers in §8 of that document. Each item is independently mergeable.

Conventions:
- File paths are repo-relative. Line numbers reflect HEAD at review time and
  may drift — re-grep the symbol if the line doesn't match.
- "Verify" lines are the bench/ruff/test command to run before marking a box.
- All Python edits must follow `llm/Taste.md` and pass `ruff` per
  `pyproject.toml` (tabs for indent).
- Use the `frappe-dev` skill for any DocType, controller, hook, or
  whitelisted-method change.

---

## Tier 1 — Taste rules and plan/spec hygiene (no code change)

### T1.1 Add six new rules to `llm/Taste.md`

File: [`llm/Taste.md`](../llm/Taste.md)

- [x] **Rule: one operation = one shell script = one Task row.**
  Body: "Compose at the script level (heredocs, `set -euo pipefail`), not by
  chaining `run_task` calls in Python. If you have two scripts that always
  run back-to-back, merge them." (Source: review §1.1; spec
  [`spec/04-tasks.md:73-89`](../spec/04-tasks.md).)
- [x] **Rule: scripts are the source of truth for server-side logic.**
  Body: "Server-side logic lives in `scripts/*.sh`. Python calls scripts and
  parses their output. Do not encode server-side state machines in Python."
  (Source: review §1.2; spec [`spec/01-architecture.md:43-50`](../spec/01-architecture.md).)
- [x] **Rule: every shell script in `scripts/` must be idempotent.**
  Body: "Retry = re-run, no special repair mode." (Source: review §1.3; spec
  [`spec/04-tasks.md:138-141`](../spec/04-tasks.md).)
- [x] **Rule: fail loud at the boundary; do not fall back.**
  Body: "SSH failed? raise. DO API 5xx? raise. The operator retries by
  clicking the button." (Source: review §1.4.)
- [x] **Rule: extend existing abbreviations rule with carve-out for `vm`.**
  Body: "`vm` is allowed only when (a) it shadows a Frappe method name
  (`delete`) or (b) it is a local variable inside a five-line function.
  Doctype controller methods, module-level functions, and public helpers
  spell it out." (Source: review §1.5.)
- [x] **Rule: tests live next to the code they cover.**
  Body: "`atlas/atlas/doctype/<x>/test_<x>.py` for controllers,
  `atlas/tests/test_<module>.py` for modules, `atlas/tests/e2e/phase_N.py`
  for end-to-end." (Source: review §1.6; plan
  [`plan/00-overview.md:47-49`](./00-overview.md).)
- [x] Verify: open `llm/Taste.md` and confirm the file is still a flat list,
  no nested bullets, each rule one paragraph at most.

### T1.2 Update `plan/00-overview.md` with test-fixture convention

File: [`plan/00-overview.md`](./00-overview.md), in the "Conventions used by
every phase" section (around the "Tests live next to the doctype" line near
[L47-49](./00-overview.md)).

- [x] Add paragraph: *"Test fixture builders (`make_server`, `make_image`,
  etc.) live in `atlas/tests/fixtures.py`. Each builder takes a name and
  `**overrides`, implements 'create if not exists.' Test files import from
  there; no per-file `_make_provider` reimplementations."* (Source: review §6.1.)
- [x] Verify: paragraph appears once, no duplicate guidance further down.

### T1.3 Update `spec/README.md` with spec-vs-code policy

File: [`spec/README.md`](../spec/README.md)

- [x] Add paragraph: *"The spec describes the system as it is. When the spec
  and code disagree, the code is the source of truth and the spec gets
  updated to match, unless the disagreement reveals a code defect. The
  `plan/drift.md` running log of these discoveries is preserved as project
  history."* (Source: review §6.2.)
- [x] Verify: paragraph sits near the top of `spec/README.md` so a reader
  encounters it before per-section specs.

### T1.4 Cite new Taste rules from per-phase plan files

For each of [`plan/phase-1-ssh-and-task.md`](./phase-1-ssh-and-task.md),
[`plan/phase-3-server-and-bootstrap.md`](./phase-3-server-and-bootstrap.md),
and every other phase file:

- [x] Phase 1 "Implementation notes" — cite new Taste rule "Task = one shell
  script" wherever the current text discusses `run_task` shape.
- [x] Phase 3 "Implementation notes" — cite new Taste rule "Scripts are the
  source of truth" wherever the current text discusses `upload_files`.
- [x] Every phase — cite new Taste rule "Idempotency is a script-author
  obligation" next to the first mention of `scripts/*.sh`.
- [x] Verify: `grep -n "Taste.md" plan/phase-*.md` shows at least one citation
  per phase that touches scripts.

### T1.5 Delete or fold `plan/e2e-reliability.md`

File: [`plan/e2e-reliability.md`](./e2e-reliability.md)

- [x] Confirm all shipped fixes from `e2e-reliability.md` are referenced in
  `drift.md` entries E1–E7. (Source: review §6.4.)
- [x] If yes, `git rm plan/e2e-reliability.md`.
- [x] Search-and-update any remaining references:
  `grep -rn "e2e-reliability" plan/ spec/ atlas/` — only the checklist file
  itself (this document) and `code-review.md` (the historical source) still
  reference it. `drift.md` references are now prose-only (no broken links).
- [ ] Verify: `bench --site atlas.local execute atlas.tests.e2e.run_all` still
  passes (the document was historical; no behavior depends on it).

---

## Tier 2 — Mechanical, high-confidence code changes

### T2.1 Create `atlas/tests/fixtures.py`, migrate the six test files

New file: `atlas/tests/fixtures.py`. (Source: review §2.1.)

- [x] Create `atlas/tests/fixtures.py` with four builders, each implementing
  "if exists, return; else insert" and accepting `**overrides`:
  - [x] `make_provider(name="test-provider", **overrides) -> Document`
        — defaults: `provider_type="DigitalOcean"`, `api_token="dop_v1_fake"`,
        `ssh_private_key=<PEM-shaped fake>`, `default_region="nyc3"`,
        `default_size="s-1vcpu-1gb"`. (Pin the token shape to `dop_v1_*` so
        callers see what the production DO library expects.)
  - [x] `make_server(provider, name="test-server", **overrides) -> Document`
        — defaults from review §2.1: status `"Pending"`,
        `provider_resource_id=None`, `region`/`size` copied from `provider`.
  - [x] `make_image(name="test-image", **overrides) -> Document` — defaults
        match `DEFAULT_IMAGE` in
        [`atlas/tests/e2e/_shared.py`](../atlas/tests/e2e/_shared.py) for
        consistency.
  - [x] `make_virtual_machine(server, image, **overrides) -> Document` —
        relies on `before_insert` UUID, defaults `vcpus=1`, `memory_mib=512`,
        `disk_gigabytes=2`.
- [x] Type-annotate every builder signature (Frappe `Document` return type).
- [x] Migrate callers, deleting the per-file `_make_*` helpers:
  - [x] [`atlas/atlas/doctype/server/test_server.py:9-44`](../atlas/atlas/doctype/server/test_server.py)
        — delete `_make_provider`, `_make_server`; import from
        `atlas.tests.fixtures`.
  - [x] [`atlas/atlas/doctype/server_provider/test_server_provider.py:7-21`](../atlas/atlas/doctype/server_provider/test_server_provider.py)
        — delete `_make_provider`; import.
  - [x] [`atlas/atlas/doctype/virtual_machine/test_virtual_machine.py:7-70`](../atlas/atlas/doctype/virtual_machine/test_virtual_machine.py)
        — delete `_ensure_image`, `_ensure_server`, `_new_vm`; import.
  - [x] [`atlas/atlas/doctype/virtual_machine_image/test_virtual_machine_image.py:9-48`](../atlas/atlas/doctype/virtual_machine_image/test_virtual_machine_image.py)
        — delete `_make_image`, `_make_provider_and_server`; import.
  - [x] [`atlas/tests/test_networking.py:14-77`](../atlas/tests/test_networking.py)
        — delete `_make_provider_and_server`, `_insert_vm`, `_ensure_image`;
        import.
  - [x] [`atlas/tests/test_permissions.py:17-31`](../atlas/tests/test_permissions.py)
        — delete `_make_provider`; import.
- [x] Audit existing tests for hidden dependence on the old `"fake"` token
  shape — search `grep -rn '"fake"' atlas/atlas/doctype atlas/tests` and
  update any assertion that pinned the old value.
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes.
- [x] Verify line count: `wc -l atlas/atlas/doctype/server/test_server.py
  atlas/atlas/doctype/server_provider/test_server_provider.py
  atlas/atlas/doctype/virtual_machine/test_virtual_machine.py
  atlas/atlas/doctype/virtual_machine_image/test_virtual_machine_image.py
  atlas/tests/test_networking.py atlas/tests/test_permissions.py` — total
  should drop ~180 lines (review §2.1 estimate).

### T2.2 Extract `ephemeral_public_key()` into `_shared.py`

Files:
[`atlas/tests/e2e/_shared.py`](../atlas/tests/e2e/_shared.py),
[`atlas/tests/e2e/phase_5.py:77-87`](../atlas/tests/e2e/phase_5.py),
[`atlas/tests/e2e/phase_6.py:102-112`](../atlas/tests/e2e/phase_6.py).
(Source: review §2.2.)

- [x] In `_shared.py`, add `def ephemeral_public_key() -> str:` that
  `ssh-keygen`s into a stable directory (e.g. `~/.cache/atlas-e2e/`) only if
  missing, then returns the `.pub` contents.
- [x] Replace `_make_ephemeral_keypair` / `_ephemeral_public_key` in
  `phase_5.py` and `phase_6.py` with a call to the shared helper.
- [x] Delete the now-unused private helpers.
- [x] Verify: phase 5 and phase 6 e2e produce the same `.pub` content on
  successive runs — `bench --site atlas.local execute
  atlas.tests.e2e.phase_5.run` followed by `… phase_6.run` should both inject
  the same key.

### T2.3 Merge `_move_image_aside` / `_move_image_back` into one helper

File: [`atlas/tests/e2e/phase_5.py:90-117`](../atlas/tests/e2e/phase_5.py).
(Source: review §2.3.)

- [x] Replace both functions with `def _move_image(server, direction: str)`
  where `direction in {"aside", "back"}`. Pass `"DIRECTION": direction` to the
  underlying script.
- [x] Update the two call sites in `phase_5.run` to pass the direction.
- [x] Verify: `bench --site atlas.local execute atlas.tests.e2e.phase_5.run`
  still moves and restores the image.

### T2.4 Extract `assert_probe()` into `_shared.py`

Files: [`atlas/tests/e2e/_shared.py`](../atlas/tests/e2e/_shared.py),
[`atlas/tests/e2e/phase_5.py:120-127`](../atlas/tests/e2e/phase_5.py),
[`atlas/tests/e2e/phase_6.py:115-145`](../atlas/tests/e2e/phase_6.py).
(Source: review §2.4.)

- [x] In `_shared.py`, add:
  ```python
  def assert_probe(server_name: str, script: str, **variables: str) -> None:
      task = run_task_on_server(
          server=server_name, script=script,
          variables=variables, timeout_seconds=15,
      )
      assert task.status == "Success", task.stderr
  ```
- [x] Replace `_assert_is_active`, `_assert_is_inactive`, `_assert_gone`,
  and any other "run probe + assert Success" wrappers in phase 5 and phase 6
  with one-liner calls.
- [x] Verify: phase 5/6 still detect a deliberately-broken probe (manually
  rename a probe script and re-run; the assertion should fire).
- [x] Verify line delta: `git diff --stat` should show ~30 lines removed
  across phase 5/6.

### T2.5 Delete `phase_3._ensure_provider`, share with `_shared.py`

Files: [`atlas/tests/e2e/phase_3.py:60-75`](../atlas/tests/e2e/phase_3.py),
[`atlas/tests/e2e/_shared.py:240-255`](../atlas/tests/e2e/_shared.py).
(Source: review §2.5.)

- [x] In `_shared.py`, rename `_ensure_e2e_provider` to `ensure_e2e_provider`
  (drop the leading underscore so it can be imported).
- [x] Update existing in-module callers in `_shared.py`.
- [x] Delete `_ensure_provider` from `phase_3.py`; import
  `ensure_e2e_provider` and use it.
- [x] Verify the provider name is identical on both paths
  (`atlas-e2e-provider`) — `grep -rn "atlas-e2e-provider" atlas/tests/e2e/`
  should show only the shared definition.
- [x] Verify: `bench --site atlas.local execute atlas.tests.e2e.phase_3.run`
  still bootstraps end-to-end.

### T2.6 Delete `phase_4._ensure_image`, share with `_shared.py`

Files: [`atlas/tests/e2e/phase_4.py:55-65`](../atlas/tests/e2e/phase_4.py),
[`atlas/tests/e2e/_shared.py:266-280`](../atlas/tests/e2e/_shared.py).
(Source: review §2.6.)

- [x] Confirm `_shared.py`'s `_ensure_image` (or `ensure_image_on_server`)
  is the superset — it should do the remote probe + sync that phase 4 needs.
- [x] Delete `_ensure_image` from `phase_4.py`; import the shared one.
- [x] If the shared helper has a leading underscore and is needed by phase
  files, drop the underscore.
- [x] Verify: `bench --site atlas.local execute atlas.tests.e2e.phase_4.run`
  produces the same image-row state as before.

### T2.7 Merge `_inspect.dump_for_server` and `dump_recent_tasks`

File: [`atlas/tests/e2e/_inspect.py`](../atlas/tests/e2e/_inspect.py). (Source:
review §2.9 and §5.3.)

- [x] Extract `_print_task(name: str) -> None` doing the
  `(stdout last 2000, stderr last 1000)` truncation pattern.
- [x] Replace both `dump_for_server` and `dump_recent_tasks` with one function
  `dump_recent_tasks(server_name: str | None = None, limit: int = 20)` that
  filters by server when provided and calls `_print_task` for each row.
- [x] Delete the now-redundant function. Keep both call paths working from
  operator console (`bench execute atlas.tests.e2e._inspect.dump_recent_tasks`
  with and without `server_name=...`).
- [x] Verify: `bench --site atlas.local execute
  atlas.tests.e2e._inspect.dump_recent_tasks` prints recent tasks; with
  `server_name="atlas-e2e-server"` it filters correctly.

### T2.8 Simplify `_resolved_uploads()`

File: [`atlas/atlas/doctype/server/server.py:120-129`](../atlas/atlas/doctype/server/server.py).
(Source: review §2.10.)

- [x] Store `BOOTSTRAP_UPLOADS` as a list of `(source_filename, destination_path)`
  tuples, where `source_filename` is the leaf name within
  `SCRIPTS_DIRECTORY`:
  ```python
  BOOTSTRAP_UPLOADS = [
      ("vm-network-up.sh", "/var/lib/atlas/bin/vm-network-up.sh"),
      ("vm-network-down.sh", "/var/lib/atlas/bin/vm-network-down.sh"),
      ("systemd/firecracker-vm@.service", "/etc/systemd/system/firecracker-vm@.service"),
  ]
  ```
- [x] Reduce `_resolved_uploads()` to:
  ```python
  def _resolved_uploads() -> list[tuple[str, str]]:
      return [(str(SCRIPTS_DIRECTORY / source), destination)
              for source, destination in BOOTSTRAP_UPLOADS]
  ```
- [x] Delete the now-unused assertion / prefix-strip logic.
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes,
  particularly any Server bootstrap unit test.
- [x] Verify on a fresh droplet: `bench --site atlas.local execute
  atlas.tests.e2e.phase_3.run` — bootstrap should upload the same files to
  the same destinations.

### T2.9 Drop dead `try/except` in `digitalocean.delete_droplet`

File: [`atlas/atlas/digitalocean.py:75-81`](../atlas/atlas/digitalocean.py).
(Source: review §3.12.)

- [x] Confirm `_request("DELETE", ..., allow_404=True)` returns `{}` on 404
  (read `_request` body to verify the `allow_404` branch returns silently).
- [x] Replace the seven-line `try/except` with the single call:
  ```python
  def delete_droplet(self, droplet_id: int) -> None:
      self._request("DELETE", f"/droplets/{droplet_id}", allow_404=True)
  ```
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes; if
  there's a test that pins the 404 branch, run it.
- [x] Verify against DO: invoke `_inspect.list_droplets` then attempt
  `delete_droplet(<bogus_id>)` from console — no exception.

### T2.10 Drop dead `_ = probe` in `_assert_image_present`

File: [`atlas/atlas/doctype/virtual_machine/virtual_machine.py:147-162`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py).
(Source: review §3.9.)

- [x] If T3.5 (fold probe into `provision-vm.sh`) is being done in the same
  PR, **skip this** — the method goes away entirely.
- [x] Otherwise: delete the `_ = probe` line. Replace `probe = run_task_on_server(...)`
  with bare `run_task_on_server(...)`. Keep the comment explaining "the
  probe's success is the assertion."
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes.

### T2.11 Flatten repeated `is_new()` checks in `before_validate`

File: [`atlas/atlas/doctype/virtual_machine/virtual_machine.py:19-27`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py).
(Source: review §3.8.)

- [x] Replace the four `if self.is_new() and not self.X:` lines with:
  ```python
  def before_validate(self) -> None:
      if not self.is_new():
          return
      if not self.mac_address:
          self.mac_address = derive_mac(self.name)
      if not self.tap_device:
          self.tap_device = derive_tap(self.name)
      if not self.ipv6_address:
          self.ipv6_address = allocate_ipv6(self.server)
      if not self.status:
          self.status = "Pending"
  ```
- [x] Verify behavior is unchanged: `bench --site atlas.local run-tests --app
  atlas --module atlas.atlas.doctype.virtual_machine.test_virtual_machine`.

### T2.12 Extract `phase()` context manager for phase-runner scaffolding

Files: [`atlas/tests/e2e/_shared.py`](../atlas/tests/e2e/_shared.py),
[`atlas/tests/e2e/phase_3.py`](../atlas/tests/e2e/phase_3.py) through
[`atlas/tests/e2e/phase_7.py`](../atlas/tests/e2e/phase_7.py). (Source: review §5.4.)

- [x] In `_shared.py`, add a `@contextmanager def phase(label, reuse=True,
  keep=True)` that:
  - [x] Captures `start = time.monotonic()`.
  - [x] Calls `ensure_bootstrapped_server(reuse=reuse, keep=keep)` and
        `sweep_old_droplets(client)`.
  - [x] `yield`s the server document.
  - [x] On exception: print `f"{label}: FAIL in {elapsed:.0f}s"`,
        `traceback.print_exc()`, re-raise.
  - [x] On success: print `f"{label}: OK in {elapsed:.0f}s"`.
  - [x] `finally`: if `created_now and not keep and server.provider_resource_id`,
        call `cleanup_droplet(client, int(server.provider_resource_id))`.
- [x] Migrate `phase_3.run` through `phase_7.run` to:
  ```python
  def run(reuse=True, keep=True):
      with phase("phase-N", reuse=reuse, keep=keep) as server:
          ...
  ```
- [x] **Do not migrate** `phase_1.run` or `phase_2.run` — neither bootstraps a
  server, so the context manager doesn't fit.
- [x] Verify per phase: `bench --site atlas.local execute
  atlas.tests.e2e.phase_3.run` (and 4–7) still emits the same one-line
  OK/FAIL summary.

### T2.13 Extract `fake_task()` mock helper

New file: `atlas/tests/_mocks.py` (or extend existing tests `__init__.py`).
(Source: review §5.2.)

- [x] Add:
  ```python
  def fake_task(name: str = "task") -> MagicMock:
      m = MagicMock()
      m.name = name
      m.status = "Success"
      return m
  ```
- [x] Audit every `MagicMock()` + `.name = ...` pattern in
  `atlas/atlas/doctype/*/test_*.py` (use `grep -rn "MagicMock()" atlas/atlas/doctype`).
  Replace with `fake_task(...)` calls where the mock represents a `Task`.
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes.

---

## Tier 3 — Architectural, each a separate PR

### T3.1 Add `Task.variables_dict` property

Files: [`atlas/atlas/doctype/task/task.py:14-22`](../atlas/atlas/doctype/task/task.py),
[`atlas/atlas/ssh.py:63`](../atlas/atlas/ssh.py),
[`atlas/atlas/ssh.py:80`](../atlas/atlas/ssh.py),
[`atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py:40`](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py).
(Source: review §3.2.)

- [x] On `Task` controller, add:
  ```python
  @property
  def variables_dict(self) -> dict:
      return json.loads(self.variables or "{}")

  @variables_dict.setter
  def variables_dict(self, value: dict) -> None:
      if not isinstance(value, dict):
          frappe.throw("Task.variables_dict must be a dict")
      self.variables = json.dumps(value, sort_keys=True)
  ```
- [x] Replace every `task.variables = json.dumps(variables, sort_keys=True)`
  with `task.variables_dict = variables`. Sites to update:
  - [x] `ssh.py:63` (in `run_task`).
  - [x] `ssh.py` `execute_task` path (re-read; locate the second `json.dumps`).
  - [x] `virtual_machine_image.py:40`.
- [x] Replace every `json.loads(task.variables or "{}")` with
  `task.variables_dict`. Sites to update:
  - [x] `ssh.py:80`.
- [x] Simplify `Task.validate()` — the setter enforces dict-shape, so the
  parse-then-check-isinstance block can collapse to invoking the property
  once (which raises on bad JSON).
- [x] Type-annotate the property/setter. Add module-level `import json` if
  not already present.
- [x] Verify: `bench --site atlas.local run-tests --app atlas
  --module atlas.atlas.doctype.task.test_task` passes. Existing Task rows
  with valid JSON in `variables` keep round-tripping.

### T3.2 Introduce `Connection` dataclass

Files: [`atlas/atlas/ssh.py:84-97`](../atlas/atlas/ssh.py),
[`atlas/atlas/ssh.py`](../atlas/atlas/ssh.py) (top-level types),
all callers that build a `dict` of `{host, ssh_private_key, user}`.
(Source: review §3.4.)

- [x] In `ssh.py` (or a new `connection.py`), define:
  ```python
  @dataclasses.dataclass(frozen=True)
  class Connection:
      host: str
      ssh_private_key: str
      user: str = "root"
  ```
- [x] Update `connection_for_server(server_doc) -> Connection` to return the
  dataclass.
- [x] Update every helper that accepts `connection: dict` to accept
  `connection: Connection`. Indexing (`connection["host"]`) becomes attribute
  access (`connection.host`). Remove `connection.get("user", "root")` —
  dataclass default handles it.
- [x] Update e2e harness callers:
  - [x] [`atlas/tests/e2e/phase_1.py`](../atlas/tests/e2e/phase_1.py) — build
        `Connection(host=..., ssh_private_key=..., user="root")` instead of a
        dict.
  - [x] [`atlas/tests/e2e/_shared.py`](../atlas/tests/e2e/_shared.py) — any
        site that builds the connection dict.
- [x] Verify: `bench --site atlas.local execute atlas.tests.e2e.phase_1.run`
  passes (this is the pure-SSH smoke test).
- [x] Verify: `ruff check atlas/` clean.

### T3.3 Merge `run_task` and `run_task_on_server`

Files: [`atlas/atlas/ssh.py:45-117`](../atlas/atlas/ssh.py),
every caller of either function.
(Source: review §3.1.)

- [x] Rewrite the signature as `run_task(*, server=None, connection=None,
  script, variables, virtual_machine=None, timeout_seconds=1800) -> Task`.
- [x] At entry: validate exactly one of `server`/`connection` is provided
  (`frappe.throw` if neither).
- [x] If `server` is given and `connection` is not: look up the Server doc and
  call `connection_for_server`.
- [x] Delete `run_task_on_server`.
- [x] Migrate callers. Every site that previously called
  `run_task_on_server(server, ...)` becomes `run_task(server=server, ...)`.
  `Server.bootstrap()` keeps `connection=` because the row may be incomplete.
  Sites to update (find with `grep -rn "run_task_on_server\|run_task(" atlas/`):
  - [x] [`atlas/atlas/doctype/server/server.py`](../atlas/atlas/doctype/server/server.py)
        — bootstrap path uses `connection=`; any other callers use `server=`.
  - [x] [`atlas/atlas/doctype/virtual_machine/virtual_machine.py`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py)
        — every `run_task_on_server` call.
  - [x] [`atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py`](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py).
  - [x] [`atlas/atlas/server_provider.py`](../atlas/atlas/server_provider.py).
  - [x] All `atlas/tests/e2e/phase_*.py` and `_shared.py`.
- [x] Update [`plan/drift.md`](./drift.md) entry 1.2: change "keep both" to
  "merged into one entry point with two modes."
- [x] Update [`spec/04-tasks.md`](../spec/04-tasks.md) "How it runs" section
  accordingly.
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes.
- [x] Verify: `bench --site atlas.local execute atlas.tests.e2e.run_all`
  passes against a real droplet.

### T3.4 Fold image-presence probe into `provision-vm.sh`

Files: [`scripts/provision-vm.sh`](../scripts/provision-vm.sh),
`scripts/probe-image-present.sh` (delete),
[`atlas/atlas/doctype/virtual_machine/virtual_machine.py:40-70, 147-162`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py).
(Source: review §2.7, recommendation (1).)

- [x] At the top of `scripts/provision-vm.sh`, add a `# 0. Verify image
  present` step:
  ```bash
  if [ ! -f "/var/lib/atlas/images/${IMAGE_NAME}/rootfs.ext4" ]; then
      echo "image '${IMAGE_NAME}' not present on server; run Sync to Server first" >&2
      exit 1
  fi
  ```
  (Confirm the exact path layout against the existing
  [`scripts/sync-image.sh`](../scripts/sync-image.sh) before pasting.)
- [x] Delete `scripts/probe-image-present.sh`.
- [x] Delete `_assert_image_present` from `virtual_machine.py`. Remove its
  call site in `provision()`.
- [x] Update [`atlas/atlas/scripts_catalog.py`](../atlas/atlas/scripts_catalog.py)
  if it explicitly enumerates `probe-image-present.sh` (it should not, since
  it scans the directory, but verify).
- [x] Update [`spec/05-virtual-machine-lifecycle.md`](../spec/05-virtual-machine-lifecycle.md)
  "Provision" section: remove any mention of two Tasks; provision is now one
  Task. Cross-check the entry already resolved in
  [`plan/drift.md`](./drift.md) 5.4.
- [x] Update [`plan/drift.md`](./drift.md) — add a new resolved entry under
  the post-iteration roadmap or directly in §5 referencing review §2.7.
- [x] Verify: `bench --site atlas.local execute
  atlas.tests.e2e.phase_5.run` — provision now produces one Task row, the
  Task is `Failed` with the clear error when the image is absent, and is
  `Success` when present.
- [x] Verify operator audit log: only one row per provision click.

### T3.5 Split `atlas/atlas/ssh.py` into a `_ssh/` package

Files: [`atlas/atlas/ssh.py`](../atlas/atlas/ssh.py) (currently ~360 lines,
over `Taste.md` cap), new subpackage `atlas/atlas/_ssh/`.
(Source: review §4.1, §4.3.)

- [x] Create `atlas/atlas/_ssh/__init__.py`. Public surface re-exports the
  same names so callers don't break:
  ```python
  from atlas.atlas._ssh.runner import run_task, execute_task, connection_for_server
  from atlas.atlas._ssh.transport import upload_files, wait_for_ssh
  ```
- [x] Move subprocess plumbing (`_run_ssh`, `_run_scp`, `_ssh_key_file`,
  `_ensure_known_hosts_directory`, `SSH_OPTIONS`) into
  `atlas/atlas/_ssh/transport.py` (~80 lines target).
- [x] Move Task lifecycle (`_execute_into`, `_finalize`, `_run_remote_script`)
  into `atlas/atlas/_ssh/runner.py` (~100 lines target).
- [x] Move `_resolve_script` into
  [`atlas/atlas/scripts_catalog.py`](../atlas/atlas/scripts_catalog.py) and
  rename to `resolve(name: str) -> Path`. Apply the same whitelist
  `allowed_scripts()` uses; this closes the inconsistency where the resolver
  and the Run Task dialog had different views of the script set.
- [x] Replace `atlas/atlas/ssh.py` with a thin re-export module of the public
  surface (~30 lines). Existing imports `from atlas.atlas.ssh import
  run_task` keep working.
- [x] Verify directory size: `ls atlas/atlas/ | wc -l` should be ≤14 after
  this change (the `_ssh/` subpackage adds one entry, not several).
- [x] Verify file sizes: `wc -l atlas/atlas/ssh.py atlas/atlas/_ssh/*.py
  atlas/atlas/scripts_catalog.py` — each between 100–300, per Taste rule.
- [x] Verify: `bench --site atlas.local run-tests --app atlas` passes;
  `bench --site atlas.local execute atlas.tests.e2e.phase_1.run` passes.

### T3.6 Split `atlas/tests/e2e/_shared.py` into four modules

File: [`atlas/tests/e2e/_shared.py`](../atlas/tests/e2e/_shared.py)
(currently ~357 lines, over Taste cap).
(Source: review §4.2.)

- [x] Create `atlas/tests/e2e/_config.py` — site-config readers
  (`get_client`, `get_ssh_key_id`, `get_region`, …), `DEFAULT_IMAGE`
  constant.
- [x] Create `atlas/tests/e2e/_droplets.py` — `create_test_droplet`,
  `sweep_old_droplets`, `cleanup_droplet`, `teardown_all`,
  `ensure_bootstrapped_server`, `server_is_reachable`, `ensure_e2e_provider`.
- [x] Create `atlas/tests/e2e/_tasks.py` — `wait_for_task`,
  `mark_orphan_tasks_failure`, `assert_probe` (from T2.4).
- [x] Create `atlas/tests/e2e/_image.py` — `ensure_image_on_server`,
  `_ensure_image` (or whatever survived T2.6).
- [x] Convert `_shared.py` to a re-export shim if any external code (incl.
  operator-facing `bench execute` paths) depends on the old import path;
  otherwise delete it and update phase files.
- [x] Confirm each new module is <100 lines: `wc -l atlas/tests/e2e/_*.py`.
- [x] Verify: `bench --site atlas.local execute atlas.tests.e2e.run_all`
  passes.

### T3.7 Replace `server.js` HTML-string render with a Frappe Dashboard

File: [`atlas/atlas/doctype/server/server.js:88-147`](../atlas/atlas/doctype/server/server.js),
[`atlas/atlas/doctype/server/server.py`](../atlas/atlas/doctype/server/server.py)
(`get_form_extras`),
[`atlas/atlas/doctype/server/server.json`](../atlas/atlas/doctype/server/server.json).
(Source: review §3.7, recommendation (2). Taste rule #7: "Use standard
Frappe API as much as possible.")

- [x] In `server.json`, configure the dashboard block with two child sections:
  - [x] "Virtual Machines" — links `Virtual Machine.server = name`.
  - [x] "Recent Tasks" — links `Task.server = name`, sorted by `creation desc`,
        limit 20.
  (Reference Frappe's `Dashboard` doctype config; the `frappe-dev` skill
  covers this.)
- [x] Delete `render_virtual_machines` and `render_recent_tasks` from
  `server.js`. Delete the `frappe.ui.form.on('Server', { refresh: ... })`
  hook that called them.
- [x] Delete `get_form_extras` from `server.py` and its
  `@frappe.whitelist()` registration.
- [x] If `server.js` still has bootstrap/reboot button code, leave those —
  they aren't affected.
- [x] Update [`spec/02-doctypes.md:128-138`](../spec/02-doctypes.md) wireframe
  to reference the dashboard config rather than custom HTML.
- [x] Verify by running the bench server and opening a Server form: VMs and
  recent Tasks render, are clickable, and sort correctly.
- [x] Verify: ~80 lines removed (`git diff --stat` covering
  `server.js`, `server.py`, `server.json`).

---

## Tier 4 — Defer

These are intentionally **not** in scope this iteration. Tracked here so they
don't get lost; do not implement without a new triggering condition.

- [ ] §5.1 — JS button helper (`atlasButton`). Wait for a fourth button.
- [ ] §2.8 — Lifecycle status pattern helper (set-running, try, set-failed,
  set-done). Wait for a third call site.
- [ ] §3.11 — Switch [`scripts/vm-network-down.sh:28-34`](../scripts/vm-network-down.sh)
  from awk to `nft -j | jq`. Wait for a breakage.
- [ ] §3.5 — Gate `SCRIPT_SEARCH_PATHS[e2e]` behind `frappe.flags.in_test`.
  (Worth a separate item if not folded into T3.5's `scripts_catalog.resolve`.)
- [ ] §3.3 — `current_user()` helper for `frappe.session.user if
  frappe.session else "Administrator"`. Saves zero lines today; pick up
  when a third call site appears.
- [ ] §3.6 — Hoist `connection_for_server` import in
  [`atlas/atlas/doctype/server/server.py:31`](../atlas/atlas/doctype/server/server.py)
  to module top once T3.5 lands (the split makes the cycle question moot).

---

## Done-criteria for the whole checklist

- [ ] All Tier 1 boxes checked.
- [ ] All Tier 2 boxes checked.
- [ ] Each Tier 3 item shipped as its own PR; all checked.
- [ ] Total LOC delta is in the range −300 to −400 (per review §8 estimate).
  Sanity-check with `git diff --stat main…HEAD | tail -1` after all merges.
- [ ] No new dependencies added.
- [ ] No behavior change: `bench --site atlas.local run-tests --app atlas`
  and `bench --site atlas.local execute atlas.tests.e2e.run_all` both pass.
- [ ] [`plan/drift.md`](./drift.md) has been amended for the items that
  changed contracts (T3.3 entry 1.2, T3.4 entry 5.4 cross-ref).
- [ ] [`llm/Taste.md`](../llm/Taste.md) carries the six new rules.
- [ ] [`plan/e2e-reliability.md`](./e2e-reliability.md) is deleted.
- [ ] This checklist file is either deleted or moved to an archive folder,
  since its lifecycle ends at iteration close-out.
