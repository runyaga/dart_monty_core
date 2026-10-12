// This is a generated file - do not edit.
//
// Generated from monty/v1/monty.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use typeOriginDescriptor instead')
const TypeOrigin$json = {
  '1': 'TypeOrigin',
  '2': [
    {'1': 'TYPE_ORIGIN_UNSPECIFIED', '2': 0},
    {'1': 'TYPE_ORIGIN_BUILTIN', '2': 1},
    {'1': 'TYPE_ORIGIN_SANDBOX', '2': 2},
    {'1': 'TYPE_ORIGIN_HOST', '2': 3},
  ],
};

/// Descriptor for `TypeOrigin`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List typeOriginDescriptor = $convert.base64Decode(
    'CgpUeXBlT3JpZ2luEhsKF1RZUEVfT1JJR0lOX1VOU1BFQ0lGSUVEEAASFwoTVFlQRV9PUklHSU'
    '5fQlVJTFRJThABEhcKE1RZUEVfT1JJR0lOX1NBTkRCT1gQAhIUChBUWVBFX09SSUdJTl9IT1NU'
    'EAM=');

@$core.Deprecated('Use persistenceDescriptor instead')
const Persistence$json = {
  '1': 'Persistence',
  '2': [
    {'1': 'PERSISTENCE_UNSPECIFIED', '2': 0},
    {'1': 'PERSISTENCE_EPHEMERAL', '2': 1},
    {'1': 'PERSISTENCE_STORED', '2': 2},
  ],
};

/// Descriptor for `Persistence`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List persistenceDescriptor = $convert.base64Decode(
    'CgtQZXJzaXN0ZW5jZRIbChdQRVJTSVNURU5DRV9VTlNQRUNJRklFRBAAEhkKFVBFUlNJU1RFTk'
    'NFX0VQSEVNRVJBTBABEhYKElBFUlNJU1RFTkNFX1NUT1JFRBAC');

@$core.Deprecated('Use typeCheckFormatDescriptor instead')
const TypeCheckFormat$json = {
  '1': 'TypeCheckFormat',
  '2': [
    {'1': 'TYPE_CHECK_FORMAT_UNSPECIFIED', '2': 0},
    {'1': 'TYPE_CHECK_FORMAT_FULL', '2': 1},
    {'1': 'TYPE_CHECK_FORMAT_CONCISE', '2': 2},
    {'1': 'TYPE_CHECK_FORMAT_AZURE', '2': 3},
    {'1': 'TYPE_CHECK_FORMAT_JSON', '2': 4},
    {'1': 'TYPE_CHECK_FORMAT_JSON_LINES', '2': 5},
    {'1': 'TYPE_CHECK_FORMAT_RDJSON', '2': 6},
    {'1': 'TYPE_CHECK_FORMAT_PYLINT', '2': 7},
    {'1': 'TYPE_CHECK_FORMAT_GITLAB', '2': 8},
    {'1': 'TYPE_CHECK_FORMAT_GITHUB', '2': 9},
  ],
};

/// Descriptor for `TypeCheckFormat`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List typeCheckFormatDescriptor = $convert.base64Decode(
    'Cg9UeXBlQ2hlY2tGb3JtYXQSIQodVFlQRV9DSEVDS19GT1JNQVRfVU5TUEVDSUZJRUQQABIaCh'
    'ZUWVBFX0NIRUNLX0ZPUk1BVF9GVUxMEAESHQoZVFlQRV9DSEVDS19GT1JNQVRfQ09OQ0lTRRAC'
    'EhsKF1RZUEVfQ0hFQ0tfRk9STUFUX0FaVVJFEAMSGgoWVFlQRV9DSEVDS19GT1JNQVRfSlNPTh'
    'AEEiAKHFRZUEVfQ0hFQ0tfRk9STUFUX0pTT05fTElORVMQBRIcChhUWVBFX0NIRUNLX0ZPUk1B'
    'VF9SREpTT04QBhIcChhUWVBFX0NIRUNLX0ZPUk1BVF9QWUxJTlQQBxIcChhUWVBFX0NIRUNLX0'
    'ZPUk1BVF9HSVRMQUIQCBIcChhUWVBFX0NIRUNLX0ZPUk1BVF9HSVRIVUIQCQ==');

@$core.Deprecated('Use printStreamDescriptor instead')
const PrintStream$json = {
  '1': 'PrintStream',
  '2': [
    {'1': 'PRINT_STREAM_UNSPECIFIED', '2': 0},
    {'1': 'PRINT_STREAM_STDOUT', '2': 1},
    {'1': 'PRINT_STREAM_STDERR', '2': 2},
  ],
};

/// Descriptor for `PrintStream`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List printStreamDescriptor = $convert.base64Decode(
    'CgtQcmludFN0cmVhbRIcChhQUklOVF9TVFJFQU1fVU5TUEVDSUZJRUQQABIXChNQUklOVF9TVF'
    'JFQU1fU1RET1VUEAESFwoTUFJJTlRfU1RSRUFNX1NUREVSUhAC');

@$core.Deprecated('Use unitDescriptor instead')
const Unit$json = {
  '1': 'Unit',
};

/// Descriptor for `Unit`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unitDescriptor = $convert.base64Decode('CgRVbml0');

@$core.Deprecated('Use arenaDescriptor instead')
const Arena$json = {
  '1': 'Arena',
  '2': [
    {'1': 'node_count', '3': 1, '4': 1, '5': 13, '10': 'nodeCount'},
    {
      '1': 'nodes',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.MontyNode',
      '10': 'nodes'
    },
  ],
};

/// Descriptor for `Arena`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List arenaDescriptor = $convert.base64Decode(
    'CgVBcmVuYRIdCgpub2RlX2NvdW50GAEgASgNUglub2RlQ291bnQSKQoFbm9kZXMYAiADKAsyEy'
    '5tb250eS52MS5Nb250eU5vZGVSBW5vZGVz');

@$core.Deprecated('Use montyNodeDescriptor instead')
const MontyNode$json = {
  '1': 'MontyNode',
  '2': [
    {
      '1': 'ellipsis',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'ellipsis'
    },
    {
      '1': 'none',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'none'
    },
    {
      '1': 'not_implemented',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'notImplemented'
    },
    {'1': 'boolean', '3': 4, '4': 1, '5': 8, '9': 0, '10': 'boolean'},
    {'1': 'int', '3': 5, '4': 1, '5': 18, '9': 0, '10': 'int'},
    {
      '1': 'bigint',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.BigInt',
      '9': 0,
      '10': 'bigint'
    },
    {'1': 'float', '3': 7, '4': 1, '5': 1, '9': 0, '10': 'float'},
    {'1': 'str', '3': 8, '4': 1, '5': 9, '9': 0, '10': 'str'},
    {'1': 'bytes', '3': 9, '4': 1, '5': 12, '9': 0, '10': 'bytes'},
    {
      '1': 'uuid',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Uuid',
      '9': 0,
      '10': 'uuid'
    },
    {
      '1': 'list',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Indexes',
      '9': 0,
      '10': 'list'
    },
    {
      '1': 'tuple',
      '3': 12,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Indexes',
      '9': 0,
      '10': 'tuple'
    },
    {
      '1': 'named_tuple',
      '3': 13,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.NamedTupleNode',
      '9': 0,
      '10': 'namedTuple'
    },
    {
      '1': 'dict',
      '3': 14,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.NodePairs',
      '9': 0,
      '10': 'dict'
    },
    {
      '1': 'set',
      '3': 15,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Indexes',
      '9': 0,
      '10': 'set'
    },
    {
      '1': 'frozen_set',
      '3': 16,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Indexes',
      '9': 0,
      '10': 'frozenSet'
    },
    {
      '1': 'date',
      '3': 17,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Date',
      '9': 0,
      '10': 'date'
    },
    {
      '1': 'time',
      '3': 18,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Time',
      '9': 0,
      '10': 'time'
    },
    {
      '1': 'datetime',
      '3': 19,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.DateTime',
      '9': 0,
      '10': 'datetime'
    },
    {
      '1': 'timedelta',
      '3': 20,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.TimeDelta',
      '9': 0,
      '10': 'timedelta'
    },
    {
      '1': 'timezone',
      '3': 21,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.TimeZone',
      '9': 0,
      '10': 'timezone'
    },
    {
      '1': 'exception',
      '3': 22,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Exception',
      '9': 0,
      '10': 'exception'
    },
    {
      '1': 'type',
      '3': 23,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Type',
      '9': 0,
      '10': 'type'
    },
    {
      '1': 'class_instance',
      '3': 24,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ClassInstanceNode',
      '9': 0,
      '10': 'classInstance'
    },
    {
      '1': 'function',
      '3': 25,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Function',
      '9': 0,
      '10': 'function'
    },
    {
      '1': 'builtin_function',
      '3': 26,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'builtinFunction'
    },
    {'1': 'path', '3': 27, '4': 1, '5': 9, '9': 0, '10': 'path'},
    {
      '1': 'file_handle',
      '3': 28,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.FileHandle',
      '9': 0,
      '10': 'fileHandle'
    },
    {'1': 'repr', '3': 29, '4': 1, '5': 9, '9': 0, '10': 'repr'},
    {'1': 'cycle', '3': 30, '4': 1, '5': 9, '9': 0, '10': 'cycle'},
    {
      '1': 'complex',
      '3': 31,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Complex',
      '9': 0,
      '10': 'complex'
    },
  ],
  '8': [
    {'1': 'kind'},
  ],
};

/// Descriptor for `MontyNode`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List montyNodeDescriptor = $convert.base64Decode(
    'CglNb250eU5vZGUSLAoIZWxsaXBzaXMYASABKAsyDi5tb250eS52MS5Vbml0SABSCGVsbGlwc2'
    'lzEiQKBG5vbmUYAiABKAsyDi5tb250eS52MS5Vbml0SABSBG5vbmUSOQoPbm90X2ltcGxlbWVu'
    'dGVkGAMgASgLMg4ubW9udHkudjEuVW5pdEgAUg5ub3RJbXBsZW1lbnRlZBIaCgdib29sZWFuGA'
    'QgASgISABSB2Jvb2xlYW4SEgoDaW50GAUgASgSSABSA2ludBIqCgZiaWdpbnQYBiABKAsyEC5t'
    'b250eS52MS5CaWdJbnRIAFIGYmlnaW50EhYKBWZsb2F0GAcgASgBSABSBWZsb2F0EhIKA3N0ch'
    'gIIAEoCUgAUgNzdHISFgoFYnl0ZXMYCSABKAxIAFIFYnl0ZXMSJAoEdXVpZBgKIAEoCzIOLm1v'
    'bnR5LnYxLlV1aWRIAFIEdXVpZBInCgRsaXN0GAsgASgLMhEubW9udHkudjEuSW5kZXhlc0gAUg'
    'RsaXN0EikKBXR1cGxlGAwgASgLMhEubW9udHkudjEuSW5kZXhlc0gAUgV0dXBsZRI7CgtuYW1l'
    'ZF90dXBsZRgNIAEoCzIYLm1vbnR5LnYxLk5hbWVkVHVwbGVOb2RlSABSCm5hbWVkVHVwbGUSKQ'
    'oEZGljdBgOIAEoCzITLm1vbnR5LnYxLk5vZGVQYWlyc0gAUgRkaWN0EiUKA3NldBgPIAEoCzIR'
    'Lm1vbnR5LnYxLkluZGV4ZXNIAFIDc2V0EjIKCmZyb3plbl9zZXQYECABKAsyES5tb250eS52MS'
    '5JbmRleGVzSABSCWZyb3plblNldBIkCgRkYXRlGBEgASgLMg4ubW9udHkudjEuRGF0ZUgAUgRk'
    'YXRlEiQKBHRpbWUYEiABKAsyDi5tb250eS52MS5UaW1lSABSBHRpbWUSMAoIZGF0ZXRpbWUYEy'
    'ABKAsyEi5tb250eS52MS5EYXRlVGltZUgAUghkYXRldGltZRIzCgl0aW1lZGVsdGEYFCABKAsy'
    'Ey5tb250eS52MS5UaW1lRGVsdGFIAFIJdGltZWRlbHRhEjAKCHRpbWV6b25lGBUgASgLMhIubW'
    '9udHkudjEuVGltZVpvbmVIAFIIdGltZXpvbmUSMwoJZXhjZXB0aW9uGBYgASgLMhMubW9udHku'
    'djEuRXhjZXB0aW9uSABSCWV4Y2VwdGlvbhIkCgR0eXBlGBcgASgLMg4ubW9udHkudjEuVHlwZU'
    'gAUgR0eXBlEkQKDmNsYXNzX2luc3RhbmNlGBggASgLMhsubW9udHkudjEuQ2xhc3NJbnN0YW5j'
    'ZU5vZGVIAFINY2xhc3NJbnN0YW5jZRIwCghmdW5jdGlvbhgZIAEoCzISLm1vbnR5LnYxLkZ1bm'
    'N0aW9uSABSCGZ1bmN0aW9uEisKEGJ1aWx0aW5fZnVuY3Rpb24YGiABKAlIAFIPYnVpbHRpbkZ1'
    'bmN0aW9uEhQKBHBhdGgYGyABKAlIAFIEcGF0aBI3CgtmaWxlX2hhbmRsZRgcIAEoCzIULm1vbn'
    'R5LnYxLkZpbGVIYW5kbGVIAFIKZmlsZUhhbmRsZRIUCgRyZXByGB0gASgJSABSBHJlcHISFgoF'
    'Y3ljbGUYHiABKAlIAFIFY3ljbGUSLQoHY29tcGxleBgfIAEoCzIRLm1vbnR5LnYxLkNvbXBsZX'
    'hIAFIHY29tcGxleEIGCgRraW5k');

