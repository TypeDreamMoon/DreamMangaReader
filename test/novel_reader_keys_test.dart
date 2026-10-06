import 'package:dream_manga_reader/core/platform/reader_keys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('dream_manga_reader/reader_keys');

  late List<bool> activations;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    ReaderKeys.debugReset();
    ReaderKeys.debugSupportedOverride = true;
    activations = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'setVolumeKeyPaging') {
        activations.add(call.arguments as bool);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    ReaderKeys.debugReset();
  });

  Future<void> pressVolume(String key) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('volumeKey', key),
      ),
      (_) {},
    );
  }

  test('volume keys go to the newest reader and fall back to the previous one',
      () async {
    final manga = <int>[];
    final novel = <int>[];

    final mangaToken = ReaderKeys.setHandler(manga.add);
    await ReaderKeys.setActive(true);
    await pressVolume('down');
    expect(manga, [1]);

    final novelToken = ReaderKeys.setHandler(novel.add);
    await ReaderKeys.setActive(true);
    await pressVolume('up');
    expect(novel, [-1]);
    expect(manga, [1]);

    // 上层阅读器退出:音量键必须还给底下那个,而不是全局关掉。
    await ReaderKeys.setActive(false);
    ReaderKeys.clearHandler(novelToken);
    await pressVolume('down');
    expect(manga, [1, 1]);
    expect(novel, [-1]);
    expect(activations, [true]);

    await ReaderKeys.setActive(false);
    ReaderKeys.clearHandler(mangaToken);
    await pressVolume('down');
    expect(manga, [1, 1]);
    expect(activations, [true, false]);
  });

  test('clearing an unknown token leaves the active handler alone', () async {
    final turns = <int>[];
    ReaderKeys.setHandler(turns.add);
    ReaderKeys.clearHandler(Object());
    await pressVolume('down');
    expect(turns, [1]);
  });

  test('setActive stays quiet while another reader still holds it', () async {
    await ReaderKeys.setActive(true);
    await ReaderKeys.setActive(true);
    await ReaderKeys.setActive(false);
    expect(activations, [true]);
    await ReaderKeys.setActive(false);
    expect(activations, [true, false]);
    // 多余的关闭不会再发一次消息。
    await ReaderKeys.setActive(false);
    expect(activations, [true, false]);
  });
}
