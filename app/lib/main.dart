// SHINODRIVE — 병みかわ NAS 클라이언트 (Flutter / iOS)
import 'package:chewie/chewie.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

// ── 팔레트 ──
const cBg = Color(0xFF0B0710);
const cBg2 = Color(0xFF100A1A);
const cCard = Color(0xFF181022);
const cCard2 = Color(0xFF20152F);
const cPink = Color(0xFFFF6FB5);
const cHot = Color(0xFFFF2D8E);
const cPurple = Color(0xFFB79CFF);
const cText = Color(0xFFF4ECFF);
const cDim = Color(0xFF9A90BF);
const cGood = Color(0xFF86FFB8);
const cLine = Color(0x3DFF6FB5);

void main() => runApp(const App());

// ── API ──
class Api {
  static final Api I = Api._();
  Api._();
  final Dio dio = Dio();
  String base = '';
  String token = '';
  String user = '';
  String role = '';
  bool canWrite = true;

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    base = p.getString('base') ?? 'http://192.168.45.205:8090';
    token = p.getString('token') ?? '';
    user = p.getString('user') ?? '';
    _apply();
  }

  void _apply() {
    dio.options.baseUrl = base;
    dio.options.headers['Authorization'] = 'Bearer $token';
    dio.options.validateStatus = (s) => s != null && s < 500;
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('base', base);
    await p.setString('token', token);
    await p.setString('user', user);
  }

  Future<bool> ok() async {
    if (token.isEmpty) return false;
    try {
      final r = await dio.get('/api/me');
      if (r.statusCode == 200) {
        user = (r.data['user'] ?? user).toString();
        role = (r.data['role'] ?? '').toString();
        canWrite = r.data['canWrite'] ?? (role != 'reader');
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> login(String server, String username, String pw) async {
    base = server.trim();
    if (!base.startsWith('http')) base = 'http://$base';
    _apply();
    try {
      final r = await dio.post('/api/login', data: {'username': username, 'password': pw});
      if (r.statusCode == 200 && r.data['token'] != null) {
        token = r.data['token'];
        user = (r.data['user'] ?? username).toString();
        role = (r.data['role'] ?? '').toString();
        canWrite = role == 'admin' || role == 'editor';
        _apply();
        await save();
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<void> logout() async {
    token = '';
    await save();
    _apply();
  }

  String media(String action, String path) =>
      '$base/$action?path=${Uri.encodeComponent(path)}&t=${Uri.encodeComponent(token)}';

  Future<List<Entry>> list(String path) async {
    final r = await dio.get('/api/list', queryParameters: {'path': path});
    return (r.data['entries'] as List).map((e) => Entry.fromJson(e)).toList();
  }

  Future<List<Entry>> search(String path, String q) async {
    final r = await dio.get('/api/search', queryParameters: {'path': path, 'q': q});
    return (r.data['entries'] as List).map((e) => Entry.fromJson(e)).toList();
  }

  Future<Map> usage() async => (await dio.get('/api/usage')).data;
  Future<Map> sys() async => (await dio.get('/api/sys')).data;
  Future<void> mkdir(String path, String name) =>
      dio.post('/api/mkdir', data: {'path': path, 'name': name});
  Future<void> del(String path) => dio.post('/api/delete', data: {'path': path});
  Future<void> rename(String path, String nn) =>
      dio.post('/api/rename', data: {'path': path, 'newName': nn});
  Future<String> share(String path) async {
    final r = await dio.post('/api/share', data: {'path': path});
    return '$base${r.data['url']}';
  }

  Future<void> upload(String path, List<PlatformFile> files, void Function(double) onProg) async {
    final form = FormData();
    for (final f in files) {
      if (f.path == null) continue;
      form.files.add(MapEntry('files', await MultipartFile.fromFile(f.path!, filename: f.name)));
    }
    await dio.post('/api/upload',
        queryParameters: {'path': path},
        data: form,
        onSendProgress: (a, b) => onProg(b > 0 ? a / b : 0));
  }
}

class Entry {
  final String name, rel;
  final bool isDir;
  final int size, mod;
  Entry(this.name, this.isDir, this.size, this.mod, this.rel);
  factory Entry.fromJson(Map e) =>
      Entry(e['name'], e['isDir'] ?? false, e['size'] ?? 0, e['mod'] ?? 0, e['rel'] ?? '');
}

// ── helpers ──
String fb(num b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  double n = b.toDouble();
  int i = 0;
  while (n >= 1024 && i < 4) {
    n /= 1024;
    i++;
  }
  return '${n >= 100 ? n.round() : n.toStringAsFixed(1)} ${u[i]}';
}

const imgExt = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'avif'];
const vidExt = ['mp4', 'webm', 'mkv', 'mov', 'avi', 'm4v', 'ts', 'flv'];
const audExt = ['mp3', 'flac', 'wav', 'ogg', 'm4a', 'opus'];
String extOf(String n) {
  final i = n.lastIndexOf('.');
  return i < 0 ? '' : n.substring(i + 1).toLowerCase();
}

IconData iconFor(Entry e) {
  if (e.isDir) return Icons.folder_rounded;
  final x = extOf(e.name);
  if (imgExt.contains(x)) return Icons.image_rounded;
  if (vidExt.contains(x)) return Icons.movie_rounded;
  if (audExt.contains(x)) return Icons.music_note_rounded;
  if (['zip', 'tar', 'gz', 'xz', '7z', 'rar'].contains(x)) return Icons.folder_zip_rounded;
  if (['txt', 'md', 'pdf', 'json', 'log'].contains(x)) return Icons.description_rounded;
  return Icons.insert_drive_file_rounded;
}

// ── App ──
class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SHINODRIVE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(primary: cPink, secondary: cPurple, surface: cCard),
        fontFamily: 'JetBrainsMono',
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: cCard2,
          contentTextStyle: TextStyle(color: cText, fontSize: 14),
          behavior: SnackBarBehavior.floating,
        ),
        dialogTheme: const DialogThemeData(backgroundColor: cBg2),
      ),
      builder: (context, child) => Stack(children: [
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF140B22), cBg]),
          ),
          child: SizedBox.expand(),
        ),
        Positioned(
          top: -120,
          right: -100,
          child: Container(
            width: 420,
            height: 420,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [cHot.withValues(alpha: .20), Colors.transparent]),
            ),
          ),
        ),
        child ?? const SizedBox(),
      ]),
      home: const Gate(),
    );
  }
}

