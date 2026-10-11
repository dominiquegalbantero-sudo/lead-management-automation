import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  static const _stages = ['New', 'Qualified', 'Proposal', 'Won', 'Lost'];

  final _spreadsheetController = TextEditingController();
  Timer? _connectionPoll;
  List<Map<String, dynamic>> _leads = [];
  String? _loadError;
  String? _connectionError;
  bool _loadingLeads = true;
  bool _connectingSheet = false;
  bool _sheetConnected = false;
  bool _checkingConnection = false;
  bool _updatingStage = false;

  SupabaseClient get _supabase => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    unawaited(_loadLeads());
    unawaited(_loadSheetConnection());
  }

  @override
  void dispose() {
    _connectionPoll?.cancel();
    _spreadsheetController.dispose();
    super.dispose();
  }

  Future<void> _loadLeads() async {
    setState(() {
      _loadingLeads = true;
      _loadError = null;
    });
    try {
      final data = await _supabase
          .from('leads')
          .select(
            'id, external_id, name, email, company, source, stage, created_at, updated_at',
          )
          .order('updated_at', ascending: false)
          .limit(200);
      if (!mounted) return;
      setState(() {
        _leads = List<Map<String, dynamic>>.from(data);
        _loadingLeads = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingLeads = false;
        _loadError = 'Could not load leads: $error';
      });
    }
  }

  Future<bool> _loadSheetConnection({bool reportErrors = true}) async {
    if (_checkingConnection) return _sheetConnected;
    _checkingConnection = true;
    try {
      final response = await _supabase.functions.invoke(
        'google-auth',
        method: HttpMethod.get,
      );
      if (response.status < 200 || response.status >= 300) {
        throw _functionError(response);
      }
      final data = Map<String, dynamic>.from(response.data as Map);
      final connected = data['connected'] == true;
      if (!mounted) return connected;
      setState(() {
        _sheetConnected = connected;
        _connectionError = null;
        final sheetId = data['spreadsheet_id'];
        if (sheetId is String && sheetId.isNotEmpty) {
          _spreadsheetController.text = sheetId;
        }
      });
      if (connected) _connectionPoll?.cancel();
      return connected;
    } catch (error) {
      if (mounted && reportErrors) {
        setState(
          () => _connectionError = 'Could not check Sheets connection: $error',
        );
      }
      return false;
    } finally {
      _checkingConnection = false;
    }
  }

  Future<void> _connectSheet() async {
    final spreadsheetId = _spreadsheetController.text.trim();
    if (spreadsheetId.isEmpty) {
      setState(
        () => _connectionError = 'Enter the spreadsheet ID from its URL.',
      );
      return;
    }

    setState(() {
      _connectingSheet = true;
      _connectionError = null;
    });
    try {
      final response = await _supabase.functions.invoke(
        'google-auth',
        body: {'spreadsheet_id': spreadsheetId},
      );
      if (response.status < 200 || response.status >= 300) {
        throw _functionError(response);
      }

      final data = Map<String, dynamic>.from(response.data as Map);
      final authorizationUrl = data['authorization_url'];
      if (authorizationUrl is! String) {
        throw const FormatException(
          'Google authorization URL was missing from the response.',
        );
      }
      final uri = Uri.parse(authorizationUrl);
      if (!await launchUrl(
        uri,
        mode: kIsWeb
            ? LaunchMode.platformDefault
            : LaunchMode.externalApplication,
        webOnlyWindowName: kIsWeb ? '_blank' : null,
      )) {
        throw StateError('Could not open Google authorization in a browser.');
      }

      _showMessage(
        'Finish Google sign-in in the browser. This page will check the connection.',
      );
      _startConnectionPolling();
    } catch (error) {
      if (mounted) {
        setState(
          () => _connectionError = 'Could not start Google sign-in: $error',
        );
      }
    } finally {
      if (mounted) setState(() => _connectingSheet = false);
    }
  }

  void _startConnectionPolling() {
    _connectionPoll?.cancel();
    var attempts = 0;
    _connectionPoll = Timer.periodic(const Duration(seconds: 4), (timer) async {
      attempts++;
      if (await _loadSheetConnection(reportErrors: false)) {
        timer.cancel();
        if (mounted) _showMessage('Google Sheets is connected.');
      } else if (attempts >= 45) {
        timer.cancel();
        if (mounted) {
          _showMessage(
            'Connection check timed out. Tap Refresh to check again.',
          );
        }
      }
    });
  }

  Object _functionError(FunctionResponse response) {
    final data = response.data;
    if (data is Map && data['error'] is String) {
      return StateError(data['error'] as String);
    }
    return StateError('Request failed with status ${response.status}.');
  }

  Future<void> _updateStage(Map<String, dynamic> lead, String stage) async {
    setState(() => _updatingStage = true);
    try {
      await _supabase
          .from('leads')
          .update({'stage': stage})
          .eq('id', lead['id']);
      await _loadLeads();
    } catch (error) {
      if (mounted) _showMessage('Could not update deal stage: $error');
    } finally {
      if (mounted) setState(() => _updatingStage = false);
    }
  }

  Future<void> _signOut() async {
    try {
      await _supabase.auth.signOut();
    } catch (error) {
      if (mounted) _showMessage('Could not sign out: $error');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final email = _supabase.auth.currentUser?.email ?? 'Account';

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Lead Management',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Center(child: Text(email)),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            children: [
              Text(
                'Dashboard',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Manage incoming leads and connect your Google Sheet.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              _sheetCard(theme),
              const SizedBox(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Leads',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Refresh leads',
                    onPressed: _loadingLeads ? null : _loadLeads,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_loadingLeads)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_loadError != null)
                _ErrorPanel(message: _loadError!, onRetry: _loadLeads)
              else if (_leads.isEmpty)
                const _EmptyLeads()
              else
                ..._leads.map(
                  (lead) => _LeadCard(
                    lead: lead,
                    stages: _stages,
                    updating: _updatingStage,
                    onStageChanged: (stage) => _updateStage(lead, stage),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetCard(ThemeData theme) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.table_chart_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Google Sheets',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh connection status',
                  onPressed: _checkingConnection
                      ? null
                      : () => _loadSheetConnection(),
                  icon: const Icon(Icons.refresh),
                ),
                Icon(
                  _sheetConnected ? Icons.check_circle : Icons.circle_outlined,
                  color: _sheetConnected ? Colors.green.shade700 : null,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              _sheetConnected
                  ? 'Connected. Lead updates are queued for automatic sync.'
                  : 'Connect a spreadsheet to sync incoming and updated leads.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _spreadsheetController,
              enabled: !_connectingSheet,
              decoration: const InputDecoration(
                labelText: 'Google spreadsheet ID',
                hintText: 'Paste the ID from the Google Sheets URL',
                helperText:
                    'In docs.google.com/spreadsheets/d/<ID>/edit, copy <ID>.',
                border: OutlineInputBorder(),
              ),
            ),
            if (_connectionError != null) ...[
              const SizedBox(height: 10),
              _ErrorPanel(message: _connectionError!),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _connectingSheet ? null : _connectSheet,
              icon: _connectingSheet
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.login),
              label: Text(
                _connectingSheet
                    ? 'Starting Google sign-in...'
                    : _sheetConnected
                    ? 'Reconnect Google account'
                    : 'Connect with Google',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LeadCard extends StatelessWidget {
  const _LeadCard({
    required this.lead,
    required this.stages,
    required this.updating,
    required this.onStageChanged,
  });

  final Map<String, dynamic> lead;
  final List<String> stages;
  final bool updating;
  final ValueChanged<String> onStageChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stage = lead['stage'] as String? ?? 'New';
    final availableStages = stages.contains(stage)
        ? stages
        : [...stages, stage];

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    lead['name'] as String? ?? 'Unnamed lead',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                DropdownButton<String>(
                  value: stage,
                  onChanged: updating
                      ? null
                      : (value) {
                          if (value != null && value != stage) {
                            onStageChanged(value);
                          }
                        },
                  items: availableStages
                      .map(
                        (value) =>
                            DropdownMenuItem(value: value, child: Text(value)),
                      )
                      .toList(),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SelectableText(lead['email'] as String? ?? ''),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 6,
              children: [
                _LeadAttribute(
                  icon: Icons.business_outlined,
                  label: lead['company'] as String? ?? '',
                ),
                _LeadAttribute(
                  icon: Icons.language,
                  label: lead['source'] as String? ?? '',
                ),
                _LeadAttribute(
                  icon: Icons.tag,
                  label: lead['external_id'] as String? ?? '',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LeadAttribute extends StatelessWidget {
  const _LeadAttribute({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 5),
        Text(label),
      ],
    );
  }
}

class _EmptyLeads extends StatelessWidget {
  const _EmptyLeads();

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          children: [
            const Icon(Icons.people_outline, size: 36),
            const SizedBox(height: 10),
            Text(
              'No leads yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            const Text('Signed leads will appear here when received.'),
          ],
        ),
      ),
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(child: SelectableText(message)),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
