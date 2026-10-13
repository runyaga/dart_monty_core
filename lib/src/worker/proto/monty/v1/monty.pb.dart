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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'monty.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'monty.pbenum.dart';

/// Empty placeholder for valueless oneof arms. Defined locally (rather than
/// importing google.protobuf.Empty) so non-Rust decoders need nothing beyond
/// this single file.
class Unit extends $pb.GeneratedMessage {
  factory Unit() => Unit._();

  Unit._();

  factory Unit.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Unit()..mergeFromBuffer(data, registry);
  factory Unit.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Unit()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Unit',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Unit.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Unit clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Unit copyWith(void Function(Unit) updates) =>
      super.copyWith((message) => updates(message as Unit)) as Unit;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Unit() / Unit.new instead')
  static Unit create() => Unit._();
  static $pb.GeneratedMessage $_createMessage() => Unit._();
  @$core.override
  Unit createEmptyInstance() => Unit._();
  @$core.pragma('dart2js:noInline')
  static Unit getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Unit>(Unit.$_createMessage);
  static Unit? _defaultInstance;
}

/// Python values cross the boundary as one node arena per message: containers
/// hold the indexes of their children, so a sub-object referenced twice is one
/// node, and the carrying message names its roots by index. Nodes are in
/// post-order (every child index is lower than its holder's), so receivers
/// build values in one forward pass; a reference back to an enclosing
/// container is a `cycle` leaf. Mirrors monty's `MontyGraph`.
class Arena extends $pb.GeneratedMessage {
  factory Arena({
    $core.int? nodeCount,
    $core.Iterable<MontyNode>? nodes,
  }) {
    final result = Arena._();
    if (nodeCount != null) result.nodeCount = nodeCount;
    if (nodes != null) result.nodes.addAll(nodes);
    return result;
  }

  Arena._();

