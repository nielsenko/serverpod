/* AUTOMATICALLY GENERATED CODE DO NOT MODIFY */
/*   To generate run: "serverpod generate"    */

// ignore_for_file: implementation_imports
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: non_constant_identifier_names
// ignore_for_file: public_member_api_docs
// ignore_for_file: type_literal_in_constant_pattern
// ignore_for_file: use_super_parameters

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:serverpod/serverpod.dart' as _i1;
import 'package:serverpod/protocol.dart' as _i2;
import 'package:serverpod_auth_backwards_compatibility_server/serverpod_auth_backwards_compatibility_server.dart'
    as _i3;
import 'package:serverpod_auth_email_server/serverpod_auth_email_server.dart'
    as _i4;
import 'package:serverpod_auth_migration_server/serverpod_auth_migration_server.dart'
    as _i5;
import 'package:serverpod_auth_profile_server/serverpod_auth_profile_server.dart'
    as _i6;
import 'package:serverpod_auth_server/serverpod_auth_server.dart' as _i7;
import 'package:serverpod_auth_email_account_server/serverpod_auth_email_account_server.dart'
    as _i8;
import 'package:serverpod_auth_user_server/serverpod_auth_user_server.dart'
    as _i9;
import 'package:serverpod_auth_session_server/serverpod_auth_session_server.dart'
    as _i10;

class Protocol extends _i1.SerializationManagerServer {
  Protocol._();

  factory Protocol() => _instance;

  static final Protocol _instance = Protocol._();

  static final List<_i2.TableDefinition> targetTableDefinitions = [
    ..._i3.Protocol.targetTableDefinitions,
    ..._i4.Protocol.targetTableDefinitions,
    ..._i5.Protocol.targetTableDefinitions,
    ..._i6.Protocol.targetTableDefinitions,
    ..._i7.Protocol.targetTableDefinitions,
    ..._i8.Protocol.targetTableDefinitions,
    ..._i9.Protocol.targetTableDefinitions,
    ..._i10.Protocol.targetTableDefinitions,
    ..._i2.Protocol.targetTableDefinitions,
  ];

  @override
  T deserialize<T>(
    dynamic data, [
    Type? t,
  ]) {
    t ??= T;
    if (t == Set<String>) {
      return (data as List).map((e) => deserialize<String>(e)).toSet() as T;
    }
    try {
      return _i3.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i4.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i5.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i6.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i7.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i8.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i9.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i10.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    try {
      return _i2.Protocol().deserialize<T>(data, t);
    } on _i1.DeserializationTypeNotFoundException catch (_) {}
    return super.deserialize<T>(data, t);
  }

  @override
  String? getClassNameForObject(Object? data) {
    String? className = super.getClassNameForObject(data);
    if (className != null) return className;
    className = _i2.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod.$className';
    }
    className = _i3.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_backwards_compatibility.$className';
    }
    className = _i4.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_email.$className';
    }
    className = _i5.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_migration.$className';
    }
    className = _i6.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_profile.$className';
    }
    className = _i7.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth.$className';
    }
    className = _i8.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_email_account.$className';
    }
    className = _i9.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_user.$className';
    }
    className = _i10.Protocol().getClassNameForObject(data);
    if (className != null) {
      return 'serverpod_auth_session.$className';
    }
    return null;
  }

  @override
  dynamic deserializeByClassName(Map<String, dynamic> data) {
    var dataClassName = data['className'];
    if (dataClassName is! String) {
      return super.deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod.')) {
      data['className'] = dataClassName.substring(10);
      return _i2.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_backwards_compatibility.')) {
      data['className'] = dataClassName.substring(39);
      return _i3.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_email.')) {
      data['className'] = dataClassName.substring(21);
      return _i4.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_migration.')) {
      data['className'] = dataClassName.substring(25);
      return _i5.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_profile.')) {
      data['className'] = dataClassName.substring(23);
      return _i6.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth.')) {
      data['className'] = dataClassName.substring(15);
      return _i7.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_email_account.')) {
      data['className'] = dataClassName.substring(29);
      return _i8.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_user.')) {
      data['className'] = dataClassName.substring(20);
      return _i9.Protocol().deserializeByClassName(data);
    }
    if (dataClassName.startsWith('serverpod_auth_session.')) {
      data['className'] = dataClassName.substring(23);
      return _i10.Protocol().deserializeByClassName(data);
    }
    return super.deserializeByClassName(data);
  }

  @override
  _i1.Table? getTableForType(Type t) {
    {
      var table = _i3.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i4.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i5.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i6.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i7.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i8.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i9.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i10.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    {
      var table = _i2.Protocol().getTableForType(t);
      if (table != null) {
        return table;
      }
    }
    return null;
  }

  @override
  List<_i2.TableDefinition> getTargetTableDefinitions() =>
      targetTableDefinitions;

  @override
  String getModuleName() => 'serverpod_new_auth_test';
}
