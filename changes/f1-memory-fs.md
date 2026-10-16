### Breaking

- Replace the mounted memory filesystem with upstream's callable `OSAccess`.
  Pass it to `os:` on feeds; seed files with `String` or `Uint8List` content.
  It serves the entire virtual namespace and exposes created files through
  `files`. Files retain mutable permissions; callback reads and writes are
  settable. Names remain final and deletion is observable through a getter.
- Match upstream path normalization, binary open seeds, stat permissions and
  timestamps, Unicode write counts, and filesystem error messages. File rename
  preserves upstream's stale-path/unlink quirk; callback paths remain fixed at
  construction, including writes after directory renames.
- Migration table (old name → new name):

| Old name | New name / replacement |
| --- | --- |
| `memoryMountedOsHandler` | `OSAccess` |
| `MontyMemoryFile` | `MemoryFile` |
| `MontyMemoryFile.withContent` | `MemoryFile(path, content)` |
| `VfsFile` | `AbstractFile` (`readContent`, `writeContent`, `delete`) |
| `VfsCallbackFile` | `CallbackFile` in `unsafe_callback_file.dart` |
| `VfsReadCallback` | Inline `Object Function(String)` |
| `VfsWriteCallback` | Inline `void Function(String, Object)` |
| `VfsCallbackFile.content` | `readContent()` / `writeContent(content)` |
| `VfsCallbackFile.seededPath` | Private construction path; no public replacement |
| `VfsContent`, `VfsText`, `VfsBytes` | `Object`: `String` or `Uint8List` |
| `MountDir` (memory-backed) | Removed; host-directory mounts follow in F-2 |
| `MountMode` | Removed with memory mount policy |
| `resolveOpenCall` | Private implementation inside `OSAccess` |
| `mounts`, `fallthrough` | Whole namespace; compose handlers explicitly |
| Memory `writeBytesLimit`, `memoryUsageLimit`, read-only mounts | Sandbox policy moves to dm |
| Custom stat tuple construction | `StatResult.fileStat` / `StatResult.dirStat` |

- Delete the internal VFS tree, path, accounting and limit types. The main
  library has 65 exported names in the F-1 window; the unsafe library has one.
  `PARITY_PIN` remains unchanged for the separate pin PR required after F-1.
