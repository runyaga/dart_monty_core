### Fixed

- The Linux worker executable and `libdart_monty_worker.so` link the GCC
  unwinder statically and no longer need `libgcc_s.so.1`. They load on images
  that carry only the Dart image's `/runtime/`, such as Serverpod 4's Alpine
  template, where every checkout failed with "the worker library ... exists
  but cannot be loaded".
