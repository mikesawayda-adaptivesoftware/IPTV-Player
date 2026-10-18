import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/platform/picture_in_picture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.adaptivesoftware.iptvplayer/pip');
  final configured = <Map<Object?, Object?>>[];

  setUp(() {
    configured.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'configure') {
        configured.add(call.arguments as Map<Object?, Object?>);
      }
      return null;
    });
  });

  Future<void> fromHost(String method, [Object? arguments]) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
  }

  test('a claim starts disabled and follows its player', () async {
    final claim = PictureInPicture.claim();
    expect(configured.last['enabled'], false);

    claim.update(enabled: true, videoSize: const Size(1920, 1080));
    expect(configured.last['enabled'], true);
    expect(configured.last['width'], 1920);
    expect(configured.last['height'], 1080);

    // Pausing keeps the last known shape.
    claim.update(enabled: false);
    expect(configured.last['enabled'], false);
    expect(configured.last['width'], 1920);

    claim.release();
    expect(configured.last['enabled'], false);
  });

  test('the newest claim speaks, and releasing it hands back', () async {
    final under = PictureInPicture.claim()..update(enabled: true);
    final over = PictureInPicture.claim();
    expect(configured.last['enabled'], false);

    over.release();
    expect(configured.last['enabled'], true);

    under.release();
    expect(configured.last['enabled'], false);
  });

  test('an unchanged update does not call the host', () async {
    final claim = PictureInPicture.claim()..update(enabled: true);
    final calls = configured.length;
    claim.update(enabled: true);
    expect(configured.length, calls);
    claim.release();
  });

  test('the host drives active, and dismissal reaches the top claim',
      () async {
    var dismissed = 0;
    final claim = PictureInPicture.claim(onDismissed: () => dismissed++);

    await fromHost('modeChanged', true);
    expect(PictureInPicture.active.value, true);

    await fromHost('dismissed');
    expect(PictureInPicture.active.value, false);
    expect(dismissed, 1);

    // Expanding back to the app is not a dismissal.
    await fromHost('modeChanged', true);
    await fromHost('modeChanged', false);
    expect(dismissed, 1);

    claim.release();
  });
}
