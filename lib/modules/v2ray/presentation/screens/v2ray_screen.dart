import 'dart:convert';
import 'dart:ui';
import 'package:dio/dio.dart';

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
  int _tabIndex = 0;
  String? _selectedProfileId;
  final _subscriptionController = TextEditingController();
  bool _subscriptionLoading = false;
  String _usageText = 'Not provided';
  String _expiryText = 'Not provided';

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
    _subscriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadProfiles() async {
    try {
      final raw = await ref.read(secureStorageProvider).read(_storageKey);
      final savedSubscription = await ref.read(secureStorageProvider).read('veleven_v2ray_subscription_url');
      if (savedSubscription != null) _subscriptionController.text = savedSubscription;
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
      if (mounted) setState(() { _profiles = profiles; _selectedProfileId ??= profiles.isEmpty ? null : profiles.first['id']; });
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
      final normalized = base64Url.normalize(encoded.replaceAll('+', '-').replaceAll('/', '_'));
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
          {'id': id, 'name': name, 'configJson': normalizedConfig},
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


  Future<void> _importSubscription() async {
    final url = _subscriptionController.text.trim();
    if (!(url.startsWith('https://') || url.startsWith('http://'))) {
      _showMessage('Enter a valid subscription URL.');
      return;
    }
    setState(() => _subscriptionLoading = true);
    try {
      final response = await Dio().get<String>(url,
        options: Options(responseType: ResponseType.plain, followRedirects: true));
      var body = (response.data ?? '').trim();
      final info = response.headers.value('subscription-userinfo') ?? '';
      final total = RegExp(r'total=(\d+)').firstMatch(info)?.group(1);
      final expire = RegExp(r'expire=(\d+)').firstMatch(info)?.group(1);
      setState(() {
        if (total != null) _usageText = total + ' bytes';
        if (expire != null && int.tryParse(expire)! > 0) {
          _expiryText = DateTime.fromMillisecondsSinceEpoch(int.parse(expire) * 1000).toLocal().toString().split('.').first;
        }
      });
      if (!body.contains('://')) {
        try { body = utf8.decode(base64.decode(base64.normalize(body))); } catch (_) {}
      }
      final links = body.split(RegExp(r'\r?\n')).map((e) => e.trim())
          .where((e) => e.startsWith('vless://') || e.startsWith('vmess://')).toList();
      if (links.isEmpty) throw const FormatException('No supported links');
      final imported = <Map<String, String>>[];
      for (var i = 0; i < links.length; i++) {
        try {
          final uri = Uri.tryParse(links[i]);
          final name = uri != null && uri.fragment.isNotEmpty
              ? Uri.decodeComponent(uri.fragment) : 'Subscription ${i + 1}';
          imported.add({
            'id': DateTime.now().microsecondsSinceEpoch.toString() + '_$i',
            'name': name,
            'configJson': jsonEncode(_buildXrayConfig(links[i])),
          });
        } catch (_) {}
      }
      if (imported.isEmpty) throw const FormatException('No valid profiles');
      setState(() { _profiles = [..._profiles, ...imported]; _selectedProfileId ??= imported.first['id']; });
      await _saveProfiles();
      await ref.read(secureStorageProvider).write('veleven_v2ray_subscription_url', url);
      _showMessage('${imported.length} servers imported.');
    } catch (_) {
      _showMessage('Could not import subscription. Check the URL and try again.');
    } finally {
      if (mounted) setState(() => _subscriptionLoading = false);
    }
  }

  Widget _glass(Widget child) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: (dark ? const Color(0xFF101B2B) : Colors.white).withValues(alpha: .78),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF3988FF).withValues(alpha: .20)),
            boxShadow: [BoxShadow(color: const Color(0xFF2878F0).withValues(alpha: .07), blurRadius: 22, offset: const Offset(0, 8))],
          ),
          child: child,
        ),
      ),
    );
  }

  Widget _heading(String title, String subtitle) => Padding(
    padding: const EdgeInsets.only(bottom: 15),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800)),
      const SizedBox(height: 4),
      Text(subtitle, style: const TextStyle(color: Colors.grey, fontSize: 12)),
    ]),
  );

  Widget _bottomBar() {
    const labels = ['Connect', 'Servers', 'Subscription', 'Settings'];
    const icons = [Icons.power_settings_new_rounded, Icons.dns_outlined, Icons.add_link_rounded, Icons.tune_rounded];
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
      child: ClipRRect(borderRadius: BorderRadius.circular(22), child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 5),
          decoration: BoxDecoration(
            color: (dark ? const Color(0xFF0D1726) : Colors.white).withValues(alpha: .88),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFF3988FF).withValues(alpha: .22)),
          ),
          child: Row(children: List.generate(4, (i) => Expanded(child: GestureDetector(
            onTap: () => setState(() => _tabIndex = i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 1),
              decoration: BoxDecoration(
                color: _tabIndex == i ? const Color(0xFF2878F0).withValues(alpha: .12) : Colors.transparent,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icons[i], size: 20, color: _tabIndex == i ? const Color(0xFF3988FF) : (dark ? Colors.white60 : Colors.blueGrey)),
                const SizedBox(height: 4),
                Text(labels[i], maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 9, fontWeight: _tabIndex == i ? FontWeight.w800 : FontWeight.w500,
                    color: _tabIndex == i ? const Color(0xFF3988FF) : (dark ? Colors.white60 : Colors.blueGrey))),
              ]),
            ),
          )))),
        ),
      )),
    ));
  }

  Widget _page() {
    final matches = _profiles.where((p) => p['id'] == _selectedProfileId);
    final selected = matches.isEmpty ? null : matches.first;
    final contentPadding = const EdgeInsets.fromLTRB(20, 14, 20, 24);
    if (_tabIndex == 0) {
      return ListView(padding: contentPadding, children: [
        _heading('V11 Connect', 'Your private connection space'),
        _glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.shield_rounded, color: Color(0xFF3988FF), size: 23),
            SizedBox(width: 9),
            Text('Account overview', style: TextStyle(fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: _statText('Traffic limit', _usageText)),
            Expanded(child: _statText('Expires', _expiryText)),
          ]),
          const SizedBox(height: 8),
          const Text('Usage details appear when your provider sends subscription information.',
            style: TextStyle(fontSize: 10, color: Colors.grey)),
        ])),
        const SizedBox(height: 16),
        _glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Selected server', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          Text(selected?['name'] ?? 'No server selected', style: const TextStyle(color: Colors.grey)),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, height: 52, child: FilledButton.icon(
            onPressed: selected == null || _connecting ? null : () => _connect(selected),
            icon: _connecting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.power_settings_new_rounded),
            label: Text(_connecting ? 'Starting…' : 'Connect'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2878F0), foregroundColor: Colors.white),
          )),
        ])),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton.icon(onPressed: () => setState(() => _tabIndex = 1), icon: const Icon(Icons.dns_outlined), label: const Text('View servers'))),
          const SizedBox(width: 10),
          Expanded(child: OutlinedButton.icon(onPressed: () => setState(() => _tabIndex = 2), icon: const Icon(Icons.add_link_rounded), label: const Text('Add subscription'))),
        ]),
      ]);
    }
    if (_tabIndex == 1) {
      return ListView(padding: contentPadding, children: [
        _heading('Your servers', 'VLESS, VMess and Xray profiles'),
        Row(children: [
          Expanded(child: Text('${_profiles.length} profiles', style: const TextStyle(color: Colors.grey, fontSize: 12))),
          FilledButton.icon(onPressed: _addProfile, icon: const Icon(Icons.add), label: const Text('Add server'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2878F0))),
        ]),
        const SizedBox(height: 14),
        if (_profiles.isEmpty) _glass(const Text('No servers yet. Add a link or import a subscription.', style: TextStyle(color: Colors.grey)))
        else ..._profiles.map((p) => Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _glass(Row(children: [
            Icon(p['id'] == _selectedProfileId ? Icons.radio_button_checked : Icons.dns_outlined, color: const Color(0xFF3988FF)),
            const SizedBox(width: 10),
            Expanded(child: GestureDetector(onTap: () => setState(() { _selectedProfileId = p['id']; _tabIndex = 0; }),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p['name']!, style: const TextStyle(fontWeight: FontWeight.w700)),
                const Text('Xray profile', style: TextStyle(color: Colors.grey, fontSize: 10)),
              ]))),
            IconButton(onPressed: _connecting ? null : () { setState(() => _selectedProfileId = p['id']); _connect(p); },
              icon: const Icon(Icons.play_circle_outline, color: Color(0xFF3988FF))),
            IconButton(onPressed: () => _delete(p), icon: const Icon(Icons.delete_outline)),
          ])),
        )),
      ]);
    }
    if (_tabIndex == 2) {
      return ListView(padding: contentPadding, children: [
        _heading('Subscriptions', 'Import and refresh your server list'),
        _glass(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Subscription URL', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text('Paste your provider URL. Supported VLESS and VMess links will be imported into your server list.',
            style: TextStyle(color: Colors.grey, fontSize: 12, height: 1.5)),
          const SizedBox(height: 14),
          TextField(controller: _subscriptionController, keyboardType: TextInputType.url, autocorrect: false, enableSuggestions: false,
            decoration: InputDecoration(hintText: 'https://example.com/subscription', prefixIcon: const Icon(Icons.link, color: Color(0xFF3988FF)),
              filled: true, fillColor: Theme.of(context).brightness == Brightness.dark ? Colors.white.withValues(alpha: .04) : const Color(0xFFF3F7FD),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none))),
          const SizedBox(height: 14),
          SizedBox(width: double.infinity, height: 50, child: FilledButton.icon(
            onPressed: _subscriptionLoading ? null : _importSubscription,
            icon: _subscriptionLoading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.download_rounded),
            label: Text(_subscriptionLoading ? 'Importing…' : 'Import subscription'),
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF2878F0), foregroundColor: Colors.white))),
        ])),
        const SizedBox(height: 14),
        _glass(const Text('Single VLESS / VMess links and manual Xray JSON can be added from the Servers tab. Traffic and expiry are shown only when provided by your subscription server.',
          style: TextStyle(fontSize: 11, color: Colors.grey, height: 1.5))),
      ]);
    }
    return ListView(padding: contentPadding, children: [
      _heading('V11 Settings', 'Workspace preferences'),
      _glass(Column(children: [
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.brightness_auto, color: Color(0xFF3988FF)),
          title: const Text('Appearance'), subtitle: Text(Theme.of(context).brightness == Brightness.dark ? 'Dark · follows device' : 'Light · follows device')),
        Divider(color: Theme.of(context).dividerColor.withValues(alpha: .3)),
        const ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.security, color: Color(0xFF3988FF)),
          title: Text('Engine'), subtitle: Text('Xray / V2Ray')),
        Divider(color: Theme.of(context).dividerColor.withValues(alpha: .3)),
        const ListTile(contentPadding: EdgeInsets.zero, leading: Icon(Icons.lock_outline, color: Color(0xFF3988FF)),
          title: Text('Profile storage'), subtitle: Text('Encrypted local storage')),
      ])),
    ]);
  }

  Widget _statText(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
    const SizedBox(height: 4),
    Text(label, style: const TextStyle(color: Colors.grey, fontSize: 10)),
  ]);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: dark
              ? const [Color(0xFF07111F), Color(0xFF0B1728), Color(0xFF08101C)]
              : const [Color(0xFFF4F8FF), Color(0xFFEAF2FF), Color(0xFFF9FBFF)],
          ),
        ),
        child: Column(children: [
          Padding(padding: const EdgeInsets.fromLTRB(22, 3, 22, 0), child: Row(children: [
            const Text('V11', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, letterSpacing: -.8)),
            const Spacer(),
            Container(padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: BoxDecoration(color: const Color(0xFF2878F0).withValues(alpha: .12),
                borderRadius: BorderRadius.circular(30), border: Border.all(color: const Color(0xFF3988FF).withValues(alpha: .24))),
              child: const Row(children: [
                Icon(Icons.circle, size: 7, color: Color(0xFF3988FF)), SizedBox(width: 7),
                Text('XRAY ENGINE', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: .8, color: Color(0xFF3988FF))),
              ])),
          ])),
          Expanded(child: _loading ? const Center(child: CircularProgressIndicator(color: Color(0xFF3988FF))) : _page()),
          _bottomBar(),
        ]),
      ),
    );
  }
}
