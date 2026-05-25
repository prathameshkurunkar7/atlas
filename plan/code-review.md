# Code review — taste, reuse, abstraction (2026-05-26)

Reviewer notes against [`llm/Taste.md`](../llm/Taste.md), the plan in
[`plan/`](./00-overview.md), and the spec in [`spec/`](../spec/README.md).

Verdict: **Phases 1–8 implement the spec.** No phase is missing. The
architecture is sound, the script/Task contract is honoured, drift is
documented. The issues below are taste-level — reuse, duplication, leaking
implementation details — not correctness defects.

The review is organised so each finding is independently actionable. Most
fixes are tens of lines. Two warrant updates to `Taste.md` itself because
they encode rules the codebase already follows that aren't yet written down.

---

## 1. Taste rules that should be made explicit

The current [`llm/Taste.md`](../llm/Taste.md) is ten one-liners. The code
already obeys several rules that aren't stated, and the missing rules are
exactly the ones a future contributor (human or LLM) is most likely to
violate. Promote them.

### 1.1 "Task = one shell script" is a taste rule, not just a doctype rule

The "one Task = one shell script" decision lives in
[`spec/04-tasks.md:73-89`](../spec/04-tasks.md). It is the single biggest
taste choice in the app and isn't reflected in `Taste.md`. A future
contributor adding a Python helper that does `run_task` twice in a row for
"one operation" is silently breaking the contract.

**Add to `Taste.md`:** *"One operation, one shell script, one Task row.
Compose at the script level (heredocs, set -euo pipefail), not by chaining
`run_task` calls in Python. If you have two scripts that always run
back-to-back, merge them."*

The current code mostly honours this, except for one borderline case (the
provision-vm path runs `probe-image-present.sh` then `provision-vm.sh` — two
Tasks for one operator action). That's defensible because the probe is
explicitly an assertion gate, but it should be named that way: see §2.7.

### 1.2 Scripts are the source of truth for what happens on a server

This is in [`spec/01-architecture.md:43-50`](../spec/01-architecture.md) and
in the existing comments at the top of `bootstrap-server.sh`, but it isn't
in `Taste.md`. Without it, the natural instinct is to encode logic in
Python and shell out for the smallest possible operation.

**Add to `Taste.md`:** *"Server-side logic lives in `scripts/*.sh`. Python
calls scripts and parses their output. Do not encode server-side state
machines in Python."*

### 1.3 Idempotency is a script-author obligation

Every script under `scripts/` is idempotent. This is stated in
[`spec/04-tasks.md:138-141`](../spec/04-tasks.md) and is the only retry
strategy Atlas has. It is *not* in `Taste.md`.

**Add to `Taste.md`:** *"Every shell script in `scripts/` must be
idempotent. Retry = re-run, no special repair mode."*

### 1.4 No silent fallbacks

The codebase is consistent: it raises `frappe.ValidationError` with a
specific message when something is wrong, rather than swallowing the error
and trying an alternative. This matches CLAUDE.md's "Don't add error
handling, fallbacks, or validation for scenarios that can't happen." Make
it explicit so a contributor doesn't add a defensive `try/except` around a
network call.

**Add to `Taste.md`:** *"Fail loud at the boundary; do not fall back. SSH
failed? raise. DO API 5xx? raise. The operator retries by clicking the
button."*

### 1.5 No abbreviations — enforce on shell too

Rule #6 in `Taste.md` says "Avoid abbreviations." Most of the Python obeys
it (`virtual_machine_name`, not `vm_name`). The shell scripts mostly
obey it for variables but several Python and JS sites still use
`vm`/`vms`. Specifically:

- [`virtual_machine.js:18`](../atlas/atlas/doctype/virtual_machine/virtual_machine.js) — `delete_vm` (collision-avoiding, fine)
- [`virtual_machine.py:116`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py) — `delete_vm` method (same, fine)
- [`_inspect.py:44`](../atlas/tests/e2e/_inspect.py) — `archive_all_vms` — could be `archive_all_virtual_machines`
- [`server.js`](../atlas/atlas/doctype/server/server.js) — `vm_wrapper`, `render_virtual_machines(rows)` — mixed
- [`phase_5.py:24`](../atlas/tests/e2e/phase_5.py) — `vm = …` local

These are fine. Pin it in `Taste.md` with the explicit carve-out: *"`vm`
is allowed only when (a) it shadows a Frappe method name (`delete`) or
(b) it is a local variable inside a five-line function. Doctype controller
methods, module-level functions, public helpers: spell it out."*

### 1.6 Test layout

The existing convention — tests next to the controller, plus
`atlas/tests/` for module-level — is good, but it's only documented in
[`plan/00-overview.md:47-49`](./00-overview.md). Promote one sentence to
`Taste.md`.

**Add to `Taste.md`:** *"Tests live next to the code they cover.
`atlas/atlas/doctype/<x>/test_<x>.py` for controllers,
`atlas/tests/test_<module>.py` for modules, `atlas/tests/e2e/phase_N.py`
for end-to-end."*

---

## 2. Code reuse and duplication

### 2.1 Test-fixture builders are duplicated across six files

