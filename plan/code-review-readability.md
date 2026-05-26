# Code review — readability and unnecessary complexity

Reviewed: 2026-05-26. Scope: `atlas/atlas/**/*.py`, `atlas/tests/**/*.py`,
`scripts/*.sh`. Focus is strictly readability and unnecessary complexity per
[`llm/Taste.md`](../llm/Taste.md) — not security, performance, or behavioral
correctness.

Findings are grouped by severity. Each entry names the file, quotes the
current shape, explains the problem, and shows the corrective shape.

---

## Severity legend

- **🔴 High** — actively misleading reader, or duplicated/dead surface that
  costs every reader time. Fix before next iteration.
- **🟡 Medium** — works fine but reads worse than it could. Fix
  opportunistically when touching the file.
- **🟢 Low** — stylistic polish. Note for future writers.

---

# 🔴 HIGH severity

## H1. `atlas/atlas/ssh.py` is a re-export shim that re-exports a re-export shim

**Files:**
- [atlas/atlas/ssh.py](../atlas/atlas/ssh.py) — 38-line shim
- [atlas/atlas/_ssh/__init__.py](../atlas/atlas/_ssh/__init__.py) — another 27-line shim
- [atlas/atlas/_ssh/transport.py](../atlas/atlas/_ssh/transport.py), [atlas/atlas/_ssh/runner.py](../atlas/atlas/_ssh/runner.py) — the actual code

**Problem.** A reader hunting `run_task` follows this chain:

