import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shots_studio/services/logger_service.dart';

/// Owns configuration and model discovery for any OpenAI-compatible endpoint.
class OpenAICompatibilityService {
  static const String baseUrlPrefKey = 'openai_compatible_base_url';
  static const String apiKeyPrefKey = 'openai_compatible_api_key';
  static const String selectedModelPrefKey = 'openai_compatible_selected_model';
  static const String modelsCachePrefKey = 'openai_compatible_models_cache';

  static const String defaultBaseUrl = 'http://localhost:11434/v1';

  /// Persist a model list returned by the configured endpoint.
  static Future<void> saveModelsCache(List<String> models) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(modelsCachePrefKey, models);
  }

  static Future<List<String>> getModelsCache() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(modelsCachePrefKey) ?? [];
  }

  static Future<String> getBaseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return normalizeBaseUrl(prefs.getString(baseUrlPrefKey) ?? defaultBaseUrl);
  }

  static Future<String> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(apiKeyPrefKey) ?? '';
  }

  static Future<String> getSelectedModel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(selectedModelPrefKey) ?? '';
  }

  static Future<void> saveConfiguration({
    required String baseUrl,
    required String apiKey,
    required String modelId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(baseUrlPrefKey, normalizeBaseUrl(baseUrl));
    await prefs.setString(apiKeyPrefKey, apiKey.trim());
    await prefs.setString(selectedModelPrefKey, modelId.trim());
  }

  static String normalizeBaseUrl(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) {
      return defaultBaseUrl;
    }

    var normalized = trimmed;
    if (!normalized.startsWith('http://') &&
        !normalized.startsWith('https://')) {
      // Keep localhost/private-network endpoints usable without requiring
      // users to type a scheme; public endpoints can use HTTPS explicitly.
      final isLocal = normalized.startsWith('localhost') ||
          normalized.startsWith('127.0.0.1') ||
          normalized.startsWith('10.') ||
          normalized.startsWith('192.168.') ||
          RegExp(r'^172\.(1[6-9]|2[0-9]|3[0-1])\.').hasMatch(normalized);
      normalized = '${isLocal ? 'http' : 'https'}://$normalized';
    }

    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }

    return normalized;
  }

  static Uri buildModelsUri(String baseUrl) {
    final normalized = normalizeBaseUrl(baseUrl);
    if (normalized.endsWith('/v1')) {
      return Uri.parse('$normalized/models');
    }

    return Uri.parse('$normalized/v1/models');
  }

  static Uri buildChatCompletionsUri(String baseUrl) {
    final normalized = normalizeBaseUrl(baseUrl);
    if (normalized.endsWith('/v1')) {
      return Uri.parse('$normalized/chat/completions');
    }

    return Uri.parse('$normalized/v1/chat/completions');
  }

  static Future<List<String>> fetchModels({
    required String baseUrl,
    String? apiKey,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final headers = <String, String>{'Content-Type': 'application/json'};
    final trimmedApiKey = (apiKey ?? '').trim();
    if (trimmedApiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $trimmedApiKey';
    }

    try {
      final primaryModels = await _fetchFromOpenaiUrls(
        baseUrl: baseUrl,
        headers: headers,
        timeout: timeout,
      );
      if (primaryModels.isNotEmpty) {
        return primaryModels;
      }
    } catch (e) {
      LoggerService.error('Primary models endpoint fetch failed', e);
    }

    try {
      return await _fetchFromOllamaTags(
        baseUrl: baseUrl,
        headers: headers,
        timeout: timeout,
      );
    } catch (e) {
      LoggerService.error('Fallback tags endpoint model fetch failed', e);
      return [];
    }
  }

  static Future<List<String>> _fetchFromOpenaiUrls({
    required String baseUrl,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final response =
        await http.get(buildModelsUri(baseUrl), headers: headers).timeout(timeout);
    if (response.statusCode != 200) {
      return [];
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['data'] is! List) {
      return [];
    }

    return (decoded['data'] as List)
        .whereType<Map>()
        .map((item) => item['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  static Future<List<String>> _fetchFromOllamaTags({
    required String baseUrl,
    required Map<String, String> headers,
    required Duration timeout,
  }) async {
    final normalized = normalizeBaseUrl(baseUrl);
    final origin = normalized.replaceFirst(RegExp(r'/v1$'), '');
    final tagsUri = Uri.parse('$origin/api/tags');

    final response = await http.get(tagsUri, headers: headers).timeout(timeout);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch models (status: ${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['models'] is! List) {
      return [];
    }

    return (decoded['models'] as List)
        .whereType<Map>()
        .map((item) => item['name']?.toString() ?? '')
        .where((name) => name.isNotEmpty)
        .toList();
  }
}
