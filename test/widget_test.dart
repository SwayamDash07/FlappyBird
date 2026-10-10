import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flappy_bird/main.dart';

void main() {
  testWidgets('shows the game start screen', (tester) async {
    await tester.pumpWidget(const FlappyBirdApp());
    expect(find.byType(CustomPaint), findsOneWidget);
    final canvas = tester.widget<CustomPaint>(find.byType(CustomPaint));
    final renderer = canvas.painter! as GameRenderer;
    expect(renderer.phase, Phase.ready);
    expect(canvas.size.height, greaterThan(0));
    expect(
      renderer.worldWidth,
      closeTo(canvas.size.width / (canvas.size.height / 512), .01),
    );
  });

  testWidgets('tap starts the game', (tester) async {
    await tester.pumpWidget(const FlappyBirdApp());
    await tester.tapAt(const Offset(400, 300));
    await tester.pump(const Duration(milliseconds: 100));
    final canvas = tester.widget<CustomPaint>(find.byType(CustomPaint));
    expect((canvas.painter! as GameRenderer).phase, Phase.playing);
  });

  testWidgets('end screen paints after resize at desktop and narrow ratios', (
    tester,
  ) async {
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(const FlappyBirdApp());

    final sizes = [
      const Size(1280, 720),
      const Size(1920, 1080),
      const Size(2560, 1080),
      const Size(360, 800),
    ];
    expect(EndScreenLayout.cardDesignHeight % 8, 0);
    final scoreKeys = [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.digit3,
      LogicalKeyboardKey.digit4,
    ];
    for (final size in sizes) {
      tester.view.physicalSize = size;
      await tester.pump();
      for (final key in scoreKeys) {
        await tester.sendKeyEvent(key);
        await tester.pump();
        final paint = tester.widget<CustomPaint>(find.byType(CustomPaint));
        final renderer = paint.painter! as GameRenderer;
        expect(renderer.phase, Phase.card);
        final layout = EndScreenLayout.forViewport(
          renderer.worldWidth,
          512,
          paint.size.height / 512,
        );
        expect(layout.cardRect.left, greaterThanOrEqualTo(0));
        expect(layout.cardRect.right, lessThanOrEqualTo(renderer.worldWidth));
        expect(layout.cardRect.bottom, lessThanOrEqualTo(512));
        expect(layout.buttonRect.top, greaterThan(layout.cardRect.top));
        expect(layout.buttonRect.bottom, lessThan(layout.cardRect.bottom));
        expect(tester.takeException(), isNull);
      }
    }

    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump(const Duration(milliseconds: 100));
    tester.view.physicalSize = const Size(1920, 1080);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.takeException(), isNull);
  });
}
