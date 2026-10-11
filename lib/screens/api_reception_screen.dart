import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';

class ApiReceptionScreen extends StatelessWidget {
  const ApiReceptionScreen({super.key});

  static const _payload = '''{
  "id": "partner-123",
  "name": "Alex Example",
  "email": "alex@example.com",
  "company": "Example Co",
  "source": "partner-site"
}''';

  static const _signingExample = '''import { createHmac } from "node:crypto";

const endpoint = process.env.LEAD_ENDPOINT;
const lead = {
  id: "partner-123",
  name: "Alex Example",
  email: "alex@example.com",
  company: "Example Co",
  source: "partner-site",
};
const timestamp = Math.floor(Date.now() / 1000).toString();
const rawBody = JSON.stringify(lead);
const signature = createHmac("sha256", process.env.LEAD_WEBHOOK_SECRET)
  .update(`\${timestamp}.\${rawBody}`, "utf8")
  .digest("hex");

await fetch(endpoint, {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "x-lead-timestamp": timestamp,
    "x-lead-signature": `sha256=\${signature}`,
  },
  body: rawBody,
});''';

  String get _endpoint => AppConfig.leadEndpoint.isEmpty
      ? 'https://<project-ref>.supabase.co/functions/v1/receive-lead'
      : AppConfig.leadEndpoint;

  Future<void> _copy(BuildContext context, String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$label copied')));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConfigured = AppConfig.isSupabaseConfigured;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Lead Management',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 20),
            child: Icon(Icons.hub_outlined),
          ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
            children: [
              Text('Integrations', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(
                'Lead API reception',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Receive authenticated leads from your partner website. '
                'The API runs on Supabase Edge Functions; this page shows '
                'the endpoint and the steps to connect your partner.',
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              _SectionCard(
                title: 'Endpoint',
                subtitle: 'Send one JSON lead per POST request.',
                trailing: IconButton(
                  tooltip: 'Copy endpoint URL',
                  onPressed: () => _copy(context, _endpoint, 'Endpoint URL'),
                  icon: const Icon(Icons.copy_outlined),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CodeBlock(text: _endpoint),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Icon(
                          isConfigured
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          size: 18,
                          color: isConfigured
                              ? Colors.green.shade700
                              : theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isConfigured
                                ? 'Supabase project is configured for this app.'
                                : 'Set SUPABASE_URL and '
                                      'SUPABASE_PUBLISHABLE_KEY when launching '
                                      'to enable sign-in and show your endpoint.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Required lead fields',
                subtitle: 'All fields are required. Email is normalized before matching.',
                child: const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _FieldChip(label: 'id'),
                    _FieldChip(label: 'name'),
                    _FieldChip(label: 'email'),
                    _FieldChip(label: 'company'),
                    _FieldChip(label: 'source'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Example request body',
                subtitle: 'Send this JSON as the exact raw request body.',
                trailing: IconButton(
                  tooltip: 'Copy example JSON',
                  onPressed: () => _copy(context, _payload, 'Example JSON'),
                  icon: const Icon(Icons.copy_outlined),
                ),
                child: const _CodeBlock(text: _payload),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Signature verification',
                subtitle:
                    'Every request must have a valid HMAC-SHA256 signature '
                    'and a Unix timestamp no more than 5 minutes old.',
                trailing: IconButton(
                  tooltip: 'Copy Node.js signing example',
                  onPressed: () =>
                      _copy(context, _signingExample, 'Signing example'),
                  icon: const Icon(Icons.copy_outlined),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _InfoRow(
                      label: 'X-Lead-Timestamp',
                      description: 'Current Unix time in seconds',
                    ),
                    SizedBox(height: 8),
                    _InfoRow(
                      label: 'X-Lead-Signature',
                      description: 'sha256=<hex HMAC digest>',
                    ),
                    SizedBox(height: 12),
                    _CodeBlock(text: _signingExample),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Keep the signing secret private',
                subtitle:
                    'The secret is intentionally not shown or stored in this '
                    'app. Configure the same secret in Supabase and your '
                    'partner’s server environment.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _CodeBlock(
                      text:
                          'npx supabase secrets set '
                          'LEAD_WEBHOOK_SECRET="<long-random-secret>"',
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Never put the secret in browser code, a mobile app, or '
                      'a request from the partner’s client browser. Sign the '
                      'request on a trusted server.',
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const _SectionCard(
                title: 'Duplicate handling',
                subtitle:
                    'The database prevents duplicate records and applies '
                    'these matching rules automatically.',
                child: Column(
                  children: [
                    _RuleRow(
                      icon: Icons.fingerprint,
                      text: 'A repeated partner ID updates its existing lead.',
                    ),
                    SizedBox(height: 12),
                    _RuleRow(
                      icon: Icons.alternate_email,
                      text:
                          'An existing email updates that lead instead of '
                          'creating another record.',
                    ),
                    SizedBox(height: 12),
                    _RuleRow(
                      icon: Icons.lock_outline,
                      text:
                          'Invalid signatures and expired timestamps are '
                          'rejected before the database is changed.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Before sending leads',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              const _ChecklistRow(
                text: 'Apply supabase/schema.sql to your Supabase project.',
              ),
              const _ChecklistRow(
                text: 'Deploy the receive-lead Edge Function.',
              ),
              const _ChecklistRow(
                text: 'Set LEAD_WEBHOOK_SECRET in Supabase and the partner server.',
              ),
              const _ChecklistRow(
                text: 'Share the endpoint URL and signature format with the partner.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.child,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
      ),
      child: SelectableText(
        text,
        style: const TextStyle(
          color: Color(0xFFE5EDF9),
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.55,
        ),
      ),
    );
  }
}

class _FieldChip extends StatelessWidget {
  const _FieldChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.data_object, size: 16),
      label: Text(label),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.description});

  final String label;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 180,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
            ),
          ),
        ),
        Expanded(child: Text(description, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}

class _RuleRow extends StatelessWidget {
  const _RuleRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    );
  }
}

class _ChecklistRow extends StatelessWidget {
  const _ChecklistRow({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.check_circle_outline,
            size: 19,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}
