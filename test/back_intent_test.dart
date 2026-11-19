import 'package:duanju_app/ui/back_intent.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('出栈后500毫秒内拦重复返回，超过窗口立即恢复', (tester) async {
    BackIntent.recordPop();
    expect(BackIntent.quietSincePop, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
    expect(BackIntent.quietSincePop, isFalse);
    await tester.pump(const Duration(milliseconds: 1));
    expect(BackIntent.quietSincePop, isTrue);
    BackIntent.recordPop();
    expect(BackIntent.quietSincePop, isFalse);
    await tester.pump(const Duration(milliseconds: 501));
    expect(BackIntent.quietSincePop, isTrue);
  });
}
