import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:country_code_picker/country_code_picker.dart';
import 'package:contacts_service/contacts_service.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final phone = prefs.getString('phone');
  final fontScale = prefs.getDouble('fontScale') ?? 1.0;
  runApp(MyMessengerApp(
    initialPhone: phone,
    initialFontScale: fontScale,
  ));
}

class MyMessengerApp extends StatefulWidget {
  final String? initialPhone;
  final double initialFontScale;
  MyMessengerApp({this.initialPhone, required this.initialFontScale});
  @override
  _MyMessengerAppState createState() => _MyMessengerAppState();
}

class _MyMessengerAppState extends State<MyMessengerApp> {
  double _fontScale = 1.0;

  @override
  void initState() {
    super.initState();
    _fontScale = widget.initialFontScale;
  }

  Future<void> _updateFontScale(double scale) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('fontScale', scale);
    setState(() => _fontScale = scale);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Secure Flutter Chat',
      theme: ThemeData.dark(),
      builder: (ctx, child) {
        final mq = MediaQuery.of(ctx);
        return MediaQuery(
          data: mq.copyWith(textScaleFactor: _fontScale),
          child: child!,
        );
      },
      home: widget.initialPhone == null
          ? PhoneInputScreen()
          : ChatListScreen(
              nick: widget.initialPhone!,
              fontScale: _fontScale,
              onFontScaleChanged: _updateFontScale,
            ),
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
    final num = _phoneCtrl.text.trim();
    if (num.isEmpty) return;
    setState(() => _loading = true);
    final full = '${_countryCode.dialCode}$num';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('phone', full);
    await prefs.setBool('sync', _syncContacts);
    final root = context.findAncestorStateOfType<_MyMessengerAppState>()!;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatListScreen(
          nick: full,
          fontScale: root._fontScale,
          onFontScaleChanged: root._updateFontScale,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Text('Телефон'), actions: [
        TextButton(
          onPressed: () => exit(0),
          child: Text('Отмена', style: TextStyle(color: Colors.white)),
        ),
      ]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(height: 20),
          Center(child: Icon(Icons.phone, size: 80, color: Colors.redAccent)),
          SizedBox(height: 16),
          Center(child: Text('Телефон', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold))),
          SizedBox(height: 8),
          Center(
            child: Text(
              'Проверьте код страны и введите свой номер телефона.',
              textAlign: TextAlign.center,
            ),
          ),
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
    utf8.decoder.bind(_socket!).transform(const LineSplitter()).listen((l) {
      _pktController.add(json.decode(l));
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

List<int> xorBytes(List<int> d, List<int> k) =>
    [for (var i = 0; i < d.length; i++) d[i] ^ k[i % k.length]];

String encryptStr(String s, List<int> k) =>
    base64.encode(xorBytes(utf8.encode(s), k));

String decryptStr(String s, List<int> k) {
  try {
    return utf8.decode(xorBytes(base64.decode(s), k));
  } catch (_) {
    return '[!decrypt failed]';
  }
}

class ChatListScreen extends StatefulWidget {
  final String nick;
  final double fontScale;
  final ValueChanged<double> onFontScaleChanged;
  ChatListScreen({
    required this.nick,
    required this.fontScale,
    required this.onFontScaleChanged,
  });
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
      for (var c in cs) {
        for (var pn in c.phones ?? []) {
          final num = pn.value!.replaceAll(RegExp(r'\D'), '').trim();
          phoneToName[num] = c.displayName ?? num;
        }
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

  @override
  void dispose() {
    _service.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext ctx) {
    final contacts = registered.where((u) => u != widget.nick).toList();
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.person),
          onPressed: () {
            Navigator.push(
              ctx,
              MaterialPageRoute(
                builder: (_) => SettingsScreen(
                  fontScale: widget.fontScale,
                  onFontScaleChanged: widget.onFontScaleChanged,
                ),
              ),
            );
          },
        ),
        title: Text('Контакты: ${widget.nick}'),
        bottom: TabBar(controller: _tabCtrl, tabs: [Tab(text: 'Недавние'), Tab(text: 'Все')]),
      ),
      body: TabBarView(controller: _tabCtrl, children: [
        // Recent + invites
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
                child: Icon(Icons.delete, color: Colors.white),
              ),
              child: ListTile(
                title: Text(name),
                onTap: () => _openChat(u),
                onLongPress: () async {
                  if (!await Permission.contacts.request().isGranted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Нет разрешения на доступ к контактам')),
                    );
                    return;
                  }
                  final newName = await showDialog<String>(
                    context: ctx,
                    builder: (_) {
                      final ctrl = TextEditingController(text: phoneToName[u] ?? '');
                      return AlertDialog(
                        title: Text('Добавить в контакты'),
                        content: TextField(
                          controller: ctrl,
                          decoration: InputDecoration(hintText: 'Имя контакта'),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Отмена')),
                          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text('OK')),
                        ],
                      );
                    },
                  );
                  if (newName != null && newName.isNotEmpty) {
                    try {
                      final contact = Contact(
                        displayName: newName,
                        phones: [Item(label: 'mobile', value: u)],
                      );
                      await ContactsService.addContact(contact);
                      setState(() {
                        phoneToName[u] = newName;
                      });
                    } catch (e) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Не удалось сохранить контакт: $e')),
                      );
                    }
                  }
                },
              ),
            );
          }).toList(),
        ]),
        // All + invites
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
            Center(
              child: Text('Нет зарегистрированных контактов.\nНажмите + чтобы добавить.', textAlign: TextAlign.center),
            )
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
  bool _showEmojiPicker = false;

  final List<String> _emojis = [
    "😀","😁","😂","🤣","😃","😄","😅","😆","😉","😊","😋","😎","😍","😘","🥰","😗","😙","😚","🙂","🤗","🤩","🤔"
  ];

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

  Future<void> _onPkt(Map<String, dynamic> pkt) async {
    final t = pkt['type'];
    if (t == 'encrypt_request' && pkt['from'] == widget.peer) {
      final sk = deriveSessionKey(widget.peer, widget.service.nick);
      incomingPass = decryptStr(pkt['enc_pass'], sk);
      setState(() {});
    }
    if (t == 'encrypt_response' && pkt['to'] == widget.service.nick) {
      if (pkt['status'] == 'accept') encrypted = true;
      incomingPass = null;
      setState(() {});
    }
    if (t == 'end_encryption' && pkt['to'] == widget.service.nick) {
      _terminateEncryption(applyLocalOnly: true);
    }
    if (t == 'message' && pkt['from'] == widget.peer) {
      final dec = decryptStr(pkt['content'], deriveMsgKey(keys[widget.peer]!));
      messages.add({'who': widget.peer, 'text': dec});
      setState(() {});
    }
    if (t == 'file' && pkt['from'] == widget.peer) {
      final key = deriveMsgKey(keys[widget.peer]!);
      final b64 = decryptStr(pkt['content'], key);
      final bytes = base64.decode(b64);
      final name = pkt['fileName'] as String;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(bytes);
      messages.add({'who': widget.peer, 'fileName': name, 'path': file.path});
      setState(() {});
    }
  }

  Future<void> _askPassword() async {
    final pass = await showDialog<String>(
      context: context,
      builder: (_) {
        final ctl = TextEditingController();
        return AlertDialog(
          title: Text('Пароль для ${widget.peer}'),
          content: TextField(controller: ctl, decoration: InputDecoration(hintText: 'Введите пароль')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(context, ctl.text.trim()), child: Text('OK')),
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

  void _terminateEncryption({bool applyLocalOnly = false}) {
    if (!applyLocalOnly) {
      widget.service.send({
        'type': 'end_encryption',
        'from': widget.service.nick,
        'to': widget.peer,
      });
    }
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

  Future<void> _onAttach() async {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: Icon(Icons.photo),
            title: Text('Галерея'),
            onTap: () {
              Navigator.pop(context);
              _pickImage(ImageSource.gallery);
            },
          ),
          ListTile(
            leading: Icon(Icons.camera_alt),
            title: Text('Камера'),
            onTap: () {
              Navigator.pop(context);
              _pickImage(ImageSource.camera);
            },
          ),
          ListTile(
            leading: Icon(Icons.attach_file),
            title: Text('Файл'),
            onTap: () {
              Navigator.pop(context);
              _pickAnyFile();
            },
          ),
        ]),
      ),
    );
  }

  Future<void> _pickImage(ImageSource src) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: src);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _storeAndSend(bytes, file.name);
  }

  Future<void> _pickAnyFile() async {
    final res = await FilePicker.platform.pickFiles();
    if (res == null) return;
    final single = res.files.single;
    List<int>? bytes = single.bytes;
    if (bytes == null && single.path != null) {
      bytes = await File(single.path!).readAsBytes();
    }
    if (bytes == null) return;
    await _storeAndSend(bytes, single.name);
  }

  Future<void> _storeAndSend(List<int> bytes, String name) async {
    // 1) сохраняем локально
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes);

    // 2) посылаем серверу
    final key = deriveMsgKey(keys[widget.peer]!);
    final dataB64 = base64.encode(bytes);
    final enc = encryptStr(dataB64, key);
    widget.service.send({
      'type': 'file',
      'from': widget.service.nick,
      'to': widget.peer,
      'fileName': name,
      'content': enc,
    });

    // 3) показываем в чате отправителю
    messages.add({'who': widget.service.nick, 'fileName': name, 'path': file.path});
    setState(() {});
  }

  bool _isImage(String name) {
    final ext = name.toLowerCase().split('.').last;
    return ['png', 'jpg', 'jpeg', 'gif', 'bmp', 'webp'].contains(ext);
  }

  void _onEmojiSelected(String em) {
    final t = _msgCtrl.text;
    final sel = _msgCtrl.selection;
    final nt = t.replaceRange(sel.start, sel.end, em);
    _msgCtrl.text = nt;
    _msgCtrl.selection = TextSelection.collapsed(offset: sel.start + em.length);
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
        // Encryption status
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
              onPressed: encrypted ? () => _terminateEncryption() : _askPassword,
              child: Text(encrypted ? 'Разорвать' : 'Зашифровать'),
              style: TextButton.styleFrom(
                backgroundColor: encrypted ? Colors.red : Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ]),
        ),

        // Incoming pass prompt
        if (!encrypted && incomingPass != null)
          Container(
            color: Colors.blue,
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Expanded(child: Text('Пароль: $incomingPass', style: TextStyle(color: Colors.white))),
              TextButton(
                onPressed: _acceptIncoming,
                child: Text('Принять'),
                style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.blue),
              ),
              TextButton(
                onPressed: _declineIncoming,
                child: Text('Отклонить'),
                style: TextButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.blue),
              ),
            ]),
          ),

        // Chat messages
        Expanded(
          child: ListView.builder(
            itemCount: messages.length,
            itemBuilder: (_, i) {
              final m = messages[i];
              final me = m['who'] == widget.service.nick;
              final bg = me ? Colors.blueAccent : Colors.grey[800];

              if (m.containsKey('fileName')) {
                final name = m['fileName']!;
                final path = m['path'];
                if (_isImage(name) && path != null) {
                  // Image thumbnail
                  return Align(
                    alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: () => OpenFile.open(path),
                      onLongPress: () async {
                        final saveDir = (await getExternalStorageDirectory())?.path;
                        if (saveDir != null) {
                          final dst = File('$saveDir/$name');
                          await File(path).copy(dst.path);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Сохранено в $saveDir')),
                          );
                        }
                      },
                      child: Container(
                        margin: EdgeInsets.all(6),
                        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.file(File(path!), width: 150, height: 150, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  );
                } else {
                  // Non-image file with icon+extension
                  final ext = name.contains('.') ? name.split('.').last.toUpperCase() : '';
                  return Align(
                    alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                    child: GestureDetector(
                      onTap: path != null ? () => OpenFile.open(path) : null,
                      onLongPress: () async {
                        final saveDir = (await getExternalStorageDirectory())?.path;
                        if (saveDir != null) {
                          final dst = File('$saveDir/$name');
                          await File(path!).copy(dst.path);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Сохранено в $saveDir')),
                          );
                        }
                      },
                      child: Container(
                        margin: EdgeInsets.all(6),
                        padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 72,
                            height: 72,
                            decoration: BoxDecoration(color: Colors.grey[700], borderRadius: BorderRadius.circular(8)),
                            alignment: Alignment.center,
                            child: Text(ext, style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                          ),
                          SizedBox(height: 6),
                          SizedBox(
                            width: 100,
                            child: Text(
                              name,
                              style: TextStyle(color: Colors.white, fontSize: 12),
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ]),
                      ),
                    ),
                  );
                }
              } else {
                // Plain text
                return Align(
                  alignment: me ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: EdgeInsets.all(6),
                    padding: EdgeInsets.all(10),
                    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                    child: Text(m['text']!, style: TextStyle(color: Colors.white)),
                  ),
                );
              }
            },
          ),
        ),

        Divider(height: 1),

        // Input row
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(children: [
            IconButton(
              icon: Icon(Icons.add, color: encrypted ? Colors.blue : Colors.grey),
              onPressed: encrypted ? _onAttach : null,
            ),
            Expanded(
              child: TextField(
                controller: _msgCtrl,
                enabled: encrypted,
                decoration: InputDecoration(
                  hintText: encrypted ? 'Сообщение' : 'Сначала зашифруйте диалог',
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.emoji_emotions, color: Colors.orange),
              onPressed: encrypted ? () => setState(() => _showEmojiPicker = !_showEmojiPicker) : null,
            ),
            IconButton(icon: Icon(Icons.send), onPressed: encrypted ? _sendMessage : null),
          ]),
        ),

        // Emoji picker
        if (_showEmojiPicker && encrypted)
          Container(
            height: 200,
            color: Colors.grey[900],
            child: GridView.builder(
              padding: EdgeInsets.all(8),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 8,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: _emojis.length,
              itemBuilder: (_, idx) => GestureDetector(
                onTap: () => _onEmojiSelected(_emojis[idx]),
                child: Center(child: Text(_emojis[idx], style: TextStyle(fontSize: 24))),
              ),
            ),
          ),
      ]),
    );
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
}

