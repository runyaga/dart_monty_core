### Internal

- Web worker tests state per-browser expectations: tests of the JSPI dispatch skip in a browser that has no JSPI (Chromium still must have it), the wasm-trap text accepts JavaScriptCore's wording, and Safari has its own measured recursion-set outcomes.