@$core.Deprecated('Use indexesDescriptor instead')
const Indexes$json = {
  '1': 'Indexes',
  '2': [
    {'1': 'items', '3': 1, '4': 3, '5': 13, '10': 'items'},
  ],
};

/// Descriptor for `Indexes`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List indexesDescriptor =
    $convert.base64Decode('CgdJbmRleGVzEhQKBWl0ZW1zGAEgAygNUgVpdGVtcw==');

@$core.Deprecated('Use nodePairDescriptor instead')
const NodePair$json = {
  '1': 'NodePair',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 13, '10': 'key'},
    {'1': 'value', '3': 2, '4': 1, '5': 13, '10': 'value'},
  ],
};

/// Descriptor for `NodePair`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List nodePairDescriptor = $convert.base64Decode(
    'CghOb2RlUGFpchIQCgNrZXkYASABKA1SA2tleRIUCgV2YWx1ZRgCIAEoDVIFdmFsdWU=');

@$core.Deprecated('Use nodePairsDescriptor instead')
const NodePairs$json = {
  '1': 'NodePairs',
  '2': [
    {
      '1': 'pairs',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.NodePair',
      '10': 'pairs'
    },
  ],
};

/// Descriptor for `NodePairs`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List nodePairsDescriptor = $convert.base64Decode(
    'CglOb2RlUGFpcnMSKAoFcGFpcnMYASADKAsyEi5tb250eS52MS5Ob2RlUGFpclIFcGFpcnM=');

@$core.Deprecated('Use bigIntDescriptor instead')
const BigInt$json = {
  '1': 'BigInt',
  '2': [
    {'1': 'negative', '3': 1, '4': 1, '5': 8, '10': 'negative'},
    {'1': 'magnitude', '3': 2, '4': 1, '5': 12, '10': 'magnitude'},
  ],
};

/// Descriptor for `BigInt`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List bigIntDescriptor = $convert.base64Decode(
    'CgZCaWdJbnQSGgoIbmVnYXRpdmUYASABKAhSCG5lZ2F0aXZlEhwKCW1hZ25pdHVkZRgCIAEoDF'
    'IJbWFnbml0dWRl');

@$core.Deprecated('Use complexDescriptor instead')
const Complex$json = {
  '1': 'Complex',
  '2': [
    {'1': 'real', '3': 1, '4': 1, '5': 1, '9': 0, '10': 'real', '17': true},
    {'1': 'imag', '3': 2, '4': 1, '5': 1, '9': 1, '10': 'imag', '17': true},
  ],
  '8': [
    {'1': '_real'},
    {'1': '_imag'},
  ],
};

/// Descriptor for `Complex`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List complexDescriptor = $convert.base64Decode(
    'CgdDb21wbGV4EhcKBHJlYWwYASABKAFIAFIEcmVhbIgBARIXCgRpbWFnGAIgASgBSAFSBGltYW'
    'eIAQFCBwoFX3JlYWxCBwoFX2ltYWc=');

@$core.Deprecated('Use namedTupleNodeDescriptor instead')
const NamedTupleNode$json = {
  '1': 'NamedTupleNode',
  '2': [
    {'1': 'type_name', '3': 1, '4': 1, '5': 9, '10': 'typeName'},
    {'1': 'field_names', '3': 2, '4': 3, '5': 9, '10': 'fieldNames'},
    {'1': 'values', '3': 3, '4': 3, '5': 13, '10': 'values'},
  ],
};

/// Descriptor for `NamedTupleNode`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List namedTupleNodeDescriptor = $convert.base64Decode(
    'Cg5OYW1lZFR1cGxlTm9kZRIbCgl0eXBlX25hbWUYASABKAlSCHR5cGVOYW1lEh8KC2ZpZWxkX2'
    '5hbWVzGAIgAygJUgpmaWVsZE5hbWVzEhYKBnZhbHVlcxgDIAMoDVIGdmFsdWVz');

@$core.Deprecated('Use dateDescriptor instead')
const Date$json = {
  '1': 'Date',
  '2': [
    {'1': 'year', '3': 1, '4': 1, '5': 5, '10': 'year'},
    {'1': 'month', '3': 2, '4': 1, '5': 13, '10': 'month'},
    {'1': 'day', '3': 3, '4': 1, '5': 13, '10': 'day'},
  ],
};

/// Descriptor for `Date`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dateDescriptor = $convert.base64Decode(
    'CgREYXRlEhIKBHllYXIYASABKAVSBHllYXISFAoFbW9udGgYAiABKA1SBW1vbnRoEhAKA2RheR'
    'gDIAEoDVIDZGF5');

@$core.Deprecated('Use dateTimeDescriptor instead')
const DateTime$json = {
  '1': 'DateTime',
  '2': [
    {'1': 'year', '3': 1, '4': 1, '5': 5, '10': 'year'},
    {'1': 'month', '3': 2, '4': 1, '5': 13, '10': 'month'},
    {'1': 'day', '3': 3, '4': 1, '5': 13, '10': 'day'},
    {'1': 'hour', '3': 4, '4': 1, '5': 13, '10': 'hour'},
    {'1': 'minute', '3': 5, '4': 1, '5': 13, '10': 'minute'},
    {'1': 'second', '3': 6, '4': 1, '5': 13, '10': 'second'},
    {'1': 'microsecond', '3': 7, '4': 1, '5': 13, '10': 'microsecond'},
    {
      '1': 'offset_seconds',
      '3': 8,
      '4': 1,
      '5': 5,
      '9': 0,
      '10': 'offsetSeconds',
      '17': true
    },
    {
      '1': 'timezone_name',
      '3': 9,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'timezoneName',
      '17': true
    },
  ],
  '8': [
    {'1': '_offset_seconds'},
    {'1': '_timezone_name'},
  ],
};

/// Descriptor for `DateTime`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dateTimeDescriptor = $convert.base64Decode(
    'CghEYXRlVGltZRISCgR5ZWFyGAEgASgFUgR5ZWFyEhQKBW1vbnRoGAIgASgNUgVtb250aBIQCg'
    'NkYXkYAyABKA1SA2RheRISCgRob3VyGAQgASgNUgRob3VyEhYKBm1pbnV0ZRgFIAEoDVIGbWlu'
    'dXRlEhYKBnNlY29uZBgGIAEoDVIGc2Vjb25kEiAKC21pY3Jvc2Vjb25kGAcgASgNUgttaWNyb3'
    'NlY29uZBIqCg5vZmZzZXRfc2Vjb25kcxgIIAEoBUgAUg1vZmZzZXRTZWNvbmRziAEBEigKDXRp'
    'bWV6b25lX25hbWUYCSABKAlIAVIMdGltZXpvbmVOYW1liAEBQhEKD19vZmZzZXRfc2Vjb25kc0'
    'IQCg5fdGltZXpvbmVfbmFtZQ==');

@$core.Deprecated('Use timeDescriptor instead')
const Time$json = {
  '1': 'Time',
  '2': [
    {'1': 'hour', '3': 1, '4': 1, '5': 13, '10': 'hour'},
    {'1': 'minute', '3': 2, '4': 1, '5': 13, '10': 'minute'},
    {'1': 'second', '3': 3, '4': 1, '5': 13, '10': 'second'},
    {'1': 'microsecond', '3': 4, '4': 1, '5': 13, '10': 'microsecond'},
    {
      '1': 'offset_seconds',
      '3': 5,
      '4': 1,
      '5': 5,
      '9': 0,
      '10': 'offsetSeconds',
      '17': true
    },
    {
      '1': 'timezone_name',
      '3': 6,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'timezoneName',
      '17': true
    },
    {'1': 'fold', '3': 7, '4': 1, '5': 13, '10': 'fold'},
  ],
  '8': [
    {'1': '_offset_seconds'},
    {'1': '_timezone_name'},
  ],
};

/// Descriptor for `Time`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List timeDescriptor = $convert.base64Decode(
    'CgRUaW1lEhIKBGhvdXIYASABKA1SBGhvdXISFgoGbWludXRlGAIgASgNUgZtaW51dGUSFgoGc2'
    'Vjb25kGAMgASgNUgZzZWNvbmQSIAoLbWljcm9zZWNvbmQYBCABKA1SC21pY3Jvc2Vjb25kEioK'
    'Dm9mZnNldF9zZWNvbmRzGAUgASgFSABSDW9mZnNldFNlY29uZHOIAQESKAoNdGltZXpvbmVfbm'
    'FtZRgGIAEoCUgBUgx0aW1lem9uZU5hbWWIAQESEgoEZm9sZBgHIAEoDVIEZm9sZEIRCg9fb2Zm'
    'c2V0X3NlY29uZHNCEAoOX3RpbWV6b25lX25hbWU=');

@$core.Deprecated('Use timeDeltaDescriptor instead')
const TimeDelta$json = {
  '1': 'TimeDelta',
  '2': [
    {'1': 'days', '3': 1, '4': 1, '5': 5, '10': 'days'},
    {'1': 'seconds', '3': 2, '4': 1, '5': 5, '10': 'seconds'},
    {'1': 'microseconds', '3': 3, '4': 1, '5': 5, '10': 'microseconds'},
  ],
};

/// Descriptor for `TimeDelta`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List timeDeltaDescriptor = $convert.base64Decode(
    'CglUaW1lRGVsdGESEgoEZGF5cxgBIAEoBVIEZGF5cxIYCgdzZWNvbmRzGAIgASgFUgdzZWNvbm'
    'RzEiIKDG1pY3Jvc2Vjb25kcxgDIAEoBVIMbWljcm9zZWNvbmRz');

@$core.Deprecated('Use timeZoneDescriptor instead')
const TimeZone$json = {
  '1': 'TimeZone',
  '2': [
    {'1': 'offset_seconds', '3': 1, '4': 1, '5': 5, '10': 'offsetSeconds'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'name', '17': true},
  ],
  '8': [
    {'1': '_name'},
  ],
};

/// Descriptor for `TimeZone`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List timeZoneDescriptor = $convert.base64Decode(
    'CghUaW1lWm9uZRIlCg5vZmZzZXRfc2Vjb25kcxgBIAEoBVINb2Zmc2V0U2Vjb25kcxIXCgRuYW'
    '1lGAIgASgJSABSBG5hbWWIAQFCBwoFX25hbWU=');