  factory Arena.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Arena()..mergeFromBuffer(data, registry);
  factory Arena.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Arena()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Arena',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Arena.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'nodeCount', fieldType: $pb.PbFieldType.OU3)
    ..pPM<MontyNode>(2, _omitFieldNames ? '' : 'nodes',
        subBuilder: MontyNode.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Arena clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Arena copyWith(void Function(Arena) updates) =>
      super.copyWith((message) => updates(message as Arena)) as Arena;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Arena() / Arena.new instead')
  static Arena create() => Arena._();
  static $pb.GeneratedMessage $_createMessage() => Arena._();
  @$core.override
  Arena createEmptyInstance() => Arena._();
  @$core.pragma('dart2js:noInline')
  static Arena getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Arena>(Arena.$_createMessage);
  static Arena? _defaultInstance;

  /// The sender's node count, so a receiver can reserve the arena once. A
  /// hint only: receivers cap it by the message size and charge it against
  /// their decode budget before allocating.
  @$pb.TagNumber(1)
  $core.int get nodeCount => $_getIZ(0);
  @$pb.TagNumber(1)
  set nodeCount($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasNodeCount() => $_has(0);
  @$pb.TagNumber(1)
  void clearNodeCount() => $_clearField(1);

  @$pb.TagNumber(2)
  $pb.PbList<MontyNode> get nodes => $_getList(1);
}

enum MontyNode_Kind {
  ellipsis,
  none,
  notImplemented,
  boolean,
  int_5,
  bigint,
  float,
  str,
  bytes,
  uuid,
  list,
  tuple,
  namedTuple,
  dict,
  set,
  frozenSet,
  date,
  time,
  datetime,
  timedelta,
  timezone,
  exception,
  type,
  classInstance,
  function,
  builtinFunction,
  path,
  fileHandle,
  repr,
  cycle,
  complex,
  notSet
}

/// One node of an `Arena`. Leaf arms carry the value; container arms carry
/// the indexes of their children.
///
/// `repr` and `cycle` are OUTPUT-ONLY: the child may emit them (e.g. inside a
/// `Complete` value) but rejects them as inputs.
class MontyNode extends $pb.GeneratedMessage {
  factory MontyNode({
    Unit? ellipsis,
    Unit? none,
    Unit? notImplemented,
    $core.bool? boolean,
    $fixnum.Int64? int_5,
    BigInt? bigint,
    $fixnum.Int64? float,
    $core.String? str,
    $core.List<$core.int>? bytes,
    Uuid? uuid,
    Indexes? list,
    Indexes? tuple,
    NamedTupleNode? namedTuple,
    NodePairs? dict,
    Indexes? set,
    Indexes? frozenSet,
    Date? date,
    Time? time,
    DateTime? datetime,
    TimeDelta? timedelta,
    TimeZone? timezone,
    Exception? exception,
    Type? type,
    ClassInstanceNode? classInstance,
    Function_? function,
    $core.String? builtinFunction,
    $core.String? path,
    FileHandle? fileHandle,
    $core.String? repr,
    $core.String? cycle,
    Complex? complex,
  }) {
    final result = MontyNode._();
    if (ellipsis != null) result.ellipsis = ellipsis;
    if (none != null) result.none = none;
    if (notImplemented != null) result.notImplemented = notImplemented;
    if (boolean != null) result.boolean = boolean;
    if (int_5 != null) result.int_5 = int_5;
    if (bigint != null) result.bigint = bigint;
    if (float != null) result.float = float;
    if (str != null) result.str = str;
    if (bytes != null) result.bytes = bytes;
    if (uuid != null) result.uuid = uuid;
    if (list != null) result.list = list;
    if (tuple != null) result.tuple = tuple;
    if (namedTuple != null) result.namedTuple = namedTuple;
    if (dict != null) result.dict = dict;
    if (set != null) result.set = set;
    if (frozenSet != null) result.frozenSet = frozenSet;
    if (date != null) result.date = date;
    if (time != null) result.time = time;
    if (datetime != null) result.datetime = datetime;
    if (timedelta != null) result.timedelta = timedelta;
    if (timezone != null) result.timezone = timezone;
    if (exception != null) result.exception = exception;
    if (type != null) result.type = type;
    if (classInstance != null) result.classInstance = classInstance;
    if (function != null) result.function = function;
    if (builtinFunction != null) result.builtinFunction = builtinFunction;
    if (path != null) result.path = path;
    if (fileHandle != null) result.fileHandle = fileHandle;
    if (repr != null) result.repr = repr;
    if (cycle != null) result.cycle = cycle;
    if (complex != null) result.complex = complex;
    return result;
  }

  MontyNode._();

  factory MontyNode.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MontyNode()..mergeFromBuffer(data, registry);
  factory MontyNode.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      MontyNode()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, MontyNode_Kind> _MontyNode_KindByTag = {
    1: MontyNode_Kind.ellipsis,
    2: MontyNode_Kind.none,
    3: MontyNode_Kind.notImplemented,
    4: MontyNode_Kind.boolean,
    5: MontyNode_Kind.int_5,
    6: MontyNode_Kind.bigint,
    7: MontyNode_Kind.float,
    8: MontyNode_Kind.str,
    9: MontyNode_Kind.bytes,
    10: MontyNode_Kind.uuid,
    11: MontyNode_Kind.list,
    12: MontyNode_Kind.tuple,
    13: MontyNode_Kind.namedTuple,
    14: MontyNode_Kind.dict,
    15: MontyNode_Kind.set,
    16: MontyNode_Kind.frozenSet,
    17: MontyNode_Kind.date,
    18: MontyNode_Kind.time,
    19: MontyNode_Kind.datetime,
    20: MontyNode_Kind.timedelta,
    21: MontyNode_Kind.timezone,
    22: MontyNode_Kind.exception,
    23: MontyNode_Kind.type,
    24: MontyNode_Kind.classInstance,
    25: MontyNode_Kind.function,
    26: MontyNode_Kind.builtinFunction,
    27: MontyNode_Kind.path,
    28: MontyNode_Kind.fileHandle,
    29: MontyNode_Kind.repr,
    30: MontyNode_Kind.cycle,
    31: MontyNode_Kind.complex,
    0: MontyNode_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'MontyNode',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: MontyNode.$_createMessage)
    ..oo(0, [
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      23,
      24,
      25,
      26,
      27,
      28,
      29,
      30,
      31
    ])
    ..aOM<Unit>(1, _omitFieldNames ? '' : 'ellipsis',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(2, _omitFieldNames ? '' : 'none',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(3, _omitFieldNames ? '' : 'notImplemented',
        subBuilder: Unit.$_createMessage)
    ..aOB(4, _omitFieldNames ? '' : 'boolean')
    ..a<$fixnum.Int64>(5, _omitFieldNames ? '' : 'int', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOM<BigInt>(6, _omitFieldNames ? '' : 'bigint',
        subBuilder: BigInt.$_createMessage)
    ..a<$fixnum.Int64>(7, _omitFieldNames ? '' : 'float', $pb.PbFieldType.OF6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(8, _omitFieldNames ? '' : 'str')
    ..a<$core.List<$core.int>>(
        9, _omitFieldNames ? '' : 'bytes', $pb.PbFieldType.OY)
    ..aOM<Uuid>(10, _omitFieldNames ? '' : 'uuid',
        subBuilder: Uuid.$_createMessage)
    ..aOM<Indexes>(11, _omitFieldNames ? '' : 'list',
        subBuilder: Indexes.$_createMessage)
    ..aOM<Indexes>(12, _omitFieldNames ? '' : 'tuple',
        subBuilder: Indexes.$_createMessage)
    ..aOM<NamedTupleNode>(13, _omitFieldNames ? '' : 'namedTuple',
        subBuilder: NamedTupleNode.$_createMessage)
    ..aOM<NodePairs>(14, _omitFieldNames ? '' : 'dict',
        subBuilder: NodePairs.$_createMessage)
    ..aOM<Indexes>(15, _omitFieldNames ? '' : 'set',
        subBuilder: Indexes.$_createMessage)
    ..aOM<Indexes>(16, _omitFieldNames ? '' : 'frozenSet',
        subBuilder: Indexes.$_createMessage)
    ..aOM<Date>(17, _omitFieldNames ? '' : 'date',
        subBuilder: Date.$_createMessage)
    ..aOM<Time>(18, _omitFieldNames ? '' : 'time',
        subBuilder: Time.$_createMessage)
    ..aOM<DateTime>(19, _omitFieldNames ? '' : 'datetime',
        subBuilder: DateTime.$_createMessage)
    ..aOM<TimeDelta>(20, _omitFieldNames ? '' : 'timedelta',
        subBuilder: TimeDelta.$_createMessage)
    ..aOM<TimeZone>(21, _omitFieldNames ? '' : 'timezone',
        subBuilder: TimeZone.$_createMessage)
    ..aOM<Exception>(22, _omitFieldNames ? '' : 'exception',
        subBuilder: Exception.$_createMessage)
    ..aOM<Type>(23, _omitFieldNames ? '' : 'type',
        subBuilder: Type.$_createMessage)
    ..aOM<ClassInstanceNode>(24, _omitFieldNames ? '' : 'classInstance',
        subBuilder: ClassInstanceNode.$_createMessage)
    ..aOM<Function_>(25, _omitFieldNames ? '' : 'function',
        subBuilder: Function_.$_createMessage)
    ..aOS(26, _omitFieldNames ? '' : 'builtinFunction')
    ..aOS(27, _omitFieldNames ? '' : 'path')
    ..aOM<FileHandle>(28, _omitFieldNames ? '' : 'fileHandle',
        subBuilder: FileHandle.$_createMessage)
    ..aOS(29, _omitFieldNames ? '' : 'repr')
    ..aOS(30, _omitFieldNames ? '' : 'cycle')
    ..aOM<Complex>(31, _omitFieldNames ? '' : 'complex',
        subBuilder: Complex.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MontyNode clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  MontyNode copyWith(void Function(MontyNode) updates) =>
      super.copyWith((message) => updates(message as MontyNode)) as MontyNode;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use MontyNode() / MontyNode.new instead')
  static MontyNode create() => MontyNode._();
  static $pb.GeneratedMessage $_createMessage() => MontyNode._();
  @$core.override
  MontyNode createEmptyInstance() => MontyNode._();
  @$core.pragma('dart2js:noInline')
  static MontyNode getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<MontyNode>(MontyNode.$_createMessage);
  static MontyNode? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  @$pb.TagNumber(13)
  @$pb.TagNumber(14)
  @$pb.TagNumber(15)
  @$pb.TagNumber(16)
  @$pb.TagNumber(17)
  @$pb.TagNumber(18)
  @$pb.TagNumber(19)
  @$pb.TagNumber(20)
  @$pb.TagNumber(21)
  @$pb.TagNumber(22)
  @$pb.TagNumber(23)
  @$pb.TagNumber(24)
  @$pb.TagNumber(25)
  @$pb.TagNumber(26)
  @$pb.TagNumber(27)
  @$pb.TagNumber(28)
  @$pb.TagNumber(29)
  @$pb.TagNumber(30)
  @$pb.TagNumber(31)
  MontyNode_Kind whichKind() => _MontyNode_KindByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  @$pb.TagNumber(13)
  @$pb.TagNumber(14)
  @$pb.TagNumber(15)
  @$pb.TagNumber(16)
  @$pb.TagNumber(17)
  @$pb.TagNumber(18)
  @$pb.TagNumber(19)
  @$pb.TagNumber(20)
  @$pb.TagNumber(21)
  @$pb.TagNumber(22)
  @$pb.TagNumber(23)
  @$pb.TagNumber(24)
  @$pb.TagNumber(25)
  @$pb.TagNumber(26)
  @$pb.TagNumber(27)
  @$pb.TagNumber(28)
  @$pb.TagNumber(29)
  @$pb.TagNumber(30)
  @$pb.TagNumber(31)
  void clearKind() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  Unit get ellipsis => $_getN(0);
  @$pb.TagNumber(1)
  set ellipsis(Unit value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasEllipsis() => $_has(0);
  @$pb.TagNumber(1)
  void clearEllipsis() => $_clearField(1);
  @$pb.TagNumber(1)
  Unit ensureEllipsis() => $_ensure(0);

  @$pb.TagNumber(2)
  Unit get none => $_getN(1);
  @$pb.TagNumber(2)
  set none(Unit value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasNone() => $_has(1);
  @$pb.TagNumber(2)
  void clearNone() => $_clearField(2);
  @$pb.TagNumber(2)
  Unit ensureNone() => $_ensure(1);

  @$pb.TagNumber(3)
  Unit get notImplemented => $_getN(2);
  @$pb.TagNumber(3)
  set notImplemented(Unit value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasNotImplemented() => $_has(2);
  @$pb.TagNumber(3)
  void clearNotImplemented() => $_clearField(3);
  @$pb.TagNumber(3)
  Unit ensureNotImplemented() => $_ensure(2);

  @$pb.TagNumber(4)
  $core.bool get boolean => $_getBF(3);
  @$pb.TagNumber(4)
  set boolean($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasBoolean() => $_has(3);
  @$pb.TagNumber(4)
  void clearBoolean() => $_clearField(4);

  /// Python int fitting in 64 bits.
  @$pb.TagNumber(5)
  $fixnum.Int64 get int_5 => $_getI64(4);
  @$pb.TagNumber(5)
  set int_5($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasInt_5() => $_has(4);
  @$pb.TagNumber(5)
  void clearInt_5() => $_clearField(5);

  /// Python int wider than 64 bits.
  @$pb.TagNumber(6)
  BigInt get bigint => $_getN(5);
  @$pb.TagNumber(6)
  set bigint(BigInt value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasBigint() => $_has(5);
  @$pb.TagNumber(6)
  void clearBigint() => $_clearField(6);
  @$pb.TagNumber(6)
  BigInt ensureBigint() => $_ensure(5);

  @$pb.TagNumber(7)
  $fixnum.Int64 get float => $_getI64(6);
  @$pb.TagNumber(7)
  set float($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(7)
  $core.bool hasFloat() => $_has(6);
  @$pb.TagNumber(7)
  void clearFloat() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.String get str => $_getSZ(7);
  @$pb.TagNumber(8)
  set str($core.String value) => $_setString(7, value);
  @$pb.TagNumber(8)
  $core.bool hasStr() => $_has(7);
  @$pb.TagNumber(8)
  void clearStr() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.List<$core.int> get bytes => $_getN(8);
  @$pb.TagNumber(9)
  set bytes($core.List<$core.int> value) => $_setBytes(8, value);
  @$pb.TagNumber(9)
  $core.bool hasBytes() => $_has(8);
  @$pb.TagNumber(9)
  void clearBytes() => $_clearField(9);

  /// A uuid.UUID value. Declared so the tag is settled, but NOT YET
  /// IMPLEMENTED: monty has no uuid module, so neither end produces or
  /// accepts this arm (conversion to a domain node rejects it).
  @$pb.TagNumber(10)
  Uuid get uuid => $_getN(9);
  @$pb.TagNumber(10)
  set uuid(Uuid value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasUuid() => $_has(9);
  @$pb.TagNumber(10)
  void clearUuid() => $_clearField(10);
  @$pb.TagNumber(10)
  Uuid ensureUuid() => $_ensure(9);

  @$pb.TagNumber(11)
  Indexes get list => $_getN(10);
  @$pb.TagNumber(11)
  set list(Indexes value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasList() => $_has(10);
  @$pb.TagNumber(11)
  void clearList() => $_clearField(11);
  @$pb.TagNumber(11)
  Indexes ensureList() => $_ensure(10);

  @$pb.TagNumber(12)
  Indexes get tuple => $_getN(11);
  @$pb.TagNumber(12)
  set tuple(Indexes value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasTuple() => $_has(11);
  @$pb.TagNumber(12)
  void clearTuple() => $_clearField(12);
  @$pb.TagNumber(12)
  Indexes ensureTuple() => $_ensure(11);

  @$pb.TagNumber(13)
  NamedTupleNode get namedTuple => $_getN(12);
  @$pb.TagNumber(13)
  set namedTuple(NamedTupleNode value) => $_setField(13, value);
  @$pb.TagNumber(13)
  $core.bool hasNamedTuple() => $_has(12);
  @$pb.TagNumber(13)
  void clearNamedTuple() => $_clearField(13);
  @$pb.TagNumber(13)
  NamedTupleNode ensureNamedTuple() => $_ensure(12);

  @$pb.TagNumber(14)
  NodePairs get dict => $_getN(13);
  @$pb.TagNumber(14)
  set dict(NodePairs value) => $_setField(14, value);
  @$pb.TagNumber(14)
  $core.bool hasDict() => $_has(13);
  @$pb.TagNumber(14)
  void clearDict() => $_clearField(14);
  @$pb.TagNumber(14)
  NodePairs ensureDict() => $_ensure(13);

  @$pb.TagNumber(15)
  Indexes get set => $_getN(14);
  @$pb.TagNumber(15)
  set set(Indexes value) => $_setField(15, value);
  @$pb.TagNumber(15)
  $core.bool hasSet() => $_has(14);
  @$pb.TagNumber(15)
  void clearSet() => $_clearField(15);
  @$pb.TagNumber(15)
  Indexes ensureSet() => $_ensure(14);

  @$pb.TagNumber(16)
  Indexes get frozenSet => $_getN(15);
  @$pb.TagNumber(16)
  set frozenSet(Indexes value) => $_setField(16, value);
  @$pb.TagNumber(16)
  $core.bool hasFrozenSet() => $_has(15);
  @$pb.TagNumber(16)
  void clearFrozenSet() => $_clearField(16);
  @$pb.TagNumber(16)
  Indexes ensureFrozenSet() => $_ensure(15);

  @$pb.TagNumber(17)
  Date get date => $_getN(16);
  @$pb.TagNumber(17)
  set date(Date value) => $_setField(17, value);
  @$pb.TagNumber(17)
  $core.bool hasDate() => $_has(16);
  @$pb.TagNumber(17)
  void clearDate() => $_clearField(17);
  @$pb.TagNumber(17)
  Date ensureDate() => $_ensure(16);

  @$pb.TagNumber(18)
  Time get time => $_getN(17);
  @$pb.TagNumber(18)
  set time(Time value) => $_setField(18, value);
  @$pb.TagNumber(18)
  $core.bool hasTime() => $_has(17);
  @$pb.TagNumber(18)
  void clearTime() => $_clearField(18);
  @$pb.TagNumber(18)
  Time ensureTime() => $_ensure(17);

  @$pb.TagNumber(19)
  DateTime get datetime => $_getN(18);
  @$pb.TagNumber(19)
  set datetime(DateTime value) => $_setField(19, value);
  @$pb.TagNumber(19)
  $core.bool hasDatetime() => $_has(18);
  @$pb.TagNumber(19)
  void clearDatetime() => $_clearField(19);
  @$pb.TagNumber(19)
  DateTime ensureDatetime() => $_ensure(18);

  @$pb.TagNumber(20)
  TimeDelta get timedelta => $_getN(19);
  @$pb.TagNumber(20)
  set timedelta(TimeDelta value) => $_setField(20, value);
  @$pb.TagNumber(20)
  $core.bool hasTimedelta() => $_has(19);
  @$pb.TagNumber(20)
  void clearTimedelta() => $_clearField(20);
  @$pb.TagNumber(20)
  TimeDelta ensureTimedelta() => $_ensure(19);

  @$pb.TagNumber(21)
  TimeZone get timezone => $_getN(20);
  @$pb.TagNumber(21)
  set timezone(TimeZone value) => $_setField(21, value);
  @$pb.TagNumber(21)
  $core.bool hasTimezone() => $_has(20);
  @$pb.TagNumber(21)
  void clearTimezone() => $_clearField(21);
  @$pb.TagNumber(21)
  TimeZone ensureTimezone() => $_ensure(20);

  /// A simple exception VALUE (no traceback) — e.g. an exception stored in a
  /// variable. Errors that terminate execution use `RaisedException` instead.
  @$pb.TagNumber(22)
  Exception get exception => $_getN(21);
  @$pb.TagNumber(22)
  set exception(Exception value) => $_setField(22, value);
  @$pb.TagNumber(22)
  $core.bool hasException() => $_has(21);
  @$pb.TagNumber(22)
  void clearException() => $_clearField(22);
  @$pb.TagNumber(22)
  Exception ensureException() => $_ensure(21);

  /// A Python type object — builtin, sandbox class, or host class. A class
  /// is a node of its own, shared by every instance of it in the arena.
  @$pb.TagNumber(23)
  Type get type => $_getN(22);
  @$pb.TagNumber(23)
  set type(Type value) => $_setField(23, value);
  @$pb.TagNumber(23)
  $core.bool hasType() => $_has(22);
  @$pb.TagNumber(23)
  void clearType() => $_clearField(23);
  @$pb.TagNumber(23)
  Type ensureType() => $_ensure(22);

  @$pb.TagNumber(24)
  ClassInstanceNode get classInstance => $_getN(23);
  @$pb.TagNumber(24)
  set classInstance(ClassInstanceNode value) => $_setField(24, value);
  @$pb.TagNumber(24)
  $core.bool hasClassInstance() => $_has(23);
  @$pb.TagNumber(24)
  void clearClassInstance() => $_clearField(24);
  @$pb.TagNumber(24)
  ClassInstanceNode ensureClassInstance() => $_ensure(23);

  @$pb.TagNumber(25)
  Function_ get function => $_getN(24);
  @$pb.TagNumber(25)
  set function(Function_ value) => $_setField(25, value);
  @$pb.TagNumber(25)
  $core.bool hasFunction() => $_has(24);
  @$pb.TagNumber(25)
  void clearFunction() => $_clearField(25);
  @$pb.TagNumber(25)
  Function_ ensureFunction() => $_ensure(24);

  /// A builtin function, named by its Python name, e.g. "len", "print".
  @$pb.TagNumber(26)
  $core.String get builtinFunction => $_getSZ(25);
  @$pb.TagNumber(26)
  set builtinFunction($core.String value) => $_setString(25, value);
  @$pb.TagNumber(26)
  $core.bool hasBuiltinFunction() => $_has(25);
  @$pb.TagNumber(26)
  void clearBuiltinFunction() => $_clearField(26);

  /// A pathlib.Path value (always a virtual POSIX path, never a host path).
  @$pb.TagNumber(27)
  $core.String get path => $_getSZ(26);
  @$pb.TagNumber(27)
  set path($core.String value) => $_setString(26, value);
  @$pb.TagNumber(27)
  $core.bool hasPath() => $_has(26);
  @$pb.TagNumber(27)
  void clearPath() => $_clearField(27);

  @$pb.TagNumber(28)
  FileHandle get fileHandle => $_getN(27);
  @$pb.TagNumber(28)
  set fileHandle(FileHandle value) => $_setField(28, value);
  @$pb.TagNumber(28)
  $core.bool hasFileHandle() => $_has(27);
  @$pb.TagNumber(28)
  void clearFileHandle() => $_clearField(28);
  @$pb.TagNumber(28)
  FileHandle ensureFileHandle() => $_ensure(27);

  /// OUTPUT-ONLY fallback: repr() of a value with no other representation.
  @$pb.TagNumber(29)
  $core.String get repr => $_getSZ(28);
  @$pb.TagNumber(29)
  set repr($core.String value) => $_setString(28, value);
  @$pb.TagNumber(29)
  $core.bool hasRepr() => $_has(28);
  @$pb.TagNumber(29)
  void clearRepr() => $_clearField(29);

  /// OUTPUT-ONLY: a reference back to a container enclosing this node, as
  /// the placeholder its repr shows ("[...]", "(...)", "{...}" or "...").
  @$pb.TagNumber(30)
  $core.String get cycle => $_getSZ(29);
  @$pb.TagNumber(30)
  set cycle($core.String value) => $_setString(29, value);
  @$pb.TagNumber(30)
  $core.bool hasCycle() => $_has(29);
  @$pb.TagNumber(30)
  void clearCycle() => $_clearField(30);

  @$pb.TagNumber(31)
  Complex get complex => $_getN(30);
  @$pb.TagNumber(31)
  set complex(Complex value) => $_setField(31, value);
  @$pb.TagNumber(31)
  $core.bool hasComplex() => $_has(30);
  @$pb.TagNumber(31)
  void clearComplex() => $_clearField(31);
  @$pb.TagNumber(31)
  Complex ensureComplex() => $_ensure(30);
}

/// Indexes of a container's children (list, tuple, set, frozenset items).
class Indexes extends $pb.GeneratedMessage {
  factory Indexes({
    $core.Iterable<$core.int>? items,
  }) {
    final result = Indexes._();
    if (items != null) result.items.addAll(items);
    return result;
  }

  Indexes._();

  factory Indexes.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Indexes()..mergeFromBuffer(data, registry);
  factory Indexes.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Indexes()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Indexes',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Indexes.$_createMessage)
    ..p<$core.int>(1, _omitFieldNames ? '' : 'items', $pb.PbFieldType.KU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Indexes clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Indexes copyWith(void Function(Indexes) updates) =>
      super.copyWith((message) => updates(message as Indexes)) as Indexes;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Indexes() / Indexes.new instead')
  static Indexes create() => Indexes._();
  static $pb.GeneratedMessage $_createMessage() => Indexes._();
  @$core.override
  Indexes createEmptyInstance() => Indexes._();
  @$core.pragma('dart2js:noInline')
  static Indexes getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Indexes>(Indexes.$_createMessage);
  static Indexes? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.int> get items => $_getList(0);
}

/// One key/value entry as node indexes. Used for dicts, attrs and kwargs:
/// proto maps cannot have message keys and do not preserve order, while
/// Python dicts allow arbitrary hashable keys and are insertion-ordered.
class NodePair extends $pb.GeneratedMessage {
  factory NodePair({
    $core.int? key,
    $core.int? value,
  }) {
    final result = NodePair._();
    if (key != null) result.key = key;
    if (value != null) result.value = value;
    return result;
  }

  NodePair._();

  factory NodePair.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NodePair()..mergeFromBuffer(data, registry);
  factory NodePair.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NodePair()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NodePair',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: NodePair.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'key', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'value', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NodePair clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NodePair copyWith(void Function(NodePair) updates) =>
      super.copyWith((message) => updates(message as NodePair)) as NodePair;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use NodePair() / NodePair.new instead')
  static NodePair create() => NodePair._();
  static $pb.GeneratedMessage $_createMessage() => NodePair._();
  @$core.override
  NodePair createEmptyInstance() => NodePair._();
  @$core.pragma('dart2js:noInline')
  static NodePair getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NodePair>(NodePair.$_createMessage);
  static NodePair? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get key => $_getIZ(0);
  @$pb.TagNumber(1)
  set key($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get value => $_getIZ(1);
  @$pb.TagNumber(2)
  set value($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);
}

class NodePairs extends $pb.GeneratedMessage {
  factory NodePairs({
    $core.Iterable<NodePair>? pairs,
  }) {
    final result = NodePairs._();
    if (pairs != null) result.pairs.addAll(pairs);
    return result;
  }

  NodePairs._();

  factory NodePairs.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NodePairs()..mergeFromBuffer(data, registry);
  factory NodePairs.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NodePairs()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NodePairs',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: NodePairs.$_createMessage)
    ..pPM<NodePair>(1, _omitFieldNames ? '' : 'pairs',
        subBuilder: NodePair.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NodePairs clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NodePairs copyWith(void Function(NodePairs) updates) =>
      super.copyWith((message) => updates(message as NodePairs)) as NodePairs;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use NodePairs() / NodePairs.new instead')
  static NodePairs create() => NodePairs._();
  static $pb.GeneratedMessage $_createMessage() => NodePairs._();
  @$core.override
  NodePairs createEmptyInstance() => NodePairs._();
  @$core.pragma('dart2js:noInline')
  static NodePairs getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NodePairs>(NodePairs.$_createMessage);
  static NodePairs? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<NodePair> get pairs => $_getList(0);
}

/// Arbitrary-precision integer as sign + big-endian magnitude. Exact and O(n);
/// JS decode is `(negative ? -1n : 1n) * BigInt('0x' + hex(magnitude))`.
class BigInt extends $pb.GeneratedMessage {
  factory BigInt({
    $core.bool? negative,
    $core.List<$core.int>? magnitude,
  }) {
    final result = BigInt._();
    if (negative != null) result.negative = negative;
    if (magnitude != null) result.magnitude = magnitude;
    return result;
  }

  BigInt._();

  factory BigInt.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BigInt()..mergeFromBuffer(data, registry);
  factory BigInt.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      BigInt()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'BigInt',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: BigInt.$_createMessage)
    ..aOB(1, _omitFieldNames ? '' : 'negative')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'magnitude', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BigInt clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  BigInt copyWith(void Function(BigInt) updates) =>
      super.copyWith((message) => updates(message as BigInt)) as BigInt;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use BigInt() / BigInt.new instead')
  static BigInt create() => BigInt._();
  static $pb.GeneratedMessage $_createMessage() => BigInt._();
  @$core.override
  BigInt createEmptyInstance() => BigInt._();
  @$core.pragma('dart2js:noInline')
  static BigInt getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<BigInt>(BigInt.$_createMessage);
  static BigInt? _defaultInstance;

  @$pb.TagNumber(1)
  $core.bool get negative => $_getBF(0);
  @$pb.TagNumber(1)
  set negative($core.bool value) => $_setBool(0, value);
  @$pb.TagNumber(1)
  $core.bool hasNegative() => $_has(0);
  @$pb.TagNumber(1)
  void clearNegative() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get magnitude => $_getN(1);
  @$pb.TagNumber(2)
  set magnitude($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMagnitude() => $_has(1);
  @$pb.TagNumber(2)
  void clearMagnitude() => $_clearField(2);
}

/// A Python complex as its two float parts. Both are always present: a plain
/// `double` omits its default on the wire, which would turn `-0.0` into `0.0`.
class Complex extends $pb.GeneratedMessage {
  factory Complex({
    $fixnum.Int64? real,
    $fixnum.Int64? imag,
  }) {
    final result = Complex._();
    if (real != null) result.real = real;
    if (imag != null) result.imag = imag;
    return result;
  }

  Complex._();

  factory Complex.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Complex()..mergeFromBuffer(data, registry);
  factory Complex.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Complex()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Complex',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Complex.$_createMessage)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'real', $pb.PbFieldType.OF6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(2, _omitFieldNames ? '' : 'imag', $pb.PbFieldType.OF6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Complex clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Complex copyWith(void Function(Complex) updates) =>
      super.copyWith((message) => updates(message as Complex)) as Complex;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Complex() / Complex.new instead')
  static Complex create() => Complex._();
  static $pb.GeneratedMessage $_createMessage() => Complex._();
  @$core.override
  Complex createEmptyInstance() => Complex._();
  @$core.pragma('dart2js:noInline')
  static Complex getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Complex>(Complex.$_createMessage);
  static Complex? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get real => $_getI64(0);
  @$pb.TagNumber(1)
  set real($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasReal() => $_has(0);
  @$pb.TagNumber(1)
  void clearReal() => $_clearField(1);

  @$pb.TagNumber(2)
  $fixnum.Int64 get imag => $_getI64(1);
  @$pb.TagNumber(2)
  set imag($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(2)
  $core.bool hasImag() => $_has(1);
  @$pb.TagNumber(2)
  void clearImag() => $_clearField(2);
}

class NamedTupleNode extends $pb.GeneratedMessage {
  factory NamedTupleNode({
    $core.String? typeName,
    $core.Iterable<$core.String>? fieldNames,
    $core.Iterable<$core.int>? values,
  }) {
    final result = NamedTupleNode._();
    if (typeName != null) result.typeName = typeName;
    if (fieldNames != null) result.fieldNames.addAll(fieldNames);
    if (values != null) result.values.addAll(values);
    return result;
  }

  NamedTupleNode._();

  factory NamedTupleNode.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NamedTupleNode()..mergeFromBuffer(data, registry);
  factory NamedTupleNode.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NamedTupleNode()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NamedTupleNode',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: NamedTupleNode.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'typeName')
    ..pPS(2, _omitFieldNames ? '' : 'fieldNames')
    ..p<$core.int>(3, _omitFieldNames ? '' : 'values', $pb.PbFieldType.KU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NamedTupleNode clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NamedTupleNode copyWith(void Function(NamedTupleNode) updates) =>
      super.copyWith((message) => updates(message as NamedTupleNode))
          as NamedTupleNode;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use NamedTupleNode() / NamedTupleNode.new instead')
  static NamedTupleNode create() => NamedTupleNode._();
  static $pb.GeneratedMessage $_createMessage() => NamedTupleNode._();
  @$core.override
  NamedTupleNode createEmptyInstance() => NamedTupleNode._();
  @$core.pragma('dart2js:noInline')
  static NamedTupleNode getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<NamedTupleNode>(
          NamedTupleNode.$_createMessage);
  static NamedTupleNode? _defaultInstance;

  /// Type name used in repr, e.g. "os.stat_result".
  @$pb.TagNumber(1)
  $core.String get typeName => $_getSZ(0);
  @$pb.TagNumber(1)
  set typeName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTypeName() => $_has(0);
  @$pb.TagNumber(1)
  void clearTypeName() => $_clearField(1);

  /// Attribute names, one per value.
  @$pb.TagNumber(2)
  $pb.PbList<$core.String> get fieldNames => $_getList(1);

  /// Indexes of the values, one per field name.
  @$pb.TagNumber(3)
  $pb.PbList<$core.int> get values => $_getList(2);
}

class Date extends $pb.GeneratedMessage {
  factory Date({
    $core.int? year,
    $core.int? month,
    $core.int? day,
  }) {
    final result = Date._();
    if (year != null) result.year = year;
    if (month != null) result.month = month;
    if (day != null) result.day = day;
    return result;
  }

  Date._();

  factory Date.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Date()..mergeFromBuffer(data, registry);
  factory Date.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Date()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Date',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Date.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'year')
    ..aI(2, _omitFieldNames ? '' : 'month', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'day', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Date clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Date copyWith(void Function(Date) updates) =>
      super.copyWith((message) => updates(message as Date)) as Date;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Date() / Date.new instead')
  static Date create() => Date._();
  static $pb.GeneratedMessage $_createMessage() => Date._();
  @$core.override
  Date createEmptyInstance() => Date._();
  @$core.pragma('dart2js:noInline')
  static Date getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Date>(Date.$_createMessage);
  static Date? _defaultInstance;

  /// Gregorian year in 1..=9999.
  @$pb.TagNumber(1)
  $core.int get year => $_getIZ(0);
  @$pb.TagNumber(1)
  set year($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasYear() => $_has(0);
  @$pb.TagNumber(1)
  void clearYear() => $_clearField(1);

  /// 1..=12.
  @$pb.TagNumber(2)
  $core.int get month => $_getIZ(1);
  @$pb.TagNumber(2)
  set month($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMonth() => $_has(1);
  @$pb.TagNumber(2)
  void clearMonth() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get day => $_getIZ(2);
  @$pb.TagNumber(3)
  set day($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDay() => $_has(2);
  @$pb.TagNumber(3)
  void clearDay() => $_clearField(3);
}

class DateTime extends $pb.GeneratedMessage {
  factory DateTime({
    $core.int? year,
    $core.int? month,
    $core.int? day,
    $core.int? hour,
    $core.int? minute,
    $core.int? second,
    $core.int? microsecond,
    $core.int? offsetSeconds,
    $core.String? timezoneName,
  }) {
    final result = DateTime._();
    if (year != null) result.year = year;
    if (month != null) result.month = month;
    if (day != null) result.day = day;
    if (hour != null) result.hour = hour;
    if (minute != null) result.minute = minute;
    if (second != null) result.second = second;
    if (microsecond != null) result.microsecond = microsecond;
    if (offsetSeconds != null) result.offsetSeconds = offsetSeconds;
    if (timezoneName != null) result.timezoneName = timezoneName;
    return result;
  }

  DateTime._();

  factory DateTime.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DateTime()..mergeFromBuffer(data, registry);
  factory DateTime.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DateTime()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DateTime',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: DateTime.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'year')
    ..aI(2, _omitFieldNames ? '' : 'month', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'day', fieldType: $pb.PbFieldType.OU3)
    ..aI(4, _omitFieldNames ? '' : 'hour', fieldType: $pb.PbFieldType.OU3)
    ..aI(5, _omitFieldNames ? '' : 'minute', fieldType: $pb.PbFieldType.OU3)
    ..aI(6, _omitFieldNames ? '' : 'second', fieldType: $pb.PbFieldType.OU3)
    ..aI(7, _omitFieldNames ? '' : 'microsecond',
        fieldType: $pb.PbFieldType.OU3)
    ..aI(8, _omitFieldNames ? '' : 'offsetSeconds')
    ..aOS(9, _omitFieldNames ? '' : 'timezoneName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DateTime clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DateTime copyWith(void Function(DateTime) updates) =>
      super.copyWith((message) => updates(message as DateTime)) as DateTime;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DateTime() / DateTime.new instead')
  static DateTime create() => DateTime._();
  static $pb.GeneratedMessage $_createMessage() => DateTime._();
  @$core.override
  DateTime createEmptyInstance() => DateTime._();
  @$core.pragma('dart2js:noInline')
  static DateTime getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DateTime>(DateTime.$_createMessage);
  static DateTime? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get year => $_getIZ(0);
  @$pb.TagNumber(1)
  set year($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasYear() => $_has(0);
  @$pb.TagNumber(1)
  void clearYear() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get month => $_getIZ(1);
  @$pb.TagNumber(2)
  set month($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMonth() => $_has(1);
  @$pb.TagNumber(2)
  void clearMonth() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get day => $_getIZ(2);
  @$pb.TagNumber(3)
  set day($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasDay() => $_has(2);
  @$pb.TagNumber(3)
  void clearDay() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.int get hour => $_getIZ(3);
  @$pb.TagNumber(4)
  set hour($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasHour() => $_has(3);
  @$pb.TagNumber(4)
  void clearHour() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.int get minute => $_getIZ(4);
  @$pb.TagNumber(5)
  set minute($core.int value) => $_setUnsignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMinute() => $_has(4);
  @$pb.TagNumber(5)
  void clearMinute() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.int get second => $_getIZ(5);
  @$pb.TagNumber(6)
  set second($core.int value) => $_setUnsignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasSecond() => $_has(5);
  @$pb.TagNumber(6)
  void clearSecond() => $_clearField(6);

  /// 0..=999999.
  @$pb.TagNumber(7)
  $core.int get microsecond => $_getIZ(6);
  @$pb.TagNumber(7)
  set microsecond($core.int value) => $_setUnsignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasMicrosecond() => $_has(6);
  @$pb.TagNumber(7)
  void clearMicrosecond() => $_clearField(7);

  /// Fixed UTC offset for aware datetimes; absent for naive values.
  @$pb.TagNumber(8)
  $core.int get offsetSeconds => $_getIZ(7);
  @$pb.TagNumber(8)
  set offsetSeconds($core.int value) => $_setSignedInt32(7, value);
  @$pb.TagNumber(8)
  $core.bool hasOffsetSeconds() => $_has(7);
  @$pb.TagNumber(8)
  void clearOffsetSeconds() => $_clearField(8);

  /// Optional timezone name; only valid when offset_seconds is set.
  @$pb.TagNumber(9)
  $core.String get timezoneName => $_getSZ(8);
  @$pb.TagNumber(9)
  set timezoneName($core.String value) => $_setString(8, value);
  @$pb.TagNumber(9)
  $core.bool hasTimezoneName() => $_has(8);
  @$pb.TagNumber(9)
  void clearTimezoneName() => $_clearField(9);
}

class Time extends $pb.GeneratedMessage {
  factory Time({
    $core.int? hour,
    $core.int? minute,
    $core.int? second,
    $core.int? microsecond,
    $core.int? offsetSeconds,
    $core.String? timezoneName,
    $core.int? fold,
  }) {
    final result = Time._();
    if (hour != null) result.hour = hour;
    if (minute != null) result.minute = minute;
    if (second != null) result.second = second;
    if (microsecond != null) result.microsecond = microsecond;
    if (offsetSeconds != null) result.offsetSeconds = offsetSeconds;
    if (timezoneName != null) result.timezoneName = timezoneName;
    if (fold != null) result.fold = fold;
    return result;
  }

  Time._();

  factory Time.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Time()..mergeFromBuffer(data, registry);
  factory Time.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Time()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Time',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Time.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'hour', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'minute', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'second', fieldType: $pb.PbFieldType.OU3)
    ..aI(4, _omitFieldNames ? '' : 'microsecond',
        fieldType: $pb.PbFieldType.OU3)
    ..aI(5, _omitFieldNames ? '' : 'offsetSeconds')
    ..aOS(6, _omitFieldNames ? '' : 'timezoneName')
    ..aI(7, _omitFieldNames ? '' : 'fold', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Time clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Time copyWith(void Function(Time) updates) =>
      super.copyWith((message) => updates(message as Time)) as Time;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Time() / Time.new instead')
  static Time create() => Time._();
  static $pb.GeneratedMessage $_createMessage() => Time._();
  @$core.override
  Time createEmptyInstance() => Time._();
  @$core.pragma('dart2js:noInline')
  static Time getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Time>(Time.$_createMessage);
  static Time? _defaultInstance;

  /// 0..=23.
  @$pb.TagNumber(1)
  $core.int get hour => $_getIZ(0);
  @$pb.TagNumber(1)
  set hour($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasHour() => $_has(0);
  @$pb.TagNumber(1)
  void clearHour() => $_clearField(1);

  /// 0..=59.
  @$pb.TagNumber(2)
  $core.int get minute => $_getIZ(1);
  @$pb.TagNumber(2)
  set minute($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMinute() => $_has(1);
  @$pb.TagNumber(2)
  void clearMinute() => $_clearField(2);

  /// 0..=59.
  @$pb.TagNumber(3)
  $core.int get second => $_getIZ(2);
  @$pb.TagNumber(3)
  set second($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasSecond() => $_has(2);
  @$pb.TagNumber(3)
  void clearSecond() => $_clearField(3);

  /// 0..=999999.
  @$pb.TagNumber(4)
  $core.int get microsecond => $_getIZ(3);
  @$pb.TagNumber(4)
  set microsecond($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMicrosecond() => $_has(3);
  @$pb.TagNumber(4)
  void clearMicrosecond() => $_clearField(4);

  /// Fixed UTC offset for aware times; absent for naive values.
  @$pb.TagNumber(5)
  $core.int get offsetSeconds => $_getIZ(4);
  @$pb.TagNumber(5)
  set offsetSeconds($core.int value) => $_setSignedInt32(4, value);
  @$pb.TagNumber(5)
  $core.bool hasOffsetSeconds() => $_has(4);
  @$pb.TagNumber(5)
  void clearOffsetSeconds() => $_clearField(5);

  /// Optional timezone name; only valid when offset_seconds is set.
  @$pb.TagNumber(6)
  $core.String get timezoneName => $_getSZ(5);
  @$pb.TagNumber(6)
  set timezoneName($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasTimezoneName() => $_has(5);
  @$pb.TagNumber(6)
  void clearTimezoneName() => $_clearField(6);

  /// Disambiguates a repeated wall clock, 0 or 1. Carried so a time does not
  /// silently lose the flag crossing the boundary; monty never interprets it.
  @$pb.TagNumber(7)
  $core.int get fold => $_getIZ(6);
  @$pb.TagNumber(7)
  set fold($core.int value) => $_setUnsignedInt32(6, value);
  @$pb.TagNumber(7)
  $core.bool hasFold() => $_has(6);
  @$pb.TagNumber(7)
  void clearFold() => $_clearField(7);
}

class TimeDelta extends $pb.GeneratedMessage {
  factory TimeDelta({
    $core.int? days,
    $core.int? seconds,
    $core.int? microseconds,
  }) {
    final result = TimeDelta._();
    if (days != null) result.days = days;
    if (seconds != null) result.seconds = seconds;
    if (microseconds != null) result.microseconds = microseconds;
    return result;
  }

  TimeDelta._();

  factory TimeDelta.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TimeDelta()..mergeFromBuffer(data, registry);
  factory TimeDelta.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TimeDelta()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TimeDelta',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: TimeDelta.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'days')
    ..aI(2, _omitFieldNames ? '' : 'seconds')
    ..aI(3, _omitFieldNames ? '' : 'microseconds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TimeDelta clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TimeDelta copyWith(void Function(TimeDelta) updates) =>
      super.copyWith((message) => updates(message as TimeDelta)) as TimeDelta;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TimeDelta() / TimeDelta.new instead')
  static TimeDelta create() => TimeDelta._();
  static $pb.GeneratedMessage $_createMessage() => TimeDelta._();
  @$core.override
  TimeDelta createEmptyInstance() => TimeDelta._();
  @$core.pragma('dart2js:noInline')
  static TimeDelta getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TimeDelta>(TimeDelta.$_createMessage);
  static TimeDelta? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get days => $_getIZ(0);
  @$pb.TagNumber(1)
  set days($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDays() => $_has(0);
  @$pb.TagNumber(1)
  void clearDays() => $_clearField(1);

  /// Normalized to 0..86400.
  @$pb.TagNumber(2)
  $core.int get seconds => $_getIZ(1);
  @$pb.TagNumber(2)
  set seconds($core.int value) => $_setSignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasSeconds() => $_has(1);
  @$pb.TagNumber(2)
  void clearSeconds() => $_clearField(2);

  /// Normalized to 0..1000000.
  @$pb.TagNumber(3)
  $core.int get microseconds => $_getIZ(2);
  @$pb.TagNumber(3)
  set microseconds($core.int value) => $_setSignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMicroseconds() => $_has(2);
  @$pb.TagNumber(3)
  void clearMicroseconds() => $_clearField(3);
}

class TimeZone extends $pb.GeneratedMessage {
  factory TimeZone({
    $core.int? offsetSeconds,
    $core.String? name,
  }) {
    final result = TimeZone._();
    if (offsetSeconds != null) result.offsetSeconds = offsetSeconds;
    if (name != null) result.name = name;
    return result;
  }

  TimeZone._();

  factory TimeZone.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TimeZone()..mergeFromBuffer(data, registry);
  factory TimeZone.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TimeZone()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TimeZone',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: TimeZone.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'offsetSeconds')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TimeZone clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TimeZone copyWith(void Function(TimeZone) updates) =>
      super.copyWith((message) => updates(message as TimeZone)) as TimeZone;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TimeZone() / TimeZone.new instead')
  static TimeZone create() => TimeZone._();
  static $pb.GeneratedMessage $_createMessage() => TimeZone._();
  @$core.override
  TimeZone createEmptyInstance() => TimeZone._();
  @$core.pragma('dart2js:noInline')
  static TimeZone getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TimeZone>(TimeZone.$_createMessage);
  static TimeZone? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get offsetSeconds => $_getIZ(0);
  @$pb.TagNumber(1)
  set offsetSeconds($core.int value) => $_setSignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOffsetSeconds() => $_has(0);
  @$pb.TagNumber(1)
  void clearOffsetSeconds() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);
}

/// A simple exception value: type name (e.g. "ValueError") + optional single
/// string argument.
class Exception extends $pb.GeneratedMessage {
  factory Exception({
    $core.String? excType,
    $core.String? arg,
  }) {
    final result = Exception._();
    if (excType != null) result.excType = excType;
    if (arg != null) result.arg = arg;
    return result;
  }

  Exception._();

  factory Exception.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Exception()..mergeFromBuffer(data, registry);
  factory Exception.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Exception()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Exception',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Exception.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'excType')
    ..aOS(2, _omitFieldNames ? '' : 'arg')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Exception clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Exception copyWith(void Function(Exception) updates) =>
      super.copyWith((message) => updates(message as Exception)) as Exception;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Exception() / Exception.new instead')
  static Exception create() => Exception._();
  static $pb.GeneratedMessage $_createMessage() => Exception._();
  @$core.override
  Exception createEmptyInstance() => Exception._();
  @$core.pragma('dart2js:noInline')
  static Exception getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Exception>(Exception.$_createMessage);
  static Exception? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get excType => $_getSZ(0);
  @$pb.TagNumber(1)
  set excType($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExcType() => $_has(0);
  @$pb.TagNumber(1)
  void clearExcType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get arg => $_getSZ(1);
  @$pb.TagNumber(2)
  set arg($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasArg() => $_has(1);
  @$pb.TagNumber(2)
  void clearArg() => $_clearField(2);
}

class FileHandle extends $pb.GeneratedMessage {
  factory FileHandle({
    $core.String? path,
    $core.String? mode,
    $fixnum.Int64? position,
  }) {
    final result = FileHandle._();
    if (path != null) result.path = path;
    if (mode != null) result.mode = mode;
    if (position != null) result.position = position;
    return result;
  }

  FileHandle._();

  factory FileHandle.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FileHandle()..mergeFromBuffer(data, registry);
  factory FileHandle.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FileHandle()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FileHandle',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: FileHandle.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aOS(2, _omitFieldNames ? '' : 'mode')
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'position', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileHandle clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FileHandle copyWith(void Function(FileHandle) updates) =>
      super.copyWith((message) => updates(message as FileHandle)) as FileHandle;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FileHandle() / FileHandle.new instead')
  static FileHandle create() => FileHandle._();
  static $pb.GeneratedMessage $_createMessage() => FileHandle._();
  @$core.override
  FileHandle createEmptyInstance() => FileHandle._();
  @$core.pragma('dart2js:noInline')
  static FileHandle getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FileHandle>(FileHandle.$_createMessage);
  static FileHandle? _defaultInstance;

  /// Virtual (sandbox) path — never a host path.
  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  /// Canonical Python open() mode string: one of r, rb, r+, rb+, w, wb, w+,
  /// wb+, a, ab, a+, ab+.
  @$pb.TagNumber(2)
  $core.String get mode => $_getSZ(1);
  @$pb.TagNumber(2)
  set mode($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMode() => $_has(1);
  @$pb.TagNumber(2)
  void clearMode() => $_clearField(2);

  /// Char index (text mode) or byte index (binary mode).
  @$pb.TagNumber(3)
  $fixnum.Int64 get position => $_getI64(2);
  @$pb.TagNumber(3)
  set position($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPosition() => $_has(2);
  @$pb.TagNumber(3)
  void clearPosition() => $_clearField(3);
}

/// A 16-byte UUID (uuid4). Exactly 16 bytes; validated on decode. Class and
/// instance ids are generated by whichever side defined the object, so they never
/// encode a memory address and cannot be reused the way CPython reuses `id()`.
class Uuid extends $pb.GeneratedMessage {
  factory Uuid({
    $core.List<$core.int>? data,
  }) {
    final result = Uuid._();
    if (data != null) result.data = data;
    return result;
  }

  Uuid._();

  factory Uuid.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Uuid()..mergeFromBuffer(data, registry);
  factory Uuid.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Uuid()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Uuid',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Uuid.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Uuid clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Uuid copyWith(void Function(Uuid) updates) =>
      super.copyWith((message) => updates(message as Uuid)) as Uuid;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Uuid() / Uuid.new instead')
  static Uuid create() => Uuid._();
  static $pb.GeneratedMessage $_createMessage() => Uuid._();
  @$core.override
  Uuid createEmptyInstance() => Uuid._();
  @$core.pragma('dart2js:noInline')
  static Uuid getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Uuid>(Uuid.$_createMessage);
  static Uuid? _defaultInstance;

  @$pb.TagNumber(1)
  $core.List<$core.int> get data => $_getN(0);
  @$pb.TagNumber(1)
  set data($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasData() => $_has(0);
  @$pb.TagNumber(1)
  void clearData() => $_clearField(1);
}

/// A Python type object crossing the sandbox boundary.
class Type extends $pb.GeneratedMessage {
  factory Type({
    $core.String? name,
    Uuid? id,
    TypeOrigin? origin,
    $core.bool? isDataclass,
    NodePairs? attrs,
  }) {
    final result = Type._();
    if (name != null) result.name = name;
    if (id != null) result.id = id;
    if (origin != null) result.origin = origin;
    if (isDataclass != null) result.isDataclass = isDataclass;
    if (attrs != null) result.attrs = attrs;
    return result;
  }

  Type._();

  factory Type.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Type()..mergeFromBuffer(data, registry);
  factory Type.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Type()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Type',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Type.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOM<Uuid>(2, _omitFieldNames ? '' : 'id',
        subBuilder: Uuid.$_createMessage)
    ..aE<TypeOrigin>(3, _omitFieldNames ? '' : 'origin',
        enumValues: TypeOrigin.values)
    ..aOB(4, _omitFieldNames ? '' : 'isDataclass')
    ..aOM<NodePairs>(5, _omitFieldNames ? '' : 'attrs',
        subBuilder: NodePairs.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Type clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Type copyWith(void Function(Type) updates) =>
      super.copyWith((message) => updates(message as Type)) as Type;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Type() / Type.new instead')
  static Type create() => Type._();
  static $pb.GeneratedMessage $_createMessage() => Type._();
  @$core.override
  Type createEmptyInstance() => Type._();
  @$core.pragma('dart2js:noInline')
  static Type getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Type>(Type.$_createMessage);
  static Type? _defaultInstance;

  /// Python-visible name: builtin Display name ("int", "datetime.datetime")
  /// or class name ("Point").
  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Identity of the class; absent iff origin == TYPE_ORIGIN_BUILTIN.
  @$pb.TagNumber(2)
  Uuid get id => $_getN(1);
  @$pb.TagNumber(2)
  set id(Uuid value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasId() => $_has(1);
  @$pb.TagNumber(2)
  void clearId() => $_clearField(2);
  @$pb.TagNumber(2)
  Uuid ensureId() => $_ensure(1);

  /// Where the type was defined (builtin, sandbox, or host).
  @$pb.TagNumber(3)
  TypeOrigin get origin => $_getN(2);
  @$pb.TagNumber(3)
  set origin(TypeOrigin value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasOrigin() => $_has(2);
  @$pb.TagNumber(3)
  void clearOrigin() => $_clearField(3);

  /// Whether `dataclasses.is_dataclass` is true for the class.
  @$pb.TagNumber(4)
  $core.bool get isDataclass => $_getBF(3);
  @$pb.TagNumber(4)
  set isDataclass($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasIsDataclass() => $_has(3);
  @$pb.TagNumber(4)
  void clearIsDataclass() => $_clearField(4);

  /// Class attributes sent eagerly with the type object (class constants, per
  /// the sending wrapper's policy), as `(name, value)` node indexes. The
  /// sandbox keeps one type object per class id: a non-empty set replaces its
  /// attrs, an empty set leaves them unchanged. The worker never sends attrs
  /// for a sandbox class.
  @$pb.TagNumber(5)
  NodePairs get attrs => $_getN(4);
  @$pb.TagNumber(5)
  set attrs(NodePairs value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasAttrs() => $_has(4);
  @$pb.TagNumber(5)
  void clearAttrs() => $_clearField(5);
  @$pb.TagNumber(5)
  NodePairs ensureAttrs() => $_ensure(4);
}

/// A class instance crossing the sandbox boundary. Host-backed instances route
/// method calls and lazy attribute lookups back to the real object by uuid
/// (`FunctionCall.object_id` / `NameLookup.object_id`); sandbox-defined
/// instances carry a worker-generated uuid instead.
class ClassInstanceNode extends $pb.GeneratedMessage {
  factory ClassInstanceNode({
    $core.int? classType,
    Uuid? instanceId,
    NodePairs? attrs,
  }) {
    final result = ClassInstanceNode._();
    if (classType != null) result.classType = classType;
    if (instanceId != null) result.instanceId = instanceId;
    if (attrs != null) result.attrs = attrs;
    return result;
  }

  ClassInstanceNode._();

  factory ClassInstanceNode.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClassInstanceNode()..mergeFromBuffer(data, registry);
  factory ClassInstanceNode.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ClassInstanceNode()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ClassInstanceNode',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ClassInstanceNode.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'classType', fieldType: $pb.PbFieldType.OU3)
    ..aOM<Uuid>(2, _omitFieldNames ? '' : 'instanceId',
        subBuilder: Uuid.$_createMessage)
    ..aOM<NodePairs>(3, _omitFieldNames ? '' : 'attrs',
        subBuilder: NodePairs.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClassInstanceNode clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ClassInstanceNode copyWith(void Function(ClassInstanceNode) updates) =>
      super.copyWith((message) => updates(message as ClassInstanceNode))
          as ClassInstanceNode;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ClassInstanceNode() / ClassInstanceNode.new instead')
  static ClassInstanceNode create() => ClassInstanceNode._();
  static $pb.GeneratedMessage $_createMessage() => ClassInstanceNode._();
  @$core.override
  ClassInstanceNode createEmptyInstance() => ClassInstanceNode._();
  @$core.pragma('dart2js:noInline')
  static ClassInstanceNode getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ClassInstanceNode>(
          ClassInstanceNode.$_createMessage);
  static ClassInstanceNode? _defaultInstance;

  /// Index of the instance's class: a `type` node with origin SANDBOX or HOST
  /// (never BUILTIN), shared by every instance of the class in the arena.
  @$pb.TagNumber(1)
  $core.int get classType => $_getIZ(0);
  @$pb.TagNumber(1)
  set classType($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasClassType() => $_has(0);
  @$pb.TagNumber(1)
  void clearClassType() => $_clearField(1);

  /// Identity of the instance, generated by whichever side defined it.
  @$pb.TagNumber(2)
  Uuid get instanceId => $_getN(1);
  @$pb.TagNumber(2)
  set instanceId(Uuid value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasInstanceId() => $_has(1);
  @$pb.TagNumber(2)
  void clearInstanceId() => $_clearField(2);
  @$pb.TagNumber(2)
  Uuid ensureInstanceId() => $_ensure(1);

  /// Eagerly-sent attributes as `(name, value)` node indexes, in order.
  @$pb.TagNumber(3)
  NodePairs get attrs => $_getN(2);
  @$pb.TagNumber(3)
  set attrs(NodePairs value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasAttrs() => $_has(2);
  @$pb.TagNumber(3)
  void clearAttrs() => $_clearField(3);
  @$pb.TagNumber(3)
  NodePairs ensureAttrs() => $_ensure(2);
}

/// An external (host-provided) function value, usually supplied by the parent
/// in response to a `NameLookup` event.
class Function_ extends $pb.GeneratedMessage {
  factory Function_({
    $core.String? name,
    $core.String? docstring,
  }) {
    final result = Function_._();
    if (name != null) result.name = name;
    if (docstring != null) result.docstring = docstring;
    return result;
  }

  Function_._();

  factory Function_.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Function_()..mergeFromBuffer(data, registry);
  factory Function_.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Function_()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Function',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Function_.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOS(2, _omitFieldNames ? '' : 'docstring')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Function_ clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Function_ copyWith(void Function(Function_) updates) =>
      super.copyWith((message) => updates(message as Function_)) as Function_;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Function_() / Function_.new instead')
  static Function_ create() => Function_._();
  static $pb.GeneratedMessage $_createMessage() => Function_._();
  @$core.override
  Function_ createEmptyInstance() => Function_._();
  @$core.pragma('dart2js:noInline')
  static Function_ getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Function_>(Function_.$_createMessage);
  static Function_? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get docstring => $_getSZ(1);
  @$pb.TagNumber(2)
  set docstring($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDocstring() => $_has(1);
  @$pb.TagNumber(2)
  void clearDocstring() => $_clearField(2);
}

/// A raised Python exception with its traceback. Mirrors monty's
/// `MontyException`.
class RaisedException extends $pb.GeneratedMessage {
  factory RaisedException({
    $core.String? excType,
    $core.String? message,
    $core.Iterable<StackFrame>? traceback,
    ExcData? data,
  }) {
    final result = RaisedException._();
    if (excType != null) result.excType = excType;
    if (message != null) result.message = message;
    if (traceback != null) result.traceback.addAll(traceback);
    if (data != null) result.data = data;
    return result;
  }

  RaisedException._();

  factory RaisedException.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RaisedException()..mergeFromBuffer(data, registry);
  factory RaisedException.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RaisedException()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RaisedException',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: RaisedException.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'excType')
    ..aOS(2, _omitFieldNames ? '' : 'message')
    ..pPM<StackFrame>(3, _omitFieldNames ? '' : 'traceback',
        subBuilder: StackFrame.$_createMessage)
    ..aOM<ExcData>(4, _omitFieldNames ? '' : 'data',
        subBuilder: ExcData.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RaisedException clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RaisedException copyWith(void Function(RaisedException) updates) =>
      super.copyWith((message) => updates(message as RaisedException))
          as RaisedException;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RaisedException() / RaisedException.new instead')
  static RaisedException create() => RaisedException._();
  static $pb.GeneratedMessage $_createMessage() => RaisedException._();
  @$core.override
  RaisedException createEmptyInstance() => RaisedException._();
  @$core.pragma('dart2js:noInline')
  static RaisedException getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<RaisedException>(
          RaisedException.$_createMessage);
  static RaisedException? _defaultInstance;

  /// Exception type name, e.g. "ValueError", "json.JSONDecodeError".
  @$pb.TagNumber(1)
  $core.String get excType => $_getSZ(0);
  @$pb.TagNumber(1)
  set excType($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasExcType() => $_has(0);
  @$pb.TagNumber(1)
  void clearExcType() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get message => $_getSZ(1);
  @$pb.TagNumber(2)
  set message($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMessage() => $_has(1);
  @$pb.TagNumber(2)
  void clearMessage() => $_clearField(2);

  /// Outermost frame first, matching Python traceback order.
  @$pb.TagNumber(3)
  $pb.PbList<StackFrame> get traceback => $_getList(2);

  /// Structured payload for exception types that carry more than a message;
  /// absent for most exceptions. Mirrors monty's `ExcData`.
  @$pb.TagNumber(4)
  ExcData get data => $_getN(3);
  @$pb.TagNumber(4)
  set data(ExcData value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasData() => $_has(3);
  @$pb.TagNumber(4)
  void clearData() => $_clearField(4);
  @$pb.TagNumber(4)
  ExcData ensureData() => $_ensure(3);
}

enum ExcData_Kind { unicode, json, notSet }

/// Structured exception payload, mirroring monty's `ExcData` enum. Future
/// exception types that carry more than a message (e.g. OSError's errno)
/// get new oneof arms with fresh tags. An absent/empty kind means "no
/// payload" (`ExcData::None`).
class ExcData extends $pb.GeneratedMessage {
  factory ExcData({
    UnicodeErrorData? unicode,
    JsonErrorData? json,
  }) {
    final result = ExcData._();
    if (unicode != null) result.unicode = unicode;
    if (json != null) result.json = json;
    return result;
  }

  ExcData._();

  factory ExcData.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ExcData()..mergeFromBuffer(data, registry);
  factory ExcData.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ExcData()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ExcData_Kind> _ExcData_KindByTag = {
    1: ExcData_Kind.unicode,
    2: ExcData_Kind.json,
    0: ExcData_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ExcData',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ExcData.$_createMessage)
    ..oo(0, [1, 2])
    ..aOM<UnicodeErrorData>(1, _omitFieldNames ? '' : 'unicode',
        subBuilder: UnicodeErrorData.$_createMessage)
    ..aOM<JsonErrorData>(2, _omitFieldNames ? '' : 'json',
        subBuilder: JsonErrorData.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ExcData clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ExcData copyWith(void Function(ExcData) updates) =>
      super.copyWith((message) => updates(message as ExcData)) as ExcData;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ExcData() / ExcData.new instead')
  static ExcData create() => ExcData._();
  static $pb.GeneratedMessage $_createMessage() => ExcData._();
  @$core.override
  ExcData createEmptyInstance() => ExcData._();
  @$core.pragma('dart2js:noInline')
  static ExcData getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ExcData>(ExcData.$_createMessage);
  static ExcData? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  ExcData_Kind whichKind() => _ExcData_KindByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  void clearKind() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  UnicodeErrorData get unicode => $_getN(0);
  @$pb.TagNumber(1)
  set unicode(UnicodeErrorData value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasUnicode() => $_has(0);
  @$pb.TagNumber(1)
  void clearUnicode() => $_clearField(1);
  @$pb.TagNumber(1)
  UnicodeErrorData ensureUnicode() => $_ensure(0);

  @$pb.TagNumber(2)
  JsonErrorData get json => $_getN(1);
  @$pb.TagNumber(2)
  set json(JsonErrorData value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasJson() => $_has(1);
  @$pb.TagNumber(2)
  void clearJson() => $_clearField(2);
  @$pb.TagNumber(2)
  JsonErrorData ensureJson() => $_ensure(1);
}

enum UnicodeErrorData_Object { objectBytes, objectStr, notSet }

/// CPython's UnicodeDecodeError/UnicodeEncodeError constructor fields
/// (encoding, object, start, end, reason), letting hosts rebuild the real
/// exception instead of a message-only fallback. Mirrors monty's
/// `UnicodeErrorData`.
class UnicodeErrorData extends $pb.GeneratedMessage {
  factory UnicodeErrorData({
    $core.String? encoding,
    $core.List<$core.int>? objectBytes,
    $core.String? objectStr,
    $fixnum.Int64? start,
    $fixnum.Int64? end,
    $core.String? reason,
  }) {
    final result = UnicodeErrorData._();
    if (encoding != null) result.encoding = encoding;
    if (objectBytes != null) result.objectBytes = objectBytes;
    if (objectStr != null) result.objectStr = objectStr;
    if (start != null) result.start = start;
    if (end != null) result.end = end;
    if (reason != null) result.reason = reason;
    return result;
  }

  UnicodeErrorData._();

  factory UnicodeErrorData.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnicodeErrorData()..mergeFromBuffer(data, registry);
  factory UnicodeErrorData.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      UnicodeErrorData()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, UnicodeErrorData_Object>
      _UnicodeErrorData_ObjectByTag = {
    2: UnicodeErrorData_Object.objectBytes,
    3: UnicodeErrorData_Object.objectStr,
    0: UnicodeErrorData_Object.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'UnicodeErrorData',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: UnicodeErrorData.$_createMessage)
    ..oo(0, [2, 3])
    ..aOS(1, _omitFieldNames ? '' : 'encoding')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'objectBytes', $pb.PbFieldType.OY)
    ..aOS(3, _omitFieldNames ? '' : 'objectStr')
    ..a<$fixnum.Int64>(4, _omitFieldNames ? '' : 'start', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(5, _omitFieldNames ? '' : 'end', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(6, _omitFieldNames ? '' : 'reason')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnicodeErrorData clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  UnicodeErrorData copyWith(void Function(UnicodeErrorData) updates) =>
      super.copyWith((message) => updates(message as UnicodeErrorData))
          as UnicodeErrorData;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use UnicodeErrorData() / UnicodeErrorData.new instead')
  static UnicodeErrorData create() => UnicodeErrorData._();
  static $pb.GeneratedMessage $_createMessage() => UnicodeErrorData._();
  @$core.override
  UnicodeErrorData createEmptyInstance() => UnicodeErrorData._();
  @$core.pragma('dart2js:noInline')
  static UnicodeErrorData getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<UnicodeErrorData>(
          UnicodeErrorData.$_createMessage);
  static UnicodeErrorData? _defaultInstance;

  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  UnicodeErrorData_Object whichObject() =>
      _UnicodeErrorData_ObjectByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearObject() => $_clearField($_whichOneof(0));

  /// Codec name as CPython reports it, e.g. "utf-8".
  @$pb.TagNumber(1)
  $core.String get encoding => $_getSZ(0);
  @$pb.TagNumber(1)
  set encoding($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasEncoding() => $_has(0);
  @$pb.TagNumber(1)
  void clearEncoding() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get objectBytes => $_getN(1);
  @$pb.TagNumber(2)
  set objectBytes($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasObjectBytes() => $_has(1);
  @$pb.TagNumber(2)
  void clearObjectBytes() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get objectStr => $_getSZ(2);
  @$pb.TagNumber(3)
  set objectStr($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasObjectStr() => $_has(2);
  @$pb.TagNumber(3)
  void clearObjectStr() => $_clearField(3);

  /// Failing range: byte offsets for decode errors, character indices for
  /// encode errors. `end` is exclusive.
  @$pb.TagNumber(4)
  $fixnum.Int64 get start => $_getI64(3);
  @$pb.TagNumber(4)
  set start($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasStart() => $_has(3);
  @$pb.TagNumber(4)
  void clearStart() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get end => $_getI64(4);
  @$pb.TagNumber(5)
  set end($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasEnd() => $_has(4);
  @$pb.TagNumber(5)
  void clearEnd() => $_clearField(5);

  /// CPython's reason wording, e.g. "ordinal not in range(128)".
  @$pb.TagNumber(6)
  $core.String get reason => $_getSZ(5);
  @$pb.TagNumber(6)
  set reason($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasReason() => $_has(5);
  @$pb.TagNumber(6)
  void clearReason() => $_clearField(6);
}

/// CPython's json.JSONDecodeError attribute fields (msg, doc, pos, lineno,
/// colno), letting hosts rebuild the real exception instead of a message-only
/// fallback. Mirrors monty's `JsonErrorData`.
class JsonErrorData extends $pb.GeneratedMessage {
  factory JsonErrorData({
    $core.String? msg,
    $core.String? doc,
    $fixnum.Int64? pos,
    $fixnum.Int64? lineno,
    $fixnum.Int64? colno,
  }) {
    final result = JsonErrorData._();
    if (msg != null) result.msg = msg;
    if (doc != null) result.doc = doc;
    if (pos != null) result.pos = pos;
    if (lineno != null) result.lineno = lineno;
    if (colno != null) result.colno = colno;
    return result;
  }

  JsonErrorData._();

  factory JsonErrorData.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      JsonErrorData()..mergeFromBuffer(data, registry);
  factory JsonErrorData.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      JsonErrorData()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'JsonErrorData',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: JsonErrorData.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'msg')
    ..aOS(2, _omitFieldNames ? '' : 'doc')
    ..a<$fixnum.Int64>(3, _omitFieldNames ? '' : 'pos', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(4, _omitFieldNames ? '' : 'lineno', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(5, _omitFieldNames ? '' : 'colno', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  JsonErrorData clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  JsonErrorData copyWith(void Function(JsonErrorData) updates) =>
      super.copyWith((message) => updates(message as JsonErrorData))
          as JsonErrorData;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use JsonErrorData() / JsonErrorData.new instead')
  static JsonErrorData create() => JsonErrorData._();
  static $pb.GeneratedMessage $_createMessage() => JsonErrorData._();
  @$core.override
  JsonErrorData createEmptyInstance() => JsonErrorData._();
  @$core.pragma('dart2js:noInline')
  static JsonErrorData getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<JsonErrorData>(
          JsonErrorData.$_createMessage);
  static JsonErrorData? _defaultInstance;

  /// Bare error message, without the ": line N column M (char K)" suffix.
  @$pb.TagNumber(1)
  $core.String get msg => $_getSZ(0);
  @$pb.TagNumber(1)
  set msg($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMsg() => $_has(0);
  @$pb.TagNumber(1)
  void clearMsg() => $_clearField(1);

  /// The document being parsed; absent when larger than the sender's size cap
  /// or when bytes input is not valid UTF-8.
  @$pb.TagNumber(2)
  $core.String get doc => $_getSZ(1);
  @$pb.TagNumber(2)
  set doc($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDoc() => $_has(1);
  @$pb.TagNumber(2)
  void clearDoc() => $_clearField(2);

  /// Character index of the error in `doc`.
  @$pb.TagNumber(3)
  $fixnum.Int64 get pos => $_getI64(2);
  @$pb.TagNumber(3)
  set pos($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPos() => $_has(2);
  @$pb.TagNumber(3)
  void clearPos() => $_clearField(3);

  /// 1-based line and column of the error.
  @$pb.TagNumber(4)
  $fixnum.Int64 get lineno => $_getI64(3);
  @$pb.TagNumber(4)
  set lineno($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasLineno() => $_has(3);
  @$pb.TagNumber(4)
  void clearLineno() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get colno => $_getI64(4);
  @$pb.TagNumber(5)
  set colno($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasColno() => $_has(4);
  @$pb.TagNumber(5)
  void clearColno() => $_clearField(5);
}

/// 1-based line/column source position (columns count characters, not bytes).
class CodeLoc extends $pb.GeneratedMessage {
  factory CodeLoc({
    $core.int? line,
    $core.int? column,
  }) {
    final result = CodeLoc._();
    if (line != null) result.line = line;
    if (column != null) result.column = column;
    return result;
  }

  CodeLoc._();

  factory CodeLoc.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CodeLoc()..mergeFromBuffer(data, registry);
  factory CodeLoc.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      CodeLoc()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'CodeLoc',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: CodeLoc.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'line', fieldType: $pb.PbFieldType.OU3)
    ..aI(2, _omitFieldNames ? '' : 'column', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CodeLoc clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  CodeLoc copyWith(void Function(CodeLoc) updates) =>
      super.copyWith((message) => updates(message as CodeLoc)) as CodeLoc;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use CodeLoc() / CodeLoc.new instead')
  static CodeLoc create() => CodeLoc._();
  static $pb.GeneratedMessage $_createMessage() => CodeLoc._();
  @$core.override
  CodeLoc createEmptyInstance() => CodeLoc._();
  @$core.pragma('dart2js:noInline')
  static CodeLoc getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<CodeLoc>(CodeLoc.$_createMessage);
  static CodeLoc? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get line => $_getIZ(0);
  @$pb.TagNumber(1)
  set line($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasLine() => $_has(0);
  @$pb.TagNumber(1)
  void clearLine() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get column => $_getIZ(1);
  @$pb.TagNumber(2)
  set column($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasColumn() => $_has(1);
  @$pb.TagNumber(2)
  void clearColumn() => $_clearField(2);
}

/// Where the expression that suspended execution is in the source. `filename`
/// names the source as a traceback frame does: `<python-input-N>` for the
/// session's N-th feed, or `<string>` inside an `eval()` / `exec()` string.
/// `start` and `end` are UTF-8 byte offsets into that source, `end` exclusive.
class SourceRange extends $pb.GeneratedMessage {
  factory SourceRange({
    $core.String? filename,
    $core.int? start,
    $core.int? end,
  }) {
    final result = SourceRange._();
    if (filename != null) result.filename = filename;
    if (start != null) result.start = start;
    if (end != null) result.end = end;
    return result;
  }

  SourceRange._();

  factory SourceRange.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SourceRange()..mergeFromBuffer(data, registry);
  factory SourceRange.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SourceRange()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SourceRange',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: SourceRange.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'filename')
    ..aI(2, _omitFieldNames ? '' : 'start', fieldType: $pb.PbFieldType.OU3)
    ..aI(3, _omitFieldNames ? '' : 'end', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SourceRange clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SourceRange copyWith(void Function(SourceRange) updates) =>
      super.copyWith((message) => updates(message as SourceRange))
          as SourceRange;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SourceRange() / SourceRange.new instead')
  static SourceRange create() => SourceRange._();
  static $pb.GeneratedMessage $_createMessage() => SourceRange._();
  @$core.override
  SourceRange createEmptyInstance() => SourceRange._();
  @$core.pragma('dart2js:noInline')
  static SourceRange getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SourceRange>(
          SourceRange.$_createMessage);
  static SourceRange? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get filename => $_getSZ(0);
  @$pb.TagNumber(1)
  set filename($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFilename() => $_has(0);
  @$pb.TagNumber(1)
  void clearFilename() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get start => $_getIZ(1);
  @$pb.TagNumber(2)
  set start($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasStart() => $_has(1);
  @$pb.TagNumber(2)
  void clearStart() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.int get end => $_getIZ(2);
  @$pb.TagNumber(3)
  set end($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasEnd() => $_has(2);
  @$pb.TagNumber(3)
  void clearEnd() => $_clearField(3);
}

class StackFrame extends $pb.GeneratedMessage {
  factory StackFrame({
    $core.String? filename,
    CodeLoc? start,
    CodeLoc? end,
    $core.String? frameName,
    $core.String? previewLine,
    $core.bool? hideCaret,
    $core.bool? hideFrameName,
  }) {
    final result = StackFrame._();
    if (filename != null) result.filename = filename;
    if (start != null) result.start = start;
    if (end != null) result.end = end;
    if (frameName != null) result.frameName = frameName;
    if (previewLine != null) result.previewLine = previewLine;
    if (hideCaret != null) result.hideCaret = hideCaret;
    if (hideFrameName != null) result.hideFrameName = hideFrameName;
    return result;
  }

  StackFrame._();

  factory StackFrame.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      StackFrame()..mergeFromBuffer(data, registry);
  factory StackFrame.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      StackFrame()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'StackFrame',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: StackFrame.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'filename')
    ..aOM<CodeLoc>(2, _omitFieldNames ? '' : 'start',
        subBuilder: CodeLoc.$_createMessage)
    ..aOM<CodeLoc>(3, _omitFieldNames ? '' : 'end',
        subBuilder: CodeLoc.$_createMessage)
    ..aOS(4, _omitFieldNames ? '' : 'frameName')
    ..aOS(5, _omitFieldNames ? '' : 'previewLine')
    ..aOB(6, _omitFieldNames ? '' : 'hideCaret')
    ..aOB(7, _omitFieldNames ? '' : 'hideFrameName')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StackFrame clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  StackFrame copyWith(void Function(StackFrame) updates) =>
      super.copyWith((message) => updates(message as StackFrame)) as StackFrame;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use StackFrame() / StackFrame.new instead')
  static StackFrame create() => StackFrame._();
  static $pb.GeneratedMessage $_createMessage() => StackFrame._();
  @$core.override
  StackFrame createEmptyInstance() => StackFrame._();
  @$core.pragma('dart2js:noInline')
  static StackFrame getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<StackFrame>(StackFrame.$_createMessage);
  static StackFrame? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get filename => $_getSZ(0);
  @$pb.TagNumber(1)
  set filename($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFilename() => $_has(0);
  @$pb.TagNumber(1)
  void clearFilename() => $_clearField(1);

  @$pb.TagNumber(2)
  CodeLoc get start => $_getN(1);
  @$pb.TagNumber(2)
  set start(CodeLoc value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasStart() => $_has(1);
  @$pb.TagNumber(2)
  void clearStart() => $_clearField(2);
  @$pb.TagNumber(2)
  CodeLoc ensureStart() => $_ensure(1);

  @$pb.TagNumber(3)
  CodeLoc get end => $_getN(2);
  @$pb.TagNumber(3)
  set end(CodeLoc value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasEnd() => $_has(2);
  @$pb.TagNumber(3)
  void clearEnd() => $_clearField(3);
  @$pb.TagNumber(3)
  CodeLoc ensureEnd() => $_ensure(2);

  /// Function name; absent for module-level code (rendered as "<module>").
  @$pb.TagNumber(4)
  $core.String get frameName => $_getSZ(3);
  @$pb.TagNumber(4)
  set frameName($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasFrameName() => $_has(3);
  @$pb.TagNumber(4)
  void clearFrameName() => $_clearField(4);

  /// Source line shown in the traceback preview.
  @$pb.TagNumber(5)
  $core.String get previewLine => $_getSZ(4);
  @$pb.TagNumber(5)
  set previewLine($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasPreviewLine() => $_has(4);
  @$pb.TagNumber(5)
  void clearPreviewLine() => $_clearField(5);

  /// Suppress the `~~~` caret markers for this frame.
  @$pb.TagNumber(6)
  $core.bool get hideCaret => $_getBF(5);
  @$pb.TagNumber(6)
  set hideCaret($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasHideCaret() => $_has(5);
  @$pb.TagNumber(6)
  void clearHideCaret() => $_clearField(6);

  /// Suppress the `, in <name>` suffix (SyntaxError style).
  @$pb.TagNumber(7)
  $core.bool get hideFrameName => $_getBF(6);
  @$pb.TagNumber(7)
  set hideFrameName($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasHideFrameName() => $_has(6);
  @$pb.TagNumber(7)
  void clearHideFrameName() => $_clearField(7);
}

/// Sandbox resource limits. Absent fields are unlimited except recursion depth
/// and `max_suspensions`, which both default to 1000. The parent enforces
/// `max_suspensions`; the child only retains it for dumps and echoes it on
/// `ChildEvent`.
class ResourceLimits extends $pb.GeneratedMessage {
  factory ResourceLimits({
    $fixnum.Int64? maxMemoryBytes,
    $fixnum.Int64? gcInterval,
    $fixnum.Int64? maxRecursionDepth,
    $fixnum.Int64? maxSuspensions,
    $fixnum.Int64? maxFeedDurationMicros,
    $fixnum.Int64? maxTurnDurationMicros,
    $fixnum.Int64? maxTotalSleepMicros,
  }) {
    final result = ResourceLimits._();
    if (maxMemoryBytes != null) result.maxMemoryBytes = maxMemoryBytes;
    if (gcInterval != null) result.gcInterval = gcInterval;
    if (maxRecursionDepth != null) result.maxRecursionDepth = maxRecursionDepth;
    if (maxSuspensions != null) result.maxSuspensions = maxSuspensions;
    if (maxFeedDurationMicros != null)
      result.maxFeedDurationMicros = maxFeedDurationMicros;
    if (maxTurnDurationMicros != null)
      result.maxTurnDurationMicros = maxTurnDurationMicros;
    if (maxTotalSleepMicros != null)
      result.maxTotalSleepMicros = maxTotalSleepMicros;
    return result;
  }

  ResourceLimits._();

  factory ResourceLimits.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResourceLimits()..mergeFromBuffer(data, registry);
  factory ResourceLimits.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResourceLimits()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ResourceLimits',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ResourceLimits.$_createMessage)
    ..a<$fixnum.Int64>(
        2, _omitFieldNames ? '' : 'maxMemoryBytes', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        3, _omitFieldNames ? '' : 'gcInterval', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        4, _omitFieldNames ? '' : 'maxRecursionDepth', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        5, _omitFieldNames ? '' : 'maxSuspensions', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        6, _omitFieldNames ? '' : 'maxFeedDurationMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        7, _omitFieldNames ? '' : 'maxTurnDurationMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        8, _omitFieldNames ? '' : 'maxTotalSleepMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResourceLimits clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResourceLimits copyWith(void Function(ResourceLimits) updates) =>
      super.copyWith((message) => updates(message as ResourceLimits))
          as ResourceLimits;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ResourceLimits() / ResourceLimits.new instead')
  static ResourceLimits create() => ResourceLimits._();
  static $pb.GeneratedMessage $_createMessage() => ResourceLimits._();
  @$core.override
  ResourceLimits createEmptyInstance() => ResourceLimits._();
  @$core.pragma('dart2js:noInline')
  static ResourceLimits getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ResourceLimits>(
          ResourceLimits.$_createMessage);
  static ResourceLimits? _defaultInstance;

  @$pb.TagNumber(2)
  $fixnum.Int64 get maxMemoryBytes => $_getI64(0);
  @$pb.TagNumber(2)
  set maxMemoryBytes($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(2)
  $core.bool hasMaxMemoryBytes() => $_has(0);
  @$pb.TagNumber(2)
  void clearMaxMemoryBytes() => $_clearField(2);

  @$pb.TagNumber(3)
  $fixnum.Int64 get gcInterval => $_getI64(1);
  @$pb.TagNumber(3)
  set gcInterval($fixnum.Int64 value) => $_setInt64(1, value);
  @$pb.TagNumber(3)
  $core.bool hasGcInterval() => $_has(1);
  @$pb.TagNumber(3)
  void clearGcInterval() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get maxRecursionDepth => $_getI64(2);
  @$pb.TagNumber(4)
  set maxRecursionDepth($fixnum.Int64 value) => $_setInt64(2, value);
  @$pb.TagNumber(4)
  $core.bool hasMaxRecursionDepth() => $_has(2);
  @$pb.TagNumber(4)
  void clearMaxRecursionDepth() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get maxSuspensions => $_getI64(3);
  @$pb.TagNumber(5)
  set maxSuspensions($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(5)
  $core.bool hasMaxSuspensions() => $_has(3);
  @$pb.TagNumber(5)
  void clearMaxSuspensions() => $_clearField(5);

  /// Per-feed and per-turn execution budgets on one clock: the feed budget
  /// resets at each feed, the turn budget at each feed and each resume.
  @$pb.TagNumber(6)
  $fixnum.Int64 get maxFeedDurationMicros => $_getI64(4);
  @$pb.TagNumber(6)
  set maxFeedDurationMicros($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(6)
  $core.bool hasMaxFeedDurationMicros() => $_has(4);
  @$pb.TagNumber(6)
  void clearMaxFeedDurationMicros() => $_clearField(6);

  @$pb.TagNumber(7)
  $fixnum.Int64 get maxTurnDurationMicros => $_getI64(5);
  @$pb.TagNumber(7)
  set maxTurnDurationMicros($fixnum.Int64 value) => $_setInt64(5, value);
  @$pb.TagNumber(7)
  $core.bool hasMaxTurnDurationMicros() => $_has(5);
  @$pb.TagNumber(7)
  void clearMaxTurnDurationMicros() => $_clearField(7);

  /// Cumulative budget for system sleeps, enforced by the parent.
  @$pb.TagNumber(8)
  $fixnum.Int64 get maxTotalSleepMicros => $_getI64(6);
  @$pb.TagNumber(8)
  set maxTotalSleepMicros($fixnum.Int64 value) => $_setInt64(6, value);
  @$pb.TagNumber(8)
  $core.bool hasMaxTotalSleepMicros() => $_has(6);
  @$pb.TagNumber(8)
  void clearMaxTotalSleepMicros() => $_clearField(8);
}

enum OsPolicy_Datetime { system, callHost, fixed, notSet }

enum OsPolicy_RandomStart { randomSystem, randomCallHost, seed, notSet }

enum OsPolicy_ProcessTime { zero, elapsed, notSet }

/// Mirrors monty's `OsPolicy`: the clock, zone, sleep, process clock and
/// initial randomness a session gets, and which of those it asks the host for.
/// Each unset arm means that field's default.
class OsPolicy extends $pb.GeneratedMessage {
  factory OsPolicy({
    Unit? system,
    Unit? callHost,
    FixedDateTime? fixed,
    SandboxTimeZone? timezone,
    SleepMode? sleep,
    Unit? randomSystem,
    Unit? randomCallHost,
    RandomSeed? seed,
    Unit? zero,
    Unit? elapsed,
  }) {
    final result = OsPolicy._();
    if (system != null) result.system = system;
    if (callHost != null) result.callHost = callHost;
    if (fixed != null) result.fixed = fixed;
    if (timezone != null) result.timezone = timezone;
    if (sleep != null) result.sleep = sleep;
    if (randomSystem != null) result.randomSystem = randomSystem;
    if (randomCallHost != null) result.randomCallHost = randomCallHost;
    if (seed != null) result.seed = seed;
    if (zero != null) result.zero = zero;
    if (elapsed != null) result.elapsed = elapsed;
    return result;
  }

  OsPolicy._();

  factory OsPolicy.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsPolicy()..mergeFromBuffer(data, registry);
  factory OsPolicy.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsPolicy()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, OsPolicy_Datetime> _OsPolicy_DatetimeByTag =
      {
    1: OsPolicy_Datetime.system,
    2: OsPolicy_Datetime.callHost,
    3: OsPolicy_Datetime.fixed,
    0: OsPolicy_Datetime.notSet
  };
  static const $core.Map<$core.int, OsPolicy_RandomStart>
      _OsPolicy_RandomStartByTag = {
    6: OsPolicy_RandomStart.randomSystem,
    7: OsPolicy_RandomStart.randomCallHost,
    8: OsPolicy_RandomStart.seed,
    0: OsPolicy_RandomStart.notSet
  };
  static const $core.Map<$core.int, OsPolicy_ProcessTime>
      _OsPolicy_ProcessTimeByTag = {
    9: OsPolicy_ProcessTime.zero,
    10: OsPolicy_ProcessTime.elapsed,
    0: OsPolicy_ProcessTime.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsPolicy',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsPolicy.$_createMessage)
    ..oo(0, [1, 2, 3])
    ..oo(1, [6, 7, 8])
    ..oo(2, [9, 10])
    ..aOM<Unit>(1, _omitFieldNames ? '' : 'system',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(2, _omitFieldNames ? '' : 'callHost',
        subBuilder: Unit.$_createMessage)
    ..aOM<FixedDateTime>(3, _omitFieldNames ? '' : 'fixed',
        subBuilder: FixedDateTime.$_createMessage)
    ..aOM<SandboxTimeZone>(4, _omitFieldNames ? '' : 'timezone',
        subBuilder: SandboxTimeZone.$_createMessage)
    ..aOM<SleepMode>(5, _omitFieldNames ? '' : 'sleep',
        subBuilder: SleepMode.$_createMessage)
    ..aOM<Unit>(6, _omitFieldNames ? '' : 'randomSystem',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(7, _omitFieldNames ? '' : 'randomCallHost',
        subBuilder: Unit.$_createMessage)
    ..aOM<RandomSeed>(8, _omitFieldNames ? '' : 'seed',
        subBuilder: RandomSeed.$_createMessage)
    ..aOM<Unit>(9, _omitFieldNames ? '' : 'zero',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(10, _omitFieldNames ? '' : 'elapsed',
        subBuilder: Unit.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsPolicy clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsPolicy copyWith(void Function(OsPolicy) updates) =>
      super.copyWith((message) => updates(message as OsPolicy)) as OsPolicy;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsPolicy() / OsPolicy.new instead')
  static OsPolicy create() => OsPolicy._();
  static $pb.GeneratedMessage $_createMessage() => OsPolicy._();
  @$core.override
  OsPolicy createEmptyInstance() => OsPolicy._();
  @$core.pragma('dart2js:noInline')
  static OsPolicy getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OsPolicy>(OsPolicy.$_createMessage);
  static OsPolicy? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  OsPolicy_Datetime whichDatetime() =>
      _OsPolicy_DatetimeByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearDatetime() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  OsPolicy_RandomStart whichRandomStart() =>
      _OsPolicy_RandomStartByTag[$_whichOneof(1)]!;
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  void clearRandomStart() => $_clearField($_whichOneof(1));

  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  OsPolicy_ProcessTime whichProcessTime() =>
      _OsPolicy_ProcessTimeByTag[$_whichOneof(2)]!;
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  void clearProcessTime() => $_clearField($_whichOneof(2));

  /// The child's clock.
  @$pb.TagNumber(1)
  Unit get system => $_getN(0);
  @$pb.TagNumber(1)
  set system(Unit value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSystem() => $_has(0);
  @$pb.TagNumber(1)
  void clearSystem() => $_clearField(1);
  @$pb.TagNumber(1)
  Unit ensureSystem() => $_ensure(0);

  /// Suspend to the parent's OS handler.
  @$pb.TagNumber(2)
  Unit get callHost => $_getN(1);
  @$pb.TagNumber(2)
  set callHost(Unit value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasCallHost() => $_has(1);
  @$pb.TagNumber(2)
  void clearCallHost() => $_clearField(2);
  @$pb.TagNumber(2)
  Unit ensureCallHost() => $_ensure(1);

  /// One frozen instant, for reproducible runs.
  @$pb.TagNumber(3)
  FixedDateTime get fixed => $_getN(2);
  @$pb.TagNumber(3)
  set fixed(FixedDateTime value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasFixed() => $_has(2);
  @$pb.TagNumber(3)
  void clearFixed() => $_clearField(3);
  @$pb.TagNumber(3)
  FixedDateTime ensureFixed() => $_ensure(2);

  /// The zone naive `datetime.now()` and `date.today()` read in, and that
  /// `astimezone()`, `%Z` and the `time` constants report. Absent = UTC.
  @$pb.TagNumber(4)
  SandboxTimeZone get timezone => $_getN(3);
  @$pb.TagNumber(4)
  set timezone(SandboxTimeZone value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasTimezone() => $_has(3);
  @$pb.TagNumber(4)
  void clearTimezone() => $_clearField(4);
  @$pb.TagNumber(4)
  SandboxTimeZone ensureTimezone() => $_ensure(3);

  /// What `time.sleep()` and `asyncio.sleep()` do.
  /// Absent (or with no arm set) = system sleep with the default maximum.
  @$pb.TagNumber(5)
  SleepMode get sleep => $_getN(4);
  @$pb.TagNumber(5)
  set sleep(SleepMode value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasSleep() => $_has(4);
  @$pb.TagNumber(5)
  void clearSleep() => $_clearField(5);
  @$pb.TagNumber(5)
  SleepMode ensureSleep() => $_ensure(4);

  /// From the child's own OS entropy.
  @$pb.TagNumber(6)
  Unit get randomSystem => $_getN(5);
  @$pb.TagNumber(6)
  set randomSystem(Unit value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasRandomSystem() => $_has(5);
  @$pb.TagNumber(6)
  void clearRandomSystem() => $_clearField(6);
  @$pb.TagNumber(6)
  Unit ensureRandomSystem() => $_ensure(5);

  /// Suspend the first draw with an `os.urandom` call for 2496 bytes.
  @$pb.TagNumber(7)
  Unit get randomCallHost => $_getN(6);
  @$pb.TagNumber(7)
  set randomCallHost(Unit value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasRandomCallHost() => $_has(6);
  @$pb.TagNumber(7)
  void clearRandomCallHost() => $_clearField(7);
  @$pb.TagNumber(7)
  Unit ensureRandomCallHost() => $_ensure(6);

  /// As `random.seed(seed)` would, for reproducible runs.
  @$pb.TagNumber(8)
  RandomSeed get seed => $_getN(7);
  @$pb.TagNumber(8)
  set seed(RandomSeed value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasSeed() => $_has(7);
  @$pb.TagNumber(8)
  void clearSeed() => $_clearField(8);
  @$pb.TagNumber(8)
  RandomSeed ensureSeed() => $_ensure(7);

  /// Always 0.0, so elapsed execution time is not observable in the sandbox.
  @$pb.TagNumber(9)
  Unit get zero => $_getN(8);
  @$pb.TagNumber(9)
  set zero(Unit value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasZero() => $_has(8);
  @$pb.TagNumber(9)
  void clearZero() => $_clearField(9);
  @$pb.TagNumber(9)
  Unit ensureZero() => $_ensure(8);

  /// The session's accumulated execution time.
  @$pb.TagNumber(10)
  Unit get elapsed => $_getN(9);
  @$pb.TagNumber(10)
  set elapsed(Unit value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasElapsed() => $_has(9);
  @$pb.TagNumber(10)
  void clearElapsed() => $_clearField(10);
  @$pb.TagNumber(10)
  Unit ensureElapsed() => $_ensure(9);
}

enum SandboxTimeZone_Zone { utc, named, fixed, notSet }

/// Mirrors monty's `SandboxTimeZone`.
class SandboxTimeZone extends $pb.GeneratedMessage {
  factory SandboxTimeZone({
    Unit? utc,
    $core.String? named,
    TimeZone? fixed,
  }) {
    final result = SandboxTimeZone._();
    if (utc != null) result.utc = utc;
    if (named != null) result.named = named;
    if (fixed != null) result.fixed = fixed;
    return result;
  }

  SandboxTimeZone._();

  factory SandboxTimeZone.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SandboxTimeZone()..mergeFromBuffer(data, registry);
  factory SandboxTimeZone.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SandboxTimeZone()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, SandboxTimeZone_Zone>
      _SandboxTimeZone_ZoneByTag = {
    1: SandboxTimeZone_Zone.utc,
    2: SandboxTimeZone_Zone.named,
    3: SandboxTimeZone_Zone.fixed,
    0: SandboxTimeZone_Zone.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SandboxTimeZone',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: SandboxTimeZone.$_createMessage)
    ..oo(0, [1, 2, 3])
    ..aOM<Unit>(1, _omitFieldNames ? '' : 'utc',
        subBuilder: Unit.$_createMessage)
    ..aOS(2, _omitFieldNames ? '' : 'named')
    ..aOM<TimeZone>(3, _omitFieldNames ? '' : 'fixed',
        subBuilder: TimeZone.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SandboxTimeZone clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SandboxTimeZone copyWith(void Function(SandboxTimeZone) updates) =>
      super.copyWith((message) => updates(message as SandboxTimeZone))
          as SandboxTimeZone;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SandboxTimeZone() / SandboxTimeZone.new instead')
  static SandboxTimeZone create() => SandboxTimeZone._();
  static $pb.GeneratedMessage $_createMessage() => SandboxTimeZone._();
  @$core.override
  SandboxTimeZone createEmptyInstance() => SandboxTimeZone._();
  @$core.pragma('dart2js:noInline')
  static SandboxTimeZone getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SandboxTimeZone>(
          SandboxTimeZone.$_createMessage);
  static SandboxTimeZone? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  SandboxTimeZone_Zone whichZone() =>
      _SandboxTimeZone_ZoneByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearZone() => $_clearField($_whichOneof(0));

  /// UTC, the default.
  @$pb.TagNumber(1)
  Unit get utc => $_getN(0);
  @$pb.TagNumber(1)
  set utc(Unit value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasUtc() => $_has(0);
  @$pb.TagNumber(1)
  void clearUtc() => $_clearField(1);
  @$pb.TagNumber(1)
  Unit ensureUtc() => $_ensure(0);

  /// An IANA zone name (`Europe/London`), resolved from the child's tz database.
  @$pb.TagNumber(2)
  $core.String get named => $_getSZ(1);
  @$pb.TagNumber(2)
  set named($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasNamed() => $_has(1);
  @$pb.TagNumber(2)
  void clearNamed() => $_clearField(2);

  /// A fixed offset from UTC, with a name if it has one.
  @$pb.TagNumber(3)
  TimeZone get fixed => $_getN(2);
  @$pb.TagNumber(3)
  set fixed(TimeZone value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasFixed() => $_has(2);
  @$pb.TagNumber(3)
  void clearFixed() => $_clearField(3);
  @$pb.TagNumber(3)
  TimeZone ensureFixed() => $_ensure(2);
}

enum SleepMode_Mode { system, callHost, zero, notSet }

/// Mirrors monty's `SleepMode`.
class SleepMode extends $pb.GeneratedMessage {
  factory SleepMode({
    SystemSleep? system,
    Unit? callHost,
    Unit? zero,
  }) {
    final result = SleepMode._();
    if (system != null) result.system = system;
    if (callHost != null) result.callHost = callHost;
    if (zero != null) result.zero = zero;
    return result;
  }

  SleepMode._();

  factory SleepMode.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SleepMode()..mergeFromBuffer(data, registry);
  factory SleepMode.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SleepMode()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, SleepMode_Mode> _SleepMode_ModeByTag = {
    1: SleepMode_Mode.system,
    2: SleepMode_Mode.callHost,
    3: SleepMode_Mode.zero,
    0: SleepMode_Mode.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SleepMode',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: SleepMode.$_createMessage)
    ..oo(0, [1, 2, 3])
    ..aOM<SystemSleep>(1, _omitFieldNames ? '' : 'system',
        subBuilder: SystemSleep.$_createMessage)
    ..aOM<Unit>(2, _omitFieldNames ? '' : 'callHost',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(3, _omitFieldNames ? '' : 'zero',
        subBuilder: Unit.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SleepMode clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SleepMode copyWith(void Function(SleepMode) updates) =>
      super.copyWith((message) => updates(message as SleepMode)) as SleepMode;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SleepMode() / SleepMode.new instead')
  static SleepMode create() => SleepMode._();
  static $pb.GeneratedMessage $_createMessage() => SleepMode._();
  @$core.override
  SleepMode createEmptyInstance() => SleepMode._();
  @$core.pragma('dart2js:noInline')
  static SleepMode getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<SleepMode>(SleepMode.$_createMessage);
  static SleepMode? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  SleepMode_Mode whichMode() => _SleepMode_ModeByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  void clearMode() => $_clearField($_whichOneof(0));

  /// The parent waits without invoking its OS handler.
  @$pb.TagNumber(1)
  SystemSleep get system => $_getN(0);
  @$pb.TagNumber(1)
  set system(SystemSleep value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasSystem() => $_has(0);
  @$pb.TagNumber(1)
  void clearSystem() => $_clearField(1);
  @$pb.TagNumber(1)
  SystemSleep ensureSystem() => $_ensure(0);

  /// Suspend to the parent, which performs the wait.
  @$pb.TagNumber(2)
  Unit get callHost => $_getN(1);
  @$pb.TagNumber(2)
  set callHost(Unit value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasCallHost() => $_has(1);
  @$pb.TagNumber(2)
  void clearCallHost() => $_clearField(2);
  @$pb.TagNumber(2)
  Unit ensureCallHost() => $_ensure(1);

  /// Return at once without waiting.
  @$pb.TagNumber(3)
  Unit get zero => $_getN(2);
  @$pb.TagNumber(3)
  set zero(Unit value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasZero() => $_has(2);
  @$pb.TagNumber(3)
  void clearZero() => $_clearField(3);
  @$pb.TagNumber(3)
  Unit ensureZero() => $_ensure(2);
}

/// A sleep capped by the child and performed by the parent.
class SystemSleep extends $pb.GeneratedMessage {
  factory SystemSleep({
    $fixnum.Int64? maxMicros,
  }) {
    final result = SystemSleep._();
    if (maxMicros != null) result.maxMicros = maxMicros;
    return result;
  }

  SystemSleep._();

  factory SystemSleep.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SystemSleep()..mergeFromBuffer(data, registry);
  factory SystemSleep.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      SystemSleep()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'SystemSleep',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: SystemSleep.$_createMessage)
    ..a<$fixnum.Int64>(
        1, _omitFieldNames ? '' : 'maxMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SystemSleep clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  SystemSleep copyWith(void Function(SystemSleep) updates) =>
      super.copyWith((message) => updates(message as SystemSleep))
          as SystemSleep;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use SystemSleep() / SystemSleep.new instead')
  static SystemSleep create() => SystemSleep._();
  static $pb.GeneratedMessage $_createMessage() => SystemSleep._();
  @$core.override
  SystemSleep createEmptyInstance() => SystemSleep._();
  @$core.pragma('dart2js:noInline')
  static SystemSleep getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<SystemSleep>(
          SystemSleep.$_createMessage);
  static SystemSleep? _defaultInstance;

  /// Longest wait one call performs; longer sleeps are cut short. Absent = 10s.
  @$pb.TagNumber(1)
  $fixnum.Int64 get maxMicros => $_getI64(0);
  @$pb.TagNumber(1)
  set maxMicros($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMaxMicros() => $_has(0);
  @$pb.TagNumber(1)
  void clearMaxMicros() => $_clearField(1);
}

/// A frozen clock reading.
class FixedDateTime extends $pb.GeneratedMessage {
  factory FixedDateTime({
    $fixnum.Int64? unixSeconds,
    $core.int? microsecond,
  }) {
    final result = FixedDateTime._();
    if (unixSeconds != null) result.unixSeconds = unixSeconds;
    if (microsecond != null) result.microsecond = microsecond;
    return result;
  }

  FixedDateTime._();

  factory FixedDateTime.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FixedDateTime()..mergeFromBuffer(data, registry);
  factory FixedDateTime.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FixedDateTime()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FixedDateTime',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: FixedDateTime.$_createMessage)
    ..aInt64(1, _omitFieldNames ? '' : 'unixSeconds')
    ..aI(2, _omitFieldNames ? '' : 'microsecond',
        fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FixedDateTime clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FixedDateTime copyWith(void Function(FixedDateTime) updates) =>
      super.copyWith((message) => updates(message as FixedDateTime))
          as FixedDateTime;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FixedDateTime() / FixedDateTime.new instead')
  static FixedDateTime create() => FixedDateTime._();
  static $pb.GeneratedMessage $_createMessage() => FixedDateTime._();
  @$core.override
  FixedDateTime createEmptyInstance() => FixedDateTime._();
  @$core.pragma('dart2js:noInline')
  static FixedDateTime getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FixedDateTime>(
          FixedDateTime.$_createMessage);
  static FixedDateTime? _defaultInstance;

  /// Seconds since the Unix epoch, UTC.
  @$pb.TagNumber(1)
  $fixnum.Int64 get unixSeconds => $_getI64(0);
  @$pb.TagNumber(1)
  set unixSeconds($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasUnixSeconds() => $_has(0);
  @$pb.TagNumber(1)
  void clearUnixSeconds() => $_clearField(1);

  /// 0..=999999; anything larger is rejected.
  @$pb.TagNumber(2)
  $core.int get microsecond => $_getIZ(1);
  @$pb.TagNumber(2)
  set microsecond($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMicrosecond() => $_has(1);
  @$pb.TagNumber(2)
  void clearMicrosecond() => $_clearField(2);
}

enum RandomSeed_Value { int_1, float, str, bytes, notSet }

/// A `random.seed()` argument: the types CPython accepts.
class RandomSeed extends $pb.GeneratedMessage {
  factory RandomSeed({
    $core.List<$core.int>? int_1,
    $core.double? float,
    $core.String? str,
    $core.List<$core.int>? bytes,
  }) {
    final result = RandomSeed._();
    if (int_1 != null) result.int_1 = int_1;
    if (float != null) result.float = float;
    if (str != null) result.str = str;
    if (bytes != null) result.bytes = bytes;
    return result;
  }

  RandomSeed._();

  factory RandomSeed.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RandomSeed()..mergeFromBuffer(data, registry);
  factory RandomSeed.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      RandomSeed()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, RandomSeed_Value> _RandomSeed_ValueByTag = {
    1: RandomSeed_Value.int_1,
    2: RandomSeed_Value.float,
    3: RandomSeed_Value.str,
    4: RandomSeed_Value.bytes,
    0: RandomSeed_Value.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'RandomSeed',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: RandomSeed.$_createMessage)
    ..oo(0, [1, 2, 3, 4])
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'int', $pb.PbFieldType.OY)
    ..aD(2, _omitFieldNames ? '' : 'float')
    ..aOS(3, _omitFieldNames ? '' : 'str')
    ..a<$core.List<$core.int>>(
        4, _omitFieldNames ? '' : 'bytes', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RandomSeed clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  RandomSeed copyWith(void Function(RandomSeed) updates) =>
      super.copyWith((message) => updates(message as RandomSeed)) as RandomSeed;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use RandomSeed() / RandomSeed.new instead')
  static RandomSeed create() => RandomSeed._();
  static $pb.GeneratedMessage $_createMessage() => RandomSeed._();
  @$core.override
  RandomSeed createEmptyInstance() => RandomSeed._();
  @$core.pragma('dart2js:noInline')
  static RandomSeed getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<RandomSeed>(RandomSeed.$_createMessage);
  static RandomSeed? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  RandomSeed_Value whichValue() => _RandomSeed_ValueByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  void clearValue() => $_clearField($_whichOneof(0));

  /// Arbitrary-size two's-complement little-endian bytes (`BigInt::to_signed_bytes_le`).
  @$pb.TagNumber(1)
  $core.List<$core.int> get int_1 => $_getN(0);
  @$pb.TagNumber(1)
  set int_1($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasInt_1() => $_has(0);
  @$pb.TagNumber(1)
  void clearInt_1() => $_clearField(1);

  /// Must be finite.
  @$pb.TagNumber(2)
  $core.double get float => $_getN(1);
  @$pb.TagNumber(2)
  set float($core.double value) => $_setDouble(1, value);
  @$pb.TagNumber(2)
  $core.bool hasFloat() => $_has(1);
  @$pb.TagNumber(2)
  void clearFloat() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get str => $_getSZ(2);
  @$pb.TagNumber(3)
  set str($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasStr() => $_has(2);
  @$pb.TagNumber(3)
  void clearStr() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.List<$core.int> get bytes => $_getN(3);
  @$pb.TagNumber(4)
  set bytes($core.List<$core.int> value) => $_setBytes(3, value);
  @$pb.TagNumber(4)
  $core.bool hasBytes() => $_has(3);
  @$pb.TagNumber(4)
  void clearBytes() => $_clearField(4);
}

enum ExtFunctionResult_Kind {
  returnValue,
  error,
  future,
  notFound,
  notHandled,
  notSet
}

/// Outcome of an external function / OS call, decided by the parent. Mirrors
/// monty's `ExtFunctionResult`, plus `not_handled` (which only the child can
/// resolve, against its suspended call).
class ExtFunctionResult extends $pb.GeneratedMessage {
  factory ExtFunctionResult({
    $core.int? returnValue,
    RaisedException? error,
    $core.int? future,
    $core.String? notFound,
    Unit? notHandled,
  }) {
    final result = ExtFunctionResult._();
    if (returnValue != null) result.returnValue = returnValue;
    if (error != null) result.error = error;
    if (future != null) result.future = future;
    if (notFound != null) result.notFound = notFound;
    if (notHandled != null) result.notHandled = notHandled;
    return result;
  }

  ExtFunctionResult._();

  factory ExtFunctionResult.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ExtFunctionResult()..mergeFromBuffer(data, registry);
  factory ExtFunctionResult.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ExtFunctionResult()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ExtFunctionResult_Kind>
      _ExtFunctionResult_KindByTag = {
    1: ExtFunctionResult_Kind.returnValue,
    2: ExtFunctionResult_Kind.error,
    3: ExtFunctionResult_Kind.future,
    4: ExtFunctionResult_Kind.notFound,
    5: ExtFunctionResult_Kind.notHandled,
    0: ExtFunctionResult_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ExtFunctionResult',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ExtFunctionResult.$_createMessage)
    ..oo(0, [1, 2, 3, 4, 5])
    ..aI(1, _omitFieldNames ? '' : 'returnValue',
        fieldType: $pb.PbFieldType.OU3)
    ..aOM<RaisedException>(2, _omitFieldNames ? '' : 'error',
        subBuilder: RaisedException.$_createMessage)
    ..aI(3, _omitFieldNames ? '' : 'future', fieldType: $pb.PbFieldType.OU3)
    ..aOS(4, _omitFieldNames ? '' : 'notFound')
    ..aOM<Unit>(5, _omitFieldNames ? '' : 'notHandled',
        subBuilder: Unit.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ExtFunctionResult clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ExtFunctionResult copyWith(void Function(ExtFunctionResult) updates) =>
      super.copyWith((message) => updates(message as ExtFunctionResult))
          as ExtFunctionResult;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ExtFunctionResult() / ExtFunctionResult.new instead')
  static ExtFunctionResult create() => ExtFunctionResult._();
  static $pb.GeneratedMessage $_createMessage() => ExtFunctionResult._();
  @$core.override
  ExtFunctionResult createEmptyInstance() => ExtFunctionResult._();
  @$core.pragma('dart2js:noInline')
  static ExtFunctionResult getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ExtFunctionResult>(
          ExtFunctionResult.$_createMessage);
  static ExtFunctionResult? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  ExtFunctionResult_Kind whichKind() =>
      _ExtFunctionResult_KindByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  void clearKind() => $_clearField($_whichOneof(0));

  /// The call returned this value: an index into the carrying message's
  /// `values` arena.
  @$pb.TagNumber(1)
  $core.int get returnValue => $_getIZ(0);
  @$pb.TagNumber(1)
  set returnValue($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasReturnValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearReturnValue() => $_clearField(1);

  /// The call raised this exception.
  @$pb.TagNumber(2)
  RaisedException get error => $_getN(1);
  @$pb.TagNumber(2)
  set error(RaisedException value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasError() => $_has(1);
  @$pb.TagNumber(2)
  void clearError() => $_clearField(2);
  @$pb.TagNumber(2)
  RaisedException ensureError() => $_ensure(1);

  /// The call is asynchronous: register an external future for `call_id`
  /// (the id from the suspension event) and keep executing other tasks.
  @$pb.TagNumber(3)
  $core.int get future => $_getIZ(2);
  @$pb.TagNumber(3)
  set future($core.int value) => $_setUnsignedInt32(2, value);
  @$pb.TagNumber(3)
  $core.bool hasFuture() => $_has(2);
  @$pb.TagNumber(3)
  void clearFuture() => $_clearField(3);

  /// No handler exists for this name — the child raises NameError.
  @$pb.TagNumber(4)
  $core.String get notFound => $_getSZ(3);
  @$pb.TagNumber(4)
  set notFound($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasNotFound() => $_has(3);
  @$pb.TagNumber(4)
  void clearNotFound() => $_clearField(4);

  /// No handler accepted this OS call — the child raises the call's own
  /// no-handler default (PermissionError naming the path for filesystem
  /// calls, RuntimeError for the rest). Only valid answering an `OsCall`
  /// suspension; the child computes it from its retained call payload.
  @$pb.TagNumber(5)
  Unit get notHandled => $_getN(4);
  @$pb.TagNumber(5)
  set notHandled(Unit value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasNotHandled() => $_has(4);
  @$pb.TagNumber(5)
  void clearNotHandled() => $_clearField(5);
  @$pb.TagNumber(5)
  Unit ensureNotHandled() => $_ensure(4);
}

class FutureResult extends $pb.GeneratedMessage {
  factory FutureResult({
    $core.int? callId,
    ExtFunctionResult? result,
  }) {
    final result$ = FutureResult._();
    if (callId != null) result$.callId = callId;
    if (result != null) result$.result = result;
    return result$;
  }

  FutureResult._();

  factory FutureResult.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FutureResult()..mergeFromBuffer(data, registry);
  factory FutureResult.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FutureResult()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FutureResult',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: FutureResult.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'callId', fieldType: $pb.PbFieldType.OU3)
    ..aOM<ExtFunctionResult>(2, _omitFieldNames ? '' : 'result',
        subBuilder: ExtFunctionResult.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FutureResult clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FutureResult copyWith(void Function(FutureResult) updates) =>
      super.copyWith((message) => updates(message as FutureResult))
          as FutureResult;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FutureResult() / FutureResult.new instead')
  static FutureResult create() => FutureResult._();
  static $pb.GeneratedMessage $_createMessage() => FutureResult._();
  @$core.override
  FutureResult createEmptyInstance() => FutureResult._();
  @$core.pragma('dart2js:noInline')
  static FutureResult getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FutureResult>(
          FutureResult.$_createMessage);
  static FutureResult? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get callId => $_getIZ(0);
  @$pb.TagNumber(1)
  set callId($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCallId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCallId() => $_clearField(1);

  @$pb.TagNumber(2)
  ExtFunctionResult get result => $_getN(1);
  @$pb.TagNumber(2)
  set result(ExtFunctionResult value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasResult() => $_has(1);
  @$pb.TagNumber(2)
  void clearResult() => $_clearField(2);
  @$pb.TagNumber(2)
  ExtFunctionResult ensureResult() => $_ensure(1);
}

/// A named input: `value` indexes the carrying message's `values` arena.
class NamedRef extends $pb.GeneratedMessage {
  factory NamedRef({
    $core.String? name,
    $core.int? value,
  }) {
    final result = NamedRef._();
    if (name != null) result.name = name;
    if (value != null) result.value = value;
    return result;
  }

  NamedRef._();

  factory NamedRef.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NamedRef()..mergeFromBuffer(data, registry);
  factory NamedRef.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NamedRef()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NamedRef',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: NamedRef.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aI(2, _omitFieldNames ? '' : 'value', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NamedRef clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NamedRef copyWith(void Function(NamedRef) updates) =>
      super.copyWith((message) => updates(message as NamedRef)) as NamedRef;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use NamedRef() / NamedRef.new instead')
  static NamedRef create() => NamedRef._();
  static $pb.GeneratedMessage $_createMessage() => NamedRef._();
  @$core.override
  NamedRef createEmptyInstance() => NamedRef._();
  @$core.pragma('dart2js:noInline')
  static NamedRef getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NamedRef>(NamedRef.$_createMessage);
  static NamedRef? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get value => $_getIZ(1);
  @$pb.TagNumber(2)
  set value($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);
}

enum ParentRequest_Kind {
  configure,
  installDependencies,
  feed,
  resumeCall,
  resumeNameLookup,
  resumeFutures,
  dump,
  load,
  reset,
  shutdown,
  abortFeed,
  notSet
}

/// Tags 1-19 are reserved for `kind` arms and the message-level fields start
/// at 20, mirroring `ChildEvent` — a oneof shares its field-number space with
/// the enclosing message, so a new arm never has to jump the numbering. The
/// same caveats apply: arms past 15 cost a two-byte key, and a forwarding
/// server mirrors this numbering to classify frames without decoding them, so
/// adding an arm degrades to "opaque" while renumbering one would misroute.
class ParentRequest extends $pb.GeneratedMessage {
  factory ParentRequest({
    Configure? configure,
    InstallDependencies? installDependencies,
    Feed? feed,
    ResumeCall? resumeCall,
    ResumeNameLookup? resumeNameLookup,
    ResumeFutures? resumeFutures,
    Dump? dump,
    Load? load,
    Reset? reset,
    Shutdown? shutdown,
    AbortFeed? abortFeed,
    $core.String? traceParent,
  }) {
    final result = ParentRequest._();
    if (configure != null) result.configure = configure;
    if (installDependencies != null)
      result.installDependencies = installDependencies;
    if (feed != null) result.feed = feed;
    if (resumeCall != null) result.resumeCall = resumeCall;
    if (resumeNameLookup != null) result.resumeNameLookup = resumeNameLookup;
    if (resumeFutures != null) result.resumeFutures = resumeFutures;
    if (dump != null) result.dump = dump;
    if (load != null) result.load = load;
    if (reset != null) result.reset = reset;
    if (shutdown != null) result.shutdown = shutdown;
    if (abortFeed != null) result.abortFeed = abortFeed;
    if (traceParent != null) result.traceParent = traceParent;
    return result;
  }

  ParentRequest._();

  factory ParentRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ParentRequest()..mergeFromBuffer(data, registry);
  factory ParentRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ParentRequest()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ParentRequest_Kind>
      _ParentRequest_KindByTag = {
    1: ParentRequest_Kind.configure,
    2: ParentRequest_Kind.installDependencies,
    3: ParentRequest_Kind.feed,
    4: ParentRequest_Kind.resumeCall,
    5: ParentRequest_Kind.resumeNameLookup,
    6: ParentRequest_Kind.resumeFutures,
    7: ParentRequest_Kind.dump,
    8: ParentRequest_Kind.load,
    9: ParentRequest_Kind.reset,
    10: ParentRequest_Kind.shutdown,
    11: ParentRequest_Kind.abortFeed,
    0: ParentRequest_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ParentRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ParentRequest.$_createMessage)
    ..oo(0, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    ..aOM<Configure>(1, _omitFieldNames ? '' : 'configure',
        subBuilder: Configure.$_createMessage)
    ..aOM<InstallDependencies>(2, _omitFieldNames ? '' : 'installDependencies',
        subBuilder: InstallDependencies.$_createMessage)
    ..aOM<Feed>(3, _omitFieldNames ? '' : 'feed',
        subBuilder: Feed.$_createMessage)
    ..aOM<ResumeCall>(4, _omitFieldNames ? '' : 'resumeCall',
        subBuilder: ResumeCall.$_createMessage)
    ..aOM<ResumeNameLookup>(5, _omitFieldNames ? '' : 'resumeNameLookup',
        subBuilder: ResumeNameLookup.$_createMessage)
    ..aOM<ResumeFutures>(6, _omitFieldNames ? '' : 'resumeFutures',
        subBuilder: ResumeFutures.$_createMessage)
    ..aOM<Dump>(7, _omitFieldNames ? '' : 'dump',
        subBuilder: Dump.$_createMessage)
    ..aOM<Load>(8, _omitFieldNames ? '' : 'load',
        subBuilder: Load.$_createMessage)
    ..aOM<Reset>(9, _omitFieldNames ? '' : 'reset',
        subBuilder: Reset.$_createMessage)
    ..aOM<Shutdown>(10, _omitFieldNames ? '' : 'shutdown',
        subBuilder: Shutdown.$_createMessage)
    ..aOM<AbortFeed>(11, _omitFieldNames ? '' : 'abortFeed',
        subBuilder: AbortFeed.$_createMessage)
    ..aOS(20, _omitFieldNames ? '' : 'traceParent')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ParentRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ParentRequest copyWith(void Function(ParentRequest) updates) =>
      super.copyWith((message) => updates(message as ParentRequest))
          as ParentRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ParentRequest() / ParentRequest.new instead')
  static ParentRequest create() => ParentRequest._();
  static $pb.GeneratedMessage $_createMessage() => ParentRequest._();
  @$core.override
  ParentRequest createEmptyInstance() => ParentRequest._();
  @$core.pragma('dart2js:noInline')
  static ParentRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ParentRequest>(
          ParentRequest.$_createMessage);
  static ParentRequest? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  ParentRequest_Kind whichKind() => _ParentRequest_KindByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  void clearKind() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  Configure get configure => $_getN(0);
  @$pb.TagNumber(1)
  set configure(Configure value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasConfigure() => $_has(0);
  @$pb.TagNumber(1)
  void clearConfigure() => $_clearField(1);
  @$pb.TagNumber(1)
  Configure ensureConfigure() => $_ensure(0);

  @$pb.TagNumber(2)
  InstallDependencies get installDependencies => $_getN(1);
  @$pb.TagNumber(2)
  set installDependencies(InstallDependencies value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasInstallDependencies() => $_has(1);
  @$pb.TagNumber(2)
  void clearInstallDependencies() => $_clearField(2);
  @$pb.TagNumber(2)
  InstallDependencies ensureInstallDependencies() => $_ensure(1);

  @$pb.TagNumber(3)
  Feed get feed => $_getN(2);
  @$pb.TagNumber(3)
  set feed(Feed value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasFeed() => $_has(2);
  @$pb.TagNumber(3)
  void clearFeed() => $_clearField(3);
  @$pb.TagNumber(3)
  Feed ensureFeed() => $_ensure(2);

  @$pb.TagNumber(4)
  ResumeCall get resumeCall => $_getN(3);
  @$pb.TagNumber(4)
  set resumeCall(ResumeCall value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasResumeCall() => $_has(3);
  @$pb.TagNumber(4)
  void clearResumeCall() => $_clearField(4);
  @$pb.TagNumber(4)
  ResumeCall ensureResumeCall() => $_ensure(3);

  @$pb.TagNumber(5)
  ResumeNameLookup get resumeNameLookup => $_getN(4);
  @$pb.TagNumber(5)
  set resumeNameLookup(ResumeNameLookup value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasResumeNameLookup() => $_has(4);
  @$pb.TagNumber(5)
  void clearResumeNameLookup() => $_clearField(5);
  @$pb.TagNumber(5)
  ResumeNameLookup ensureResumeNameLookup() => $_ensure(4);

  @$pb.TagNumber(6)
  ResumeFutures get resumeFutures => $_getN(5);
  @$pb.TagNumber(6)
  set resumeFutures(ResumeFutures value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasResumeFutures() => $_has(5);
  @$pb.TagNumber(6)
  void clearResumeFutures() => $_clearField(6);
  @$pb.TagNumber(6)
  ResumeFutures ensureResumeFutures() => $_ensure(5);

  @$pb.TagNumber(7)
  Dump get dump => $_getN(6);
  @$pb.TagNumber(7)
  set dump(Dump value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasDump() => $_has(6);
  @$pb.TagNumber(7)
  void clearDump() => $_clearField(7);
  @$pb.TagNumber(7)
  Dump ensureDump() => $_ensure(6);

  @$pb.TagNumber(8)
  Load get load => $_getN(7);
  @$pb.TagNumber(8)
  set load(Load value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasLoad() => $_has(7);
  @$pb.TagNumber(8)
  void clearLoad() => $_clearField(8);
  @$pb.TagNumber(8)
  Load ensureLoad() => $_ensure(7);

  @$pb.TagNumber(9)
  Reset get reset => $_getN(8);
  @$pb.TagNumber(9)
  set reset(Reset value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasReset() => $_has(8);
  @$pb.TagNumber(9)
  void clearReset() => $_clearField(9);
  @$pb.TagNumber(9)
  Reset ensureReset() => $_ensure(8);

  @$pb.TagNumber(10)
  Shutdown get shutdown => $_getN(9);
  @$pb.TagNumber(10)
  set shutdown(Shutdown value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasShutdown() => $_has(9);
  @$pb.TagNumber(10)
  void clearShutdown() => $_clearField(10);
  @$pb.TagNumber(10)
  Shutdown ensureShutdown() => $_ensure(9);

  @$pb.TagNumber(11)
  AbortFeed get abortFeed => $_getN(10);
  @$pb.TagNumber(11)
  set abortFeed(AbortFeed value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasAbortFeed() => $_has(10);
  @$pb.TagNumber(11)
  void clearAbortFeed() => $_clearField(11);
  @$pb.TagNumber(11)
  AbortFeed ensureAbortFeed() => $_ensure(10);

  /// W3C `traceparent` identifying the caller's span, so a child that exports
  /// its own telemetry can attach its spans to the trace the request came
  /// from. Purely additive context: the child's execution of the request must
  /// not depend on it, and it is absent whenever the parent is not tracing.
  @$pb.TagNumber(20)
  $core.String get traceParent => $_getSZ(11);
  @$pb.TagNumber(20)
  set traceParent($core.String value) => $_setString(11, value);
  @$pb.TagNumber(20)
  $core.bool hasTraceParent() => $_has(11);
  @$pb.TagNumber(20)
  void clearTraceParent() => $_clearField(20);
}

/// Configures the REPL session this child will serve until `Reset`, sent once
/// when the worker is checked out. The session's repl is materialized lazily on
/// the first `Feed` (or restored by `Load`), so a checked-out-but-unfed
/// worker can still be initialized by `Load` instead. Valid only when the
/// worker has no session yet.
class Configure extends $pb.GeneratedMessage {
  factory Configure({
    $core.String? scriptName,
    ResourceLimits? limits,
    $core.bool? typeCheck,
    $core.String? typeCheckStubs,
    $core.String? montyVersion,
    $core.int? assertMessageAnnotations,
    TypeCheckFormat? typeCheckFormat,
    $core.bool? typeCheckColor,
    $core.int? protocolVersion,
    $core.int? printFlushIntervalMs,
    OsPolicy? osPolicy,
    Persistence? persistence,
    $core.String? profile,
  }) {
    final result = Configure._();
    if (scriptName != null) result.scriptName = scriptName;
    if (limits != null) result.limits = limits;
    if (typeCheck != null) result.typeCheck = typeCheck;
    if (typeCheckStubs != null) result.typeCheckStubs = typeCheckStubs;
    if (montyVersion != null) result.montyVersion = montyVersion;
    if (assertMessageAnnotations != null)
      result.assertMessageAnnotations = assertMessageAnnotations;
    if (typeCheckFormat != null) result.typeCheckFormat = typeCheckFormat;
    if (typeCheckColor != null) result.typeCheckColor = typeCheckColor;
    if (protocolVersion != null) result.protocolVersion = protocolVersion;
    if (printFlushIntervalMs != null)
      result.printFlushIntervalMs = printFlushIntervalMs;
    if (osPolicy != null) result.osPolicy = osPolicy;
    if (persistence != null) result.persistence = persistence;
    if (profile != null) result.profile = profile;
    return result;
  }

  Configure._();

  factory Configure.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Configure()..mergeFromBuffer(data, registry);
  factory Configure.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Configure()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Configure',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Configure.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'scriptName')
    ..aOM<ResourceLimits>(2, _omitFieldNames ? '' : 'limits',
        subBuilder: ResourceLimits.$_createMessage)
    ..aOB(3, _omitFieldNames ? '' : 'typeCheck')
    ..aOS(4, _omitFieldNames ? '' : 'typeCheckStubs')
    ..aOS(5, _omitFieldNames ? '' : 'montyVersion')
    ..aI(6, _omitFieldNames ? '' : 'assertMessageAnnotations',
        fieldType: $pb.PbFieldType.OU3)
    ..aE<TypeCheckFormat>(7, _omitFieldNames ? '' : 'typeCheckFormat',
        enumValues: TypeCheckFormat.values)
    ..aOB(8, _omitFieldNames ? '' : 'typeCheckColor')
    ..aI(9, _omitFieldNames ? '' : 'protocolVersion',
        fieldType: $pb.PbFieldType.OU3)
    ..aI(10, _omitFieldNames ? '' : 'printFlushIntervalMs',
        fieldType: $pb.PbFieldType.OU3)
    ..aOM<OsPolicy>(11, _omitFieldNames ? '' : 'osPolicy',
        subBuilder: OsPolicy.$_createMessage)
    ..aE<Persistence>(12, _omitFieldNames ? '' : 'persistence',
        enumValues: Persistence.values)
    ..aOS(13, _omitFieldNames ? '' : 'profile')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Configure clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Configure copyWith(void Function(Configure) updates) =>
      super.copyWith((message) => updates(message as Configure)) as Configure;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Configure() / Configure.new instead')
  static Configure create() => Configure._();
  static $pb.GeneratedMessage $_createMessage() => Configure._();
  @$core.override
  Configure createEmptyInstance() => Configure._();
  @$core.pragma('dart2js:noInline')
  static Configure getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Configure>(Configure.$_createMessage);
  static Configure? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get scriptName => $_getSZ(0);
  @$pb.TagNumber(1)
  set scriptName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasScriptName() => $_has(0);
  @$pb.TagNumber(1)
  void clearScriptName() => $_clearField(1);

  @$pb.TagNumber(2)
  ResourceLimits get limits => $_getN(1);
  @$pb.TagNumber(2)
  set limits(ResourceLimits value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasLimits() => $_has(1);
  @$pb.TagNumber(2)
  void clearLimits() => $_clearField(2);
  @$pb.TagNumber(2)
  ResourceLimits ensureLimits() => $_ensure(1);

  /// Type-check each fed snippet before executing it.
  @$pb.TagNumber(3)
  $core.bool get typeCheck => $_getBF(2);
  @$pb.TagNumber(3)
  set typeCheck($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasTypeCheck() => $_has(2);
  @$pb.TagNumber(3)
  void clearTypeCheck() => $_clearField(3);

  /// Optional stub file contents used by type checking.
  @$pb.TagNumber(4)
  $core.String get typeCheckStubs => $_getSZ(3);
  @$pb.TagNumber(4)
  set typeCheckStubs($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasTypeCheckStubs() => $_has(3);
  @$pb.TagNumber(4)
  void clearTypeCheckStubs() => $_clearField(4);

  /// The parent's monty package version (e.g. "0.0.18"). INFORMATIONAL ONLY —
  /// it is never checked, only reported (in telemetry, and when diagnosing a
  /// rejected `protocol_version`). Parent and child may run different package
  /// versions as long as their protocol versions are compatible.
  @$pb.TagNumber(5)
  $core.String get montyVersion => $_getSZ(4);
  @$pb.TagNumber(5)
  set montyVersion($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasMontyVersion() => $_has(4);
  @$pb.TagNumber(5)
  void clearMontyVersion() => $_clearField(5);

  /// Introspected `assert` failure messages (see limitations/assert.md).
  /// Absent = on with the default 120-byte operand-repr truncation; 0 disables
  /// annotations; any other value retains that many bytes per operand before
  /// any ellipsis, cutting on a character boundary.
  @$pb.TagNumber(6)
  $core.int get assertMessageAnnotations => $_getIZ(5);
  @$pb.TagNumber(6)
  set assertMessageAnnotations($core.int value) => $_setUnsignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasAssertMessageAnnotations() => $_has(5);
  @$pb.TagNumber(6)
  void clearAssertMessageAnnotations() => $_clearField(6);

  /// How the child renders the diagnostics carried by `TypingError`. The
  /// structured diagnostics borrow the type checker's database and so cannot
  /// cross the wire — the parent picks the format up front and the child
  /// renders it. Ignored when `type_check` is false.
  @$pb.TagNumber(7)
  TypeCheckFormat get typeCheckFormat => $_getN(6);
  @$pb.TagNumber(7)
  set typeCheckFormat(TypeCheckFormat value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasTypeCheckFormat() => $_has(6);
  @$pb.TagNumber(7)
  void clearTypeCheckFormat() => $_clearField(7);

  /// Render typing diagnostics with ANSI colour escapes. Only `FULL` and
  /// `CONCISE` carry colour; the machine-readable formats ignore it.
  @$pb.TagNumber(8)
  $core.bool get typeCheckColor => $_getBF(7);
  @$pb.TagNumber(8)
  set typeCheckColor($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasTypeCheckColor() => $_has(7);
  @$pb.TagNumber(8)
  void clearTypeCheckColor() => $_clearField(8);

  /// Version of the wire schema the parent speaks. The child rejects the
  /// session with a `FatalError` naming its own supported range when this
  /// falls outside it, so a parent deployed separately from its worker (over
  /// a websocket, say) learns what to downgrade to without a handshake.
  ///
  /// 0 means the parent declared nothing — either it predates this field or it
  /// is not a monty parent — and is always rejected. The protocol has no
  /// in-band negotiation, so an undeclared peer cannot be assumed compatible.
  @$pb.TagNumber(9)
  $core.int get protocolVersion => $_getIZ(8);
  @$pb.TagNumber(9)
  set protocolVersion($core.int value) => $_setUnsignedInt32(8, value);
  @$pb.TagNumber(9)
  $core.bool hasProtocolVersion() => $_has(8);
  @$pb.TagNumber(9)
  void clearProtocolVersion() => $_clearField(9);

  /// How long the child may hold buffered `print()` output before emitting it
  /// as a `Print` event, in milliseconds. Absent means the child's default
  /// (`DEFAULT_PRINT_FLUSH_INTERVAL`). 0 disables the timer and restores line
  /// buffering — one event per completed line, as before this field existed —
  /// for a host that wants each `print()` delivered on its own.
  ///
  /// Output is always flushed before a turn-ending event whatever this says, so
  /// the field trades streaming latency for event volume and nothing else.
  @$pb.TagNumber(10)
  $core.int get printFlushIntervalMs => $_getIZ(9);
  @$pb.TagNumber(10)
  set printFlushIntervalMs($core.int value) => $_setUnsignedInt32(9, value);
  @$pb.TagNumber(10)
  $core.bool hasPrintFlushIntervalMs() => $_has(9);
  @$pb.TagNumber(10)
  void clearPrintFlushIntervalMs() => $_clearField(10);

  /// Absent = `OsPolicy::default()`: the child's clock in UTC and its entropy,
  /// with parent-serviced sleeps capped at 10s. `Load` restores the dump's settings.
  @$pb.TagNumber(11)
  OsPolicy get osPolicy => $_getN(10);
  @$pb.TagNumber(11)
  set osPolicy(OsPolicy value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasOsPolicy() => $_has(10);
  @$pb.TagNumber(11)
  void clearOsPolicy() => $_clearField(11);
  @$pb.TagNumber(11)
  OsPolicy ensureOsPolicy() => $_ensure(10);

  /// Relay-only: whether a serving relay may store the session. Children ignore
  /// it.
  @$pb.TagNumber(12)
  Persistence get persistence => $_getN(11);
  @$pb.TagNumber(12)
  set persistence(Persistence value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasPersistence() => $_has(11);
  @$pb.TagNumber(12)
  void clearPersistence() => $_clearField(12);

  /// Relay-only: names the server-side profile to run the session under.
  /// Absent = the relay's default. Children ignore it.
  @$pb.TagNumber(13)
  $core.String get profile => $_getSZ(12);
  @$pb.TagNumber(13)
  set profile($core.String value) => $_setString(12, value);
  @$pb.TagNumber(13)
  $core.bool hasProfile() => $_has(12);
  @$pb.TagNumber(13)
  void clearProfile() => $_clearField(13);
}

/// Executes one snippet against the session. Turn ends with `Complete`,
/// `Error`, `TypingError`, or a suspension event.
class Feed extends $pb.GeneratedMessage {
  factory Feed({
    $core.String? code,
    $core.Iterable<NamedRef>? inputs,
    Arena? values,
    $core.bool? skipTypeCheck,
    $core.String? cwd,
  }) {
    final result = Feed._();
    if (code != null) result.code = code;
    if (inputs != null) result.inputs.addAll(inputs);
    if (values != null) result.values = values;
    if (skipTypeCheck != null) result.skipTypeCheck = skipTypeCheck;
    if (cwd != null) result.cwd = cwd;
    return result;
  }

  Feed._();

  factory Feed.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Feed()..mergeFromBuffer(data, registry);
  factory Feed.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Feed()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Feed',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Feed.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'code')
    ..pPM<NamedRef>(2, _omitFieldNames ? '' : 'inputs',
        subBuilder: NamedRef.$_createMessage)
    ..aOM<Arena>(3, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..aOB(4, _omitFieldNames ? '' : 'skipTypeCheck')
    ..aOS(5, _omitFieldNames ? '' : 'cwd')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Feed clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Feed copyWith(void Function(Feed) updates) =>
      super.copyWith((message) => updates(message as Feed)) as Feed;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Feed() / Feed.new instead')
  static Feed create() => Feed._();
  static $pb.GeneratedMessage $_createMessage() => Feed._();
  @$core.override
  Feed createEmptyInstance() => Feed._();
  @$core.pragma('dart2js:noInline')
  static Feed getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Feed>(Feed.$_createMessage);
  static Feed? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get code => $_getSZ(0);
  @$pb.TagNumber(1)
  set code($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCode() => $_has(0);
  @$pb.TagNumber(1)
  void clearCode() => $_clearField(1);

  /// Inputs, each an index into `values`; one arena, so an object passed
  /// under two names is one sandbox object.
  @$pb.TagNumber(2)
  $pb.PbList<NamedRef> get inputs => $_getList(1);

  @$pb.TagNumber(3)
  Arena get values => $_getN(2);
  @$pb.TagNumber(3)
  set values(Arena value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasValues() => $_has(2);
  @$pb.TagNumber(3)
  void clearValues() => $_clearField(3);
  @$pb.TagNumber(3)
  Arena ensureValues() => $_ensure(2);

  /// Skip type checking for this feed even when the session enables it.
  @$pb.TagNumber(4)
  $core.bool get skipTypeCheck => $_getBF(3);
  @$pb.TagNumber(4)
  set skipTypeCheck($core.bool value) => $_setBool(3, value);
  @$pb.TagNumber(4)
  $core.bool hasSkipTypeCheck() => $_has(3);
  @$pb.TagNumber(4)
  void clearSkipTypeCheck() => $_clearField(4);

  /// Absolute virtual working directory to switch the session to before the
  /// feed, resolved by the parent (an explicit choice, or the first mount on
  /// the session's first feed). Empty keeps the session's current directory.
  @$pb.TagNumber(5)
  $core.String get cwd => $_getSZ(4);
  @$pb.TagNumber(5)
  set cwd($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasCwd() => $_has(4);
  @$pb.TagNumber(5)
  void clearCwd() => $_clearField(5);
}

/// Ends a pending suspension by raising `exception` uncatchably at its site.
/// The session returns ready in an `Error` event. Hosts use this to stop a feed,
/// including when `max_suspensions` is exceeded.
class AbortFeed extends $pb.GeneratedMessage {
  factory AbortFeed({
    RaisedException? exception,
  }) {
    final result = AbortFeed._();
    if (exception != null) result.exception = exception;
    return result;
  }

  AbortFeed._();

  factory AbortFeed.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AbortFeed()..mergeFromBuffer(data, registry);
  factory AbortFeed.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AbortFeed()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AbortFeed',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: AbortFeed.$_createMessage)
    ..aOM<RaisedException>(1, _omitFieldNames ? '' : 'exception',
        subBuilder: RaisedException.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AbortFeed clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AbortFeed copyWith(void Function(AbortFeed) updates) =>
      super.copyWith((message) => updates(message as AbortFeed)) as AbortFeed;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use AbortFeed() / AbortFeed.new instead')
  static AbortFeed create() => AbortFeed._();
  static $pb.GeneratedMessage $_createMessage() => AbortFeed._();
  @$core.override
  AbortFeed createEmptyInstance() => AbortFeed._();
  @$core.pragma('dart2js:noInline')
  static AbortFeed getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<AbortFeed>(AbortFeed.$_createMessage);
  static AbortFeed? _defaultInstance;

  @$pb.TagNumber(1)
  RaisedException get exception => $_getN(0);
  @$pb.TagNumber(1)
  set exception(RaisedException value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasException() => $_has(0);
  @$pb.TagNumber(1)
  void clearException() => $_clearField(1);
  @$pb.TagNumber(1)
  RaisedException ensureException() => $_ensure(0);
}

/// Answers a `FunctionCall` or `OsCall` suspension. `call_id` must match the
/// suspension event.
class ResumeCall extends $pb.GeneratedMessage {
  factory ResumeCall({
    $core.int? callId,
    ExtFunctionResult? result,
    Arena? values,
  }) {
    final result$ = ResumeCall._();
    if (callId != null) result$.callId = callId;
    if (result != null) result$.result = result;
    if (values != null) result$.values = values;
    return result$;
  }

  ResumeCall._();

  factory ResumeCall.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResumeCall()..mergeFromBuffer(data, registry);
  factory ResumeCall.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResumeCall()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ResumeCall',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ResumeCall.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'callId', fieldType: $pb.PbFieldType.OU3)
    ..aOM<ExtFunctionResult>(2, _omitFieldNames ? '' : 'result',
        subBuilder: ExtFunctionResult.$_createMessage)
    ..aOM<Arena>(3, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResumeCall clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResumeCall copyWith(void Function(ResumeCall) updates) =>
      super.copyWith((message) => updates(message as ResumeCall)) as ResumeCall;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ResumeCall() / ResumeCall.new instead')
  static ResumeCall create() => ResumeCall._();
  static $pb.GeneratedMessage $_createMessage() => ResumeCall._();
  @$core.override
  ResumeCall createEmptyInstance() => ResumeCall._();
  @$core.pragma('dart2js:noInline')
  static ResumeCall getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ResumeCall>(ResumeCall.$_createMessage);
  static ResumeCall? _defaultInstance;

  @$pb.TagNumber(1)
  $core.int get callId => $_getIZ(0);
  @$pb.TagNumber(1)
  set callId($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCallId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCallId() => $_clearField(1);

  @$pb.TagNumber(2)
  ExtFunctionResult get result => $_getN(1);
  @$pb.TagNumber(2)
  set result(ExtFunctionResult value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasResult() => $_has(1);
  @$pb.TagNumber(2)
  void clearResult() => $_clearField(2);
  @$pb.TagNumber(2)
  ExtFunctionResult ensureResult() => $_ensure(1);

  /// The arena `result.return_value` indexes.
  @$pb.TagNumber(3)
  Arena get values => $_getN(2);
  @$pb.TagNumber(3)
  set values(Arena value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasValues() => $_has(2);
  @$pb.TagNumber(3)
  void clearValues() => $_clearField(3);
  @$pb.TagNumber(3)
  Arena ensureValues() => $_ensure(2);
}

enum ResumeNameLookup_Kind { value, undefined, error, notSet }

/// Answers a `NameLookup` suspension.
class ResumeNameLookup extends $pb.GeneratedMessage {
  factory ResumeNameLookup({
    Arena? values,
    $core.int? value,
    Unit? undefined,
    RaisedException? error,
  }) {
    final result = ResumeNameLookup._();
    if (values != null) result.values = values;
    if (value != null) result.value = value;
    if (undefined != null) result.undefined = undefined;
    if (error != null) result.error = error;
    return result;
  }

  ResumeNameLookup._();

  factory ResumeNameLookup.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResumeNameLookup()..mergeFromBuffer(data, registry);
  factory ResumeNameLookup.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResumeNameLookup()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ResumeNameLookup_Kind>
      _ResumeNameLookup_KindByTag = {
    2: ResumeNameLookup_Kind.value,
    3: ResumeNameLookup_Kind.undefined,
    4: ResumeNameLookup_Kind.error,
    0: ResumeNameLookup_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ResumeNameLookup',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ResumeNameLookup.$_createMessage)
    ..oo(0, [2, 3, 4])
    ..aOM<Arena>(1, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..aI(2, _omitFieldNames ? '' : 'value', fieldType: $pb.PbFieldType.OU3)
    ..aOM<Unit>(3, _omitFieldNames ? '' : 'undefined',
        subBuilder: Unit.$_createMessage)
    ..aOM<RaisedException>(4, _omitFieldNames ? '' : 'error',
        subBuilder: RaisedException.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResumeNameLookup clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResumeNameLookup copyWith(void Function(ResumeNameLookup) updates) =>
      super.copyWith((message) => updates(message as ResumeNameLookup))
          as ResumeNameLookup;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ResumeNameLookup() / ResumeNameLookup.new instead')
  static ResumeNameLookup create() => ResumeNameLookup._();
  static $pb.GeneratedMessage $_createMessage() => ResumeNameLookup._();
  @$core.override
  ResumeNameLookup createEmptyInstance() => ResumeNameLookup._();
  @$core.pragma('dart2js:noInline')
  static ResumeNameLookup getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ResumeNameLookup>(
          ResumeNameLookup.$_createMessage);
  static ResumeNameLookup? _defaultInstance;

  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  ResumeNameLookup_Kind whichKind() =>
      _ResumeNameLookup_KindByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  void clearKind() => $_clearField($_whichOneof(0));

  /// The arena `value` indexes.
  @$pb.TagNumber(1)
  Arena get values => $_getN(0);
  @$pb.TagNumber(1)
  set values(Arena value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasValues() => $_has(0);
  @$pb.TagNumber(1)
  void clearValues() => $_clearField(1);
  @$pb.TagNumber(1)
  Arena ensureValues() => $_ensure(0);

  /// The name resolves to this value: an index into `values`.
  @$pb.TagNumber(2)
  $core.int get value => $_getIZ(1);
  @$pb.TagNumber(2)
  set value($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasValue() => $_has(1);
  @$pb.TagNumber(2)
  void clearValue() => $_clearField(2);

  /// The name is undefined — the child raises NameError (AttributeError for
  /// a lazy attribute lookup).
  @$pb.TagNumber(3)
  Unit get undefined => $_getN(2);
  @$pb.TagNumber(3)
  set undefined(Unit value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasUndefined() => $_has(2);
  @$pb.TagNumber(3)
  void clearUndefined() => $_clearField(3);
  @$pb.TagNumber(3)
  Unit ensureUndefined() => $_ensure(2);

  /// Resolving the name raised on the parent — the child raises this
  /// exception where the lookup suspended, bypassing hasattr()/getattr()
  /// defaults.
  @$pb.TagNumber(4)
  RaisedException get error => $_getN(3);
  @$pb.TagNumber(4)
  set error(RaisedException value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasError() => $_has(3);
  @$pb.TagNumber(4)
  void clearError() => $_clearField(4);
  @$pb.TagNumber(4)
  RaisedException ensureError() => $_ensure(3);
}

/// Answers a `ResolveFutures` suspension with results for some or all pending
/// call ids.
class ResumeFutures extends $pb.GeneratedMessage {
  factory ResumeFutures({
    $core.Iterable<FutureResult>? results,
    Arena? values,
  }) {
    final result = ResumeFutures._();
    if (results != null) result.results.addAll(results);
    if (values != null) result.values = values;
    return result;
  }

  ResumeFutures._();

  factory ResumeFutures.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResumeFutures()..mergeFromBuffer(data, registry);
  factory ResumeFutures.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResumeFutures()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ResumeFutures',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ResumeFutures.$_createMessage)
    ..pPM<FutureResult>(1, _omitFieldNames ? '' : 'results',
        subBuilder: FutureResult.$_createMessage)
    ..aOM<Arena>(2, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResumeFutures clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResumeFutures copyWith(void Function(ResumeFutures) updates) =>
      super.copyWith((message) => updates(message as ResumeFutures))
          as ResumeFutures;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ResumeFutures() / ResumeFutures.new instead')
  static ResumeFutures create() => ResumeFutures._();
  static $pb.GeneratedMessage $_createMessage() => ResumeFutures._();
  @$core.override
  ResumeFutures createEmptyInstance() => ResumeFutures._();
  @$core.pragma('dart2js:noInline')
  static ResumeFutures getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ResumeFutures>(
          ResumeFutures.$_createMessage);
  static ResumeFutures? _defaultInstance;

  /// Also answers an eager FunctionCall with exactly one result matching its
  /// call_id. The worker creates a settled awaitable before continuing.
  @$pb.TagNumber(1)
  $pb.PbList<FutureResult> get results => $_getList(0);

  /// The arena every `return_value` indexes.
  @$pb.TagNumber(2)
  Arena get values => $_getN(1);
  @$pb.TagNumber(2)
  set values(Arena value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasValues() => $_has(1);
  @$pb.TagNumber(2)
  void clearValues() => $_clearField(2);
  @$pb.TagNumber(2)
  Arena ensureValues() => $_ensure(1);
}

/// Requests an opaque serialized snapshot of the current session state
/// (idle or suspended). The session stays usable afterwards. The byte payload
/// format is at the discretion of the remote (e.g. it may be an ID or a full dump
/// of state). A relay without session storage answers `Error` and the session
/// carries on.
class Dump extends $pb.GeneratedMessage {
  factory Dump() => Dump._();

  Dump._();

  factory Dump.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Dump()..mergeFromBuffer(data, registry);
  factory Dump.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Dump()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Dump',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Dump.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Dump clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Dump copyWith(void Function(Dump) updates) =>
      super.copyWith((message) => updates(message as Dump)) as Dump;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Dump() / Dump.new instead')
  static Dump create() => Dump._();
  static $pb.GeneratedMessage $_createMessage() => Dump._();
  @$core.override
  Dump createEmptyInstance() => Dump._();
  @$core.pragma('dart2js:noInline')
  static Dump getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Dump>(Dump.$_createMessage);
  static Dump? _defaultInstance;
}

/// Restores state produced by `Dump`. Valid only from no session. If
/// the restored state was suspended, the child re-emits the suspension event so
/// the parent learns the resume point; otherwise it replies `Ok`. A relay
/// without session storage answers `Error` and the session carries on.
class Load extends $pb.GeneratedMessage {
  factory Load({
    $core.List<$core.int>? state,
  }) {
    final result = Load._();
    if (state != null) result.state = state;
    return result;
  }

  Load._();

  factory Load.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Load()..mergeFromBuffer(data, registry);
  factory Load.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Load()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Load',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Load.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'state', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Load clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Load copyWith(void Function(Load) updates) =>
      super.copyWith((message) => updates(message as Load)) as Load;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Load() / Load.new instead')
  static Load create() => Load._();
  static $pb.GeneratedMessage $_createMessage() => Load._();
  @$core.override
  Load createEmptyInstance() => Load._();
  @$core.pragma('dart2js:noInline')
  static Load getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Load>(Load.$_createMessage);
  static Load? _defaultInstance;

  /// Either:
  /// - Dump bytes, or
  /// - A previously named session ID from `ChildEvent::session_id`
  @$pb.TagNumber(1)
  $core.List<$core.int> get state => $_getN(0);
  @$pb.TagNumber(1)
  set state($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasState() => $_has(0);
  @$pb.TagNumber(1)
  void clearState() => $_clearField(1);
}

/// Ends the checkout: the child drops all session state and returns to the
/// no-session state, ready for the next `Configure` or `Load`.
class Reset extends $pb.GeneratedMessage {
  factory Reset() => Reset._();

  Reset._();

  factory Reset.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Reset()..mergeFromBuffer(data, registry);
  factory Reset.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Reset()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Reset',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Reset.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Reset clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Reset copyWith(void Function(Reset) updates) =>
      super.copyWith((message) => updates(message as Reset)) as Reset;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Reset() / Reset.new instead')
  static Reset create() => Reset._();
  static $pb.GeneratedMessage $_createMessage() => Reset._();
  @$core.override
  Reset createEmptyInstance() => Reset._();
  @$core.pragma('dart2js:noInline')
  static Reset getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Reset>(Reset.$_createMessage);
  static Reset? _defaultInstance;
}

/// The child replies `Ok` and exits cleanly.
class Shutdown extends $pb.GeneratedMessage {
  factory Shutdown() => Shutdown._();

  Shutdown._();

  factory Shutdown.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Shutdown()..mergeFromBuffer(data, registry);
  factory Shutdown.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Shutdown()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Shutdown',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Shutdown.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Shutdown clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Shutdown copyWith(void Function(Shutdown) updates) =>
      super.copyWith((message) => updates(message as Shutdown)) as Shutdown;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Shutdown() / Shutdown.new instead')
  static Shutdown create() => Shutdown._();
  static $pb.GeneratedMessage $_createMessage() => Shutdown._();
  @$core.override
  Shutdown createEmptyInstance() => Shutdown._();
  @$core.pragma('dart2js:noInline')
  static Shutdown getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Shutdown>(Shutdown.$_createMessage);
  static Shutdown? _defaultInstance;
}

/// Installs third-party Python packages into the session before further feeds,
/// using `uv pip install --python <venv-python>` against the worker's session
/// virtualenv. Only the
/// embedded-CPython worker honors this; the Monty sandbox child rejects it with
/// an `Error` (it has no host interpreter to install for). Repeatable between
/// feeds. Turn ends with `Ok` on success or `Error` (carrying uv's stderr) on
/// failure. Valid only once a session exists (after `Configure`).
class InstallDependencies extends $pb.GeneratedMessage {
  factory InstallDependencies({
    $core.Iterable<$core.String>? requirements,
  }) {
    final result = InstallDependencies._();
    if (requirements != null) result.requirements.addAll(requirements);
    return result;
  }

  InstallDependencies._();

  factory InstallDependencies.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      InstallDependencies()..mergeFromBuffer(data, registry);
  factory InstallDependencies.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      InstallDependencies()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'InstallDependencies',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: InstallDependencies.$_createMessage)
    ..pPS(1, _omitFieldNames ? '' : 'requirements')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallDependencies clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  InstallDependencies copyWith(void Function(InstallDependencies) updates) =>
      super.copyWith((message) => updates(message as InstallDependencies))
          as InstallDependencies;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core
      .Deprecated('Use InstallDependencies() / InstallDependencies.new instead')
  static InstallDependencies create() => InstallDependencies._();
  static $pb.GeneratedMessage $_createMessage() => InstallDependencies._();
  @$core.override
  InstallDependencies createEmptyInstance() => InstallDependencies._();
  @$core.pragma('dart2js:noInline')
  static InstallDependencies getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<InstallDependencies>(
          InstallDependencies.$_createMessage);
  static InstallDependencies? _defaultInstance;

  /// PEP 508 requirement strings, e.g. "httpx>=0.27", "numpy". An empty list is
  /// a no-op that replies `Ok`.
  @$pb.TagNumber(1)
  $pb.PbList<$core.String> get requirements => $_getList(0);
}

enum ChildEvent_Kind {
  print,
  functionCall,
  osCall,
  nameLookup,
  resolveFutures,
  complete,
  error,
  typingError,
  dumpResult,
  ok,
  fatalError,
  shutdown,
  notSet
}

/// A oneof shares its field-number space with the enclosing message, so tags
/// 1-19 are reserved by convention for `kind` arms and the message-level
/// fields start at 20 — a new arm then never has to jump the numbering. Note
/// arms past 15 cost a two-byte key instead of one, which forwarding servers
/// (which walk only field keys, on every frame) pay per event. Such a server
/// mirrors this numbering to classify frames without decoding them; it treats
/// a tag it does not know as opaque, so adding an arm degrades rather than
/// misroutes, but renumbering an existing one would break it.
class ChildEvent extends $pb.GeneratedMessage {
  factory ChildEvent({
    Print? print,
    FunctionCall? functionCall,
    OsCall? osCall,
    NameLookup? nameLookup,
    ResolveFutures? resolveFutures,
    Complete? complete,
    Error? error,
    TypingError? typingError,
    DumpResult? dumpResult,
    Ok? ok,
    FatalError? fatalError,
    ShutdownDump? shutdown,
    $fixnum.Int64? totalExecutionMicros,
    $fixnum.Int64? maxSuspensions,
    $core.String? restoredScriptName,
    $fixnum.Int64? feedExecutionMicros,
    $fixnum.Int64? maxFeedDurationMicros,
    $fixnum.Int64? maxTurnDurationMicros,
    $fixnum.Int64? maxTotalSleepMicros,
    $core.List<$core.int>? sessionId,
  }) {
    final result = ChildEvent._();
    if (print != null) result.print = print;
    if (functionCall != null) result.functionCall = functionCall;
    if (osCall != null) result.osCall = osCall;
    if (nameLookup != null) result.nameLookup = nameLookup;
    if (resolveFutures != null) result.resolveFutures = resolveFutures;
    if (complete != null) result.complete = complete;
    if (error != null) result.error = error;
    if (typingError != null) result.typingError = typingError;
    if (dumpResult != null) result.dumpResult = dumpResult;
    if (ok != null) result.ok = ok;
    if (fatalError != null) result.fatalError = fatalError;
    if (shutdown != null) result.shutdown = shutdown;
    if (totalExecutionMicros != null)
      result.totalExecutionMicros = totalExecutionMicros;
    if (maxSuspensions != null) result.maxSuspensions = maxSuspensions;
    if (restoredScriptName != null)
      result.restoredScriptName = restoredScriptName;
    if (feedExecutionMicros != null)
      result.feedExecutionMicros = feedExecutionMicros;
    if (maxFeedDurationMicros != null)
      result.maxFeedDurationMicros = maxFeedDurationMicros;
    if (maxTurnDurationMicros != null)
      result.maxTurnDurationMicros = maxTurnDurationMicros;
    if (maxTotalSleepMicros != null)
      result.maxTotalSleepMicros = maxTotalSleepMicros;
    if (sessionId != null) result.sessionId = sessionId;
    return result;
  }

  ChildEvent._();

  factory ChildEvent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ChildEvent()..mergeFromBuffer(data, registry);
  factory ChildEvent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ChildEvent()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, ChildEvent_Kind> _ChildEvent_KindByTag = {
    1: ChildEvent_Kind.print,
    2: ChildEvent_Kind.functionCall,
    3: ChildEvent_Kind.osCall,
    4: ChildEvent_Kind.nameLookup,
    5: ChildEvent_Kind.resolveFutures,
    6: ChildEvent_Kind.complete,
    7: ChildEvent_Kind.error,
    8: ChildEvent_Kind.typingError,
    9: ChildEvent_Kind.dumpResult,
    10: ChildEvent_Kind.ok,
    11: ChildEvent_Kind.fatalError,
    12: ChildEvent_Kind.shutdown,
    0: ChildEvent_Kind.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ChildEvent',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ChildEvent.$_createMessage)
    ..oo(0, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
    ..aOM<Print>(1, _omitFieldNames ? '' : 'print',
        subBuilder: Print.$_createMessage)
    ..aOM<FunctionCall>(2, _omitFieldNames ? '' : 'functionCall',
        subBuilder: FunctionCall.$_createMessage)
    ..aOM<OsCall>(3, _omitFieldNames ? '' : 'osCall',
        subBuilder: OsCall.$_createMessage)
    ..aOM<NameLookup>(4, _omitFieldNames ? '' : 'nameLookup',
        subBuilder: NameLookup.$_createMessage)
    ..aOM<ResolveFutures>(5, _omitFieldNames ? '' : 'resolveFutures',
        subBuilder: ResolveFutures.$_createMessage)
    ..aOM<Complete>(6, _omitFieldNames ? '' : 'complete',
        subBuilder: Complete.$_createMessage)
    ..aOM<Error>(7, _omitFieldNames ? '' : 'error',
        subBuilder: Error.$_createMessage)
    ..aOM<TypingError>(8, _omitFieldNames ? '' : 'typingError',
        subBuilder: TypingError.$_createMessage)
    ..aOM<DumpResult>(9, _omitFieldNames ? '' : 'dumpResult',
        subBuilder: DumpResult.$_createMessage)
    ..aOM<Ok>(10, _omitFieldNames ? '' : 'ok', subBuilder: Ok.$_createMessage)
    ..aOM<FatalError>(11, _omitFieldNames ? '' : 'fatalError',
        subBuilder: FatalError.$_createMessage)
    ..aOM<ShutdownDump>(12, _omitFieldNames ? '' : 'shutdown',
        subBuilder: ShutdownDump.$_createMessage)
    ..a<$fixnum.Int64>(
        20, _omitFieldNames ? '' : 'totalExecutionMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        22, _omitFieldNames ? '' : 'maxSuspensions', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..aOS(23, _omitFieldNames ? '' : 'restoredScriptName')
    ..a<$fixnum.Int64>(
        24, _omitFieldNames ? '' : 'feedExecutionMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        25, _omitFieldNames ? '' : 'maxFeedDurationMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        26, _omitFieldNames ? '' : 'maxTurnDurationMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$fixnum.Int64>(
        27, _omitFieldNames ? '' : 'maxTotalSleepMicros', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..a<$core.List<$core.int>>(
        28, _omitFieldNames ? '' : 'sessionId', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChildEvent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ChildEvent copyWith(void Function(ChildEvent) updates) =>
      super.copyWith((message) => updates(message as ChildEvent)) as ChildEvent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ChildEvent() / ChildEvent.new instead')
  static ChildEvent create() => ChildEvent._();
  static $pb.GeneratedMessage $_createMessage() => ChildEvent._();
  @$core.override
  ChildEvent createEmptyInstance() => ChildEvent._();
  @$core.pragma('dart2js:noInline')
  static ChildEvent getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<ChildEvent>(ChildEvent.$_createMessage);
  static ChildEvent? _defaultInstance;

  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  ChildEvent_Kind whichKind() => _ChildEvent_KindByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(1)
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  void clearKind() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  Print get print => $_getN(0);
  @$pb.TagNumber(1)
  set print(Print value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasPrint() => $_has(0);
  @$pb.TagNumber(1)
  void clearPrint() => $_clearField(1);
  @$pb.TagNumber(1)
  Print ensurePrint() => $_ensure(0);

  @$pb.TagNumber(2)
  FunctionCall get functionCall => $_getN(1);
  @$pb.TagNumber(2)
  set functionCall(FunctionCall value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasFunctionCall() => $_has(1);
  @$pb.TagNumber(2)
  void clearFunctionCall() => $_clearField(2);
  @$pb.TagNumber(2)
  FunctionCall ensureFunctionCall() => $_ensure(1);

  @$pb.TagNumber(3)
  OsCall get osCall => $_getN(2);
  @$pb.TagNumber(3)
  set osCall(OsCall value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasOsCall() => $_has(2);
  @$pb.TagNumber(3)
  void clearOsCall() => $_clearField(3);
  @$pb.TagNumber(3)
  OsCall ensureOsCall() => $_ensure(2);

  @$pb.TagNumber(4)
  NameLookup get nameLookup => $_getN(3);
  @$pb.TagNumber(4)
  set nameLookup(NameLookup value) => $_setField(4, value);
  @$pb.TagNumber(4)
  $core.bool hasNameLookup() => $_has(3);
  @$pb.TagNumber(4)
  void clearNameLookup() => $_clearField(4);
  @$pb.TagNumber(4)
  NameLookup ensureNameLookup() => $_ensure(3);

  @$pb.TagNumber(5)
  ResolveFutures get resolveFutures => $_getN(4);
  @$pb.TagNumber(5)
  set resolveFutures(ResolveFutures value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasResolveFutures() => $_has(4);
  @$pb.TagNumber(5)
  void clearResolveFutures() => $_clearField(5);
  @$pb.TagNumber(5)
  ResolveFutures ensureResolveFutures() => $_ensure(4);

  @$pb.TagNumber(6)
  Complete get complete => $_getN(5);
  @$pb.TagNumber(6)
  set complete(Complete value) => $_setField(6, value);
  @$pb.TagNumber(6)
  $core.bool hasComplete() => $_has(5);
  @$pb.TagNumber(6)
  void clearComplete() => $_clearField(6);
  @$pb.TagNumber(6)
  Complete ensureComplete() => $_ensure(5);

  @$pb.TagNumber(7)
  Error get error => $_getN(6);
  @$pb.TagNumber(7)
  set error(Error value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasError() => $_has(6);
  @$pb.TagNumber(7)
  void clearError() => $_clearField(7);
  @$pb.TagNumber(7)
  Error ensureError() => $_ensure(6);

  @$pb.TagNumber(8)
  TypingError get typingError => $_getN(7);
  @$pb.TagNumber(8)
  set typingError(TypingError value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasTypingError() => $_has(7);
  @$pb.TagNumber(8)
  void clearTypingError() => $_clearField(8);
  @$pb.TagNumber(8)
  TypingError ensureTypingError() => $_ensure(7);

  @$pb.TagNumber(9)
  DumpResult get dumpResult => $_getN(8);
  @$pb.TagNumber(9)
  set dumpResult(DumpResult value) => $_setField(9, value);
  @$pb.TagNumber(9)
  $core.bool hasDumpResult() => $_has(8);
  @$pb.TagNumber(9)
  void clearDumpResult() => $_clearField(9);
  @$pb.TagNumber(9)
  DumpResult ensureDumpResult() => $_ensure(8);

  @$pb.TagNumber(10)
  Ok get ok => $_getN(9);
  @$pb.TagNumber(10)
  set ok(Ok value) => $_setField(10, value);
  @$pb.TagNumber(10)
  $core.bool hasOk() => $_has(9);
  @$pb.TagNumber(10)
  void clearOk() => $_clearField(10);
  @$pb.TagNumber(10)
  Ok ensureOk() => $_ensure(9);

  @$pb.TagNumber(11)
  FatalError get fatalError => $_getN(10);
  @$pb.TagNumber(11)
  set fatalError(FatalError value) => $_setField(11, value);
  @$pb.TagNumber(11)
  $core.bool hasFatalError() => $_has(10);
  @$pb.TagNumber(11)
  void clearFatalError() => $_clearField(11);
  @$pb.TagNumber(11)
  FatalError ensureFatalError() => $_ensure(10);

  @$pb.TagNumber(12)
  ShutdownDump get shutdown => $_getN(11);
  @$pb.TagNumber(12)
  set shutdown(ShutdownDump value) => $_setField(12, value);
  @$pb.TagNumber(12)
  $core.bool hasShutdown() => $_has(11);
  @$pb.TagNumber(12)
  void clearShutdown() => $_clearField(12);
  @$pb.TagNumber(12)
  ShutdownDump ensureShutdown() => $_ensure(11);

  /// Cumulative execution time consumed by the session's sandbox code, in
  /// microseconds. The in-sandbox clock runs only while the interpreter is
  /// executing bytecode — never while suspended waiting on the parent or idle
  /// between feeds — and survives Dump/Load. Set on every turn-ending event
  /// while a session exists (zero on Print events and outside a session) so
  /// the parent can report how much sandbox time a session has used without
  /// keeping a second clock. Bounds nothing: the budgets are per-feed and
  /// per-turn.
  @$pb.TagNumber(20)
  $fixnum.Int64 get totalExecutionMicros => $_getI64(12);
  @$pb.TagNumber(20)
  set totalExecutionMicros($fixnum.Int64 value) => $_setInt64(12, value);
  @$pb.TagNumber(20)
  $core.bool hasTotalExecutionMicros() => $_has(12);
  @$pb.TagNumber(20)
  void clearTotalExecutionMicros() => $_clearField(20);

  /// Echoes the parent-enforced budget so a host restoring an opaque dump can
  /// recover it.
  @$pb.TagNumber(22)
  $fixnum.Int64 get maxSuspensions => $_getI64(13);
  @$pb.TagNumber(22)
  set maxSuspensions($fixnum.Int64 value) => $_setInt64(13, value);
  @$pb.TagNumber(22)
  $core.bool hasMaxSuspensions() => $_has(13);
  @$pb.TagNumber(22)
  void clearMaxSuspensions() => $_clearField(22);

  /// The session's script name, surfaced on a `Load` reply so a parent that
  /// restored a session (whose script name, like the limits above, travels
  /// inside the opaque dump bytes) learns it without parsing the dump. Set only
  /// on a successful `Load` reply; unset on all other events.
  @$pb.TagNumber(23)
  $core.String get restoredScriptName => $_getSZ(14);
  @$pb.TagNumber(23)
  set restoredScriptName($core.String value) => $_setString(14, value);
  @$pb.TagNumber(23)
  $core.bool hasRestoredScriptName() => $_has(14);
  @$pb.TagNumber(23)
  void clearRestoredScriptName() => $_clearField(23);

  /// Execution time consumed by the feed in progress, in microseconds — the
  /// `total_execution_micros` clock restarted at the feed that is running.
  /// Lets the parent backstop `max_feed_duration_micros` without tracking feed
  /// boundaries against a clock it cannot see. Zero outside a session.
  @$pb.TagNumber(24)
  $fixnum.Int64 get feedExecutionMicros => $_getI64(15);
  @$pb.TagNumber(24)
  set feedExecutionMicros($fixnum.Int64 value) => $_setInt64(15, value);
  @$pb.TagNumber(24)
  $core.bool hasFeedExecutionMicros() => $_has(15);
  @$pb.TagNumber(24)
  void clearFeedExecutionMicros() => $_clearField(24);

  /// The session's `max_feed_duration` and `max_turn_duration` limits in
  /// microseconds, when configured. Reported so a parent that restored a
  /// session via `Load` (where the limits travel inside the opaque state
  /// bytes) still learns its budgets.
  @$pb.TagNumber(25)
  $fixnum.Int64 get maxFeedDurationMicros => $_getI64(16);
  @$pb.TagNumber(25)
  set maxFeedDurationMicros($fixnum.Int64 value) => $_setInt64(16, value);
  @$pb.TagNumber(25)
  $core.bool hasMaxFeedDurationMicros() => $_has(16);
  @$pb.TagNumber(25)
  void clearMaxFeedDurationMicros() => $_clearField(25);

  @$pb.TagNumber(26)
  $fixnum.Int64 get maxTurnDurationMicros => $_getI64(17);
  @$pb.TagNumber(26)
  set maxTurnDurationMicros($fixnum.Int64 value) => $_setInt64(17, value);
  @$pb.TagNumber(26)
  $core.bool hasMaxTurnDurationMicros() => $_has(17);
  @$pb.TagNumber(26)
  void clearMaxTurnDurationMicros() => $_clearField(26);

  /// Parent-enforced sleep budget, also reported on `Load`.
  @$pb.TagNumber(27)
  $fixnum.Int64 get maxTotalSleepMicros => $_getI64(18);
  @$pb.TagNumber(27)
  set maxTotalSleepMicros($fixnum.Int64 value) => $_setInt64(18, value);
  @$pb.TagNumber(27)
  $core.bool hasMaxTotalSleepMicros() => $_has(18);
  @$pb.TagNumber(27)
  void clearMaxTotalSleepMicros() => $_clearField(27);

  /// The session this connection now holds, set only by a remote that stores
  /// sessions, on its first reply to `Configure` or `Load` whatever that
  /// reply's kind. Unset for ephemeral sessions or for remotes that don't
  /// support persistence.
  @$pb.TagNumber(28)
  $core.List<$core.int> get sessionId => $_getN(19);
  @$pb.TagNumber(28)
  set sessionId($core.List<$core.int> value) => $_setBytes(19, value);
  @$pb.TagNumber(28)
  $core.bool hasSessionId() => $_has(19);
  @$pb.TagNumber(28)
  void clearSessionId() => $_clearField(28);
}

/// One run of print() output on a single stream, as one `Print` event may
/// carry several.
class PrintSegment extends $pb.GeneratedMessage {
  factory PrintSegment({
    PrintStream? stream,
    $core.String? text,
  }) {
    final result = PrintSegment._();
    if (stream != null) result.stream = stream;
    if (text != null) result.text = text;
    return result;
  }

  PrintSegment._();

  factory PrintSegment.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PrintSegment()..mergeFromBuffer(data, registry);
  factory PrintSegment.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      PrintSegment()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'PrintSegment',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: PrintSegment.$_createMessage)
    ..aE<PrintStream>(1, _omitFieldNames ? '' : 'stream',
        enumValues: PrintStream.values)
    ..aOS(2, _omitFieldNames ? '' : 'text')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PrintSegment clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  PrintSegment copyWith(void Function(PrintSegment) updates) =>
      super.copyWith((message) => updates(message as PrintSegment))
          as PrintSegment;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use PrintSegment() / PrintSegment.new instead')
  static PrintSegment create() => PrintSegment._();
  static $pb.GeneratedMessage $_createMessage() => PrintSegment._();
  @$core.override
  PrintSegment createEmptyInstance() => PrintSegment._();
  @$core.pragma('dart2js:noInline')
  static PrintSegment getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<PrintSegment>(
          PrintSegment.$_createMessage);
  static PrintSegment? _defaultInstance;

  @$pb.TagNumber(1)
  PrintStream get stream => $_getN(0);
  @$pb.TagNumber(1)
  set stream(PrintStream value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasStream() => $_has(0);
  @$pb.TagNumber(1)
  void clearStream() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get text => $_getSZ(1);
  @$pb.TagNumber(2)
  set text($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasText() => $_has(1);
  @$pb.TagNumber(2)
  void clearText() => $_clearField(2);
}

/// Streamed sandbox print() output. Zero or more of these precede each
/// turn-ending event, and each carries the runs the worker had buffered, in
/// the order the sandbox produced them — so output alternating between the
/// streams batches into one event without losing that order.
class Print extends $pb.GeneratedMessage {
  factory Print({
    $core.Iterable<PrintSegment>? segments,
  }) {
    final result = Print._();
    if (segments != null) result.segments.addAll(segments);
    return result;
  }

  Print._();

  factory Print.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Print()..mergeFromBuffer(data, registry);
  factory Print.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Print()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Print',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Print.$_createMessage)
    ..pPM<PrintSegment>(1, _omitFieldNames ? '' : 'segments',
        subBuilder: PrintSegment.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Print clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Print copyWith(void Function(Print) updates) =>
      super.copyWith((message) => updates(message as Print)) as Print;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Print() / Print.new instead')
  static Print create() => Print._();
  static $pb.GeneratedMessage $_createMessage() => Print._();
  @$core.override
  Print createEmptyInstance() => Print._();
  @$core.pragma('dart2js:noInline')
  static Print getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Print>(Print.$_createMessage);
  static Print? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<PrintSegment> get segments => $_getList(0);
}

/// Suspension: the sandbox called an external function, or — when `object_id`
/// is set — a method on a host-backed object (the receiver is NOT included in
/// `args`; the host routes by uuid). The receiver may be a class instance or a
/// class type: calling a host class arrives as a `__call__` method call on the
/// class's uuid, and the host's own policy decides whether construction is
/// allowed. Answer with `ResumeCall`.
class FunctionCall extends $pb.GeneratedMessage {
  factory FunctionCall({
    $core.String? functionName,
    $core.Iterable<$core.int>? args,
    $core.Iterable<NodePair>? kwargs,
    $core.int? callId,
    Uuid? objectId,
    $core.bool? allowEagerAwait,
    Arena? values,
    SourceRange? position,
  }) {
    final result = FunctionCall._();
    if (functionName != null) result.functionName = functionName;
    if (args != null) result.args.addAll(args);
    if (kwargs != null) result.kwargs.addAll(kwargs);
    if (callId != null) result.callId = callId;
    if (objectId != null) result.objectId = objectId;
    if (allowEagerAwait != null) result.allowEagerAwait = allowEagerAwait;
    if (values != null) result.values = values;
    if (position != null) result.position = position;
    return result;
  }

  FunctionCall._();

  factory FunctionCall.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FunctionCall()..mergeFromBuffer(data, registry);
  factory FunctionCall.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FunctionCall()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FunctionCall',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: FunctionCall.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'functionName')
    ..p<$core.int>(2, _omitFieldNames ? '' : 'args', $pb.PbFieldType.KU3)
    ..pPM<NodePair>(3, _omitFieldNames ? '' : 'kwargs',
        subBuilder: NodePair.$_createMessage)
    ..aI(4, _omitFieldNames ? '' : 'callId', fieldType: $pb.PbFieldType.OU3)
    ..aOM<Uuid>(5, _omitFieldNames ? '' : 'objectId',
        subBuilder: Uuid.$_createMessage)
    ..aOB(6, _omitFieldNames ? '' : 'allowEagerAwait')
    ..aOM<Arena>(7, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..aOM<SourceRange>(8, _omitFieldNames ? '' : 'position',
        subBuilder: SourceRange.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionCall clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FunctionCall copyWith(void Function(FunctionCall) updates) =>
      super.copyWith((message) => updates(message as FunctionCall))
          as FunctionCall;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FunctionCall() / FunctionCall.new instead')
  static FunctionCall create() => FunctionCall._();
  static $pb.GeneratedMessage $_createMessage() => FunctionCall._();
  @$core.override
  FunctionCall createEmptyInstance() => FunctionCall._();
  @$core.pragma('dart2js:noInline')
  static FunctionCall getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<FunctionCall>(
          FunctionCall.$_createMessage);
  static FunctionCall? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get functionName => $_getSZ(0);
  @$pb.TagNumber(1)
  set functionName($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasFunctionName() => $_has(0);
  @$pb.TagNumber(1)
  void clearFunctionName() => $_clearField(1);

  /// Positional arguments, as indexes into `values`.
  @$pb.TagNumber(2)
  $pb.PbList<$core.int> get args => $_getList(1);

  /// Keyword arguments as `(key, value)` indexes into `values`, in order.
  @$pb.TagNumber(3)
  $pb.PbList<NodePair> get kwargs => $_getList(2);

  @$pb.TagNumber(4)
  $core.int get callId => $_getIZ(3);
  @$pb.TagNumber(4)
  set callId($core.int value) => $_setUnsignedInt32(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCallId() => $_has(3);
  @$pb.TagNumber(4)
  void clearCallId() => $_clearField(4);

  /// The uuid of the receiver; absent for plain external function calls.
  @$pb.TagNumber(5)
  Uuid get objectId => $_getN(4);
  @$pb.TagNumber(5)
  set objectId(Uuid value) => $_setField(5, value);
  @$pb.TagNumber(5)
  $core.bool hasObjectId() => $_has(4);
  @$pb.TagNumber(5)
  void clearObjectId() => $_clearField(5);
  @$pb.TagNumber(5)
  Uuid ensureObjectId() => $_ensure(4);

  /// The host may await a coroutine and answer with ResumeFutures for this
  /// call_id. Synchronous results use ResumeCall; returning a pending
  /// future remains valid. Absent/false requires the ordinary call reply.
  @$pb.TagNumber(6)
  $core.bool get allowEagerAwait => $_getBF(5);
  @$pb.TagNumber(6)
  set allowEagerAwait($core.bool value) => $_setBool(5, value);
  @$pb.TagNumber(6)
  $core.bool hasAllowEagerAwait() => $_has(5);
  @$pb.TagNumber(6)
  void clearAllowEagerAwait() => $_clearField(6);

  /// The arena `args` and `kwargs` index: one per call, so an object passed
  /// twice crosses once.
  @$pb.TagNumber(7)
  Arena get values => $_getN(6);
  @$pb.TagNumber(7)
  set values(Arena value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasValues() => $_has(6);
  @$pb.TagNumber(7)
  void clearValues() => $_clearField(7);
  @$pb.TagNumber(7)
  Arena ensureValues() => $_ensure(6);

  /// Where the call expression is in the source. Absent from a child that
  /// predates the field; the parent then reports an empty range at offset 0.
  @$pb.TagNumber(8)
  SourceRange get position => $_getN(7);
  @$pb.TagNumber(8)
  set position(SourceRange value) => $_setField(8, value);
  @$pb.TagNumber(8)
  $core.bool hasPosition() => $_has(7);
  @$pb.TagNumber(8)
  void clearPosition() => $_clearField(8);
  @$pb.TagNumber(8)
  SourceRange ensurePosition() => $_ensure(7);
}

class OsCall_TextWrite extends $pb.GeneratedMessage {
  factory OsCall_TextWrite({
    $core.String? path,
    $core.String? data,
  }) {
    final result = OsCall_TextWrite._();
    if (path != null) result.path = path;
    if (data != null) result.data = data;
    return result;
  }

  OsCall_TextWrite._();

  factory OsCall_TextWrite.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_TextWrite()..mergeFromBuffer(data, registry);
  factory OsCall_TextWrite.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_TextWrite()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.TextWrite',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_TextWrite.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aOS(2, _omitFieldNames ? '' : 'data')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_TextWrite clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_TextWrite copyWith(void Function(OsCall_TextWrite) updates) =>
      super.copyWith((message) => updates(message as OsCall_TextWrite))
          as OsCall_TextWrite;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_TextWrite() / OsCall_TextWrite.new instead')
  static OsCall_TextWrite create() => OsCall_TextWrite._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_TextWrite._();
  @$core.override
  OsCall_TextWrite createEmptyInstance() => OsCall_TextWrite._();
  @$core.pragma('dart2js:noInline')
  static OsCall_TextWrite getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_TextWrite>(
          OsCall_TextWrite.$_createMessage);
  static OsCall_TextWrite? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get data => $_getSZ(1);
  @$pb.TagNumber(2)
  set data($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);
}

class OsCall_BytesWrite extends $pb.GeneratedMessage {
  factory OsCall_BytesWrite({
    $core.String? path,
    $core.List<$core.int>? data,
  }) {
    final result = OsCall_BytesWrite._();
    if (path != null) result.path = path;
    if (data != null) result.data = data;
    return result;
  }

  OsCall_BytesWrite._();

  factory OsCall_BytesWrite.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_BytesWrite()..mergeFromBuffer(data, registry);
  factory OsCall_BytesWrite.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_BytesWrite()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.BytesWrite',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_BytesWrite.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..a<$core.List<$core.int>>(
        2, _omitFieldNames ? '' : 'data', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_BytesWrite clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_BytesWrite copyWith(void Function(OsCall_BytesWrite) updates) =>
      super.copyWith((message) => updates(message as OsCall_BytesWrite))
          as OsCall_BytesWrite;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_BytesWrite() / OsCall_BytesWrite.new instead')
  static OsCall_BytesWrite create() => OsCall_BytesWrite._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_BytesWrite._();
  @$core.override
  OsCall_BytesWrite createEmptyInstance() => OsCall_BytesWrite._();
  @$core.pragma('dart2js:noInline')
  static OsCall_BytesWrite getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_BytesWrite>(
          OsCall_BytesWrite.$_createMessage);
  static OsCall_BytesWrite? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.List<$core.int> get data => $_getN(1);
  @$pb.TagNumber(2)
  set data($core.List<$core.int> value) => $_setBytes(1, value);
  @$pb.TagNumber(2)
  $core.bool hasData() => $_has(1);
  @$pb.TagNumber(2)
  void clearData() => $_clearField(2);
}

class OsCall_Open extends $pb.GeneratedMessage {
  factory OsCall_Open({
    $core.String? path,
    $core.String? mode,
  }) {
    final result = OsCall_Open._();
    if (path != null) result.path = path;
    if (mode != null) result.mode = mode;
    return result;
  }

  OsCall_Open._();

  factory OsCall_Open.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Open()..mergeFromBuffer(data, registry);
  factory OsCall_Open.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Open()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.Open',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_Open.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aOS(2, _omitFieldNames ? '' : 'mode')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Open clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Open copyWith(void Function(OsCall_Open) updates) =>
      super.copyWith((message) => updates(message as OsCall_Open))
          as OsCall_Open;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_Open() / OsCall_Open.new instead')
  static OsCall_Open create() => OsCall_Open._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_Open._();
  @$core.override
  OsCall_Open createEmptyInstance() => OsCall_Open._();
  @$core.pragma('dart2js:noInline')
  static OsCall_Open getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_Open>(
          OsCall_Open.$_createMessage);
  static OsCall_Open? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  /// Canonical open() mode string, same set as `FileHandle.mode`.
  @$pb.TagNumber(2)
  $core.String get mode => $_getSZ(1);
  @$pb.TagNumber(2)
  set mode($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasMode() => $_has(1);
  @$pb.TagNumber(2)
  void clearMode() => $_clearField(2);
}

class OsCall_Mkdir extends $pb.GeneratedMessage {
  factory OsCall_Mkdir({
    $core.String? path,
    $core.bool? parents,
    $core.bool? existOk,
  }) {
    final result = OsCall_Mkdir._();
    if (path != null) result.path = path;
    if (parents != null) result.parents = parents;
    if (existOk != null) result.existOk = existOk;
    return result;
  }

  OsCall_Mkdir._();

  factory OsCall_Mkdir.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Mkdir()..mergeFromBuffer(data, registry);
  factory OsCall_Mkdir.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Mkdir()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.Mkdir',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_Mkdir.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'path')
    ..aOB(2, _omitFieldNames ? '' : 'parents')
    ..aOB(3, _omitFieldNames ? '' : 'existOk')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Mkdir clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Mkdir copyWith(void Function(OsCall_Mkdir) updates) =>
      super.copyWith((message) => updates(message as OsCall_Mkdir))
          as OsCall_Mkdir;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_Mkdir() / OsCall_Mkdir.new instead')
  static OsCall_Mkdir create() => OsCall_Mkdir._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_Mkdir._();
  @$core.override
  OsCall_Mkdir createEmptyInstance() => OsCall_Mkdir._();
  @$core.pragma('dart2js:noInline')
  static OsCall_Mkdir getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_Mkdir>(
          OsCall_Mkdir.$_createMessage);
  static OsCall_Mkdir? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get path => $_getSZ(0);
  @$pb.TagNumber(1)
  set path($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasPath() => $_has(0);
  @$pb.TagNumber(1)
  void clearPath() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.bool get parents => $_getBF(1);
  @$pb.TagNumber(2)
  set parents($core.bool value) => $_setBool(1, value);
  @$pb.TagNumber(2)
  $core.bool hasParents() => $_has(1);
  @$pb.TagNumber(2)
  void clearParents() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.bool get existOk => $_getBF(2);
  @$pb.TagNumber(3)
  set existOk($core.bool value) => $_setBool(2, value);
  @$pb.TagNumber(3)
  $core.bool hasExistOk() => $_has(2);
  @$pb.TagNumber(3)
  void clearExistOk() => $_clearField(3);
}

class OsCall_Rename extends $pb.GeneratedMessage {
  factory OsCall_Rename({
    $core.String? src,
    $core.String? dst,
  }) {
    final result = OsCall_Rename._();
    if (src != null) result.src = src;
    if (dst != null) result.dst = dst;
    return result;
  }

  OsCall_Rename._();

  factory OsCall_Rename.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Rename()..mergeFromBuffer(data, registry);
  factory OsCall_Rename.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Rename()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.Rename',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_Rename.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'src')
    ..aOS(2, _omitFieldNames ? '' : 'dst')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Rename clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Rename copyWith(void Function(OsCall_Rename) updates) =>
      super.copyWith((message) => updates(message as OsCall_Rename))
          as OsCall_Rename;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_Rename() / OsCall_Rename.new instead')
  static OsCall_Rename create() => OsCall_Rename._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_Rename._();
  @$core.override
  OsCall_Rename createEmptyInstance() => OsCall_Rename._();
  @$core.pragma('dart2js:noInline')
  static OsCall_Rename getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_Rename>(
          OsCall_Rename.$_createMessage);
  static OsCall_Rename? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get src => $_getSZ(0);
  @$pb.TagNumber(1)
  set src($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSrc() => $_has(0);
  @$pb.TagNumber(1)
  void clearSrc() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get dst => $_getSZ(1);
  @$pb.TagNumber(2)
  set dst($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDst() => $_has(1);
  @$pb.TagNumber(2)
  void clearDst() => $_clearField(2);
}

/// os.getenv(key, default) — `default` may be any Python value: an index
/// into the enclosing `OsCall.values`.
class OsCall_Getenv extends $pb.GeneratedMessage {
  factory OsCall_Getenv({
    $core.String? key,
    $core.int? default_2,
  }) {
    final result = OsCall_Getenv._();
    if (key != null) result.key = key;
    if (default_2 != null) result.default_2 = default_2;
    return result;
  }

  OsCall_Getenv._();

  factory OsCall_Getenv.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Getenv()..mergeFromBuffer(data, registry);
  factory OsCall_Getenv.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Getenv()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.Getenv',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_Getenv.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'key')
    ..aI(2, _omitFieldNames ? '' : 'default', fieldType: $pb.PbFieldType.OU3)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Getenv clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Getenv copyWith(void Function(OsCall_Getenv) updates) =>
      super.copyWith((message) => updates(message as OsCall_Getenv))
          as OsCall_Getenv;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_Getenv() / OsCall_Getenv.new instead')
  static OsCall_Getenv create() => OsCall_Getenv._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_Getenv._();
  @$core.override
  OsCall_Getenv createEmptyInstance() => OsCall_Getenv._();
  @$core.pragma('dart2js:noInline')
  static OsCall_Getenv getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_Getenv>(
          OsCall_Getenv.$_createMessage);
  static OsCall_Getenv? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get key => $_getSZ(0);
  @$pb.TagNumber(1)
  set key($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasKey() => $_has(0);
  @$pb.TagNumber(1)
  void clearKey() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.int get default_2 => $_getIZ(1);
  @$pb.TagNumber(2)
  set default_2($core.int value) => $_setUnsignedInt32(1, value);
  @$pb.TagNumber(2)
  $core.bool hasDefault_2() => $_has(1);
  @$pb.TagNumber(2)
  void clearDefault_2() => $_clearField(2);
}

/// A `time`-module clock read. `caller` names the Python function that asked
/// (`time.time`, `time.monotonic`, ...), so a parent may answer them
/// differently; they all share the `time.time` call name.
class OsCall_TimeCall extends $pb.GeneratedMessage {
  factory OsCall_TimeCall({
    $core.String? caller,
  }) {
    final result = OsCall_TimeCall._();
    if (caller != null) result.caller = caller;
    return result;
  }

  OsCall_TimeCall._();

  factory OsCall_TimeCall.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_TimeCall()..mergeFromBuffer(data, registry);
  factory OsCall_TimeCall.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_TimeCall()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.TimeCall',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_TimeCall.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'caller')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_TimeCall clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_TimeCall copyWith(void Function(OsCall_TimeCall) updates) =>
      super.copyWith((message) => updates(message as OsCall_TimeCall))
          as OsCall_TimeCall;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_TimeCall() / OsCall_TimeCall.new instead')
  static OsCall_TimeCall create() => OsCall_TimeCall._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_TimeCall._();
  @$core.override
  OsCall_TimeCall createEmptyInstance() => OsCall_TimeCall._();
  @$core.pragma('dart2js:noInline')
  static OsCall_TimeCall getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_TimeCall>(
          OsCall_TimeCall.$_createMessage);
  static OsCall_TimeCall? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get caller => $_getSZ(0);
  @$pb.TagNumber(1)
  set caller($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCaller() => $_has(0);
  @$pb.TagNumber(1)
  void clearCaller() => $_clearField(1);
}

/// datetime.now(tz) — the VM validates the argument to None-or-timezone
/// before suspending, so the wire carries a typed TimeZone rather than an
/// arbitrary MontyObject.
class OsCall_DateTimeNow extends $pb.GeneratedMessage {
  factory OsCall_DateTimeNow({
    TimeZone? tz,
  }) {
    final result = OsCall_DateTimeNow._();
    if (tz != null) result.tz = tz;
    return result;
  }

  OsCall_DateTimeNow._();

  factory OsCall_DateTimeNow.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_DateTimeNow()..mergeFromBuffer(data, registry);
  factory OsCall_DateTimeNow.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_DateTimeNow()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.DateTimeNow',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_DateTimeNow.$_createMessage)
    ..aOM<TimeZone>(1, _omitFieldNames ? '' : 'tz',
        subBuilder: TimeZone.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_DateTimeNow clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_DateTimeNow copyWith(void Function(OsCall_DateTimeNow) updates) =>
      super.copyWith((message) => updates(message as OsCall_DateTimeNow))
          as OsCall_DateTimeNow;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_DateTimeNow() / OsCall_DateTimeNow.new instead')
  static OsCall_DateTimeNow create() => OsCall_DateTimeNow._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_DateTimeNow._();
  @$core.override
  OsCall_DateTimeNow createEmptyInstance() => OsCall_DateTimeNow._();
  @$core.pragma('dart2js:noInline')
  static OsCall_DateTimeNow getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OsCall_DateTimeNow>(
          OsCall_DateTimeNow.$_createMessage);
  static OsCall_DateTimeNow? _defaultInstance;

  /// Fixed-offset timezone for an aware result; absent for a naive one.
  @$pb.TagNumber(1)
  TimeZone get tz => $_getN(0);
  @$pb.TagNumber(1)
  set tz(TimeZone value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasTz() => $_has(0);
  @$pb.TagNumber(1)
  void clearTz() => $_clearField(1);
  @$pb.TagNumber(1)
  TimeZone ensureTz() => $_ensure(0);
}

/// os.urandom(size) — the byte count the sandbox validated; unsigned so
/// a negative count cannot be expressed on the wire.
class OsCall_Urandom extends $pb.GeneratedMessage {
  factory OsCall_Urandom({
    $fixnum.Int64? size,
  }) {
    final result = OsCall_Urandom._();
    if (size != null) result.size = size;
    return result;
  }

  OsCall_Urandom._();

  factory OsCall_Urandom.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Urandom()..mergeFromBuffer(data, registry);
  factory OsCall_Urandom.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Urandom()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.Urandom',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_Urandom.$_createMessage)
    ..a<$fixnum.Int64>(1, _omitFieldNames ? '' : 'size', $pb.PbFieldType.OU6,
        defaultOrMaker: $fixnum.Int64.ZERO)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Urandom clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Urandom copyWith(void Function(OsCall_Urandom) updates) =>
      super.copyWith((message) => updates(message as OsCall_Urandom))
          as OsCall_Urandom;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_Urandom() / OsCall_Urandom.new instead')
  static OsCall_Urandom create() => OsCall_Urandom._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_Urandom._();
  @$core.override
  OsCall_Urandom createEmptyInstance() => OsCall_Urandom._();
  @$core.pragma('dart2js:noInline')
  static OsCall_Urandom getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_Urandom>(
          OsCall_Urandom.$_createMessage);
  static OsCall_Urandom? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get size => $_getI64(0);
  @$pb.TagNumber(1)
  set size($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSize() => $_has(0);
  @$pb.TagNumber(1)
  void clearSize() => $_clearField(1);
}

/// time.sleep(seconds) — the parent waits, then answers (the sandbox
/// evaluates the call to None whatever the answer carried). Answering with a
/// future is refused: the call is a block by definition.
class OsCall_Sleep extends $pb.GeneratedMessage {
  factory OsCall_Sleep({
    $core.double? seconds,
  }) {
    final result = OsCall_Sleep._();
    if (seconds != null) result.seconds = seconds;
    return result;
  }

  OsCall_Sleep._();

  factory OsCall_Sleep.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Sleep()..mergeFromBuffer(data, registry);
  factory OsCall_Sleep.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_Sleep()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.Sleep',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_Sleep.$_createMessage)
    ..aD(1, _omitFieldNames ? '' : 'seconds')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Sleep clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_Sleep copyWith(void Function(OsCall_Sleep) updates) =>
      super.copyWith((message) => updates(message as OsCall_Sleep))
          as OsCall_Sleep;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_Sleep() / OsCall_Sleep.new instead')
  static OsCall_Sleep create() => OsCall_Sleep._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_Sleep._();
  @$core.override
  OsCall_Sleep createEmptyInstance() => OsCall_Sleep._();
  @$core.pragma('dart2js:noInline')
  static OsCall_Sleep getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_Sleep>(
          OsCall_Sleep.$_createMessage);
  static OsCall_Sleep? _defaultInstance;

  /// How long to wait. Always finite, non-negative, and small enough to be a
  /// duration of nanoseconds in an int64; a frame breaking that is rejected.
  @$pb.TagNumber(1)
  $core.double get seconds => $_getN(0);
  @$pb.TagNumber(1)
  set seconds($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasSeconds() => $_has(0);
  @$pb.TagNumber(1)
  void clearSeconds() => $_clearField(1);
}

/// asyncio.sleep(delay) — the awaitable form. A parent running an event
/// loop should answer `ExtFunctionResult.future` and resolve it once the
/// delay elapses, so the sandbox's other tasks keep running; answering
/// directly is equivalent to a wait that blocks them. The answer's value is
/// ignored: the sandbox keeps the `result` argument itself and produces it
/// from the `await`.
class OsCall_AsyncSleep extends $pb.GeneratedMessage {
  factory OsCall_AsyncSleep({
    $core.double? delay,
  }) {
    final result = OsCall_AsyncSleep._();
    if (delay != null) result.delay = delay;
    return result;
  }

  OsCall_AsyncSleep._();

  factory OsCall_AsyncSleep.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_AsyncSleep()..mergeFromBuffer(data, registry);
  factory OsCall_AsyncSleep.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall_AsyncSleep()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall.AsyncSleep',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall_AsyncSleep.$_createMessage)
    ..aD(1, _omitFieldNames ? '' : 'delay')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_AsyncSleep clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall_AsyncSleep copyWith(void Function(OsCall_AsyncSleep) updates) =>
      super.copyWith((message) => updates(message as OsCall_AsyncSleep))
          as OsCall_AsyncSleep;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall_AsyncSleep() / OsCall_AsyncSleep.new instead')
  static OsCall_AsyncSleep create() => OsCall_AsyncSleep._();
  static $pb.GeneratedMessage $_createMessage() => OsCall_AsyncSleep._();
  @$core.override
  OsCall_AsyncSleep createEmptyInstance() => OsCall_AsyncSleep._();
  @$core.pragma('dart2js:noInline')
  static OsCall_AsyncSleep getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OsCall_AsyncSleep>(
          OsCall_AsyncSleep.$_createMessage);
  static OsCall_AsyncSleep? _defaultInstance;

  /// How long to wait, under the same constraints as `Sleep.seconds`.
  @$pb.TagNumber(1)
  $core.double get delay => $_getN(0);
  @$pb.TagNumber(1)
  set delay($core.double value) => $_setDouble(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDelay() => $_has(0);
  @$pb.TagNumber(1)
  void clearDelay() => $_clearField(1);
}

enum OsCall_Call {
  exists,
  isFile,
  isDir,
  isSymlink,
  readText,
  readBytes,
  stat,
  iterdir,
  resolve,
  absolute,
  unlink,
  rmdir,
  writeText,
  appendText,
  writeBytes,
  appendBytes,
  open,
  mkdir,
  rename,
  getenv,
  getEnviron,
  dateToday,
  dateTimeNow,
  urandom,
  time,
  sleep,
  asyncSleep,
  systemSleep,
  asyncSystemSleep,
  notSet
}

/// Suspension: the sandbox performed an OS operation, surfaced for the parent
/// to service (e.g. from a mount) or answer with `ResumeCall`. One typed arm
/// per call; every path is a virtual POSIX sandbox path, never a host path.
/// Some calls have typed result expectations (e.g. `open` must return a
/// file_handle); a mismatched result becomes a Python-level error inside the
/// sandbox.
///
/// A parent with no handler should answer `ResumeCall` with
/// `ExtFunctionResult.not_handled`: the child raises the call's own default
/// (PermissionError naming the path for filesystem calls, RuntimeError for
/// the rest — monty's `OsFunctionCall::on_no_handler`).
///
/// Tags 2-49 are reserved for `call` arms and the other message-level fields
/// start at 50, as in `ChildEvent`, so a new call never has to jump the numbering.
class OsCall extends $pb.GeneratedMessage {
  factory OsCall({
    $core.int? callId,
    $core.String? exists,
    $core.String? isFile,
    $core.String? isDir,
    $core.String? isSymlink,
    $core.String? readText,
    $core.String? readBytes,
    $core.String? stat,
    $core.String? iterdir,
    $core.String? resolve,
    $core.String? absolute,
    $core.String? unlink,
    $core.String? rmdir,
    OsCall_TextWrite? writeText,
    OsCall_TextWrite? appendText,
    OsCall_BytesWrite? writeBytes,
    OsCall_BytesWrite? appendBytes,
    OsCall_Open? open,
    OsCall_Mkdir? mkdir,
    OsCall_Rename? rename,
    OsCall_Getenv? getenv,
    Unit? getEnviron,
    Unit? dateToday,
    OsCall_DateTimeNow? dateTimeNow,
    OsCall_Urandom? urandom,
    OsCall_TimeCall? time,
    OsCall_Sleep? sleep,
    OsCall_AsyncSleep? asyncSleep,
    OsCall_Sleep? systemSleep,
    OsCall_AsyncSleep? asyncSystemSleep,
    Arena? values,
    $core.bool? allowEagerAwait,
    SourceRange? position,
  }) {
    final result = OsCall._();
    if (callId != null) result.callId = callId;
    if (exists != null) result.exists = exists;
    if (isFile != null) result.isFile = isFile;
    if (isDir != null) result.isDir = isDir;
    if (isSymlink != null) result.isSymlink = isSymlink;
    if (readText != null) result.readText = readText;
    if (readBytes != null) result.readBytes = readBytes;
    if (stat != null) result.stat = stat;
    if (iterdir != null) result.iterdir = iterdir;
    if (resolve != null) result.resolve = resolve;
    if (absolute != null) result.absolute = absolute;
    if (unlink != null) result.unlink = unlink;
    if (rmdir != null) result.rmdir = rmdir;
    if (writeText != null) result.writeText = writeText;
    if (appendText != null) result.appendText = appendText;
    if (writeBytes != null) result.writeBytes = writeBytes;
    if (appendBytes != null) result.appendBytes = appendBytes;
    if (open != null) result.open = open;
    if (mkdir != null) result.mkdir = mkdir;
    if (rename != null) result.rename = rename;
    if (getenv != null) result.getenv = getenv;
    if (getEnviron != null) result.getEnviron = getEnviron;
    if (dateToday != null) result.dateToday = dateToday;
    if (dateTimeNow != null) result.dateTimeNow = dateTimeNow;
    if (urandom != null) result.urandom = urandom;
    if (time != null) result.time = time;
    if (sleep != null) result.sleep = sleep;
    if (asyncSleep != null) result.asyncSleep = asyncSleep;
    if (systemSleep != null) result.systemSleep = systemSleep;
    if (asyncSystemSleep != null) result.asyncSystemSleep = asyncSystemSleep;
    if (values != null) result.values = values;
    if (allowEagerAwait != null) result.allowEagerAwait = allowEagerAwait;
    if (position != null) result.position = position;
    return result;
  }

  OsCall._();

  factory OsCall.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall()..mergeFromBuffer(data, registry);
  factory OsCall.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OsCall()..mergeFromJson(json, registry);

  static const $core.Map<$core.int, OsCall_Call> _OsCall_CallByTag = {
    2: OsCall_Call.exists,
    3: OsCall_Call.isFile,
    4: OsCall_Call.isDir,
    5: OsCall_Call.isSymlink,
    6: OsCall_Call.readText,
    7: OsCall_Call.readBytes,
    8: OsCall_Call.stat,
    9: OsCall_Call.iterdir,
    10: OsCall_Call.resolve,
    11: OsCall_Call.absolute,
    12: OsCall_Call.unlink,
    13: OsCall_Call.rmdir,
    14: OsCall_Call.writeText,
    15: OsCall_Call.appendText,
    16: OsCall_Call.writeBytes,
    17: OsCall_Call.appendBytes,
    18: OsCall_Call.open,
    19: OsCall_Call.mkdir,
    20: OsCall_Call.rename,
    21: OsCall_Call.getenv,
    22: OsCall_Call.getEnviron,
    23: OsCall_Call.dateToday,
    24: OsCall_Call.dateTimeNow,
    25: OsCall_Call.urandom,
    26: OsCall_Call.time,
    27: OsCall_Call.sleep,
    28: OsCall_Call.asyncSleep,
    29: OsCall_Call.systemSleep,
    30: OsCall_Call.asyncSystemSleep,
    0: OsCall_Call.notSet
  };
  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OsCall',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: OsCall.$_createMessage)
    ..oo(0, [
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
      17,
      18,
      19,
      20,
      21,
      22,
      23,
      24,
      25,
      26,
      27,
      28,
      29,
      30
    ])
    ..aI(1, _omitFieldNames ? '' : 'callId', fieldType: $pb.PbFieldType.OU3)
    ..aOS(2, _omitFieldNames ? '' : 'exists')
    ..aOS(3, _omitFieldNames ? '' : 'isFile')
    ..aOS(4, _omitFieldNames ? '' : 'isDir')
    ..aOS(5, _omitFieldNames ? '' : 'isSymlink')
    ..aOS(6, _omitFieldNames ? '' : 'readText')
    ..aOS(7, _omitFieldNames ? '' : 'readBytes')
    ..aOS(8, _omitFieldNames ? '' : 'stat')
    ..aOS(9, _omitFieldNames ? '' : 'iterdir')
    ..aOS(10, _omitFieldNames ? '' : 'resolve')
    ..aOS(11, _omitFieldNames ? '' : 'absolute')
    ..aOS(12, _omitFieldNames ? '' : 'unlink')
    ..aOS(13, _omitFieldNames ? '' : 'rmdir')
    ..aOM<OsCall_TextWrite>(14, _omitFieldNames ? '' : 'writeText',
        subBuilder: OsCall_TextWrite.$_createMessage)
    ..aOM<OsCall_TextWrite>(15, _omitFieldNames ? '' : 'appendText',
        subBuilder: OsCall_TextWrite.$_createMessage)
    ..aOM<OsCall_BytesWrite>(16, _omitFieldNames ? '' : 'writeBytes',
        subBuilder: OsCall_BytesWrite.$_createMessage)
    ..aOM<OsCall_BytesWrite>(17, _omitFieldNames ? '' : 'appendBytes',
        subBuilder: OsCall_BytesWrite.$_createMessage)
    ..aOM<OsCall_Open>(18, _omitFieldNames ? '' : 'open',
        subBuilder: OsCall_Open.$_createMessage)
    ..aOM<OsCall_Mkdir>(19, _omitFieldNames ? '' : 'mkdir',
        subBuilder: OsCall_Mkdir.$_createMessage)
    ..aOM<OsCall_Rename>(20, _omitFieldNames ? '' : 'rename',
        subBuilder: OsCall_Rename.$_createMessage)
    ..aOM<OsCall_Getenv>(21, _omitFieldNames ? '' : 'getenv',
        subBuilder: OsCall_Getenv.$_createMessage)
    ..aOM<Unit>(22, _omitFieldNames ? '' : 'getEnviron',
        subBuilder: Unit.$_createMessage)
    ..aOM<Unit>(23, _omitFieldNames ? '' : 'dateToday',
        subBuilder: Unit.$_createMessage)
    ..aOM<OsCall_DateTimeNow>(24, _omitFieldNames ? '' : 'dateTimeNow',
        subBuilder: OsCall_DateTimeNow.$_createMessage)
    ..aOM<OsCall_Urandom>(25, _omitFieldNames ? '' : 'urandom',
        subBuilder: OsCall_Urandom.$_createMessage)
    ..aOM<OsCall_TimeCall>(26, _omitFieldNames ? '' : 'time',
        subBuilder: OsCall_TimeCall.$_createMessage)
    ..aOM<OsCall_Sleep>(27, _omitFieldNames ? '' : 'sleep',
        subBuilder: OsCall_Sleep.$_createMessage)
    ..aOM<OsCall_AsyncSleep>(28, _omitFieldNames ? '' : 'asyncSleep',
        subBuilder: OsCall_AsyncSleep.$_createMessage)
    ..aOM<OsCall_Sleep>(29, _omitFieldNames ? '' : 'systemSleep',
        subBuilder: OsCall_Sleep.$_createMessage)
    ..aOM<OsCall_AsyncSleep>(30, _omitFieldNames ? '' : 'asyncSystemSleep',
        subBuilder: OsCall_AsyncSleep.$_createMessage)
    ..aOM<Arena>(50, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..aOB(51, _omitFieldNames ? '' : 'allowEagerAwait')
    ..aOM<SourceRange>(52, _omitFieldNames ? '' : 'position',
        subBuilder: SourceRange.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OsCall copyWith(void Function(OsCall) updates) =>
      super.copyWith((message) => updates(message as OsCall)) as OsCall;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OsCall() / OsCall.new instead')
  static OsCall create() => OsCall._();
  static $pb.GeneratedMessage $_createMessage() => OsCall._();
  @$core.override
  OsCall createEmptyInstance() => OsCall._();
  @$core.pragma('dart2js:noInline')
  static OsCall getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<OsCall>(OsCall.$_createMessage);
  static OsCall? _defaultInstance;

  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  @$pb.TagNumber(13)
  @$pb.TagNumber(14)
  @$pb.TagNumber(15)
  @$pb.TagNumber(16)
  @$pb.TagNumber(17)
  @$pb.TagNumber(18)
  @$pb.TagNumber(19)
  @$pb.TagNumber(20)
  @$pb.TagNumber(21)
  @$pb.TagNumber(22)
  @$pb.TagNumber(23)
  @$pb.TagNumber(24)
  @$pb.TagNumber(25)
  @$pb.TagNumber(26)
  @$pb.TagNumber(27)
  @$pb.TagNumber(28)
  @$pb.TagNumber(29)
  @$pb.TagNumber(30)
  OsCall_Call whichCall() => _OsCall_CallByTag[$_whichOneof(0)]!;
  @$pb.TagNumber(2)
  @$pb.TagNumber(3)
  @$pb.TagNumber(4)
  @$pb.TagNumber(5)
  @$pb.TagNumber(6)
  @$pb.TagNumber(7)
  @$pb.TagNumber(8)
  @$pb.TagNumber(9)
  @$pb.TagNumber(10)
  @$pb.TagNumber(11)
  @$pb.TagNumber(12)
  @$pb.TagNumber(13)
  @$pb.TagNumber(14)
  @$pb.TagNumber(15)
  @$pb.TagNumber(16)
  @$pb.TagNumber(17)
  @$pb.TagNumber(18)
  @$pb.TagNumber(19)
  @$pb.TagNumber(20)
  @$pb.TagNumber(21)
  @$pb.TagNumber(22)
  @$pb.TagNumber(23)
  @$pb.TagNumber(24)
  @$pb.TagNumber(25)
  @$pb.TagNumber(26)
  @$pb.TagNumber(27)
  @$pb.TagNumber(28)
  @$pb.TagNumber(29)
  @$pb.TagNumber(30)
  void clearCall() => $_clearField($_whichOneof(0));

  @$pb.TagNumber(1)
  $core.int get callId => $_getIZ(0);
  @$pb.TagNumber(1)
  set callId($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasCallId() => $_has(0);
  @$pb.TagNumber(1)
  void clearCallId() => $_clearField(1);

  /// ---- FS read / check / remove — the string is the virtual path -------
  @$pb.TagNumber(2)
  $core.String get exists => $_getSZ(1);
  @$pb.TagNumber(2)
  set exists($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasExists() => $_has(1);
  @$pb.TagNumber(2)
  void clearExists() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get isFile => $_getSZ(2);
  @$pb.TagNumber(3)
  set isFile($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasIsFile() => $_has(2);
  @$pb.TagNumber(3)
  void clearIsFile() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get isDir => $_getSZ(3);
  @$pb.TagNumber(4)
  set isDir($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasIsDir() => $_has(3);
  @$pb.TagNumber(4)
  void clearIsDir() => $_clearField(4);

  @$pb.TagNumber(5)
  $core.String get isSymlink => $_getSZ(4);
  @$pb.TagNumber(5)
  set isSymlink($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasIsSymlink() => $_has(4);
  @$pb.TagNumber(5)
  void clearIsSymlink() => $_clearField(5);

  @$pb.TagNumber(6)
  $core.String get readText => $_getSZ(5);
  @$pb.TagNumber(6)
  set readText($core.String value) => $_setString(5, value);
  @$pb.TagNumber(6)
  $core.bool hasReadText() => $_has(5);
  @$pb.TagNumber(6)
  void clearReadText() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.String get readBytes => $_getSZ(6);
  @$pb.TagNumber(7)
  set readBytes($core.String value) => $_setString(6, value);
  @$pb.TagNumber(7)
  $core.bool hasReadBytes() => $_has(6);
  @$pb.TagNumber(7)
  void clearReadBytes() => $_clearField(7);

  @$pb.TagNumber(8)
  $core.String get stat => $_getSZ(7);
  @$pb.TagNumber(8)
  set stat($core.String value) => $_setString(7, value);
  @$pb.TagNumber(8)
  $core.bool hasStat() => $_has(7);
  @$pb.TagNumber(8)
  void clearStat() => $_clearField(8);

  @$pb.TagNumber(9)
  $core.String get iterdir => $_getSZ(8);
  @$pb.TagNumber(9)
  set iterdir($core.String value) => $_setString(8, value);
  @$pb.TagNumber(9)
  $core.bool hasIterdir() => $_has(8);
  @$pb.TagNumber(9)
  void clearIterdir() => $_clearField(9);

  @$pb.TagNumber(10)
  $core.String get resolve => $_getSZ(9);
  @$pb.TagNumber(10)
  set resolve($core.String value) => $_setString(9, value);
  @$pb.TagNumber(10)
  $core.bool hasResolve() => $_has(9);
  @$pb.TagNumber(10)
  void clearResolve() => $_clearField(10);

  @$pb.TagNumber(11)
  $core.String get absolute => $_getSZ(10);
  @$pb.TagNumber(11)
  set absolute($core.String value) => $_setString(10, value);
  @$pb.TagNumber(11)
  $core.bool hasAbsolute() => $_has(10);
  @$pb.TagNumber(11)
  void clearAbsolute() => $_clearField(11);

  @$pb.TagNumber(12)
  $core.String get unlink => $_getSZ(11);
  @$pb.TagNumber(12)
  set unlink($core.String value) => $_setString(11, value);
  @$pb.TagNumber(12)
  $core.bool hasUnlink() => $_has(11);
  @$pb.TagNumber(12)
  void clearUnlink() => $_clearField(12);

  @$pb.TagNumber(13)
  $core.String get rmdir => $_getSZ(12);
  @$pb.TagNumber(13)
  set rmdir($core.String value) => $_setString(12, value);
  @$pb.TagNumber(13)
  $core.bool hasRmdir() => $_has(12);
  @$pb.TagNumber(13)
  void clearRmdir() => $_clearField(13);

  /// ---- FS write / mutate -----------------------------------------------
  @$pb.TagNumber(14)
  OsCall_TextWrite get writeText => $_getN(13);
  @$pb.TagNumber(14)
  set writeText(OsCall_TextWrite value) => $_setField(14, value);
  @$pb.TagNumber(14)
  $core.bool hasWriteText() => $_has(13);
  @$pb.TagNumber(14)
  void clearWriteText() => $_clearField(14);
  @$pb.TagNumber(14)
  OsCall_TextWrite ensureWriteText() => $_ensure(13);

  @$pb.TagNumber(15)
  OsCall_TextWrite get appendText => $_getN(14);
  @$pb.TagNumber(15)
  set appendText(OsCall_TextWrite value) => $_setField(15, value);
  @$pb.TagNumber(15)
  $core.bool hasAppendText() => $_has(14);
  @$pb.TagNumber(15)
  void clearAppendText() => $_clearField(15);
  @$pb.TagNumber(15)
  OsCall_TextWrite ensureAppendText() => $_ensure(14);

  @$pb.TagNumber(16)
  OsCall_BytesWrite get writeBytes => $_getN(15);
  @$pb.TagNumber(16)
  set writeBytes(OsCall_BytesWrite value) => $_setField(16, value);
  @$pb.TagNumber(16)
  $core.bool hasWriteBytes() => $_has(15);
  @$pb.TagNumber(16)
  void clearWriteBytes() => $_clearField(16);
  @$pb.TagNumber(16)
  OsCall_BytesWrite ensureWriteBytes() => $_ensure(15);

  @$pb.TagNumber(17)
  OsCall_BytesWrite get appendBytes => $_getN(16);
  @$pb.TagNumber(17)
  set appendBytes(OsCall_BytesWrite value) => $_setField(17, value);
  @$pb.TagNumber(17)
  $core.bool hasAppendBytes() => $_has(16);
  @$pb.TagNumber(17)
  void clearAppendBytes() => $_clearField(17);
  @$pb.TagNumber(17)
  OsCall_BytesWrite ensureAppendBytes() => $_ensure(16);

  @$pb.TagNumber(18)
  OsCall_Open get open => $_getN(17);
  @$pb.TagNumber(18)
  set open(OsCall_Open value) => $_setField(18, value);
  @$pb.TagNumber(18)
  $core.bool hasOpen() => $_has(17);
  @$pb.TagNumber(18)
  void clearOpen() => $_clearField(18);
  @$pb.TagNumber(18)
  OsCall_Open ensureOpen() => $_ensure(17);

  @$pb.TagNumber(19)
  OsCall_Mkdir get mkdir => $_getN(18);
  @$pb.TagNumber(19)
  set mkdir(OsCall_Mkdir value) => $_setField(19, value);
  @$pb.TagNumber(19)
  $core.bool hasMkdir() => $_has(18);
  @$pb.TagNumber(19)
  void clearMkdir() => $_clearField(19);
  @$pb.TagNumber(19)
  OsCall_Mkdir ensureMkdir() => $_ensure(18);

  @$pb.TagNumber(20)
  OsCall_Rename get rename => $_getN(19);
  @$pb.TagNumber(20)
  set rename(OsCall_Rename value) => $_setField(20, value);
  @$pb.TagNumber(20)
  $core.bool hasRename() => $_has(19);
  @$pb.TagNumber(20)
  void clearRename() => $_clearField(20);
  @$pb.TagNumber(20)
  OsCall_Rename ensureRename() => $_ensure(19);

  /// ---- Non-FS ----------------------------------------------------------
  @$pb.TagNumber(21)
  OsCall_Getenv get getenv => $_getN(20);
  @$pb.TagNumber(21)
  set getenv(OsCall_Getenv value) => $_setField(21, value);
  @$pb.TagNumber(21)
  $core.bool hasGetenv() => $_has(20);
  @$pb.TagNumber(21)
  void clearGetenv() => $_clearField(21);
  @$pb.TagNumber(21)
  OsCall_Getenv ensureGetenv() => $_ensure(20);

  @$pb.TagNumber(22)
  Unit get getEnviron => $_getN(21);
  @$pb.TagNumber(22)
  set getEnviron(Unit value) => $_setField(22, value);
  @$pb.TagNumber(22)
  $core.bool hasGetEnviron() => $_has(21);
  @$pb.TagNumber(22)
  void clearGetEnviron() => $_clearField(22);
  @$pb.TagNumber(22)
  Unit ensureGetEnviron() => $_ensure(21);

  @$pb.TagNumber(23)
  Unit get dateToday => $_getN(22);
  @$pb.TagNumber(23)
  set dateToday(Unit value) => $_setField(23, value);
  @$pb.TagNumber(23)
  $core.bool hasDateToday() => $_has(22);
  @$pb.TagNumber(23)
  void clearDateToday() => $_clearField(23);
  @$pb.TagNumber(23)
  Unit ensureDateToday() => $_ensure(22);

  /// datetime.now(tz) — the timezone argument (absent for a naive result).
  @$pb.TagNumber(24)
  OsCall_DateTimeNow get dateTimeNow => $_getN(23);
  @$pb.TagNumber(24)
  set dateTimeNow(OsCall_DateTimeNow value) => $_setField(24, value);
  @$pb.TagNumber(24)
  $core.bool hasDateTimeNow() => $_has(23);
  @$pb.TagNumber(24)
  void clearDateTimeNow() => $_clearField(24);
  @$pb.TagNumber(24)
  OsCall_DateTimeNow ensureDateTimeNow() => $_ensure(23);

  /// os.urandom(size), also how `random` seeds an unseeded generator.
  @$pb.TagNumber(25)
  OsCall_Urandom get urandom => $_getN(24);
  @$pb.TagNumber(25)
  set urandom(OsCall_Urandom value) => $_setField(25, value);
  @$pb.TagNumber(25)
  $core.bool hasUrandom() => $_has(24);
  @$pb.TagNumber(25)
  void clearUrandom() => $_clearField(25);
  @$pb.TagNumber(25)
  OsCall_Urandom ensureUrandom() => $_ensure(24);

  @$pb.TagNumber(26)
  OsCall_TimeCall get time => $_getN(25);
  @$pb.TagNumber(26)
  set time(OsCall_TimeCall value) => $_setField(26, value);
  @$pb.TagNumber(26)
  $core.bool hasTime() => $_has(25);
  @$pb.TagNumber(26)
  void clearTime() => $_clearField(26);
  @$pb.TagNumber(26)
  OsCall_TimeCall ensureTime() => $_ensure(25);

  @$pb.TagNumber(27)
  OsCall_Sleep get sleep => $_getN(26);
  @$pb.TagNumber(27)
  set sleep(OsCall_Sleep value) => $_setField(27, value);
  @$pb.TagNumber(27)
  $core.bool hasSleep() => $_has(26);
  @$pb.TagNumber(27)
  void clearSleep() => $_clearField(27);
  @$pb.TagNumber(27)
  OsCall_Sleep ensureSleep() => $_ensure(26);

  @$pb.TagNumber(28)
  OsCall_AsyncSleep get asyncSleep => $_getN(27);
  @$pb.TagNumber(28)
  set asyncSleep(OsCall_AsyncSleep value) => $_setField(28, value);
  @$pb.TagNumber(28)
  $core.bool hasAsyncSleep() => $_has(27);
  @$pb.TagNumber(28)
  void clearAsyncSleep() => $_clearField(28);
  @$pb.TagNumber(28)
  OsCall_AsyncSleep ensureAsyncSleep() => $_ensure(27);

  /// System sleeps: capped by the child, charged to `max_total_sleep` and
  /// waited out by the parent without invoking its OS handler.
  @$pb.TagNumber(29)
  OsCall_Sleep get systemSleep => $_getN(28);
  @$pb.TagNumber(29)
  set systemSleep(OsCall_Sleep value) => $_setField(29, value);
  @$pb.TagNumber(29)
  $core.bool hasSystemSleep() => $_has(28);
  @$pb.TagNumber(29)
  void clearSystemSleep() => $_clearField(29);
  @$pb.TagNumber(29)
  OsCall_Sleep ensureSystemSleep() => $_ensure(28);

  @$pb.TagNumber(30)
  OsCall_AsyncSleep get asyncSystemSleep => $_getN(29);
  @$pb.TagNumber(30)
  set asyncSystemSleep(OsCall_AsyncSleep value) => $_setField(30, value);
  @$pb.TagNumber(30)
  $core.bool hasAsyncSystemSleep() => $_has(29);
  @$pb.TagNumber(30)
  void clearAsyncSystemSleep() => $_clearField(30);
  @$pb.TagNumber(30)
  OsCall_AsyncSleep ensureAsyncSystemSleep() => $_ensure(29);

  /// The arena any value-typed argument (`Getenv.default`) indexes.
  @$pb.TagNumber(50)
  Arena get values => $_getN(30);
  @$pb.TagNumber(50)
  set values(Arena value) => $_setField(50, value);
  @$pb.TagNumber(50)
  $core.bool hasValues() => $_has(30);
  @$pb.TagNumber(50)
  void clearValues() => $_clearField(50);
  @$pb.TagNumber(50)
  Arena ensureValues() => $_ensure(30);

  /// As on `FunctionCall`: the parent may await a coroutine and answer with
  /// `ResumeFutures` for `call_id`. Only ever set on `async_sleep`, the one
  /// call a future may answer at all.
  @$pb.TagNumber(51)
  $core.bool get allowEagerAwait => $_getBF(31);
  @$pb.TagNumber(51)
  set allowEagerAwait($core.bool value) => $_setBool(31, value);
  @$pb.TagNumber(51)
  $core.bool hasAllowEagerAwait() => $_has(31);
  @$pb.TagNumber(51)
  void clearAllowEagerAwait() => $_clearField(51);

  /// Where the call expression is in the source; absent as on `FunctionCall`.
  @$pb.TagNumber(52)
  SourceRange get position => $_getN(32);
  @$pb.TagNumber(52)
  set position(SourceRange value) => $_setField(52, value);
  @$pb.TagNumber(52)
  $core.bool hasPosition() => $_has(32);
  @$pb.TagNumber(52)
  void clearPosition() => $_clearField(52);
  @$pb.TagNumber(52)
  SourceRange ensurePosition() => $_ensure(32);
}

/// Suspension: the sandbox read an undefined name — typically probing whether
/// the parent provides an external function — or, when `object_id` is set, a
/// lazy attribute lookup on a host-backed object. Answer with
/// `ResumeNameLookup`; for attribute lookups an `undefined` answer raises
/// AttributeError (not NameError) inside the sandbox.
class NameLookup extends $pb.GeneratedMessage {
  factory NameLookup({
    $core.String? name,
    Uuid? objectId,
    SourceRange? position,
  }) {
    final result = NameLookup._();
    if (name != null) result.name = name;
    if (objectId != null) result.objectId = objectId;
    if (position != null) result.position = position;
    return result;
  }

  NameLookup._();

  factory NameLookup.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NameLookup()..mergeFromBuffer(data, registry);
  factory NameLookup.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      NameLookup()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'NameLookup',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: NameLookup.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'name')
    ..aOM<Uuid>(2, _omitFieldNames ? '' : 'objectId',
        subBuilder: Uuid.$_createMessage)
    ..aOM<SourceRange>(3, _omitFieldNames ? '' : 'position',
        subBuilder: SourceRange.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NameLookup clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  NameLookup copyWith(void Function(NameLookup) updates) =>
      super.copyWith((message) => updates(message as NameLookup)) as NameLookup;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use NameLookup() / NameLookup.new instead')
  static NameLookup create() => NameLookup._();
  static $pb.GeneratedMessage $_createMessage() => NameLookup._();
  @$core.override
  NameLookup createEmptyInstance() => NameLookup._();
  @$core.pragma('dart2js:noInline')
  static NameLookup getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<NameLookup>(NameLookup.$_createMessage);
  static NameLookup? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get name => $_getSZ(0);
  @$pb.TagNumber(1)
  set name($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasName() => $_has(0);
  @$pb.TagNumber(1)
  void clearName() => $_clearField(1);

  /// Set for attribute lookups on a host-backed object — a class instance, or
  /// a class type (a lazy class attribute): the uuid of the receiver.
  @$pb.TagNumber(2)
  Uuid get objectId => $_getN(1);
  @$pb.TagNumber(2)
  set objectId(Uuid value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasObjectId() => $_has(1);
  @$pb.TagNumber(2)
  void clearObjectId() => $_clearField(2);
  @$pb.TagNumber(2)
  Uuid ensureObjectId() => $_ensure(1);

  /// Where the name (or attribute access) is in the source; absent as on
  /// `FunctionCall`.
  @$pb.TagNumber(3)
  SourceRange get position => $_getN(2);
  @$pb.TagNumber(3)
  set position(SourceRange value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasPosition() => $_has(2);
  @$pb.TagNumber(3)
  void clearPosition() => $_clearField(3);
  @$pb.TagNumber(3)
  SourceRange ensurePosition() => $_ensure(2);
}

/// Suspension: every sandbox task is blocked on external futures previously
/// registered via `ExtFunctionResult.future`. Answer with `ResumeFutures`.
class ResolveFutures extends $pb.GeneratedMessage {
  factory ResolveFutures({
    $core.Iterable<$core.int>? pendingCallIds,
    SourceRange? position,
  }) {
    final result = ResolveFutures._();
    if (pendingCallIds != null) result.pendingCallIds.addAll(pendingCallIds);
    if (position != null) result.position = position;
    return result;
  }

  ResolveFutures._();

  factory ResolveFutures.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResolveFutures()..mergeFromBuffer(data, registry);
  factory ResolveFutures.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ResolveFutures()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ResolveFutures',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ResolveFutures.$_createMessage)
    ..p<$core.int>(
        1, _omitFieldNames ? '' : 'pendingCallIds', $pb.PbFieldType.KU3)
    ..aOM<SourceRange>(2, _omitFieldNames ? '' : 'position',
        subBuilder: SourceRange.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResolveFutures clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ResolveFutures copyWith(void Function(ResolveFutures) updates) =>
      super.copyWith((message) => updates(message as ResolveFutures))
          as ResolveFutures;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ResolveFutures() / ResolveFutures.new instead')
  static ResolveFutures create() => ResolveFutures._();
  static $pb.GeneratedMessage $_createMessage() => ResolveFutures._();
  @$core.override
  ResolveFutures createEmptyInstance() => ResolveFutures._();
  @$core.pragma('dart2js:noInline')
  static ResolveFutures getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ResolveFutures>(
          ResolveFutures.$_createMessage);
  static ResolveFutures? _defaultInstance;

  @$pb.TagNumber(1)
  $pb.PbList<$core.int> get pendingCallIds => $_getList(0);

  /// Where the main task's blocked `await` is in the source; absent as on
  /// `FunctionCall`.
  @$pb.TagNumber(2)
  SourceRange get position => $_getN(1);
  @$pb.TagNumber(2)
  set position(SourceRange value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasPosition() => $_has(1);
  @$pb.TagNumber(2)
  void clearPosition() => $_clearField(2);
  @$pb.TagNumber(2)
  SourceRange ensurePosition() => $_ensure(1);
}

/// Turn end: the snippet completed with this value. The session is ready for
/// the next `Feed`.
class Complete extends $pb.GeneratedMessage {
  factory Complete({
    $core.int? value,
    Arena? values,
  }) {
    final result = Complete._();
    if (value != null) result.value = value;
    if (values != null) result.values = values;
    return result;
  }

  Complete._();

  factory Complete.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Complete()..mergeFromBuffer(data, registry);
  factory Complete.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Complete()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Complete',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Complete.$_createMessage)
    ..aI(1, _omitFieldNames ? '' : 'value', fieldType: $pb.PbFieldType.OU3)
    ..aOM<Arena>(2, _omitFieldNames ? '' : 'values',
        subBuilder: Arena.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Complete clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Complete copyWith(void Function(Complete) updates) =>
      super.copyWith((message) => updates(message as Complete)) as Complete;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Complete() / Complete.new instead')
  static Complete create() => Complete._();
  static $pb.GeneratedMessage $_createMessage() => Complete._();
  @$core.override
  Complete createEmptyInstance() => Complete._();
  @$core.pragma('dart2js:noInline')
  static Complete getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Complete>(Complete.$_createMessage);
  static Complete? _defaultInstance;

  /// Index of the result in `values`.
  @$pb.TagNumber(1)
  $core.int get value => $_getIZ(0);
  @$pb.TagNumber(1)
  set value($core.int value) => $_setUnsignedInt32(0, value);
  @$pb.TagNumber(1)
  $core.bool hasValue() => $_has(0);
  @$pb.TagNumber(1)
  void clearValue() => $_clearField(1);

  @$pb.TagNumber(2)
  Arena get values => $_getN(1);
  @$pb.TagNumber(2)
  set values(Arena value) => $_setField(2, value);
  @$pb.TagNumber(2)
  $core.bool hasValues() => $_has(1);
  @$pb.TagNumber(2)
  void clearValues() => $_clearField(2);
  @$pb.TagNumber(2)
  Arena ensureValues() => $_ensure(1);
}

/// Turn end: the snippet (or request) failed with a Python exception. The
/// session survives — prior globals remain available to later feeds.
class Error extends $pb.GeneratedMessage {
  factory Error({
    RaisedException? exception,
  }) {
    final result = Error._();
    if (exception != null) result.exception = exception;
    return result;
  }

  Error._();

  factory Error.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Error()..mergeFromBuffer(data, registry);
  factory Error.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Error()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Error',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Error.$_createMessage)
    ..aOM<RaisedException>(1, _omitFieldNames ? '' : 'exception',
        subBuilder: RaisedException.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Error clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Error copyWith(void Function(Error) updates) =>
      super.copyWith((message) => updates(message as Error)) as Error;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Error() / Error.new instead')
  static Error create() => Error._();
  static $pb.GeneratedMessage $_createMessage() => Error._();
  @$core.override
  Error createEmptyInstance() => Error._();
  @$core.pragma('dart2js:noInline')
  static Error getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Error>(Error.$_createMessage);
  static Error? _defaultInstance;

  @$pb.TagNumber(1)
  RaisedException get exception => $_getN(0);
  @$pb.TagNumber(1)
  set exception(RaisedException value) => $_setField(1, value);
  @$pb.TagNumber(1)
  $core.bool hasException() => $_has(0);
  @$pb.TagNumber(1)
  void clearException() => $_clearField(1);
  @$pb.TagNumber(1)
  RaisedException ensureException() => $_ensure(0);
}

/// Turn end: type checking rejected the fed snippet (only when the session
/// was created with type_check). The snippet was not executed; the session
/// survives.
class TypingError extends $pb.GeneratedMessage {
  factory TypingError({
    $core.String? diagnostics,
  }) {
    final result = TypingError._();
    if (diagnostics != null) result.diagnostics = diagnostics;
    return result;
  }

  TypingError._();

  factory TypingError.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TypingError()..mergeFromBuffer(data, registry);
  factory TypingError.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TypingError()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TypingError',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: TypingError.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'diagnostics')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypingError clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TypingError copyWith(void Function(TypingError) updates) =>
      super.copyWith((message) => updates(message as TypingError))
          as TypingError;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TypingError() / TypingError.new instead')
  static TypingError create() => TypingError._();
  static $pb.GeneratedMessage $_createMessage() => TypingError._();
  @$core.override
  TypingError createEmptyInstance() => TypingError._();
  @$core.pragma('dart2js:noInline')
  static TypingError getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<TypingError>(
          TypingError.$_createMessage);
  static TypingError? _defaultInstance;

  /// Diagnostics rendered in the session's `TypeCheckFormat`.
  @$pb.TagNumber(1)
  $core.String get diagnostics => $_getSZ(0);
  @$pb.TagNumber(1)
  set diagnostics($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDiagnostics() => $_has(0);
  @$pb.TagNumber(1)
  void clearDiagnostics() => $_clearField(1);
}

class DumpResult extends $pb.GeneratedMessage {
  factory DumpResult({
    $core.List<$core.int>? state,
  }) {
    final result = DumpResult._();
    if (state != null) result.state = state;
    return result;
  }

  DumpResult._();

  factory DumpResult.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DumpResult()..mergeFromBuffer(data, registry);
  factory DumpResult.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      DumpResult()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'DumpResult',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: DumpResult.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'state', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DumpResult clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  DumpResult copyWith(void Function(DumpResult) updates) =>
      super.copyWith((message) => updates(message as DumpResult)) as DumpResult;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use DumpResult() / DumpResult.new instead')
  static DumpResult create() => DumpResult._();
  static $pb.GeneratedMessage $_createMessage() => DumpResult._();
  @$core.override
  DumpResult createEmptyInstance() => DumpResult._();
  @$core.pragma('dart2js:noInline')
  static DumpResult getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<DumpResult>(DumpResult.$_createMessage);
  static DumpResult? _defaultInstance;

  /// Opaque versioned snapshot; see `Dump`.
  @$pb.TagNumber(1)
  $core.List<$core.int> get state => $_getN(0);
  @$pb.TagNumber(1)
  set state($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasState() => $_has(0);
  @$pb.TagNumber(1)
  void clearState() => $_clearField(1);
}

/// Generic acknowledgement for Configure / Load (idle) / Reset / Shutdown.
class Ok extends $pb.GeneratedMessage {
  factory Ok() => Ok._();

  Ok._();

  factory Ok.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Ok()..mergeFromBuffer(data, registry);
  factory Ok.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Ok()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Ok',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: Ok.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Ok clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Ok copyWith(void Function(Ok) updates) =>
      super.copyWith((message) => updates(message as Ok)) as Ok;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Ok() / Ok.new instead')
  static Ok create() => Ok._();
  static $pb.GeneratedMessage $_createMessage() => Ok._();
  @$core.override
  Ok createEmptyInstance() => Ok._();
  @$core.pragma('dart2js:noInline')
  static Ok getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Ok>(Ok.$_createMessage);
  static Ok? _defaultInstance;
}

/// The child hit an unrecoverable error (frame desync, panic, unsupported
/// protocol version) and exits immediately after writing this. A child that
/// exits WITHOUT a FatalError crashed hard (segfault, abort, kill) — parents
/// must treat EOF as a crash.
class FatalError extends $pb.GeneratedMessage {
  factory FatalError({
    $core.String? message,
  }) {
    final result = FatalError._();
    if (message != null) result.message = message;
    return result;
  }

  FatalError._();

  factory FatalError.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FatalError()..mergeFromBuffer(data, registry);
  factory FatalError.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      FatalError()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'FatalError',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: FatalError.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'message')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FatalError clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  FatalError copyWith(void Function(FatalError) updates) =>
      super.copyWith((message) => updates(message as FatalError)) as FatalError;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use FatalError() / FatalError.new instead')
  static FatalError create() => FatalError._();
  static $pb.GeneratedMessage $_createMessage() => FatalError._();
  @$core.override
  FatalError createEmptyInstance() => FatalError._();
  @$core.pragma('dart2js:noInline')
  static FatalError getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<FatalError>(FatalError.$_createMessage);
  static FatalError? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get message => $_getSZ(0);
  @$pb.TagNumber(1)
  set message($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasMessage() => $_has(0);
  @$pb.TagNumber(1)
  void clearMessage() => $_clearField(1);
}

/// Turn end: the serving relay (monty-server, never a child) is shutting down
/// and did NOT run the request it is replying to. Sent only in reply to an
/// in-flight request, so the client is always reading when it arrives.
///
/// Every other server policy action (idle/session/turn timeout, capacity) is
/// just a dropped connection, which the client already classifies as a dead
/// worker — only shutdown needs a message, because only shutdown has state to
/// hand back.
class ShutdownDump extends $pb.GeneratedMessage {
  factory ShutdownDump({
    $core.List<$core.int>? dump,
  }) {
    final result = ShutdownDump._();
    if (dump != null) result.dump = dump;
    return result;
  }

  ShutdownDump._();

  factory ShutdownDump.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ShutdownDump()..mergeFromBuffer(data, registry);
  factory ShutdownDump.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      ShutdownDump()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'ShutdownDump',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'monty.v1'),
      createEmptyInstance: ShutdownDump.$_createMessage)
    ..a<$core.List<$core.int>>(
        1, _omitFieldNames ? '' : 'dump', $pb.PbFieldType.OY)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ShutdownDump clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  ShutdownDump copyWith(void Function(ShutdownDump) updates) =>
      super.copyWith((message) => updates(message as ShutdownDump))
          as ShutdownDump;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use ShutdownDump() / ShutdownDump.new instead')
  static ShutdownDump create() => ShutdownDump._();
  static $pb.GeneratedMessage $_createMessage() => ShutdownDump._();
  @$core.override
  ShutdownDump createEmptyInstance() => ShutdownDump._();
  @$core.pragma('dart2js:noInline')
  static ShutdownDump getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<ShutdownDump>(
          ShutdownDump.$_createMessage);
  static ShutdownDump? _defaultInstance;

  /// What `Load` restores the session from on a fresh connection: the ID a
  /// relay with session storage parked it under. Absent when there is nothing
  /// to load: no session yet, an ephemeral session, a relay without storage, or
  /// a park that failed.
  @$pb.TagNumber(1)
  $core.List<$core.int> get dump => $_getN(0);
  @$pb.TagNumber(1)
  set dump($core.List<$core.int> value) => $_setBytes(0, value);
  @$pb.TagNumber(1)
  $core.bool hasDump() => $_has(0);
  @$pb.TagNumber(1)
  void clearDump() => $_clearField(1);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
