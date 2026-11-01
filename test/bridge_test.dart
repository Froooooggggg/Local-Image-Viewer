import 'package:flutter_test/flutter_test.dart';
import 'package:simple_gallery_viewer/core/bridge/bridge_config.dart';
import 'package:simple_gallery_viewer/core/bridge/bridge_client.dart';
import 'package:simple_gallery_viewer/core/bridge/translation_job.dart';
import 'package:simple_gallery_viewer/core/bridge/translation_service.dart';
import 'package:simple_gallery_viewer/core/bridge/translation_task.dart';

/// 这些测试只覆盖纯逻辑（解析、命名、JSON 往返）——
/// 真正跟服务端打交道的行为靠真机联调验证，见 docs/ 里的技术文档。
void main() {
  group('配对信息解析', () {
    test('完整 JSON', () {
      final p = BridgePairing.tryParse(
        '{"api":1,"port":8099,"token":"abc123def456abc123def456",'
        '"hosts":["192.168.1.5","10.0.0.2"]}',
      );
      expect(p, isNotNull);
      expect(p!.api, 1);
      expect(p.port, 8099);
      expect(p.token, 'abc123def456abc123def456');
      expect(p.hosts, ['192.168.1.5', '10.0.0.2']);
    });

    test('缺端口时用默认端口', () {
      final p = BridgePairing.tryParse('{"token":"abc123def456abc123def456"}');
      expect(p!.port, 8098);
      expect(p.hosts, isEmpty);
    });

    test('端口越界时退回默认端口', () {
      final p = BridgePairing.tryParse(
        '{"port":70000,"token":"abc123def456abc123def456"}',
      );
      expect(p!.port, 8098);
    });

    test('只粘贴了 token 也认', () {
      final p = BridgePairing.tryParse('  abc123def456abc123def456  ');
      expect(p!.token, 'abc123def456abc123def456');
      expect(p.port, 8098);
    });

    test('剪贴板里的普通文字不会被当成配对码', () {
      expect(BridgePairing.tryParse('你好世界'), isNull);
      expect(BridgePairing.tryParse(''), isNull);
      // 太短，不像 token
      expect(BridgePairing.tryParse('abc123'), isNull);
    });

    test('JSON 里没有 token 就判为无效', () {
      expect(BridgePairing.tryParse('{"api":1,"port":8098}'), isNull);
    });
  });

  group('配置持久化', () {
    test('JSON 往返保留全部字段', () {
      const cfg = BridgeConfig(
        host: '192.168.1.5',
        port: 8099,
        token: 'tok123',
        source: 'ja',
        target: 'zh',
        maxSide: 2048,
        minChars: 2,
        outputTreeUri: 'content://tree/abc',
        outputTreeName: '下载',
      );
      final back = BridgeConfig.fromJson(cfg.toJson());
      expect(back.host, '192.168.1.5');
      expect(back.port, 8099);
      expect(back.token, 'tok123');
      expect(back.maxSide, 2048);
      expect(back.minChars, 2);
      expect(back.outputTreeUri, 'content://tree/abc');
      expect(back.outputTreeName, '下载');
    });

    test('损坏/缺字段时回落到默认值', () {
      final back = BridgeConfig.fromJson(const {'host': '', 'port': 'oops'});
      expect(back.host, '127.0.0.1');
      expect(back.port, 8098);
      expect(back.hasToken, isFalse);
      expect(back.source, 'ja');
    });

    test('配对只覆盖 host/port/token，不动语言与目录', () {
      const cfg = BridgeConfig(
        token: 'old',
        source: 'en',
        target: 'ko',
        outputTreeName: '相册',
      );
      final merged = cfg.mergedWith(
        const BridgePairing(
          api: 1,
          port: 8099,
          token: 'new',
          hosts: ['127.0.0.1'],
        ),
      );
      expect(merged.token, 'new');
      expect(merged.port, 8099);
      expect(merged.source, 'en');
      expect(merged.target, 'ko');
      expect(merged.outputTreeName, '相册');
    });

    // 1.3.10 起语义反转：显式配对总是采用新 host。否则换电脑/换 IP 之后
    // 无论怎么重新粘贴配对 JSON 都还连着旧地址（远程 PC 场景就是这么卡住的）。
    test('显式配对总是采用配对信息里的 host', () {
      const cfg = BridgeConfig(host: '192.168.1.9');
      final merged = cfg.mergedWith(
        const BridgePairing(
          api: 1,
          port: 8098,
          token: 'new',
          hosts: ['192.168.1.20'],
        ),
      );
      expect(merged.host, '192.168.1.20');
    });

    test('配对信息没有 hosts 时保留原 host', () {
      const cfg = BridgeConfig(host: '192.168.1.9');
      final merged = cfg.mergedWith(
        const BridgePairing(api: 1, port: 8098, token: 'new', hosts: []),
      );
      expect(merged.host, '192.168.1.9');
    });
  });

  group('输出命名', () {
    test('目录名是「原名<AITranslate>」，重复翻译落回同一目录', () {
      expect(TranslationJob.translatedDirName('海贼王'), '海贼王<AITranslate>');
      // 同一个图集翻两次必须落到同一处，才能续传/追加。
      expect(
        TranslationJob.translatedDirName('海贼王'),
        TranslationJob.translatedDirName('海贼王'),
      );
    });

    test('清洗路径分隔符与保留字符', () {
      final name = TranslationJob.translatedDirName(r'a/b\c:d*e?f"g<h>i|j');
      expect(name, isNot(contains('/')));
      expect(name, isNot(contains(r'\')));
      expect(name, isNot(contains(':')));
      expect(name, isNot(contains('*')));
      expect(name, isNot(contains('?')));
      expect(name, isNot(contains('"')));
      expect(name, isNot(contains('|')));
      // 尖括号是后缀的一部分，允许存在；但标题里的尖括号被清洗掉，不会歧义。
      expect(name, endsWith('<AITranslate>'));
      expect('<'.allMatches(name).length, 1);
    });

    test('超长标题截到 40 字', () {
      final name = TranslationJob.sanitizeTitle('长' * 100);
      expect(name.length, 40);
    });

    test('空标题兜底', () {
      expect(TranslationJob.sanitizeTitle('  '), '未命名');
      expect(TranslationJob.sanitizeTitle('---'), '---');
    });

    test('页文件名从 1 开始、补零到 4 位', () {
      expect(TranslationJob.pageFileName(0), 'page-0001.jpg');
      expect(TranslationJob.pageFileName(41), 'page-0042.jpg');
    });

    test('动图沿用原扩展名，避免被当成静态图', () {
      expect(TranslationJob.pageFileName(0, gif: true), 'page-0001.gif');
    });
  });

  group('翻译任务记录', () {
    test('JSON 往返保留进度与关联的翻译图集 id', () {
      final task = TranslationTask(
        galleryId: 'g1',
        galleryTitle: '海贼王',
        source: 'ja',
        target: 'zh',
        outputTreeUri: 'content://tree/root',
        outputDirUri: 'content://tree/x',
        outputDirName: '海贼王<AITranslate>',
        outputGalleryId: 'g2',
        state: TranslationTaskState.paused,
        total: 120,
        done: 40,
        failed: 1,
        skipped: 5,
        copiedGif: 2,
      );
      final back = TranslationTask.fromJson(task.toJson());
      expect(back.galleryTitle, '海贼王');
      expect(back.outputGalleryId, 'g2');
      expect(back.state, TranslationTaskState.paused);
      expect(back.done, 40);
      expect(back.skipped, 5);
      expect(back.copiedGif, 2);
      expect(back.processed, 46); // 40 + 1 + 5
    });

    test('坏数据不炸：缺字段时回落到默认值', () {
      final back = TranslationTask.fromJson({'galleryId': 'g9'});
      expect(back.total, 0);
      expect(back.state, TranslationTaskState.stopped);
      // 终止/暂停过的任务仍然"可以继续"（isActive），只是没在跑。
      expect(back.isActive, isTrue);
      expect(back.isRunning, isFalse);
    });
  });

  group('单页结果 JSON 往返', () {
    test('成功页', () {
      const page = TranslationPageResult(
        index: 3,
        sourceName: '003.jpg',
        output: 'page-0004.jpg',
        uri: 'content://doc/page-0004.jpg',
        width: 900,
        height: 1200,
        lines: 8,
        translated: 7,
        failed: 1,
        elapsedMs: 2500,
      );
      final back = TranslationPageResult.fromJson(page.toJson());
      expect(back.index, 3);
      expect(back.sourceName, '003.jpg');
      expect(back.output, 'page-0004.jpg');
      // 1.3.7 起阅读器直接按 uri 读译文，必须能往返。
      expect(back.uri, 'content://doc/page-0004.jpg');
      expect(back.width, 900);
      expect(back.lines, 8);
      expect(back.ok, isTrue);
      expect(back.error, isNull);
    });

    test('旧 manifest 没有 uri 时按空串处理', () {
      final back = TranslationPageResult.fromJson({
        'index': 0,
        'output': 'page-0001.jpg',
      });
      expect(back.uri, '');
    });

    test('失败页保留错误原因', () {
      const page = TranslationPageResult(
        index: 5,
        sourceName: '005.jpg',
        output: '',
        error: '服务端忙（409），重试 3 次仍失败',
      );
      final back = TranslationPageResult.fromJson(page.toJson());
      expect(back.ok, isFalse);
      expect(back.error, contains('409'));
    });

    test('renderMissing 也写进 manifest', () {
      const page = TranslationPageResult(
        index: 0,
        sourceName: 'a.jpg',
        output: 'page-0001.jpg',
        renderMissing: true,
      );
      expect(page.toJson()['renderMissing'], isTrue);
    });
  });

  group('错误分类', () {
    test('401 不再重试', () {
      final e = BridgeException(
        status: 401,
        code: 'unauthorized',
        message: 'x',
      );
      expect(e.isUnauthorized, isTrue);
      expect(e.isRetryable, isFalse);
    });

    test('409 与 5xx 可重试', () {
      expect(
        BridgeException(status: 409, code: 'busy', message: 'x').isRetryable,
        isTrue,
      );
      expect(
        BridgeException(
          status: 500,
          code: 'bridge_error',
          message: 'x',
        ).isRetryable,
        isTrue,
      );
      expect(
        BridgeException(status: 408, code: 'timeout', message: 'x').isRetryable,
        isTrue,
      );
    });

    test('413 太大不重试', () {
      final e = BridgeException(
        status: 413,
        code: 'image_too_large',
        message: 'x',
      );
      expect(e.isTooLarge, isTrue);
      expect(e.isRetryable, isFalse);
    });

    test('410 渲染图过期可识别', () {
      expect(
        BridgeException(
          status: 410,
          code: 'render_gone',
          message: 'x',
        ).isRenderGone,
        isTrue,
      );
    });

    // 1.3.9 起 404 也算过期：服务端渲染缓存是 LRU，被挤掉时回的是 404。
    test('404 也算渲染图过期', () {
      expect(
        BridgeException(
          status: 404,
          code: 'not_found',
          message: 'x',
        ).isRenderGone,
        isTrue,
      );
    });
  });

  group('服务版本门槛', () {    BridgeHealth health({
      int api = 1,
      String app = '同传互译',
      String version = '0.8.0-beta',
    }) => BridgeHealth(
      api: api,
      ok: true,
      app: app,
      version: version,
      backend: 'llama',
      model: 'm',
      visionReady: true,
      translateReady: true,
      bridgeEnabled: true,
      port: 8098,
    );

    test('手机端 0.8.0 放行', () {
      expect(TranslationService.versionGate(health()), isNull);
    });

    test('手机端 0.7.x 被挡下', () {
      expect(
        TranslationService.versionGate(health(version: '0.7.9')),
        contains('版本太旧'),
      );
    });

    // PC 服务版本线是 0.1.0，不是「同传互译」那条，不能被 0.8.0 卡住。
    test('PC 服务 0.1.0 放行', () {
      expect(
        TranslationService.versionGate(
          health(app: 'PC 整页翻译', version: '0.1.0'),
        ),
        isNull,
      );
    });

    test('api 不是 1 一律拒绝', () {
      expect(
        TranslationService.versionGate(
          health(api: 2, app: 'PC 整页翻译', version: '0.1.0'),
        ),
        contains('api=1'),
      );
    });
  });

  // `.nomedia` 只往译文目录里放，认错目录会往用户自己的文件夹里塞文件。
  group('译文目录识别', () {
    test('正常命名', () {
      expect(
        TranslationJob.isTranslatedDirName('Foo<AITranslate>'),
        isTrue,
      );
    });

    test('exFAT / SD 卡被改写成下划线后仍认得出', () {
      expect(
        TranslationJob.isTranslatedDirName('Foo_AITranslate_'),
        isTrue,
      );
    });

    test('普通目录不认', () {
      expect(TranslationJob.isTranslatedDirName('Foo'), isFalse);
      expect(TranslationJob.isTranslatedDirName('Pictures'), isFalse);
      expect(TranslationJob.isTranslatedDirName('翻译'), isFalse);
    });
  });

  // 「无有效内容」既没报错也没成品，必须和真失败区分开：
  // 计数、任务卡统计、阅读器提示都靠 noText 这一位。
  group('无有效内容（no_text）', () {
    test('noText 页不算成功也不算失败', () {
      const p = TranslationPageResult(
        index: 3,
        sourceName: 'p4.jpg',
        output: 'page-0004.jpg',
        noText: true,
      );
      expect(p.noText, isTrue);
      expect(p.error, isNull);
      expect(p.ok, isFalse);
    });

    test('JSON 往返保留 noText，老 manifest 按 false 处理', () {
      const p = TranslationPageResult(
        index: 0,
        sourceName: 'a.jpg',
        output: 'page-0001.jpg',
        noText: true,
      );
      final back = TranslationPageResult.fromJson(p.toJson());
      expect(back.noText, isTrue);
      expect(back.ok, isFalse);

      final old = TranslationPageResult.fromJson(<String, dynamic>{
        'index': 1,
        'output': 'page-0002.jpg',
        'uri': 'content://doc/x',
      });
      expect(old.noText, isFalse);
      expect(old.ok, isTrue);
    });

    test('任务统计把无有效内容算进已处理、不混进失败', () {
      final t = TranslationTask(
        galleryId: 'g',
        galleryTitle: 't',
        source: 'ja',
        target: 'zh',
        outputTreeUri: 'content://tree/1',
        outputDirUri: 'content://doc/2',
        outputDirName: 't_AITranslate_',
        done: 5,
        failed: 1,
        noText: 3,
        skipped: 2,
      );
      expect(t.processed, 11);
      final back = TranslationTask.fromJson(t.toJson());
      expect(back.noText, 3);
      expect(back.failed, 1);
      expect(back.processed, 11);
    });
  });
}
