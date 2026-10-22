import 'package:toshiba_flashair_wifi_viewer/core/version_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseVersion accepts releases and rejects other labels', () {
    expect(parseVersion('v1.2.3').toString(), '1.2.3');
    expect(parseVersion('1.2.3+4').toString(), '1.2.3');
    expect(parseVersion('v1.2.3-beta'), isNull);
    expect(parseVersion('latest'), isNull);
    expect(parseVersion(''), isNull);
  });

  test('compareVersions compares each numeric component', () {
    expect(
      compareVersions(parseVersion('1.0.9')!, parseVersion('1.0.10')!),
      lessThan(0),
    );
    expect(
      compareVersions(parseVersion('1.2.0')!, parseVersion('1.1.99')!),
      greaterThan(0),
    );
    expect(compareVersions(parseVersion('1.2.0')!, parseVersion('v1.2.0')!), 0);
  });

  test('isUpdateDue uses a 24 hour interval', () {
    final now = DateTime(2026, 10, 22, 12);
    expect(isUpdateDue(null, now), isTrue);
    expect(isUpdateDue(now.subtract(const Duration(hours: 23)), now), isFalse);
    expect(isUpdateDue(now.subtract(const Duration(hours: 25)), now), isTrue);
  });
}
