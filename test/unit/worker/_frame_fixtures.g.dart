// Raw ChildEvent frames with upstream's verdict on each, recorded by
// decoding the frame with monty-proto 1.1.0 (`pb::ChildEvent::decode` inside
// `with_decode_budget`, prost 0.14.4):
//
// - [FrameFixture.error]: upstream's `DecodeError` text, for a rejected frame;
// - [FrameFixture.budget]: the smallest decode budget the frame decodes
//   under, found by bisection, which is the sum of the charges upstream's
//   decoder makes;
// - [FrameFixture.canonical]: prost's re-encoding of what it decoded
//   (`encode_to_vec`), so the decoded values can be compared;
// - [FrameFixture.strings]: the UTF-8 of every non-empty string field in
//   that re-encoding, sorted, found with a schema read from monty.proto, so
//   string values are compared without package:protobuf decoding either
//   side.
//
// [FrameFixture.protobufDiffers] marks the frames package:protobuf alone
// would accept where upstream rejects, or read differently.
//
// Generated; do not edit by hand.

/// One frame and upstream's verdict on it.
final class FrameFixture {
  const FrameFixture(
    this.name,
    this.hex, {
    required this.protobufDiffers,
    this.error,
    this.budget,
    this.canonical,
    this.strings = const [],
  });

  final String name;
  final String hex;
  final bool protobufDiffers;

  /// Upstream's error, or null when upstream accepts the frame.
  final String? error;
  final int? budget;
  final String? canonical;

  /// Hex of each string value's UTF-8, sorted.
  final List<String> strings;
}

