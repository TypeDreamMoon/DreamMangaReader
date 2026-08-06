import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class FlutterSecretStore implements SecretStore {
  const FlutterSecretStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

Future<String?> readMigratingSecret({
  required SecretStore secrets,
  required SharedPreferences preferences,
  required String secureKey,
  required Iterable<String> legacyKeys,
}) async {
  try {
    final secure = await secrets.read(secureKey);
    if (secure != null && secure.isNotEmpty) {
      for (final key in legacyKeys) {
        await preferences.remove(key);
      }
      return secure;
    }
  } catch (_) {
    // A legacy value can still keep the current session usable.
  }

  String? legacy;
  for (final key in legacyKeys) {
    final candidate = preferences.getString(key);
    if (candidate != null && candidate.isNotEmpty) {
      legacy = candidate;
      break;
    }
  }
  if (legacy == null) return null;

  try {
    await secrets.write(secureKey, legacy);
    if (await secrets.read(secureKey) == legacy) {
      for (final key in legacyKeys) {
        await preferences.remove(key);
      }
    }
  } catch (_) {
    // Keep plaintext until a verified secure write succeeds on a later load.
  }
  return legacy;
}

Future<void> writeVerifiedSecret({
  required SecretStore secrets,
  required String key,
  required String value,
}) async {
  await secrets.write(key, value);
  if (await secrets.read(key) != value) {
    throw StateError('Secure credential verification failed');
  }
}