class Gate extends StatefulWidget {
  const Gate({super.key});
  @override
  State<Gate> createState() => _GateState();
}

class _GateState extends State<Gate> {
  bool? authed;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    await Api.I.load();
    final ok = await Api.I.ok();
    setState(() => authed = ok);
  }

  @override
  Widget build(BuildContext context) {
    if (authed == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator(color: cPink)));
    }
    return authed! ? const Browser() : LoginScreen(onDone: () => setState(() => authed = true));
  }
}

// ── 로그인 ──
class LoginScreen extends StatefulWidget {
  final VoidCallback onDone;
  const LoginScreen({super.key, required this.onDone});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final server = TextEditingController(text: Api.I.base);
  final usr = TextEditingController(text: Api.I.user);
  final pw = TextEditingController();
  String err = '';
  bool busy = false;

  Future<void> _go() async {
    setState(() {
      busy = true;
      err = '';
    });
    final ok = await Api.I.login(server.text, usr.text.trim(), pw.text);
    if (ok) {
      widget.onDone();
    } else {
      setState(() {
        busy = false;
        err = '접속 실패… 주소나 비번 확인해봐 ♡';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('♥ SHINODRIVE ♥',
                textAlign: TextAlign.center,
                style: TextStyle(color: cPink, fontFamily: 'PressStart2P', fontSize: 16)),
            const SizedBox(height: 6),
            const SizedBox(height: 4),
            const Text('病みかわ NAS ・ ぱすわーど いれて ♡', style: TextStyle(color: cDim, fontSize: 13)),
            const SizedBox(height: 28),
            _field(server, '서버 주소 (예: 192.168.45.205:8090)', false),
            const SizedBox(height: 12),
            _field(usr, '아이디', false),
            const SizedBox(height: 12),
            _field(pw, 'password…', true, onSubmit: _go),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : _go,
                style: FilledButton.styleFrom(
                    backgroundColor: cPink,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: busy
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('ログイン ♥', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
            Text(err, style: const TextStyle(color: cHot, fontSize: 12)),
          ]),
        ),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, bool obscure, {VoidCallback? onSubmit}) {
    return TextField(
      controller: c,
      obscureText: obscure,
      style: const TextStyle(color: cText),
      onSubmitted: (_) => onSubmit?.call(),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: cDim, fontSize: 13),
        filled: true,
        fillColor: cCard,
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: cLine)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: cPink)),
      ),
    );
  }
}

