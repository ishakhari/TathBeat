import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

void main() => runApp(const LoopApp());

class LoopApp extends StatelessWidget {
  const LoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TathBeat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF3DDC97),
        scaffoldBackgroundColor: const Color(0xFF101418),
      ),
      home: const LooperPage(),
    );
  }
}

class LooperPage extends StatefulWidget {
  const LooperPage({super.key});

  @override
  State<LooperPage> createState() => _LooperPageState();
}

class _LooperPageState extends State<LooperPage> {
  final _urlCtl = TextEditingController();
  final _startCtl = TextEditingController(text: '0:00');
  final _endCtl = TextEditingController(text: '0:00');

  YoutubePlayerController? _player;
  final List<StreamSubscription> _subs = [];
  bool _initializing = false;
  Timer? _initTimer;
  int _loadId = 0;

  int _total = 0; // video length, seconds
  int _start = 0; // loop start, seconds
  int _end = 0; // loop end, seconds
  double _position = 0; // current playback position, seconds
  bool _isPlaying = false;
  bool _loop = true;
  double _speed = 1.0;
  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
  String? _error;
  int _lastCommittedStart = 0;
  String _loadedUrl = ''; // link of the video currently loaded
  int? _pendingStart; // start/end to apply once the duration is known
  int? _pendingEnd;

  @override
  void dispose() {
    _closePlayer();
    _urlCtl.dispose();
    _startCtl.dispose();
    _endCtl.dispose();
    super.dispose();
  }

  void _closePlayer() {
    _initTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player?.close();
    _player = null;
  }

  // ---------- helpers ----------

  String _fmt(num seconds) {
    final s = seconds.floor();
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final ss = (s % 60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
    return '$m:$ss';
  }

  /// Accepts "75", "1:15" or "1:01:15". Returns null if invalid.
  int? _parse(String text) {
    final parts = text.trim().split(':');
    if (parts.isEmpty || parts.length > 3) return null;
    int total = 0;
    for (final p in parts) {
      final n = int.tryParse(p.trim());
      if (n == null || n < 0) return null;
      total = total * 60 + n;
    }
    return total;
  }

  void _syncFields() {
    _startCtl.text = _fmt(_start);
    _endCtl.text = _fmt(_end);
  }

  void _seek(num seconds) {
    _player?.seekTo(seconds: seconds.toDouble(), allowSeekAhead: true);
  }

  // ---------- player ----------

  /// Pulls the 11-character video id out of any common YouTube link:
  /// youtu.be/ID, youtube.com/watch?v=ID, m./music. variants, /embed/, /shorts/,
  /// /live/, or a bare id. Extra params (&t=, &list=, ?si=) are ignored.
  String? _extractVideoId(String input) {
    var text = input.trim();
    if (text.isEmpty) return null;
    final idPattern = RegExp(r'^[A-Za-z0-9_-]{11}$');
    if (idPattern.hasMatch(text)) return text;

    if (!text.contains('://')) text = 'https://$text';
    final uri = Uri.tryParse(text);
    if (uri == null) return null;

    final host = uri.host.toLowerCase();
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    String? candidate;

    if (host == 'youtu.be' || host == 'www.youtu.be') {
      if (segs.isNotEmpty) candidate = segs.first;
    } else if (host == 'youtube.com' || host.endsWith('.youtube.com') ||
        host == 'youtube-nocookie.com' || host.endsWith('.youtube-nocookie.com')) {
      candidate = uri.queryParameters['v'];
      if (candidate == null && segs.length >= 2 &&
          const ['embed', 'shorts', 'live', 'v'].contains(segs.first)) {
        candidate = segs[1];
      }
    }
    if (candidate != null && idPattern.hasMatch(candidate)) return candidate;
    return null;
  }


  void _loadVideo({int? restoreStart, int? restoreEnd}) {
    FocusScope.of(context).unfocus();
    final id = _extractVideoId(_urlCtl.text);
    if (id == null) {
      setState(() => _error = 'Cela ne ressemble pas à un lien YouTube.');
      return;
    }
    _loadedUrl = _urlCtl.text.trim();
    _pendingStart = restoreStart;
    _pendingEnd = restoreEnd;
    _initTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    final oldPlayer = _player;
    _loadId++;

    // Autoplay briefly so YouTube reports the duration; we pause as soon as
    // we know it (see _tryInit).
    final c = YoutubePlayerController.fromVideoId(
      videoId: id,
      autoPlay: false,
      params: const YoutubePlayerParams(
        showControls: false,
        showFullscreenButton: false,
      ),
    );
    _subs.add(c.stream.listen(_onValue));
    _subs.add(c.videoStateStream.listen((s) => _onVideoPosition(s.position)));

    // Poll for the duration so setup doesn't depend on a player event firing
    // (on a second Load the player may not emit one).
    int tries = 0;
    _initTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      if (!mounted || _total > 0 || ++tries > 60) {
        timer.cancel();
        return;
      }
      _tryInit();
    });

