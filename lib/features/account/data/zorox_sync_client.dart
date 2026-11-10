import 'package:dio/dio.dart';

/// The ZoroX sync Worker URL.
///
/// Empty means cloud sync is not set up yet: the account screen says so and
/// offers Export/Import instead. Set it in the app under
/// Settings -> Accounts -> ZoroX Account -> "Sync server" (stored in the
/// settings box, see [ZoroxAccountNotifier.setWorkerUrl]); that stored value
/// wins over this constant, so a deployed Worker URL never needs a rebuild.
///
/// The URL must start with `https://` — the password goes to the Worker and
/// nowhere else, and plain HTTP would send it in the clear.
const String kZoroxSyncWorkerUrl = '';

/// What the sync server answered with, in the user's words.
class ZoroxSyncException implements Exception {
  const ZoroxSyncException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The zorox-sync Worker calls: register, login, upload, download.
///
/// A fresh [Dio] of its own — not the app's shared client — so account calls
/// never pick up a plugin's cookies or DNS overrides. Throws
/// [ZoroxSyncException] with a readable message for anything the server or
/// the network reports.
class ZoroxSyncClient {
  ZoroxSyncClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 30),
              sendTimeout: const Duration(seconds: 30),
              responseType: ResponseType.json,
            ),
          );

  final Dio _dio;

  static void checkBaseUrl(String baseUrl) {
    if (baseUrl.isEmpty) {
      throw const ZoroxSyncException(
        'Cloud sync is not set up yet — set the sync server URL first, or use Export/Import.',
      );
    }
    if (!baseUrl.startsWith('https://')) {
      throw const ZoroxSyncException(
        'The sync server URL must start with https://',
      );
    }
  }

  /// Creates the account and returns the session token.
  Future<String> register(
    String baseUrl,
    String email,
    String password,
  ) async {
    final body = await _post(baseUrl, '/register', {
      'email': email,
      'password': password,
    });
    return _tokenFrom(body);
  }

  /// Logs in and returns the session token.
  Future<String> login(String baseUrl, String email, String password) async {
    final body = await _post(baseUrl, '/login', {
      'email': email,
      'password': password,
    });
    return _tokenFrom(body);
  }

  /// Uploads [backup] (a [ZoroxBackup.toJson] map). Returns the server's
  /// `updatedAt` (unix milliseconds).
  Future<int> upload(
    String baseUrl,
    String token,
    Map<String, dynamic> backup,
  ) async {
    final body = await _post(baseUrl, '/sync', {
      'token': token,
      'backup': backup,
    });
    return (body['updatedAt'] as num?)?.toInt() ?? 0;
  }

  /// Downloads the saved backup, or null when the account has never synced.
  Future<Map<String, dynamic>?> download(String baseUrl, String token) async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        '$baseUrl/backup',
        queryParameters: {'token': token},
      );
      final body = response.data ?? const {};
      if (body['ok'] != true) {
        throw ZoroxSyncException(_serverMessage(body));
      }
      final backup = body['backup'];
      if (backup is! Map) return null;
      return Map<String, dynamic>.from(backup);
    } on ZoroxSyncException {
      rethrow;
    } on DioException catch (e) {
      // A 404 here is not an error: it means "no backup saved yet".
      if (e.response?.statusCode == 404) return null;
      throw ZoroxSyncException(_dioMessage(e));
    }
  }

  /// Ends the session on the server. Best effort: a logout must work even
  /// when the network does not.
  Future<void> logout(String baseUrl, String token) async {
    try {
      await _post(baseUrl, '/logout', {'token': token});
    } catch (_) {
      // The local session is deleted regardless; the token expires in 24h.
    }
  }

  Future<Map<String, dynamic>> _post(
    String baseUrl,
    String path,
    Map<String, dynamic> body,
  ) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        '$baseUrl$path',
        data: body,
      );
      final data = response.data ?? const {};
      if (data['ok'] != true) {
        throw ZoroxSyncException(_serverMessage(data));
      }
      return data;
    } on ZoroxSyncException {
      rethrow;
    } on DioException catch (e) {
      throw ZoroxSyncException(_dioMessage(e));
    }
  }

  static String _tokenFrom(Map<String, dynamic> body) {
    final token = body['token'];
    if (token is! String || token.isEmpty) {
      throw const ZoroxSyncException('The server did not return a session.');
    }
    return token;
  }

  static String _serverMessage(Map<String, dynamic> body) {
    final error = body['error'];
    if (error is String && error.isNotEmpty) return error;
    return 'The sync server answered with an error.';
  }

  static String _dioMessage(DioException e) {
    final data = e.response?.data;
    if (data is Map) {
      final error = data['error'];
      if (error is String && error.isNotEmpty) return error;
    }
    return switch (e.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.sendTimeout ||
      DioExceptionType.receiveTimeout => 'The sync server took too long to answer.',
      DioExceptionType.connectionError => 'Could not reach the sync server. Check your connection.',
      _ => 'Could not reach the sync server.',
    };
  }
}
