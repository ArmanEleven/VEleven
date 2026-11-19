import 'dart:convert';

import 'package:defyx_vpn/core/data/local/secure_storage/secure_storage.dart';
import 'package:defyx_vpn/modules/core/vpn_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class V2RayScreen extends ConsumerStatefulWidget {
  const V2RayScreen({super.key});

  @override
  ConsumerState<V2RayScreen> createState() => _V2RayScreenState();
}

class _V2RayScreenState extends ConsumerState<V2RayScreen> {
  static const _storageKey = 'veleven_v2ray_profiles_v1';
  final _nameController = TextEditingController();
  final _configController = TextEditingController();
  List<Map<String, String>> _profiles = [];
  bool _loading = true;
  bool _connecting = false;

  bool get _isPersian =>
      Localizations.localeOf(context).languageCode.toLowerCase() == 'fa';

  @override
  void initState() {
    super.initState();
    _loadProfiles();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _configController.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    try {
      final raw = await ref.read(secureStorageProvider).read(_storageKey);
      final decoded = raw == null ? <dynamic>[] : jsonDecode(raw) as List<dynamic>;
      final profiles = decoded
          .whereType<Map>()
          .map((item) => {
                'id': item['id']?.toString() ?? '',
                'name': item['name']?.toString() ?? 'V2Ray',
                'configJson': item['configJson']?.toString() ?? '',
              })
          .where((item) => item['id']!.isNotEmpty && item['configJson']!.isNotEmpty)
          .toList();
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      if (mounted) _showMessage(_isPersian ? 'خواندن فهرست سرورها ناموفق بود.' : 'Could not read the server list.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveProfiles() async {
    await ref.read(secureStorageProvider).write(_storageKey, jsonEncode(_profiles));
  }

  Map<String, dynamic> _buildXrayConfig(String input) {
    final raw = input.trim();
    if (raw.startsWith('vless://')) {
      return _buildVlessConfig(Uri.parse(raw));
    }
    if (raw.startsWith('vmess://')) {
      final encoded = raw.substring('vmess://'.length).split('#').first;
      final normalized = base64Url.normalize(encoded);
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid VMess payload');
      }
      return _buildVmessConfig(decoded);
    }

    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded['outbounds'] is! List ||
        (decoded['outbounds'] as List).isEmpty) {
      throw const FormatException('Invalid Xray config');
    }
    _ensureTunInbound(decoded);
    return decoded;
  }

