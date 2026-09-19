import json, time, inspect
import pydantic_monty as m
print("feed_run sig:", inspect.signature(m.MontySession.feed_run))

CODE = "while True:\n    ping()"

def probe(label, limits):
    calls = 0
    def ping(*a, **k):
        nonlocal calls
        calls += 1
        return None
    t0 = time.monotonic()
    try:
        with m.Monty() as mt:
            with mt.checkout(limits=limits) as s:
                r = s.feed_run(CODE, external_lookup={"ping": ping})
                out = f"returned {type(r).__name__}"
    except BaseException as e:
        out = f"raised {type(e).__name__}: {e}"
    ms = (time.monotonic() - t0) * 1000
    print("E4CTL:" + json.dumps(
        {"limits": label, "calls": calls, "ms": round(ms), "outcome": out[:100]}))

probe("NO limits at all", None)
probe("duration 0.5s only", {"max_duration_secs": 0.5})
probe("max_suspensions 50", {"max_suspensions": 50})
probe("max_suspensions 100000", {"max_suspensions": 100000})