1. Open `ssh.py` (public surface, per [drift.md T3.5](./drift.md#L538)).
2. Sees `from atlas.atlas._ssh.runner import run_task` — opens `_ssh/`.
3. `_ssh/__init__.py` *also* re-exports `run_task` from `runner`. Why? It's not
   imported from anywhere — `ssh.py` imports directly from the submodules.
4. Finally lands in `_ssh/runner.py`, the real definition.

Two layers of shims for one function. The `_ssh/__init__.py` block is dead:
nothing in the tree imports from `atlas.atlas._ssh` (everything goes through
`atlas.atlas.ssh`). Verified via grep:

```bash
$ grep -rn "from atlas.atlas._ssh" atlas/ scripts/
atlas/atlas/ssh.py:8:from atlas.atlas._ssh.runner import (
atlas/atlas/ssh.py:13:from atlas.atlas._ssh.transport import (
atlas/atlas/tests/test_ssh.py:34: patch("atlas.atlas._ssh.transport.subprocess.run", ...)
```

Plus, `ssh.py` *also* re-exports `SCRIPT_SEARCH_PATHS` and `SCRIPTS_DIRECTORY`
from `scripts_catalog` (lines 21-24) — these have nothing to do with SSH.
The shim is doing two unrelated jobs.

**The Tier-3 split (T3.5) was right to break the 200-line `ssh.py` apart, but
the resulting shim layer is now its own form of clutter.**

**Corrective steps.**

1. **Delete `atlas/atlas/_ssh/__init__.py`** entirely — leave it as an empty
   marker. The package only needs to exist; nothing should import from it.
2. **In `atlas/atlas/ssh.py`, drop the catalog re-exports.** Callers that
   need `SCRIPTS_DIRECTORY` import it from `scripts_catalog` directly. Today
   the only caller is `atlas/atlas/doctype/server/server.py:94`:

   ```python
   # Today
   from atlas.atlas.ssh import SCRIPTS_DIRECTORY  # noqa: PLC0415
   # After
   from atlas.atlas.scripts_catalog import SCRIPTS_DIRECTORY
   ```
3. **Consider promoting `_ssh` from "underscore-prefixed" to a regular
   package** (`atlas.atlas.ssh` becomes a package, not a file). The shim
   exists because `_ssh` looks private and `ssh` doesn't. If `ssh/` is the
   package, `ssh/__init__.py` carries the public API, and `ssh/transport.py`
   / `ssh/runner.py` are the implementation — no shim. Concrete:

   ```
   atlas/atlas/ssh/
   ├── __init__.py          # re-exports (was ssh.py)
   ├── transport.py         # was _ssh/transport.py
   └── runner.py            # was _ssh/runner.py
   ```

   The "from atlas.atlas.ssh import …" call sites don't change. The `_ssh`
   underscore-private package goes away.

---

## H2. `atlas/tests/e2e/_shared.py` is a 72-line re-export shim

**File:** [atlas/tests/e2e/_shared.py](../atlas/tests/e2e/_shared.py)

**Problem.** Per [drift.md T3.6](./drift.md#L546), the e2e helpers were split
into four files (`_config.py`, `_droplets.py`, `_image.py`, `_tasks.py`).
`_shared.py` is kept as a shim "for callers that haven't migrated, including
operator-facing `bench execute` paths."

But every phase file already imports from `_shared`:

```bash
$ grep -h "^from atlas.tests.e2e" atlas/tests/e2e/phase_*.py | sort -u
from atlas.atlas.ssh import Connection, run_task
from atlas.tests.e2e._shared import (
from atlas.tests.e2e._shared import MissingConfig, get_phase1_connection
from atlas.tests.e2e._shared import (
from atlas.tests.e2e._shared import (
from atlas.tests.e2e._shared import (
from atlas.tests.e2e._shared import (
```

Nothing imports from the split files directly. The "migration" never happened,
so the shim is the *only* path. It's not a shim — it's the public surface
under a name that lies about it.

There is also a circular oddity: `atlas/tests/fixtures.py:16` reaches into the
shim to grab `DEFAULT_IMAGE` (`from atlas.tests.e2e._shared import DEFAULT_IMAGE`),
even though `DEFAULT_IMAGE` belongs to `_config.py`. Production fixtures
reaching into an e2e shim is a layering smell.

**Corrective steps.**

1. **Pick one canonical name for the public surface.** Either:
   - **Option A (recommended):** keep `_shared.py` as the public façade, drop
     the misleading "backwards-compatibility" docstring, and accept it as the
     designed entry point. Update the docstring to say so.
   - **Option B:** delete `_shared.py`, migrate every phase to import from
     the four split files directly. Verbose but honest.
2. **Move `DEFAULT_IMAGE` out of e2e.** It's image *content*, not e2e
   harness state. Best home: `atlas/tests/_fixtures_data.py` or just
   `atlas/tests/fixtures.py` itself. Then both `fixtures.py` and
   `_config.py` import from there, and the cross-package reach disappears.

**Example after Option A:**

```python
# atlas/tests/e2e/_shared.py
"""Public surface for the e2e harness.

Helpers are split across _config / _droplets / _image / _tasks for size;
this module is the single import target for phase runners, operator
`bench execute` commands, and unit tests that need image defaults.
"""
# (re-exports unchanged)
```

---

## H3. `Server.run_task_dialog` does three different things in one method

**File:** [atlas/atlas/doctype/server/server.py:52-72](../atlas/atlas/doctype/server/server.py#L52)

**Current:**

```python
@frappe.whitelist()
def run_task_dialog(self, script: str, variables: dict | str | None = None) -> str:
    if isinstance(variables, str):
        variables = json.loads(variables or "{}")
    if variables is None:
        variables = {}
    if not isinstance(variables, dict):
        frappe.throw("variables must be a JSON object")
    if script not in scripts_catalog.allowed_scripts():
        frappe.throw(f"Unknown script: {script}")
    task = run_task(
        server=self.name,
        script=script,
        variables=variables,
        timeout_seconds=1800,
    )
    return task.name
```

**Problem.** Three concerns are interleaved:

1. **Normalize `variables`** (str → dict, None → dict, type-check) — 4 lines
   handling something the *client*, not this controller, should be normalizing.
2. **Authorize the script** — 1 line.
3. **Actually run the task** — 1 call.

The normalization is here because the Frappe JS form passes JSON strings.
But `Task.variables_dict` (the property setter at
[task.py:21](../atlas/atlas/doctype/task/task.py#L21)) already does
JSON-string → dict conversion *and* type-checks. So the controller is doing
its own version of the same work — duplicated logic that has to stay in
sync.

Also `reboot()` proxies through `run_task_dialog` ([server.py:50](../atlas/atlas/doctype/server/server.py#L50))
just to inherit the script whitelist check. But `reboot-server.sh` is
hard-coded in the controller — it's *known good*. Routing it through the
whitelist is theater.

**Corrective steps.**

1. **Make `variables` always a dict at the API boundary**, and let the JS
   form serialize before posting (it can). Drop the str/None handling.
2. **Inline the script-whitelist check** into a one-liner helper, and stop
   piggybacking `reboot()` through `run_task_dialog`.

**After:**

```python
@frappe.whitelist()
def reboot(self) -> str:
    """Run reboot-server.sh. SSH drops mid-Task; Task ends in Failure or
    Success — operator confirms by waiting and reconnecting."""
    return run_task(
        server=self.name,
        script="reboot-server.sh",
        variables={},
    ).name

@frappe.whitelist()
def run_task_dialog(self, script: str, variables: dict) -> str:
    """Operator escape hatch. Picks from the script whitelist."""
    if script not in scripts_catalog.allowed_scripts():
        frappe.throw(f"Unknown script: {script}")
    return run_task(
        server=self.name,
        script=script,
        variables=variables,
        timeout_seconds=1800,
    ).name
```

If the JS form genuinely posts strings (some Frappe versions do), put that
*once* in the form script (`server.js`), not in the controller. Server-side
code is then dict-only and obvious.

---

## H4. `_execute_into` is the longest function in the codebase and braids three responsibilities

**File:** [atlas/atlas/_ssh/runner.py:88-138](../atlas/atlas/_ssh/runner.py#L88) — 51 lines.

**Problem.** Per [Taste.md](../llm/Taste.md) rule 3, functions should be
~10 lines. `_execute_into` is 51 lines and does:

1. Set Task to Running and commit.
2. Run the remote script.
3. Handle timeout, generic exception, success-but-non-zero-exit, and success
   separately — each branch builds its own `_finalize` call.
4. Re-raise with type fixups.

Three almost-identical `_finalize` calls (lines 106-113, 118-125, 132) with
different `stdout/stderr/exit_code/status` tuples is the classic "this
should be a state transition" signal. A reader has to compare three nearly
identical blocks to spot the actual difference.

Plus, the type-fixup at lines 126-128:

```python
if isinstance(exception, frappe.ValidationError):
    raise
raise frappe.ValidationError(str(exception)) from exception
```

…catches a generic `Exception`, re-raises if it's already a `ValidationError`,
otherwise wraps. This is defensive plumbing for a case nobody can
articulate. What is `Exception` here that isn't `TimeoutExpired` (already
caught above) and isn't a `ValidationError`? `ValueError` from
`scripts_catalog.resolve` is `FileNotFoundError`, actually. The catch-all
hides the real exception types.

**Corrective steps.**

1. **Collapse the three `_finalize` shapes into one.** Build a small
   "outcome" tuple/dataclass and finalize once:

   ```python
   def _execute_into(task, connection, script, variables, timeout_seconds):
       _mark_running(task)
       start = time.monotonic()
       outcome = _try_run(connection, script, variables, timeout_seconds)
       _finalize(task, outcome, elapsed_ms=int((time.monotonic() - start) * 1000))
       if outcome.status == "Failure":
           raise frappe.ValidationError(outcome.error_message)

   @dataclasses.dataclass(frozen=True)
   class _Outcome:
       stdout: str
       stderr: str
       exit_code: int | None
       status: str            # "Success" | "Failure"
       error_message: str     # used for the final raise, never persisted

   def _try_run(connection, script, variables, timeout_seconds) -> _Outcome:
       try:
           stdout, stderr, exit_code = _run_remote_script(...)
       except subprocess.TimeoutExpired:
           msg = f"Timed out after {timeout_seconds}s"
           return _Outcome("", msg, None, "Failure", msg)
       except FileNotFoundError as e:
           return _Outcome("", str(e), None, "Failure", str(e))
       if exit_code == 0:
           return _Outcome(stdout, stderr, 0, "Success", "")
       return _Outcome(stdout, stderr, exit_code, "Failure",
                       f"({script}) exited {exit_code}: {stderr[:500]}")
   ```

2. **Drop the `frappe.ValidationError`-vs-Exception type fix-up.** Catch the
   specific exceptions the upstream actually throws (`TimeoutExpired`,
   `FileNotFoundError`). If something else escapes, let it escape — that's a
   bug worth seeing.

3. **The reader benefit:** the three states (Timeout, FileNotFound, exit≠0,
   exit==0) line up vertically as `return _Outcome(...)` rows. The single
   `_finalize` knows how to persist any `_Outcome`. The control flow is
   linear: try → outcome → save → maybe raise.

---

## H5. `VirtualMachine.provision` mixes layers and reads like a flowchart

**File:** [atlas/atlas/doctype/virtual_machine/virtual_machine.py:41-71](../atlas/atlas/doctype/virtual_machine/virtual_machine.py#L41)

**Current:**

```python
@frappe.whitelist()
def provision(self) -> str:
    if self.status not in ("Pending", "Failed"):
        frappe.throw(f"Cannot provision from {self.status}")
    self.status = "Provisioning"
    self.save(ignore_permissions=True)
    frappe.db.commit()
    try:
        task = run_task(
            server=self.server,
            script="provision-vm.sh",
            variables=self._provision_variables(),
            virtual_machine=self.name,
            timeout_seconds=30,
        )
    except Exception:
        self.reload()
        self.status = "Failed"
        self.save(ignore_permissions=True)
        frappe.db.commit()
        raise
    self.reload()
    self.status = "Running"
    self.last_started = frappe.utils.now_datetime()
    self.save(ignore_permissions=True)
    return task.name
```

**Problem.** Same issue as H4 in a different form: state-machine plumbing
(check, save, commit, run, on-fail save+commit, on-success save) drowns the
single domain action. The reader sees seven `self.status = ...` /
`self.save(...)` / `frappe.db.commit()` lines for one logical "provision."

[plan/refactor-layering.md](./refactor-layering.md) already proposed the
solution — three bands of methods (public action, business predicates,
bridges), so `provision()` becomes:

```python
@frappe.whitelist()
def provision(self) -> str:
    self.check_provisionable()
    self.set_status("Provisioning")
    try:
        task = self.run("provision-vm.sh", self.variables(), timeout=30)
    except Exception:
        self.fail()
        raise
    self.started()
    return task.name
```

**Corrective step.** This is already a planned refactor (see
[plan/refactor-layering.md](./refactor-layering.md)). Ship it. The same
shape applies to `start`, `stop`, `delete_vm`, `bootstrap`. Caveat: don't
add bridges for one-shot calls (per Taste rule 8, "reuse" — bridges earn
their keep when called twice or when they remove a context-switch).

---

## H6. Three nearly identical lifecycle methods on `VirtualMachine`

**File:** [atlas/atlas/doctype/virtual_machine/virtual_machine.py:73-130](../atlas/atlas/doctype/virtual_machine/virtual_machine.py#L73)

**Problem.** `start`, `stop`, and `delete_vm` are structurally identical:

```python
def start(self) -> str:
    if self.status != "Stopped":
        frappe.throw(f"Cannot start from {self.status}")
    task = run_task(server=..., script="start-vm.sh", variables={...}, ..., timeout_seconds=30)
    self.reload()
    self.status = "Running"
    self.last_started = frappe.utils.now_datetime()
    self.save(ignore_permissions=True)
    return task.name

def stop(self) -> str:
    if self.status != "Running":
        frappe.throw(f"Cannot stop from {self.status}")
    task = run_task(server=..., script="stop-vm.sh", variables={...}, ..., timeout_seconds=30)
    self.reload()
    self.status = "Stopped"
    self.last_stopped = frappe.utils.now_datetime()
    self.save(ignore_permissions=True)
    return task.name

def delete_vm(self) -> str:
    if self.status == "Archived":
        frappe.throw("VM is already archived")
    task = run_task(server=..., script="delete-vm.sh", variables={...}, ..., timeout_seconds=60)
    self.reload()
    self.status = "Archived"
    self.save(ignore_permissions=True)
    return task.name
```

Per Taste rule 8 ("Reuse. Write as little code as possible"), three near-
duplicates is a smell. The variation is small: precondition, script name,
target status, timestamp field, timeout.

**Corrective step.** Once H5's refactor lands, the duplication disappears
because the bridges (`check_running`, `started`, `stopped`, `run`) are
shared. The public methods become four lines each — no longer "near-
identical 8-line blocks" but "different one-sentence stories using shared
verbs." That's the right kind of reuse.

A heavier alternative — a single `_lifecycle_action(from_status, to_status,
script, ts_field)` — is **not** recommended. It would compress three readable
methods into one parameterized one, but the call sites
(`vm.start()` vs `vm._lifecycle_action("Stopped", "Running", "start-vm.sh",
"last_started")`) get unreadable. Bridges are the right granularity.

---

## H7. `scripts_catalog.py` has two ways to resolve a script and a dead function

**File:** [atlas/atlas/scripts_catalog.py](../atlas/atlas/scripts_catalog.py)

**Problem.** Three resolvers for the same job:

- `allowed_scripts()` — whitelist for the dialog. Lists `.sh` in `SCRIPTS_DIRECTORY`.
- `script_path(script)` — resolves only allowed scripts in `SCRIPTS_DIRECTORY`.
- `resolve(script)` — resolves in either `SCRIPTS_DIRECTORY` *or*
  `E2E_SCRIPTS_DIRECTORY`, no whitelist.

`script_path` is **dead**. Verified:

```bash
$ grep -rn "script_path\b" atlas/
atlas/atlas/scripts_catalog.py:30:def script_path(script: str) -> Path:
```

Only the definition. No callers. The function exists, has its own docstring,
and is at risk of being mistaken for the canonical resolver.

The two-directory search in `resolve()` is also subtle: production scripts
and e2e probe scripts live in the same flat namespace, so a typo in a probe
name could pick up a production script. Acceptable but worth a docstring
note.

**Corrective steps.**

1. **Delete `script_path()`.** It's dead code.
2. **In `resolve()`'s docstring, name the precedence.** "If the same name
   exists in both directories, the production directory wins." (Currently
   true via list order, but undocumented.)
3. **Consider renaming `resolve()` → `script_path()`** after step 1, since
   that's the more domain-correct name. (Optional; only if a reader could
   confuse "resolve" with something async.)

---

# 🟡 MEDIUM severity

## M1. `_ssh_key_file` is named like a function but is a class — confusing

**File:** [atlas/atlas/_ssh/transport.py:122-151](../atlas/atlas/_ssh/transport.py#L122)

**Problem.** Python convention: lowercase-with-underscores is a function,
PascalCase is a class. `_ssh_key_file` is a class, used as a context manager.
The lowercase name reads like a function call:

```python
with _ssh_key_file(connection.ssh_private_key) as key_path:
```

A reader assumes "this is a function that yields" — i.e. a `@contextmanager`-
decorated function — and only on opening the file learns it's a class with
`__enter__`/`__exit__`.

**Corrective steps.**

Convert it to a `@contextlib.contextmanager`-decorated function. The shape
shrinks from 30 lines to ~10:

```python
from contextlib import contextmanager

@contextmanager
def _ssh_key_file(private_key: str) -> Iterator[str]:
    """Write the private key to a 0600 tempfile and delete it on exit."""
    handle = tempfile.NamedTemporaryFile(
        mode="w", delete=False, prefix="atlas-ssh-", suffix=".key"
    )
    try:
        os.chmod(handle.name, 0o600)
        key = private_key if private_key.endswith("\n") else private_key + "\n"
        handle.write(key)
        handle.close()
        yield handle.name
    finally:
        try:
            os.unlink(handle.name)
        except OSError:
            pass
```

No `self.path` field tracking, no separate `__init__/__enter__/__exit__`.
The `with` site is unchanged.

---

## M2. Mixed `frappe.ValidationError` raising patterns — `frappe.throw` vs `raise`

**Files (many):**
- [_ssh/transport.py:46-48](../atlas/atlas/_ssh/transport.py#L46) — `raise frappe.ValidationError(...)`
- [_ssh/transport.py:117-119](../atlas/atlas/_ssh/transport.py#L117) — `raise frappe.ValidationError(...)`
- [_ssh/runner.py:44](../atlas/atlas/_ssh/runner.py#L44) — `frappe.throw(...)`
- [_ssh/runner.py:69](../atlas/atlas/_ssh/runner.py#L69) — `frappe.throw(...)`
- [doctype/server/server.py:26](../atlas/atlas/doctype/server/server.py#L26) — `frappe.throw(...)`
- [networking.py:64](../atlas/atlas/networking.py#L64) — `raise frappe.ValidationError(...)`
- [virtual_machine_image.py:10](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py#L10) — `frappe.throw(...)`

**Problem.** Two ways to raise the same exception type, mixed within a single
file. `frappe.throw(msg)` is the Frappe idiom (translates the message,
captures the user-facing context); `raise frappe.ValidationError(msg)` is the
Python idiom. They produce the same Python exception, but the
operator-visible message ends up styled differently.

Per Taste rule 7 ("Use standard Frappe API as much as possible"), the
Frappe-idiomatic choice is `frappe.throw`. Mixing the two within `_ssh/`
suggests the developer didn't know which to use.

**Corrective steps.**

Pick one rule:

- **Inside DocType controllers and Frappe-aware code:** `frappe.throw(...)`.
- **Inside lower-level transport/IO modules where Frappe might not be loaded
  (e.g. `digitalocean.py`):** raise a domain exception (`DigitalOceanError`,
  not `frappe.ValidationError`). Already true for DO. Apply same rule to
  the SSH layer: define `class SSHError(Exception)` in
  `_ssh/transport.py` and stop importing `frappe` there at all.

This isolates Frappe from a leaf module that doesn't need it, and removes
the mixed-idiom confusion in one move. The Task-finalization layer in
`runner.py` is allowed to import frappe (it has to persist rows); it
catches `SSHError` and translates to `frappe.ValidationError` once at the
boundary.

---

## M3. `wait_for_ssh` uses two timeout mechanisms in parallel

**File:** [atlas/atlas/_ssh/transport.py:36-49](../atlas/atlas/_ssh/transport.py#L36)

**Current:**

```python
def wait_for_ssh(connection, timeout_seconds: int = 300, poll_seconds: int = 5):
    deadline = time.monotonic() + timeout_seconds
    with _ssh_key_file(connection.ssh_private_key) as key_path:
        while True:
            _, _, exit_code = run_ssh(connection, key_path, "true", timeout_seconds=30)
            if exit_code == 0:
                return
            if time.monotonic() >= deadline:
                raise frappe.ValidationError(...)
            time.sleep(poll_seconds)
```

**Problem.** Two timeouts coexist: the outer `timeout_seconds` (deadline
loop) and the per-SSH-call `timeout_seconds=30` (subprocess). If the outer
is 30s and each subprocess takes up to 30s, the actual maximum wall time
is 30 + 5 (poll) ≈ 60s, *not* 30s. The reader has to do this arithmetic
mentally.

**Corrective steps.**

Either:
1. Cap the per-call SSH timeout at `min(30, deadline - now())` so total
   wall-time matches the outer parameter, or
2. Document the relationship inline: `# per-call timeout is 30s; total wall
   time is up to timeout_seconds + 30.`

The first is the right fix. The second is acceptable if the docstring
already promises "best effort."

---

## M4. `connection_for_server` validates fields in a way that surfaces only one error at a time

**File:** [atlas/atlas/_ssh/runner.py:76-85](../atlas/atlas/_ssh/runner.py#L76)

**Current:**

```python
def connection_for_server(server) -> Connection:
    from atlas.atlas.secrets import get_secret
    if not server.ipv4_address:
        frappe.throw(f"Server {server.name} has no ipv4_address; cannot SSH")
    if not server.provider:
        frappe.throw(f"Server {server.name} has no provider; cannot SSH")
    private_key = get_secret("Server Provider", server.provider, "ssh_private_key")
    return Connection(host=server.ipv4_address, ssh_private_key=private_key)
```

**Problem.** Two minor things:

1. `server` is untyped. The parameter is a Frappe `Document` (a `Server`),
   but the reader has to guess. Add `server: Document` (or `"Server"` if a
   forward ref is needed).
2. The two error messages are nearly identical templates — small smell, fine
   to leave.
3. **Inline import of `get_secret`** at the function top. Frappe sometimes
   needs lazy imports to avoid circular-import issues, but `secrets.py` has
   no Frappe-doctype dependencies; this can be a top-of-file import.

**Corrective steps.**

```python
from atlas.atlas.secrets import get_secret
from frappe.model.document import Document  # already imported elsewhere

def connection_for_server(server: Document) -> Connection:
    if not server.ipv4_address:
        frappe.throw(f"Server {server.name} has no ipv4_address; cannot SSH")
    if not server.provider:
        frappe.throw(f"Server {server.name} has no provider; cannot SSH")
    return Connection(
        host=server.ipv4_address,
        ssh_private_key=get_secret("Server Provider", server.provider, "ssh_private_key"),
    )
```

Three line types added (top-of-file import, type annotation, no-temp
return). Loses nothing.

---

## M5. `Task.validate` calls a property for its side effect

**File:** [atlas/atlas/doctype/task/task.py:26-30](../atlas/atlas/doctype/task/task.py#L26)

**Current:**

```python
def validate(self) -> None:
    if not self.variables:
        frappe.throw("variables is required")
    self.variables_dict
    self._validate_immutability()
```

**Problem.** `self.variables_dict` is a property getter. The expression on
its own line is there to trigger the property's JSON-parse + type-check,
which `frappe.throw`s on bad input. To a reader unfamiliar with the
codebase, it looks like a statement with no effect — Python lint tools
flag this as an unused expression.

**Corrective step.**

Rename the validation-only path into a method, *or* make the side effect
explicit:

```python
def validate(self) -> None:
    if not self.variables:
        frappe.throw("variables is required")
    _ = self.variables_dict          # parse-validate; raises on bad JSON
    self._validate_immutability()
```

The `_ = ...` assignment signals "we want this value, even though we throw
it away," and silences the unused-expression warning. Better still:

```python
def validate(self) -> None:
    self._validate_variables_json()
    self._validate_immutability()

def _validate_variables_json(self) -> None:
    if not self.variables:
        frappe.throw("variables is required")
    self.variables_dict  # property raises on bad JSON
```

Now the property access has a *named* caller; the comment carries the
"this throws" contract.

---

## M6. `Server._absorb_bootstrap_output` is fine; the regex is over-engineered

**File:** [atlas/atlas/doctype/server/server.py:18, 79-90](../atlas/atlas/doctype/server/server.py#L79)

**Current:**

```python
KEY_VALUE_LINE = re.compile(r"^([A-Z][A-Z0-9_]*)=(.+)$")

def _absorb_bootstrap_output(self, stdout: str) -> None:
    fields = {"FIRECRACKER_VERSION": "firecracker_version",
              "KERNEL_VERSION": "kernel_version",
              "ARCHITECTURE": "architecture"}
    for line in stdout.splitlines():
        match = KEY_VALUE_LINE.match(line.strip())
        if not match:
            continue
        key, value = match.group(1), match.group(2).strip()
        fieldname = fields.get(key)
        if fieldname:
            setattr(self, fieldname, value)
```

**Problem.** The regex matches *any* `K=V` line where K is an uppercase
identifier — wider than needed. Bootstrap output only emits three specific
keys. The wider regex makes the reader wonder if there's a fourth key we
might pick up incidentally, and the dict-of-known-keys exists to narrow it.
Two filtering layers for one job.

Additionally `[A-Z][A-Z0-9_]*` is technically more permissive than the
shell script's emitted keys (`FIRECRACKER_VERSION`, `KERNEL_VERSION`,
`ARCHITECTURE`) — yet there's no test for "another K=V format we ignore."

**Corrective step.**

Just check for the known prefix per line. Five lines, no regex:

```python
def _absorb_bootstrap_output(self, stdout: str) -> None:
    fields = {
        "FIRECRACKER_VERSION=": "firecracker_version",
        "KERNEL_VERSION=":      "kernel_version",
        "ARCHITECTURE=":        "architecture",
    }
    for line in stdout.splitlines():
        line = line.strip()
        for prefix, fieldname in fields.items():
            if line.startswith(prefix):
                setattr(self, fieldname, line[len(prefix):].strip())
                break
```

Same behavior, no module-level regex, no `match.group(1)/group(2)` shuffle.
Module-level `KEY_VALUE_LINE` constant goes away.

---

## M7. `_provision_variables` constructs an 11-key dict inline

**File:** [atlas/atlas/doctype/virtual_machine/virtual_machine.py:132-146](../atlas/atlas/doctype/virtual_machine/virtual_machine.py#L132)

**Problem.** Eleven items in a builder, each cast as a string explicitly
(`str(self.vcpus)`, `str(self.memory_megabytes)`, `str(self.disk_gigabytes)`).
This is fine — it makes the script contract obvious — but it's right at
the line-count limit (Taste rule 4: 10-line ideal).

Not actively a problem; calling it out so future-you doesn't grow this to
20 keys before refactoring.

**Corrective step.** (Optional.) If a fourth or fifth script joins (each
with its own variables dict), promote to a method-per-script of an
extracted `_ScriptInputs` mixin. Until then, leave it. Premature.

---

## M8. `ensure_bootstrapped_server` returns a tuple that callers partially ignore

**File:** [atlas/tests/e2e/_droplets.py:92-140](../atlas/tests/e2e/_droplets.py#L92)

**Current:**

```python
def ensure_bootstrapped_server(reuse=True, keep=False) -> tuple[Document, DigitalOceanClient, bool]:
    """..."""
    _ = keep  # callers gate their own teardown on this; recorded for symmetry
    ...
```

The `keep` parameter is accepted, *immediately discarded*, and the docstring
admits it. This is dead-on-arrival argument — every call site that passes
`keep=True` is being lied to. The `phase()` context manager
([_droplets.py:170](../atlas/tests/e2e/_droplets.py#L170)) does its own
`keep` gating downstream, so the helper does not actually need the
parameter.

The "for symmetry" comment is a tell that the parameter exists to satisfy
a caller's idea of the API, not to do work.

**Corrective step.**

1. **Drop the `keep` parameter** from `ensure_bootstrapped_server`.
   Update `phase()` (the only caller) accordingly.
2. **Drop the `_ = keep` and the explanatory comment.**

```python
def ensure_bootstrapped_server(reuse: bool = True) -> tuple[Document, DigitalOceanClient, bool]:
    client = get_client()
    ...

@contextmanager
def phase(label: str, reuse: bool = True, keep: bool = True):
    start_clock = time.monotonic()
    server, client, created_now = ensure_bootstrapped_server(reuse=reuse)
    ...
```

Caller intent for `keep` is preserved (gates the `finally` cleanup);
`ensure_bootstrapped_server` is just no longer asked about it.

---

## M9. `phase_1.run()` repeats the start-clock/traceback/format dance that `phase()` already encapsulates

**File:** [atlas/tests/e2e/phase_1.py:12-31](../atlas/tests/e2e/phase_1.py#L12)
vs [atlas/tests/e2e/_droplets.py:161-185](../atlas/tests/e2e/_droplets.py#L161)

**Problem.** Phase 1 reproduces the harness from `phase()` by hand —
`start_clock`, `traceback.print_exc()`, the OK/FAIL formatting — because
`phase()` runs `ensure_bootstrapped_server`, which doesn't apply to phase 1
(operator-provided droplet via site config).

Same pattern in `phase_2.py:15-45` and `phase_3.py:18-53`. Three phases
duplicate the timing/formatting/traceback boilerplate; only phases 4–7 use
`phase()`.

Per Taste rule 8 (reuse), this is reuse opportunity left on the floor.

**Corrective step.**

Split `phase()` into two layers:

```python
@contextmanager
def reported(label: str):
    """Time + OK/FAIL summary + traceback. No droplet management."""
    start_clock = time.monotonic()
    try:
        yield
    except Exception:
        elapsed = time.monotonic() - start_clock
        print(f"{label}: FAIL in {elapsed:.0f}s")
        traceback.print_exc()
        raise
    else:
        elapsed = time.monotonic() - start_clock
        print(f"{label}: OK in {elapsed:.0f}s")

@contextmanager
def phase(label: str, reuse=True, keep=True):
    """As before, but built on `reported`."""
    with reported(label):
        server, client, created_now = ensure_bootstrapped_server(reuse=reuse)
        sweep_old_droplets(client)
        try:
            yield server
        finally:
            if created_now and not keep and server.provider_resource_id:
                cleanup_droplet(client, int(server.provider_resource_id))
```

Phase 1's `run()` becomes:

```python
def run() -> None:
    with reported("phase-1"):
        connection = get_phase1_connection()
        _check_happy_path(connection)
        _check_failure(connection)
        _check_missing_script(connection)
```

Phases 2 and 3 collapse similarly. Three boilerplate blocks gone.

---

## M10. `phase()` context manager mixes happy-path printing with failure printing

**File:** [atlas/tests/e2e/_droplets.py:161-185](../atlas/tests/e2e/_droplets.py#L161)

**Current shape** has `try/except/else/finally` with print statements in
both the `except` and `else` branches plus a cleanup in `finally`. Reads
fine but is on the edge of being too clever:

```python
try:
    yield server
except Exception:
    elapsed = time.monotonic() - start_clock
    print(f"{label}: FAIL in {elapsed:.0f}s")
    traceback.print_exc()
    raise
else:
    elapsed = time.monotonic() - start_clock
    print(f"{label}: OK in {elapsed:.0f}s")
finally:
    if created_now and not keep and server.provider_resource_id:
        cleanup_droplet(client, int(server.provider_resource_id))
```

The `elapsed = ...` line appears twice. Hoist it:

```python
try:
    yield server
    outcome = "OK"
except Exception:
    outcome = "FAIL"
    traceback.print_exc()
    raise
finally:
    elapsed = time.monotonic() - start_clock
    print(f"{label}: {outcome} in {elapsed:.0f}s")
    if created_now and not keep and server.provider_resource_id:
        cleanup_droplet(client, int(server.provider_resource_id))
```

Subtle catch: setting `outcome = "OK"` *after* the yield only runs if
nothing was raised, and `finally` always runs. This is the same control
flow with one fewer copy of the elapsed-print.

---

## M11. `digitalocean.py::_request` accepts `allow_404=True` only at one call site

**File:** [atlas/atlas/digitalocean.py:75-105](../atlas/atlas/digitalocean.py#L75)

**Current:**

```python
def delete_droplet(self, droplet_id: int) -> None:
    self._request("DELETE", f"/droplets/{droplet_id}", allow_404=True)

def _request(self, method, path, json=None, allow_404=False):
    ...
    if response.status_code == 404 and allow_404:
        return {}
    ...
```

**Problem.** `allow_404` is a public-ish parameter on `_request` (one of two
optional kwargs) used at exactly one call site. It's a feature-flag
parameter — clutter on the shared method to support one special case.

**Corrective step.**

Inline it at the only caller:

```python
def delete_droplet(self, droplet_id: int) -> None:
    response = self._raw_request("DELETE", f"/droplets/{droplet_id}")
    if response.status_code == 404:
        return
    self._raise_for_status(response)

def _request(self, method, path, json=None):
    response = self._raw_request(method, path, json=json)
    self._raise_for_status(response)
    if response.status_code == 204 or not response.content:
        return {}
    return response.json()
```

This is heavier — adds a `_raw_request` and `_raise_for_status` — so only
worth it if a second special case shows up. **For now, leaving `allow_404`
in place is fine.** Calling it out as a smell to watch: every additional
boolean param to `_request` makes this fork more.

---

## M12. `derive_tap` has a comment explaining a constant that the constant doesn't explain

**File:** [atlas/atlas/networking.py:29-36](../atlas/atlas/networking.py#L29)

**Current:**

```python
def derive_tap(virtual_machine_name: str) -> str:
    """atlas-<first 9 hex chars of UUID>. Length 15, IFNAMSIZ-safe.

    Linux IFNAMSIZ is 16 bytes including the null terminator, so 15 chars
    is the real max usable length. `atlas-` (6) + 9 hex = 15.
    """
    hex_only = uuid.UUID(virtual_machine_name).hex
    return f"atlas-{hex_only[:9]}"
```

**Problem.** The function is 2 lines of code and 4 lines of docstring. That
ratio is fine (it's a domain-non-obvious constraint), but the *magic numbers*
(`6`, `9`, `15`, `16`) live in the docstring rather than the code:

```python
TAP_PREFIX = "atlas-"
TAP_HEX_CHARS = 9        # IFNAMSIZ is 16 bytes incl NUL → 15 usable; len("atlas-") = 6

def derive_tap(virtual_machine_name: str) -> str:
    return TAP_PREFIX + uuid.UUID(virtual_machine_name).hex[:TAP_HEX_CHARS]
```

Now a maintainer changing the prefix to `"atlasvm-"` instantly sees the
budget. Today they'd have to read the docstring to recompute.

This is a **Taste rule 6 win** (no comment when a name says it).

**Corrective step.** Hoist the constants. Drop the docstring's arithmetic
to a single sentence: *"Linux interface names cap at 15 chars (IFNAMSIZ
minus NUL)."*

---

# 🟢 LOW severity

## L1. `IMMUTABLE_AFTER_INSERT` lives in two places with no shared definition

**Files:**
- [task.py:6](../atlas/atlas/doctype/task/task.py#L6) — `IMMUTABLE_AFTER_INSERT = (...)`
- [virtual_machine.py:9](../atlas/atlas/doctype/virtual_machine/virtual_machine.py#L9) — same constant name, different fields

**Note.** This is fine — each DocType has its own set. The shared name is
slightly noisy because a reader grepping for "immutable" sees two unrelated
declarations. Leave it.

---

## L2. `sync_to_server` builds the variables dict inline; `_provision_variables` is extracted

**File:** [virtual_machine_image.py:21-33](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py#L21)

**Note.** `Server.bootstrap()` builds its 2-key variables dict inline.
`Image.sync_to_server()` builds a 9-key dict inline. `VM.provision()` extracts
its 11-key dict to `_provision_variables()`. The cut-off is arbitrary —
make it consistent (probably extract any dict >= 5 keys). Low priority.

---

## L3. Magic-number timeouts scattered

**Files:**
- `run_task(..., timeout_seconds=1800)` — default
- `run_task(..., timeout_seconds=30)` for VM scripts
- `run_task(..., timeout_seconds=60)` for delete-vm
- `run_task(..., timeout_seconds=15)` for probes
- `run_task(..., timeout_seconds=300)` for SCP

**Note.** A constants module (`TIMEOUTS.SHORT_VM_OPERATION = 30`,
`TIMEOUTS.LONG_SYNC = 1800`) would make these grepable. **Don't add yet** —
five sites, five different reasons, no convergence pressure. Note for
when a sixth caller wants 30s.

---

## L4. `frappe.session.user if frappe.session else "Administrator"` repeated twice

**Files:**
- [_ssh/runner.py:56](../atlas/atlas/_ssh/runner.py#L56)
- [virtual_machine_image.py:39](../atlas/atlas/doctype/virtual_machine_image/virtual_machine_image.py#L39)

**Note.** Two call sites for `session_user_or_administrator()`. Worth a
shared one-liner *only* if a third site appears. For now, the inline form
is cheaper to read than the indirection.

---

## L5. `# noqa: PLC0415` annotations on lazy imports

**Files (many):**
- [server.py:28, 94](../atlas/atlas/doctype/server/server.py#L28)
- [server_provider.py:20](../atlas/atlas/doctype/server_provider/server_provider.py#L20)
- [networking.py:45](../atlas/atlas/networking.py#L45)
- [digitalocean.py:129](../atlas/atlas/digitalocean.py#L129)

**Note.** Several `# noqa: PLC0415` (function-level import) annotations.
PLC0415 catches imports moved inside functions — usually for circular-
import reasons. Some of these have valid reasons (circular imports
between server / ssh / secrets); some don't (`digitalocean.py:129`'s
`import ipaddress` inside `_network_cidr` is gratuitous).

**Corrective step.** Audit each `noqa: PLC0415` and hoist where possible.
For genuine circulars, prefer a structural fix (move the function) over
the noqa. Low priority because the noqa is at least flagged.

---

## L6. `_load_key` in `_config.py` accepts inline-PEM-or-path, then `get_ssh_private_key` calls it but `get_phase1_connection` also calls it

**File:** [atlas/tests/e2e/_config.py:36, 51-58, 78-82](../atlas/tests/e2e/_config.py#L36)

**Note.** Two readers of the same config field both call `_load_key`. If
the field can be either inline PEM or a path, that's a config-shape
decision — pick one form and require it. The auto-detect inside `_load_key`
is friendly but adds branches the reader has to think about.

Low priority because this is operator-config UX, not hot-path code.

---

## L7. `_inspect.py::dump_recent_tasks` prints the bare list before iterating

**File:** [atlas/tests/e2e/_inspect.py:21](../atlas/tests/e2e/_inspect.py#L21)

**Current:**

```python
tasks = frappe.get_all(...)
print(tasks)
for record in tasks:
    _print_task(record.name)
```

The `print(tasks)` at line 21 dumps the unformatted list of dicts; then
each task is printed nicely. Either the operator wants the raw list
*or* the formatted one. Two outputs back-to-back is confusing. **Drop the
bare `print(tasks)`.**

---

# Summary

| Severity | Count | Theme |
|---|---|---|
| 🔴 High    | 7 | Shim layers, long methods, duplicated DocType lifecycles |
| 🟡 Medium  | 12 | API hygiene, raising idioms, sub-pattern dedup |
| 🟢 Low     | 7 | Stylistic / leave-alone-but-watch |

**Top 3 to fix this week:**

1. **H1 + H2:** Collapse the SSH and e2e shim chains. Two unrelated
   re-export shims is one too many; together they confuse every new reader.
   ~1h of mechanical work.
2. **H4 + H5:** Land the layered-DocType refactor for `VirtualMachine`
   ([plan/refactor-layering.md](./refactor-layering.md)) plus the
   `_Outcome` dataclass for `_execute_into`. These are the two longest
   functions in the codebase. ~3h.
3. **H7:** Delete dead `script_path()`. ~5 min.

Everything else is opportunistic — touch when you're already in the file.

The codebase is generally clean — `Taste.md` is followed in spirit, file
sizes are under the 300-line cap, abbreviations are spelled out. The
high-severity items are all consequences of *successful* refactors
([drift.md T3.5, T3.6](./drift.md#L538)) that left a shim layer behind. The
refactors were the right calls; the shims should now retire.
