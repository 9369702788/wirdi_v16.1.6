
import 'dart:async';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/radio_station.dart';
import '../data/radio_stations.dart';

enum RadioState { stopped, loading, playing, error }

class RadioService extends ChangeNotifier {
  RadioService._();
  static final RadioService instance = RadioService._();

  final AudioPlayer _player = AudioPlayer();
  RadioState _state = RadioState.stopped;
  RadioStation? _currentStation;
  String? _errorMessage;
  Timer? _sleepTimer;
  Timer? _sleepCountdown;
  int? _sleepMinutesRemaining;
  Set<String> _favoriteIds = {};
  bool _initialized = false;
  List<RadioStation> _liveStations = [];
  bool _loadingLive = false;

  static const _favsKey = 'radio_favorites';

  RadioState get state             => _state;
  RadioStation? get currentStation => _currentStation;
  String? get errorMessage         => _errorMessage;
  bool get isPlaying               => _state == RadioState.playing;
  bool get isLoading               => _state == RadioState.loading;
  int? get sleepMinutesRemaining   => _sleepMinutesRemaining;
  bool get hasSleepTimer           => _sleepTimer != null;
  bool get loadingLive             => _loadingLive;
  bool isFavorite(String id)       => _favoriteIds.contains(id);

  List<RadioStation> get allStations =>
      _liveStations.isNotEmpty ? _liveStations : kCuratedStations;

  List<RadioStation> get favoriteStations =>
      allStations.where((s) => _favoriteIds.contains(s.id)).toList();

  // ── Init ──────────────────────────────────────────────────────────────────
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    await _loadFavorites();

    // Listen for state changes
    _player.onPlayerStateChanged.listen((ps) {
      debugPrint('[RadioService] PlayerState changed: $ps');
      if (ps == PlayerState.playing) {
        _state = RadioState.playing;
        notifyListeners();
      } else if (ps == PlayerState.stopped || ps == PlayerState.completed) {
        if (_state != RadioState.error) {
          _state = RadioState.stopped;
          notifyListeners();
        }
      }
    });

    // Log any player errors for debugging
    _player.onLog.listen((msg) {
      debugPrint('[RadioService] AudioPlayer log: $msg');
    });

    // Fetch live stations in background
    _fetchLiveStations();
  }

  // ── Fetch from radio-browser.info ─────────────────────────────────────────
  Future<void> _fetchLiveStations() async {
    _loadingLive = true;
    notifyListeners();
    try {
      final uri = Uri.parse(
        'https://de1.api.radio-browser.info/json/stations/search'
        '?tag=quran&limit=40&hidebroken=true&order=votes&reverse=true',
      );
      final resp = await http.get(uri, headers: {
        'User-Agent': 'WirdiApp/1.50 (Islamic companion; wirdi.app)',
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 12));

      if (resp.statusCode == 200) {
        final List<dynamic> data = jsonDecode(resp.body);
        final stations = data
            .map((j) => RadioStation.fromRadioBrowser(j as Map<String, dynamic>))
            .where((s) =>
                s.streamUrl.isNotEmpty &&
                (s.streamUrl.startsWith('http://') ||
                 s.streamUrl.startsWith('https://')))
            .toList();
        if (stations.isNotEmpty) {
          _liveStations = stations;
          debugPrint('[RadioService] Loaded ${stations.length} live stations');
        }
      }
    } catch (e) {
      debugPrint('[RadioService] Failed to fetch live stations: $e');
    } finally {
      _loadingLive = false;
      notifyListeners();
    }
  }

  Future<void> refreshStations() => _fetchLiveStations();

  // ── Play ──────────────────────────────────────────────────────────────────
  Future<void> play(RadioStation station) async {
    debugPrint('[RadioService] play() called: ${station.nameEn} → ${station.streamUrl}');
    try {
      if (_currentStation?.id == station.id && isPlaying) return;

      _state = RadioState.loading;
      _currentStation = station;
      _errorMessage = null;
      notifyListeners();

      // Stop any current playback first
      await _player.stop();

      // Set release mode to STOP (not loop) for live streams
      await _player.setReleaseMode(ReleaseMode.stop);

      // THE KEY CALL: play(UrlSource) is the correct API for HTTP streams
      // Do NOT use setSourceUrl + resume — that is for local files
      debugPrint('[RadioService] Calling _player.play(UrlSource(...))');
      await _player.play(UrlSource(station.streamUrl));
      debugPrint('[RadioService] play() returned without exception');

    } catch (e, stack) {
      debugPrint('[RadioService] play() EXCEPTION: $e');
      debugPrint('[RadioService] Stack: $stack');
      _state = RadioState.error;
      // Show the REAL error message, not a generic one
      _errorMessage = 'Error: $e';
      notifyListeners();
    }
  }

  Future<void> stop() async {
    try { await _player.stop(); } catch (e) {
      debugPrint('[RadioService] stop() error: $e');
    }
    _state = RadioState.stopped;
    _currentStation = null;
    cancelSleepTimer();
    notifyListeners();
  }

  Future<void> togglePlay(RadioStation station) async {
    if (_currentStation?.id == station.id && isPlaying) {
      await stop();
    } else {
      await play(station);
    }
  }

  // ── Sleep Timer ───────────────────────────────────────────────────────────
  void setSleepTimer(int minutes) {
    cancelSleepTimer();
    _sleepMinutesRemaining = minutes;
    _sleepTimer = Timer(Duration(minutes: minutes), () async {
      await stop();
      _sleepMinutesRemaining = null;
      notifyListeners();
    });
    _sleepCountdown = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_sleepMinutesRemaining != null && _sleepMinutesRemaining! > 0) {
        _sleepMinutesRemaining = _sleepMinutesRemaining! - 1;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepCountdown?.cancel();
    _sleepTimer = null;
    _sleepCountdown = null;
    _sleepMinutesRemaining = null;
  }

  // ── Favorites ─────────────────────────────────────────────────────────────
  Future<void> toggleFavorite(String stationId) async {
    if (_favoriteIds.contains(stationId)) {
      _favoriteIds.remove(stationId);
    } else {
      _favoriteIds.add(stationId);
    }
    await _saveFavorites();
    notifyListeners();
  }

  Future<void> _loadFavorites() async {
    final p = await SharedPreferences.getInstance();
    _favoriteIds = (p.getStringList(_favsKey) ?? []).toSet();
  }

  Future<void> _saveFavorites() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList(_favsKey, _favoriteIds.toList());
  }
}
