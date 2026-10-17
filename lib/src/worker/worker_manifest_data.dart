/// Provides the manifest bundled with this package.
library;

import 'package:dart_monty_core/src/worker/worker_manifest.dart';

/// The manifest of the worker release assets this package version installs.
///
/// An empty `targets` map means no prebuilt worker is published.
const workerManifestJson =
    '{"schema":1,"version":"v0.110.0-dev.3","targets":{"linux-arm64":{"work'
    'er":{"file":"dart_monty_worker","bytes":23213464,"sha256":"58c350f104f'
    'f02d7daa18284f6e84173a18fe28c20412de9e8442b677bc3121d","archive":{"nam'
    'e":"dart_monty_worker-linux-arm64.gz","bytes":10889760,"sha256":"3bd75'
    'b378475f28d518ebe193a96d4f935923ea858ab4e93e63596e8a42a6a5c"}},"librar'
    'y":{"file":"libdart_monty_worker.so","bytes":22692736,"sha256":"39494a'
    '354690233192aa0bcd1c9542189b82d05720540029f74a9674d2bd5bf8","archive":'
    '{"name":"dart_monty_worker_library-linux-arm64.gz","bytes":9971552,"sh'
    'a256":"58937f63abbf447728c3e65fa440522ba740588974f8f5c38fc705e08197230'
    'd"}}},"linux-x64":{"worker":{"file":"dart_monty_worker","bytes":262215'
    '44,"sha256":"9258cdc893c70abb767a9cd1f2aef23768613f334d268bf93d483b643'
    '63e9d1b","archive":{"name":"dart_monty_worker-linux-x64.gz","bytes":11'
    '464053,"sha256":"d23f34fe1e97b5b86495651cd80b56a403ec0c831766ed3944ec1'
    'b0ff0b3d8ef"}},"library":{"file":"libdart_monty_worker.so","bytes":261'
    '35408,"sha256":"2382e443e612244e8591d5661c0530ec3507e1a844ff2360f38c5b'
    '591172c969","archive":{"name":"dart_monty_worker_library-linux-x64.gz"'
    ',"bytes":10513444,"sha256":"becd718bf85f25590205a9b2be1f0d77c80dafa7b8'
    '93b9c4f249a8851d332241"}}},"macos-arm64":{"worker":{"file":"dart_monty'
    '_worker","bytes":22490976,"sha256":"707f49dc81370c85f017c43bc77e1239ba'
    'cc102f8bb33165a9699b8b6806f7e8","archive":{"name":"dart_monty_worker-m'
    'acos-arm64.gz","bytes":10453282,"sha256":"66810e658a27b5bafdd978d079e3'
    'a35049a5d0528e2d85b7709c38ecce421bfa"}},"library":{"file":"libdart_mon'
    'ty_worker.dylib","bytes":21877904,"sha256":"51fdd75933e7c5c3e0b58ca570'
    '280514be10a7c6075b4cbcdabfb78bc17fbcf4","archive":{"name":"dart_monty_'
    'worker_library-macos-arm64.gz","bytes":9625947,"sha256":"ff3d8c1043b00'
    'f478882e747fde8508276bddab8564b63d242472beba9e6e2be"}}},"windows-x64":'
    '{"worker":{"file":"dart_monty_worker.exe","bytes":28739072,"sha256":"a'
    'e80c69eb95eca80600239fd1698e0b45d960f97965ee9a58e6426f16749c783","arch'
    'ive":{"name":"dart_monty_worker-windows-x64.gz","bytes":11619438,"sha2'
    '56":"5c72d74112daad35d1c1dd385d6e5ef27cbe5294cff96f50d19839a77f0e7f42"'
    '}},"library":{"file":"dart_monty_worker.dll","bytes":27985920,"sha256"'
    ':"dba6295b4a95e193439e10b98d0cee95ce08f54d117496d1852194bfbf0a165a","a'
    'rchive":{"name":"dart_monty_worker_library-windows-x64.gz","bytes":105'
    '91673,"sha256":"da2cd98e9f72370add6b117dbe4c0caa4314bbbec0ed32b2ef6ca1'
    'bca8318702"}}}}}';

/// The parsed manifest bundled with this package.
final bundledWorkerManifest = WorkerManifest.fromJson(workerManifestJson);

/// Default GitHub release mirror template for worker archives.
///
/// `{tag}` comes from [WorkerManifest.version], `{target}` names the host,
/// and `{archive}` names the archive file. A configured mirror overrides this
/// default.
const defaultWorkerMirrorTemplate =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';
