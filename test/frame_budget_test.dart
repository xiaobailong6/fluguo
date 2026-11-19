import 'package:duanju_app/ui/widgets/perf_hud.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('HUD 根据屏幕刷新率计算帧预算，无效刷新率回退 60 Hz', () {
    expect(frameBudgetMicros(60), 16667);
    expect(frameBudgetMicros(90), 11111);
    expect(frameBudgetMicros(120), 8333);
    for (final hz in [0.0, -1.0, double.nan, double.infinity]) {
      expect(frameBudgetMicros(hz), 16667);
    }
  });
}
