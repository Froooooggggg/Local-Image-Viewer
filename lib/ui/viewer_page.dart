import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../core/archive_reader.dart';
import '../core/bridge/translation_service.dart';
import '../core/byte_source.dart';
import '../core/image_pan_bounds.dart';
import '../core/models.dart';
import '../core/repository.dart';
import '../core/saf_channel.dart';
import 'progress_dialog.dart';

/// 查看器日志。统一前缀便于用 logcat 过滤。
void _log(String msg) {
  // ignore: avoid_print
  print('[SGV-查看器] $msg');
}

/// 内置图片查看器。
///
/// 内存策略（对应「2 GB 以内」的目标）：
///  * 只在内存中保留当前张附近的一个窗口，窗口大小由设置的预加载张数决定；
///  * 解码时按屏幕尺寸降采样，绝不把整张原图解成位图；
///  * 超出卸载距离的图片主动 `dispose()` 并释放引用；
///  * 退出页面时释放全部已解码图片。
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    required this.gallery,
    this.restoreProgress = true,
    this.initialIndex,
    this.startTranslated = false,
  });

  final Gallery gallery;

  /// 是否恢复上次的观看进度。
  ///
  /// 默认恢复；从"换位预览"之类需要从头看的场合可传 false。
  final bool restoreProgress;

  /// 直接定位到这一页（0 基）。传了就不恢复进度：调用方明确要看这一页。
  ///
  /// 列表里点「已翻译」角标时用它跳到第一页有译文的页。
  final int? initialIndex;

  /// 打开时先显示译文（默认先看原图）。
  ///
  /// 只有点「已翻译」角标进来才带 true：用户点它是为了看译文；
  /// 从列表平铺点开一本图集时，默认仍应看原图。
  final bool startTranslated;

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _repo = GalleryRepository.instance;
  late final List<GalleryImage> _images = widget.gallery.images;
  late final ReadingMode _mode = _repo.settings.readingMode;

  /// zip 会话：索引与文件句柄在整个阅读过程中只建立一次。
  ///
  /// 早先的实现每加载一张图都要重新解析一次中央目录并重开文件，
  /// 1000 张图就是 1000 次索引 —— 纯属浪费。这里改为复用。
  _ZipSession? _zip;

  /// 一个紧凑的解码缓存：序号 -> 已解码图像。
  late final _ImageWindow _window;

  ScrollController? _scrollController;
  int _index = 0;

  /// 顶部/底部控件是否可见。点击画面中间切换。
  bool _uiVisible = true;
  String? _error;

  /// 阅读时临时亮度；null 表示沿用全局设置。
  ///
  /// **只在本页生效，退出阅读器即失效**。之前 onChangeEnd 会把滑块值写回
  /// `settings.brightness`（全局设置），导致"在查看器里调暗一次，全局亮度就
  /// 被永久改掉，而只能回设置页改回来"。
  double? _overrideBrightness;

  /// 每张图连续读取失败的次数（用于"3 次失败后询问"）。
  final Map<int, int> _failCount = {};

  /// 用户在本图集的本次浏览中选了"否"，不再弹出恢复询问。
  /// 退出阅读器后重置，下次浏览仍会询问。
  bool _recoveryDeclined = false;

  /// 阈值：同一张图连续失败几次后询问是否验证文件。
  static const _failureThreshold = 3;

  /// 音量键事件订阅（由 Android 侧原生拦截后上报）。
  StreamSubscription<dynamic>? _volumeSub;

  /// 当前是否正在播放动图。
  bool _playing = false;

  /// 动图当前显示到第几帧。
  int _frameIndex = 0;

  /// 播放循环的取消令牌：自增即让旧的循环自行退出。
  int _playToken = 0;

  /// 当前这张是否正在送去翻译。只影响按钮外观，不挡任何手势。
  bool _translating = false;

  Timer? _frameTimer;

  /// 已经尝试过自动播放的那一张（-1 表示还没有）。
  ///
  /// 只尝试一次：失败后若在 onChanged 里反复重试，会不停解码、白耗资源。
  int _autoPlayTried = -1;

  double get _brightness => _overrideBrightness ?? _repo.settings.brightness;

  @override
  void initState() {
    super.initState();
    // 只对**将要打开的这一本**重排图片：排序设置随时可能改过。
    // 之前是在设置变更时重排全部图集并写盘，600+ 本会明显卡顿。
    _repo.resortOne(widget.gallery);

    // 默认先看原图；从「已翻译」角标进来时才先看译文。
    _showTranslated = widget.startTranslated;

    // **恢复观看进度**：接着上次读到的那一张继续。
    // 必须在 resortOne 之后取值 —— 排序可能改变图片顺序，
    // 存的是"第几张"而不是某张图的身份，因此这里取的是排序后的位置。
    // 调用方指定了页（点角标）时不恢复进度：他就是要看那一页。
    final wanted = widget.initialIndex;
    if (wanted != null) {
      if (_images.isNotEmpty) {
        _index = wanted < 0
            ? 0
            : (wanted >= _images.length ? _images.length - 1 : wanted);
      }
    } else if (widget.restoreProgress) {
      final saved = widget.gallery.lastIndex;
      if (saved != null && saved > 0 && saved < _images.length) {
        _index = saved;
      }
    }

    // 直接进来（没有翻页动作）时也要查一次首屏有没有译文。
    if (_images.isNotEmpty) unawaited(_probeTranslated(_index));

    _window = _ImageWindow(
      images: _images,
      loader: _loadBytes,
      preload: _repo.settings.preloadCount,
      unloadDistance: _repo.settings.unloadDistance,
      onChanged: () {
        if (mounted) setState(() {});
        // 动图解码完成后（此时才知道它是动图）尝试自动播放。
        unawaited(_maybeAutoPlay());
      },
      // 读取/解码失败时上报，由页面累计次数并决定是否发起恢复询问。
      onFailure: (i) {
        if (mounted) _recordFailure(i);
      },
    );

    if (_mode == ReadingMode.paged) {
      // 翻页模式自己实现（无需控制器）；首帧就按恢复后的下标渲染。
    } else {
      _scrollController = ScrollController(
        // 滚动模式：让列表直接定位到上次读到的那一张。
        // 用 initialScrollOffset 而不是建好后再 jumpTo —— 后者会先渲染第 0 张
        // 再跳走，出现一次明显的位置闪动。
        initialScrollOffset: _index * _estimatedItemExtent,
      )..addListener(_onScroll);
    }
    unawaited(_window.update(_index));
    _listenVolumeKeys();
    // 切后台时暂停动图：继续跑既耗电又白白占着内存。
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _playing) {
      _stopPlayback(releaseFrames: true);
    }
  }

  /// 需求：进入阅读器后，音量键改为「+ 向上翻页 / − 向下翻页」。
  ///
  /// Android 侧在 Activity 中拦截音量键并通过 EventChannel 上报；订阅期间
  /// 系统音量面板不会弹出。离开本页时取消订阅，音量键恢复默认行为。
  void _listenVolumeKeys() {
    const channel = EventChannel('simple_gallery_viewer/volume_keys');
    _volumeSub = channel.receiveBroadcastStream().listen(
      (event) {
        if (!mounted) return;
        if (event == 'up') {
          _goTo(_index - 1);
        } else if (event == 'down') {
          _goTo(_index + 1);
        }
      },
      onError: (_) {
        // 在不支持该通道的环境（如桌面端测试）静默忽略。
      },
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _volumeSub?.cancel();
    _frameTimer?.cancel();
    _playToken++;
    _zip?.dispose();
    _scrollController?.dispose();
    // 退出即释放：不留下任何已解码位图。
    _window.disposeAll();

    // **保存观看进度**：只在退出时写一次盘。
    // 翻页是高频操作，若每翻一页都写索引文件会明显拖慢阅读。
    // 用 unawaited：dispose 不能等待异步，写盘失败也只是一次进度丢失。
    unawaited(_repo.markProgress(widget.gallery, _index));

    super.dispose();
  }

  /// 按需取出第 [index] 张图片的原始字节。
  ///
  /// 压缩包来源复用同一个字节来源与已解析的中央目录索引；
  /// 文件夹来源直接读该图片对应的 `content://` 文档。
  Future<Uint8List?> _loadBytes(int index) async {
    final img = _images[index];
    if (img.entryIndex < 0) {
      // 文件夹来源：分块读取，避免一次性申请很大的数组。
      return GalleryRepository.withSource(img.path, _readAllChunked);
    }

    final session = await _zipSession();
    return session.read(img.entryIndex);
  }

  /// 分块读完一个来源。
  ///
  /// 为什么不一次读很大：原生侧的 `readBytes` 会按请求长度一次性分配
  /// `ByteArray`（例如 64 MB），大图很容易直接触发 Java 侧的分配失败 ——
  /// 那会以 JNI 异常的形式让引擎 abort（崩溃信息 jni_util.cc 正是如此）。
  /// 分块申请把单次分配压到 8 MB 以内，显著降低这个风险。
  /// 实现见 [readAllChunked]（批量翻译共用同一份，避免两处逻辑漂移）。
  static Future<Uint8List> _readAllChunked(ByteSource source) =>
      readAllChunked(source);

  Future<_ZipSession> _zipSession() async {
    final existing = _zip;
    if (existing != null) return existing;
    final created = await _ZipSession.open(widget.gallery.sourcePath);
    _zip = created;
    return created;
  }

  /// 跨页动画的最大距离。
  ///
  /// 超过这个距离就**直接跳过去、不做动画**。原因是 PageView 做跨页动画时会
  /// 沿途构建并绘制每一页，而每页都会触发一次按需解码 —— 一次跳几百张就会
  /// 瞬间堆起几百个解码任务，直接把应用卡死/闪退。
  /// 直接跳页只会构建目标页，开销恒定。
  static const _maxAnimatedJump = 12;

  void _goTo(int index) {
    if (index < 0 || index >= _images.length) return;

    if (_mode == ReadingMode.paged) {
      // 翻页已由本页自己实现（不再使用 PageView），直接切换下标即可。
      // 拖动进度条跳页属于"直接跳"，不需要跟手位移。
      if (index == _index) return;
      _onIndexChanged(index);
    } else {
      // 滚动模式：按估算的外推位置跳转，避免测量所有子项。
      final controller = _scrollController;
      if (controller == null || !controller.hasClients) return;
      final target = (index * _estimatedItemExtent).clamp(
        0.0,
        controller.position.maxScrollExtent,
      );
      final current = controller.offset;
      final scaled =
          (target - current).abs() > _estimatedItemExtent * _maxAnimatedJump;
      if (scaled) {
        controller.jumpTo(target);
      } else {
        controller.animateTo(
          target,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    }
  }

  double get _estimatedItemExtent {
    final h = MediaQuery.of(context).size.height;
    return h * 0.72;
  }

  void _onIndexChanged(int index) {
    if (index == _index) return;
    // 翻页立即停止播放并释放其余帧：动图不预加载，也不在后台继续跑，
    // 否则翻过几张动图就会累积大量帧内存、还持续耗电。
    if (_playing) _stopPlayback(releaseFrames: true);
    // 换页时复原缩放：新的一页应以原大小开始，
    // 否则下一页会带着上一页的放大倍数出现（画面莫名被裁切）。
    _resetZoom();
    setState(() {
      _index = index;
      // 默认仍显示译文：用户是来看"翻译后的这一页"的，
      // 需要原图时再点顶栏的「原图」按钮。
      _showTranslated = true;
    });
    unawaited(_probeTranslated(index));
    unawaited(
      _window.update(index).then((_) {
        // 解码完成后才知道是不是动图，因此这里和 onChanged 都要尝试。
        unawaited(_maybeAutoPlay());
      }),
    );
  }

  /// 本页译文（null = 没有译文，或还没读到）。
  ///
  /// 数据源是翻译目录里的文件（索引记在 TranslationSetStore），因此
  /// **退出重进后译文仍在**：之前只把译文放在内存里，一退出就回到原图。
  final Map<int, Uint8List> _translated = {};

  /// 已经查过的页：避免每次翻回来都去读一次磁盘。
  final Set<int> _translatedProbed = {};

  /// 当前是否显示译文（仅当 [_translated] 里有本页时才生效）。
  ///
  /// 初始值由 [ViewerPage.startTranslated] 决定：点角标进来先看译文，
  /// 从列表点开则先看原图，顶栏的对照按钮随时可切。
  bool _showTranslated = false;

  /// 查一次本页有没有译文。
  ///
  /// 判据是 `hasTranslation`（译文页数 > 0），而不是「我自己是翻译图集」。
  Future<void> _probeTranslated(int index) async {
    if (_translatedProbed.contains(index)) return;
    _translatedProbed.add(index);
    if (!widget.gallery.hasTranslation) return;
    final bytes = await TranslationService.instance.loadTranslatedPage(
      widget.gallery,
      index,
    );
    if (bytes == null || !mounted) return;
    setState(() => _translated[index] = bytes);
  }

  /// 滚动模式下根据滚动位置推断当前看到第几张，用于更新序号与进度条。
  void _onScroll() {
    final controller = _scrollController;
    if (controller == null || !controller.hasClients) return;
    final extent = _estimatedItemExtent;
    if (extent <= 0) return;
    final visible = (controller.offset / extent).round();
    if (visible != _index && visible >= 0 && visible < _images.length) {
      _onIndexChanged(visible);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    // 需求：音量键 + 上一页（向上翻），− 下一页（向下翻）。
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeUp) {
      _goTo(_index - 1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.audioVolumeDown) {
      _goTo(_index + 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final dim = (1.0 - _brightness).clamp(0.0, 0.9);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: Stack(
          children: [
            Positioned.fill(child: _buildContent()),
            if (dim > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(color: Colors.black.withValues(alpha: dim)),
                ),
              ),
            if (_uiVisible) ..._buildOverlays(),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_images.isEmpty) {
      return const Center(child: Text('这个图集里没有图片'));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, textAlign: TextAlign.center),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // 记录视口尺寸：手势处理需要它来算平移边界。
        _viewportSize = size;
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          onPointerCancel: _onPointerUp,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 单击唤起/隐藏界面；双击缩放；长按不做处理（避免吃掉拖动）。
            onTap: () {
              // 拖动过就不算点击：否则滑完顺手把界面藏起来会很意外。
              if (_gestureEndedAsTap) _toggleUi();
            },
            onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
            onDoubleTap: () => _handleDoubleTap(
              _doubleTapPos ?? Offset(size.width / 2, size.height / 2),
              size,
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: _mode == ReadingMode.paged
                      ? _buildPaged(size)
                      : _buildScrolling(),
                ),
                // 边缘待翻页提示条（需求量：在将要翻页的那一侧显示）。
                if (_edgeFlipArmed && _mode == ReadingMode.paged)
                  _edgeFlipHint(),
              ],
            ),
          ),
        );
      },
    );
  }

  Offset? _doubleTapPos;

  /// 边缘待翻页提示：一条**贴壁的渐隐蓝条**，没有文字。
  ///
  /// 需求：
  ///   * 改成整屏边缘的渐隐贴壁蓝条（去掉文字）
  ///   * **往哪一页翻就贴在哪一侧** —— 翻下一页贴右边缘，回上一页贴左边缘
  ///
  /// 用渐变从边缘向外淡出、不做成实心块，避免遮挡画面内容。
  Widget _edgeFlipHint() {
    // _edgeDragDx > 0 表示手指向右拖 → 将翻到**上一页** → 贴左边缘。
    final toPrevious = _edgeDragDx > 0;
    const barWidth = 26.0;

    return Positioned(
      top: 0,
      bottom: 0,
      left: toPrevious ? 0 : null,
      right: toPrevious ? null : 0,
      child: IgnorePointer(
        child: SizedBox(
          width: barWidth,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: toPrevious
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                end: toPrevious ? Alignment.centerRight : Alignment.centerLeft,
                colors: const [
                  Color(0xCC4C8DF6), // 贴边最亮
                  Color(0x664C8DF6),
                  Color(0x004C8DF6), // 向外完全淡出
                ],
                stops: [0.0, 0.45, 1.0],
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x594C8DF6),
                  blurRadius: 10,
                  spreadRadius: -2,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 翻页模式：**自己实现**，不用 `PageView`。
  ///
  /// 为什么不用 PageView：
  ///   * 需求要求"单指滑动至少 15 像素才开始触发翻页"，而 PageView 在几像素时
  ///     就会抢走手势，无法满足；
  ///   * 放大后的平移与翻页会互相抢手势（实测放大后误翻页、图片乱移）。
  ///
  /// 自己实现后两件事都变简单了：
  ///   * 拖动距离完全可控（阈值、跟手位移都由状态机给）；
  ///   * 翻页与缩放是两套互不相干的状态，不会再抢。
  ///
  /// 跟手位移的取值说明：`_pageDragDx` 就是"页面整体左移多少"。
  /// 向左拖动（dx<0）时页面左移、右页从右侧进来；向右拖动时反之。
  Widget _buildPaged(Size size) {
    final w = size.width;
    final cur = _index;
    final prev = cur - 1;
    final next = cur + 1;

    Widget pageAt(int i, {required bool interactive}) {
      return Positioned.fill(
        child: _ZoomableImage(
          key: ValueKey('p$i'),
          image: _window.get(i),
          loading: !_window.has(i),
          error: _window.errorOf(i),
          // 只有当前页应用缩放矩阵。
          transform: interactive ? _imageTransform : Matrix4.identity(),
          alternative: _translated[i],
          showAlternative: interactive && _showTranslated,
        ),
      );
    }

    final layered = Stack(
      children: [
        if (prev >= 0)
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(-w, 0),
              child: _ZoomableImage(
                key: ValueKey('p$prev'),
                image: _window.get(prev),
                loading: !_window.has(prev),
                error: _window.errorOf(prev),
                transform: Matrix4.identity(),
                alternative: _translated[prev],
                showAlternative: _showTranslated,
              ),
            ),
          ),
        pageAt(cur, interactive: true),
        if (next < _images.length)
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(w, 0),
              child: _ZoomableImage(
                key: ValueKey('p$next'),
                image: _window.get(next),
                loading: !_window.has(next),
                error: _window.errorOf(next),
                transform: Matrix4.identity(),
                alternative: _translated[next],
                showAlternative: _showTranslated,
              ),
            ),
          ),
      ],
    );

    // 不拖动时不套 Transform：避免每帧都做一次无谓的图层变换。
    if (_pageDragDx == 0) return layered;
    return Transform.translate(offset: Offset(_pageDragDx, 0), child: layered);
  }

  Widget _buildScrolling() {
    return ListView.builder(
      controller: _scrollController,
      // 不预建屏幕外的项，把解码量控制在窗口内。
      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
      itemCount: _images.length,
      itemBuilder: (context, i) => SizedBox(
        height: _estimatedItemExtent,
        child: _ZoomableImage(
          key: ValueKey('s$i'),
          image: _window.get(i),
          loading: !_window.has(i),
          error: _window.errorOf(i),
          transform: i == _index ? _imageTransform : Matrix4.identity(),
          alternative: _translated[i],
          showAlternative: i == _index && _showTranslated,
        ),
      ),
    );
  }

  void _toggleUi() => setState(() => _uiVisible = !_uiVisible);

  /// 当前图片的缩放倍数（1.0 = 原大小）。
  double _imageScale = 1.0;

  /// 平移量（缩放状态下的单指拖动）。
  Offset _panTotal = Offset.zero;

  /// 缩放/平移矩阵。由页面统一维护，图片组件只负责呈现。
  Matrix4 _imageTransform = Matrix4.identity();

  /// 亮度条是否展开。默认收起，点按钮才唤出（需求）。
  bool _brightnessOpen = false;

  bool get _imageZoomed => _imageScale > 1.001;

  // ------------------------------------------------------------ 手势状态机
  //
  // 翻页、平移、缩放三者互相冲突，必须由一个状态机决定当前谁生效。
  // 交给 PageView / InteractiveViewer 各自处理必然互抢（实测放大后会误翻页）。
  //
  //   单指按下 → 候选：翻页 或（已放大时）平移
  //     移动 ≥ _pageTriggerDistance → 未放大：累积水平位移，松开超阈值才翻页
  //                                   已放大：平移；到边缘且继续同向滑
  //                                           够 _edgeFlipDistance → 翻页
  //     第二指落下 → 立即中止翻页候选，切换为缩放
  //
  // 距离都用**物理像素**判断，避免不同屏幕密度下手感不一致。

  /// 单指至少移动这么多物理像素，才可能触发翻页（需求：15 像素）。
  static const double _pageTriggerDistance = 15;

  /// 放大后滑到边缘、再继续同向滑动这么多像素，**松手时**才翻页。
  ///
  /// 需求：拖到头需要再拉 70 像素才唤起提示条；唤起后要往回拉到
  /// 提示条出现时的位置（即累积量归零）才取消。
  /// 阈值刻意比翻页触发距离大，让"我要翻页"需要明确的手势。
  static const double _edgeFlipDistance = 70;

  /// 移动超过这个距离就不再算"点击"。
  static const double _tapSlop = 15;

  static const double _maxScale = 8.0;

  final Map<int, Offset> _pointers = {};
  Offset? _lastPointerPos;
  double _pathLength = 0;
  int? _primaryPointer;
  bool _gestureIsPinch = false;
  double _startSpan = 0;
  double _startScale = 1;
  double _pageDragDx = 0;

  /// 翻页位移动画进行中：期间忽略手势，避免与动画抢状态。
  bool _pageAnimating = false;
  double _edgeDragDx = 0;
  bool _edgeFlipArmed = false;

  /// 正在播放边缘翻页的滑动动画。期间忽略手势，避免与动画抢状态。
  bool _flipAnimating = false;
  bool _gestureEndedAsTap = false;

  bool get _multiTouch => _pointers.length >= 2;

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.position;
    _lastPointerPos = e.position;

    if (_pointers.length == 1) {
      _primaryPointer = e.pointer;
      _pathLength = 0;
      _gestureIsPinch = false;
      _gestureEndedAsTap = false;
      // **不要重置 _panTotal**：它就是当前的平移位置，一归零图片会跳回正中央。
      // 之前长按拖动画面跳到中间就是这个原因。平移只在复原缩放或翻页时清零。
      _pageDragDx = 0;
      _edgeDragDx = 0;
      _edgeFlipArmed = false;
      return;
    }

    // 出现第二指：立刻中止翻页候选，转为缩放
    //（需求：途中检测到双指自动开始缩放）。
    if (!_gestureIsPinch) {
      _gestureIsPinch = true;
      _pageDragDx = 0;
      _edgeDragDx = 0;
      _edgeFlipArmed = false;
      _startSpan = _currentSpan();
      _startScale = _imageScale;
      if (mounted) setState(() {});
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    // 位移动画期间不接受手势，避免与动画抢状态。
    if (_pageAnimating || _flipAnimating) return;

    final prev = _lastPointerPos;
    if (prev != null) _pathLength += (e.position - prev).distance;
    _lastPointerPos = e.position;
    _pointers[e.pointer] = e.position;

    if (_multiTouch) {
      _updatePinch();
      return;
    }
    if (e.pointer != _primaryPointer) return;

    if (_imageZoomed) {
      _updatePan(e.position, e.delta);
    } else if (_pathLength >= _pageTriggerDistance) {
      // 未放大：达到触发距离后才累积水平位移用于翻页。
      if (e.delta.dx != 0 && mounted) {
        setState(() => _pageDragDx += e.delta.dx);
      }
    }
  }

  void _onPointerUp(PointerEvent e) {
    final wasPrimary = e.pointer == _primaryPointer;
    _pointers.remove(e.pointer);
    _lastPointerPos = _pointers.isEmpty ? null : _pointers.values.last;

    if (wasPrimary) {
      // 仅"几乎没有移动"才算点击：拖动过就不该顺手把界面藏起来。
      _gestureEndedAsTap = _pathLength < _tapSlop;
    }

    if (_pointers.isEmpty) {
      _finishGesture();
    } else if (_pointers.length == 1) {
      // 从双指回到单指：以剩下的手指重新开始平移，
      // 否则跨度突变会让画面跳一下。
      _startSpan = _currentSpan();
      _startScale = _imageScale;
    }
  }

  double _currentSpan() {
    if (_pointers.length < 2) return 0;
    final pts = _pointers.values.toList();
    return (pts[0] - pts[1]).distance;
  }

  void _updatePinch() {
    if (_pointers.length < 2 || _startSpan <= 0) return;
    final span = _currentSpan();
    if (span <= 0) return;
    final target = (_startScale * span / _startSpan).clamp(1.0, _maxScale);
    _imageScale = target;
    // 缩放后原来的平移量可能已经越界，先夹一次再重绘。
    _panTotal = _clampPan(_panTotal);
    _rebuildTransform();
  }

  /// 当前视口尺寸（由 build 记录，供手势处理计算边界）。
  Size _viewportSize = Size.zero;

  /// 把平移量夹在"图片边缘不越过画面"的范围内。
  ///
  /// 边界计算见 [ImagePanBounds]（已抽成纯函数并带测试）。
  ///
  /// **必须夹住**：否则平移量无限增长，"是否已到边缘"永远成立，
  /// 任何单指拖动都会被误判成"在边缘继续滑"而直接翻页。
  Offset _clampPan(Offset pan) {
    final img = _window.decoded(_index)?.display;
    if (img == null) return Offset.zero;
    return ImagePanBounds.clamp(
      pan: pan,
      imageWidth: img.width.toDouble(),
      imageHeight: img.height.toDouble(),
      viewport: _viewportSize,
      scale: _imageScale,
    );
  }

  void _rebuildTransform() {
    if (!mounted) return;
    setState(() {
      // **顺序很重要**：先 translate 再 scale，平移量才不会被缩放放大。
      // 反过来写的话，2× 时拖 100px 画面会走 200px，手感完全不对。
      _imageTransform = Matrix4.identity()
        ..translateByDouble(_panTotal.dx, _panTotal.dy, 0, 1)
        ..scaleByDouble(_imageScale, _imageScale, 1, 1);
    });
  }

  void _updatePan(Offset pos, Offset delta) {
    // 翻页动画进行中不接受平移，避免与动画抢状态。
    if (_flipAnimating) return;

    final prev = _panTotal;
    final next = _clampPan(prev + delta);
    final stuck = (next.dx - prev.dx).abs() < 0.01;

    // 位移被夹住 → 已经贴在某一侧边缘，继续拖动的量就是"越界拖动量"。
    //
    // 只判断"被夹住"即可，不需要额外看方向：
    //   * 按住不动时 delta≈0，累积量不变，本来就不会误触发；
    //   * 往回拉时 delta 与累积量反号，累加即自然抵消，正是需要的行为。
    //
    // 早先版本因为"符号翻转就归零"，累积量不断掉回阈值以下，
    // 提示条会抖动、甚至贴错边（用户反馈"还是有问题"即指此）。
    if (stuck) {
      // 累积"越界拖动量的净值"：继续外推则累加，往回拉则自然抵消。
      //
      // **不要因为符号翻转就归零**：那样累积量会不断掉回阈值以下，
      // 提示条就会抖动甚至消失（原先的实现正是这样，导致"贴着的一侧"也错乱）。
      // 只有真正离开边缘（下面的分支）才清空。
      _edgeDragDx += delta.dx;

      // 需求：拖到头要再拉 _edgeFlipDistance 像素才显示提示条；
      // 往回拉到阈值以内即取消。
      // 越过阈值只表示"松手后会翻页"，**不在此刻翻页**。
      final nextArmed = _edgeDragDx.abs() >= _edgeFlipDistance;
      if (nextArmed != _edgeFlipArmed && mounted) {
        setState(() => _edgeFlipArmed = nextArmed);
      } else {
        _edgeFlipArmed = nextArmed;
        // 方向（即贴哪一侧）会随净值符号变化，需要重绘提示条。
        if (nextArmed && mounted) setState(() {});
      }
      return;
    }

    // 已经真的离开了边缘 → 撤销待翻页状态与提示条。
    if (_edgeFlipArmed || _edgeDragDx != 0) {
      _edgeFlipArmed = false;
      _edgeDragDx = 0;
      if (mounted) setState(() {});
    }

    _panTotal = next;
    _rebuildTransform();
  }

  /// 从"放大状态下的边缘拖动"触发翻页。
  ///
  /// 直接用滑动动画切到目标页（自己实现的翻页，不再依赖 PageView）。
  /// 缩放由 [_onIndexChanged] 统一复原，新的一页以原大小出现。
  void _flipFromEdge(int delta) {
    final dest = _index + delta;
    if (dest < 0 || dest >= _images.length) {
      // 已是第一/最后一页：撤销，避免反复触发。
      _edgeFlipArmed = false;
      _edgeDragDx = 0;
      if (mounted) setState(() {});
      return;
    }
    _edgeFlipArmed = false;
    _edgeDragDx = 0;
    _flipAnimating = true;
    _goToAnimated(dest).whenComplete(() {
      if (mounted) _flipAnimating = false;
    });
  }

  /// 手势结束：决定是翻页、回弹，还是保持原状。
  void _finishGesture() {
    if (_gestureIsPinch) {
      _gestureIsPinch = false;
      return;
    }
    if (_edgeFlipArmed) {
      // 需求量：边缘处滑够 30px 后**松手**才翻页。
      // 期间手指挪回去的话 _edgeFlipArmed 已被撤销，走不到这里。
      final dir = _edgeDragDx > 0 ? -1 : 1;
      _edgeFlipArmed = false;
      _edgeDragDx = 0;
      if (mounted) setState(() {});
      _flipFromEdge(dir);
      return;
    }
    // 松开时若仍在边缘累积但未达阈值 → 清掉累积量，不翻页。
    if (_edgeDragDx != 0) {
      _edgeDragDx = 0;
      if (mounted) setState(() {});
    }
    if (_imageZoomed) return; // 平移结束，保持当前位置

    final dx = _pageDragDx;
    final hadDrag = _pathLength >= _pageTriggerDistance;
    if (!hadDrag) {
      if (dx != 0 && mounted) setState(() => _pageDragDx = 0);
      return;
    }

    // 水平位移要足够明显才翻页，避免轻微斜向滑动误触发。
    final threshold = MediaQuery.of(context).size.width * 0.15;
    if (dx.abs() < threshold) {
      // 不翻页：平滑回弹到原位，而不是"跳"回去。
      _animatePageDrag(to: 0);
      return;
    }
    _goToAnimated(dx < 0 ? _index + 1 : _index - 1);
  }

  /// 把跟手位移从当前值动画到 [to]（0 表示回弹原位）。
  ///
  /// 用一次性 controller：位移动画很短（不到 200ms），
  /// 复用同一个 controller 反而要处理中断与重入，得不偿失。
  Future<void> _animatePageDrag({required double to, int? thenGoTo}) async {
    final from = _pageDragDx;
    if ((from - to).abs() < 0.5) {
      if (mounted) setState(() => _pageDragDx = to);
      if (thenGoTo != null) _onIndexChanged(thenGoTo);
      return;
    }

    _pageAnimating = true;
    final anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    final tween = Tween<double>(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut));
    void listener() {
      if (mounted) setState(() => _pageDragDx = tween.value);
    }

    anim.addListener(listener);
    try {
      await anim.forward();
    } finally {
      anim.removeListener(listener);
      anim.dispose();
    }
    if (!mounted) return;

    setState(() {
      _pageDragDx = to;
      _pageAnimating = false;
    });
    // 位移到位之后才切页：新页正好落在原位，不会出现内容与下标错位。
    if (thenGoTo != null) _onIndexChanged(thenGoTo);
  }

  /// 带跟手位移的翻页：滑出整屏后切换页并复位位移。
  Future<void> _goToAnimated(int target) async {
    if (target < 0 || target >= _images.length) {
      _animatePageDrag(to: 0);
      return;
    }
    final w = _viewportSize.width;
    if (w <= 0) {
      _goTo(target);
      return;
    }
    // 与拖动方向一致：向左拖（dx<0）→ 继续左移整屏。
    final forward = target > _index;
    await _animatePageDrag(to: forward ? -w : w, thenGoTo: target);
  }

  /// 复原缩放（需求：复原按钮）。
  void _resetZoom() {
    _imageScale = 1.0;
    _panTotal = Offset.zero;
    _edgeFlipArmed = false;
    _edgeDragDx = 0;
    _pageDragDx = 0;
    if (mounted) {
      setState(() => _imageTransform = Matrix4.identity());
    } else {
      _imageTransform = Matrix4.identity();
    }
  }

  /// 双击以点击位置为中心在 1× 与 2.5× 之间切换。
  void _handleDoubleTap(Offset localPos, Size size) {
    if (_imageZoomed) {
      _resetZoom();
      return;
    }
    const s = 2.5;
    final center = Offset(size.width / 2, size.height / 2);
    final d = localPos - center;
    // 让点击处移向画面中心：先算平移量再夹住，避免把图片拖出画面。
    final wanted = Offset(-d.dx * (1 - 1 / s), -d.dy * (1 - 1 / s));
    _imageScale = s;
    _panTotal = _clampPan(wanted);
    _rebuildTransform();
  }

  /// 点按播放/暂停。
  Future<void> _togglePlay() async {
    if (_playing) {
      _stopPlayback(releaseFrames: true);
      return;
    }
    await _startPlayback(reportFailure: true);
  }

  /// 开始播放当前张的动图。
  ///
  /// 设计约定（与需求一致）：
  ///   * 用户点播放就播 —— 对自己设备的内存有信心是他的判断，不弹对话框阻拦。
  ///   * **唯一的例外**：连降采样后系统都装不下（会直接把进程拖死、界面卡住），
  ///     此时才提示并说明原因。
  ///
  /// [reportFailure] 为 false 时（自动播放）不弹提示，只记日志：
  /// 自动播放失败不该用 snackbar 打扰阅读。
  Future<bool> _startPlayback({required bool reportFailure}) async {
    final d = _window.decoded(_index);
    if (d == null || !d.isAnimated) return false;
    if (!mounted) return false;
    final messenger = ScaffoldMessenger.of(context);

    // 预测需要多少内存：帧数 × 单帧字节。
    final neededFull = d.fullBytes;
    final avail = await SafChannel.availableMemory();

    // 系统可用内存（availMem）是内核判断"该不该杀进程"的同一口径。
    // 留 1.3 倍余量：解码过程本身还有临时开销。
    int? targetWidth;
    if (avail != null && avail > 0) {
      final budget = (avail / 1.3).floor();
      if (neededFull > budget) {
        // 装不下原尺寸 → 先尝试按内存比例降采样（能不拦就不拦）。
        final ratio = budget / neededFull;
        final scaled = (d.width * math.sqrt(ratio)).floor();
        if (scaled < 64) {
          // 连很小的尺寸都装不下：这时播放必然把进程拖死，必须拦。
          _log(
            '动图过大，已阻止播放：需要 ${_fmtMb(neededFull)}，'
            '可用 ${_fmtMb(avail)}',
          );
          if (reportFailure) {
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  '这个动图需要约 ${_fmtMb(neededFull)}，'
                  '当前可用内存只有 ${_fmtMb(avail)}，播放会直接把应用卡死，已取消。',
                ),
                duration: const Duration(seconds: 6),
              ),
            );
          }
          return false;
        }
        targetWidth = scaled;
        _log(
          '动图降采样播放：需要 ${_fmtMb(neededFull)}，'
          '可用 ${_fmtMb(avail)} → 解码宽度 $scaled',
        );
      }
    }

    final token = ++_playToken;
    final bytes = await _window.loadBytes(_index);
    if (bytes == null) return false;

    _DecodedImage? full;
    try {
      full = await _window.decodeAllFrames(bytes, targetWidth: targetWidth);
    } catch (e) {
      _log('动图解码失败：$e');
      full = null;
    }
    if (!mounted || token != _playToken) {
      full?.disposeAll();
      return false;
    }
    if (full == null || !full.isAnimated) {
      if (reportFailure) {
        messenger.showSnackBar(const SnackBar(content: Text('这个动图无法解码')));
      }
      return false;
    }

    // 换掉"只含首帧"的预览对象；旧对象单独释放，避免泄漏首帧。
    _window.replaceWithFull(_index, full);
    setState(() {
      _playing = true;
      _frameIndex = 0;
    });
    _scheduleFrame(full, _playToken);
    return true;
  }

  /// 自动播放：读到动图后若设置了自动播放就尝试播放一次。
  ///
  /// 每张只尝试一次（[_autoPlayTried]），避免失败后在 onChanged 里反复重试。
  Future<void> _maybeAutoPlay() async {
    if (!_repo.settings.autoPlayGif) return;
    if (_playing) return;
    if (_autoPlayTried == _index) return;
    final d = _window.decoded(_index);
    if (d == null || !d.isAnimated) return;
    _autoPlayTried = _index;
    await _startPlayback(reportFailure: false);
  }

  /// 按当前帧的时长安排下一帧。
  ///
  /// [token] 是发起播放时的 [_playToken] 快照：暂停或翻页会自增它，
  /// 旧循环据此在下一拍自行退出（不再递归，也不会误播）。
  void _scheduleFrame(_DecodedImage d, int token) {
    _frameTimer?.cancel();
    _frameTimer = Timer(d.durationOf(_frameIndex), () {
      if (!mounted || !_playing || token != _playToken) return;
      var next = _frameIndex + 1;
      if (next >= d.frameCount) {
        // repetitions: 0 = 只播一次，-1 = 无限循环。
        if (d.repetitions == 0) {
          _stopPlayback(releaseFrames: false);
          return;
        }
        next = 0;
      }
      d.setDisplayIndex(next);
      setState(() => _frameIndex = next);
      _scheduleFrame(d, token);
    });
  }

  /// 停止播放。[releaseFrames] 为 true 时释放除首帧外的所有帧，回到预览状态。
  void _stopPlayback({required bool releaseFrames}) {
    _playToken++;
    _frameTimer?.cancel();
    _frameTimer = null;
    final d = _window.decoded(_index);
    if (releaseFrames) {
      d?.releaseFramesBeyondFirst();
    }
    if (mounted) {
      setState(() {
        _playing = false;
        _frameIndex = 0;
      });
    } else {
      _playing = false;
    }
  }

  static String _fmtMb(int bytes) => '${(bytes / (1024 * 1024)).round()} MB';

  /// 刷新：重新读取当前张与其预加载窗口。  ///
  /// 用途：遇到「读取失败」「无法解码」时（授权抖动、大压缩包读取超时、
  /// 系统回收资源等），不必退出重进，点一下即可重新读。
  void _refresh() {
    // 刷新同时把失败计数清零，让用户手动重试后不再被旧计数影响。
    _failCount.remove(_index);
    _window.refresh();
    setState(() {
      _error = null;
    });
    unawaited(_window.update(_index));
  }

  /// 翻译当前这一张。
  ///
  /// 刻意不弹任何进度框、不改动图片窗口：翻译在服务端做，阅读器只等一个
  /// Future；哪怕翻译端卡死，也只是这个按钮转圈，翻页/缩放手势完全不受影响
  /// （[TranslationService.translatePage] 里还有一层总超时兜底）。
  ///
  /// 发过去的永远是**原图**（job 按索引从原图集读字节），所以失败后可以
  /// 反复点这个按钮重试，不会把"上一版的译文"再翻一遍。
  /// 成功后把成品读进内存并就地替代显示，顶栏随即出现「看原图」。
  Future<void> _translateCurrent() async {
    if (_translating || _images.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final service = TranslationService.instance;
    final index = _index;
    setState(() => _translating = true);
    messenger.showSnackBar(
      const SnackBar(content: Text('正在翻译这一张…'), duration: Duration(seconds: 2)),
    );
    try {
      final r = await service.translatePage(
        gallery: widget.gallery,
        index: index,
      );
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      if (r.ok) {
        // 纯画面页：服务端一块都没翻出来。这不是失败，也不会落盘，
        // 别走到下面「已翻译」的分支去骗用户。
        if (r.page!.noText) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('这一页没有可翻译的文字，已跳过（不计失败）'),
              duration: Duration(seconds: 3),
            ),
          );
          return;
        }
        // 从刚写好的译文目录里读成品：和"重开阅读器后自动显示译文"
        // 走同一条路径，避免两套逻辑各说各话。
        final bytes = await service.loadTranslatedPage(widget.gallery, index);
        if (bytes != null && mounted) {
          _translatedProbed.add(index);
          setState(() {
            _translated[index] = bytes;
            _showTranslated = true;
          });
        }
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              // 行级失败很常见（本机模型偶尔对某些句子给空译文），
              // 说清「翻成了、只是几句没出来」，别让人以为整页白翻。
              r.page!.copied
                  ? '这张是动图，已原样复制'
                  : r.page!.failed > 0
                      ? '已翻译；其中 ${r.page!.failed} 行没翻出来（模型返回空译文）'
                      : '已翻译，顶栏可切换原图/译文',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('${r.error ?? '翻译失败'}（可再点一次重试）'),
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  /// 记录一次读取失败；达到阈值后询问是否验证文件是否存在。
  void _recordFailure(int index) {
    final n = (_failCount[index] ?? 0) + 1;
    _failCount[index] = n;
    if (n < _failureThreshold) return;
    if (_recoveryDeclined) return; // 本次浏览已明确拒绝，不再打扰
    // 只在用户停在出错的那一张时询问。
    if (index != _index) return;
    _failCount[index] = 0; // 避免连续弹窗
    unawaited(_askRecover());
  }

  /// 读取失败 3 次后的恢复流程。
  ///
  /// 需求流程：
  ///   询问「是否验证文件存在？」
  ///     否 → 本次浏览不再询问（下次浏览仍会问）
  ///     是 → ① 来源存在？→ 等同更新的重载
  ///          ② 不存在：压缩包 → 问是否移除图集以便重新导入
  ///                     文件夹 → 问是否去上一级目录查找
  ///                        是 → 查找（带进度、可取消）
  ///                             找到 → 重载；找不到 → 问是否移除图集
  ///                             取消 → 等同"否"
  ///                        否 → 关闭窗口
  Future<void> _askRecover() async {
    if (!mounted) return;
    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);

    // 第 1 步：是否验证文件存在
    final verify = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('这张图读取失败'),
        content: Text(
          '「${widget.gallery.title}」已经连续 $_failureThreshold 次读取失败。\n\n'
          '是否验证来源文件是否存在？',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('否'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('验证'),
          ),
        ],
      ),
    );
    if (verify != true) {
      // 选否：本次浏览不再询问（下次进入本图集仍会问）。
      _recoveryDeclined = true;
      return;
    }
    if (!mounted) return;

    // 第 2 步：验证来源是否存在
    final progress = showProgressDialog(
      navigator,
      initial: '正在验证文件…',
      cancellable: false,
    );
    bool exists;
    try {
      exists = await _repo.verifySource(widget.gallery);
    } catch (_) {
      exists = false;
    } finally {
      await progress.finish();
    }
    if (!mounted) return;

    if (exists) {
      await _reloadGallery('来源仍然存在，正在重新读取…', messenger);
      return;
    }

    // 第 3 步：来源不存在
    if (widget.gallery.isFolder) {
      await _askSearchParent(navigator, messenger);
    } else {
      await _askRemoveGallery(navigator, messenger, '压缩包已经不在原来的位置了。');
    }
  }

  /// 文件夹来源读不到时：询问是否去上一级目录查找。
  Future<void> _askSearchParent(
    NavigatorState navigator,
    ScaffoldMessengerState messenger,
  ) async {
    if (!mounted) return;
    final search = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('来源文件夹找不到了'),
        content: const Text(
          '这个文件夹可能被移动或改名了。\n\n是否到上一级目录里查找它？',
          style: TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('否'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('查找'),
          ),
        ],
      ),
    );
    if (search != true) return;
    if (!mounted) return;

    // 带进度、可取消的查找
    final progress = showProgressDialog(navigator, initial: '正在查找文件夹…');
    String? found;
    bool userCancelled = false;
    try {
      found = await _repo.findFolderInParents(
        widget.gallery,
        onProgress: (level, max) {
          progress.handle.update(level, max, '正在向上查找第 $level 级');
        },
        isCancelled: () => progress.handle.cancelled,
      );
    } finally {
      // 必须在 finish() 之前读取取消状态：finish 会释放 ValueNotifier，
      // 之后再访问它的字段属于使用已释放对象。
      userCancelled = progress.handle.cancelled;
      await progress.finish();
    }
    if (!mounted) return;

    if (userCancelled) {
      // 取消 = 等同"否"
      _recoveryDeclined = true;
      return;
    }

    if (found != null) {
      final r = await _repo.reloadFromUri(widget.gallery, found);
      messenger.showSnackBar(SnackBar(content: Text(r.message)));
      await _reloadWindow();
      return;
    }

    await _askRemoveGallery(navigator, messenger, '在上级目录里没有找到这个文件夹。');
  }

  /// 询问是否移除图集（只移除软件内的记录，不动文件），以便重新手动导入。
  Future<void> _askRemoveGallery(
    NavigatorState navigator,
    ScaffoldMessengerState messenger,
    String reason,
  ) async {
    if (!mounted) return;
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('找不到来源文件'),
        content: Text(
          '$reason\n\n'
          '是否从列表移除这个图集，之后由你手动重新导入？\n\n'
          '注意：只会移除本软件内的记录，'
          '磁盘上的文件不会被删除或移动。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('否'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除图集'),
          ),
        ],
      ),
    );
    if (remove != true) return;

    await _repo.removeFromIndex(widget.gallery);
    messenger.showSnackBar(const SnackBar(content: Text('已从列表移除，可重新导入')));
    if (mounted) navigator.pop(); // 退回列表
  }

  /// 来源仍可读：重新载入并刷新窗口。
  Future<void> _reloadGallery(
    String label,
    ScaffoldMessengerState messenger,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final progress = showProgressDialog(
      navigator,
      initial: label,
      cancellable: false,
    );
    try {
      final r = await _repo.reloadFromUri(
        widget.gallery,
        widget.gallery.sourcePath,
      );
      messenger.showSnackBar(SnackBar(content: Text(r.message)));
    } finally {
      await progress.finish();
    }
    await _reloadWindow();
  }

  /// 重新载入当前图集的图片清单并重建窗口。
  Future<void> _reloadWindow() async {
    if (!mounted) return;
    _failCount.clear();
    _window.disposeAll();
    _autoPlayTried = -1;
    setState(() {
      _error = null;
      _index = 0;
    });
    unawaited(_window.update(0));
  }

  List<Widget> _buildOverlays() {
    return [
      // 顶部：返回、标题、序号。
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: Text(
                    widget.gallery.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15),
                  ),
                ),
                // 动图的播放/暂停。只在这一张确实是动图时出现。
                if (_window.decoded(_index)?.isAnimated ?? false) ...[
                  if (_playing)
                    Padding(
                      padding: const EdgeInsets.only(right: 2),
                      child: Text(
                        '${_frameIndex + 1}/${_window.decoded(_index)!.frameCount}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFFB9BCC4),
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: _playing ? '暂停动图' : '播放动图',
                    icon: Icon(
                      _playing ? Icons.pause_circle : Icons.play_circle,
                      size: 24,
                    ),
                    onPressed: _togglePlay,
                  ),
                ],
                // 复原缩放：只在放大时出现，避免平时占位置。
                if (_imageZoomed)
                  IconButton(
                    tooltip: '复原缩放（${(_imageScale * 100).round()}%）',
                    icon: const Icon(Icons.zoom_out_map, size: 20),
                    onPressed: _resetZoom,
                  ),
                // 原图 / 译文切换：只有本页确实有译文时才出现。
                // 图标故意不用 translate（会与右边「翻译这一张」撞脸）：
                // 用 compare 表达「原图 ↔ 译文对照」。
                if (_translated[_index] != null)
                  IconButton(
                    tooltip: _showTranslated ? '看原图' : '看译文',
                    icon: Icon(
                      _showTranslated ? Icons.compare : Icons.compare_outlined,
                      size: 20,
                    ),
                    onPressed: () =>
                        setState(() => _showTranslated = !_showTranslated),
                  ),
                // 单张翻译：不弹进度框、不阻塞阅读，失败就在底部提示。
                if (_images.isNotEmpty)
                  IconButton(
                    tooltip: _translating ? '正在翻译这一张…' : '翻译这一张',
                    icon: _translating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.translate, size: 20),
                    onPressed: _translating ? null : _translateCurrent,
                  ),
                IconButton(
                  tooltip: '刷新（重新读取图片）',
                  icon: const Icon(Icons.refresh, size: 20),
                  onPressed: _refresh,
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Text(
                    // 放大时顺便显示倍数，让"当前处于放大状态"一目了然。
                    _imageZoomed
                        ? '${(_imageScale * 100).round()}%  ${_index + 1}/${_images.length}'
                        : '${_index + 1}/${_images.length}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFFB9BCC4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),

      // 底部：进度条 + 亮度。
      Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        child: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Color(0xCC000000), Color(0x00000000)],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 亮度条：默认收起，点按钮才唤出（需求）。
                // 收起后底部只剩进度条，画面更干净。
                if (_brightnessOpen)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '收起亮度条',
                          icon: const Icon(Icons.expand_more, size: 20),
                          onPressed: () =>
                              setState(() => _brightnessOpen = false),
                        ),
                        const Icon(
                          Icons.brightness_6,
                          size: 16,
                          color: Color(0xFFB9BCC4),
                        ),
                        Expanded(
                          child: Slider(
                            value: _brightness.clamp(0.15, 1.0),
                            min: 0.15,
                            max: 1.0,
                            // 只改本页的临时亮度，**不写全局设置**：
                            // 全局亮度属于「设置」页，阅读时随手调暗不应该永久生效。
                            onChanged: (v) =>
                                setState(() => _overrideBrightness = v),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '${(_brightness * 100).round()}%',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFFB9BCC4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${_index + 1}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB9BCC4),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Slider(
                          value: _index.toDouble().clamp(
                            0,
                            (_images.length - 1).toDouble(),
                          ),
                          min: 0,
                          max: (_images.length - 1).toDouble().clamp(1, 1e9),
                          onChanged: (v) {
                            final target = v.round();
                            if (target != _index) _onIndexChanged(target);
                          },
                          onChangeEnd: (v) => _goTo(v.round()),
                        ),
                      ),
                      SizedBox(
                        width: 42,
                        child: Text(
                          '${_images.length}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFB9BCC4),
                          ),
                        ),
                      ),
                      // 亮度按钮：点它唤出/收起亮度条。
                      // 亮度值不是 100% 时用醒目一点的颜色，提示"当前已调过"。
                      IconButton(
                        tooltip: _brightnessOpen ? '收起亮度条' : '调整亮度',
                        icon: Icon(
                          _brightnessOpen
                              ? Icons.brightness_high
                              : Icons.brightness_6,
                          size: 20,
                          color: _brightness < 0.999
                              ? const Color(0xFF8FB6E8)
                              : const Color(0xFFB9BCC4),
                        ),
                        onPressed: () =>
                            setState(() => _brightnessOpen = !_brightnessOpen),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ];
  }
}

