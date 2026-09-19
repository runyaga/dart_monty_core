"""E3 comparison — Dart outcomes against the pydantic-monty control.

Reads CAP:{...} lines (from the Dart capability matrix) and CTL:{...} lines
(from e3_control.py) on stdin, in either order, and prints one verdict per
(case, entry point, backend).

THE VERDICT VOCABULARY IS DELIBERATELY THREE-VALUED. An experiment that cannot
return "inconclusive" is not an experiment:

  match       Dart and the control both raised, or both returned.
  DIVERGES    one raised and the other returned. This is the finding.
  REFUSED     Dart threw a capability refusal (UnsupportedError) instead of
              executing, so the cell says nothing about the behaviour under
              test -- only that the wrong entry point was used for that
              backend. Measured: on web, `Monty.exec(limits:)` refuses via
              core#140, and scoring that as agreement with a control that
              raised would be a FALSE MATCH.
  no-control  the control has no comparable cell, so nothing is concluded.

Exit status is always 0. This reports; it does not gate. A comparison that
fails the build on its first divergence stops producing the inventory that
makes the divergence interpretable.
"""

import json
import sys

# The control either raises or it does not; Dart either throws or it does not.
# Everything else about the two taxonomies is incomparable, so the comparison
# is deliberately coarse.
RAISED = {"raised", "threw"}


def main():
    cap, ctl = [], {}
    for line in sys.stdin:
        line = line.strip()
        if line.startswith("CAP:"):
            cap.append(json.loads(line[4:]))
        elif line.startswith("CTL:"):
            row = json.loads(line[4:])
            ctl[row["case"]] = row

    if not cap or not ctl:
        print("REFUSING: need both CAP: and CTL: lines "
              f"(got {len(cap)} / {len(ctl)}).")
        print("  A comparison with one side missing would print all-match.")
        return 1

    print(f"{'case':9} {'entry':14} {'backend':16} "
          f"{'dart':16} {'control':10} verdict")
    print("-" * 86)
    for row in cap:
        control = ctl.get(row["case"])
        if control is None or row["entry"] == "n/a":
            verdict = "no-control"
        elif row["detail"].startswith("UnsupportedError"):
            verdict = "REFUSED"
        else:
            both_raise = (row["outcome"] in RAISED) == (
                control["outcome"] in RAISED)
            verdict = "match" if both_raise else "DIVERGES"
        print(f"{row['case']:9} {row['entry']:14} {row['backend']:16} "
              f"{row['outcome']:16} "
              f"{(control or {}).get('outcome', '-'):10} {verdict}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
