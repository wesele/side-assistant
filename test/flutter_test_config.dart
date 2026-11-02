import 'dart:async';
import 'package:side_assistant/services/service_registrations.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  ServiceRegistrations.ensureInitialized();
  await testMain();
}
