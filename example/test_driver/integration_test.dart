import 'package:integration_test/integration_test_driver.dart';

// 性能长测通过 flutter drive --profile 运行；只在验收时启用。
Future<void> main() => integrationDriver(timeout: const Duration(minutes: 30));
