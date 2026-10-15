### Internal

- The `spec_values_*` tests pass DCM again (the local `tool/dcm_ratchet.sh` gate): locals replace repeated constructions, list destructuring replaces indexed access and `.single`, and a small `spec_values_support.dart` holds two helpers. The tests assert exactly what they did before.
