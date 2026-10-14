### Internal

- The worker-channel test "a descendant writing after the worker exits stays
  bounded" no longer times out on a loaded machine. Its fake worker exited
  after a fixed 2 s, so a descendant slower to start than that plus the drain
  grace had written nothing when the drain ended, and the test waited for a
  read-ahead that could not arrive. The fake worker now exits only once the
  descendant has written 3 MiB, and the descendant starts late on
  purpose so the test covers the slow case every run. The channel itself is
  unchanged.
