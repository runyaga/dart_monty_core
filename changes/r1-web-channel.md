### Fixed

- Browser workers deliver prints as they flush, await print callbacks before completing a turn, and apply a 4 MiB acknowledgement window when JSPI is available.
- Browser memory limits no longer charge request frames during execution or retain a turn's printed output in wasm memory. Hard allocator breaches now report `MemoryError`, as on native workers.