    setState(() {
      _player = c;
      _total = 0;
      _start = 0;
      _end = 0;
      _position = 0;
      _isPlaying = false;
      _error = null;
      _initializing = false;
      _syncFields();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => oldPlayer?.close());
  }

  void _onValue(YoutubePlayerValue v) {
    if (!mounted) return;
    final playing = v.playerState == PlayerState.playing;
    if (_total > 0) {
      if (playing != _isPlaying) setState(() => _isPlaying = playing);
    } else {
      _tryInit();
    }
  }

  Future<void> _tryInit() async {
    final c = _player;
    if (c == null || _initializing || _total > 0) return;
    _initializing = true;
    try {
      final d = (await c.duration.timeout(const Duration(seconds: 2))).round();
      if (!mounted || c != _player) return;
      if (d > 0) {
        c.pauseVideo();
        c.setPlaybackRate(_speed);
        final s0 = (_pendingStart ?? 0).clamp(0, d - 1);
        final e0 = (_pendingEnd ?? d).clamp(s0 + 1, d);
        _pendingStart = null;
        _pendingEnd = null;
        _seek(s0);
        setState(() {
          _total = d;
          _start = s0;
          _end = e0;
          _lastCommittedStart = s0;
          _isPlaying = false;
          _position = 0;
          _syncFields();
        });
      }
    } catch (_) {
      // Player not ready yet; the timer will retry.
    } finally {
      _initializing = false;
    }
  }

  void _onVideoPosition(Duration position) {
    if (!mounted || _total == 0) return;
    final pos = position.inMilliseconds / 1000.0;
    if (_loop && _isPlaying && pos >= _end - 0.15 * _speed) {
      _seek(_start);
    }
    if (pos != _position) setState(() => _position = pos);
  }

  void _setSpeed(double s) {
    setState(() => _speed = s);
    _player?.setPlaybackRate(s);
  }

  void _togglePlay() {
    final c = _player;
    if (c == null || _total == 0) return;
    if (_isPlaying) {
      c.pauseVideo();
    } else {
      if (_position < _start || _position >= _end - 0.2) _seek(_start);
      c.playVideo();
    }
  }

  // ---------- range editing ----------

  void _onRangeChanged(RangeValues r) {
    setState(() {
      _start = r.start.round();
      _end = r.end.round();
      if (_end - _start < 1) {
        if (_start >= _total) {
          _start = _total - 1;
        } else {
          _end = _start + 1;
        }
      }
      _syncFields();
    });
  }

  void _onRangeChangeEnd(RangeValues r) {
    final startMoved = _start != _lastCommittedStart;
    if (startMoved) {
      _seek(_start);
    } else if (_position >= _end) {
      _seek(_start);
    }
    _lastCommittedStart = _start;
  }

  void _applyStartText() {
    final v = _parse(_startCtl.text);
    setState(() {
      if (v != null && _total > 0) _start = v.clamp(0, _end - 1);
      _syncFields();
    });
    _seek(_start);
    _lastCommittedStart = _start;
  }

  void _applyEndText() {
    final v = _parse(_endCtl.text);
    setState(() {
      if (v != null && _total > 0) _end = v.clamp(_start + 1, _total);
      _syncFields();
    });
  }

  void _setStartHere() {
    setState(() {
      _start = _position.floor().clamp(0, _end - 1);
      _syncFields();
    });
    _lastCommittedStart = _start;
  }

  void _setEndHere() {
    setState(() {
      _end = _position.ceil().clamp(_start + 1, _total);
      _syncFields();
    });
  }

  // ---------- favorites ----------

  String _defaultName() {
    const days = [
      'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'
    ];
    const months = [
      'janvier', 'février', 'mars', 'avril', 'mai', 'juin', 'juillet',
      'août', 'septembre', 'octobre', 'novembre', 'décembre'
    ];
    final n = DateTime.now();
    return 'Écoute ${days[n.weekday - 1]} ${n.day} ${months[n.month - 1]}';
  }

