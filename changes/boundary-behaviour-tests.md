### Internal

- Session boundary tests on the VM, dart2js and dart2wasm pin outcomes recorded from upstream 1.1.0: aggregate and input memory limits, feed and turn limits, the type-check deadline, restore of dumps of another version and of modified bytes, the limits a dump carries, and the paths an OS handler receives. `tool/check_worker_wasm_layout.py` checks that the worker module places its stack first.
