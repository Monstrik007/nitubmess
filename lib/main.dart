import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:contacts_service/contacts_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:country_code_picker/country_code_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final phone = prefs.getString('phone');
  runApp(MyMessengerApp(initialPhone: phone));
}

class MyMessengerApp extends StatelessWidget {
  final String? initialPhone;
  MyMessengerApp({this.initialPhone});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Secure Flutter Chat',
      theme: ThemeData.dark(),
      home: initialPhone == null
          ? PhoneInputScreen()
          : ChatListScreen(nick: initialPhone!),
    );
  }
}

class PhoneInputScreen extends StatefulWidget {
  @override
  _PhoneInputScreenState createState() => _PhoneInputScreenState();
}

class _PhoneInputScreenState extends State<PhoneInputScreen> {
  CountryCode _countryCode = CountryCode.fromDialCode('+7');
  final _phoneCtrl = TextEditingController();
  bool _syncContacts = true, _loading = false;

  Future<void> _onContinue() async {
    final number = _phoneCtrl.text.trim();
    if (number.isEmpty) return;
    setState(() => _loading = true);
    final full = '${_countryCode.dialCode}$number';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phone', full);
    await prefs.setBool('sync', _syncContacts);
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => ChatListScreen(nick: full)),
    );
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Text('Телефон'), actions: [
        TextButton(onPressed: () => exit(0), child: Text('Отмена', style: TextStyle(color: Colors.white))),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 20),
          Center(child: Icon(Icons.phone, size: 80, color: Colors.redAccent)),
          SizedBox(height: 16),
          Center(child: Text('Телефон', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
          SizedBox(height: 8),
          Center(child: Text('Проверьте код страны и введите свой номер телефона.', textAlign: TextAlign.center)),
          SizedBox(height: 24),
          Row(children: [
            CountryCodePicker(
              onChanged: (c) => setState(() => _countryCode = c),
              initialSelection: _countryCode.code,
              favorite: ['+7', 'RU'],
            ),
            Expanded(
              child: TextField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(hintText: '000 000 0000'),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ]),
          SwitchListTile(
            title: Text('Синхронизировать контакты'),
            value: _syncContacts,
            onChanged: (v) => setState(() => _syncContacts = v),
          ),
          Spacer(),
          ElevatedButton(
            onPressed: (_phoneCtrl.text.trim().isEmpty || _loading) ? null : _onContinue,
            child: _loading
                ? SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white))
                : Text('Продолжить'),
            style: ElevatedButton.styleFrom(minimumSize: Size(double.infinity, 48)),
          ),
        ]),
      ),
    );
  }
}

class _PendingReq {
  final String peer, pass;
  _PendingReq(this.peer, this.pass);
}

class ChatService {
  Socket? _socket;
  final _pktController = StreamController<Map<String, dynamic>>.broadcast();
  String nick = '';
  Stream<Map<String, dynamic>> get pkts => _pktController.stream;

  Future<void> connect(String nick) async {
    this.nick = nick;
    _socket = await Socket.connect('127.0.0.1', 12345);
    utf8.decoder.bind(_socket!).transform(const LineSplitter()).listen((line) {
      _pktController.add(json.decode(line));
    });
    _socket!.write(json.encode({'type': 'presence', 'nick': nick}) + '\n');
  }

  void send(Map<String, dynamic> pkt) => _socket?.write(json.encode(pkt) + '\n');
  void dispose() {
    _socket?.destroy();
    _pktController.close();
  }
}

List<int> deriveSessionKey(String a, String b) {
  var s = [a, b]..sort();
  return sha256.convert(utf8.encode(s.join())).bytes;
}
List<int> deriveMsgKey(String p) => sha256.convert(utf8.encode(p)).bytes;
List<int> xorBytes(List<int> d, List<int> k) => [
      for (var i = 0; i < d.length; i++) d[i] ^ k[i % k.length]
    ];
String encryptStr(String s, List<int> k) => base64.encode(xorBytes(utf8.encode(s), k));
String decryptStr(String s, List<int> k) {
  try {
    return utf8.decode(xorBytes(base64.decode(s), k));
  } catch (_) {
    return '[!decrypt failed]';
  }
}

