// RL: native device list for the technician (like the desktop RL-Control).
// Logs in to the RL console, shows the live device list, tap-to-connect.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../common.dart';
import '../../models/platform_model.dart';
import 'home_page.dart';

const _kUserKey = 'rl-console-user';
const _kPassKey = 'rl-console-pass';

// Console endpoints: internal (fast, on-LAN) preferred, external HTTPS fallback.
// The relay used for a connection matches whichever console responded.
class _Endpoint {
  final String base;
  final String relay;
  const _Endpoint(this.base, this.relay);
}

const List<_Endpoint> _endpoints = [
  _Endpoint('http://10.0.44.170:21120', '10.0.44.170'),
  _Endpoint('https://82.166.23.44', '82.166.23.44'),
];

class ConsoleDevicesPage extends StatefulWidget implements PageShape {
  ConsoleDevicesPage({Key? key}) : super(key: key);

  @override
  final String title = 'מכשירים';

  @override
  final Widget icon = const Icon(Icons.devices);

  @override
  final List<Widget> appBarActions = [];

  @override
  State<ConsoleDevicesPage> createState() => _ConsoleDevicesPageState();
}

class _ConsoleDevicesPageState extends State<ConsoleDevicesPage> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  late final IOClient _client;
  String? _cookie;
  _Endpoint? _ep; // which console we reached
  bool _loggedIn = false;
  bool _busy = false;
  String? _error;
  List<dynamic> _devices = [];
  String _search = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final io = HttpClient()
      ..badCertificateCallback = ((X509Certificate cert, String host, int port) => true)
      ..connectionTimeout = const Duration(seconds: 6);
    _client = IOClient(io);
    _userCtrl.text = bind.mainGetLocalOption(key: _kUserKey);
    _passCtrl.text = bind.mainGetLocalOption(key: _kPassKey);
    if (_userCtrl.text.isNotEmpty && _passCtrl.text.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _login(save: false));
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _userCtrl.dispose();
    _passCtrl.dispose();
    _searchCtrl.dispose();
    try {
      _client.close();
    } catch (_) {}
    super.dispose();
  }

  // Try each endpoint: POST /login (no redirect) -> read rl cookie -> GET /api/devices.
  Future<void> _login({bool save = true}) async {
    final user = _userCtrl.text.trim();
    final pass = _passCtrl.text;
    if (user.isEmpty || pass.isEmpty) {
      setState(() => _error = 'נא להזין שם משתמש וסיסמה');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    String? lastErr;
    for (final ep in _endpoints) {
      try {
        final req = http.Request('POST', Uri.parse('${ep.base}/login'))
          ..followRedirects = false
          ..headers['Content-Type'] = 'application/x-www-form-urlencoded'
          ..body =
              'username=${Uri.encodeQueryComponent(user)}&password=${Uri.encodeQueryComponent(pass)}';
        final resp =
            await _client.send(req).timeout(const Duration(seconds: 8));
        await resp.stream.drain();
        final sc = resp.headers['set-cookie'] ?? '';
        final m = RegExp(r'rl=([^;]+)').firstMatch(sc);
        final token = m?.group(1);
        if (token == null || token.isEmpty) {
          lastErr = 'שם משתמש או סיסמה שגויים';
          continue;
        }
        // validate by fetching devices
        final cookie = 'rl=$token';
        final dr = await _client.get(Uri.parse('${ep.base}/api/devices'),
            headers: {'Cookie': cookie}).timeout(const Duration(seconds: 10));
        if (dr.statusCode != 200) {
          lastErr = 'שגיאת התחברות (${dr.statusCode})';
          continue;
        }
        final data = jsonDecode(utf8.decode(dr.bodyBytes));
        if (data is! List) {
          lastErr = 'תשובה לא תקינה מהשרת';
          continue;
        }
        if (save) {
          await bind.mainSetLocalOption(key: _kUserKey, value: user);
          await bind.mainSetLocalOption(key: _kPassKey, value: pass);
        }
        if (!mounted) return;
        setState(() {
          _ep = ep;
          _cookie = cookie;
          _loggedIn = true;
          _devices = data;
          _busy = false;
          _error = null;
        });
        _startAutoRefresh();
        return;
      } catch (e) {
        lastErr = 'לא ניתן להגיע לשרת';
        continue;
      }
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = lastErr ?? 'ההתחברות נכשלה';
    });
  }

  void _startAutoRefresh() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final ep = _ep;
    final cookie = _cookie;
    if (ep == null || cookie == null) return;
    try {
      final dr = await _client.get(Uri.parse('${ep.base}/api/devices'),
          headers: {'Cookie': cookie}).timeout(const Duration(seconds: 10));
      if (dr.statusCode == 401) {
        // session expired
        if (mounted) setState(() => _loggedIn = false);
        _timer?.cancel();
        return;
      }
      if (dr.statusCode == 200) {
        final data = jsonDecode(utf8.decode(dr.bodyBytes));
        if (data is List && mounted) setState(() => _devices = data);
      }
    } catch (_) {}
  }

  void _logout() {
    _timer?.cancel();
    setState(() {
      _loggedIn = false;
      _cookie = null;
      _devices = [];
      _error = null;
    });
  }

  void _connectTo(Map d) {
    final id = (d['id'] ?? '').toString();
    if (id.isEmpty) return;
    final pw = (d['pw'] ?? '').toString();
    // Pick a relay BOTH sides can reach, based on where the customer device is:
    //  - customer on our LAN (ping.internal) -> internal relay (direct, no NAT hairpin)
    //  - customer off-LAN                    -> external relay (already-open relay port)
    // The technician is always inside our network (console reached internally).
    final ping = d['ping'] is Map ? d['ping'] as Map : null;
    final custInternal = ping != null && ping['internal'] == true;
    final relay = custInternal ? '10.0.44.170' : '82.166.23.44';
    final target = '$id/r@$relay';
    connect(context, target, password: pw.isNotEmpty ? pw : 'RL123456');
  }

  List<Map> get _visible {
    final q = _search.trim().toLowerCase();
    final list = _devices.whereType<Map>().where((d) {
      final online = d['online'] == true;
      final active = (d['active_by'] is List) && (d['active_by'] as List).isNotEmpty;
      if (!online && !active) return false;
      if (q.isEmpty) return true;
      final hay = '${d['name'] ?? ''} ${d['id'] ?? ''} ${d['ip'] ?? ''}'.toLowerCase();
      return hay.contains(q);
    }).toList();
    list.sort((a, b) {
      final aa = (a['active_by'] is List) && (a['active_by'] as List).isNotEmpty;
      final ba = (b['active_by'] is List) && (b['active_by'] as List).isNotEmpty;
      if (aa != ba) return aa ? -1 : 1;
      return '${a['name'] ?? a['id']}'.compareTo('${b['name'] ?? b['id']}');
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: _loggedIn ? _buildList(context) : _buildLogin(context),
    );
  }

  Widget _buildLogin(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.devices, size: 56, color: Color(0xFF2563EB)),
            const SizedBox(height: 12),
            const Text('התחברות לקונסול RL',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            TextField(
              controller: _userCtrl,
              textDirection: TextDirection.ltr,
              decoration: const InputDecoration(
                  labelText: 'שם משתמש', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passCtrl,
              obscureText: true,
              textDirection: TextDirection.ltr,
              onSubmitted: (_) => _login(),
              decoration: const InputDecoration(
                  labelText: 'סיסמה', border: OutlineInputBorder()),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _busy ? null : () => _login(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: _busy
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('התחבר'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(BuildContext context) {
    final items = _visible;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'חיפוש (שם / מזהה / IP)',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 0, horizontal: 8),
                  ),
                ),
              ),
              IconButton(
                  tooltip: 'רענן', onPressed: _refresh, icon: const Icon(Icons.refresh)),
              IconButton(
                  tooltip: 'התנתק', onPressed: _logout, icon: const Icon(Icons.logout)),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            children: [
              Text('${items.length} מחוברים',
                  style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text('אין מכשירים מחוברים כרגע',
                      style: TextStyle(color: Colors.grey)))
              : RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) => _deviceTile(items[i]),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _deviceTile(Map d) {
    final name = (d['name'] ?? '').toString();
    final id = (d['id'] ?? '').toString();
    final ip = (d['ip'] ?? '').toString();
    final active = (d['active_by'] is List) && (d['active_by'] as List).isNotEmpty;
    final activeBy = active ? (d['active_by'] as List).join(', ') : '';
    final online = d['online'] == true;
    final isAgent = (d['kind'] ?? '') == 'agent';
    final ping = d['ping'] is Map ? d['ping'] as Map : null;

    Color dotColor = active ? Colors.orange : (online ? Colors.green : Colors.grey);
    final sub = <String>[];
    sub.add(id);
    if (ip.isNotEmpty) sub.add(ip);
    if (active) sub.add('בשליטה: $activeBy');

    return ListTile(
      leading: Stack(
        alignment: Alignment.bottomRight,
        children: [
          CircleAvatar(
            backgroundColor: const Color(0xFF1e293b),
            child: Icon(isAgent ? Icons.dns : Icons.computer,
                color: Colors.white70, size: 20),
          ),
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ],
      ),
      title: Text(name.isNotEmpty ? name : id,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(sub.join('  ·  '),
              style: TextStyle(
                  fontSize: 12,
                  color: active ? Colors.orange : Colors.grey)),
          if (ping != null && ping['updated'] != null && ping['updated'] != 0)
            Text(
              [
                (ping['internal'] == true ? '🟢' : '🔴') + ' פנימי',
                (ping['netfree'] == true ? '🟢' : '🔴') + ' נטפרי',
                (ping['external'] == true ? '🟢' : '🔴') + ' אינטרנט',
              ].join('  '),
              style: const TextStyle(fontSize: 11),
            ),
        ],
      ),
      trailing: ElevatedButton.icon(
        onPressed: () => _connectTo(d),
        icon: const Icon(Icons.login, size: 16),
        label: const Text('התחבר'),
        style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF2563EB),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 10)),
      ),
      onTap: () => _connectTo(d),
    );
  }
}
