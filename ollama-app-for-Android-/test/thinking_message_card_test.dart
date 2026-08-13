import 'package:flutter/material.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/main.dart';

void main() {
  const assistant = types.User(id: 'assistant');

  types.CustomMessage thinkingMessage(String text, {bool active = true}) {
    return types.CustomMessage(
        author: assistant,
        id: 'thinking-message',
        metadata: {
          'kind': 'thinking',
          'thinking': text,
          'isThinking': active,
        });
  }

  Widget app(types.CustomMessage message) {
    return MaterialApp(
        home: Scaffold(
            body: ThinkingMessageCard(
                key: const ValueKey('thinking-message'),
                message: message,
                messageWidth: 320)));
  }

  testWidgets('thinking stays collapsible while streaming updates arrive',
      (tester) async {
    await tester.pumpWidget(app(thinkingMessage('Primer fragmento')));

    expect(find.text('Thinking'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Primer fragmento'), findsNothing);

    await tester.tap(
        find.byKey(const ValueKey('thinking-toggle-thinking-message')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Primer fragmento'), findsOneWidget);

    await tester.pumpWidget(
        app(thinkingMessage('Primer fragmento y segundo fragmento')));
    await tester.pump();
    expect(find.text('Primer fragmento y segundo fragmento'), findsOneWidget);

    await tester.tap(
        find.byKey(const ValueKey('thinking-toggle-thinking-message')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(find.text('Primer fragmento y segundo fragmento'), findsNothing);
  });
}