@$core.Deprecated('Use exceptionDescriptor instead')
const Exception$json = {
  '1': 'Exception',
  '2': [
    {'1': 'exc_type', '3': 1, '4': 1, '5': 9, '10': 'excType'},
    {'1': 'arg', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'arg', '17': true},
  ],
  '8': [
    {'1': '_arg'},
  ],
};

/// Descriptor for `Exception`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List exceptionDescriptor = $convert.base64Decode(
    'CglFeGNlcHRpb24SGQoIZXhjX3R5cGUYASABKAlSB2V4Y1R5cGUSFQoDYXJnGAIgASgJSABSA2'
    'FyZ4gBAUIGCgRfYXJn');

@$core.Deprecated('Use fileHandleDescriptor instead')
const FileHandle$json = {
  '1': 'FileHandle',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'mode', '3': 2, '4': 1, '5': 9, '10': 'mode'},
    {'1': 'position', '3': 3, '4': 1, '5': 4, '10': 'position'},
  ],
};

/// Descriptor for `FileHandle`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fileHandleDescriptor = $convert.base64Decode(
    'CgpGaWxlSGFuZGxlEhIKBHBhdGgYASABKAlSBHBhdGgSEgoEbW9kZRgCIAEoCVIEbW9kZRIaCg'
    'hwb3NpdGlvbhgDIAEoBFIIcG9zaXRpb24=');

@$core.Deprecated('Use uuidDescriptor instead')
const Uuid$json = {
  '1': 'Uuid',
  '2': [
    {'1': 'data', '3': 1, '4': 1, '5': 12, '10': 'data'},
  ],
};

/// Descriptor for `Uuid`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List uuidDescriptor =
    $convert.base64Decode('CgRVdWlkEhIKBGRhdGEYASABKAxSBGRhdGE=');

@$core.Deprecated('Use typeDescriptor instead')
const Type$json = {
  '1': 'Type',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'id', '3': 2, '4': 1, '5': 11, '6': '.monty.v1.Uuid', '10': 'id'},
    {
      '1': 'origin',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.monty.v1.TypeOrigin',
      '10': 'origin'
    },
    {'1': 'is_dataclass', '3': 4, '4': 1, '5': 8, '10': 'isDataclass'},
    {
      '1': 'attrs',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.NodePairs',
      '10': 'attrs'
    },
  ],
};

/// Descriptor for `Type`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List typeDescriptor = $convert.base64Decode(
    'CgRUeXBlEhIKBG5hbWUYASABKAlSBG5hbWUSHgoCaWQYAiABKAsyDi5tb250eS52MS5VdWlkUg'
    'JpZBIsCgZvcmlnaW4YAyABKA4yFC5tb250eS52MS5UeXBlT3JpZ2luUgZvcmlnaW4SIQoMaXNf'
    'ZGF0YWNsYXNzGAQgASgIUgtpc0RhdGFjbGFzcxIpCgVhdHRycxgFIAEoCzITLm1vbnR5LnYxLk'
    '5vZGVQYWlyc1IFYXR0cnM=');

@$core.Deprecated('Use classInstanceNodeDescriptor instead')
const ClassInstanceNode$json = {
  '1': 'ClassInstanceNode',
  '2': [
    {'1': 'class_type', '3': 1, '4': 1, '5': 13, '10': 'classType'},
    {
      '1': 'instance_id',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Uuid',
      '10': 'instanceId'
    },
    {
      '1': 'attrs',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.NodePairs',
      '10': 'attrs'
    },
  ],
};

/// Descriptor for `ClassInstanceNode`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List classInstanceNodeDescriptor = $convert.base64Decode(
    'ChFDbGFzc0luc3RhbmNlTm9kZRIdCgpjbGFzc190eXBlGAEgASgNUgljbGFzc1R5cGUSLwoLaW'
    '5zdGFuY2VfaWQYAiABKAsyDi5tb250eS52MS5VdWlkUgppbnN0YW5jZUlkEikKBWF0dHJzGAMg'
    'ASgLMhMubW9udHkudjEuTm9kZVBhaXJzUgVhdHRycw==');

@$core.Deprecated('Use function_Descriptor instead')
const Function_$json = {
  '1': 'Function',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'docstring',
      '3': 2,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'docstring',
      '17': true
    },
  ],
  '8': [
    {'1': '_docstring'},
  ],
};

/// Descriptor for `Function`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List function_Descriptor = $convert.base64Decode(
    'CghGdW5jdGlvbhISCgRuYW1lGAEgASgJUgRuYW1lEiEKCWRvY3N0cmluZxgCIAEoCUgAUglkb2'
    'NzdHJpbmeIAQFCDAoKX2RvY3N0cmluZw==');

@$core.Deprecated('Use raisedExceptionDescriptor instead')
const RaisedException$json = {
  '1': 'RaisedException',
  '2': [
    {'1': 'exc_type', '3': 1, '4': 1, '5': 9, '10': 'excType'},
    {
      '1': 'message',
      '3': 2,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'message',
      '17': true
    },
    {
      '1': 'traceback',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.StackFrame',
      '10': 'traceback'
    },
    {
      '1': 'data',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ExcData',
      '10': 'data'
    },
  ],
  '8': [
    {'1': '_message'},
  ],
};

/// Descriptor for `RaisedException`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List raisedExceptionDescriptor = $convert.base64Decode(
    'Cg9SYWlzZWRFeGNlcHRpb24SGQoIZXhjX3R5cGUYASABKAlSB2V4Y1R5cGUSHQoHbWVzc2FnZR'
    'gCIAEoCUgAUgdtZXNzYWdliAEBEjIKCXRyYWNlYmFjaxgDIAMoCzIULm1vbnR5LnYxLlN0YWNr'
    'RnJhbWVSCXRyYWNlYmFjaxIlCgRkYXRhGAQgASgLMhEubW9udHkudjEuRXhjRGF0YVIEZGF0YU'
    'IKCghfbWVzc2FnZQ==');

@$core.Deprecated('Use excDataDescriptor instead')
const ExcData$json = {
  '1': 'ExcData',
  '2': [
    {
      '1': 'unicode',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.UnicodeErrorData',
      '9': 0,
      '10': 'unicode'
    },
    {
      '1': 'json',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.JsonErrorData',
      '9': 0,
      '10': 'json'
    },
  ],
  '8': [
    {'1': 'kind'},
  ],
};

/// Descriptor for `ExcData`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List excDataDescriptor = $convert.base64Decode(
    'CgdFeGNEYXRhEjYKB3VuaWNvZGUYASABKAsyGi5tb250eS52MS5Vbmljb2RlRXJyb3JEYXRhSA'
    'BSB3VuaWNvZGUSLQoEanNvbhgCIAEoCzIXLm1vbnR5LnYxLkpzb25FcnJvckRhdGFIAFIEanNv'
    'bkIGCgRraW5k');

@$core.Deprecated('Use unicodeErrorDataDescriptor instead')
const UnicodeErrorData$json = {
  '1': 'UnicodeErrorData',
  '2': [
    {'1': 'encoding', '3': 1, '4': 1, '5': 9, '10': 'encoding'},
    {'1': 'object_bytes', '3': 2, '4': 1, '5': 12, '9': 0, '10': 'objectBytes'},
    {'1': 'object_str', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'objectStr'},
    {'1': 'start', '3': 4, '4': 1, '5': 4, '10': 'start'},
    {'1': 'end', '3': 5, '4': 1, '5': 4, '10': 'end'},
    {'1': 'reason', '3': 6, '4': 1, '5': 9, '10': 'reason'},
  ],
  '8': [
    {'1': 'object'},
  ],
};

/// Descriptor for `UnicodeErrorData`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List unicodeErrorDataDescriptor = $convert.base64Decode(
    'ChBVbmljb2RlRXJyb3JEYXRhEhoKCGVuY29kaW5nGAEgASgJUghlbmNvZGluZxIjCgxvYmplY3'
    'RfYnl0ZXMYAiABKAxIAFILb2JqZWN0Qnl0ZXMSHwoKb2JqZWN0X3N0chgDIAEoCUgAUglvYmpl'
    'Y3RTdHISFAoFc3RhcnQYBCABKARSBXN0YXJ0EhAKA2VuZBgFIAEoBFIDZW5kEhYKBnJlYXNvbh'
    'gGIAEoCVIGcmVhc29uQggKBm9iamVjdA==');

@$core.Deprecated('Use jsonErrorDataDescriptor instead')
const JsonErrorData$json = {
  '1': 'JsonErrorData',
  '2': [
    {'1': 'msg', '3': 1, '4': 1, '5': 9, '10': 'msg'},
    {'1': 'doc', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'doc', '17': true},
    {'1': 'pos', '3': 3, '4': 1, '5': 4, '10': 'pos'},
    {'1': 'lineno', '3': 4, '4': 1, '5': 4, '10': 'lineno'},
    {'1': 'colno', '3': 5, '4': 1, '5': 4, '10': 'colno'},
  ],
  '8': [
    {'1': '_doc'},
  ],
};

/// Descriptor for `JsonErrorData`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List jsonErrorDataDescriptor = $convert.base64Decode(
    'Cg1Kc29uRXJyb3JEYXRhEhAKA21zZxgBIAEoCVIDbXNnEhUKA2RvYxgCIAEoCUgAUgNkb2OIAQ'
    'ESEAoDcG9zGAMgASgEUgNwb3MSFgoGbGluZW5vGAQgASgEUgZsaW5lbm8SFAoFY29sbm8YBSAB'
    'KARSBWNvbG5vQgYKBF9kb2M=');

@$core.Deprecated('Use codeLocDescriptor instead')
const CodeLoc$json = {
  '1': 'CodeLoc',
  '2': [
    {'1': 'line', '3': 1, '4': 1, '5': 13, '10': 'line'},
    {'1': 'column', '3': 2, '4': 1, '5': 13, '10': 'column'},
  ],
};

/// Descriptor for `CodeLoc`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List codeLocDescriptor = $convert.base64Decode(
    'CgdDb2RlTG9jEhIKBGxpbmUYASABKA1SBGxpbmUSFgoGY29sdW1uGAIgASgNUgZjb2x1bW4=');

@$core.Deprecated('Use sourceRangeDescriptor instead')
const SourceRange$json = {
  '1': 'SourceRange',
  '2': [
    {'1': 'filename', '3': 1, '4': 1, '5': 9, '10': 'filename'},
    {'1': 'start', '3': 2, '4': 1, '5': 13, '10': 'start'},
    {'1': 'end', '3': 3, '4': 1, '5': 13, '10': 'end'},
  ],
};

/// Descriptor for `SourceRange`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sourceRangeDescriptor = $convert.base64Decode(
    'CgtTb3VyY2VSYW5nZRIaCghmaWxlbmFtZRgBIAEoCVIIZmlsZW5hbWUSFAoFc3RhcnQYAiABKA'
    '1SBXN0YXJ0EhAKA2VuZBgDIAEoDVIDZW5k');

@$core.Deprecated('Use stackFrameDescriptor instead')
const StackFrame$json = {
  '1': 'StackFrame',
  '2': [
    {'1': 'filename', '3': 1, '4': 1, '5': 9, '10': 'filename'},
    {
      '1': 'start',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.CodeLoc',
      '10': 'start'
    },
    {
      '1': 'end',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.CodeLoc',
      '10': 'end'
    },
    {
      '1': 'frame_name',
      '3': 4,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'frameName',
      '17': true
    },
    {
      '1': 'preview_line',
      '3': 5,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'previewLine',
      '17': true
    },
    {'1': 'hide_caret', '3': 6, '4': 1, '5': 8, '10': 'hideCaret'},
    {'1': 'hide_frame_name', '3': 7, '4': 1, '5': 8, '10': 'hideFrameName'},
  ],
  '8': [
    {'1': '_frame_name'},
    {'1': '_preview_line'},
  ],
};

