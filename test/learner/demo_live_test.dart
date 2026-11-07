import 'package:flutter_test/flutter_test.dart';
import 'package:soussight/learner/demo_live.dart';
import 'package:soussight/live/live_types.dart';

void main() {
  test('rehearsal UI echoes the current host step after advancement', () async {
    final transport = DemoLiveTransport();
    await transport.connect(systemInstruction: 'currentStepId: prep');
    final first = transport.events
        .where((event) => event is LiveToolCall)
        .first;
    await transport.sendText('Show the initial workspace.');
    expect(((await first) as LiveToolCall).arguments['stepId'], 'prep');
    final next = transport.events.where((event) => event is LiveToolCall).first;
    await transport.sendText('currentStepId: mash. Update the workspace.');
    expect(((await next) as LiveToolCall).arguments['stepId'], 'mash');
    await transport.close();
  });
}
