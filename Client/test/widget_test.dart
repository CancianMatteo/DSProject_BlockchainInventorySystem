import 'package:flutter_test/flutter_test.dart';
import 'package:distr_bis/main.dart';

void main() {
  testWidgets('Unauthenticated users see the login screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());

    expect(find.text('Bentornato'), findsOneWidget);
    expect(find.text('ACCEDI'), findsOneWidget);
  });
}