/// Descriptor for `StackFrame`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List stackFrameDescriptor = $convert.base64Decode(
    'CgpTdGFja0ZyYW1lEhoKCGZpbGVuYW1lGAEgASgJUghmaWxlbmFtZRInCgVzdGFydBgCIAEoCz'
    'IRLm1vbnR5LnYxLkNvZGVMb2NSBXN0YXJ0EiMKA2VuZBgDIAEoCzIRLm1vbnR5LnYxLkNvZGVM'
    'b2NSA2VuZBIiCgpmcmFtZV9uYW1lGAQgASgJSABSCWZyYW1lTmFtZYgBARImCgxwcmV2aWV3X2'
    'xpbmUYBSABKAlIAVILcHJldmlld0xpbmWIAQESHQoKaGlkZV9jYXJldBgGIAEoCFIJaGlkZUNh'
    'cmV0EiYKD2hpZGVfZnJhbWVfbmFtZRgHIAEoCFINaGlkZUZyYW1lTmFtZUINCgtfZnJhbWVfbm'
    'FtZUIPCg1fcHJldmlld19saW5l');

@$core.Deprecated('Use resourceLimitsDescriptor instead')
const ResourceLimits$json = {
  '1': 'ResourceLimits',
  '2': [
    {
      '1': 'max_memory_bytes',
      '3': 2,
      '4': 1,
      '5': 4,
      '9': 0,
      '10': 'maxMemoryBytes',
      '17': true
    },
    {
      '1': 'gc_interval',
      '3': 3,
      '4': 1,
      '5': 4,
      '9': 1,
      '10': 'gcInterval',
      '17': true
    },
    {
      '1': 'max_recursion_depth',
      '3': 4,
      '4': 1,
      '5': 4,
      '9': 2,
      '10': 'maxRecursionDepth',
      '17': true
    },
    {
      '1': 'max_suspensions',
      '3': 5,
      '4': 1,
      '5': 4,
      '9': 3,
      '10': 'maxSuspensions',
      '17': true
    },
    {
      '1': 'max_feed_duration_micros',
      '3': 6,
      '4': 1,
      '5': 4,
      '9': 4,
      '10': 'maxFeedDurationMicros',
      '17': true
    },
    {
      '1': 'max_turn_duration_micros',
      '3': 7,
      '4': 1,
      '5': 4,
      '9': 5,
      '10': 'maxTurnDurationMicros',
      '17': true
    },
    {
      '1': 'max_total_sleep_micros',
      '3': 8,
      '4': 1,
      '5': 4,
      '9': 6,
      '10': 'maxTotalSleepMicros',
      '17': true
    },
  ],
  '8': [
    {'1': '_max_memory_bytes'},
    {'1': '_gc_interval'},
    {'1': '_max_recursion_depth'},
    {'1': '_max_suspensions'},
    {'1': '_max_feed_duration_micros'},
    {'1': '_max_turn_duration_micros'},
    {'1': '_max_total_sleep_micros'},
  ],
  '9': [
    {'1': 1, '2': 2},
  ],
};

/// Descriptor for `ResourceLimits`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resourceLimitsDescriptor = $convert.base64Decode(
    'Cg5SZXNvdXJjZUxpbWl0cxItChBtYXhfbWVtb3J5X2J5dGVzGAIgASgESABSDm1heE1lbW9yeU'
    'J5dGVziAEBEiQKC2djX2ludGVydmFsGAMgASgESAFSCmdjSW50ZXJ2YWyIAQESMwoTbWF4X3Jl'
    'Y3Vyc2lvbl9kZXB0aBgEIAEoBEgCUhFtYXhSZWN1cnNpb25EZXB0aIgBARIsCg9tYXhfc3VzcG'
    'Vuc2lvbnMYBSABKARIA1IObWF4U3VzcGVuc2lvbnOIAQESPAoYbWF4X2ZlZWRfZHVyYXRpb25f'
    'bWljcm9zGAYgASgESARSFW1heEZlZWREdXJhdGlvbk1pY3Jvc4gBARI8ChhtYXhfdHVybl9kdX'
    'JhdGlvbl9taWNyb3MYByABKARIBVIVbWF4VHVybkR1cmF0aW9uTWljcm9ziAEBEjgKFm1heF90'
    'b3RhbF9zbGVlcF9taWNyb3MYCCABKARIBlITbWF4VG90YWxTbGVlcE1pY3Jvc4gBAUITChFfbW'
    'F4X21lbW9yeV9ieXRlc0IOCgxfZ2NfaW50ZXJ2YWxCFgoUX21heF9yZWN1cnNpb25fZGVwdGhC'
    'EgoQX21heF9zdXNwZW5zaW9uc0IbChlfbWF4X2ZlZWRfZHVyYXRpb25fbWljcm9zQhsKGV9tYX'
    'hfdHVybl9kdXJhdGlvbl9taWNyb3NCGQoXX21heF90b3RhbF9zbGVlcF9taWNyb3NKBAgBEAI=');

@$core.Deprecated('Use osPolicyDescriptor instead')
const OsPolicy$json = {
  '1': 'OsPolicy',
  '2': [
    {
      '1': 'system',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'system'
    },
    {
      '1': 'call_host',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'callHost'
    },
    {
      '1': 'fixed',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.FixedDateTime',
      '9': 0,
      '10': 'fixed'
    },
    {
      '1': 'timezone',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SandboxTimeZone',
      '10': 'timezone'
    },
    {
      '1': 'sleep',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SleepMode',
      '10': 'sleep'
    },
    {
      '1': 'random_system',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 1,
      '10': 'randomSystem'
    },
    {
      '1': 'random_call_host',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 1,
      '10': 'randomCallHost'
    },
    {
      '1': 'seed',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.RandomSeed',
      '9': 1,
      '10': 'seed'
    },
    {
      '1': 'zero',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 2,
      '10': 'zero'
    },
    {
      '1': 'elapsed',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 2,
      '10': 'elapsed'
    },
  ],
  '8': [
    {'1': 'datetime'},
    {'1': 'random_start'},
    {'1': 'process_time'},
  ],
};

/// Descriptor for `OsPolicy`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List osPolicyDescriptor = $convert.base64Decode(
    'CghPc1BvbGljeRIoCgZzeXN0ZW0YASABKAsyDi5tb250eS52MS5Vbml0SABSBnN5c3RlbRItCg'
    'ljYWxsX2hvc3QYAiABKAsyDi5tb250eS52MS5Vbml0SABSCGNhbGxIb3N0Ei8KBWZpeGVkGAMg'
    'ASgLMhcubW9udHkudjEuRml4ZWREYXRlVGltZUgAUgVmaXhlZBI1Cgh0aW1lem9uZRgEIAEoCz'
    'IZLm1vbnR5LnYxLlNhbmRib3hUaW1lWm9uZVIIdGltZXpvbmUSKQoFc2xlZXAYBSABKAsyEy5t'
    'b250eS52MS5TbGVlcE1vZGVSBXNsZWVwEjUKDXJhbmRvbV9zeXN0ZW0YBiABKAsyDi5tb250eS'
    '52MS5Vbml0SAFSDHJhbmRvbVN5c3RlbRI6ChByYW5kb21fY2FsbF9ob3N0GAcgASgLMg4ubW9u'
    'dHkudjEuVW5pdEgBUg5yYW5kb21DYWxsSG9zdBIqCgRzZWVkGAggASgLMhQubW9udHkudjEuUm'
    'FuZG9tU2VlZEgBUgRzZWVkEiQKBHplcm8YCSABKAsyDi5tb250eS52MS5Vbml0SAJSBHplcm8S'
    'KgoHZWxhcHNlZBgKIAEoCzIOLm1vbnR5LnYxLlVuaXRIAlIHZWxhcHNlZEIKCghkYXRldGltZU'
    'IOCgxyYW5kb21fc3RhcnRCDgoMcHJvY2Vzc190aW1l');

@$core.Deprecated('Use sandboxTimeZoneDescriptor instead')
const SandboxTimeZone$json = {
  '1': 'SandboxTimeZone',
  '2': [
    {
      '1': 'utc',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'utc'
    },
    {'1': 'named', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'named'},
    {
      '1': 'fixed',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.TimeZone',
      '9': 0,
      '10': 'fixed'
    },
  ],
  '8': [
    {'1': 'zone'},
  ],
};

/// Descriptor for `SandboxTimeZone`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sandboxTimeZoneDescriptor = $convert.base64Decode(
    'Cg9TYW5kYm94VGltZVpvbmUSIgoDdXRjGAEgASgLMg4ubW9udHkudjEuVW5pdEgAUgN1dGMSFg'
    'oFbmFtZWQYAiABKAlIAFIFbmFtZWQSKgoFZml4ZWQYAyABKAsyEi5tb250eS52MS5UaW1lWm9u'
    'ZUgAUgVmaXhlZEIGCgR6b25l');

@$core.Deprecated('Use sleepModeDescriptor instead')
const SleepMode$json = {
  '1': 'SleepMode',
  '2': [
    {
      '1': 'system',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SystemSleep',
      '9': 0,
      '10': 'system'
    },
    {
      '1': 'call_host',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'callHost'
    },
    {
      '1': 'zero',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'zero'
    },
  ],
  '8': [
    {'1': 'mode'},
  ],
};

/// Descriptor for `SleepMode`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List sleepModeDescriptor = $convert.base64Decode(
    'CglTbGVlcE1vZGUSLwoGc3lzdGVtGAEgASgLMhUubW9udHkudjEuU3lzdGVtU2xlZXBIAFIGc3'
    'lzdGVtEi0KCWNhbGxfaG9zdBgCIAEoCzIOLm1vbnR5LnYxLlVuaXRIAFIIY2FsbEhvc3QSJAoE'
    'emVybxgDIAEoCzIOLm1vbnR5LnYxLlVuaXRIAFIEemVyb0IGCgRtb2Rl');

@$core.Deprecated('Use systemSleepDescriptor instead')
const SystemSleep$json = {
  '1': 'SystemSleep',
  '2': [
    {
      '1': 'max_micros',
      '3': 1,
      '4': 1,
      '5': 4,
      '9': 0,
      '10': 'maxMicros',
      '17': true
    },
  ],
  '8': [
    {'1': '_max_micros'},
  ],
};

/// Descriptor for `SystemSleep`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List systemSleepDescriptor = $convert.base64Decode(
    'CgtTeXN0ZW1TbGVlcBIiCgptYXhfbWljcm9zGAEgASgESABSCW1heE1pY3Jvc4gBAUINCgtfbW'
    'F4X21pY3Jvcw==');

@$core.Deprecated('Use fixedDateTimeDescriptor instead')
const FixedDateTime$json = {
  '1': 'FixedDateTime',
  '2': [
    {'1': 'unix_seconds', '3': 1, '4': 1, '5': 3, '10': 'unixSeconds'},
    {'1': 'microsecond', '3': 2, '4': 1, '5': 13, '10': 'microsecond'},
  ],
};

/// Descriptor for `FixedDateTime`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fixedDateTimeDescriptor = $convert.base64Decode(
    'Cg1GaXhlZERhdGVUaW1lEiEKDHVuaXhfc2Vjb25kcxgBIAEoA1ILdW5peFNlY29uZHMSIAoLbW'
    'ljcm9zZWNvbmQYAiABKA1SC21pY3Jvc2Vjb25k');

@$core.Deprecated('Use randomSeedDescriptor instead')
const RandomSeed$json = {
  '1': 'RandomSeed',
  '2': [
    {'1': 'int', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'int'},
    {'1': 'float', '3': 2, '4': 1, '5': 1, '9': 0, '10': 'float'},
    {'1': 'str', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'str'},
    {'1': 'bytes', '3': 4, '4': 1, '5': 12, '9': 0, '10': 'bytes'},
  ],
  '8': [
    {'1': 'value'},
  ],
};