/// 一次阅读会话内的 zip 访问器：索引与字节来源复用，退出时关闭。
///
/// 字节来源可能是 `content://` 文档（用户选的压缩包）或本地文件，
/// 由 [GalleryRepository.byteSourceFor] 统一决定 —— 阅读器本身不关心。
class _ZipSession {
  _ZipSession._(this._index, this._source);

  final ZipIndex _index;
  final ByteSource _source;
  bool _closed = false;

  static Future<_ZipSession> open(String sourcePath) async {
    final source = GalleryRepository.byteSourceFor(sourcePath);
    try {
      final index = await ZipIndex.openSource(source);
      return _ZipSession._(index, source);
    } catch (_) {
      await source.close();
      rethrow;
    }
  }

  /// 读取第 [imageOrdinal] 张图片的原始字节（对应索引里的图片序号）。
  Future<Uint8List?> read(int imageOrdinal) async {
    if (_closed) return null;
    if (imageOrdinal < 0 || imageOrdinal >= _index.imageEntries.length) {
      return null;
    }
    return _index.imageEntries[imageOrdinal].read(_source);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    unawaited(_source.close());
  }
}

/// 受外部控制的图片呈现控件（缩放矩阵由调用方提供）。
///
/// 这里**不处理任何手势**：翻页、平移、缩放的手势全部由查看器页面统一调度。
/// 原因是这三者互相冲突，必须由一个状态机决定当前谁生效 ——
/// 让 InteractiveViewer 与 PageView 各自处理手势，必然互相抢。
class _ZoomableImage extends StatelessWidget {
  const _ZoomableImage({
    super.key,
    required this.image,
    required this.loading,
    required this.error,
    required this.transform,
    this.alternative,
    this.showAlternative = false,
  });

