### Changed

- Upgraded to upstream pydantic/monty 1.3.0 (the `v1.3.0` tag): the worker,
  the pinned corpus and the pinned upstream references in this package now
  name that release. The worker protocol stays at version 6, so the driver
  and the pinned worker still agree on it.
- Python's `functools` gains `lru_cache` and `cache`, which 1.2.0 did not
  have at all. The type of a cached function reaches the host as the builtin
  type proxy named `functools._lru_cache_wrapper`, so
  `type(functools.cache(f))` answers with that type name instead of raising
  `AttributeError`.
- A type-checked feed whose source is nested past the parser's nesting limit
  is rejected at once, as a syntax error (`Source is too deeply nested`).
  On 1.2.0 the type check walked the deep AST instead, so the feed ran into
  its deadline and the worker was killed after the limit and its grace.
- A user `__iter__` or `__next__` method may suspend: a direct `iter()`, a
  `next()` (with or without a default) and `functools.reduce()` suspend for a
  host call inside such a method, where 1.2.0 raised `NotImplementedError`.
- The pinned upstream corpus grows to 703 cases, from the 695 the 1.2.0 pin
  recorded: the corpus the worker runs, and the scorecard the corpus jobs
  print, now name 703.
- A session dump may only tighten the ceilings of the session that loads it,
  so a dump can no longer downgrade them: the dump's resource limits and the
  loader's are tightened into the stricter of the two, and the loader's feed
  and turn duration limits are not forgotten on a restore. A dump of another
  format version is refused rather than downgraded into a restore, and the
  refusal names the limit: `dump format version 12 is older than 13`.
