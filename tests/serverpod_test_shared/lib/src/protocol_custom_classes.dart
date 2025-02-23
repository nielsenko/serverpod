import 'package:serverpod_serialization/serverpod_serialization.dart';

class ProtocolCustomClass implements SerializableModel, ProtocolSerialization {
  final String? value;
  final String? serverOnlyValue;

  ProtocolCustomClass({
    required this.value,
    required this.serverOnlyValue,
  });

  factory ProtocolCustomClass.fromJson(
    Map<String, dynamic> json,
  ) {
    return ProtocolCustomClass(
      value: json["value"] as String?,
      serverOnlyValue: json["serverOnlyValue"] as String?,
    );
  }

  @override
  Map<String, dynamic> toJsonForProtocol() {
    return {
      "value": value,
    };
  }

  @override
  Map<String, dynamic> toJson() {
    return {
      "value": value,
      "serverOnlyValue": serverOnlyValue,
    };
  }
}
