import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:simple_gallery_viewer/core/gallery_store.dart';
import 'package:simple_gallery_viewer/core/repository.dart';
import 'package:simple_gallery_viewer/main.dart';

/// 基础冒烟测试：应用能启动，并在没有图集时显示空状态引导。
///
/// 这里不触碰真实文件系统：只验证界面骨架与空状态文案，
/// 涉及 zip 读取的逻辑由 `archive_reader_test.dart` 覆盖。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() {
    SharedPreferences.setMockInitialValues({});

    // 组件测试跑在 fake-async 时钟下，Isolate.run 的 Future 永远不会完成，
    // 会让 pumpAndSettle 一直等下去。索引解析本身有独立测试覆盖，
    // 这里关掉 isolate，只验证界面骨架。
    GalleryStore.useIsolate = false;

    // path_provider 在 widget 测试里没有实现，若不接管，封面缓存初始化会卡住，
    // 整个应用停在加载动画上。这里让它返回一个真实的临时目录。
    tmp = Directory.systemTemp.createTempSync('sgv_widget_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => tmp.path,
        );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  testWidgets('应用启动后显示图集空状态', (tester) async {
    await tester.pumpWidget(const SimpleGalleryViewerApp());
    // 等待仓库异步加载完成
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('简易图集查看器'), findsNothing); // 标题在 AppBar 上，不是独立文本
    expect(find.textContaining('图集'), findsWidgets);
    expect(find.text('还没有图集'), findsOneWidget);
  });

  testWidgets('底部三个入口都在', (tester) async {
    await tester.pumpWidget(const SimpleGalleryViewerApp());
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(find.text('收藏夹'), findsWidgets);
    expect(find.text('图集'), findsWidgets);
    expect(find.text('设置'), findsWidgets);
  });

  group('首次启动的免责声明', () {
    testWidgets('未同意时启动应弹出确认，且不能靠返回键跳过', (tester) async {
      await tester.pumpWidget(const SimpleGalleryViewerApp());
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('使用前请阅读'), findsOneWidget, reason: '首次启动应弹出免责声明');
      expect(find.text('同意并继续'), findsOneWidget);
      expect(find.text('不同意'), findsOneWidget);
      // 完整条款正文应在弹窗里（抽查几个关键段落标题）
      expect(find.textContaining('① 对设备与文件的影响'), findsOneWidget);
      expect(find.textContaining('② 导入内容的合法性'), findsOneWidget);
      expect(find.textContaining('③ 翻译功能与第三方服务'), findsOneWidget);
      expect(find.textContaining('⑤ AI 生成声明'), findsOneWidget);
      expect(find.textContaining('⑥ 开源与许可'), findsOneWidget);
    });

    testWidgets('点「同意并继续」后写入标记，重启不再弹', (tester) async {
      await tester.pumpWidget(const SimpleGalleryViewerApp());
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('使用前请阅读'), findsOneWidget);

      await tester.tap(find.text('同意并继续'));
      await tester.pumpAndSettle(const Duration(seconds: 2));

      // 弹窗消失，进入主界面（底部导航出现）
      expect(find.text('使用前请阅读'), findsNothing);
      expect(find.text('设置'), findsWidgets);

      // 标记已持久化
      expect(GalleryRepository.instance.disclaimerAccepted, isTrue);

      // 模拟"重启"：重新构建整棵树，不应再弹
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SimpleGalleryViewerApp());
      await tester.pumpAndSettle(const Duration(seconds: 2));
      expect(find.text('使用前请阅读'), findsNothing, reason: '已同意过就不该再打扰');
    });

    testWidgets('已同意过的用户启动时直接进入主界面', (tester) async {
      SharedPreferences.setMockInitialValues({
        'disclaimer.accepted.v1': true,
        'settings.v1': '{}',
      });
      // 让仓库重新读取 prefs（它缓存了 SharedPreferences 实例）
      GalleryRepository.instance.resetForTesting();
      await GalleryRepository.instance.load();

      await tester.pumpWidget(const SimpleGalleryViewerApp());
      await tester.pumpAndSettle(const Duration(seconds: 2));

      expect(find.text('使用前请阅读'), findsNothing);
      expect(find.text('还没有图集'), findsOneWidget);
    });
  });
}
