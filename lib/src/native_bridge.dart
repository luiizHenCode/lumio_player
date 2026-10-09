import 'package:flutter/services.dart';

/// Wire protocol shared by Kotlin and Swift. One event subscription per process.
class LumioNativeBridge {
  static const methods = MethodChannel('lumio_player/methods');
  static final Stream<Map<String, dynamic>> events =
      const EventChannel('lumio_player/events').receiveBroadcastStream().map(
        (event) => Map<String, dynamic>.from(event as Map),
      );

  Future<Map<String, dynamic>> create() async => Map<String, dynamic>.from(
    (await methods.invokeMethod<Map<Object?, Object?>>('create'))!,
  );
  Future<Object?> invoke(
    String method,
    int id, [
    Map<String, Object?> arguments = const {},
  ]) => methods.invokeMethod<Object?>(method, {'id': id, ...arguments});
}
