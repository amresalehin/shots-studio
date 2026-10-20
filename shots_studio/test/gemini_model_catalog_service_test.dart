import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shots_studio/services/gemini_model_catalog_service.dart';
import 'package:shots_studio/utils/ai_provider_config.dart';

void main() {
  group('GeminiModelCatalogService', () {
    test('uses baseModelId and filters unsupported/non-Gemini models', () {
      final models = GeminiModelCatalogService.parseModelsResponse({
        'models': [
          {
            'name': 'models/gemini-2.5-flash-001',
            'baseModelId': 'gemini-2.5-flash',
            'displayName': 'Gemini 2.5 Flash',
            'description': 'Fast multimodal model',
            'inputTokenLimit': 1000000,
            'outputTokenLimit': 8192,
            'supportedGenerationMethods': ['generateContent', 'countTokens'],
          },
          {
            'name': 'models/gemini-embedding-001',
            'baseModelId': 'gemini-embedding-001',
            'supportedGenerationMethods': ['embedContent'],
          },
          {
            'name': 'models/gemma-3-27b-it',
            'baseModelId': 'gemma-3-27b-it',
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/gemini-tuning-test',
            'baseModelId': 'gemini-tuning-test',
            'supportedGenerationMethods': ['countTokens'],
          },
        ],
      });

      expect(models, hasLength(1));
      expect(models.single.id, 'gemini-2.5-flash');
      expect(models.single.displayName, 'Gemini 2.5 Flash');
      expect(models.single.inputTokenLimit, 1000000);
      expect(models.single.outputTokenLimit, 8192);
    });

    test('deduplicates versioned entries with the same base model ID', () {
      final models = GeminiModelCatalogService.parseModelsResponse({
        'models': [
          {
            'name': 'models/gemini-2.5-flash-001',
            'baseModelId': 'gemini-2.5-flash',
            'displayName': 'Gemini 2.5 Flash',
            'supportedGenerationMethods': ['generateContent'],
          },
          {
            'name': 'models/gemini-2.5-flash-latest',
            'baseModelId': 'gemini-2.5-flash',
            'displayName': 'Gemini 2.5 Flash latest',
            'supportedGenerationMethods': ['generateContent'],
          },
        ],
      });

      expect(models, hasLength(1));
      expect(models.single.id, 'gemini-2.5-flash');
    });

    test('recognizes unseen Gemini model IDs as remote Gemini models', () {
      expect(AIProviderConfig.getProviderForModel('gemini-3-flash'), 'gemini');
      expect(AIProviderConfig.requiresApiKey('gemini-3-flash'), isTrue);
      expect(AIProviderConfig.getMaxCategorizationLimitForModel('gemini-3-flash'), 50);
    });

    test('fetches every catalog page and caches supported model IDs', () async {
      SharedPreferences.setMockInitialValues({});
      var requestCount = 0;
      final client = MockClient((http.Request request) async {
        requestCount++;
        if (request.url.queryParameters['pageToken'] == null) {
          return http.Response(
            jsonEncode({
              'models': [
                {
                  'name': 'models/gemini-2.5-flash-001',
                  'baseModelId': 'gemini-2.5-flash',
                  'supportedGenerationMethods': ['generateContent'],
                },
              ],
              'nextPageToken': 'page-two',
            }),
            200,
          );
        }

        return http.Response(
          jsonEncode({
            'models': [
              {
                'name': 'models/gemini-2.5-pro',
                'baseModelId': 'gemini-2.5-pro',
                'supportedGenerationMethods': ['generateContent'],
              },
            ],
          }),
          200,
        );
      });

      final models = await GeminiModelCatalogService.refreshModels(
        apiKey: 'test-key',
        client: client,
      );
      final cached = await GeminiModelCatalogService.getCachedModelIds();
      client.close();

      expect(requestCount, 2);
      expect(models.map((model) => model.id).toList(), [
        'gemini-2.5-flash',
        'gemini-2.5-pro',
      ]);
      expect(cached, [
        'gemini-2.5-flash',
        'gemini-2.5-pro',
      ]);
    });

    test('builds a paginated URL and safely encodes the API key', () {
      final uri = GeminiModelCatalogService.buildModelsUri(
        apiKey: 'key+with/slash',
        pageToken: 'next page/token',
      );

      expect(uri.path, '/v1beta/models');
      expect(uri.queryParameters['key'], 'key+with/slash');
      expect(uri.queryParameters['pageSize'], '1000');
      expect(uri.queryParameters['pageToken'], 'next page/token');
    });
  });
}
