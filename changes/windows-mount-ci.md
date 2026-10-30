### Internal

- New CI job `test-worker-windows` (`windows-2025`) builds the worker and mount library and runs `test/integration/worker/mount_windows_io_test.dart`: junction, file-symlink, `\..\`, drive-letter, rename-out, reserved-device-name and trailing-dot/space cases against a host `MountDir` in all three modes, held to a test-count floor. It is the first job that runs tests on Windows.