/// Descriptor for `RandomSeed`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List randomSeedDescriptor = $convert.base64Decode(
    'CgpSYW5kb21TZWVkEhIKA2ludBgBIAEoDEgAUgNpbnQSFgoFZmxvYXQYAiABKAFIAFIFZmxvYX'
    'QSEgoDc3RyGAMgASgJSABSA3N0chIWCgVieXRlcxgEIAEoDEgAUgVieXRlc0IHCgV2YWx1ZQ==');

@$core.Deprecated('Use extFunctionResultDescriptor instead')
const ExtFunctionResult$json = {
  '1': 'ExtFunctionResult',
  '2': [
    {'1': 'return_value', '3': 1, '4': 1, '5': 13, '9': 0, '10': 'returnValue'},
    {
      '1': 'error',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.RaisedException',
      '9': 0,
      '10': 'error'
    },
    {'1': 'future', '3': 3, '4': 1, '5': 13, '9': 0, '10': 'future'},
    {'1': 'not_found', '3': 4, '4': 1, '5': 9, '9': 0, '10': 'notFound'},
    {
      '1': 'not_handled',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'notHandled'
    },
  ],
  '8': [
    {'1': 'kind'},
  ],
};

/// Descriptor for `ExtFunctionResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List extFunctionResultDescriptor = $convert.base64Decode(
    'ChFFeHRGdW5jdGlvblJlc3VsdBIjCgxyZXR1cm5fdmFsdWUYASABKA1IAFILcmV0dXJuVmFsdW'
    'USMQoFZXJyb3IYAiABKAsyGS5tb250eS52MS5SYWlzZWRFeGNlcHRpb25IAFIFZXJyb3ISGAoG'
    'ZnV0dXJlGAMgASgNSABSBmZ1dHVyZRIdCglub3RfZm91bmQYBCABKAlIAFIIbm90Rm91bmQSMQ'
    'oLbm90X2hhbmRsZWQYBSABKAsyDi5tb250eS52MS5Vbml0SABSCm5vdEhhbmRsZWRCBgoEa2lu'
    'ZA==');

@$core.Deprecated('Use futureResultDescriptor instead')
const FutureResult$json = {
  '1': 'FutureResult',
  '2': [
    {'1': 'call_id', '3': 1, '4': 1, '5': 13, '10': 'callId'},
    {
      '1': 'result',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ExtFunctionResult',
      '10': 'result'
    },
  ],
};

/// Descriptor for `FutureResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List futureResultDescriptor = $convert.base64Decode(
    'CgxGdXR1cmVSZXN1bHQSFwoHY2FsbF9pZBgBIAEoDVIGY2FsbElkEjMKBnJlc3VsdBgCIAEoCz'
    'IbLm1vbnR5LnYxLkV4dEZ1bmN0aW9uUmVzdWx0UgZyZXN1bHQ=');

@$core.Deprecated('Use namedRefDescriptor instead')
const NamedRef$json = {
  '1': 'NamedRef',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {'1': 'value', '3': 2, '4': 1, '5': 13, '10': 'value'},
  ],
};

/// Descriptor for `NamedRef`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List namedRefDescriptor = $convert.base64Decode(
    'CghOYW1lZFJlZhISCgRuYW1lGAEgASgJUgRuYW1lEhQKBXZhbHVlGAIgASgNUgV2YWx1ZQ==');

@$core.Deprecated('Use parentRequestDescriptor instead')
const ParentRequest$json = {
  '1': 'ParentRequest',
  '2': [
    {
      '1': 'configure',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Configure',
      '9': 0,
      '10': 'configure'
    },
    {
      '1': 'install_dependencies',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.InstallDependencies',
      '9': 0,
      '10': 'installDependencies'
    },
    {
      '1': 'feed',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Feed',
      '9': 0,
      '10': 'feed'
    },
    {
      '1': 'resume_call',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ResumeCall',
      '9': 0,
      '10': 'resumeCall'
    },
    {
      '1': 'resume_name_lookup',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ResumeNameLookup',
      '9': 0,
      '10': 'resumeNameLookup'
    },
    {
      '1': 'resume_futures',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ResumeFutures',
      '9': 0,
      '10': 'resumeFutures'
    },
    {
      '1': 'dump',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Dump',
      '9': 0,
      '10': 'dump'
    },
    {
      '1': 'load',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Load',
      '9': 0,
      '10': 'load'
    },
    {
      '1': 'reset',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Reset',
      '9': 0,
      '10': 'reset'
    },
    {
      '1': 'shutdown',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Shutdown',
      '9': 0,
      '10': 'shutdown'
    },
    {
      '1': 'abort_feed',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.AbortFeed',
      '9': 0,
      '10': 'abortFeed'
    },
    {
      '1': 'trace_parent',
      '3': 20,
      '4': 1,
      '5': 9,
      '9': 1,
      '10': 'traceParent',
      '17': true
    },
  ],
  '8': [
    {'1': 'kind'},
    {'1': '_trace_parent'},
  ],
};

/// Descriptor for `ParentRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List parentRequestDescriptor = $convert.base64Decode(
    'Cg1QYXJlbnRSZXF1ZXN0EjMKCWNvbmZpZ3VyZRgBIAEoCzITLm1vbnR5LnYxLkNvbmZpZ3VyZU'
    'gAUgljb25maWd1cmUSUgoUaW5zdGFsbF9kZXBlbmRlbmNpZXMYAiABKAsyHS5tb250eS52MS5J'
    'bnN0YWxsRGVwZW5kZW5jaWVzSABSE2luc3RhbGxEZXBlbmRlbmNpZXMSJAoEZmVlZBgDIAEoCz'
    'IOLm1vbnR5LnYxLkZlZWRIAFIEZmVlZBI3CgtyZXN1bWVfY2FsbBgEIAEoCzIULm1vbnR5LnYx'
    'LlJlc3VtZUNhbGxIAFIKcmVzdW1lQ2FsbBJKChJyZXN1bWVfbmFtZV9sb29rdXAYBSABKAsyGi'
    '5tb250eS52MS5SZXN1bWVOYW1lTG9va3VwSABSEHJlc3VtZU5hbWVMb29rdXASQAoOcmVzdW1l'
    'X2Z1dHVyZXMYBiABKAsyFy5tb250eS52MS5SZXN1bWVGdXR1cmVzSABSDXJlc3VtZUZ1dHVyZX'
    'MSJAoEZHVtcBgHIAEoCzIOLm1vbnR5LnYxLkR1bXBIAFIEZHVtcBIkCgRsb2FkGAggASgLMg4u'
    'bW9udHkudjEuTG9hZEgAUgRsb2FkEicKBXJlc2V0GAkgASgLMg8ubW9udHkudjEuUmVzZXRIAF'
    'IFcmVzZXQSMAoIc2h1dGRvd24YCiABKAsyEi5tb250eS52MS5TaHV0ZG93bkgAUghzaHV0ZG93'
    'bhI0CgphYm9ydF9mZWVkGAsgASgLMhMubW9udHkudjEuQWJvcnRGZWVkSABSCWFib3J0RmVlZB'
    'ImCgx0cmFjZV9wYXJlbnQYFCABKAlIAVILdHJhY2VQYXJlbnSIAQFCBgoEa2luZEIPCg1fdHJh'
    'Y2VfcGFyZW50');

@$core.Deprecated('Use configureDescriptor instead')
const Configure$json = {
  '1': 'Configure',
  '2': [
    {'1': 'script_name', '3': 1, '4': 1, '5': 9, '10': 'scriptName'},
    {
      '1': 'limits',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ResourceLimits',
      '10': 'limits'
    },
    {'1': 'type_check', '3': 3, '4': 1, '5': 8, '10': 'typeCheck'},
    {
      '1': 'type_check_stubs',
      '3': 4,
      '4': 1,
      '5': 9,
      '9': 0,
      '10': 'typeCheckStubs',
      '17': true
    },
    {'1': 'monty_version', '3': 5, '4': 1, '5': 9, '10': 'montyVersion'},
    {
      '1': 'assert_message_annotations',
      '3': 6,
      '4': 1,
      '5': 13,
      '9': 1,
      '10': 'assertMessageAnnotations',
      '17': true
    },
    {
      '1': 'type_check_format',
      '3': 7,
      '4': 1,
      '5': 14,
      '6': '.monty.v1.TypeCheckFormat',
      '10': 'typeCheckFormat'
    },
    {'1': 'type_check_color', '3': 8, '4': 1, '5': 8, '10': 'typeCheckColor'},
    {'1': 'protocol_version', '3': 9, '4': 1, '5': 13, '10': 'protocolVersion'},
    {
      '1': 'print_flush_interval_ms',
      '3': 10,
      '4': 1,
      '5': 13,
      '9': 2,
      '10': 'printFlushIntervalMs',
      '17': true
    },
    {
      '1': 'os_policy',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsPolicy',
      '9': 3,
      '10': 'osPolicy',
      '17': true
    },
    {
      '1': 'persistence',
      '3': 12,
      '4': 1,
      '5': 14,
      '6': '.monty.v1.Persistence',
      '10': 'persistence'
    },
    {
      '1': 'profile',
      '3': 13,
      '4': 1,
      '5': 9,
      '9': 4,
      '10': 'profile',
      '17': true
    },
  ],
  '8': [
    {'1': '_type_check_stubs'},
    {'1': '_assert_message_annotations'},
    {'1': '_print_flush_interval_ms'},
    {'1': '_os_policy'},
    {'1': '_profile'},
  ],
};

/// Descriptor for `Configure`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List configureDescriptor = $convert.base64Decode(
    'CglDb25maWd1cmUSHwoLc2NyaXB0X25hbWUYASABKAlSCnNjcmlwdE5hbWUSMAoGbGltaXRzGA'
    'IgASgLMhgubW9udHkudjEuUmVzb3VyY2VMaW1pdHNSBmxpbWl0cxIdCgp0eXBlX2NoZWNrGAMg'
    'ASgIUgl0eXBlQ2hlY2sSLQoQdHlwZV9jaGVja19zdHVicxgEIAEoCUgAUg50eXBlQ2hlY2tTdH'
    'Vic4gBARIjCg1tb250eV92ZXJzaW9uGAUgASgJUgxtb250eVZlcnNpb24SQQoaYXNzZXJ0X21l'
    'c3NhZ2VfYW5ub3RhdGlvbnMYBiABKA1IAVIYYXNzZXJ0TWVzc2FnZUFubm90YXRpb25ziAEBEk'
    'UKEXR5cGVfY2hlY2tfZm9ybWF0GAcgASgOMhkubW9udHkudjEuVHlwZUNoZWNrRm9ybWF0Ug90'
    'eXBlQ2hlY2tGb3JtYXQSKAoQdHlwZV9jaGVja19jb2xvchgIIAEoCFIOdHlwZUNoZWNrQ29sb3'
    'ISKQoQcHJvdG9jb2xfdmVyc2lvbhgJIAEoDVIPcHJvdG9jb2xWZXJzaW9uEjoKF3ByaW50X2Zs'
    'dXNoX2ludGVydmFsX21zGAogASgNSAJSFHByaW50Rmx1c2hJbnRlcnZhbE1ziAEBEjQKCW9zX3'
    'BvbGljeRgLIAEoCzISLm1vbnR5LnYxLk9zUG9saWN5SANSCG9zUG9saWN5iAEBEjcKC3BlcnNp'
    'c3RlbmNlGAwgASgOMhUubW9udHkudjEuUGVyc2lzdGVuY2VSC3BlcnNpc3RlbmNlEh0KB3Byb2'
    'ZpbGUYDSABKAlIBFIHcHJvZmlsZYgBAUITChFfdHlwZV9jaGVja19zdHVic0IdChtfYXNzZXJ0'
    'X21lc3NhZ2VfYW5ub3RhdGlvbnNCGgoYX3ByaW50X2ZsdXNoX2ludGVydmFsX21zQgwKCl9vc1'
    '9wb2xpY3lCCgoIX3Byb2ZpbGU=');