  Future<void> _saveFavorite() async {
    if (_loadedUrl.isEmpty || _total == 0) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: 'Enregistrer cette écoute',
        initial: _defaultName(),
        confirmLabel: 'Enregistrer',
      ),
    );
    if (name == null) return;
    final items = await FavoritesStore.load();
    items.insert(
      0,
      Favorite(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        url: _loadedUrl,
        start: _start,
        end: _end,
      ),
    );
    await FavoritesStore.save(items);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('« $name » enregistré')),
    );
  }

  Future<void> _openFavorites() async {
    final fav = await Navigator.of(context).push<Favorite>(
      MaterialPageRoute(builder: (_) => const FavoritesPage()),
    );
    if (fav != null && mounted) _applyFavorite(fav);
  }

  void _applyFavorite(Favorite f) {
    _urlCtl.text = f.url;
    setState(() => _error = null);
    _loadVideo(restoreStart: f.start, restoreEnd: f.end);
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final ready = _player != null && _total > 0;

    return Scaffold(
      appBar: AppBar(
        title: const _BrandTitle(),
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: 'Mes écoutes sauvegardées',
            onPressed: _openFavorites,
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtl,
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _loadVideo(),
                    decoration: InputDecoration(
                      hintText: 'Coller votre lien Youtube',
                      errorText: _error,
                      suffixIcon: ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _urlCtl,
                        builder: (context, value, _) => Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (value.text.isNotEmpty)
                              IconButton(
                                icon: const Icon(Icons.close),
                                tooltip: 'Clear',
                                onPressed: () {
                                  _urlCtl.clear();
                                  if (_error != null) {
                                    setState(() => _error = null);
                                  }
                                },
                              ),
                            IconButton(
                              icon: const Icon(Icons.content_paste),
                              tooltip: 'Paste',
                              onPressed: () async {
                                final data =
                                await Clipboard.getData('text/plain');
                                if (data?.text != null) {
                                  _urlCtl.text = data!.text!;
                                }
                              },
                            ),
                          ],
                        ),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _loadVideo,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(64, 56),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('Go'),
                ),
              ],
            ),
            const SizedBox(height: 16),

            if (_player != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: YoutubePlayer(
                  key: ValueKey(_loadId),
                  controller: _player!,
                  aspectRatio: 16 / 9,
                ),
              )
            else
              AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A2027),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: const Center(
                    child: Text('Entrer votre vidéo Youtube'),
                  ),
                ),
              ),
            const SizedBox(height: 20),

            if (_player != null && !ready)
              const Center(child: CircularProgressIndicator()),

            if (ready) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmt(_start),
                      style: TextStyle(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                  Text('Maintenant ${_fmt(_position)}',
                      style: const TextStyle(color: Colors.white70)),
                  Text(_fmt(_end),
                      style: TextStyle(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                ],
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 8,
                  rangeThumbShape:
                  const RoundRangeSliderThumbShape(enabledThumbRadius: 12),
                  overlayShape:
                  const RoundSliderOverlayShape(overlayRadius: 22),
                ),
                child: RangeSlider(
                  min: 0,
                  max: _total.toDouble(),
                  values: RangeValues(_start.toDouble(), _end.toDouble()),
                  onChangeStart: (r) => _lastCommittedStart = _start,
                  onChanged: _onRangeChanged,
                  onChangeEnd: _onRangeChangeEnd,
                ),
              ),
              LinearProgressIndicator(
                value: (_position / _total).clamp(0.0, 1.0),
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Longueur de la vidéo ${_fmt(_total)}',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _TimeField(
                      label: 'Début',
                      controller: _startCtl,
                      onCommit: _applyStartText,
                      onSetHere: _setStartHere,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _TimeField(
                      label: 'Fin',
                      controller: _endCtl,
                      onCommit: _applyEndText,
                      onSetHere: _setEndHere,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton.filledTonal(
                    iconSize: 28,
                    tooltip: 'Jump to start',
                    onPressed: () => _seek(_start),
                    icon: const Icon(Icons.skip_previous),
                  ),
                  const SizedBox(width: 20),
                  IconButton.filled(
                    iconSize: 44,
                    padding: const EdgeInsets.all(14),
                    onPressed: _togglePlay,
                    icon: Icon(_isPlaying ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 20),
                  IconButton.filledTonal(
                    iconSize: 28,
                    tooltip: _loop ? 'Loop on' : 'Loop off',
                    isSelected: _loop,
                    onPressed: () => setState(() => _loop = !_loop),
                    icon: const Icon(Icons.repeat),
                    selectedIcon: const Icon(Icons.repeat_on),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  for (final s in _speeds)
                    ChoiceChip(
                      label: Text('${s == s.roundToDouble() ? s.toInt() : s}x'),
                      selected: _speed == s,
                      onSelected: (_) => _setSpeed(s),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              FilledButton.tonalIcon(
                onPressed: _saveFavorite,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('Enregistrer cette écoute'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({
    required this.label,
    required this.controller,
    required this.onCommit,
    required this.onSetHere,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onCommit;
  final VoidCallback onSetHere;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.datetime,
          textInputAction: TextInputAction.done,
          textAlign: TextAlign.center,
          onSubmitted: (_) => onCommit(),
          onTapOutside: (_) {
            onCommit();
            FocusScope.of(context).unfocus();
          },
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
          decoration: InputDecoration(
            labelText: '$label (hh:mm:ss)',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        const SizedBox(height: 6),
        TextButton.icon(
          onPressed: onSetHere,
          icon: const Icon(Icons.my_location, size: 16),
          label: Text('$label = Maintenant'),
        ),
      ],
    );
  }
}


/// App bar title: fixed-size logo + wordmark that can never overflow.
class _BrandTitle extends StatelessWidget {
  const _BrandTitle();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Image.asset('assets/icon/icon.png', fit: BoxFit.cover),
          ),
        ),
        const SizedBox(width: 10),
        const Flexible(
          child: Text(
            'TathBeat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: -0.5),
          ),
        ),
      ],
    );
  }
}


// ======================= Favorites =======================

String formatSeconds(int seconds) {
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
  return '$m:$s';
}

class Favorite {
  Favorite({
    required this.id,
    required this.name,
    required this.url,
    required this.start,
    required this.end,
  });

  final String id;
  String name;
  final String url;
  final int start; // seconds
  final int end; // seconds

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'url': url, 'start': start, 'end': end};

  factory Favorite.fromJson(Map<String, dynamic> j) => Favorite(
    id: j['id'] as String,
    name: j['name'] as String,
    url: j['url'] as String,
    start: j['start'] as int,
    end: j['end'] as int,
  );
}