// ── 브라우저 ──
class Browser extends StatefulWidget {
  const Browser({super.key});
  @override
  State<Browser> createState() => _BrowserState();
}

class _BrowserState extends State<Browser> {
  String cur = '/';
  List<Entry> entries = [];
  bool grid = false, loading = true, searching = false;
  Map usageData = {};
  Map sysData = {};

  @override
  void initState() {
    super.initState();
    _load();
    _poll();
  }

  Future<void> _load() async {
    setState(() => loading = true);
    try {
      entries = await Api.I.list(cur);
    } catch (_) {}
    if (mounted) setState(() => loading = false);
    _refreshMeta();
  }

  Future<void> _refreshMeta() async {
    try {
      usageData = await Api.I.usage();
      if (mounted) setState(() {});
    } catch (_) {}
  }

  void _poll() async {
    while (mounted) {
      try {
        sysData = await Api.I.sys();
        if (mounted) setState(() {});
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 3));
    }
  }

  void _nav(String p) {
    cur = p;
    searching = false;
    _load();
  }

  Future<void> _doSearch(String q) async {
    if (q.trim().isEmpty) {
      _load();
      return;
    }
    searching = true;
    try {
      entries = await Api.I.search(cur, q.trim());
      if (mounted) setState(() {});
    } catch (_) {}
  }

  String pathOf(Entry e) => e.rel.isNotEmpty ? e.rel : (cur == '/' ? '' : cur) + '/' + e.name;

  void _open(Entry e) {
    if (e.isDir) {
      _nav(pathOf(e));
    } else {
      final x = extOf(e.name);
      if (imgExt.contains(x) || vidExt.contains(x) || audExt.contains(x)) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => Preview(entry: e, path: pathOf(e))));
      } else {
        _download(e);
      }
    }
  }

  Future<void> _download(Entry e) async {
    _toast('내려받는 중…');
    try {
      final dir = await getTemporaryDirectory();
      final fp = '${dir.path}/${e.name}';
      await Api.I.dio.download(Api.I.media(e.isDir ? 'api/zip' : 'dl', pathOf(e)), fp);
      await Share.shareXFiles([XFile(fp)]);
    } catch (_) {
      _toast('실패…💔');
    }
  }

  Future<void> _upload() async {
    final res = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (res == null || res.files.isEmpty) return;
    final entry = _uploadProgress();
    try {
      await Api.I.upload(cur, res.files, (p) => entry.value = p);
      entry.remove();
      _toast('올렸어 ♡');
      _load();
    } catch (_) {
      entry.remove();
      _toast('업로드 실패…💔');
    }
  }

  _Prog _uploadProgress() {
    final notifier = ValueNotifier<double>(0);
    final overlay = OverlayEntry(
      builder: (_) => Positioned(
        left: 14,
        right: 14,
        bottom: 30,
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: cCard2, borderRadius: BorderRadius.circular(14), border: Border.all(color: cLine)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('올리는 중…', style: TextStyle(color: cPink, fontSize: 12)),
              const SizedBox(height: 8),
              ValueListenableBuilder<double>(
                valueListenable: notifier,
                builder: (_, v, __) => ClipRRect(
                  borderRadius: BorderRadius.circular(5),
                  child: LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: Colors.white10, color: cPink),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
    Overlay.of(context).insert(overlay);
    return _Prog(notifier, overlay);
  }

  void _toast(String m) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: cCard2,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 1600),
    ));
  }

  Future<void> _share(Entry e) async {
    try {
      final link = await Api.I.share(pathOf(e));
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          backgroundColor: cBg2,
          title: const Text('🔗 링크 공유 ♡', style: TextStyle(color: cPink, fontSize: 15)),
          content: SelectableText(link, style: const TextStyle(color: cText, fontSize: 13)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기', style: TextStyle(color: cDim))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cPink),
              onPressed: () {
                Share.share(link);
                Navigator.pop(context);
              },
              child: const Text('보내기 ♥'),
            ),
          ],
        ),
      );
    } catch (_) {
      _toast('공유 실패…💔');
    }
  }

  void _menu(Entry e) {
    showModalBottomSheet(
      context: context,
      backgroundColor: cBg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(width: 42, height: 4, decoration: BoxDecoration(color: const Color(0xFF3A2F4D), borderRadius: BorderRadius.circular(3))),
          const SizedBox(height: 8),
          _mrow(e.isDir ? Icons.folder_zip_rounded : Icons.download_rounded, e.isDir ? 'ZIP 다운로드' : '다운로드', () {
            Navigator.pop(context);
            _download(e);
          }),
          _mrow(Icons.share_rounded, '링크 공유', () {
            Navigator.pop(context);
            _share(e);
          }),
          if (Api.I.canWrite) ...[
            _mrow(Icons.edit_rounded, '이름 바꾸기', () {
              Navigator.pop(context);
              _rename(e);
            }),
            _mrow(Icons.delete_rounded, '삭제', () {
              Navigator.pop(context);
              _del(e);
            }, danger: true),
          ],
          const SizedBox(height: 10),
        ]),
      ),
    );
  }

  Widget _mrow(IconData ic, String t, VoidCallback fn, {bool danger = false}) {
    final c = danger ? cHot : cText;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
      leading: Icon(ic, color: danger ? cHot : cPink, size: 26),
      title: Text(t, style: TextStyle(color: c, fontSize: 17)),
      onTap: fn,
    );
  }

  Future<void> _rename(Entry e) async {
    final c = TextEditingController(text: e.name);
    final nn = await _prompt('이름 바꾸기', c);
    if (nn != null && nn.isNotEmpty) {
      await Api.I.rename(pathOf(e), nn);
      _load();
    }
  }

  Future<void> _newFolder() async {
    final c = TextEditingController();
    final name = await _prompt('새 폴더 ♡', c);
    if (name != null && name.isNotEmpty) {
      await Api.I.mkdir(cur, name);
      _load();
    }
  }

  Future<String?> _prompt(String title, TextEditingController c) {
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cBg2,
        title: Text(title, style: const TextStyle(color: cPink, fontSize: 15)),
        content: TextField(controller: c, autofocus: true, style: const TextStyle(color: cText)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: cDim))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cPink),
              onPressed: () => Navigator.pop(context, c.text.trim()),
              child: const Text('확인 ♥')),
        ],
      ),
    );
  }

  Future<void> _del(Entry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cBg2,
        title: const Text('삭제할까…?', style: TextStyle(color: cPink, fontSize: 15)),
        content: Text(e.name, style: const TextStyle(color: cDim)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('아니', style: TextStyle(color: cDim))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: cHot),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('삭제')),
        ],
      ),
    );
    if (ok == true) {
      await Api.I.del(pathOf(e));
      _load();
    }
  }

  void _addSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: cBg2,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (_) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 16),
          _mrow(Icons.upload_rounded, '파일 올리기', () {
            Navigator.pop(context);
            _upload();
          }),
          _mrow(Icons.create_new_folder_rounded, '새 폴더', () {
            Navigator.pop(context);
            _newFolder();
          }),
          const SizedBox(height: 10),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        toolbarHeight: 62,
        title: Row(children: const [
          Icon(Icons.favorite, color: cHot, size: 20),
          SizedBox(width: 9),
          Text('SHINODRIVE', style: TextStyle(color: cPink, fontFamily: 'PressStart2P', fontSize: 15)),
        ]),
        actionsIconTheme: const IconThemeData(size: 26),
        actions: [
          IconButton(icon: const Icon(Icons.search_rounded, color: cPink), onPressed: _searchDialog),
          IconButton(icon: Icon(grid ? Icons.view_list_rounded : Icons.grid_view_rounded, color: cPink), onPressed: () => setState(() => grid = !grid)),
          IconButton(icon: const Icon(Icons.power_settings_new_rounded, color: cPink), onPressed: _logout),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        _metaBar(),
        _crumbs(),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator(color: cPink))
              : RefreshIndicator(
                  color: cPink,
                  backgroundColor: cCard,
                  onRefresh: _load,
                  child: entries.isEmpty ? _empty() : (grid ? _grid() : _list()),
                ),
        ),
      ]),
      floatingActionButton: Api.I.canWrite
          ? SizedBox(
              width: 66,
              height: 66,
              child: FloatingActionButton(
                backgroundColor: cPink,
                elevation: 8,
                shape: const CircleBorder(),
                onPressed: _addSheet,
                child: const Icon(Icons.add, color: Colors.white, size: 34),
              ),
            )
          : null,
    );
  }

  Widget _metaBar() {
    final total = (usageData['total'] ?? 0).toDouble();
    final used = (usageData['used'] ?? 0).toDouble();
    final cpu = (sysData['cpu'] ?? 0);
    final mem = (sysData['mem']?['pct'] ?? 0);
    final temp = (sysData['temp'] ?? 0);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: Column(children: [
        Row(children: [
          const Icon(Icons.storage_rounded, color: cPurple, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: total > 0 ? used / total : 0,
                minHeight: 11,
                backgroundColor: Colors.white10,
                color: cPink,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text('${fb(used)} / ${fb(total)}', style: const TextStyle(color: cDim, fontSize: 13)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          _chip(Icons.bolt_rounded, '${cpu.round()}%'),
          const SizedBox(width: 7),
          _chip(Icons.memory_rounded, '${(mem is num ? mem.round() : 0)}%'),
          const SizedBox(width: 7),
          _chip(Icons.thermostat_rounded, '${temp.round()}°'),
        ]),
      ]),
    );
  }

  Widget _chip(IconData ic, String v) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(color: cCard, borderRadius: BorderRadius.circular(12), border: Border.all(color: cLine)),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(ic, color: cPurple, size: 19),
            const SizedBox(width: 7),
            Text(v, style: const TextStyle(color: cPink, fontWeight: FontWeight.bold, fontSize: 16)),
          ]),
        ),
      );

  Widget _crumbs() {
    final parts = cur.split('/').where((s) => s.isNotEmpty).toList();
    String acc = '';
    final widgets = <Widget>[
      InkWell(onTap: () => _nav('/'), child: const Text('♥ home', style: TextStyle(color: cPink, fontWeight: FontWeight.bold, fontSize: 15))),
    ];
    for (final p in parts) {
      acc += '/$p';
      final a = acc;
      widgets.add(const Text('  /  ', style: TextStyle(color: cDim, fontSize: 14)));
      widgets.add(InkWell(onTap: () => _nav(a), child: Text(p, style: const TextStyle(color: cDim, fontSize: 14))));
    }
    return Container(
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 10),
      child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: widgets)),
    );
  }

  Widget _empty() => ListView(children: const [
        SizedBox(height: 120),
        Icon(Icons.favorite, color: cPink, size: 40),
        SizedBox(height: 12),
        Center(child: Text('텅 비었어… ♡', style: TextStyle(color: cPink))),
      ]);

  Widget _list() => ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
        itemCount: entries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 9),
        itemBuilder: (_, i) {
          final e = entries[i];
          return Material(
            color: cCard,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: e.isDir ? cLine : cLine.withValues(alpha: .12)),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _open(e),
              onLongPress: () => _menu(e),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
                child: Row(children: [
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: (e.isDir ? cPink : cPurple).withValues(alpha: .12),
                      borderRadius: BorderRadius.circular(13),
                    ),
                    child: Icon(iconFor(e), color: e.isDir ? cPink : cPurple, size: 26),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cText, fontSize: 17)),
                      const SizedBox(height: 4),
                      Text(e.isDir ? '폴더' : fb(e.size), style: const TextStyle(color: cDim, fontSize: 13)),
                    ]),
                  ),
                  IconButton(icon: const Icon(Icons.more_vert_rounded, color: cDim, size: 24), onPressed: () => _menu(e)),
                ]),
              ),
            ),
          );
        },
      );

  Widget _grid() => GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 2, 12, 90),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 156, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .82),
        itemCount: entries.length,
        itemBuilder: (_, i) {
          final e = entries[i];
          final x = extOf(e.name);
          final showThumb = !e.isDir && (imgExt.contains(x) || vidExt.contains(x));
          return Material(
            color: cCard,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: cLine.withValues(alpha: .2))),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _open(e),
              onLongPress: () => _menu(e),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: Container(
                    color: cCard2,
                    child: showThumb
                        ? Image.network(Api.I.media('thumb', pathOf(e)), fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Icon(iconFor(e), color: cPurple, size: 42))
                        : Icon(iconFor(e), color: e.isDir ? cPink : cPurple, size: 42),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(e.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: cText, fontSize: 14)),
                ),
              ]),
            ),
          );
        },
      );

  Future<void> _searchDialog() async {
    final c = TextEditingController();
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: cBg2,
        title: const Text('🔍 검색', style: TextStyle(color: cPink, fontSize: 15)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: const TextStyle(color: cText),
          decoration: const InputDecoration(hintText: 'なにさがす？ ♡', hintStyle: TextStyle(color: cDim)),
          onSubmitted: (q) {
            Navigator.pop(context);
            _doSearch(q);
          },
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: cPink),
            onPressed: () {
              Navigator.pop(context);
              _doSearch(c.text);
            },
            child: const Text('찾기 ♥'),
          ),
        ],
      ),
    );
  }

  Future<void> _logout() async {
    await Api.I.logout();
    if (mounted) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const Gate()));
    }
  }
}

