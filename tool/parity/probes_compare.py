"""Compare one probe transcript (core) with the oracle's, under a row's rule.

Events are compared in order and in full, after:
  - `norm` from score.py (uuids, hidden keys, float display text);
  - a `refused` event compares as a refusal, not by the host's error text
    (each binding words its own refusal);
  - the row's named exceptions: `ignore_keys` drops those event keys on both
    sides before comparing (e.g. `position`, when core exposes none).
"""

from __future__ import annotations

from score import norm


def _events(doc: dict, ignore: set[str]) -> list[dict]:
    out = []
    for e in doc.get('events') or []:
        e = dict(e)
        if e.get('ev') == 'refused':
            e = {'ev': 'refused'}
        out.append(norm({k: v for k, v in e.items() if k not in ignore}))
    return out


def judge(pid: str, ref: dict | None, got: dict | None, rule: dict) -> tuple[str, list[str], list[str]]:
    """-> (class, what differs, names of the exceptions that changed the verdict)."""
    if got is None or got.get('runner_error'):
        return 'NO-OUTCOME', ['!'], []
    if rule.get('refusal') and any(e.get('ev') == 'refused' for e in got.get('events') or []):
        return 'REFUSED', [], []
    if ref is None or ref.get('runner_error'):
        return 'NO-ORACLE', ['?'], []
    ignore: set[str] = set()
    applied = []
    for ex in rule.get('exceptions', []):
        if ex.get('probe') not in (None, pid):
            continue
        keys = set(ex['ignore_keys'])
        if _events(ref, ignore) != _events(got, ignore) and _events(ref, ignore | keys) != _events(ref, ignore):
            ignore |= keys
            applied.append(ex['name'])
    r, g = _events(ref, ignore), _events(got, ignore)
    if r == g:
        return 'MATCH', [], applied
    why = [f'events differ at #{i}' for i, (a, b) in enumerate(zip(r, g)) if a != b][:1] or [f'{len(r)} vs {len(g)} events']
    return 'DIVERGE', why, applied
