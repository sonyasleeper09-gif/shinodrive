import 'package:flutter_test/flutter_test.dart';
import 'package:shinodrive/main.dart';

void main() {
  test('fb formats bytes', () {
    expect(fb(0), '0 B');
    expect(fb(1024), '1.0 KB');
  });
}
