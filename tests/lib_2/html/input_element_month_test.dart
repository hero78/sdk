import 'dart:html';

import 'package:expect/minitest.dart';

main() {
  test('supported', () {
    expect(MonthInputElement.supported, true);
  });
}