@$core.Deprecated('Use feedDescriptor instead')
const Feed$json = {
  '1': 'Feed',
  '2': [
    {'1': 'code', '3': 1, '4': 1, '5': 9, '10': 'code'},
    {
      '1': 'inputs',
      '3': 2,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.NamedRef',
      '10': 'inputs'
    },
    {
      '1': 'values',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
    {'1': 'skip_type_check', '3': 4, '4': 1, '5': 8, '10': 'skipTypeCheck'},
    {'1': 'cwd', '3': 5, '4': 1, '5': 9, '10': 'cwd'},
  ],
};

/// Descriptor for `Feed`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List feedDescriptor = $convert.base64Decode(
    'CgRGZWVkEhIKBGNvZGUYASABKAlSBGNvZGUSKgoGaW5wdXRzGAIgAygLMhIubW9udHkudjEuTm'
    'FtZWRSZWZSBmlucHV0cxInCgZ2YWx1ZXMYAyABKAsyDy5tb250eS52MS5BcmVuYVIGdmFsdWVz'
    'EiYKD3NraXBfdHlwZV9jaGVjaxgEIAEoCFINc2tpcFR5cGVDaGVjaxIQCgNjd2QYBSABKAlSA2'
    'N3ZA==');

@$core.Deprecated('Use abortFeedDescriptor instead')
const AbortFeed$json = {
  '1': 'AbortFeed',
  '2': [
    {
      '1': 'exception',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.RaisedException',
      '10': 'exception'
    },
  ],
};

/// Descriptor for `AbortFeed`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List abortFeedDescriptor = $convert.base64Decode(
    'CglBYm9ydEZlZWQSNwoJZXhjZXB0aW9uGAEgASgLMhkubW9udHkudjEuUmFpc2VkRXhjZXB0aW'
    '9uUglleGNlcHRpb24=');

@$core.Deprecated('Use resumeCallDescriptor instead')
const ResumeCall$json = {
  '1': 'ResumeCall',
  '2': [
    {'1': 'call_id', '3': 1, '4': 1, '5': 13, '10': 'callId'},
    {
      '1': 'result',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ExtFunctionResult',
      '10': 'result'
    },
    {
      '1': 'values',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
  ],
};

/// Descriptor for `ResumeCall`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resumeCallDescriptor = $convert.base64Decode(
    'CgpSZXN1bWVDYWxsEhcKB2NhbGxfaWQYASABKA1SBmNhbGxJZBIzCgZyZXN1bHQYAiABKAsyGy'
    '5tb250eS52MS5FeHRGdW5jdGlvblJlc3VsdFIGcmVzdWx0EicKBnZhbHVlcxgDIAEoCzIPLm1v'
    'bnR5LnYxLkFyZW5hUgZ2YWx1ZXM=');

@$core.Deprecated('Use resumeNameLookupDescriptor instead')
const ResumeNameLookup$json = {
  '1': 'ResumeNameLookup',
  '2': [
    {
      '1': 'values',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
    {'1': 'value', '3': 2, '4': 1, '5': 13, '9': 0, '10': 'value'},
    {
      '1': 'undefined',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'undefined'
    },
    {
      '1': 'error',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.RaisedException',
      '9': 0,
      '10': 'error'
    },
  ],
  '8': [
    {'1': 'kind'},
  ],
};

/// Descriptor for `ResumeNameLookup`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resumeNameLookupDescriptor = $convert.base64Decode(
    'ChBSZXN1bWVOYW1lTG9va3VwEicKBnZhbHVlcxgBIAEoCzIPLm1vbnR5LnYxLkFyZW5hUgZ2YW'
    'x1ZXMSFgoFdmFsdWUYAiABKA1IAFIFdmFsdWUSLgoJdW5kZWZpbmVkGAMgASgLMg4ubW9udHku'
    'djEuVW5pdEgAUgl1bmRlZmluZWQSMQoFZXJyb3IYBCABKAsyGS5tb250eS52MS5SYWlzZWRFeG'
    'NlcHRpb25IAFIFZXJyb3JCBgoEa2luZA==');

@$core.Deprecated('Use resumeFuturesDescriptor instead')
const ResumeFutures$json = {
  '1': 'ResumeFutures',
  '2': [
    {
      '1': 'results',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.FutureResult',
      '10': 'results'
    },
    {
      '1': 'values',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
  ],
};

/// Descriptor for `ResumeFutures`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resumeFuturesDescriptor = $convert.base64Decode(
    'Cg1SZXN1bWVGdXR1cmVzEjAKB3Jlc3VsdHMYASADKAsyFi5tb250eS52MS5GdXR1cmVSZXN1bH'
    'RSB3Jlc3VsdHMSJwoGdmFsdWVzGAIgASgLMg8ubW9udHkudjEuQXJlbmFSBnZhbHVlcw==');

@$core.Deprecated('Use dumpDescriptor instead')
const Dump$json = {
  '1': 'Dump',
};

/// Descriptor for `Dump`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dumpDescriptor = $convert.base64Decode('CgREdW1w');

@$core.Deprecated('Use loadDescriptor instead')
const Load$json = {
  '1': 'Load',
  '2': [
    {'1': 'state', '3': 1, '4': 1, '5': 12, '10': 'state'},
  ],
};

/// Descriptor for `Load`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List loadDescriptor =
    $convert.base64Decode('CgRMb2FkEhQKBXN0YXRlGAEgASgMUgVzdGF0ZQ==');

@$core.Deprecated('Use resetDescriptor instead')
const Reset$json = {
  '1': 'Reset',
};

/// Descriptor for `Reset`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resetDescriptor =
    $convert.base64Decode('CgVSZXNldA==');

@$core.Deprecated('Use shutdownDescriptor instead')
const Shutdown$json = {
  '1': 'Shutdown',
};

/// Descriptor for `Shutdown`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List shutdownDescriptor =
    $convert.base64Decode('CghTaHV0ZG93bg==');

@$core.Deprecated('Use installDependenciesDescriptor instead')
const InstallDependencies$json = {
  '1': 'InstallDependencies',
  '2': [
    {'1': 'requirements', '3': 1, '4': 3, '5': 9, '10': 'requirements'},
  ],
};

/// Descriptor for `InstallDependencies`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List installDependenciesDescriptor = $convert.base64Decode(
    'ChNJbnN0YWxsRGVwZW5kZW5jaWVzEiIKDHJlcXVpcmVtZW50cxgBIAMoCVIMcmVxdWlyZW1lbn'
    'Rz');

@$core.Deprecated('Use childEventDescriptor instead')
const ChildEvent$json = {
  '1': 'ChildEvent',
  '2': [
    {
      '1': 'print',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Print',
      '9': 0,
      '10': 'print'
    },
    {
      '1': 'function_call',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.FunctionCall',
      '9': 0,
      '10': 'functionCall'
    },
    {
      '1': 'os_call',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall',
      '9': 0,
      '10': 'osCall'
    },
    {
      '1': 'name_lookup',
      '3': 4,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.NameLookup',
      '9': 0,
      '10': 'nameLookup'
    },
    {
      '1': 'resolve_futures',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ResolveFutures',
      '9': 0,
      '10': 'resolveFutures'
    },
    {
      '1': 'complete',
      '3': 6,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Complete',
      '9': 0,
      '10': 'complete'
    },
    {
      '1': 'error',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Error',
      '9': 0,
      '10': 'error'
    },
    {
      '1': 'typing_error',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.TypingError',
      '9': 0,
      '10': 'typingError'
    },
    {
      '1': 'dump_result',
      '3': 9,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.DumpResult',
      '9': 0,
      '10': 'dumpResult'
    },
    {
      '1': 'ok',
      '3': 10,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Ok',
      '9': 0,
      '10': 'ok'
    },
    {
      '1': 'fatal_error',
      '3': 11,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.FatalError',
      '9': 0,
      '10': 'fatalError'
    },
    {
      '1': 'shutdown',
      '3': 12,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.ShutdownDump',
      '9': 0,
      '10': 'shutdown'
    },
    {
      '1': 'total_execution_micros',
      '3': 20,
      '4': 1,
      '5': 4,
      '10': 'totalExecutionMicros'
    },
    {
      '1': 'max_suspensions',
      '3': 22,
      '4': 1,
      '5': 4,
      '9': 1,
      '10': 'maxSuspensions',
      '17': true
    },
    {
      '1': 'feed_execution_micros',
      '3': 24,
      '4': 1,
      '5': 4,
      '10': 'feedExecutionMicros'
    },
    {
      '1': 'max_feed_duration_micros',
      '3': 25,
      '4': 1,
      '5': 4,
      '9': 2,
      '10': 'maxFeedDurationMicros',
      '17': true
    },
    {
      '1': 'max_turn_duration_micros',
      '3': 26,
      '4': 1,
      '5': 4,
      '9': 3,
      '10': 'maxTurnDurationMicros',
      '17': true
    },
    {
      '1': 'max_total_sleep_micros',
      '3': 27,
      '4': 1,
      '5': 4,
      '9': 4,
      '10': 'maxTotalSleepMicros',
      '17': true
    },
    {
      '1': 'restored_script_name',
      '3': 23,
      '4': 1,
      '5': 9,
      '9': 5,
      '10': 'restoredScriptName',
      '17': true
    },
    {
      '1': 'session_id',
      '3': 28,
      '4': 1,
      '5': 12,
      '9': 6,
      '10': 'sessionId',
      '17': true
    },
  ],
  '8': [
    {'1': 'kind'},
    {'1': '_max_suspensions'},
    {'1': '_max_feed_duration_micros'},
    {'1': '_max_turn_duration_micros'},
    {'1': '_max_total_sleep_micros'},
    {'1': '_restored_script_name'},
    {'1': '_session_id'},
  ],
  '9': [
    {'1': 21, '2': 22},
  ],
};

/// Descriptor for `ChildEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List childEventDescriptor = $convert.base64Decode(
    'CgpDaGlsZEV2ZW50EicKBXByaW50GAEgASgLMg8ubW9udHkudjEuUHJpbnRIAFIFcHJpbnQSPQ'
    'oNZnVuY3Rpb25fY2FsbBgCIAEoCzIWLm1vbnR5LnYxLkZ1bmN0aW9uQ2FsbEgAUgxmdW5jdGlv'
    'bkNhbGwSKwoHb3NfY2FsbBgDIAEoCzIQLm1vbnR5LnYxLk9zQ2FsbEgAUgZvc0NhbGwSNwoLbm'
    'FtZV9sb29rdXAYBCABKAsyFC5tb250eS52MS5OYW1lTG9va3VwSABSCm5hbWVMb29rdXASQwoP'
    'cmVzb2x2ZV9mdXR1cmVzGAUgASgLMhgubW9udHkudjEuUmVzb2x2ZUZ1dHVyZXNIAFIOcmVzb2'
    'x2ZUZ1dHVyZXMSMAoIY29tcGxldGUYBiABKAsyEi5tb250eS52MS5Db21wbGV0ZUgAUghjb21w'
    'bGV0ZRInCgVlcnJvchgHIAEoCzIPLm1vbnR5LnYxLkVycm9ySABSBWVycm9yEjoKDHR5cGluZ1'
    '9lcnJvchgIIAEoCzIVLm1vbnR5LnYxLlR5cGluZ0Vycm9ySABSC3R5cGluZ0Vycm9yEjcKC2R1'
    'bXBfcmVzdWx0GAkgASgLMhQubW9udHkudjEuRHVtcFJlc3VsdEgAUgpkdW1wUmVzdWx0Eh4KAm'
    '9rGAogASgLMgwubW9udHkudjEuT2tIAFICb2sSNwoLZmF0YWxfZXJyb3IYCyABKAsyFC5tb250'
    'eS52MS5GYXRhbEVycm9ySABSCmZhdGFsRXJyb3ISNAoIc2h1dGRvd24YDCABKAsyFi5tb250eS'
    '52MS5TaHV0ZG93bkR1bXBIAFIIc2h1dGRvd24SNAoWdG90YWxfZXhlY3V0aW9uX21pY3JvcxgU'
    'IAEoBFIUdG90YWxFeGVjdXRpb25NaWNyb3MSLAoPbWF4X3N1c3BlbnNpb25zGBYgASgESAFSDm'
    '1heFN1c3BlbnNpb25ziAEBEjIKFWZlZWRfZXhlY3V0aW9uX21pY3JvcxgYIAEoBFITZmVlZEV4'
    'ZWN1dGlvbk1pY3JvcxI8ChhtYXhfZmVlZF9kdXJhdGlvbl9taWNyb3MYGSABKARIAlIVbWF4Rm'
    'VlZER1cmF0aW9uTWljcm9ziAEBEjwKGG1heF90dXJuX2R1cmF0aW9uX21pY3JvcxgaIAEoBEgD'
    'UhVtYXhUdXJuRHVyYXRpb25NaWNyb3OIAQESOAoWbWF4X3RvdGFsX3NsZWVwX21pY3JvcxgbIA'
    'EoBEgEUhNtYXhUb3RhbFNsZWVwTWljcm9ziAEBEjUKFHJlc3RvcmVkX3NjcmlwdF9uYW1lGBcg'
    'ASgJSAVSEnJlc3RvcmVkU2NyaXB0TmFtZYgBARIiCgpzZXNzaW9uX2lkGBwgASgMSAZSCXNlc3'
    'Npb25JZIgBAUIGCgRraW5kQhIKEF9tYXhfc3VzcGVuc2lvbnNCGwoZX21heF9mZWVkX2R1cmF0'
    'aW9uX21pY3Jvc0IbChlfbWF4X3R1cm5fZHVyYXRpb25fbWljcm9zQhkKF19tYXhfdG90YWxfc2'
    'xlZXBfbWljcm9zQhcKFV9yZXN0b3JlZF9zY3JpcHRfbmFtZUINCgtfc2Vzc2lvbl9pZEoECBUQ'
    'Fg==');

