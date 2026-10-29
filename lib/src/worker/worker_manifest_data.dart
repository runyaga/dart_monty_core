/// Provides the manifest bundled with this package.
library;

import 'package:dart_monty_core/src/worker/worker_manifest.dart';

/// The manifest of the worker release assets this package version installs.
///
/// An empty `targets` map means no prebuilt worker is published.
const workerManifestJson =
    '{"schema":1,"version":"v0.120.0","targets":{"linux-arm64":{"worker":{"fi'
    'le":"dart_monty_worker","bytes":24262080,"sha256":"5edc042b2f76c3fd9b11f'
    'a8981bc37ffc98a319c8c0f065c7106322b8f7d6a2f","archive":{"name":"dart_mon'
    'ty_worker-linux-arm64.gz","bytes":11400485,"sha256":"18132357d3a1d3b6384'
    'd8a3a2feffc55e4c684a8c2d40a1b6f60733c5b1e9e9a"}},"library":{"file":"libd'
    'art_monty_worker.so","bytes":23675824,"sha256":"1b9156ea250e4211cc0e91a1'
    'd68a4c658de5d814b7fee5cb89feb074df01b33b","archive":{"name":"dart_monty_'
    'worker_library-linux-arm64.gz","bytes":10490415,"sha256":"f5ce69f80545f6'
    '41d04aa1ca22498467f0facfc30caba7be105977e25147cd0c"}}},"linux-x64":{"wor'
    'ker":{"file":"dart_monty_worker","bytes":27474784,"sha256":"f19a2e4d226e'
    '3952cda831b0f18cf3f2f967b587dadc35eba385f841bd425d8f","archive":{"name":'
    '"dart_monty_worker-linux-x64.gz","bytes":12003673,"sha256":"6a2dd5291d33'
    '004792a4e86c2bcf5bd657de1b4c8f9f8cd60ef637b1748393a2"}},"library":{"file'
    '":"libdart_monty_worker.so","bytes":27441128,"sha256":"76db50022954ab9c7'
    '09e925ee555b21731cfa5e5a47783fb00cc815dc1ff6670","archive":{"name":"dart'
    '_monty_worker_library-linux-x64.gz","bytes":11056266,"sha256":"118511dcb'
    '74988b81303ee62c5161629596688b5aba72170b83a12f2de9ba91e"}}},"macos-arm64'
    '":{"worker":{"file":"dart_monty_worker","bytes":23483424,"sha256":"5fcaf'
    '86e2c505738edcf2b163b6e0519ccf911b47c440ce944eb285fcb82cc20","archive":{'
    '"name":"dart_monty_worker-macos-arm64.gz","bytes":10927138,"sha256":"124'
    '6828d85b4888dd98d2b1525fda57c397b63be4304793d9f008ac8d157035c"}},"librar'
    'y":{"file":"libdart_monty_worker.dylib","bytes":22903728,"sha256":"a7a18'
    '0dc7e8cacf25db22cbbc14dd6e8db0434f008dcbb5960863ba21cd4082b","archive":{'
    '"name":"dart_monty_worker_library-macos-arm64.gz","bytes":10117106,"sha2'
    '56":"a9b0047dc936d88c21a1af83467626005efa743f2522b127a8d721a6c8ca6713"}}'
    '},"windows-x64":{"worker":{"file":"dart_monty_worker.exe","bytes":301255'
    '68,"sha256":"f62998ff317bc2fb923fd12f1a57725b4fa53b1a897133047276fa7d2be'
    '559a1","archive":{"name":"dart_monty_worker-windows-x64.gz","bytes":1216'
    '6251,"sha256":"8a583f384c94e4ad7126e5604599293452a9466455a5f9b1d544edb6f'
    'd93ffa4"}},"library":{"file":"dart_monty_worker.dll","bytes":29396992,"s'
    'ha256":"bc6af419cbb5afcbc9134d4ace78395c4fcfd170928c7078b943c59d43457e72'
    '","archive":{"name":"dart_monty_worker_library-windows-x64.gz","bytes":1'
    '1136396,"sha256":"734b1160be103a5f891d3a6658f6e27accfbffff5ac78509419b2d'
    '9dfd62213a"}}}}}';

/// The parsed manifest bundled with this package.
final bundledWorkerManifest = WorkerManifest.fromJson(workerManifestJson);

/// Default GitHub release mirror template for worker archives.
///
/// `{tag}` comes from [WorkerManifest.version], `{target}` names the host,
/// and `{archive}` names the archive file. A configured mirror overrides this
/// default.
const defaultWorkerMirrorTemplate =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';