  final ui.Image? image;
  final bool loading;
  final String? error;

  /// 缩放/平移矩阵。
  final Matrix4 transform;

  /// 「译文」字节：读取器单图翻译后替代原图显示。
  ///
  /// 用 `Image.memory` 而不是解成 `ui.Image` 塞进图片窗口：译文只在这一页
  /// 临时出现，不该占用那套按窗口管理的解码缓存。
  final Uint8List? alternative;

  /// 为 true 且 [alternative] 不为 null 时显示译文，否则显示原图。
  final bool showAlternative;

  @override
  Widget build(BuildContext context) {
    if (error != null) {
      return Center(
        child: Text(
          error!,
          style: const TextStyle(color: Color(0xFFC98A8A), fontSize: 13),
        ),
      );
    }
    final showingAlternative = showAlternative && alternative != null;
    if (image == null && !showingAlternative) {
      return Center(
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(
                Icons.broken_image_outlined,
                color: Color(0xFF4A4D57),
                size: 28,
              ),
      );
    }
    // 图片本身已被按需降采样，直接以 RawImage 呈现，避免额外的 provider 缓存。
    //
    // 固定 BoxFit.contain：按图片**原有比例**完整显示，不裁切、不拉伸、不铺满。
    // 外层 Center 保证不超出可用空间时不放大（小图保持实际显示尺寸）。
    //
    // 不裁切溢出部分：放大后画面可以超出可视区，靠矩阵平移查看。
    return Transform(
      transform: transform,
      alignment: Alignment.center,
      child: Center(
        child: showingAlternative
            ? Image.memory(
                alternative!,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
              )
            : RawImage(
                image: image,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
              ),
      ),
    );
  }
}

