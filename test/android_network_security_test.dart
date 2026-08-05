import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  test('Android allows cleartext only for the Small Color service domains', () {
    final manifest = XmlDocument.parse(
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync(),
    );
    final application = manifest.findAllElements('application').single;
    expect(
      application.getAttribute(
        'networkSecurityConfig',
        namespace: 'http://schemas.android.com/apk/res/android',
      ),
      '@xml/network_security_config',
    );

    final config = XmlDocument.parse(
      File('android/app/src/main/res/xml/network_security_config.xml')
          .readAsStringSync(),
    );
    final base = config.findAllElements('base-config').single;
    expect(base.getAttribute('cleartextTrafficPermitted'), 'false');

    final cleartextDomains = <String>{
      for (final domainConfig in config.findAllElements('domain-config'))
        if (domainConfig.getAttribute('cleartextTrafficPermitted') == 'true')
          for (final domain in domainConfig.findElements('domain'))
            domain.innerText.trim(),
    };
    expect(cleartextDomains, {
      'smallcolor.hair',
      'xiaoxiaocomic.top',
      'animewcaip.top',
      'truefruit.tw',
    });
  });
}
