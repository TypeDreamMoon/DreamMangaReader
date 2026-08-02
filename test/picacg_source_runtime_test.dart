import 'dart:convert';
import 'dart:io';

import 'package:dream_manga_reader/core/script/js_engine.dart';
import 'package:dream_manga_reader/core/script/script_source.dart';
import 'package:dream_manga_reader/core/source/auth_token.dart';
import 'package:dream_manga_reader/core/source/source.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real Picacg script runs through QuickJS login and continuation',
      () async {
    final script = File(
      r'D:\UnrealMap\DreamMangaReader-Source\picacg.js',
    ).readAsStringSync();
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
  });
}