@$core.Deprecated('Use printSegmentDescriptor instead')
const PrintSegment$json = {
  '1': 'PrintSegment',
  '2': [
    {
      '1': 'stream',
      '3': 1,
      '4': 1,
      '5': 14,
      '6': '.monty.v1.PrintStream',
      '10': 'stream'
    },
    {'1': 'text', '3': 2, '4': 1, '5': 9, '10': 'text'},
  ],
};

/// Descriptor for `PrintSegment`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List printSegmentDescriptor = $convert.base64Decode(
    'CgxQcmludFNlZ21lbnQSLQoGc3RyZWFtGAEgASgOMhUubW9udHkudjEuUHJpbnRTdHJlYW1SBn'
    'N0cmVhbRISCgR0ZXh0GAIgASgJUgR0ZXh0');

@$core.Deprecated('Use printDescriptor instead')
const Print$json = {
  '1': 'Print',
  '2': [
    {
      '1': 'segments',
      '3': 1,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.PrintSegment',
      '10': 'segments'
    },
  ],
};

/// Descriptor for `Print`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List printDescriptor = $convert.base64Decode(
    'CgVQcmludBIyCghzZWdtZW50cxgBIAMoCzIWLm1vbnR5LnYxLlByaW50U2VnbWVudFIIc2VnbW'
    'VudHM=');

