import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A Gemini API model that supports content generation.
class GeminiCatalogModel {
  final String id;
  final String displayName;
  final String description;
  final int? inputTokenLimit;
  final int? outputTokenLimit;

  const GeminiCatalogModel({
    required this.id,
    required this.displayName,
    required this.description,
    this.inputTokenLimit,
    this.outputTokenLimit,
  });
}

/// Fetches and caches the models actually exposed by the configured Gemini API
/// key. The picker can still use its built-in fallback list before a refresh.
class GeminiModelCatalogService {
  static const String _modelsEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';
  static const String _cachedIdsKey = 'gemini_model_catalog_ids';
  static const String _cachedAtKey = 'gemini_model_catalog_fetched_at';
  static const int _pageSize = 1000;
  static const int _maxPages = 20;

  /// Builds the official models.list URL, preserving page tokens and encoding
  /// API keys safely as query parameters.
  static Uri buildModelsUri({
    required String apiKey,
    String? pageToken,
  }) {
    return Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models',
      <String, String>{
        'key': apiKey.trim(),
        'pageSize': '$_pageSize',
        if (pageToken != null && pageToken.isNotEmpty) 'pageToken': pageToken,
      },
    );
  }

  /// Downloads all pages and stores the IDs of Gemini models that implement
  /// generateContent. Other API resources (for example, embedding models and
  /// hosted Gemma variants) are excluded because this app routes those models
  /// to different providers.
  static Future<List<GeminiCatalogModel>> refreshModels({
    required String apiKey,
    Duration timeout = const Duration(seconds: 15),
    http.Client? client,
  }) async {
    final trimmedKey = apiKey.trim();
    if (trimmedKey.isEmpty) {
      throw const GeminiModelCatalogException(
        'Enter a Gemini API key before refreshing the model catalog.',
      );
    }

    final ownsClient = client == null;
    final httpClient = client ?? http.Client();
    final modelsById = <String, GeminiCatalogModel>{};
    final seenPageTokens = <String>{};
    String? pageToken;

    try {
      for (var page = 0; page < _maxPages; page++) {
        final response = await httpClient
            .get(buildModelsUri(apiKey: trimmedKey, pageToken: pageToken))
            .timeout(timeout);

        if (response.statusCode != 200) {
          throw GeminiModelCatalogException(
            _extractApiError(response.body) ??
                'Gemini API returned HTTP ${response.statusCode}.',
          );
        }

        dynamic decoded;
        try {
          decoded = jsonDecode(response.body);
        } on FormatException {
          throw const GeminiModelCatalogException(
            'Gemini API returned invalid JSON while listing models.',
          );
        }

        if (decoded is! Map<String, dynamic>) {
          throw const GeminiModelCatalogException(
            'Gemini API returned an unexpected model catalog response.',
          );
        }

        for (final model in parseModelsResponse(decoded)) {
          modelsById.putIfAbsent(model.id, () => model);
        }

        final nextToken = decoded['nextPageToken']?.toString().trim() ?? '';
        if (nextToken.isEmpty || !seenPageTokens.add(nextToken)) {
          break;
        }
        pageToken = nextToken;
      }
    } finally {
      if (ownsClient) {
        httpClient.close();
      }
    }

    final models = modelsById.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    if (models.isEmpty) {
      throw const GeminiModelCatalogException(
        'No Gemini models supporting generateContent were returned for this API key.',
      );
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _cachedIdsKey,
      models.map((model) => model.id).toList(),
    );
    await prefs.setString(_cachedAtKey, DateTime.now().toIso8601String());

    return models;
  }

  /// Parses one models.list response and returns only supported Gemini models.
  /// The API's baseModelId is preferred because it is the model ID intended
  /// for generation requests; resource names are used as a fallback.
  static List<GeminiCatalogModel> parseModelsResponse(
    Map<String, dynamic> response,
  ) {
    final rawModels = response['models'];
    if (rawModels is! List) {
      return const <GeminiCatalogModel>[];
    }

    final modelsById = <String, GeminiCatalogModel>{};
    for (final rawModel in rawModels) {
      if (rawModel is! Map) continue;

      final methods = rawModel['supportedGenerationMethods'];
      if (methods is! List ||
          !methods.map((method) => method.toString()).contains('generateContent')) {
        continue;
      }

      final resourceName = rawModel['name']?.toString().trim() ?? '';
      final baseModelId = rawModel['baseModelId']?.toString().trim() ?? '';
      var id = baseModelId.isNotEmpty ? baseModelId : resourceName;
      if (id.startsWith('models/')) {
        id = id.substring('models/'.length);
      }

      // Gemma hosted models are not interchangeable with this app's local
      // Gemma provider, so keep this catalog scoped to Gemini model IDs.
      if (!id.toLowerCase().startsWith('gemini-')) continue;

      modelsById.putIfAbsent(
        id,
        () => GeminiCatalogModel(
          id: id,
          displayName: rawModel['displayName']?.toString().trim().isNotEmpty == true
              ? rawModel['displayName'].toString().trim()
              : id,
          description: rawModel['description']?.toString() ?? '',
          inputTokenLimit: _readInt(rawModel['inputTokenLimit']),
          outputTokenLimit: _readInt(rawModel['outputTokenLimit']),
        ),
      );
    }

    return modelsById.values.toList();
  }

  static int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static String? _extractApiError(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final error = decoded['error'];
        if (error is Map && error['message'] != null) {
          return error['message'].toString();
        }
      }
    } catch (_) {
      // Fall through to the HTTP status message.
    }
    return null;
  }

  /// IDs are cached separately from metadata so the model picker can read them
  /// with SharedPreferences without making a network request.
  static Future<List<String>> getCachedModelIds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_cachedIdsKey) ?? const <String>[];
  }

  static Future<DateTime?> getLastRefreshTime() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_cachedAtKey);
    return value == null ? null : DateTime.tryParse(value);
  }

  static Future<void> clearCache() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cachedIdsKey);
    await prefs.remove(_cachedAtKey);
  }
}

class GeminiModelCatalogException implements Exception {
  final String message;

  const GeminiModelCatalogException(this.message);

  @override
  String toString() => message;
}
