import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dream_manga_reader/core/bili/bili_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// 按路径回放的 dio 传输层。B站接口全是同一套 `{code,message,data}` 信封,
/// 脚本化之后就能验证「什么时候该回退到综合搜索」这类分支。
class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.bodies);

  final Map<String, Object?> bodies;
  final List<String> requested = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requested.add(options.uri.path);
    final body = bodies[options.uri.path];
    if (body == null) throw StateError('unscripted request: ${options.uri}');
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

Map<String, Object?> _navBody() => {
      'code': 0,
      'data': {
        'wbi_img': {
          'img_url': 'https://i0.hdslb.com/bfs/wbi/aaaabbbb.png',
          'sub_url': 'https://i0.hdslb.com/bfs/wbi/ccccdddd.png',
        },
      },
    };

Map<String, Object?> _mediaBody(List<int> seasonIds) => {
      'code': 0,
      'data': {
        'result': [
          for (final id in seasonIds)
            {'season_id': id, 'title': 'S$id', 'cover': '//c.test/$id.jpg'},
        ],
      },
    };

void main() {
  tearDown(() => BiliApi.debugAdapter = null);

  // 专搜正常翻到末页也会返回空,老实现把它当成「被风控软拦」,于是回退综合搜索
  // 又把前几页的番剧块重发一遍 —— 列表永远翻不到底,还全是重复项。
  test('an empty page beyond the first does not fall back to the all-search',
      () async {
    final adapter = _ScriptedAdapter({
      '/x/frontend/finger/spi': {
        'code': 0,
        'data': {'b_3': 'b3', 'b_4': 'b4'},
      },
      '/x/web-interface/nav': _navBody(),
      '/x/web-interface/wbi/search/type': _mediaBody(const []),
    });
    BiliApi.debugAdapter = adapter;

    final results = await BiliApi.instance.searchBangumi('孤独摇滚', 3);

    expect(results, isEmpty);
    expect(adapter.requested,
        isNot(contains('/x/web-interface/wbi/search/all/v2')));
  });

  test('an empty first page still falls back to the all-search', () async {
    final adapter = _ScriptedAdapter({
      '/x/frontend/finger/spi': {
        'code': 0,
        'data': {'b_3': 'b3', 'b_4': 'b4'},
      },
      '/x/web-interface/nav': _navBody(),
      '/x/web-interface/wbi/search/type': _mediaBody(const []),
      '/x/web-interface/wbi/search/all/v2': {
        'code': 0,
        'data': {
          'result': [
            {
              'result_type': 'media_bangumi',
              'data': [
                {'season_id': 42, 'title': '回退到的结果'},
              ],
            },
          ],
        },
      },
    });
    BiliApi.debugAdapter = adapter;

    final results = await BiliApi.instance.searchBangumi('孤独摇滚', 1);

    expect(results.single.id, '42');
    expect(adapter.requested, contains('/x/web-interface/wbi/search/all/v2'));
  });
}