This is the single biggest source of duplication in the codebase.

Five test files each define their own `_make_provider` / `_ensure_server` /
`_ensure_image` / `_make_server`:

- [`atlas/atlas/doctype/server/test_server.py:9-44`](../atlas/atlas/doctype/server/test_server.py)
  — `_make_provider`, `_make_server`
- [`atlas/atlas/doctype/server_provider/test_server_provider.py:7-21`](../atlas/atlas/doctype/server_provider/test_server_provider.py)
  — `_make_provider`
- [`atlas/atlas/doctype/virtual_machine/test_virtual_machine.py:7-70`](../atlas/atlas/doctype/virtual_machine/test_virtual_machine.py)
  — `_ensure_image`, `_ensure_server`, `_new_vm`
- [`atlas/atlas/doctype/virtual_machine_image/test_virtual_machine_image.py:9-48`](../atlas/atlas/doctype/virtual_machine_image/test_virtual_machine_image.py)
  — `_make_image`, `_make_provider_and_server`
- [`atlas/tests/test_networking.py:14-77`](../atlas/tests/test_networking.py)
  — `_make_provider_and_server`, `_insert_vm`, `_ensure_image`
- [`atlas/tests/test_permissions.py:17-31`](../atlas/tests/test_permissions.py)
  — `_make_provider`

Six near-identical Server Provider builders, each with slightly different
defaults (`api_token = "fake"` vs `"dop_v1_fake"`; `ssh_private_key = "k"`
vs PEM). All re-implement the "if exists, return it; else insert" pattern.

**Fix:** create `atlas/tests/fixtures.py` (or extend the existing
`atlas/tests/__init__.py`) with one builder each:

```python
# atlas/tests/fixtures.py
def make_provider(name="test-provider", **overrides): ...
def make_server(provider, name="test-server", **overrides): ...
def make_image(name="test-image", **overrides): ...
def make_virtual_machine(server, image, **overrides): ...
```

Each builder is the "if exists, return; else insert" idiom, takes a name
and an `**overrides` kwarg, and applies sensible defaults. Test files
import what they need. Conservatively cuts ~180 lines from the test suite.
Also fixes a real bug: the disparity in defaults (`"fake"` vs `"dop_v1_fake"`)
makes it harder to spot when a test relies on token shape.

### 2.2 Ephemeral SSH keypair generator is duplicated between phase 5 and phase 6

[`phase_5.py:77-87`](../atlas/tests/e2e/phase_5.py) and
[`phase_6.py:102-112`](../atlas/tests/e2e/phase_6.py) implement
`_make_ephemeral_keypair` / `_ephemeral_public_key` essentially identically.
The difference is what they return (directory vs public-key string), but
the keypair-generation half is byte-identical.

**Fix:** one helper in `_shared.py`:

```python
def ephemeral_public_key() -> str:
    ...  # ssh-keygen if missing, return .pub contents
```

Both phases call it. Saves ~25 lines and makes "phase 5 and phase 6 use
the same key" an enforced invariant rather than two coincident
implementations.

### 2.3 `phase_5._move_image_aside` / `_move_image_back` collapse to one helper

[`phase_5.py:90-117`](../atlas/tests/e2e/phase_5.py): two near-identical
functions, only differ in `"DIRECTION": "aside"` vs `"back"`. Make it one
function with a `direction` parameter. Saves ~25 lines.

### 2.4 The "is X status, run script, assert Success" pattern is repeated 6× in phase 5/6

[`phase_5.py:120-127`](../atlas/tests/e2e/phase_5.py),
[`phase_6.py:115-145`](../atlas/tests/e2e/phase_6.py) all have:

```python
def _assert_is_active(server_name, vm_name):
    task = run_task_on_server(
        server=server_name,
        script="phase5-is-active.sh",
        variables={"VIRTUAL_MACHINE_NAME": vm_name},
        timeout_seconds=15,
    )
    assert task.status == "Success", task.stderr
```

The variant that takes one extra variable (`TAP_DEVICE` in
`_assert_gone`) is the same template. These collapse to:

```python
# in _shared.py
def assert_probe(server_name, script, **variables):
    task = run_task_on_server(
        server=server_name, script=script, variables=variables, timeout_seconds=15,
    )
    assert task.status == "Success", task.stderr
```

Removes ~30 lines, makes probe assertion a one-liner.

### 2.5 `_ensure_provider` duplicated between `phase_3.py` and `_shared.py`

[`phase_3.py:60-75`](../atlas/tests/e2e/phase_3.py)'s `_ensure_provider`
and [`_shared.py:240-255`](../atlas/tests/e2e/_shared.py)'s
`_ensure_e2e_provider` are 95% identical — same fields, same `name`,
same insert pattern. They were even given the same provider name
(`atlas-e2e-provider`).

**Fix:** delete `phase_3._ensure_provider`, import the shared one. Drop
the leading underscore on the shared helper so it can be imported.

### 2.6 `_ensure_image` duplicated between `_shared.py` and `phase_4.py`

