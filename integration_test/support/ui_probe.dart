import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:plezy/media/media_item.dart';
import 'package:plezy/widgets/media_card.dart';
import 'package:plezy/widgets/music/track_row.dart';

/// Says what is on screen and what can be tapped.
///
/// Driving this app on a device meant guessing at finders: a tap that changed
/// nothing was indistinguishable between the finder matching the wrong widget,
/// the widget being off-screen, and the tap landing but doing nothing. Several
/// hours went into that distinction one guess at a time.
///
/// A test that reports what it can see turns each of those into a different
/// message, and — more usefully — lets it pick a target that is actually
/// hittable rather than the first one a predicate happened to match.

/// Visible text, in tree order, capped so a failure message stays readable.
String visibleText(WidgetTester tester, {int limit = 40}) {
  final texts = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data ?? '')
      .where((value) => value.trim().isNotEmpty)
      .take(limit)
      .toList();
  return texts.isEmpty ? '(no text on screen)' : texts.join(' | ');
}

/// One thing the test could tap.
class Tappable {
  const Tappable({required this.finder, required this.kind, required this.label, required this.rect});

  final Finder finder;

  /// `album`, `track`, … for a media card; the widget type otherwise.
  final String kind;
  final String label;
  final Rect rect;

  /// Whether a tap would actually reach it.
  ///
  /// On screen and a real size is not enough: a card under the app bar, the
  /// nav bar or the mini player is visible and still un-hittable, and
  /// `tap()` then derives an offset that hit-tests to something else entirely.
  /// That failure reads exactly like the product bug — nothing plays — so it
  /// has to be excluded here rather than diagnosed afterwards.
  bool hittableIn(Size screen) {
    const chromeTop = 140.0;
    const chromeBottom = 180.0;
    return rect.width > 8 &&
        rect.height > 8 &&
        rect.top > chromeTop &&
        rect.bottom < screen.height - chromeBottom &&
        rect.left >= 0 &&
        rect.right <= screen.width;
  }

  @override
  String toString() =>
      '$kind "$label" at ${rect.left.toStringAsFixed(0)},${rect.top.toStringAsFixed(0)}'
      ' ${rect.width.toStringAsFixed(0)}x${rect.height.toStringAsFixed(0)}';
}

/// Every media card and track row currently mounted, with what it is and where.
List<Tappable> tappables(WidgetTester tester) {
  final found = <Tappable>[];

  for (var i = 0; i < tester.widgetList<MediaCard>(find.byType(MediaCard)).length; i++) {
    final finder = find.byType(MediaCard).at(i);
    final widget = tester.widget<MediaCard>(finder);
    final item = widget.item;
    found.add(
      Tappable(
        finder: finder,
        kind: item is MediaItem ? item.kind.name : 'card',
        label: item is MediaItem ? (item.displayTitle) : '?',
        rect: _rectOf(tester, finder),
      ),
    );
  }

  for (var i = 0; i < tester.widgetList<TrackRow>(find.byType(TrackRow)).length; i++) {
    final finder = find.byType(TrackRow).at(i);
    found.add(Tappable(finder: finder, kind: 'trackRow', label: '#$i', rect: _rectOf(tester, finder)));
  }

  return found;
}

Rect _rectOf(WidgetTester tester, Finder finder) {
  try {
    return tester.getRect(finder);
  } catch (_) {
    return Rect.zero;
  }
}

/// A one-line description of everything tappable, for a failure message.
String describeTappables(WidgetTester tester) {
  final all = tappables(tester);
  if (all.isEmpty) return '(nothing tappable found)';
  return all.map((t) => t.toString()).join(' ; ');
}

/// Scroll [target] into view and tap it, failing with what was on screen.
///
/// `warnIfMissed: false` is deliberately *not* used: a tap that misses is the
/// failure this exists to surface, not something to swallow.
Future<void> tapTarget(WidgetTester tester, Tappable target, {required String what}) async {
  await tester.ensureVisible(target.finder);
  await tester.pump(const Duration(milliseconds: 400));
  // Checked rather than warned about: a tap that misses produces silence,
  // which is indistinguishable from the product failing to play. Reading that
  // as the bug is the mistake this file exists to prevent.
  final box = tester.getRect(target.finder);
  final hit = HitTestResult();
  WidgetsBinding.instance.hitTestInView(hit, box.center, tester.view.viewId);
  final reached = hit.path.any((entry) => identical(entry.target, tester.renderObject(target.finder)));
  expect(reached, isTrue, reason: 'wanted to tap $what at ${box.center} but something else is there: $target');
  await tester.tap(target.finder);
  await tester.pump(const Duration(seconds: 2));
}
