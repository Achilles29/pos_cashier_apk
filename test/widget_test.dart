import 'package:flutter_test/flutter_test.dart';
import 'package:pos_cashier_apk/src/app.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders POS app', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const PosCashierApp());
    await tester.pumpAndSettle();

    expect(find.text('Pengaturan POS'), findsOneWidget);
  });
}
