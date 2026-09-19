"""E3 control side — the same reproducers through pydantic-monty.

WHY A PYTHON SCRIPT IS THE YARDSTICK. pydantic-monty binds the SAME Rust
engine this package binds, at the same tag (native/Cargo.toml: monty
tag = "v0.0.23"; pydantic-monty 0.0.23). Different binding language, identical
engine. So when the two disagree, the engine is not the variable.

WHAT IT MAY AND MAY NOT BE USED FOR. Typed outcomes only: did the binding
RAISE, or did it RETURN an error object? Never timings -- Python's elapsed
time contains Python's own binding cost, and subtracting it from Dart's
isolates nothing.

Run:  <venv>/bin/python tool/control/e3_control.py
Emits one CTL:{...} line per case, for tool/control/compare.py.
"""

import json

import pydantic_monty as m

# Mirrors test/integration/_capability_matrix_body.dart exactly. If one side
# changes a reproducer, the comparison stops meaning anything, so they are
# written to be diffed by eye.
CASES = [
    ("syntax", "def (", None),
    ("timeout", "while True: pass", {"max_duration_secs": 0.15}),
    ("memory", "x = [0] * (10**8)", {"max_memory": 1024 * 1024}),
]


def probe(case_id, code, limits):
    try:
        with m.Monty() as mt:
            with mt.checkout(limits=limits) as session:
                result = session.feed_run(code)
                # Reaching here at all is the finding: the binding did not
                # raise. Whether the result carries an error is secondary.
                err = getattr(result, "error", None)
                return {
                    "case": case_id,
                    "outcome": "returned-error" if err else "returned-ok",
                    "detail": f"{type(result).__name__}: {err or result}"[:110],
                }
    except BaseException as exc:  # noqa: BLE001 — classifying, not handling
        return {
            "case": case_id,
            "outcome": "raised",
            "detail": f"{type(exc).__name__}: {exc}"[:110],
        }


def main():
    for case_id, code, limits in CASES:
        print("CTL:" + json.dumps(probe(case_id, code, limits)))


if __name__ == "__main__":
    main()
