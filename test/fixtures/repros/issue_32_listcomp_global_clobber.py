# Repro: dart_monty_core#32
#   MontyRepl: host function global binding clobbered to int after
#   repeat list-comprehension calls.
#
# https://github.com/runyaga/dart_monty_core/issues/32
#
# Symptom
# -------
# When a function registered as an `externalFunction` on `MontyRepl` is
# invoked from a list comprehension across two or more consecutive
# `feedRun` calls, the function's global binding is replaced by an int
# (apparently the comprehension's length / final iteration value).
# Subsequent calls raise `TypeError: 'int' object is not callable`.
#
# Sibling externals (e.g. `delay_fn`, `http_fn`) are not affected — only
# the name actually called inside the list comp gets clobbered.
#
# Workarounds that work today
# ---------------------------
#   - Use `for ... : results.append(sync_fn())` instead of a list comp.
#   - Separate the two list-comp `feedRun`s with any other `feedRun`.
#   - Use direct calls (`x = sync_fn()`) instead of comprehensions.
#
# Side-loading against the reference implementation
# -------------------------------------------------
# This file is directly runnable Python. Under CPython or pydantic-monty,
# `sync_fn` remains a function across all three feeds and the final line
# prints `function`:
#
#   $ python3 test/fixtures/repros/issue_32_listcomp_global_clobber.py
#   function
#
# Under dart_monty_core (current behavior), the equivalent feed sequence
# (replayed by issue_32_listcomp_global_clobber_ffi_test.dart) makes the
# final probe see `int`, and any subsequent `sync_fn()` call raises
# `TypeError: 'int' object is not callable`.

# === EXTERNALS (reference impl) ===
# The Dart-side test registers `sync_fn` via externalFunctions: (...).
# Defined inline here so this file is directly runnable for cross-check.
def sync_fn():
    return 'sync_ok'


# === FEED 1 ===
# First list-comp call — establishes the bug condition.
results = [sync_fn() for _ in range(10)]


# === FEED 2 ===
# Second list-comp call — bug triggers here on dart_monty_core.
results = [sync_fn() for _ in range(5)]


# === FEED 3 ===
# Probe: type of sync_fn after the bug fires.
#
# Reference impl (this file under CPython):  function
# dart_monty_core (issue #32, observed):     int
print(type(sync_fn).__name__)