[`phase_4.py:55-65`](../atlas/tests/e2e/phase_4.py) and
[`_shared.py:266-280`](../atlas/tests/e2e/_shared.py) both implement the
"insert-or-update Virtual Machine Image" pattern. The `_shared.py` version
is the better one (it does the remote probe + sync). Phase 4 should call it
and lose `_ensure_image` entirely.

### 2.7 `provision()` runs two Tasks per operator click — name the probe correctly or fold it in

[`virtual_machine.py:40-70, 147-162`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py).
The current flow: `provision()` runs `probe-image-present.sh` as a Task,
then `provision-vm.sh` as a second Task. Per §1.1 ("one operation, one
Task"), this leaks an implementation detail (the probe) into the audit log.

Two acceptable resolutions:

1. **Fold the probe into `provision-vm.sh`.** Add a `# 0. Verify image`
   step at the top of [`provision-vm.sh`](../scripts/provision-vm.sh) that
   does the existence check the probe currently does, and exits with a
   clear message. Drop `probe-image-present.sh` entirely. One Task per
   provision, message stays clear, audit log stays clean.
2. **Keep the probe, but document it.** Add a paragraph to
   [`spec/05-virtual-machine-lifecycle.md`](../spec/05-virtual-machine-lifecycle.md)
   that says provision produces two Task rows by design: the probe is its
   own Task because it can fail without changing VM state, and that makes
   the operator's debugging easier.

Recommendation: (1). The probe doesn't earn its row — its output is
`echo "image present"` and its only failure mode is "missing file."
`provision-vm.sh` already does dozens of small checks; one more at the
top is cheaper than maintaining a separate script and a separate Task.

### 2.8 The "set status, save, commit, try, on-fail set status, save, commit, re-raise" pattern repeats

[`virtual_machine.py:40-70`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py)
(`provision`) and
[`server_provider.py:53-86`](../atlas/atlas/server_provider.py)
(`finish_provisioning`) both implement the same skeleton:

```
1. set status = "InProgress"
2. save + commit
3. try: run the long thing
4. except: reload, set status = "Failed", save, commit, re-raise
5. reload, set status = "Done", save, commit
```

Worth one helper if a third site appears. Right now two sites is the
threshold below which an abstraction usually costs more than it saves.
Worth pinning as a comment so a contributor doesn't extract it
prematurely. **No change this iteration; flag for revisit.**

### 2.9 `e2e/_inspect.py` is a grab-bag — split or scope

[`_inspect.py`](../atlas/tests/e2e/_inspect.py) has five unrelated
operator-escape-hatch functions: `dump_for_server`, `mark_task_failure`,
`list_droplets`, `archive_all_vms`, `rebootstrap`, `dump_recent_tasks`.
Two are near-duplicates (`dump_for_server` vs `dump_recent_tasks`).

**Fix:** collapse `dump_for_server` and `dump_recent_tasks` into one
function that takes an optional `server_name` filter. Saves ~15 lines.
The other functions are fine as-is.

### 2.10 `_resolved_uploads()` in `server.py` is overkill for three hard-coded paths

[`server.py:120-129`](../atlas/atlas/doctype/server/server.py) loops over
three tuples, asserts a prefix, strips it, rejoins. The prefix-strip is
load-bearing: `BOOTSTRAP_UPLOADS` keeps repo-relative paths, but
`SCRIPTS_DIRECTORY` is already `<repo>/scripts/`. The whole helper exists
because the data was stored in a format the consumer can't use directly.

**Fix:** store the upload list in the form the caller needs:

```python
BOOTSTRAP_UPLOADS = [
    ("vm-network-up.sh", "/var/lib/atlas/bin/vm-network-up.sh"),
    ("vm-network-down.sh", "/var/lib/atlas/bin/vm-network-down.sh"),
    ("systemd/firecracker-vm@.service", "/etc/systemd/system/firecracker-vm@.service"),
]

def _resolved_uploads():
    return [(str(SCRIPTS_DIRECTORY / src), dst) for src, dst in BOOTSTRAP_UPLOADS]
```

Same effect, half the code, no assertion needed.

### 2.11 `script_uploads.py` is a one-entry registry

[`script_uploads.py`](../atlas/atlas/script_uploads.py) defines a 20-line
module to support a dict with a single key (`sync-image.sh`). The
abstraction is the right shape — declaration goes where the script's
sidecars are needed — but at one entry it's hard to tell. Leave it; it
becomes load-bearing the moment a second script needs a sidecar.

`SCRIPT_UPLOADS` is referenced by `ssh._run_remote_script` via a function
that just does `dict.get()`. That function is unnecessary indirection:

```python
# script_uploads.py
def files_to_upload(script: str) -> list[tuple[str, str]]:
    return SCRIPT_UPLOADS.get(script, [])
```

Could be `SCRIPT_UPLOADS.get(script, [])` inline at the one call site,
dropping the wrapper. But the wrapper is a documented hookpoint — keep it
for the affordance even though it has one user.

### 2.12 `ssh.execute_task` and `ssh.run_task` have meaningful overlap

[`ssh.py:45-81`](../atlas/atlas/ssh.py): `run_task` inserts then runs;
`execute_task` loads then runs. Both end up calling `_execute_into`. The
shape is right.

One small issue: `execute_task` rebuilds the connection from scratch
(loads `Server` doc, builds dict). It can't reuse `run_task_on_server`
because it operates on an existing Task. The current code is fine —
`_execute_into` is the shared core. **No change.**

---

## 3. Leaking implementation details

### 3.1 `run_task_on_server` re-implements what `run_task` already does

[`ssh.py:100-117`](../atlas/atlas/ssh.py): `run_task_on_server` exists
purely to translate a server name into a connection dict, then call
`run_task` with all the same arguments restated:

```python
def run_task_on_server(server, script, variables, virtual_machine=None, timeout_seconds=1800):
    server_doc = frappe.get_doc("Server", server)
    connection = connection_for_server(server_doc)
    return run_task(
        connection=connection,
        script=script,
        variables=variables,
        server=server,
        virtual_machine=virtual_machine,
        timeout_seconds=timeout_seconds,
    )
```

Every keyword argument is restated. Adding a new argument to `run_task`
means adding it twice. Two clean options:

1. **Make `run_task` smarter:** accept *either* `connection=` *or*
   `server=` as the first arg. If `server`, look up the doc and build the
   connection.
2. **Use `**kwargs` passthrough on the wrapper** for everything except
   the two args the wrapper actually transforms.

(1) is the cleaner refactor and matches the natural mental model
("run_task on a server"). The downside is `connection=` becomes for
bootstrap-only (no Server doc exists yet). Document that explicitly.

```python
def run_task(
    *,
    server: str | None = None,
    connection: dict | None = None,
    script: str,
    variables: dict,
    virtual_machine: str | None = None,
    timeout_seconds: int = 1800,
) -> "Task":
    if not (server or connection):
        frappe.throw("run_task needs server=… or connection=…")
    if server and not connection:
        connection = connection_for_server(frappe.get_doc("Server", server))
    ...
```

Caller sites become uniform: `run_task(server=..., script=..., variables=...)`
everywhere except `Server.bootstrap()` which still passes `connection=` because
the row may be incomplete. Phase 8's drift.md item 1.2 ("keep both") can
be revisited: the right answer is "merge into one entry point with two
modes."

### 3.2 `Task.variables` is JSON-as-string at the row level — should be parsed on read

Every caller of `Task` either:
- Writes JSON into `variables` (`json.dumps(variables, sort_keys=True)` —
  done at four sites: [`ssh.py:63`](../atlas/atlas/ssh.py),
  [`virtual_machine_image.py:40`](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py),
  one more in execute_task path).
- Reads JSON out of `variables`
  ([`ssh.py:80`](../atlas/atlas/ssh.py) — `json.loads(task.variables or "{}")`).
- Has a validator that re-parses to check
  ([`task.py:14-22`](../atlas/atlas/doctype/task/task.py)).

The JSON-encoding is implementation detail. The Task should hide it.

**Fix:** add two helpers on the Task controller:

```python
class Task(Document):
    @property
    def variables_dict(self) -> dict:
        return json.loads(self.variables or "{}")

    @variables_dict.setter
    def variables_dict(self, value: dict) -> None:
        self.variables = json.dumps(value, sort_keys=True)
```

Callers go from `json.dumps(variables, sort_keys=True)` to
`task.variables_dict = variables`. The validation in `Task.validate()`
stops needing to JSON-parse-then-check-it's-a-dict because the setter
enforces dict-shape on the way in. The DocType field stays a string
(Frappe storage), but Python never sees the encoded form again.

### 3.3 `frappe.session.user if frappe.session else "Administrator"` is repeated

Two sites:
- [`ssh.py:65`](../atlas/atlas/ssh.py)
- [`virtual_machine_image.py:42`](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py)

Both compute the same thing. Encode once:

```python
# in ssh.py or a small auth.py
def current_user() -> str:
    return getattr(frappe.session, "user", None) or "Administrator"
```

Saves zero lines on its own, but means a future change ("scheduler should
log as `Atlas Scheduler` not `Administrator`") touches one site.

### 3.4 Connection dict is structural typing — should be a small dataclass

[`ssh.py:84-97`](../atlas/atlas/ssh.py): every helper takes `connection:
dict` and indexes `connection["host"]`, `connection["ssh_private_key"]`,
`connection.get("user", "root")`. The shape is duplicated by every caller
that builds one (phase 1 e2e, `_shared.py`).

**Fix:** small dataclass.

```python
@dataclasses.dataclass(frozen=True)
class Connection:
    host: str
    ssh_private_key: str
    user: str = "root"
```

`run_task` accepts `Connection`. `connection_for_server` returns
`Connection`. `dict` callers (the e2e harness, phase 1) build a
`Connection`. The `connection.get("user", "root")` default lives in one
place (the dataclass default). Removes 4 sites that have to know the
shape, doesn't change runtime behavior, gives IDE autocomplete.

### 3.5 `_resolve_script` walks two directories — make it data-driven

[`ssh.py:347-354`](../atlas/atlas/ssh.py): `SCRIPT_SEARCH_PATHS` is two
entries: production scripts and e2e-only scripts. The "e2e scripts are
under `atlas/tests/e2e/scripts/`" is a thing test code knows. Production
code shouldn't have to know it.

Either:
- Gate the e2e directory behind a check that we're in a test (existing
  Frappe convention: `frappe.flags.in_test`), so a production deploy can't
  resolve a test-only script as a Task.
- Or move the e2e scripts to a location the resolver doesn't have to
  special-case (e.g. include them under `scripts/` but exclude from
  `scripts_catalog.allowed_scripts()` already — the catalog is the security
  boundary, the resolver doesn't need to be one).

Phase 7's `scripts_catalog.allowed_scripts()` is the actual whitelist. The
resolver doesn't need to know about test scripts at all if e2e tests just
use the same `scripts/` directory and rely on the catalog for the boundary.

Recommendation: **gate behind `frappe.flags.in_test`** because moving the
phase-N probe scripts dilutes the production `scripts/` directory.

### 3.6 `Server.bootstrap`'s import of `connection_for_server` is at function scope

[`server.py:31`](../atlas/atlas/doctype/server/server.py):

```python
def bootstrap(self) -> str:
    ...
    from atlas.atlas.ssh import connection_for_server  # noqa: PLC0415
```

The `noqa` comment signals this is intentional, but the import sits inside
a method body. Looking at the actual cycle:
- `server.py` imports from `atlas.atlas.ssh`: `run_task`, `run_task_on_server`,
  `upload_files`.
- `atlas.atlas.ssh` imports… nothing from `server`. The cycle isn't real.

This is a leftover from an earlier draft. Hoist the import to the top
with the other `ssh.py` imports. Same for
[`virtual_machine.py:6`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py)
which already has `run_task_on_server` at the top — good. And for the
`server_provider.py:20` local import which is genuinely circular-ish
(controller calling module function of the same name); document the
reason or rename one of them.

### 3.7 The HTML rendering in `server.js` belongs in a template, not in `.then` callbacks

[`server.js:88-147`](../atlas/atlas/doctype/server/server.js): two
~25-line template-string functions, `render_virtual_machines` and
`render_recent_tasks`, that build HTML by string concatenation. They
escape correctly. They are still html-in-strings.

Two options:

1. **Move them to a template.** Frappe has Jinja templates server-side.
   Return rendered HTML from `get_form_extras()` directly.
2. **Use the standard Frappe child-list pattern.** A `Dashboard` block on
   the Server form would show child VMs and recent Tasks without any JS.
   `frappe.ui.form.on('Server', { refresh: render_dashboard })` calls a
   built-in helper.

The spec wireframe ([`spec/02-doctypes.md:128-138`](../spec/02-doctypes.md))
shows these as part of the form. (2) is more idiomatic for Frappe; it's a
dashboard config + zero JS. (1) keeps the data shape control but moves the
strings out of JS.

Recommendation: (2). The whitelisted Python method
`get_form_extras` and the two render functions go away entirely. Save ~80
lines, gain dashboard sort/click/etc. for free. Rule #7 in `Taste.md`
("Use standard Frappe API as much as possible") points the same way.

### 3.8 `Virtual Machine.before_validate` re-checks `is_new()` four times

[`virtual_machine.py:19-27`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py):

```python
def before_validate(self) -> None:
    if self.is_new() and not self.mac_address:
        self.mac_address = derive_mac(self.name)
    if self.is_new() and not self.tap_device:
        self.tap_device = derive_tap(self.name)
    if self.is_new() and not self.ipv6_address:
        self.ipv6_address = allocate_ipv6(self.server)
    if self.is_new() and not self.status:
        self.status = "Pending"
```

Reads cleaner as:

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

Same lines saved, clearer intent: "everything below this is insert-only."

### 3.9 `_assert_image_present` ends with a dead `_ = probe`

[`virtual_machine.py:147-162`](../atlas/atlas/doctype/virtual_machine/virtual_machine.py):

```python
probe = run_task_on_server(...)
# comment explaining why
_ = probe
```

The comment explains that the probe's success is the assertion (it raises
on failure). The `_ = probe` swallow is doing nothing — `probe` is
already unused. Either:

- Don't bind the return value at all: `run_task_on_server(...)` standalone.
  The comment alone explains the intent.
- Or merge with §2.7's recommendation: fold the check into
  `provision-vm.sh` and delete this method entirely.

### 3.10 `bootstrap-server.sh` re-implements an idempotent file install

[`bootstrap-server.sh:55-59`](../scripts/bootstrap-server.sh):

```bash
sudo install -m 0644 /dev/stdin /etc/sysctl.d/60-atlas.conf <<'CONF'
...
CONF
```

This is fine. Just flagging that `sync-image.sh` and `provision-vm.sh`
also use this pattern — three sites. If a fourth site shows up, extract a
shell helper sourced by all of them. Not now.

### 3.11 `vm-network-down.sh` parses `nft` output via awk

[`vm-network-down.sh:28-34`](../scripts/vm-network-down.sh):

```bash
handles="$(sudo nft -a list chain inet atlas forward 2>/dev/null \
    | awk -v ip="$VIRTUAL_MACHINE_IPV6" '$0 ~ ip {print $NF}')"
```

`nft -j` produces JSON. `jq` is already a hard dep (installed by
`bootstrap-server.sh`). Switching to `nft -j list chain inet atlas forward
| jq -r '.[] | select(.rule.expr[]?.match.right == "<ip>") | .rule.handle'`
is more robust against output format changes. Not urgent — current code
works — but the awk version is the kind of thing that breaks silently on
a Debian/Ubuntu upgrade.

### 3.12 `digitalocean.py::delete_droplet` does work twice for 404s

[`digitalocean.py:75-81`](../atlas/atlas/digitalocean.py):

```python
def delete_droplet(self, droplet_id: int) -> None:
    try:
        self._request("DELETE", f"/droplets/{droplet_id}", allow_404=True)
    except DigitalOceanError as exception:
        if "404" in str(exception):
            return
        raise
```

`allow_404=True` already swallows the 404 inside `_request` (`return {}`).
The `try/except DigitalOceanError` that checks for "404" in the message
is unreachable code. Drop the try/except.

```python
def delete_droplet(self, droplet_id: int) -> None:
    self._request("DELETE", f"/droplets/{droplet_id}", allow_404=True)
```

Three lines instead of seven.

---

## 4. File-size and module-size compliance

`Taste.md` rule #4: 100–300 lines per file. Rule #5: <15 files per
directory.

Current status:

- `atlas/atlas/ssh.py` — **360 lines**, over the cap.
- `atlas/tests/e2e/_shared.py` — **357 lines**, over the cap.

Both are above 300 by ~20%. Suggestions:

### 4.1 Split `ssh.py`

[`ssh.py`](../atlas/atlas/ssh.py) currently does:
1. Public surface (`run_task`, `execute_task`, `run_task_on_server`,
   `connection_for_server`, `wait_for_ssh`, `upload_files`).
2. Subprocess plumbing (`_run_ssh`, `_run_scp`, `_ssh_key_file`).
3. Script resolution (`_resolve_script`).
4. Task row lifecycle (`_execute_into`, `_finalize`).

Natural split:
- `ssh.py` — public surface only (~120 lines).
- `_ssh_subprocess.py` — `_run_ssh`, `_run_scp`, `_ssh_key_file`,
  `_ensure_known_hosts_directory`, `SSH_OPTIONS` (~80 lines).
- `_task_runner.py` — `_execute_into`, `_finalize`, `_run_remote_script`
  (~100 lines).
- The script resolution helpers move into `scripts_catalog.py` (which is
  already the script-knowledge module). The `_resolve_script` function
  becomes `scripts_catalog.resolve()` and applies the same whitelist the
  Run Task dialog uses — closing one tiny inconsistency.

Public callers (`Server`, `Virtual Machine`, `Server Provider`) import
from `ssh` and don't care about the internal split.

### 4.2 Split `_shared.py`

[`_shared.py`](../atlas/tests/e2e/_shared.py) does six things:
- Site-config reads (`get_client`, `get_ssh_key_id`, `get_region`, …).
- Droplet provisioning helpers (`create_test_droplet`,
  `sweep_old_droplets`, `cleanup_droplet`, `teardown_all`).
- Task polling (`wait_for_task`, `mark_orphan_tasks_failure`).
- Server lifecycle (`ensure_bootstrapped_server`, `server_is_reachable`,
  `_ensure_e2e_provider`).
- Image lifecycle (`ensure_image_on_server`, `DEFAULT_IMAGE`).
- Phase-1 connection.

Split into:
- `e2e/_config.py` — site-config readers, `DEFAULT_IMAGE`.
- `e2e/_droplets.py` — droplet/server provisioning + teardown.
- `e2e/_tasks.py` — Task waiting + orphan cleanup.
- `e2e/_image.py` — image fixture management.

Each <100 lines. Phase files import what they need.

### 4.3 Directory-size compliance: `atlas/atlas/` is at 12

Currently in [`atlas/atlas/`](../atlas/atlas/): `__init__.py`,
`digitalocean.py`, `networking.py`, `secrets.py`, `server_provider.py`,
`script_uploads.py`, `scripts_catalog.py`, `ssh.py`, `config/`,
`patches/`, `templates/`, `doctype/`. That's 12, under the cap. Splitting
`ssh.py` per §4.1 brings it to 14 (still under cap if the helpers go in a
private subpackage `_ssh/`, or one over if flat). Recommend a `_ssh/`
subpackage to keep the top-level module count clean.

---

## 5. Verbosity reductions

### 5.1 Five-line `confirm/call/show_alert/reload` JS dance

`server.js`, `virtual_machine.js`, `virtual_machine_image.js` all have:

```js
frm.add_custom_button("X", () => {
    frappe.confirm(`X ${frm.doc.name}?`, () => {
        frm.call("x").then(({message}) => {
            frappe.show_alert({...});
            frm.reload_doc();
        });
    });
});
```

Five sites × five lines = 25 lines that could be a helper:

```js
// in atlas/public/js/atlas_buttons.js (new file, autoloaded via hooks)
function atlasButton(frm, label, method, options = {}) {
    frm.add_custom_button(label, () => {
        frappe.confirm(options.message || `${label} ${frm.doc.name}?`, () => {
            frm.call(method).then(({message}) => {
                if (options.alert) frappe.show_alert({message: options.alert(message), indicator: options.indicator || "blue"});
                if (options.route) frappe.set_route("Form", options.route, message);
                else frm.reload_doc();
            });
        });
    });
}
```

Caller becomes:

```js
atlasButton(frm, "Bootstrap", "bootstrap",
    {alert: t => `Bootstrap Task: ${t}`, indicator: "blue"});
```

Less code; the *intent* of each button (confirm → call → react) is
visible in one line. Adds one shared module the hooks must autoload.

Counter-argument: each callsite is small, and a custom helper makes the
naive reader chase one more indirection. Verdict: **probably worth it
once the third button shows up**, which it has. Recommend implementing.

### 5.2 `MagicMock` + `mocked.assert_called_once()` ceremony in tests

Many tests do:

```python
task = MagicMock()
task.name = "task-x"
with patch.object(module, "run_task_on_server", return_value=task) as mocked:
    result = vm.start()
self.assertEqual(result, "task-x")
vm.reload()
self.assertEqual(vm.status, "Running")
mocked.assert_called_once()
self.assertEqual(mocked.call_args.kwargs["script"], "start-vm.sh")
```

The `MagicMock()` + `.name = "task-x"` two-liner could be one:
`task = MagicMock(name="x"); task.name = "task-x"` (the Mock constructor's
`name` is the mock's own name, not the attribute; that's surprising and
worth a helper).

```python
# atlas/tests/_mocks.py
def fake_task(name="task"):
    m = MagicMock()
    m.name = name
    m.status = "Success"
    return m
```

Test sites become `fake_task("task-start-1")`. Marginal gain (~10 lines
saved across the suite); take it.

### 5.3 `_inspect.dump_*` functions print and don't return

They are operator-facing console helpers, so `print` is fine. But each
function ends with the same "last 2000/last 1000" truncation pattern.
Worth one helper:

```python
def _print_task(name: str) -> None:
    doc = frappe.get_doc("Task", name)
    print(f"\n=== Task {doc.name} ({doc.script}) status={doc.status} ===")
    print("STDOUT (last 2000):"); print((doc.stdout or "(none)")[-2000:])
    print("\nSTDERR (last 1000):"); print((doc.stderr or "(none)")[-1000:])
```

Both `dump_for_server` and `dump_recent_tasks` call it. Then merge per
§2.9.

### 5.4 Phase runners have identical try/except/print scaffolding

Every `phase_N.py` (1, 2, 3, 4, 5, 6, 7) opens with:

```python
def run(reuse: bool = True, keep: bool = True) -> None:
    start_clock = time.monotonic()
    server, client, created_now = ensure_bootstrapped_server(reuse=reuse, keep=keep)
    sweep_old_droplets(client)
    ...
    try:
        ...
    except Exception:
        elapsed = time.monotonic() - start_clock
        print(f"phase-N: FAIL in {elapsed:.0f}s")
        traceback.print_exc()
        raise
    finally:
        if created_now and not keep and server.provider_resource_id:
            cleanup_droplet(client, int(server.provider_resource_id))

    elapsed = time.monotonic() - start_clock
    print(f"phase-N: OK in {elapsed:.0f}s")
```

That's six phases each repeating ~15 lines of identical scaffolding.
Extract a context manager:

```python
# in _shared.py
@contextmanager
def phase(label: str, reuse: bool = True, keep: bool = True):
    start = time.monotonic()
    server, client, created_now = ensure_bootstrapped_server(reuse=reuse, keep=keep)
    sweep_old_droplets(client)
    try:
        yield server
    except Exception:
        elapsed = time.monotonic() - start
        print(f"{label}: FAIL in {elapsed:.0f}s")
        traceback.print_exc()
        raise
    else:
        elapsed = time.monotonic() - start
        print(f"{label}: OK in {elapsed:.0f}s")
    finally:
        if created_now and not keep and server.provider_resource_id:
            cleanup_droplet(client, int(server.provider_resource_id))
```

Each phase body becomes:

```python
def run(reuse=True, keep=True):
    with phase("phase-5", reuse=reuse, keep=keep) as server:
        ... actual test ...
```

Saves ~80 lines across the e2e suite. Phase 1 and phase 2 don't fit the
shape (no bootstrapped server), so they keep their current form.

---

## 6. Plan/spec hygiene that fell out of the review

### 6.1 Phase plan doesn't reference the test-fixture sharing decision

The plan describes "tests live next to the doctype they cover" but
doesn't say "tests share fixture builders from a central module."
Phases 3–6 each ended up writing their own builders (see §2.1). The
plan should pin this convention upfront.

**Fix:** add a paragraph to
[`plan/00-overview.md`](./00-overview.md)'s "Conventions used by every
phase" section:

> Test fixture builders (`make_server`, `make_image`, etc.) live in
> `atlas/tests/fixtures.py`. Each builder takes a name and `**overrides`,
> implements "create if not exists." Test files import from there; no
> per-file `_make_provider` reimplementations.

### 6.2 `drift.md` entries 1.1, 1.2, 3.x, 7.x all resolved as "spec was wrong" — pattern worth noting

A skim of `drift.md` shows the resolution pattern: when the spec disagreed
with the implementation, the implementation was almost always the right
answer. Items 1.1 (hash vs UUID), 1.2 (run_task signature), 3.x (Server
field semantics), 5.1 (UUID naming), 7.x (reboot, scripts catalog) all
became spec updates.

This is fine — the spec is descriptive, the code is the artifact. Worth
adding one paragraph to [`spec/README.md`](../spec/README.md):

> The spec describes the system as it is. When the spec and code disagree,
> the code is the source of truth and the spec gets updated to match,
> unless the disagreement reveals a code defect. The `plan/drift.md`
> running log of these discoveries is preserved as project history.

### 6.3 Phase plans should reference `Taste.md` for the rules added in §1

Once §1's additions land in `Taste.md`, the per-phase plan files'
"Implementation notes" sections should reference them where relevant:

- Phase 1's "Task = one shell script" notes → cite the new §1.1 taste rule.
- Phase 3's "scripts uploaded by bootstrap" → cite §1.2.
- Every phase's "idempotent" mention → cite §1.3.

This is a 5-minute pass through the phase files.

### 6.4 `plan/e2e-reliability.md` should fold into `drift.md` or be deleted

[`plan/e2e-reliability.md`](./e2e-reliability.md) is a 13 KB working
document about test-flakiness fixes that all shipped. The shipped fixes
are recorded in `drift.md` (entries E1–E7). The standalone document is
no longer the authoritative version of any of those decisions.

**Fix:** delete `plan/e2e-reliability.md` once §6.1's review and §1's
`Taste.md` updates land. The historical work product is preserved in
git and in `drift.md`.

---

## 7. Phase-by-phase taste compliance

| Phase | Implements spec? | Taste-clean? | Headline issue |
|-------|------------------|--------------|----------------|
| 1 (SSH + Task) | Yes | Mostly | `ssh.py` over the line cap; `run_task` / `run_task_on_server` duplication |
| 2 (DO client) | Yes | Yes | Tiny `delete_droplet` dead-code (§3.12) |
| 3 (Server + bootstrap) | Yes | Mostly | `_resolved_uploads` overkill (§2.10); duplicate `_ensure_provider` (§2.5) |
| 4 (Image sync) | Yes | Mostly | Duplicate `_ensure_image` (§2.6) |
| 5 (VM provision) | Yes | Mostly | Two Tasks per click (§2.7); duplicate keypair helper (§2.2); aside/back twins (§2.3) |
| 6 (VM lifecycle) | Yes | Mostly | Probe-assertion duplication (§2.4); shared keypair (§2.2) |
| 7 (Run Task + polish) | Yes | Yes | Form HTML in JS strings (§3.7) — leaks into Phase 3's form too |
| 8 (Permissions + docs) | Yes | Yes | None |

No phase is structurally wrong. No drift item is unresolved beyond what
`drift.md` already pins to the post-iteration roadmap. The taste issues
are uniformly small (delete N lines, extract one helper).

---

## 8. Prioritised do-list

If only some of this lands, do them in this order:

**Tier 1 (taste-rule additions, no code change required):**
1. Update `Taste.md` per §1 (six new rules).
2. Update `plan/00-overview.md` per §6.1 (test fixture convention).
3. Update `spec/README.md` per §6.2 (spec-vs-code policy).

**Tier 2 (mechanical, high-confidence):**
4. Add `atlas/tests/fixtures.py`, migrate test files (§2.1).
5. Extract `ephemeral_public_key` helper, merge `_move_image_aside/back`,
   extract `assert_probe`, extract `phase()` context manager
   (§2.2, §2.3, §2.4, §5.4).
6. Delete `phase_3._ensure_provider`, delete `phase_4._ensure_image`,
   merge `dump_for_server`/`dump_recent_tasks` (§2.5, §2.6, §2.9).
7. Simplify `_resolved_uploads` (§2.10), drop dead try/except in
   `delete_droplet` (§3.12), drop `_ = probe` (§3.9), flatten `is_new()`
   checks in VM `before_validate` (§3.8).

**Tier 3 (architectural; each is a separate PR):**
8. Add `Task.variables_dict` property, migrate callers (§3.2).
9. Introduce `Connection` dataclass (§3.4).
10. Merge `run_task` / `run_task_on_server` into one entry point (§3.1).
11. Fold image-presence probe into `provision-vm.sh` (§2.7).
12. Split `ssh.py` and `_shared.py` (§4.1, §4.2).
13. Replace `server.js` HTML-strings with a Frappe dashboard (§3.7).

**Tier 4 (defer):**
14. JS button helper (§5.1) — wait for a fourth button.
15. Lifecycle status pattern helper (§2.8) — wait for a third call site.
16. Switch `vm-network-down.sh` awk → `nft -j | jq` (§3.11) — wait for a
    breakage.

Total impact across all tiers: roughly **–300 to –400 lines of code**,
no new dependencies, no behavior change.