const List<FrameFixture> frameFixtures = [
  FrameFixture(
    'bool node 2^32',
    '320a12081206208080808010',
    budget: 288,
    canonical: '32081206080112022001',
    strings: [],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool node 2^63',
    '320f120d120b2080808080808080808001',
    budget: 288,
    canonical: '32081206080112022001',
    strings: [],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool node 2^32 padded to 10 bytes',
    '320f120d120b2080808080908080808000',
    budget: 288,
    canonical: '32081206080112022001',
    strings: [],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool node 2^32 + 1 (control)',
    '320a12081206208180808010',
    budget: 288,
    canonical: '32081206080112022001',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'bool Type.is_dataclass 2^32',
    '322612241222ba011f0a014312120a100102030405060708090a0b0c0d0e0f101802208080808010',
    budget: 377,
    canonical:
        '322412220801121eba011b0a014312120a100102030405060708090a0b0c0d0e0f1018022001',
    strings: ['43'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool BigInt.negative 2^32',
    '320f120d120b3209088080808010120101',
    budget: 321,
    canonical: '320d120b0801120732050801120101',
    strings: [],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool FunctionCall.allow_eager_await 2^40',
    '120c0a0166308080808080203a00',
    budget: 1,
    canonical: '12070a016630013a00',
    strings: ['66'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool OsCall.allow_eager_await 2^32',
    '1a0d12017092030098038080808010',
    budget: 1,
    canonical: '1a09120170920300980301',
    strings: ['70'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool StackFrame.hide_caret 2^32',
    '3a190a170a0a56616c75654572726f721a090a0166308080808010',
    budget: 427,
    canonical: '3a150a130a0a56616c75654572726f721a050a01663001',
    strings: ['56616c75654572726f72', '66'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'bool Mkdir.parents 2^35',
    '1a0d9a010a0a016410808080808001',
    budget: 1,
    canonical: '1a089a01050a01641001',
    strings: ['64'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'u64 envelope 2^64 - 1 (control)',
    'a001ffffffffffffffffff01',
    budget: 0,
    canonical: 'a001ffffffffffffffffff01',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'varint overflow: tenth byte 2, envelope',
    'a001ffffffffffffffffff02',
    error:
        'failed to decode Protobuf message: ChildEvent.total_execution_micros: invalid varint',
    protobufDiffers: true,
  ),
  FrameFixture(
    'varint overflow: tenth byte 0x7f, MontyNode.int',
    '320f120d120b28ffffffffffffffffff7f',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid varint',
    protobufDiffers: true,
  ),
  FrameFixture(
    'varint overflow: Complete.value',
    '32110880808080808080808002120412021200',
    error:
        'failed to decode Protobuf message: Complete.value: ChildEvent.kind: invalid varint',
    protobufDiffers: true,
  ),
  FrameFixture(
    'varint overflow: a boolean',
    '320f120d120b2080808080808080808002',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid varint',
    protobufDiffers: true,
  ),
  FrameFixture(
    'varint of eleven bytes (control)',
    'a0018080808080808080808000',
    error:
        'failed to decode Protobuf message: ChildEvent.total_execution_micros: invalid varint',
    protobufDiffers: false,
  ),
  FrameFixture(
    'varint cut by the end of the frame (control)',
    'a0018080',
    error:
        'failed to decode Protobuf message: ChildEvent.total_execution_micros: invalid varint',
    protobufDiffers: false,
  ),
  FrameFixture(
    'key beyond 32 bits',
    'b28080801006120412021200',
    error: 'failed to decode Protobuf message: invalid key value: 4294967346',
    protobufDiffers: true,
  ),
  FrameFixture(
    'key with field number 0 (control)',
    '0001',
    error: 'failed to decode Protobuf message: invalid tag value: 0',
    protobufDiffers: false,
  ),
  FrameFixture(
    'key with wire type 6 (control)',
    'a60100',
    error: 'failed to decode Protobuf message: invalid wire type value: 6',
    protobufDiffers: false,
  ),
  FrameFixture(
    'key in two bytes (control)',
    'b20006120412021200',
    budget: 288,
    canonical: '32081206080112021200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'wire type: Complete.value delimited',
    '32040a020805',
    error:
        'failed to decode Protobuf message: Complete.value: ChildEvent.kind: invalid wire type: LengthDelimited (expected Varint)',
    protobufDiffers: true,
  ),
  FrameFixture(
    'wire type: ChildEvent.complete as a varint',
    '3001',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: invalid wire type: Varint (expected LengthDelimited)',
    protobufDiffers: true,
  ),
  FrameFixture(
    'wire type: MontyNode.float as 32 bits',
    '3209120712053d00000000',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid wire type: ThirtyTwoBit (expected SixtyFourBit)',
    protobufDiffers: true,
  ),
  FrameFixture(
    'wire type: MontyNode.str as a varint',
    '3206120412024001',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid wire type: Varint (expected LengthDelimited)',
    protobufDiffers: true,
  ),
  FrameFixture(
    'wire type: Indexes.items as 32 bits',
    '32110801120d1202120012075a050d00000000',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid wire type: ThirtyTwoBit (expected Varint)',
    protobufDiffers: true,
  ),
  FrameFixture(
    'wire type: Complete.values as a group',
    '32021314',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: invalid wire type: StartGroup (expected LengthDelimited)',
    protobufDiffers: true,
  ),
  FrameFixture(
    'Indexes.items unpacked (control)',
    '321408021210120212001202120012065a0408000801',
    budget: 352,
    canonical: '3216080212120803120212001202120012065a040a020001',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'enum PrintStream: stderr then 7',
    '0a090a0708020807120178',
    budget: 129,
    canonical: '0a070a050807120178',
    strings: ['78'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'enum PrintStream: -1',
    '0a100a0e08ffffffffffffffffff01120178',
    budget: 129,
    canonical: '0a100a0e08ffffffffffffffffff01120178',
    strings: ['78'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'enum PrintStream: 2^32 + 2 (control)',
    '0a0b0a09088280808010120178',
    budget: 129,
    canonical: '0a070a050802120178',
    strings: ['78'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'enum Type.origin: 2 then 7',
    '32221220121eba011b0a014312120a100102030405060708090a0b0c0d0e0f1018021807',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: invalid value for Type.origin: unknown origin 7',
    protobufDiffers: true,
  ),
  FrameFixture(
    'enum Type.origin: 7 then 2 (control)',
    '32221220121eba011b0a014312120a100102030405060708090a0b0c0d0e0f1018071802',
    budget: 377,
    canonical:
        '322212200801121cba01190a014312120a100102030405060708090a0b0c0d0e0f101802',
    strings: ['43'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'utf8: invalid byte in a str node',
    '3208120612044202c328',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a surrogate',
    '3209120712054203eda080',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: an overlong NUL',
    '3208120612044202c080',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: beyond U+10FFFF',
    '320a120812064204f4908080',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: cut at the end',
    '320912071205420361e282',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a leading byte-order mark is kept',
    '320a120812064204efbbbf61',
    budget: 292,
    canonical: '320c120a080112064204efbbbf61',
    strings: ['efbbbf61'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a string that is only a byte-order mark',
    '3209120712054203efbbbf',
    budget: 291,
    canonical: '320b1209080112054203efbbbf',
    strings: ['efbbbf'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: two leading byte-order marks',
    '320d120b12094207efbbbfefbbbf61',
    budget: 295,
    canonical: '320f120d080112094207efbbbfefbbbf61',
    strings: ['efbbbfefbbbf61'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a byte-order mark after the start (control)',
    '320a12081206420461efbbbf',
    budget: 292,
    canonical: '320c120a08011206420461efbbbf',
    strings: ['61efbbbf'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'utf8: a byte-order mark in Print text',
    '0a0a0a0808011204efbbbf78',
    budget: 132,
    canonical: '0a0a0a0808011204efbbbf78',
    strings: ['efbbbf78'],
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a byte-order mark before a builtin type name',
    '3211120f120dba010a0a06efbbbf696e741801',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: unknown type name "\\u{feff}int"',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a byte-order mark before a builtin function name',
    '320d120b1209d20106efbbbf6c656e',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: unknown builtin function "\\u{feff}len"',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: a byte-order mark before an exception type, in a discarded arm',
    '321612141212b2010f0a0defbbbf56616c75654572726f725200',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: unknown exception type "\\u{feff}ValueError"',
    protobufDiffers: true,
  ),
  FrameFixture(
    'builtin type name (control)',
    '320e120c120aba01070a03696e741801',
    budget: 291,
    canonical: '3210120e0801120aba01070a03696e741801',
    strings: ['696e74'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'utf8: four-byte characters (control)',
    '3210120e120c420af09f9880f48fbfbfc3a9',
    budget: 298,
    canonical: '321212100801120c420af09f9880f48fbfbfc3a9',
    strings: ['f09f9880f48fbfbfc3a9'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'utf8: Print text',
    '0a050a031201ff',
    error:
        'failed to decode Protobuf message: PrintSegment.text: Print.segments: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: FatalError.message',
    '5a030a0180',
    error:
        'failed to decode Protobuf message: FatalError.message: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: UnicodeErrorData.object_str',
    '3a1d0a1b0a12556e69636f64654465636f64654572726f7222050a031a01fe',
    error:
        'failed to decode Protobuf message: UnicodeErrorData.object: ExcData.kind: RaisedException.data: Error.exception: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: UnicodeErrorData.object_bytes is bytes (control)',
    '3a1d0a1b0a12556e69636f64654465636f64654572726f7222050a031201fe',
    budget: 19,
    canonical: '3a1d0a1b0a12556e69636f64654465636f64654572726f7222050a031201fe',
    strings: ['556e69636f64654465636f64654572726f72'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'utf8: in an arm a later arm discards',
    '5a040a02c0805200',
    error:
        'failed to decode Protobuf message: FatalError.message: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: in an unknown field (control)',
    '7a02fffe5200',
    budget: 0,
    canonical: '5200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'utf8: OsCall path',
    '1a051203edbfbf',
    error:
        'failed to decode Protobuf message: OsCall.call: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: FunctionCall.function_name',
    '12070a03e080803a00',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'utf8: NamedTupleNode.field_names',
    '32150801121112021200120b6a090a01501201801a0100',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: invalid string value: data is not UTF-8 encoded',
    protobufDiffers: true,
  ),
  FrameFixture(
    'node: complex then int=1 is an int (control)',
    '320912071205fa01002802',
    budget: 288,
    canonical: '32081206080112022802',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'node: invalid node in a discarded Complete',
    '320712051203fa01005200',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: missing required field Complex.real',
    protobufDiffers: true,
  ),
  FrameFixture(
    'node: invalid node in the final arena',
    '3210120e120cfa0109090000000000000000',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: missing required field Complex.imag',
    protobufDiffers: true,
  ),
  FrameFixture(
    'node: invalid node in a discarded FunctionCall',
    '120c0a01663a0712058a010208003206120412021200',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: invalid value for Date.year: 0 is outside the range 1..=9999',
    protobufDiffers: true,
  ),
  FrameFixture(
    'node: a node with no kind',
    '320412021200',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: missing required field MontyNode.kind',
    protobufDiffers: true,
  ),
  FrameFixture(
    'node: the uuid arm',
    '32181216121452120a100102030405060708090a0b0c0d0e0f10',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: missing required field MontyNode.kind',
    protobufDiffers: true,
  ),
  FrameFixture(
    'node: list arms merge (control)',
    '321608021212120212001202120012085a0208005a020801',
    budget: 352,
    canonical: '3216080212120803120212001202120012065a040a020001',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'node: list, str, list keeps the last list (control)',
    '3219080212151202120012021200120b5a0208004201785a020801',
    budget: 417,
    canonical: '3215080212110803120212001202120012055a030a0101',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'node: Complete arms merge their arenas (control)',
    '32061204120212003208080112041202280a',
    budget: 288,
    canonical: '320e0801120a0802120212001202280a',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'node: valid class type (control)',
    '3220121e121cba01190a014312120a100102030405060708090a0b0c0d0e0f101802',
    budget: 377,
    canonical:
        '322212200801121cba01190a014312120a100102030405060708090a0b0c0d0e0f101802',
    strings: ['43'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'node: discarded event, then a Complete repeated (control)',
    '52003206120412022802',
    budget: 288,
    canonical: '32081206080112022802',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'object_id of 15 bytes',
    '12180a01662a110a0f0102030405060708090a0b0c0d0e0f3a00',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: invalid value for FunctionCall.object_id: uuid must be 16 bytes, got 15',
    protobufDiffers: true,
  ),
  FrameFixture(
    'object_id of 16 bytes (control)',
    '12190a01662a120a100102030405060708090a0b0c0d0e0f103a00',
    budget: 17,
    canonical: '12190a01662a120a100102030405060708090a0b0c0d0e0f103a00',
    strings: ['66'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'object_id of 15 then 16 bytes',
    '122c0a01662a110a0f0102030405060708090a0b0c0d0e0f2a120a100102030405060708090a0b0c0d0e0f103a00',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: invalid value for FunctionCall.object_id: uuid must be 16 bytes, got 15',
    protobufDiffers: true,
  ),
  FrameFixture(
    'position: filenames shrink then grow across occurrences',
    '12190a0166420b0a066162636465660a016142050a036162633a00',
    budget: 10,
    canonical: '120c0a01663a0042050a03616263',
    strings: ['616263', '66'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'position: an empty filename resets the buffer',
    '121a0a016642080a0661626364656642020a0042050a036162633a00',
    budget: 10,
    canonical: '120c0a01663a0042050a03616263',
    strings: ['616263', '66'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'position: two 257-byte filenames',
    '1293040a01664284020a810278787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878784284020a810278787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878783a00',
    budget: 515,
    canonical:
        '128b020a01663a004283020a800278787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878',
    strings: [
      '66',
      '78787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878',
    ],
    protobufDiffers: true,
  ),
  FrameFixture(
    'position: a 257-byte filename is cut to 256',
    '128c020a01664284020a810278787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878783a00',
    budget: 258,
    canonical:
        '128b020a01663a004283020a800278787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878',
    strings: [
      '66',
      '78787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878787878',
    ],
    protobufDiffers: true,
  ),
  FrameFixture(
    'position: cut on a character boundary',
    '128c020a01664284020a8102616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161c3a93a00',
    budget: 258,
    canonical:
        '128a020a01663a004282020aff01616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161',
    strings: [
      '616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161616161',
      '66',
    ],
    protobufDiffers: true,
  ),
  FrameFixture(
    'position: a cut filename is kept by an occurrence without one',
    '12bb020a016642af020aac02797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979420210053a00',
    budget: 301,
    canonical:
        '128d020a01663a004285020a8002797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979791005',
    strings: [
      '66',
      '79797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979797979',
    ],
    protobufDiffers: true,
  ),
  FrameFixture(
    'position: a 256-byte filename is whole (control)',
    '128b020a01664283020a8002777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777773a00',
    budget: 257,
    canonical:
        '128b020a01663a004283020a800277777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777',
    strings: [
      '66',
      '77777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777777',
    ],
    protobufDiffers: false,
  ),
  FrameFixture(
    'OsCall.position is not cut (control)',
    '1ab602120170a203af020aac027a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a',
    budget: 301,
    canonical:
        '1ab602120170a203af020aac027a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a',
    strings: [
      '70',
      '7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a7a',
    ],
    protobufDiffers: false,
  ),
  FrameFixture(
    'NameLookup.object_id is not checked (control)',
    '220a0a017812050a03010203',
    budget: 4,
    canonical: '220a0a017812050a03010203',
    strings: ['78'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: node_count hint capped by the frame',
    '32120801120e08ffffffff0f1202120012021200',
    budget: 144,
    canonical: '320e0801120a08021202120012021200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: node_count after a node is ignored',
    '320912071202120008e807',
    budget: 288,
    canonical: '32081206080112021200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: node_count 0 then 3',
    '320a12080800080312021200',
    budget: 72,
    canonical: '32081206080112021200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: nine nodes grow 4, 8, 16',
    '322808081224120212001202120012021200120212001202120012021200120212001202120012021200',
    budget: 2016,
    canonical:
        '322a080812260809120212001202120012021200120212001202120012021200120212001202120012021200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: big integer with leading zeros',
    '320c120a12083206120400000102',
    budget: 324,
    canonical: '320c120a08011206320412020102',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: big integer of 40 bytes',
    '3230122e122c322a122807070707070707070707070707070707070707070707070707070707070707070707070707070707',
    budget: 368,
    canonical:
        '323212300801122c322a122807070707070707070707070707070707070707070707070707070707070707070707070707070707',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: big integer of zeros',
    '320a12081206320412020000',
    budget: 290,
    canonical: '320b1209080112053203120100',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: class type with attrs',
    '32310802122d1203420161120212001222ba011f0a014312120a100102030405060708090a0b0c0d0e0f1018022a040a021001',
    budget: 506,
    canonical:
        '32330802122f08031203420161120212001222ba011f0a014312120a100102030405060708090a0b0c0d0e0f1018022a040a021001',
    strings: ['43', '61'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: a string reuses its buffer',
    '321a1218121642066162636465664202616242086162636465666768',
    budget: 302,
    canonical: '3210120e0801120a42086162636465666768',
    strings: ['6162636465666768'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: five print segments',
    '0a280a04080112000a0508011201740a060801120274740a07080112037474740a080801120474747474',
    budget: 394,
    canonical:
        '0a260a0208010a0508011201740a060801120274740a07080112037474740a080801120474747474',
    strings: ['74', '7474', '747474', '74747474'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: a traceback frame',
    '3a3c0a3a0a0a56616c75654572726f7212016d1a140a04662e70791202080322083c6d6f64756c653e221312110a09457870656374696e6712027b7d1801',
    budget: 450,
    canonical:
        '3a3c0a3a0a0a56616c75654572726f7212016d1a140a04662e70791202080322083c6d6f64756c653e221312110a09457870656374696e6712027b7d1801',
    strings: [
      '3c6d6f64756c653e',
      '457870656374696e67',
      '56616c75654572726f72',
      '662e7079',
      '6d',
      '7b7d',
    ],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: pending call ids packed and unpacked',
    '2a090a0500010203040809',
    budget: 48,
    canonical: '2a080a06000102030409',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: call args, kwargs and object id',
    '123d0a0166120300000110001a0208011a0210012a120a100102030405060708090a0b0c0d0e0f1042050a0361626342030a01613a0912021200120342016b',
    budget: 581,
    canonical:
        '12370a01661204000001001a0208011a0210012a120a100102030405060708090a0b0c0d0e0f103a0b080212021200120342016b42030a0161',
    strings: ['61', '66', '6b'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: named tuple',
    '321e0802121a120212001202120012106a0e0a0150120161120262621a020001',
    budget: 420,
    canonical:
        '32200802121c0803120212001202120012106a0e0a0150120161120262621a020001',
    strings: ['50', '61', '6262'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: dict of five pairs',
    '32160801121212021200120c720a0a000a000a000a000a00',
    budget: 672,
    canonical: '321808011214080212021200120c720a0a000a000a000a000a00',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: OsCall write_bytes, dump, session id',
    '1a1282010f0a0170120a000000000000000000004a090a0701010101010101e20103020202',
    budget: 21,
    canonical: '4a090a0701010101010101e20103020202',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: switching arms keeps every charge',
    '320a120812064204616161615a050a0361626332081206120442026262',
    budget: 585,
    canonical: '320a12080801120442026262',
    strings: ['6262'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: repeated Complete keeps the arena',
    '32100802120c120212001202120012021200320e120c120212001202120012021200',
    budget: 864,
    canonical:
        '321e0802121a0806120212001202120012021200120212001202120012021200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'budget: str arm switched away and back starts afresh',
    '3210120e120c420461626364280142026162',
    budget: 294,
    canonical: '320a12080801120442026162',
    strings: ['6162'],
    protobufDiffers: false,
  ),
  FrameFixture(
    'group: 100 nested, empty (control)',
    '7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c',
    budget: 0,
    canonical: '',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'group: 100 nested around a varint',
    '7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b08007c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c',
    error: 'failed to decode Protobuf message: recursion limit reached',
    protobufDiffers: true,
  ),
  FrameFixture(
    'group: 99 nested around a varint (control)',
    '7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b08007c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c',
    budget: 0,
    canonical: '',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'group: 101 nested (control)',
    '7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c',
    error: 'failed to decode Protobuf message: recursion limit reached',
    protobufDiffers: false,
  ),
  FrameFixture(
    'group: mismatched end (control)',
    '7b8401',
    error: 'failed to decode Protobuf message: unexpected end group tag',
    protobufDiffers: false,
  ),
  FrameFixture(
    'group: stray end (control)',
    '7c',
    error: 'failed to decode Protobuf message: unexpected end group tag',
    protobufDiffers: false,
  ),
  FrameFixture(
    'unknown fixed32, fixed64, delimited (control)',
    '7d00000000810100000000000000008a01036162635200',
    budget: 0,
    canonical: '5200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'group inside a nested message: 98 deep around a varint (control)',
    '32c6017b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b08007c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c',
    budget: 0,
    canonical: '3200',
    strings: [],
    protobufDiffers: false,
  ),
  FrameFixture(
    'group inside a nested message: 99 deep around a varint',
    '32c8017b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b7b08007c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c7c',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: recursion limit reached',
    protobufDiffers: true,
  ),
  FrameFixture(
    'length past the frame (control)',
    '320508',
    error:
        'failed to decode Protobuf message: ChildEvent.kind: buffer underflow',
    protobufDiffers: false,
  ),
  FrameFixture(
    'string past its message, inside the frame (control)',
    '3206120412024203616263',
    error:
        'failed to decode Protobuf message: Complete.values: ChildEvent.kind: delimited length exceeded',
    protobufDiffers: false,
  ),
  FrameFixture(
    'fixed64 cut short (control)',
    '320712051203390000',
    error:
        'failed to decode Protobuf message: MontyNode.kind: Complete.values: ChildEvent.kind: buffer underflow',
    protobufDiffers: false,
  ),
  FrameFixture(
    'empty frame (control)',
    '',
    budget: 0,
    canonical: '',
    strings: [],
    protobufDiffers: false,
  ),
];