/// 要几百 MB 到数 GB。只解首帧后，浏览时的内存与普通图片完全一致。
class _DecodedImage {
  _DecodedImage._(
    this._frames,
    this._durations,
    this._available, {
    this.repetitions = -1,
  });

  final List<ui.Image> _frames;

  /// 各帧显示时长，长度等于**总帧数**（即使其余帧还没解码）。
  final List<Duration> _durations;

  /// 已经解码出来的帧数。动图未播放时等于 1。
  int _available;

  /// 循环次数：0 = 只播一次，-1 = 无限循环。
  final int repetitions;

  /// 只解首帧。静态图与"动图预览"都走这里，成本与原来完全一样。
  factory _DecodedImage.single(ui.Image first) =>
      _DecodedImage._([first], const [Duration(milliseconds: 100)], 1);

  /// 动图预览：只持有首帧，但已知总帧数与各帧时长。
  factory _DecodedImage.preview(
    ui.Image first,
    List<Duration> durations, {
    int repetitions = -1,
  }) => _DecodedImage._([first], durations, 1, repetitions: repetitions);

  /// 多帧（用户点播放后解全部帧时使用）。
  factory _DecodedImage.animated(
    List<ui.Image> frames,
    List<Duration> d, {
    int repetitions = -1,
  }) => _DecodedImage._(frames, d, frames.length, repetitions: repetitions);

