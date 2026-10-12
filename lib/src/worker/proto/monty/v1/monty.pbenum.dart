// This is a generated file - do not edit.
//
// Generated from monty/v1/monty.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

/// Where a `Type` comes from — drives id presence and input validation.
class TypeOrigin extends $pb.ProtobufEnum {
  /// Rejected on decode.
  static const TypeOrigin TYPE_ORIGIN_UNSPECIFIED =
      TypeOrigin._(0, _omitEnumNames ? '' : 'TYPE_ORIGIN_UNSPECIFIED');

  /// `name` must parse as a known builtin type name ("int", "ValueError");
  /// valid as an execution input. `id` must be absent. Kept distinct from
  /// SANDBOX so a sandbox class shadowing a builtin name ("int") cannot be
  /// confused with the builtin type.
  static const TypeOrigin TYPE_ORIGIN_BUILTIN =
      TypeOrigin._(1, _omitEnumNames ? '' : 'TYPE_ORIGIN_BUILTIN');

  /// A sandbox-defined class; `id` required. Accepted by the decoder but
  /// rejected as an execution input (the class binding cannot be
  /// reconstructed host-side).
  static const TypeOrigin TYPE_ORIGIN_SANDBOX =
      TypeOrigin._(2, _omitEnumNames ? '' : 'TYPE_ORIGIN_SANDBOX');

  /// A host-defined class; `id` required.
  static const TypeOrigin TYPE_ORIGIN_HOST =
      TypeOrigin._(3, _omitEnumNames ? '' : 'TYPE_ORIGIN_HOST');

  static const $core.List<TypeOrigin> values = <TypeOrigin>[
    TYPE_ORIGIN_UNSPECIFIED,
    TYPE_ORIGIN_BUILTIN,
    TYPE_ORIGIN_SANDBOX,
    TYPE_ORIGIN_HOST,
  ];

  static final $core.List<TypeOrigin?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 3);
  static TypeOrigin? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const TypeOrigin._(super.value, super.name);
}

/// How a serving relay treats the session's state; children ignore it.
class Persistence extends $pb.ProtobufEnum {
  /// The relay's default.
  static const Persistence PERSISTENCE_UNSPECIFIED =
      Persistence._(0, _omitEnumNames ? '' : 'PERSISTENCE_UNSPECIFIED');

  /// Never stored by the relay on its own: no session ID and never parked.
  static const Persistence PERSISTENCE_EPHEMERAL =
      Persistence._(1, _omitEnumNames ? '' : 'PERSISTENCE_EPHEMERAL');

  /// Parked on idle, drain or disconnect, and loadable by its session ID.
  static const Persistence PERSISTENCE_STORED =
      Persistence._(2, _omitEnumNames ? '' : 'PERSISTENCE_STORED');

  static const $core.List<Persistence> values = <Persistence>[
    PERSISTENCE_UNSPECIFIED,
    PERSISTENCE_EPHEMERAL,
    PERSISTENCE_STORED,
  ];

  static final $core.List<Persistence?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static Persistence? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const Persistence._(super.value, super.name);
}

/// Rendering of the typing diagnostics a `TypingError` carries; mirrors ty's
/// `DiagnosticFormat`.
class TypeCheckFormat extends $pb.ProtobufEnum {
  /// Unset by an older parent — the child renders `FULL`.
  static const TypeCheckFormat TYPE_CHECK_FORMAT_UNSPECIFIED =
      TypeCheckFormat._(
          0, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_UNSPECIFIED');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_FULL =
      TypeCheckFormat._(1, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_FULL');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_CONCISE =
      TypeCheckFormat._(2, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_CONCISE');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_AZURE =
      TypeCheckFormat._(3, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_AZURE');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_JSON =
      TypeCheckFormat._(4, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_JSON');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_JSON_LINES = TypeCheckFormat._(
      5, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_JSON_LINES');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_RDJSON =
      TypeCheckFormat._(6, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_RDJSON');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_PYLINT =
      TypeCheckFormat._(7, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_PYLINT');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_GITLAB =
      TypeCheckFormat._(8, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_GITLAB');
  static const TypeCheckFormat TYPE_CHECK_FORMAT_GITHUB =
      TypeCheckFormat._(9, _omitEnumNames ? '' : 'TYPE_CHECK_FORMAT_GITHUB');

  static const $core.List<TypeCheckFormat> values = <TypeCheckFormat>[
    TYPE_CHECK_FORMAT_UNSPECIFIED,
    TYPE_CHECK_FORMAT_FULL,
    TYPE_CHECK_FORMAT_CONCISE,
    TYPE_CHECK_FORMAT_AZURE,
    TYPE_CHECK_FORMAT_JSON,
    TYPE_CHECK_FORMAT_JSON_LINES,
    TYPE_CHECK_FORMAT_RDJSON,
    TYPE_CHECK_FORMAT_PYLINT,
    TYPE_CHECK_FORMAT_GITLAB,
    TYPE_CHECK_FORMAT_GITHUB,
  ];

  static final $core.List<TypeCheckFormat?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 9);
  static TypeCheckFormat? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const TypeCheckFormat._(super.value, super.name);
}

class PrintStream extends $pb.ProtobufEnum {
  static const PrintStream PRINT_STREAM_UNSPECIFIED =
      PrintStream._(0, _omitEnumNames ? '' : 'PRINT_STREAM_UNSPECIFIED');
  static const PrintStream PRINT_STREAM_STDOUT =
      PrintStream._(1, _omitEnumNames ? '' : 'PRINT_STREAM_STDOUT');
  static const PrintStream PRINT_STREAM_STDERR =
      PrintStream._(2, _omitEnumNames ? '' : 'PRINT_STREAM_STDERR');

  static const $core.List<PrintStream> values = <PrintStream>[
    PRINT_STREAM_UNSPECIFIED,
    PRINT_STREAM_STDOUT,
    PRINT_STREAM_STDERR,
  ];

  static final $core.List<PrintStream?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 2);
  static PrintStream? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const PrintStream._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