class FavoritesStore {
  static const _key = 'favorites_v1';

  static Future<List<Favorite>> load() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Favorite.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<Favorite> items) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_key, jsonEncode(items.map((e) => e.toJson()).toList()));
  }
}

class FavoritesPage extends StatefulWidget {
  const FavoritesPage({super.key});

  @override
  State<FavoritesPage> createState() => _FavoritesPageState();
}

class _FavoritesPageState extends State<FavoritesPage> {
  List<Favorite>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await FavoritesStore.load();
    if (mounted) setState(() => _items = l);
  }

  Future<void> _rename(Favorite f) async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: 'Renommer',
        initial: f.name,
        confirmLabel: 'OK',
      ),
    );
    if (name == null) return;
    setState(() => f.name = name);
    await FavoritesStore.save(_items!);
  }

  Future<void> _delete(Favorite f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ?'),
        content: Text('« ${f.name} » sera supprimé.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _items!.remove(f));
    await FavoritesStore.save(_items!);
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mes écoutes sauvegardées'),
        backgroundColor: Colors.transparent,
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'Aucune écoute sauvegardée.\n'
                'Charge une vidéo, règle ton début et ta fin, '
                'puis appuie sur « Enregistrer cette écoute ».',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ),
      )
          : ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final f = items[i];
          return Card(
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            child: ListTile(
              contentPadding:
              const EdgeInsets.fromLTRB(16, 6, 4, 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              leading: const Icon(Icons.bookmark),
              title: Text(f.name,
                  style:
                  const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text(
                '${formatSeconds(f.start)} → ${formatSeconds(f.end)}'
                    '  ·  ${f.url}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, f),
              trailing: PopupMenuButton<String>(
                onSelected: (v) =>
                v == 'rename' ? _rename(f) : _delete(f),
                itemBuilder: (_) => const [
                  PopupMenuItem(
                      value: 'rename', child: Text('Renommer')),
                  PopupMenuItem(
                      value: 'delete', child: Text('Supprimer')),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.initial,
    required this.confirmLabel,
  });

  final String title;
  final String initial;
  final String confirmLabel;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _ctl =
  TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = _ctl.text.trim();
    if (n.isEmpty) return;
    Navigator.pop(context, n);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _submit(),
        decoration: const InputDecoration(labelText: 'Nom'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}