  int get frameCount => _durations.length;

  /// 是否动图（多于 1 帧）。
  bool get isAnimated => frameCount > 1;

  bool get isFullyLoaded => _available >= frameCount;

  int get width => _frames.first.width;
  int get height => _frames.first.height;

  /// 当前应显示的帧（**按帧显示，不持有全部帧**）。
  ui.Image get display => _frames[_displayIndex];
  int _displayIndex = 0;
  int get displayIndex => _displayIndex;

  /// 仅切换显示哪一帧，不改变内存占用。
  void setDisplayIndex(int i) {
    if (i >= 0 && i < _available) _displayIndex = i;
  }

  Duration durationOf(int i) =>
      i < _durations.length ? _durations[i] : const Duration(milliseconds: 100);

  /// 单帧字节数（ARGB8888：每像素 4 字节）。
  int get bytesPerFrame => width * height * 4;

  /// 全部帧都解码时所需的字节数。
  int get fullBytes => bytesPerFrame * frameCount;

  /// 当前实际占用的字节数（只算已解码的帧）。
  int get currentBytes => bytesPerFrame * _available;

  /// 释放除首帧外的所有帧，回到"仅预览"状态。
  void releaseFramesBeyondFirst() {
    if (_available <= 1) return;
    final doomed = _frames.sublist(1, _available);
    _frames.removeRange(1, _available);
    _available = 1;
    _displayIndex = 0;
    _ImageWindow._disposeAfterFrame(doomed);
  }

