### Internal

- Rename the spec tests by subject and drop their requirement ids from test names: the codec, value, channel and mount tests lose the `spec_` prefix and `REQ-` ids, and the launch-selection tests join `worker_locator_test.dart`. Test count and behaviour are unchanged.
