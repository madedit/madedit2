import 'package:flutter_test/flutter_test.dart';
import 'package:madedit2/main.dart';
import 'package:madedit2/editor/large_file_view.dart';
import 'package:madedit2/src/rust/frb_generated.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => await RustLib.init());

  testWidgets('App launches with the large-file editor', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.byType(LargeFileEditorPage), findsOneWidget);
  });
}