  void disposeAll() {
    _ImageWindow._disposeAfterFrame(List<ui.Image>.from(_frames));
    _frames.clear();
    _available = 0;
  }
}

/// 已解码图像的有界窗口，负责预加载与主动卸载。
class _ImageWindow {
  _ImageWindow({
    required this.images,
    required this.loader,
    required this.preload,
    required this.unloadDistance,
    required this.onChanged,
    required this.onFailure,
  });

  final List<GalleryImage> images;
  final Future<Uint8List?> Function(int index) loader;
  final int preload;

  /// 超出当前张多少张后卸载。上限不限，由用户设置。
  final int unloadDistance;
  final VoidCallback onChanged;

  /// 某一张读取或解码失败时回调（用于累计失败次数并触发恢复流程）。
  final void Function(int index) onFailure;

  /// 有序缓存，便于按距离淘汰。
  final _cache = <int, _DecodedImage>{};

  /// 已解码位图的**硬上限**。
  ///
  /// 用户可把"卸载距离"设成不限，但缓存不能真的无限：
  /// 每张按屏幕尺度解码约占 6 MB，上限 24 张 ≈ 144 MB，
  /// 既够顺滑翻页，也不会在快速跳页时把内存打爆。
  static const _maxCachedImages = 24;

  final _errors = <int, String>{};
  final _inFlight = <int>{};

