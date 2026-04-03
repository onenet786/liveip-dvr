import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ipcamera_viewer/main.dart';

void main() {
  testWidgets('camera watcher shell renders', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const IPCameraWatcherApp());
    await tester.pump();

    expect(find.text('IP Camera Viewer and Face Alert System'), findsOneWidget);
    expect(find.text('Take Picture From IP Cam'), findsOneWidget);
    expect(find.text('Select Face and Save Alert Target'), findsOneWidget);
    expect(find.text('Start Monitoring'), findsOneWidget);
  });
}
