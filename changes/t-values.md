### Internal

- 102 requirement tests for the value family (`test/unit/platform/spec_values_*_test.dart`): toString formats, equality and hash fields, `fromDart` identity and refusals, cycle refusals, the 400-level and 2^22-visit budget, and dart2js integral-double dispatch. The unit floors in CI are raised to 2690 (VM) and 5350 (web).