  /// 已作废的在途解码。用户跳页后，这些结果即便解出来也直接丢弃。
  final _abandoned = <int>{};
  int _generation = 0;

  bool has(int i) => _cache.containsKey(i);
  _DecodedImage? decoded(int i) => _cache[i];

  /// 当前应绘制的位图（动图取当前帧）。
  ui.Image? get(int i) => _cache[i]?.display;
  String? errorOf(int i) => _errors[i];

  /// 清空缓存以强制重新读取。
  ///
  /// 需求：查看器里的「刷新」，用于重新读取那些"读取失败 / 无法解码"的图片
  /// （授权抖动、大包读取超时等都会导致这种情况）。
  /// 已缓存的图片一并丢弃，确保是真的重新读一遍。
  void refresh() {
    _generation++;
    final all = _cache.values.toList();
    _cache.clear();
    _errors.clear();
    _inFlight.clear();
    // 逐帧释放：动图有多个 ui.Image，漏一帧就是静默泄漏。
    for (final d in all) {
      d.disposeAll();
    }
  }

  /// 切换到第 [index] 张：预加载窗口，并卸载超距的图片。
  Future<void> update(int index) async {
    final gen = ++_generation;

    // 用户又跳走了：把上一代在途的解码记为作废并立即放弃。
    //
    // 这是"一次跳几百张就卡死"的直接原因 —— PageView 跨页动画会沿途构建
    // 每一页，每次都触发一轮解码；若不中途放弃，几百轮解码会同时堆在内存里。
    if (_inFlight.isNotEmpty) {
      _abandoned.addAll(_inFlight);
      _inFlight.clear();
    }

    // 需要保留的范围：前后各 preload 张。
    final keepFrom = (index - preload).clamp(0, images.length - 1);
    final keepTo = (index + preload).clamp(0, images.length - 1);

    // 先卸载超出「当前张 ± unloadDistance」的图片，控制峰值内存。
    //
    // 硬上限是必须的：设置里的卸载距离**上限不限**，用户调到很大时缓存会
    // 无限增长，快速跳页时容易 OOM。
    final evictThreshold = unloadDistance <= 0
        ? _maxCachedImages
        : (unloadDistance > _maxCachedImages
              ? _maxCachedImages
              : unloadDistance);
    final doomed = _cache.keys
        .where((k) => (k - index).abs() > evictThreshold)
        .toList();
    final removed = <_DecodedImage>[];
    for (final k in doomed) {
      final img = _cache.remove(k);
      if (img != null) removed.add(img);
    }

    // 即使都在距离内，也仍要保证不超过硬上限：优先丢弃离当前位置最远的。
    //
    // 动图在播放时单个条目就可能占几百 MB，所以数量上限之外还要按**字节**兜底：
    // 超过预算时同样从最远的开始丢。
    if (_cache.length > _maxCachedImages) {
      final byDistance = _cache.keys.toList()
        ..sort((a, b) => (b - index).abs().compareTo((a - index).abs()));
      final overflow = _cache.length - _maxCachedImages;
      for (var i = 0; i < overflow && i < byDistance.length; i++) {
        final img = _cache.remove(byDistance[i]);
        if (img != null) removed.add(img);
      }
    }

    if (removed.isNotEmpty) {
      // **关键**：不能立即 dispose —— 这些位图可能仍在本帧的绘制队列里，
      // 立刻释放会导致"使用已释放的图像"而崩溃（快速跳页时必现）。
      // 统一推迟到帧结束之后再释放。动图会逐帧释放。
      for (final d in removed) {
        d.disposeAll();
      }
      onChanged();
    }

    // 再按「近 -> 远」的顺序补载窗口内的图片。
    //
    // 只补当前窗口，且**严格串行**：Flutter 的图片解码在部分设备上会走
    // Java 侧的 ImageDecoder（JNI），并发解码容易让引擎因 Java 异常直接 abort
    // （实测崩溃信息：jni_util.cc Check failed: env->ExceptionCheck() == JNI_FALSE）。
    final wanted = <int>[];
    for (var d = 0; d <= preload; d++) {
      for (final i in [index - d, index + d]) {
        if (i >= keepFrom && i <= keepTo && !wanted.contains(i)) {
          wanted.add(i);
        }
      }
    }

    for (final i in wanted) {
      if (gen != _generation) return; // 已翻到别处，不再继续补载。
      if (_cache.containsKey(i) || _inFlight.contains(i)) continue;
      await _decodeInto(i, gen);
    }
  }