@$core.Deprecated('Use functionCallDescriptor instead')
const FunctionCall$json = {
  '1': 'FunctionCall',
  '2': [
    {'1': 'function_name', '3': 1, '4': 1, '5': 9, '10': 'functionName'},
    {'1': 'args', '3': 2, '4': 3, '5': 13, '10': 'args'},
    {
      '1': 'kwargs',
      '3': 3,
      '4': 3,
      '5': 11,
      '6': '.monty.v1.NodePair',
      '10': 'kwargs'
    },
    {'1': 'call_id', '3': 4, '4': 1, '5': 13, '10': 'callId'},
    {
      '1': 'object_id',
      '3': 5,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Uuid',
      '10': 'objectId'
    },
    {'1': 'allow_eager_await', '3': 6, '4': 1, '5': 8, '10': 'allowEagerAwait'},
    {
      '1': 'values',
      '3': 7,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
    {
      '1': 'position',
      '3': 8,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SourceRange',
      '10': 'position'
    },
  ],
};

/// Descriptor for `FunctionCall`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List functionCallDescriptor = $convert.base64Decode(
    'CgxGdW5jdGlvbkNhbGwSIwoNZnVuY3Rpb25fbmFtZRgBIAEoCVIMZnVuY3Rpb25OYW1lEhIKBG'
    'FyZ3MYAiADKA1SBGFyZ3MSKgoGa3dhcmdzGAMgAygLMhIubW9udHkudjEuTm9kZVBhaXJSBmt3'
    'YXJncxIXCgdjYWxsX2lkGAQgASgNUgZjYWxsSWQSKwoJb2JqZWN0X2lkGAUgASgLMg4ubW9udH'
    'kudjEuVXVpZFIIb2JqZWN0SWQSKgoRYWxsb3dfZWFnZXJfYXdhaXQYBiABKAhSD2FsbG93RWFn'
    'ZXJBd2FpdBInCgZ2YWx1ZXMYByABKAsyDy5tb250eS52MS5BcmVuYVIGdmFsdWVzEjEKCHBvc2'
    'l0aW9uGAggASgLMhUubW9udHkudjEuU291cmNlUmFuZ2VSCHBvc2l0aW9u');

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall$json = {
  '1': 'OsCall',
  '2': [
    {'1': 'call_id', '3': 1, '4': 1, '5': 13, '10': 'callId'},
    {'1': 'exists', '3': 2, '4': 1, '5': 9, '9': 0, '10': 'exists'},
    {'1': 'is_file', '3': 3, '4': 1, '5': 9, '9': 0, '10': 'isFile'},
    {'1': 'is_dir', '3': 4, '4': 1, '5': 9, '9': 0, '10': 'isDir'},
    {'1': 'is_symlink', '3': 5, '4': 1, '5': 9, '9': 0, '10': 'isSymlink'},
    {'1': 'read_text', '3': 6, '4': 1, '5': 9, '9': 0, '10': 'readText'},
    {'1': 'read_bytes', '3': 7, '4': 1, '5': 9, '9': 0, '10': 'readBytes'},
    {'1': 'stat', '3': 8, '4': 1, '5': 9, '9': 0, '10': 'stat'},
    {'1': 'iterdir', '3': 9, '4': 1, '5': 9, '9': 0, '10': 'iterdir'},
    {'1': 'resolve', '3': 10, '4': 1, '5': 9, '9': 0, '10': 'resolve'},
    {'1': 'absolute', '3': 11, '4': 1, '5': 9, '9': 0, '10': 'absolute'},
    {'1': 'unlink', '3': 12, '4': 1, '5': 9, '9': 0, '10': 'unlink'},
    {'1': 'rmdir', '3': 13, '4': 1, '5': 9, '9': 0, '10': 'rmdir'},
    {
      '1': 'write_text',
      '3': 14,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.TextWrite',
      '9': 0,
      '10': 'writeText'
    },
    {
      '1': 'append_text',
      '3': 15,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.TextWrite',
      '9': 0,
      '10': 'appendText'
    },
    {
      '1': 'write_bytes',
      '3': 16,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.BytesWrite',
      '9': 0,
      '10': 'writeBytes'
    },
    {
      '1': 'append_bytes',
      '3': 17,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.BytesWrite',
      '9': 0,
      '10': 'appendBytes'
    },
    {
      '1': 'open',
      '3': 18,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Open',
      '9': 0,
      '10': 'open'
    },
    {
      '1': 'mkdir',
      '3': 19,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Mkdir',
      '9': 0,
      '10': 'mkdir'
    },
    {
      '1': 'rename',
      '3': 20,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Rename',
      '9': 0,
      '10': 'rename'
    },
    {
      '1': 'getenv',
      '3': 21,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Getenv',
      '9': 0,
      '10': 'getenv'
    },
    {
      '1': 'get_environ',
      '3': 22,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'getEnviron'
    },
    {
      '1': 'date_today',
      '3': 23,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Unit',
      '9': 0,
      '10': 'dateToday'
    },
    {
      '1': 'date_time_now',
      '3': 24,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.DateTimeNow',
      '9': 0,
      '10': 'dateTimeNow'
    },
    {
      '1': 'urandom',
      '3': 25,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Urandom',
      '9': 0,
      '10': 'urandom'
    },
    {
      '1': 'time',
      '3': 26,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.TimeCall',
      '9': 0,
      '10': 'time'
    },
    {
      '1': 'sleep',
      '3': 27,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Sleep',
      '9': 0,
      '10': 'sleep'
    },
    {
      '1': 'async_sleep',
      '3': 28,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.AsyncSleep',
      '9': 0,
      '10': 'asyncSleep'
    },
    {
      '1': 'system_sleep',
      '3': 29,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.Sleep',
      '9': 0,
      '10': 'systemSleep'
    },
    {
      '1': 'async_system_sleep',
      '3': 30,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.OsCall.AsyncSleep',
      '9': 0,
      '10': 'asyncSystemSleep'
    },
    {
      '1': 'values',
      '3': 50,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
    {
      '1': 'allow_eager_await',
      '3': 51,
      '4': 1,
      '5': 8,
      '10': 'allowEagerAwait'
    },
    {
      '1': 'position',
      '3': 52,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SourceRange',
      '10': 'position'
    },
  ],
  '3': [
    OsCall_TextWrite$json,
    OsCall_BytesWrite$json,
    OsCall_Open$json,
    OsCall_Mkdir$json,
    OsCall_Rename$json,
    OsCall_Getenv$json,
    OsCall_TimeCall$json,
    OsCall_DateTimeNow$json,
    OsCall_Urandom$json,
    OsCall_Sleep$json,
    OsCall_AsyncSleep$json
  ],
  '8': [
    {'1': 'call'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_TextWrite$json = {
  '1': 'TextWrite',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'data', '3': 2, '4': 1, '5': 9, '10': 'data'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_BytesWrite$json = {
  '1': 'BytesWrite',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'data', '3': 2, '4': 1, '5': 12, '10': 'data'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_Open$json = {
  '1': 'Open',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'mode', '3': 2, '4': 1, '5': 9, '10': 'mode'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_Mkdir$json = {
  '1': 'Mkdir',
  '2': [
    {'1': 'path', '3': 1, '4': 1, '5': 9, '10': 'path'},
    {'1': 'parents', '3': 2, '4': 1, '5': 8, '10': 'parents'},
    {'1': 'exist_ok', '3': 3, '4': 1, '5': 8, '10': 'existOk'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_Rename$json = {
  '1': 'Rename',
  '2': [
    {'1': 'src', '3': 1, '4': 1, '5': 9, '10': 'src'},
    {'1': 'dst', '3': 2, '4': 1, '5': 9, '10': 'dst'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_Getenv$json = {
  '1': 'Getenv',
  '2': [
    {'1': 'key', '3': 1, '4': 1, '5': 9, '10': 'key'},
    {'1': 'default', '3': 2, '4': 1, '5': 13, '10': 'default'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_TimeCall$json = {
  '1': 'TimeCall',
  '2': [
    {'1': 'caller', '3': 1, '4': 1, '5': 9, '10': 'caller'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_DateTimeNow$json = {
  '1': 'DateTimeNow',
  '2': [
    {
      '1': 'tz',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.TimeZone',
      '9': 0,
      '10': 'tz',
      '17': true
    },
  ],
  '8': [
    {'1': '_tz'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_Urandom$json = {
  '1': 'Urandom',
  '2': [
    {'1': 'size', '3': 1, '4': 1, '5': 4, '10': 'size'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_Sleep$json = {
  '1': 'Sleep',
  '2': [
    {'1': 'seconds', '3': 1, '4': 1, '5': 1, '10': 'seconds'},
  ],
};

@$core.Deprecated('Use osCallDescriptor instead')
const OsCall_AsyncSleep$json = {
  '1': 'AsyncSleep',
  '2': [
    {'1': 'delay', '3': 1, '4': 1, '5': 1, '10': 'delay'},
  ],
};

/// Descriptor for `OsCall`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List osCallDescriptor = $convert.base64Decode(
    'CgZPc0NhbGwSFwoHY2FsbF9pZBgBIAEoDVIGY2FsbElkEhgKBmV4aXN0cxgCIAEoCUgAUgZleG'
    'lzdHMSGQoHaXNfZmlsZRgDIAEoCUgAUgZpc0ZpbGUSFwoGaXNfZGlyGAQgASgJSABSBWlzRGly'
    'Eh8KCmlzX3N5bWxpbmsYBSABKAlIAFIJaXNTeW1saW5rEh0KCXJlYWRfdGV4dBgGIAEoCUgAUg'
    'hyZWFkVGV4dBIfCgpyZWFkX2J5dGVzGAcgASgJSABSCXJlYWRCeXRlcxIUCgRzdGF0GAggASgJ'
    'SABSBHN0YXQSGgoHaXRlcmRpchgJIAEoCUgAUgdpdGVyZGlyEhoKB3Jlc29sdmUYCiABKAlIAF'
    'IHcmVzb2x2ZRIcCghhYnNvbHV0ZRgLIAEoCUgAUghhYnNvbHV0ZRIYCgZ1bmxpbmsYDCABKAlI'
    'AFIGdW5saW5rEhYKBXJtZGlyGA0gASgJSABSBXJtZGlyEjsKCndyaXRlX3RleHQYDiABKAsyGi'
    '5tb250eS52MS5Pc0NhbGwuVGV4dFdyaXRlSABSCXdyaXRlVGV4dBI9CgthcHBlbmRfdGV4dBgP'
    'IAEoCzIaLm1vbnR5LnYxLk9zQ2FsbC5UZXh0V3JpdGVIAFIKYXBwZW5kVGV4dBI+Cgt3cml0ZV'
    '9ieXRlcxgQIAEoCzIbLm1vbnR5LnYxLk9zQ2FsbC5CeXRlc1dyaXRlSABSCndyaXRlQnl0ZXMS'
    'QAoMYXBwZW5kX2J5dGVzGBEgASgLMhsubW9udHkudjEuT3NDYWxsLkJ5dGVzV3JpdGVIAFILYX'
    'BwZW5kQnl0ZXMSKwoEb3BlbhgSIAEoCzIVLm1vbnR5LnYxLk9zQ2FsbC5PcGVuSABSBG9wZW4S'
    'LgoFbWtkaXIYEyABKAsyFi5tb250eS52MS5Pc0NhbGwuTWtkaXJIAFIFbWtkaXISMQoGcmVuYW'
    '1lGBQgASgLMhcubW9udHkudjEuT3NDYWxsLlJlbmFtZUgAUgZyZW5hbWUSMQoGZ2V0ZW52GBUg'
    'ASgLMhcubW9udHkudjEuT3NDYWxsLkdldGVudkgAUgZnZXRlbnYSMQoLZ2V0X2Vudmlyb24YFi'
    'ABKAsyDi5tb250eS52MS5Vbml0SABSCmdldEVudmlyb24SLwoKZGF0ZV90b2RheRgXIAEoCzIO'
    'Lm1vbnR5LnYxLlVuaXRIAFIJZGF0ZVRvZGF5EkIKDWRhdGVfdGltZV9ub3cYGCABKAsyHC5tb2'
    '50eS52MS5Pc0NhbGwuRGF0ZVRpbWVOb3dIAFILZGF0ZVRpbWVOb3cSNAoHdXJhbmRvbRgZIAEo'
    'CzIYLm1vbnR5LnYxLk9zQ2FsbC5VcmFuZG9tSABSB3VyYW5kb20SLwoEdGltZRgaIAEoCzIZLm'
    '1vbnR5LnYxLk9zQ2FsbC5UaW1lQ2FsbEgAUgR0aW1lEi4KBXNsZWVwGBsgASgLMhYubW9udHku'
    'djEuT3NDYWxsLlNsZWVwSABSBXNsZWVwEj4KC2FzeW5jX3NsZWVwGBwgASgLMhsubW9udHkudj'
    'EuT3NDYWxsLkFzeW5jU2xlZXBIAFIKYXN5bmNTbGVlcBI7CgxzeXN0ZW1fc2xlZXAYHSABKAsy'
    'Fi5tb250eS52MS5Pc0NhbGwuU2xlZXBIAFILc3lzdGVtU2xlZXASSwoSYXN5bmNfc3lzdGVtX3'
    'NsZWVwGB4gASgLMhsubW9udHkudjEuT3NDYWxsLkFzeW5jU2xlZXBIAFIQYXN5bmNTeXN0ZW1T'
    'bGVlcBInCgZ2YWx1ZXMYMiABKAsyDy5tb250eS52MS5BcmVuYVIGdmFsdWVzEioKEWFsbG93X2'
    'VhZ2VyX2F3YWl0GDMgASgIUg9hbGxvd0VhZ2VyQXdhaXQSMQoIcG9zaXRpb24YNCABKAsyFS5t'
    'b250eS52MS5Tb3VyY2VSYW5nZVIIcG9zaXRpb24aMwoJVGV4dFdyaXRlEhIKBHBhdGgYASABKA'
    'lSBHBhdGgSEgoEZGF0YRgCIAEoCVIEZGF0YRo0CgpCeXRlc1dyaXRlEhIKBHBhdGgYASABKAlS'
    'BHBhdGgSEgoEZGF0YRgCIAEoDFIEZGF0YRouCgRPcGVuEhIKBHBhdGgYASABKAlSBHBhdGgSEg'
    'oEbW9kZRgCIAEoCVIEbW9kZRpQCgVNa2RpchISCgRwYXRoGAEgASgJUgRwYXRoEhgKB3BhcmVu'
    'dHMYAiABKAhSB3BhcmVudHMSGQoIZXhpc3Rfb2sYAyABKAhSB2V4aXN0T2saLAoGUmVuYW1lEh'
    'AKA3NyYxgBIAEoCVIDc3JjEhAKA2RzdBgCIAEoCVIDZHN0GjQKBkdldGVudhIQCgNrZXkYASAB'
    'KAlSA2tleRIYCgdkZWZhdWx0GAIgASgNUgdkZWZhdWx0GiIKCFRpbWVDYWxsEhYKBmNhbGxlch'
    'gBIAEoCVIGY2FsbGVyGj0KC0RhdGVUaW1lTm93EicKAnR6GAEgASgLMhIubW9udHkudjEuVGlt'
    'ZVpvbmVIAFICdHqIAQFCBQoDX3R6Gh0KB1VyYW5kb20SEgoEc2l6ZRgBIAEoBFIEc2l6ZRohCg'
    'VTbGVlcBIYCgdzZWNvbmRzGAEgASgBUgdzZWNvbmRzGiIKCkFzeW5jU2xlZXASFAoFZGVsYXkY'
    'ASABKAFSBWRlbGF5QgYKBGNhbGw=');

@$core.Deprecated('Use nameLookupDescriptor instead')
const NameLookup$json = {
  '1': 'NameLookup',
  '2': [
    {'1': 'name', '3': 1, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'object_id',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Uuid',
      '10': 'objectId'
    },
    {
      '1': 'position',
      '3': 3,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SourceRange',
      '10': 'position'
    },
  ],
};

/// Descriptor for `NameLookup`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List nameLookupDescriptor = $convert.base64Decode(
    'CgpOYW1lTG9va3VwEhIKBG5hbWUYASABKAlSBG5hbWUSKwoJb2JqZWN0X2lkGAIgASgLMg4ubW'
    '9udHkudjEuVXVpZFIIb2JqZWN0SWQSMQoIcG9zaXRpb24YAyABKAsyFS5tb250eS52MS5Tb3Vy'
    'Y2VSYW5nZVIIcG9zaXRpb24=');

@$core.Deprecated('Use resolveFuturesDescriptor instead')
const ResolveFutures$json = {
  '1': 'ResolveFutures',
  '2': [
    {'1': 'pending_call_ids', '3': 1, '4': 3, '5': 13, '10': 'pendingCallIds'},
    {
      '1': 'position',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.SourceRange',
      '10': 'position'
    },
  ],
};

/// Descriptor for `ResolveFutures`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List resolveFuturesDescriptor = $convert.base64Decode(
    'Cg5SZXNvbHZlRnV0dXJlcxIoChBwZW5kaW5nX2NhbGxfaWRzGAEgAygNUg5wZW5kaW5nQ2FsbE'
    'lkcxIxCghwb3NpdGlvbhgCIAEoCzIVLm1vbnR5LnYxLlNvdXJjZVJhbmdlUghwb3NpdGlvbg==');

@$core.Deprecated('Use completeDescriptor instead')
const Complete$json = {
  '1': 'Complete',
  '2': [
    {'1': 'value', '3': 1, '4': 1, '5': 13, '10': 'value'},
    {
      '1': 'values',
      '3': 2,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.Arena',
      '10': 'values'
    },
  ],
};

/// Descriptor for `Complete`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List completeDescriptor = $convert.base64Decode(
    'CghDb21wbGV0ZRIUCgV2YWx1ZRgBIAEoDVIFdmFsdWUSJwoGdmFsdWVzGAIgASgLMg8ubW9udH'
    'kudjEuQXJlbmFSBnZhbHVlcw==');

@$core.Deprecated('Use errorDescriptor instead')
const Error$json = {
  '1': 'Error',
  '2': [
    {
      '1': 'exception',
      '3': 1,
      '4': 1,
      '5': 11,
      '6': '.monty.v1.RaisedException',
      '10': 'exception'
    },
  ],
};

/// Descriptor for `Error`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List errorDescriptor = $convert.base64Decode(
    'CgVFcnJvchI3CglleGNlcHRpb24YASABKAsyGS5tb250eS52MS5SYWlzZWRFeGNlcHRpb25SCW'
    'V4Y2VwdGlvbg==');

@$core.Deprecated('Use typingErrorDescriptor instead')
const TypingError$json = {
  '1': 'TypingError',
  '2': [
    {'1': 'diagnostics', '3': 1, '4': 1, '5': 9, '10': 'diagnostics'},
  ],
};

/// Descriptor for `TypingError`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List typingErrorDescriptor = $convert.base64Decode(
    'CgtUeXBpbmdFcnJvchIgCgtkaWFnbm9zdGljcxgBIAEoCVILZGlhZ25vc3RpY3M=');

@$core.Deprecated('Use dumpResultDescriptor instead')
const DumpResult$json = {
  '1': 'DumpResult',
  '2': [
    {'1': 'state', '3': 1, '4': 1, '5': 12, '10': 'state'},
  ],
};

/// Descriptor for `DumpResult`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List dumpResultDescriptor =
    $convert.base64Decode('CgpEdW1wUmVzdWx0EhQKBXN0YXRlGAEgASgMUgVzdGF0ZQ==');

@$core.Deprecated('Use okDescriptor instead')
const Ok$json = {
  '1': 'Ok',
};

/// Descriptor for `Ok`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List okDescriptor = $convert.base64Decode('CgJPaw==');

@$core.Deprecated('Use fatalErrorDescriptor instead')
const FatalError$json = {
  '1': 'FatalError',
  '2': [
    {'1': 'message', '3': 1, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `FatalError`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List fatalErrorDescriptor = $convert
    .base64Decode('CgpGYXRhbEVycm9yEhgKB21lc3NhZ2UYASABKAlSB21lc3NhZ2U=');

@$core.Deprecated('Use shutdownDumpDescriptor instead')
const ShutdownDump$json = {
  '1': 'ShutdownDump',
  '2': [
    {'1': 'dump', '3': 1, '4': 1, '5': 12, '9': 0, '10': 'dump', '17': true},
  ],
  '8': [
    {'1': '_dump'},
  ],
};

/// Descriptor for `ShutdownDump`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List shutdownDumpDescriptor = $convert.base64Decode(
    'CgxTaHV0ZG93bkR1bXASFwoEZHVtcBgBIAEoDEgAUgRkdW1wiAEBQgcKBV9kdW1w');
