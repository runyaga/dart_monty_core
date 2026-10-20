/// Provides the manifest bundled with this package.
library;

import 'package:dart_monty_core/src/worker/worker_manifest.dart';

/// The manifest of the worker release assets this package version installs.
///
/// An empty `targets` map means no prebuilt worker is published.
const workerManifestJson =
    '{"schema":1,"version":"v0.110.0-dev.4","targets":{"linux-arm64":{"worke'
    'r":{"file":"dart_monty_worker","bytes":23213464,"sha256":"952a2a491d547'
    'f2d7a5ca0c81ceca1bfbb9253b0769c690ac5651a12d8bef6c4","archive":{"name":'
    '"dart_monty_worker-linux-arm64.gz","bytes":10889757,"sha256":"fdd5d7599'
    '78bcadc61e0d7350a1b330b9c5e0cb924e963312a874b5c9851cefd"}},"library":{"'
    'file":"libdart_monty_worker.so","bytes":22692736,"sha256":"8aa4c0d1d2b7'
    '18c124dee5d6ed4a9a98072cd8a15d0de8e7510f370c8a0867a1","archive":{"name"'
    ':"dart_monty_worker_library-linux-arm64.gz","bytes":9971548,"sha256":"0'
    'b550cdc7fe9644ab2c01de3387ccf03b404334d0f014df8f611dcb7ac91fdff"}}},"li'
    'nux-x64":{"worker":{"file":"dart_monty_worker","bytes":26221544,"sha256'
    '":"4aeab752940e533eccea8699308cab499569001886cfcbbfd5d57b358307c6ce","a'
    'rchive":{"name":"dart_monty_worker-linux-x64.gz","bytes":11464349,"sha2'
    '56":"43c2a368f4fb0985562c185525db9f2aa38aad42bc630b01db2f3d3673c2a44d"}'
    '},"library":{"file":"libdart_monty_worker.so","bytes":26135408,"sha256"'
    ':"a30fcc41205486dfc2f50b523ab420b608242150080f5d3810d7a715477a5338","ar'
    'chive":{"name":"dart_monty_worker_library-linux-x64.gz","bytes":1051372'
    '8,"sha256":"fb37c0cbb27c6330ccb6504f5ed25b4cef3025bace9a26322295b96fdaf'
    '9db19"}}},"macos-arm64":{"worker":{"file":"dart_monty_worker","bytes":2'
    '2490976,"sha256":"b362e61143674fc27f92edebb1eb84984aea670d09fb82f0afbcb'
    '5417f651a4a","archive":{"name":"dart_monty_worker-macos-arm64.gz","byte'
    's":10453279,"sha256":"b91724495c46ffd2ca566980e20627f7f57ea2d7faba11a64'
    '62c58117eda75ac"}},"library":{"file":"libdart_monty_worker.dylib","byte'
    's":21877904,"sha256":"40d5f2b6e227ad595f652813356d321b4bdf85ecb79165cea'
    'a792c8243857ca1","archive":{"name":"dart_monty_worker_library-macos-arm'
    '64.gz","bytes":9625948,"sha256":"3b667c54420cc5e603a111381c59aefe6799a8'
    '561c283ff8d8286d7b3d40cda9"}}},"windows-x64":{"worker":{"file":"dart_mo'
    'nty_worker.exe","bytes":28739072,"sha256":"168eea6294aadf3df7b400f76e2b'
    '79740b247945c772bd603476322260a2d3fd","archive":{"name":"dart_monty_wor'
    'ker-windows-x64.gz","bytes":11619438,"sha256":"ae37b23f0e10b6c2c5958cea'
    '463c62d591abd94c1c96aa5c8bfd2195ac9575b4"}},"library":{"file":"dart_mon'
    'ty_worker.dll","bytes":27985920,"sha256":"9bf3893a3a04ba19b8c49dd71d34d'
    '902b7861df99ef3d806854540447e4671c2","archive":{"name":"dart_monty_work'
    'er_library-windows-x64.gz","bytes":10591672,"sha256":"6bbdddf472f4295a9'
    'c23d9282b37acdc40574a10a56c29a19e795c6c78b45509"}}}}}';

/// The parsed manifest bundled with this package.
final bundledWorkerManifest = WorkerManifest.fromJson(workerManifestJson);

/// Default GitHub release mirror template for worker archives.
///
/// `{tag}` comes from [WorkerManifest.version], `{target}` names the host,
/// and `{archive}` names the archive file. A configured mirror overrides this
/// default.
const defaultWorkerMirrorTemplate =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';