  /// 把释放动作推迟到当前帧结束之后。
  static void _disposeAfterFrame(List<ui.Image> images) {
    if (images.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final img in images) {
        img._disposeImage();
      }
    });
  }

  /// 限制**同时只有一次**图片解码在进行。
  ///
  /// 关键：Flutter 的解码在 Android 上可能走 Java 侧 ImageDecoder（JNI）。
  /// 并发解码时，Java 侧一旦抛异常（例如分配失败），引擎会因未清理的 JNI
  /// 异常直接 abort —— 实测崩溃信息正是
  /// `[FATAL:flutter/fml/platform/android/jni_util.cc(92)]
  ///  Check failed: env->ExceptionCheck() == JNI_FALSE.`
  /// 串行化能把并发压力降到最低，也顺带削平内存峰值。
  static Future<void> _decodeLock = Future<void>.value();

  Future<void> _decodeInto(int index, int gen) async {
    // 已被更新的跳页作废：直接放弃，不要再去读文件。
    if (gen != _generation || _abandoned.contains(index)) return;

    _inFlight.add(index);
    // 串行化：把本次解码排在上一次之后，避免并发解码触发引擎 JNI 崩溃。
    final previous = _decodeLock;
    final completer = Completer<void>();
    _decodeLock = completer.future;
    try {
      await previous;

      if (gen != _generation || _abandoned.contains(index)) return;

      final bytes = await loader(index);

      // 期间用户可能又跳页了 —— 此时立刻退出，避免继续解码浪费内存。
      if (gen != _generation || _abandoned.contains(index)) return;

      if (bytes == null) {
        _errors[index] = '图片不可读';
        onFailure(index);
        return;
      }

      final decoded = await _decodeFirstFrame(bytes);
      if (gen != _generation || _abandoned.contains(index)) {
        // 解码已经发生，把结果释放掉即可。
        decoded?.disposeAll();
        return;
      }
      if (decoded == null) {
        _errors[index] = '无法解码该图片';
        onFailure(index);
      } else {
        _errors.remove(index);
        final old = _cache.remove(index);
        _cache[index] = decoded;
        // 覆盖旧图时同样要推迟释放（动图逐帧释放）。
        old?.disposeAll();
      }
      onChanged();
    } catch (e, st) {
      // 解码失败绝不能升级成崩溃：记下原因，让这一张显示为失败，
      // 用户可以用查看器里的「刷新」重试。
      _errors[index] = '读取失败';
      _log('第 ${index + 1} 张解码失败：$e');
      _log('$st');
      onFailure(index);
    } finally {
      _inFlight.remove(index);
      _abandoned.remove(index);
      if (!completer.isCompleted) completer.complete();
    }
  }

  /// 解码**首帧**，并读出总帧数、各帧时长与循环次数（不解其余帧）。
  ///
  /// 为什么只解首帧：动图全帧需要"帧数 × 单帧字节"的连续内存，
  /// 一个 128 帧的大 GIF 可能要几百 MB 到数 GB。只解首帧后，
  /// 浏览时的内存与普通图片完全一致 —— 播放由用户显式触发。
  ///
  /// 注意帧时长来自 `FrameInfo.duration`（`Codec` 上没有该方法），
  /// 因此必须逐次 `getNextFrame()` 才能拿到所有时长；为了不多留内存，
  /// 除首帧外的帧取到时长后立刻释放。
  Future<_DecodedImage?> _decodeFirstFrame(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: _longestScreenSide,
      allowUpscaling: false,
    );
    try {
      final first = await codec.getNextFrame();
      if (codec.frameCount <= 1) {
        return _DecodedImage.single(first.image);
      }

      final durations = <Duration>[_frameDuration(first.duration)];
      // 继续取出其余帧只为拿到时长，随后立即释放，避免预览就吃掉全部内存。
      for (var i = 1; i < codec.frameCount; i++) {
        final f = await codec.getNextFrame();
        durations.add(_frameDuration(f.duration));
        f.image._disposeImage();
      }
      return _DecodedImage.preview(
        first.image,
        durations,
        repetitions: codec.repetitionCount,
      );
    } finally {
      codec.dispose();
    }
  }

  /// 帧延时的下限保护。
  ///
  /// GIF 允许 0/1 厘秒的延时，照搬会导致定时器疯狂触发、白耗 CPU 与电。
  static Duration _frameDuration(Duration raw) {
    const min = Duration(milliseconds: 20);
    return raw < min ? min : raw;
  }

  /// 屏幕最长边（解码上限）。
  int get _longestScreenSide {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    final size = view?.physicalSize;
    if (size == null) return 2560;
    final w = size.width.round();
    final h = size.height.round();
    return w > h ? w : h;
  }

  /// 解出**全部帧**（用户点了播放才会走到这里）。
  ///
  /// [targetWidth] 为 null 表示按原始尺寸解码；给出时按该宽度降采样。
  /// 返回 null 表示无法解码。
  Future<_DecodedImage?> decodeAllFrames(
    Uint8List bytes, {
    int? targetWidth,
  }) async {
    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: targetWidth,
      allowUpscaling: false,
    );
    try {
      final frames = <ui.Image>[];
      final durations = <Duration>[];
      for (var i = 0; i < codec.frameCount; i++) {
        final f = await codec.getNextFrame();
        frames.add(f.image);
        durations.add(_frameDuration(f.duration));
      }
      if (frames.length <= 1) {
        return frames.isEmpty ? null : _DecodedImage.single(frames.first);
      }
      return _DecodedImage.animated(
        frames,
        durations,
        repetitions: codec.repetitionCount,
      );
    } finally {
      codec.dispose();
    }
  }

  /// 用解好的全帧替换缓存里的预览（只保留首帧的那个）。
  void replaceWithFull(int index, _DecodedImage full) {
    final old = _cache.remove(index);
    _cache[index] = full;
    // 旧的那个只持有首帧，单独释放；新对象持有自己的全部帧。
    old?.disposeAll();
  }

  /// 取原始图片字节（播放时需要重新读一次用于解全部帧）。
  Future<Uint8List?> loadBytes(int index) => loader(index);

  void disposeAll() {
    _generation++;
    for (final img in _cache.values) {
      img.disposeAll();
    }
    _cache.clear();
    _errors.clear();
  }
}

extension on ui.Image {
  void _disposeImage() {
    try {
      dispose();
    } catch (_) {
      // 已释放的图片重复释放不应影响阅读。
    }
  }
}
