import 'package:flutter_test/flutter_test.dart';
import 'package:medito/constants/http/http_constants.dart';

void main() {
  test('Intronauts ignores old Facebook configuration', () {
    expect(facebookAppId, isEmpty);
    expect(facebookClientToken, isEmpty);
  });
}
