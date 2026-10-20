import 'package:flutter/material.dart';
import 'package:shots_studio/services/openai_compatibility_service.dart';
import 'package:shots_studio/services/snackbar_service.dart';

/// Configuration UI kept separate from Gemini's API-key flow.
class OpenAICompatibleSection extends StatefulWidget {
  const OpenAICompatibleSection({super.key});

  @override
  State<OpenAICompatibleSection> createState() => _OpenAICompatibleSectionState();
}

class _OpenAICompatibleSectionState extends State<OpenAICompatibleSection> {
  final _baseUrlController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _modelController = TextEditingController();
  bool _obscureApiKey = true;
  bool _isLoading = true;
  bool _isFetchingModels = false;
  List<String> _models = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final baseUrl = await OpenAICompatibilityService.getBaseUrl();
    final apiKey = await OpenAICompatibilityService.getApiKey();
    final modelId = await OpenAICompatibilityService.getSelectedModel();
    final models = await OpenAICompatibilityService.getModelsCache();
    if (!mounted) return;
    setState(() {
      _baseUrlController.text = baseUrl;
      _apiKeyController.text = apiKey;
      _modelController.text = modelId;
      _models = models;
      _isLoading = false;
    });
  }

  Future<void> _saveSettings() async {
    await OpenAICompatibilityService.saveConfiguration(
      baseUrl: _baseUrlController.text,
      apiKey: _apiKeyController.text,
      modelId: _modelController.text,
    );
    if (mounted) {
      SnackbarService().showSuccess(context, 'OpenAI-compatible settings saved');
    }
  }

  Future<void> _fetchModels() async {
    if (_isFetchingModels) return;
    setState(() => _isFetchingModels = true);
    try {
      final models = await OpenAICompatibilityService.fetchModels(
        baseUrl: _baseUrlController.text,
        apiKey: _apiKeyController.text,
      );
      await OpenAICompatibilityService.saveModelsCache(models);
      if (!mounted) return;
      setState(() => _models = models);
      if (models.isEmpty) {
        SnackbarService().showWarning(
          context,
          'No models returned. You can still enter a model ID manually.',
        );
      }
    } catch (e) {
      if (mounted) {
        SnackbarService().showError(context, 'Could not fetch models: $e');
      }
    } finally {
      if (mounted) setState(() => _isFetchingModels = false);
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      elevation: 0,
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'OpenAI-compatible endpoint',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Configure any server implementing the OpenAI chat-completions API. '
              'These credentials are stored separately from your Gemini API key.',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _baseUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Base URL',
                hintText: 'https://api.example.com/v1',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _apiKeyController,
              obscureText: _obscureApiKey,
              decoration: InputDecoration(
                labelText: 'API key (optional for local servers)',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: _obscureApiKey ? 'Show API key' : 'Hide API key',
                  icon: Icon(
                    _obscureApiKey ? Icons.visibility : Icons.visibility_off,
                  ),
                  onPressed: () => setState(
                    () => _obscureApiKey = !_obscureApiKey,
                  ),
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _modelController,
              decoration: const InputDecoration(
                labelText: 'Remote model ID',
                hintText: 'e.g. gpt-4o-mini or provider/model-name',
                border: OutlineInputBorder(),
              ),
            ),
            if (_models.isNotEmpty) ...[
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _models.contains(_modelController.text)
                    ? _modelController.text
                    : null,
                decoration: const InputDecoration(
                  labelText: 'Discovered models',
                  border: OutlineInputBorder(),
                ),
                items: _models
                    .map((model) => DropdownMenuItem(
                          value: model,
                          child: Text(model, overflow: TextOverflow.ellipsis),
                        ))
                    .toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _modelController.text = value);
                  }
                },
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _isFetchingModels ? null : _fetchModels,
                  icon: _isFetchingModels
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_isFetchingModels ? 'Loading models…' : 'Fetch models'),
                ),
                FilledButton.icon(
                  onPressed: _modelController.text.trim().isEmpty
                      ? null
                      : _saveSettings,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('Save configuration'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
