import 'package:flutter_test/flutter_test.dart';

import '../scripts/check_live_lines.dart' as checks;

void main() {
  test('直播多线路去重、清晰度隔离、签名与选择策略', checks.checkLiveLineParsers);
}