  Map<String, dynamic> _buildVlessConfig(Uri uri) {
    final query = uri.queryParameters;
    final network = query['type'] ?? 'tcp';
    final security = query['security'] ?? 'none';
    final userId = Uri.decodeComponent(uri.userInfo);
    if (userId.isEmpty || uri.host.isEmpty || uri.port <= 0) {
      throw const FormatException('Invalid VLESS link');
    }

    final stream = <String, dynamic>{
      'network': network,
      'security': security,
    };
    if (security == 'tls') {
      stream['tlsSettings'] = {
        'serverName': query['sni'] ?? query['serverName'] ?? uri.host,
        'allowInsecure': false,
        if (query['fp'] != null) 'fingerprint': query['fp'],
        if (query['alpn'] != null) 'alpn': query['alpn']!.split(','),
      };
    } else if (security == 'reality') {
      stream['realitySettings'] = {
        'serverName': query['sni'] ?? uri.host,
        'fingerprint': query['fp'] ?? 'chrome',
        if (query['pbk'] != null) 'publicKey': query['pbk'],
        if (query['sid'] != null) 'shortId': query['sid'],
        if (query['spx'] != null) 'spiderX': query['spx'],
      };
    }
    _addTransportSettings(stream, network, query['path'], query['host'], query['serviceName']);

    final outbound = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vless',
      'settings': {
        'vnext': [
          {
            'address': uri.host,
            'port': uri.port,
            'users': [
              {
                'id': userId,
                'encryption': query['encryption'] ?? 'none',
                if (query['flow'] != null && query['flow']!.isNotEmpty) 'flow': query['flow'],
              }
            ],
          }
        ],
      },
      'streamSettings': stream,
    };
    return _wrapOutbound(outbound);
  }

  Map<String, dynamic> _buildVmessConfig(Map<String, dynamic> source) {
    final host = (source['add'] ?? '').toString();
    final port = int.tryParse((source['port'] ?? '').toString()) ?? 0;
    final id = (source['id'] ?? '').toString();
    if (host.isEmpty || port <= 0 || id.isEmpty) {
      throw const FormatException('Invalid VMess link');
    }
    final network = (source['net'] ?? 'tcp').toString();
    final security = (source['tls'] ?? '').toString() == 'tls' ? 'tls' : 'none';
    final query = <String, String>{
      if (source['path'] != null) 'path': source['path'].toString(),
      if (source['host'] != null) 'host': source['host'].toString(),
    };
    final stream = <String, dynamic>{'network': network, 'security': security};
    if (security == 'tls') {
      stream['tlsSettings'] = {
        'serverName': (source['sni'] ?? source['host'] ?? host).toString(),
        'allowInsecure': false,
        if (source['fp'] != null) 'fingerprint': source['fp'].toString(),
      };
    }
    _addTransportSettings(stream, network, query['path'], query['host'], source['path']?.toString());

    final outbound = <String, dynamic>{
      'tag': 'proxy',
      'protocol': 'vmess',
      'settings': {
        'vnext': [
          {
            'address': host,
            'port': port,
            'users': [
              {
                'id': id,
                'alterId': int.tryParse((source['aid'] ?? '0').toString()) ?? 0,
                'security': (source['scy'] ?? 'auto').toString(),
              }
            ],
          }
        ],
      },
      'streamSettings': stream,
    };
    return _wrapOutbound(outbound);
  }

  void _addTransportSettings(
    Map<String, dynamic> stream,
    String network,
    String? path,
    String? host,
    String? serviceName,
  ) {
    if (network == 'ws') {
      stream['wsSettings'] = {
        'path': path ?? '/',
        if (host != null && host.isNotEmpty) 'headers': {'Host': host},
      };
    } else if (network == 'grpc') {
      stream['grpcSettings'] = {
        'serviceName': serviceName ?? path ?? '',
      };
    } else if (network == 'httpupgrade') {
      stream['httpupgradeSettings'] = {
        'path': path ?? '/',
        if (host != null && host.isNotEmpty) 'host': host,
      };
    }
  }

  Map<String, dynamic> _wrapOutbound(Map<String, dynamic> outbound) {
    final config = <String, dynamic>{
      'log': {'loglevel': 'warning'},
      'inbounds': [
        {
          'tag': 'tun',
          'protocol': 'tun',
          'settings': {'name': 'xray0', 'MTU': 1500, 'userLevel': 8},
          'sniffing': {
            'enabled': true,
            'destOverride': ['http', 'tls', 'quic'],
          },
        }
      ],
      'outbounds': [
        outbound,
        {
          'tag': 'direct',
          'protocol': 'freedom',
          'settings': {},
        },
        {
          'tag': 'block',
          'protocol': 'blackhole',
          'settings': {'response': {'type': 'http'}},
        },
      ],
      'routing': {'domainStrategy': 'AsIs', 'rules': []},
    };
    return config;
  }

  void _ensureTunInbound(Map<String, dynamic> config) {
    final inbounds = config['inbounds'] is List
        ? config['inbounds'] as List
        : <dynamic>[];
    final hasTun = inbounds.any(
      (item) => item is Map && item['protocol'] == 'tun',
    );
    if (!hasTun) {
      inbounds.add({
        'tag': 'tun',
        'protocol': 'tun',
        'settings': {'name': 'xray0', 'MTU': 1500, 'userLevel': 8},
        'sniffing': {
          'enabled': true,
          'destOverride': ['http', 'tls', 'quic'],
        },
      });
    }
    config['inbounds'] = inbounds;
    config.putIfAbsent('routing', () => {'domainStrategy': 'AsIs', 'rules': []});
  }

  Future<void> _addProfile() async {
    _nameController.clear();
    _configController.clear();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isPersian ? 'افزودن سرور V2Ray' : 'Add V2Ray server'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: _isPersian ? 'نام سرور' : 'Server name',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _configController,
                  minLines: 8,
                  maxLines: 12,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    alignLabelWithHint: true,
                    labelText: _isPersian ? 'لینک VLESS / VMess یا کانفیگ JSON' : 'VLESS / VMess link or Xray JSON',
                    hintText: 'vless://...  |  vmess://...  |  JSON',
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(_isPersian ? 'لغو' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(_isPersian ? 'ذخیره' : 'Save'),
          ),
        ],
      ),
    );

    if (accepted != true) return;
    final name = _nameController.text.trim();
    final config = _configController.text.trim();
    if (name.isEmpty || config.isEmpty) {
      _showMessage(_isPersian ? 'نام و کانفیگ را وارد کن.' : 'Enter a name and config.');
      return;
    }
    late final String normalizedConfig;
    try {
      normalizedConfig = jsonEncode(_buildXrayConfig(config));
    } catch (_) {
      _showMessage(
        _isPersian
            ? 'لینک یا JSON معتبر نیست. لینک VLESS/VMess یا کانفیگ کامل Xray وارد کن.'
            : 'Invalid link or JSON. Enter a VLESS/VMess link or full Xray config.',
      );
      return;
    }

    final id = DateTime.now().microsecondsSinceEpoch.toString();
    setState(() => _profiles = [
          ..._profiles,
          {'id': id, 'name': name, 'configJson': config},
        ]);
    try {
      await _saveProfiles();
      _showMessage(_isPersian ? 'سرور ذخیره شد.' : 'Server saved.');
    } catch (_) {
      setState(() => _profiles.removeWhere((item) => item['id'] == id));
      _showMessage(_isPersian ? 'ذخیره سرور ناموفق بود.' : 'Could not save the server.');
    }
  }

  Future<void> _connect(Map<String, String> profile) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    try {
      await VpnBridge().connectXray(configJson: profile['configJson']!);
      _showMessage(_isPersian ? 'درخواست اتصال ارسال شد.' : 'Connection request sent.');
    } catch (error) {
      _showMessage(_isPersian ? 'اتصال شروع نشد.' : 'Could not start the connection.');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _delete(Map<String, String> profile) async {
    setState(() => _profiles.removeWhere((item) => item['id'] == profile['id']));
    try {
      await _saveProfiles();
      _showMessage(_isPersian ? 'سرور حذف شد.' : 'Server deleted.');
    } catch (_) {
      setState(() => _profiles.add(profile));
      _showMessage(_isPersian ? 'حذف سرور ناموفق بود.' : 'Could not delete the server.');
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final title = _isPersian ? 'سرورهای V2Ray' : 'V2Ray servers';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _isPersian
                                ? 'این فهرست جدا از سرورهای خودکار DX ذخیره می‌شود.'
                                : 'This list is stored separately from the automatic DX servers.',
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          onPressed: _addProfile,
                          icon: const Icon(Icons.add),
                          label: Text(_isPersian ? 'افزودن' : 'Add'),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _profiles.isEmpty
                        ? Center(
                            child: Text(
                              _isPersian
                                  ? 'هنوز سروری اضافه نکردی.'
                                  : 'No V2Ray servers added yet.',
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.all(16),
                            itemCount: _profiles.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final profile = _profiles[index];
                              return Card(
                                child: ListTile(
                                  leading: const Icon(Icons.dns_outlined),
                                  title: Text(profile['name']!),
                                  subtitle: Text(_isPersian ? 'پروفایل مستقل Xray' : 'Independent Xray profile'),
                                  trailing: Wrap(
                                    spacing: 4,
                                    children: [
                                      IconButton(
                                        tooltip: _isPersian ? 'اتصال' : 'Connect',
                                        onPressed: _connecting ? null : () => _connect(profile),
                                        icon: const Icon(Icons.play_arrow_rounded),
                                      ),
                                      IconButton(
                                        tooltip: _isPersian ? 'حذف' : 'Delete',
                                        onPressed: () => _delete(profile),
                                        icon: const Icon(Icons.delete_outline),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}
