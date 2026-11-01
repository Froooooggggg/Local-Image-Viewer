import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:simple_gallery_viewer/core/byte_source.dart';

/// 可控的假来源：把 [reportedLength] 设成 0 就能模拟「SAF 提供方报不出长度」。
class _FakeSource implements ByteSource {
  _FakeSource(this.data, {this.reportedLength});

  final Uint8List data;
  final int? reportedLength;
  int readCalls = 0;
  bool closed = false;

  @override
  Future<int> length() async => reportedLength ?? data.length;

  @override
  Future<Uint8List> read(int offset, int count) async {
    readCalls++;
    if (count <= 0 || offset >= data.length) return Uint8List(0);
    final end = (offset + count).clamp(0, data.length);
    return Uint8List.sublistView(data, offset, end);
  }

  @override
  Future<TailChunk> readTail(int maxBytes) async =>
      throw UnimplementedError('本文件的用例用不到 readTail');

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  String get describe => 'fake:${data.length}B';
}

Uint8List _bytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i % 251));

void main() {
  test('长度报 0 时也能读完（回归：SAF 子文档被当成目录 → 文件为空）', () async {
    final data = _bytes(5000);
    final source = _FakeSource(data, reportedLength: 0);

    final got = await readAllChunked(source, chunkSize: 1024);

    expect(got.length, 5000);
    expect(got, orderedEquals(data));
  });

  test('数量正好是块大小的整数倍时也能读全', () async {
    final data = _bytes(4096);
    final source = _FakeSource(data);

    final got = await readAllChunked(source, chunkSize: 1024);

    expect(got.length, 4096);
    expect(got, orderedEquals(data));
  });

  test('maxBytes 会截断返回内容', () async {
    final data = _bytes(1000);
    final source = _FakeSource(data);

    final got = await readAllChunked(source, chunkSize: 100, maxBytes: 250);

    expect(got.length, 250);
    expect(got, orderedEquals(Uint8List.sublistView(data, 0, 250)));
  });

  test('空来源返回空，不报错', () async {
    final source = _FakeSource(Uint8List(0), reportedLength: 0);

    final got = await readAllChunked(source, chunkSize: 1024);

    expect(got, isEmpty);
  });

  test('分多块读取，不是一次性读完', () async {
    final data = _bytes(100);
    final source = _FakeSource(data, reportedLength: 0);

    await readAllChunked(source, chunkSize: 32);

    // 32 + 32 + 32 + 4，最后一块不足 → 结束；至少 4 次调用。
    expect(source.readCalls, greaterThanOrEqualTo(4));
  });

  test('readAllChunked 自己不关来源（由调用方负责）', () async {
    final source = _FakeSource(_bytes(10));

    await readAllChunked(source);

    expect(source.closed, isFalse);
  });
}