class ChatListScreen extends StatefulWidget {
  final String nick;
  ChatListScreen({required this.nick});
  @override
  _ChatListScreenState createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> with SingleTickerProviderStateMixin {
  late ChatService _service;
  List<String> registered = [], online = [], recent = [];
  Map<String, String> phoneToName = {};
  List<String> manual = [];
  List<_PendingReq> pending = [];
  bool _syncContacts = true;
  late TabController _tabCtrl;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _loadRecent();
    _initAll();
  }

  Future<void> _loadRecent() async {
    final p = await SharedPreferences.getInstance();
    recent = p.getStringList('recent') ?? [];
    setState(() {});
  }

  Future<void> _saveRecent() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('recent', recent);
  }

  Future<void> _initAll() async {
    final prefs = await SharedPreferences.getInstance();
    _syncContacts = prefs.getBool('sync') ?? true;

    if (_syncContacts && await Permission.contacts.request().isGranted) {
      final cs = await ContactsService.getContacts(withThumbnails: false);
      for (var c in cs)
        for (var pn in c.phones ?? []) {
          final num = pn.value!.replaceAll(RegExp(r'\D'), '').trim();
          phoneToName[num] = c.displayName ?? num;
        }
    }

    _service = ChatService();
    await _service.connect(widget.nick);

    _service.send({
      'type': 'check_users',
      'users': [...phoneToName.keys, ...manual],
    });
    _service.pkts.listen(_onPkt);
  }

  void _onPkt(Map<String, dynamic> pkt) {
    switch (pkt['type']) {
      case 'registered_users':
        registered = List<String>.from(pkt['users']);
        break;
      case 'user_list':
        online = List<String>.from(pkt['users']);
        break;
      case 'encrypt_request':
        final peer = pkt['from'] as String;
        final sk = deriveSessionKey(peer, widget.nick);
        final pass = decryptStr(pkt['enc_pass'], sk);
        pending.add(_PendingReq(peer, pass));
        break;
    }
    setState(() {});
  }

  void _addManual() async {
    final phone = await showDialog<String>(
      context: context,
      builder: (_) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: Text('Добавить контакт'),
          content: TextField(controller: ctrl, decoration: InputDecoration(hintText: 'Телефон')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: Text('OK')),
          ],
        );
      },
    );
    if (phone != null && phone.isNotEmpty) {
      manual.add(phone);
      _service.send({
        'type': 'check_users',
        'users': [...phoneToName.keys, ...manual],
      });
    }
  }

  void _accept(_PendingReq r) {
    _service.send({
      'type': 'encrypt_response',
      'from': widget.nick,
      'to': r.peer,
      'status': 'accept',
    });
    _openChat(r.peer, initial: r.pass, initiator: false);
    pending.remove(r);
    setState(() {});
  }

  void _decline(_PendingReq r) {
    _service.send({
      'type': 'encrypt_response',
      'from': widget.nick,
      'to': r.peer,
      'status': 'decline',
    });
    pending.remove(r);
    setState(() {});
  }

  void _openChat(String peer, {String? initial, bool initiator = true}) {
    if (!recent.contains(peer)) {
      recent.insert(0, peer);
      if (recent.length > 50) recent.removeLast();
      _saveRecent();
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          service: _service,
          peer: peer,
          initialPassword: initial,
          initiator: initiator,
          onClosed: _loadRecent,
        ),
      ),
    );
  }

  void _goSettings() {
    Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()));
  }

  @override
  void dispose() {
    _service.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final contacts = registered.where((u) => u != widget.nick).toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(icon: Icon(Icons.person), onPressed: _goSettings),
        title: Text('Контакты: ${widget.nick}'),
        bottom: TabBar(controller: _tabCtrl, tabs: [Tab(text: 'Недавние'), Tab(text: 'Все')]),
      ),
      body: TabBarView(controller: _tabCtrl, children: [
        // === НЕДАВНИЕ + приглашения ===
        ListView(children: [
          if (pending.isNotEmpty) ...[
            SizedBox(height: 8),
            Text('Приглашения:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ...pending.map((r) => Card(
                  color: Colors.blue[800],
                  child: ListTile(
                    title: Text(phoneToName[r.peer] ?? r.peer),
                    subtitle: Text('Пароль: ${r.pass}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton(onPressed: () => _accept(r), child: Text('Принять')),
                      TextButton(onPressed: () => _decline(r), child: Text('Отклонить')),
                    ]),
                  ),
                )),
            Divider(),
          ],
          ...recent.map((u) {
            final name = phoneToName[u] ?? u;
            return Dismissible(
              key: Key(u),
              direction: DismissDirection.endToStart,
              onDismissed: (_) {
                recent.remove(u);
                _saveRecent();
                setState(() {});
              },
              background: Container(
                  color: Colors.red,
                  alignment: Alignment.centerRight,
                  padding: EdgeInsets.only(right: 20),
                  child: Icon(Icons.delete, color: Colors.white)),
              child: ListTile(
                title: Text(name),
                onTap: () => _openChat(u),
              ),
            );
          }).toList(),
        ]),
        // === ВСЕ + приглашения ===
        ListView(padding: EdgeInsets.all(8), children: [
          if (pending.isNotEmpty) ...[
            Text('Приглашения:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ...pending.map((r) => Card(
                  color: Colors.blue[800],
                  child: ListTile(
                    title: Text(phoneToName[r.peer] ?? r.peer),
                    subtitle: Text('Пароль: ${r.pass}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton(onPressed: () => _accept(r), child: Text('Принять')),
                      TextButton(onPressed: () => _decline(r), child: Text('Отклонить')),
                    ]),
                  ),
                )),
            Divider(),
          ],
          if (contacts.isEmpty)
            Center(child: Text('Нет зарегистрированных контактов.\nНажмите + чтобы добавить.', textAlign: TextAlign.center))
          else
            ...contacts.map((u) {
              final name = phoneToName[u] ?? u;
              final isOnline = online.contains(u);
              return ListTile(
                title: Text(name),
                subtitle: Text(isOnline ? 'Online' : 'Offline'),
                onTap: () => _openChat(u),
              );
            }).toList(),
        ]),
      ]),
      floatingActionButton: FloatingActionButton(onPressed: _addManual, child: Icon(Icons.person_add)),
    );
  }
}

