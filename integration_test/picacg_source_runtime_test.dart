import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/auth_token.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class PicacgFixtureHttp implements HttpService {
  final requests = <HostRequest>[];

  @override
  Future<HostResponse> fetch(HostRequest request) async {
    requests.add(request);
    final uri = Uri.parse(request.url);
    Object body;

    if (uri.path == '/auth/sign-in') {
      body = {
        'data': {'token': 'fixture-token'},
      };
    } else if (uri.path == '/comics/advanced-search') {
      body = {
        'data': {
          'comics': {
            'docs': [_comic],
          },
        },
      };
    } else if (uri.path == '/comics/comic-1') {
      body = {
        'data': {'comic': _comic},
      };
    } else if (uri.path == '/comics/comic-1/eps') {
      final page = int.parse(uri.queryParameters['page']!);
      body = {
        'data': {
          'eps': {
            'page': page,
            'pages': 2,
            'docs': [
              {'order': page, 'title': '第$page话'},
            ],
          },
        },
      };
    } else if (uri.path == '/comics/comic-1/order/1/pages') {
      final page = int.parse(uri.queryParameters['page']!);
      body = {
        'data': {
          'pages': {
            'page': page,
            'pages': 2,
            'limit': 2,
            'docs': page == 1
                ? [
                    {
                      'media': {
                        'fileServer': 'https://img.test',
                        'path': '0.jpg',
                      },
                    },
                    {
                      'media': {
                        'fileServer': 'https://img.test',
                        'path': '1.jpg',
                      },
                    },
                  ]
                : [
                    {
                      'media': {
                        'fileServer': 'https://img.test',
                        'path': '2.jpg',
                      },
                    },
                  ],
          },
        },
      };
    } else {
      throw StateError('Unexpected Picacg fixture request: ${request.url}');
    }

    return HostResponse(
      status: 200,
      headers: const {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
  }
}

const _comic = {
  '_id': 'comic-1',
  'title': '测试漫画',
  'author': '测试作者',
  'description': '测试简介',
  'thumb': {'fileServer': 'https://img.test', 'path': 'cover.jpg'},
  'categories': ['分类'],
  'tags': ['标签'],
  'finished': false,
};

/// 用**真实的 picacg 源脚本**跑一遍登录 + 分页集合(响应用 fixture,不联网)。
///
/// 引擎仓库不携带任何源脚本,脚本在外部源仓库里 —— 路径由 `DMR_PICACG_SCRIPT`
/// 指定,没配或文件不在就跳过(否则这条用例只在写它那台机器上能过)。
///
/// 运行:
///   flutter test integration_test/picacg_source_runtime_test.dart -d windows \
///     `--dart-define=DMR_PICACG_SCRIPT=picacg.js 的绝对路径`
const _scriptPathDefine = String.fromEnvironment('DMR_PICACG_SCRIPT');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final scriptPath = _scriptPathDefine.isNotEmpty
      ? _scriptPathDefine
      : Platform.environment['DMR_PICACG_SCRIPT'] ?? '';
  final scriptFile = scriptPath.isEmpty ? null : File(scriptPath);
  final skipReason = scriptFile == null || !scriptFile.existsSync()
      ? '未配置 DMR_PICACG_SCRIPT(指向外部源仓库的 picacg.js)'
      : null;

  test('real Picacg script runs through QuickJS login and continuation',
      () async {
    final script = scriptFile!.readAsStringSync();
    final http = PicacgFixtureHttp();
    final source = ScriptSource(
      engine: JsEngine(),
      http: http,
      scriptCode: script,
    );
    addTearDown(() {
      SourceAuth.set('picacg', null);
      source.dispose();
    });

    final login = await source.login('reader@example.test', 'fixture-password');
    SourceAuth.set(source.id, login.token);
    final search = await source.getSearch('测试', 1);
    final detail = await source.getMangaDetail('comic-1');
    final chapters = await source.getChapters('comic-1');
    final pages = await source.getPages('comic-1', '1');

    expect(source.id, 'picacg');
    expect(source.nsfw, true);
    expect(login.token, 'fixture-token');
    expect(search.items.single.id, 'comic-1');
    expect(detail.title, '测试漫画');
    expect(chapters.items.map((chapter) => chapter.id), ['1', '2']);
    expect(pages.map((page) => page.index), [0, 1, 2]);
    expect(
      http.requests.every(
        (request) => RegExp(r'^[0-9a-f]{64}$')
            .hasMatch(request.headers['signature'] ?? ''),
      ),
      true,
    );
    expect(
      http.requests
          .where((request) => !request.url.endsWith('/auth/sign-in'))
          .every(
            (request) => request.headers['authorization'] == 'fixture-token',
          ),
      true,
    );
  }, skip: skipReason);
}