class SettingsScreen extends StatelessWidget {
  final double fontScale;
  final ValueChanged<double> onFontScaleChanged;
  SettingsScreen({required this.fontScale, required this.onFontScaleChanged});

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
        ListTile(
          leading: Icon(Icons.text_fields),
          title: Text('Размер шрифта'),
          subtitle: Text('${(fontScale * 100).round()}%'),
          onTap: () {
            Navigator.push(
              c,
              MaterialPageRoute(
                builder: (_) => FontSizeScreen(
                  initialScale: fontScale,
                  onChanged: onFontScaleChanged,
                ),
              ),
            );
          },
        ),
      ]),
    );
  }
}

class FontSizeScreen extends StatefulWidget {
  final double initialScale;
  final ValueChanged<double> onChanged;
  FontSizeScreen({required this.initialScale, required this.onChanged});

  @override
  _FontSizeScreenState createState() => _FontSizeScreenState();
}

class _FontSizeScreenState extends State<FontSizeScreen> {
  late double _current;

  @override
  void initState() {
    super.initState();
    _current = widget.initialScale;
  }

  @override
  Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Text('Размер шрифта')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text('Регулируйте размер шрифта', style: TextStyle(fontSize: 18)),
          SizedBox(height: 24),
          Slider(
            value: _current,
            min: 0.8,
            max: 1.5,
            divisions: 14,
            label: '${(_current * 100).round()}%',
            onChanged: (v) {
              setState(() => _current = v);
              widget.onChanged(v);
            },
          ),
          SizedBox(height: 16),
          Text('Пример: Заголовок', style: TextStyle(fontSize: 20)),
          Text('Пример: Обычный текст', style: TextStyle(fontSize: 16)),
        ]),
      ),
    );
  }
}