class ChatScreen extends StatefulWidget {
  final ChatService service;
  final String peer;
  final String? initialPassword;
  final bool initiator;
  final VoidCallback onClosed;
  ChatScreen({
    required this.service,
    required this.peer,
    this.initialPassword,
    this.initiator = true,
    required this.onClosed,
  });
  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _msgCtrl = TextEditingController();
  List<Map<String, String>> messages = [];
  Map<String, String> keys = {};
  bool encrypted = false;
  String? incomingPass;

  @override
  void initState() {
    super.initState();
    widget.service.pkts.listen(_onPkt);
    if (widget.initialPassword != null) {
      keys[widget.peer] = widget.initialPassword!;
      encrypted = true;
    }
    if (widget.initiator) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _askPassword());
    }
  }

  void _onPkt(Map<String, dynamic> pkt) {
    final t = pkt['type'];
    if (t == 'encrypt_request' && pkt['from'] == widget.peer) {
      final sk = deriveSessionKey(widget.peer, widget.service.nick);
      incomingPass = decryptStr(pkt['enc_pass'], sk);
      setState(() {});
    }
    if (t == 'encrypt_response' && pkt['to'] == widget.service.nick) {
      if (pkt['status'] == 'accept') {
        encrypted = true;
      }
      incomingPass = null;
      setState(() {});
    }
    if (t == 'end_encryption' && pkt['to'] == widget.service.nick) {
      _closeSession();
    }
    if (t == 'message' && pkt['from'] == widget.peer) {
      final dec = decryptStr(pkt['content'], deriveMsgKey(keys[widget.peer]!));
      messages.add({'who': widget.peer, 'text': dec});
      setState(() {});
    }
  }

  Future<void> _askPassword() async {
    final pass = await showDialog<String>(
      context: context,
      builder: (_) {
        final c = TextEditingController();
        return AlertDialog(
          title: Text('Пароль для ${widget.peer}'),
          content: TextField(controller: c, decoration: InputDecoration(hintText: 'Введите пароль')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: Text('OK')),
          ],
        );
      },
    );
    if (pass != null && pass.isNotEmpty) {
      keys[widget.peer] = pass;
      final sk = deriveSessionKey(widget.service.nick, widget.peer);
      widget.service.send({
        'type': 'encrypt_request',
        'from': widget.service.nick,
        'to': widget.peer,
        'enc_pass': encryptStr(pass, sk),
      });
    }
  }

  void _acceptIncoming() {
    widget.service.send({
      'type': 'encrypt_response',
      'from': widget.service.nick,
      'to': widget.peer,
      'status': 'accept',
    });
    keys[widget.peer] = incomingPass!;
    encrypted = true;
    incomingPass = null;
    setState(() {});
  }

  void _declineIncoming() {
    widget.service.send({
      'type': 'encrypt_response',
      'from': widget.service.nick,
      'to': widget.peer,
      'status': 'decline',
    });
    incomingPass = null;
    setState(() {});
  }

  void _terminateEncryption() {
    widget.service.send({
      'type': 'end_encryption',
      'from': widget.service.nick,
      'to': widget.peer,
    });
    widget.service.send({
      'type': 'end_encryption',
      'from': widget.peer,
      'to': widget.service.nick,
    });
    _closeSession();
  }

  void _closeSession() {
    encrypted = false;
    incomingPass = null;
    messages.clear();
    keys.remove(widget.peer);
    setState(() {});
  }

  void _sendMessage() {
    if (!encrypted) return;
    final t = _msgCtrl.text.trim();
    if (t.isEmpty) return;
    final enc = encryptStr(t, deriveMsgKey(keys[widget.peer]!));
    widget.service.send({
      'type': 'message',
      'from': widget.service.nick,
      'to': widget.peer,
      'encrypted': true,
      'content': enc,
    });
    messages.add({'who': widget.service.nick, 'text': t});
    _msgCtrl.clear();
    setState(() {});
  }

  @override
  void dispose() {
    widget.onClosed();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final pass = keys[widget.peer] ?? '';
    return Scaffold(
      appBar: AppBar(title: Text(widget.peer)),
      body: Column(children: [
        Container(
          color: encrypted ? Colors.green : Colors.red,
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(
              child: Text(
                encrypted ? 'Шифрование активно: $pass' : 'Не зашифровано',
                style: TextStyle(color: Colors.white),
              ),
            ),
            TextButton(
              onPressed: encrypted ? _terminateEncryption : _askPassword,
              child: Text(encrypted ? 'Разорвать' : 'Зашифровать'),
              style: TextButton.styleFrom(
                backgroundColor: encrypted ? Colors.red : Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ]),
        ),
        if (!encrypted && incomingPass != null) ...[
          // приглашение прямо в чате
          Container(
            color: Colors.blue,
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Text('Пароль: $incomingPass', style: TextStyle(color: Colors.white))),
              TextButton(onPressed: _acceptIncoming, child: Text('Принять'), style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.blue)),
              TextButton(onPressed: _declineIncoming, child: Text('Отклонить'), style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.blue)),
            ]),
          ),
        ],
        Expanded(
          child: ListView.builder(
            itemCount: messages.length,
            itemBuilder: (_, i) {
              final m = messages[i], me = m['who'] == widget.service.nick;
              return Align(
                alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: EdgeInsets.all(4),
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: me ? Colors.blueAccent : Colors.grey[800],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(m['text']!),
                ),
              );
            },
          ),
        ),
        Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _msgCtrl,
                enabled: encrypted,
                decoration: InputDecoration(
                  hintText: encrypted ? 'Сообщение' : 'Сначала шифруйте диалог',
                ),
              ),
            ),
            IconButton(icon: Icon(Icons.send), onPressed: encrypted ? _sendMessage : null),
          ]),
        ),
      ]),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  Future<void> _logout(BuildContext c) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('phone');
    Navigator.of(c).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => PhoneInputScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Text('Настройки')),
      body: ListView(children: [
        ListTile(
          leading: Icon(Icons.logout),
          title: Text('Выйти'),
          onTap: () => _logout(c),
        ),
        // тут можно добавить ещё свои настройки
      ]),
    );
  }
}