class _Prog {
  final ValueNotifier<double> notifier;
  final OverlayEntry overlay;
  _Prog(this.notifier, this.overlay);
  set value(double v) => notifier.value = v;
  void remove() => overlay.remove();
}

// ── 미리보기 ──
class Preview extends StatefulWidget {
  final Entry entry;
  final String path;
  const Preview({super.key, required this.entry, required this.path});
  @override
  State<Preview> createState() => _PreviewState();
}

class _PreviewState extends State<Preview> {
  VideoPlayerController? vc;
  ChewieController? chewie;
  bool err = false;

  @override
  void initState() {
    super.initState();
    final x = extOf(widget.entry.name);
    if (vidExt.contains(x) || audExt.contains(x)) {
      final native = ['mp4', 'webm', 'm4v', 'mov'].contains(x);
      vc = VideoPlayerController.networkUrl(Uri.parse(Api.I.media(native ? 'raw' : 'stream', widget.path)));
      vc!.initialize().then((_) {
        chewie = ChewieController(
          videoPlayerController: vc!,
          autoPlay: true,
          looping: false,
          allowFullScreen: true,
          allowMuting: true,
          aspectRatio: vc!.value.aspectRatio == 0 ? 16 / 9 : vc!.value.aspectRatio,
          materialProgressColors: ChewieProgressColors(
            playedColor: cPink,
            handleColor: cHot,
            bufferedColor: Colors.white24,
            backgroundColor: Colors.white10,
          ),
          placeholder: const ColoredBox(color: Colors.black),
        );
        if (mounted) setState(() {});
      }).catchError((_) {
        if (mounted) setState(() => err = true);
      });
    }
  }

  @override
  void dispose() {
    chewie?.dispose();
    vc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final x = extOf(widget.entry.name);
    Widget body;
    if (imgExt.contains(x)) {
      body = InteractiveViewer(minScale: 0.5, maxScale: 5, child: Image.network(Api.I.media('raw', widget.path)));
    } else if (err) {
      body = const Text('재생할 수 없어…💔', style: TextStyle(color: cDim));
    } else if (chewie != null) {
      body = Chewie(controller: chewie!);
    } else {
      body = const CircularProgressIndicator(color: cPink);
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: cPink),
        title: Text(widget.entry.name, style: const TextStyle(color: cText, fontSize: 14)),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, color: cPink),
            onPressed: () => Share.share(Api.I.media('dl', widget.path)),
          ),
        ],
      ),
      body: Center(child: body),
    );
  }
}
