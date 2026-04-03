import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const IPCameraWatcherApp());
}

class IPCameraWatcherApp extends StatelessWidget {
  const IPCameraWatcherApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedColor = Color(0xFFB63B24);

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'IP Camera Face Watch',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedColor,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF6EFE8),
        useMaterial3: true,
      ),
      home: const CameraWatcherPage(),
    );
  }
}

class _TargetSelectionResult {
  const _TargetSelectionResult({
    required this.croppedBytes,
    required this.signature,
  });

  final Uint8List croppedBytes;
  final List<int> signature;
}

enum CameraVendor { hikvision, dahuaXvr }

class CameraWatcherPage extends StatefulWidget {
  const CameraWatcherPage({super.key});

  @override
  State<CameraWatcherPage> createState() => _CameraWatcherPageState();
}

class _CameraWatcherPageState extends State<CameraWatcherPage> {
  static const String _defaultHikvisionUrl =
      'http://192.168.19.22/ISAPI/Streaming/channels/1/picture';
  static const String _defaultDahuaUrl =
      'http://192.168.19.22/cgi-bin/snapshot.cgi';

  CameraVendor _selectedVendor = CameraVendor.hikvision;
  final TextEditingController _cameraUrlController = TextEditingController();
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _dahuaChannelCountController =
      TextEditingController(text: '4');
  final TextEditingController _dahuaRtspPortController = TextEditingController(
    text: '554',
  );
  final TextEditingController _thresholdController = TextEditingController(
    text: '88',
  );
  final TextEditingController _intervalController = TextEditingController(
    text: '3',
  );

  Uint8List? _currentFrameBytes;
  Uint8List? _liveFrameBytes;
  Uint8List? _targetFrameBytes;
  List<int>? _targetSignature;
  final Map<int, Uint8List?> _dahuaLiveFrames = {};
  final Map<int, bool> _dahuaChannelConnected = {};
  int _selectedCameraChannel = 1;
  int? _fullscreenLiveChannel;
  int _dahuaRefreshCursor = 1;
  Player? _dahuaPlayer;
  VideoController? _dahuaVideoController;
  StreamSubscription<bool>? _dahuaPlayingSubscription;
  StreamSubscription<String>? _dahuaErrorSubscription;

  bool _isFetchingFrame = false;
  bool _isRefreshingLive = false;
  bool _isSavingTarget = false;
  bool _isMonitoring = false;
  bool _isLiveStreaming = false;
  bool _isLiveConnected = false;
  bool _isLiveFullscreenVisible = false;
  bool _alarmVisible = false;
  bool _alarmMuted = false;

  String _statusText =
      'Default camera loaded for 192.168.19.22. Capture a frame to begin.';
  double _lastSimilarity = 0;
  DateTime? _lastFrameAt;
  DateTime? _lastAlertAt;

  Timer? _monitorTimer;
  Timer? _liveTimer;
  Timer? _alarmTimer;

  @override
  void initState() {
    super.initState();
    _restoreSavedConfig();
  }

  @override
  void dispose() {
    _cameraUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _dahuaChannelCountController.dispose();
    _dahuaRtspPortController.dispose();
    _thresholdController.dispose();
    _intervalController.dispose();
    _monitorTimer?.cancel();
    _liveTimer?.cancel();
    _alarmTimer?.cancel();
    _disposeDahuaPlayer();
    super.dispose();
  }

  Future<void> _restoreSavedConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final savedVendor = prefs.getString('camera_vendor');
    final savedUrl = prefs.getString('camera_url');
    final savedUsername = prefs.getString('camera_username');
    final savedPassword = prefs.getString('camera_password');
    final savedDahuaChannelCount = prefs.getInt('dahua_channel_count');
    final savedDahuaRtspPort = prefs.getString('dahua_rtsp_port');
    final savedSelectedChannel = prefs.getInt('selected_camera_channel');
    final savedThreshold = prefs.getDouble('match_threshold');
    final savedInterval = prefs.getInt('poll_interval');
    final targetImage = prefs.getString('target_frame_b64');

    if (savedVendor == CameraVendor.dahuaXvr.name) {
      _selectedVendor = CameraVendor.dahuaXvr;
    }
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _cameraUrlController.text = savedUrl;
    } else {
      _cameraUrlController.text = _defaultUrlForVendor(_selectedVendor);
    }
    if (savedUsername != null) {
      _usernameController.text = savedUsername;
    }
    if (savedPassword != null) {
      _passwordController.text = savedPassword;
    }
    if (savedDahuaChannelCount != null) {
      _dahuaChannelCountController.text = savedDahuaChannelCount.toString();
    }
    if (savedDahuaRtspPort != null && savedDahuaRtspPort.isNotEmpty) {
      _dahuaRtspPortController.text = savedDahuaRtspPort;
    }
    if (savedSelectedChannel != null) {
      _selectedCameraChannel = savedSelectedChannel;
    }
    if (savedThreshold != null) {
      _thresholdController.text = savedThreshold.round().toString();
    }
    if (savedInterval != null) {
      _intervalController.text = savedInterval.toString();
    }
    if (targetImage != null && targetImage.isNotEmpty) {
      final bytes = base64Decode(targetImage);
      _targetFrameBytes = bytes;
      _targetSignature = _buildSignature(bytes);
      _statusText = 'Saved target restored. Ready to monitor.';
    }
    _ensureDahuaChannelState();

    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _persistConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('camera_vendor', _selectedVendor.name);
    await prefs.setString('camera_url', _normalizedCameraBaseUrl());
    await prefs.setString('camera_username', _usernameController.text.trim());
    await prefs.setString('camera_password', _passwordController.text);
    await prefs.setInt('dahua_channel_count', _dahuaChannelCount);
    await prefs.setString(
      'dahua_rtsp_port',
      _dahuaRtspPortController.text.trim(),
    );
    await prefs.setInt('selected_camera_channel', _selectedCameraChannel);
    await prefs.setDouble('match_threshold', _matchThreshold);
    await prefs.setInt('poll_interval', _pollSeconds);
    if (_targetFrameBytes != null) {
      await prefs.setString(
        'target_frame_b64',
        base64Encode(_targetFrameBytes!),
      );
    }
  }

  double get _matchThreshold {
    final parsed = double.tryParse(_thresholdController.text.trim()) ?? 88;
    return parsed.clamp(50, 100);
  }

  int get _pollSeconds {
    final parsed = int.tryParse(_intervalController.text.trim()) ?? 3;
    return parsed.clamp(1, 30);
  }

  Duration get _liveRefreshDuration {
    if (_selectedVendor == CameraVendor.dahuaXvr) {
      return const Duration(seconds: 2);
    }
    return const Duration(milliseconds: 900);
  }

  int get _dahuaRtspPort {
    final parsed = int.tryParse(_dahuaRtspPortController.text.trim()) ?? 554;
    return parsed.clamp(1, 65535);
  }

  int get _dahuaChannelCount {
    final parsed = int.tryParse(_dahuaChannelCountController.text.trim()) ?? 4;
    return parsed.clamp(1, 16);
  }

  String _defaultUrlForVendor(CameraVendor vendor) {
    return vendor == CameraVendor.hikvision
        ? _defaultHikvisionUrl
        : _defaultDahuaUrl;
  }

  List<String> _dahuaRtspUrls(int channel) {
    final uri = Uri.parse(_normalizedCameraBaseUrl());
    final host = uri.host.isEmpty ? '192.168.19.22' : uri.host;
    final credentials = _cameraUsername.isEmpty
        ? ''
        : '${Uri.encodeComponent(_cameraUsername)}:${Uri.encodeComponent(_cameraPassword)}@';
    final base = 'rtsp://$credentials$host:$_dahuaRtspPort';
    return [
      '$base/cam/realmonitor?channel=$channel&subtype=0',
      '$base/cam/realmonitor?channel=$channel&subtype=0&unicast=true',
      '$base/cam/realmonitor?channel=$channel&subtype=1',
      '$base/cam/realmonitor?channel=$channel&subtype=1&unicast=true',
      '$base/live/ch00_${channel - 1}',
      '$base/live/ch0$channel',
    ];
  }

  Future<void> _disposeDahuaPlayer() async {
    await _dahuaPlayingSubscription?.cancel();
    await _dahuaErrorSubscription?.cancel();
    _dahuaPlayingSubscription = null;
    _dahuaErrorSubscription = null;
    final player = _dahuaPlayer;
    _dahuaVideoController = null;
    _dahuaPlayer = null;
    if (player != null) {
      await player.dispose();
    }
  }

  Future<void> _startDahuaRtspLive() async {
    await _disposeDahuaPlayer();
    final player = Player();
    final controller = VideoController(player);
    _dahuaPlayer = player;
    _dahuaVideoController = controller;

    _dahuaPlayingSubscription = player.stream.playing.listen((playing) {
      if (!mounted || _selectedVendor != CameraVendor.dahuaXvr) {
        return;
      }
      if (playing) {
        setState(() {
          _isLiveConnected = true;
          _dahuaChannelConnected[_selectedCameraChannel] = true;
          _statusText =
              'Dahua RTSP live stream connected on channel $_selectedCameraChannel.';
        });
      }
    });

    _dahuaErrorSubscription = player.stream.error.listen((error) {
      if (!mounted || _selectedVendor != CameraVendor.dahuaXvr) {
        return;
      }
      setState(() {
        _isLiveConnected = false;
        _dahuaChannelConnected[_selectedCameraChannel] = false;
        _statusText = 'Dahua RTSP error: $error';
      });
    });

    Object? lastError;
    for (final url in _dahuaRtspUrls(_selectedCameraChannel)) {
      try {
        await player.open(Media(url));
        await player.play();
        if (mounted) {
          setState(() {
            _statusText =
                'Trying Dahua RTSP live on channel $_selectedCameraChannel.';
          });
        }
        return;
      } catch (error) {
        lastError = error;
      }
    }

    if (mounted) {
      setState(() {
        _isLiveConnected = false;
        _dahuaChannelConnected[_selectedCameraChannel] = false;
        _statusText =
            'Dahua RTSP error: failed to recognize stream format on channel $_selectedCameraChannel.';
      });
    }
    if (lastError != null) {
      throw Exception(lastError.toString());
    }
  }

  void _ensureDahuaChannelState() {
    for (var channel = 1; channel <= _dahuaChannelCount; channel++) {
      _dahuaLiveFrames.putIfAbsent(channel, () => null);
      _dahuaChannelConnected.putIfAbsent(channel, () => false);
    }
    _dahuaLiveFrames.removeWhere((key, value) => key > _dahuaChannelCount);
    _dahuaChannelConnected.removeWhere(
      (key, value) => key > _dahuaChannelCount,
    );
    _selectedCameraChannel = _selectedCameraChannel.clamp(
      1,
      _dahuaChannelCount,
    );
    _dahuaRefreshCursor = _dahuaRefreshCursor.clamp(1, _dahuaChannelCount);
    if (_fullscreenLiveChannel != null) {
      _fullscreenLiveChannel = _fullscreenLiveChannel!.clamp(
        1,
        _dahuaChannelCount,
      );
    }
  }

  String _normalizedCameraBaseUrl() {
    var input = _cameraUrlController.text.trim();
    if (input.isEmpty) {
      return _defaultUrlForVendor(_selectedVendor);
    }

    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      input = 'http://$input';
    }

    final uri = Uri.tryParse(input);
    if (uri == null) {
      return _defaultUrlForVendor(_selectedVendor);
    }

    var path = uri.path.trim();
    if (path.isEmpty || path == '/') {
      path = _selectedVendor == CameraVendor.hikvision
          ? '/ISAPI/Streaming/channels/1/picture'
          : '/cgi-bin/snapshot.cgi';
    }

    if (_selectedVendor == CameraVendor.dahuaXvr) {
      final params = Map<String, String>.from(uri.queryParameters);
      params.remove('channel');
      params.remove('ts');
      return uri.replace(path: path, queryParameters: params).toString();
    }

    return uri.replace(path: path, queryParameters: {}).toString();
  }

  Uri _frameUri({int channel = 1}) {
    final normalizedUrl = _normalizedCameraBaseUrl();
    if (_cameraUrlController.text.trim() != normalizedUrl) {
      _cameraUrlController.text = normalizedUrl;
      _cameraUrlController.selection = TextSelection.collapsed(
        offset: normalizedUrl.length,
      );
    }

    final uri = Uri.parse(normalizedUrl);
    final params = Map<String, String>.from(uri.queryParameters);
    params['ts'] = DateTime.now().millisecondsSinceEpoch.toString();
    if (_selectedVendor == CameraVendor.dahuaXvr) {
      params['channel'] = channel.toString();
    }
    return uri.replace(queryParameters: params);
  }

  String get _cameraUsername => _usernameController.text.trim();

  String get _cameraPassword => _passwordController.text;

  Map<String, String> _basicAuthHeaders() {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    if (username.isEmpty) {
      return const {};
    }

    final token = base64Encode(utf8.encode('$username:$password'));
    return {'Authorization': 'Basic $token'};
  }

  Future<http.Response> _performAuthenticatedGet(Uri uri) async {
    var response = await http.get(uri);

    if (response.statusCode == 401 && _cameraUsername.isNotEmpty) {
      final challenge = response.headers['www-authenticate'] ?? '';
      if (challenge.toLowerCase().startsWith('digest ')) {
        final digestHeader = _buildDigestAuthorizationHeader(
          challenge: challenge,
          method: 'GET',
          uri: uri,
          username: _cameraUsername,
          password: _cameraPassword,
        );
        if (digestHeader != null) {
          response = await http.get(
            uri,
            headers: {'Authorization': digestHeader},
          );
        }
      } else {
        response = await http.get(uri, headers: _basicAuthHeaders());
      }
    }

    return response;
  }

  List<Uri> _dahuaFrameUris(int channel) {
    final base = Uri.parse(_normalizedCameraBaseUrl());
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final variants = <Uri>[];

    Uri withPath(String path, Map<String, String> extraParams) {
      final params = <String, String>{...base.queryParameters, ...extraParams};
      params['ts'] = timestamp;
      return base.replace(path: path, queryParameters: params);
    }

    variants.add(
      withPath('/cgi-bin/snapshot.cgi', {'channel': channel.toString()}),
    );
    variants.add(
      withPath('/cgi-bin/snapshot.cgi', {
        'channel': channel.toString(),
        'subtype': '0',
      }),
    );
    variants.add(
      withPath('/onvif/snapshot', {
        'channel': channel.toString(),
        'subtype': '0',
      }),
    );
    if (channel == 1) {
      variants.add(withPath('/cgi-bin/snapshot.cgi', {}));
    }

    final seen = <String>{};
    return variants.where((uri) => seen.add(uri.toString())).toList();
  }

  Future<http.Response> _fetchCameraFrame({int channel = 1}) async {
    if (_selectedVendor == CameraVendor.dahuaXvr) {
      http.Response? bestResponse;
      for (final uri in _dahuaFrameUris(channel)) {
        final response = await _performAuthenticatedGet(uri);
        if (response.statusCode == 200 && response.bodyBytes.isNotEmpty) {
          return response;
        }
        bestResponse = response;
      }
      return bestResponse ??
          http.Response(
            'No Dahua snapshot response',
            520,
            request: http.Request('GET', _frameUri(channel: channel)),
          );
    }

    return _performAuthenticatedGet(_frameUri(channel: channel));
  }

  Future<Uint8List?> _captureBestFrameBytes() async {
    if (_selectedVendor == CameraVendor.dahuaXvr &&
        _selectedCameraChannel ==
            (_fullscreenLiveChannel ?? _selectedCameraChannel) &&
        _dahuaPlayer != null) {
      try {
        final screenshot = await _dahuaPlayer!.screenshot(format: 'image/jpeg');
        if (screenshot != null && screenshot.isNotEmpty) {
          return screenshot;
        }
      } catch (_) {
        // Fall back to HTTP snapshot if RTSP screenshot is unavailable.
      }
    }

    final response = await _fetchCameraFrame(channel: _selectedCameraChannel);
    if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
      throw Exception(
        'Camera response was empty (${response.statusCode}) on channel $_selectedCameraChannel.',
      );
    }
    return response.bodyBytes;
  }

  String? _buildDigestAuthorizationHeader({
    required String challenge,
    required String method,
    required Uri uri,
    required String username,
    required String password,
  }) {
    final trimmed = challenge.replaceFirst(
      RegExp('^Digest\\s+', caseSensitive: false),
      '',
    );
    final values = <String, String>{};
    for (final part in trimmed.split(RegExp(r',(?=(?:[^"]*"[^"]*")*[^"]*$)'))) {
      final pieces = part.split('=');
      if (pieces.length < 2) {
        continue;
      }
      final key = pieces.first.trim().toLowerCase();
      final value = pieces.sublist(1).join('=').trim().replaceAll('"', '');
      values[key] = value;
    }

    final realm = values['realm'];
    final nonce = values['nonce'];
    if (realm == null || nonce == null) {
      return null;
    }

    final algorithm = (values['algorithm'] ?? 'MD5').toUpperCase();
    final qopOptions =
        values['qop']?.split(',').map((e) => e.trim()).toList() ?? const [];
    final qop = qopOptions.contains('auth')
        ? 'auth'
        : (qopOptions.isNotEmpty ? qopOptions.first : null);
    final opaque = values['opaque'];
    final nonceCount = '00000001';
    final cnonce = _randomHex(16);
    final digestUri = uri.path + (uri.hasQuery ? '?${uri.query}' : '');

    final ha1Base = _hashForAlgorithm('$username:$realm:$password', algorithm);
    final ha1 = algorithm.endsWith('-SESS')
        ? _hashForAlgorithm('$ha1Base:$nonce:$cnonce', algorithm)
        : ha1Base;
    final ha2 = _hashForAlgorithm('$method:$digestUri', algorithm);
    final response = qop == null
        ? _hashForAlgorithm('$ha1:$nonce:$ha2', algorithm)
        : _hashForAlgorithm(
            '$ha1:$nonce:$nonceCount:$cnonce:$qop:$ha2',
            algorithm,
          );

    final fields = <String>[
      'username="$username"',
      'realm="$realm"',
      'nonce="$nonce"',
      'uri="$digestUri"',
      'response="$response"',
      'algorithm=$algorithm',
    ];

    if (opaque != null && opaque.isNotEmpty) {
      fields.add('opaque="$opaque"');
    }
    if (qop != null) {
      fields.add('qop=$qop');
      fields.add('nc=$nonceCount');
      fields.add('cnonce="$cnonce"');
    }

    return 'Digest ${fields.join(', ')}';
  }

  String _hashForAlgorithm(String input, String algorithm) {
    final bytes = utf8.encode(input);
    if (algorithm.startsWith('SHA-256')) {
      return sha256.convert(bytes).toString();
    }
    return md5.convert(bytes).toString();
  }

  String _randomHex(int bytesLength) {
    final random = Random.secure();
    final buffer = StringBuffer();
    for (var i = 0; i < bytesLength; i++) {
      buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  Future<void> _fetchPreviewFrame() async {
    final url = _cameraUrlController.text.trim();
    if (url.isEmpty) {
      _setStatus(
        'Default camera URL is missing. Please check the camera setup.',
      );
      return;
    }

    setState(() {
      _isFetchingFrame = true;
    });

    try {
      final bytes = await _captureBestFrameBytes();
      if (bytes == null || bytes.isEmpty) {
        throw Exception('Capture returned no image data.');
      }

      setState(() {
        _currentFrameBytes = bytes;
        if (_selectedVendor == CameraVendor.hikvision) {
          _liveFrameBytes = bytes;
        } else {
          _dahuaLiveFrames[_selectedCameraChannel] = bytes;
          _dahuaChannelConnected[_selectedCameraChannel] = true;
        }
        _lastFrameAt = DateTime.now();
        _statusText = _selectedVendor == CameraVendor.dahuaXvr
            ? 'High-quality frame captured from Dahua primary channel $_selectedCameraChannel.'
            : 'Live frame captured from the IP camera.';
      });

      await _persistConfig();
    } catch (error) {
      _setStatus('Could not fetch camera frame: $error');
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingFrame = false;
        });
      }
    }
  }

  Future<void> _saveCurrentFrameAsTarget() async {
    if (_currentFrameBytes == null) {
      _setStatus('Capture a frame first, then save it as the alert target.');
      return;
    }

    setState(() {
      _isSavingTarget = true;
    });

    final selection = await _selectTargetFaceCrop(_currentFrameBytes!);
    if (!mounted) {
      return;
    }

    if (selection == null) {
      setState(() {
        _isSavingTarget = false;
        _statusText = 'Target selection cancelled.';
      });
      return;
    }

    if (selection.signature.isEmpty) {
      _setStatus(
        'This target crop could not be processed. Try selecting a clearer face or object.',
      );
      setState(() {
        _isSavingTarget = false;
      });
      return;
    }

    setState(() {
      _targetFrameBytes = selection.croppedBytes;
      _targetSignature = selection.signature;
      _statusText =
          'Target saved from the selected crop. Monitoring can start now.';
    });

    await _persistConfig();

    if (mounted) {
      setState(() {
        _isSavingTarget = false;
      });
    }
  }

  void _toggleMonitoring() {
    if (_isMonitoring) {
      _stopMonitoring(message: 'Monitoring stopped.');
      return;
    }

    if (_targetSignature == null) {
      _setStatus(
        'Save a target image first so the app knows what to watch for.',
      );
      return;
    }

    if (_cameraUrlController.text.trim().isEmpty) {
      _setStatus('Camera URL is not available. Please check the camera setup.');
      return;
    }

    _startMonitoring();
  }

  void _toggleLiveStreaming() {
    if (_isLiveStreaming) {
      _stopLiveStreaming(message: 'Live stream stopped.');
      return;
    }

    _startLiveStreaming();
  }

  void _startLiveStreaming() {
    _liveTimer?.cancel();
    _ensureDahuaChannelState();
    setState(() {
      _isLiveStreaming = true;
      _isLiveConnected = false;
      _statusText = _selectedVendor == CameraVendor.hikvision
          ? 'Live stream started. Refreshing the camera preview box.'
          : 'Live stream started. Opening the Dahua RTSP primary channel.';
    });

    if (_selectedVendor == CameraVendor.dahuaXvr) {
      _startDahuaRtspLive();
      return;
    }

    _runLiveStreamRefresh();
    _liveTimer = Timer.periodic(
      _liveRefreshDuration,
      (_) => _runLiveStreamRefresh(),
    );
  }

  void _stopLiveStreaming({String? message}) {
    _liveTimer?.cancel();
    if (_selectedVendor == CameraVendor.dahuaXvr) {
      _disposeDahuaPlayer();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _isLiveStreaming = false;
      _isLiveConnected = false;
      _statusText = message ?? 'Live stream stopped.';
    });
  }

  void _startMonitoring() {
    _monitorTimer?.cancel();
    setState(() {
      _isMonitoring = true;
      _statusText =
          'Monitoring started. The app is checking the IP camera feed.';
    });

    _persistConfig();
    _runMonitorCheck();
    _monitorTimer = Timer.periodic(
      Duration(seconds: _pollSeconds),
      (_) => _runMonitorCheck(),
    );
  }

  void _stopMonitoring({String? message}) {
    _monitorTimer?.cancel();
    setState(() {
      _isMonitoring = false;
      _statusText = message ?? 'Monitoring stopped.';
    });
  }

  Future<void> _runLiveStreamRefresh() async {
    if (!_isLiveStreaming || _isRefreshingLive) {
      return;
    }

    try {
      if (mounted) {
        setState(() {
          _isRefreshingLive = true;
        });
      }

      if (_selectedVendor == CameraVendor.hikvision) {
        final response = await _fetchCameraFrame(
          channel: _selectedCameraChannel,
        );
        if (response.statusCode == 401 || response.statusCode == 403) {
          _stopLiveStreaming(
            message:
                'Live stream stopped. Hikvision credentials were rejected.',
          );
          return;
        }
        if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
          throw Exception('Empty live frame');
        }

        if (!mounted) {
          return;
        }

        setState(() {
          _liveFrameBytes = response.bodyBytes;
          _isLiveConnected = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLiveConnected = false;
          _statusText = _selectedVendor == CameraVendor.hikvision
              ? 'Live stream disconnected. The camera did not return a frame.'
              : 'Live stream disconnected. Dahua primary channel $_selectedCameraChannel did not return a frame.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isRefreshingLive = false;
        });
      }
    }
  }

  Future<void> _runMonitorCheck() async {
    if (!_isMonitoring || _isFetchingFrame) {
      return;
    }

    try {
      setState(() {
        _isFetchingFrame = true;
      });

      final response = await _fetchCameraFrame(channel: _selectedCameraChannel);
      if (response.statusCode == 401 || response.statusCode == 403) {
        _setStatus(
          'Monitoring stopped because the Hikvision camera requires valid login credentials.',
        );
        _stopMonitoring(
          message: 'Monitoring stopped. Update the Hikvision credentials.',
        );
        return;
      }
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        throw Exception('Empty frame');
      }

      if (_targetSignature == null) {
        _setStatus(
          'Monitoring skipped because the frame could not be processed.',
        );
        return;
      }

      final similarity = _scanFrameForBestMatch(
        response.bodyBytes,
        _targetSignature!,
      );
      final matched = similarity >= _matchThreshold;

      if (!mounted) {
        return;
      }

      setState(() {
        _currentFrameBytes = response.bodyBytes;
        if (_selectedVendor == CameraVendor.hikvision) {
          _liveFrameBytes = response.bodyBytes;
        } else {
          _dahuaLiveFrames[_selectedCameraChannel] = response.bodyBytes;
          _dahuaChannelConnected[_selectedCameraChannel] = true;
        }
        _lastFrameAt = DateTime.now();
        _lastSimilarity = similarity;
        _statusText = matched
            ? 'Target match detected at ${_formatTime(_lastFrameAt!)}.'
            : 'Monitoring active. Last similarity: ${similarity.toStringAsFixed(1)}%.';
      });

      if (matched) {
        _triggerAlarm();
      }
    } catch (_) {
      _setStatus('Monitor check failed. The camera may be offline or blocked.');
    } finally {
      if (mounted) {
        setState(() {
          _isFetchingFrame = false;
        });
      }
    }
  }

  void _triggerAlarm() {
    if (_alarmVisible) {
      return;
    }

    _alarmTimer?.cancel();
    setState(() {
      _alarmVisible = true;
      _alarmMuted = false;
      _lastAlertAt = DateTime.now();
    });

    _alarmTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_alarmMuted) {
        return;
      }
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.heavyImpact();
    });

    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
  }

  void _dismissAlarm({bool keepMonitoring = true}) {
    _alarmTimer?.cancel();
    setState(() {
      _alarmVisible = false;
      _alarmMuted = false;
      _statusText = keepMonitoring
          ? 'Alarm dismissed. Monitoring continues.'
          : 'Alarm dismissed and monitoring stopped.';
    });

    if (!keepMonitoring) {
      _stopMonitoring(message: 'Monitoring stopped after the alarm.');
    }
  }

  void _toggleMuteAlarm() {
    setState(() {
      _alarmMuted = !_alarmMuted;
    });
  }

  void _clearTarget() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('target_frame_b64');
    setState(() {
      _targetFrameBytes = null;
      _targetSignature = null;
      _lastSimilarity = 0;
      _statusText = 'Saved target cleared.';
    });
  }

  Future<_TargetSelectionResult?> _selectTargetFaceCrop(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null || !mounted) {
      return null;
    }

    var center = const Offset(0.5, 0.38);
    var scale = 0.28;

    return showDialog<_TargetSelectionResult>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Rect normalizedRect() {
              final half = scale / 2;
              final left = (center.dx - half).clamp(0.0, 1.0 - scale);
              final top = (center.dy - half).clamp(0.0, 1.0 - scale);
              return Rect.fromLTWH(left, top, scale, scale);
            }

            final rect = normalizedRect();

            return AlertDialog(
              title: const Text('Select Target Area'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Move the square over the face or object you want to detect. A tighter crop usually gives better matching.',
                    ),
                    const SizedBox(height: 16),
                    AspectRatio(
                      aspectRatio: decoded.width / decoded.height,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return GestureDetector(
                            onPanUpdate: (details) {
                              setDialogState(() {
                                center = Offset(
                                  (center.dx +
                                          (details.delta.dx /
                                              constraints.maxWidth))
                                      .clamp(scale / 2, 1 - (scale / 2)),
                                  (center.dy +
                                          (details.delta.dy /
                                              constraints.maxHeight))
                                      .clamp(scale / 2, 1 - (scale / 2)),
                                );
                              });
                            },
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Image.memory(bytes, fit: BoxFit.cover),
                                ),
                                Positioned(
                                  left: rect.left * constraints.maxWidth,
                                  top: rect.top * constraints.maxHeight,
                                  width: rect.width * constraints.maxWidth,
                                  height: rect.height * constraints.maxHeight,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: const Color(0xFFFFB85E),
                                        width: 3,
                                      ),
                                      borderRadius: BorderRadius.circular(18),
                                      color: const Color(0x22FFB85E),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text('Face box size'),
                    Slider(
                      value: scale,
                      min: 0.16,
                      max: 0.46,
                      onChanged: (value) {
                        setDialogState(() {
                          scale = value;
                          center = Offset(
                            center.dx.clamp(scale / 2, 1 - (scale / 2)),
                            center.dy.clamp(scale / 2, 1 - (scale / 2)),
                          );
                        });
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final crop = _cropBytesByNormalizedRect(bytes, rect);
                    final signature = crop == null
                        ? null
                        : _buildSignature(crop);
                    if (crop == null || signature == null) {
                      Navigator.of(context).pop();
                      return;
                    }
                    Navigator.of(context).pop(
                      _TargetSelectionResult(
                        croppedBytes: crop,
                        signature: signature,
                      ),
                    );
                  },
                  child: const Text('Save Target'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Uint8List? _cropBytesByNormalizedRect(Uint8List bytes, Rect normalizedRect) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }

    final x = (normalizedRect.left * decoded.width).round().clamp(
      0,
      decoded.width - 1,
    );
    final y = (normalizedRect.top * decoded.height).round().clamp(
      0,
      decoded.height - 1,
    );
    final width = (normalizedRect.width * decoded.width).round().clamp(
      1,
      decoded.width - x,
    );
    final height = (normalizedRect.height * decoded.height).round().clamp(
      1,
      decoded.height - y,
    );

    final cropped = img.copyCrop(
      decoded,
      x: x,
      y: y,
      width: width,
      height: height,
    );
    return Uint8List.fromList(img.encodeJpg(cropped, quality: 92));
  }

  List<int>? _buildSignature(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    return _buildSignatureFromImage(decoded);
  }

  List<int>? _buildSignatureFromImage(img.Image decoded) {
    final squareSize = decoded.width < decoded.height
        ? decoded.width
        : decoded.height;
    final left = (decoded.width - squareSize) ~/ 2;
    final top = (decoded.height - squareSize) ~/ 2;
    final cropped = img.copyCrop(
      decoded,
      x: left,
      y: top,
      width: squareSize,
      height: squareSize,
    );
    final resized = img.copyResizeCropSquare(cropped, size: 32);
    final grayscale = img.grayscale(resized);

    final signature = <int>[];
    for (var y = 0; y < grayscale.height; y += 2) {
      for (var x = 0; x < grayscale.width; x += 2) {
        final pixel = grayscale.getPixel(x, y);
        signature.add(pixel.r.toInt());
      }
    }
    return signature;
  }

  double _scanFrameForBestMatch(Uint8List bytes, List<int> targetSignature) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return 0;
    }

    final minSide = min(decoded.width, decoded.height);
    final scales = [0.18, 0.24, 0.3, 0.36, 0.42];
    var best = 0.0;

    for (final scale in scales) {
      final cropSize = max(40, (minSide * scale).round());
      final step = max(18, cropSize ~/ 3);
      final maxY = max(0, decoded.height - cropSize);
      final maxX = max(0, decoded.width - cropSize);

      for (var y = 0; y <= maxY; y += step) {
        for (var x = 0; x <= maxX; x += step) {
          final candidate = img.copyCrop(
            decoded,
            x: x,
            y: y,
            width: cropSize,
            height: cropSize,
          );
          final signature = _buildSignatureFromImage(candidate);
          if (signature == null) {
            continue;
          }

          final similarity = _compareSignatures(targetSignature, signature);
          if (similarity > best) {
            best = similarity;
          }
        }
      }
    }

    return best;
  }

  double _compareSignatures(List<int> a, List<int> b) {
    if (a.length != b.length || a.isEmpty) {
      return 0;
    }

    var totalDelta = 0.0;
    for (var i = 0; i < a.length; i++) {
      totalDelta += (a[i] - b[i]).abs();
    }

    final averageDelta = totalDelta / a.length;
    final similarity = 100 - ((averageDelta / 255) * 100);
    return similarity.clamp(0, 100);
  }

  void _setStatus(String message) {
    if (!mounted) {
      return;
    }
    setState(() {
      _statusText = message;
    });
  }

  String _formatTime(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    final second = value.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFFF8F0E8), Color(0xFFE6D2C1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final vertical = constraints.maxWidth < 980;
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight - 40,
                      ),
                      child: vertical
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildHeader(colorScheme),
                                const SizedBox(height: 20),
                                _buildControlPanel(colorScheme),
                                const SizedBox(height: 20),
                                _buildFeedPanel(colorScheme),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildHeader(colorScheme),
                                const SizedBox(height: 20),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Expanded(
                                      flex: 5,
                                      child: _buildFeedPanel(colorScheme),
                                    ),
                                    const SizedBox(width: 20),
                                    Expanded(
                                      flex: 4,
                                      child: _buildControlPanel(colorScheme),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (_alarmVisible) _buildAlarmOverlay(),
          if (_isLiveFullscreenVisible) _buildLiveFullscreenOverlay(),
        ],
      ),
    );
  }

  Widget _buildHeader(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x19000000),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Wrap(
        runSpacing: 16,
        spacing: 24,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 560,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'IP Camera Viewer and Target Alert System',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.8,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'Capture a frame from the camera, save a face or object as the watch target, and trigger a full-screen alarm when a similar target appears again.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    height: 1.5,
                    color: const Color(0xFF503A2B),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF241511),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'System Status',
                  style: TextStyle(
                    color: Color(0xFFE7C9A6),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _statusText,
                  style: const TextStyle(color: Colors.white, height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControlPanel(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Watch Controls',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _cameraUrlController,
            decoration: InputDecoration(
              labelText: _selectedVendor == CameraVendor.hikvision
                  ? 'IP camera snapshot URL'
                  : 'Dahua XVR base snapshot URL',
              hintText: _selectedVendor == CameraVendor.hikvision
                  ? _defaultHikvisionUrl
                  : _defaultDahuaUrl,
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _persistConfig(),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<CameraVendor>(
            initialValue: _selectedVendor,
            decoration: const InputDecoration(
              labelText: 'Device type',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: CameraVendor.hikvision,
                child: Text('Hikvision IP Camera'),
              ),
              DropdownMenuItem(
                value: CameraVendor.dahuaXvr,
                child: Text('Dahua XVR'),
              ),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              setState(() {
                if (_selectedVendor == CameraVendor.dahuaXvr) {
                  _disposeDahuaPlayer();
                }
                _selectedVendor = value;
                _cameraUrlController.text = _defaultUrlForVendor(value);
                _selectedCameraChannel = 1;
                _isLiveConnected = false;
                _liveFrameBytes = null;
                _ensureDahuaChannelState();
              });
              _persistConfig();
            },
          ),
          if (_selectedVendor == CameraVendor.dahuaXvr) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _dahuaChannelCountController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'XVR camera count',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      setState(() {
                        _ensureDahuaChannelState();
                      });
                      _persistConfig();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _selectedCameraChannel.clamp(
                      1,
                      _dahuaChannelCount,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Primary channel',
                      border: OutlineInputBorder(),
                    ),
                    items: List.generate(
                      _dahuaChannelCount,
                      (index) => DropdownMenuItem(
                        value: index + 1,
                        child: Text('Channel ${index + 1}'),
                      ),
                    ),
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() {
                        _selectedCameraChannel = value;
                      });
                      if (_isLiveStreaming &&
                          _selectedVendor == CameraVendor.dahuaXvr) {
                        _startDahuaRtspLive();
                      }
                      _persistConfig();
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _dahuaRtspPortController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Dahua RTSP port',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_isLiveStreaming &&
                    _selectedVendor == CameraVendor.dahuaXvr) {
                  _startDahuaRtspLive();
                }
                _persistConfig();
              },
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _usernameController,
                  decoration: InputDecoration(
                    labelText: _selectedVendor == CameraVendor.hikvision
                        ? 'Hikvision username'
                        : 'Device username',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _persistConfig(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: _selectedVendor == CameraVendor.hikvision
                        ? 'Hikvision password'
                        : 'Device password',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _persistConfig(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _thresholdController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Match threshold %',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _persistConfig(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _intervalController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Poll interval sec',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => _persistConfig(),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _isFetchingFrame ? null : _fetchPreviewFrame,
            icon: const Icon(Icons.videocam),
            label: Text(
              _isFetchingFrame
                  ? 'Fetching frame...'
                  : 'Take Picture From IP Cam',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _toggleLiveStreaming,
            icon: Icon(_isLiveStreaming ? Icons.stop : Icons.live_tv),
            label: Text(
              _isLiveStreaming
                  ? 'Stop Live Stream Box'
                  : 'Start Live Stream Box',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.tonalIcon(
            onPressed: _isSavingTarget ? null : _saveCurrentFrameAsTarget,
            icon: const Icon(Icons.person_search),
            label: Text(
              _isSavingTarget
                  ? 'Saving target...'
                  : 'Select Target and Save Alert',
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: _isMonitoring
                  ? const Color(0xFF7C291D)
                  : colorScheme.primary,
            ),
            onPressed: _toggleMonitoring,
            icon: Icon(_isMonitoring ? Icons.pause_circle : Icons.sensors),
            label: Text(_isMonitoring ? 'Stop Monitoring' : 'Start Monitoring'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _targetFrameBytes == null ? null : _clearTarget,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear Saved Target'),
          ),
          const SizedBox(height: 20),
          _buildStatsCard(),
          const SizedBox(height: 20),
          _buildInstructionsCard(),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    final lastFrame = _lastFrameAt == null
        ? 'No frame yet'
        : _formatTime(_lastFrameAt!);
    final lastAlert = _lastAlertAt == null
        ? 'No alert yet'
        : _formatTime(_lastAlertAt!);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF9F1EB),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Live Monitoring',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _statLine('Monitoring', _isMonitoring ? 'Active' : 'Stopped'),
          _statLine(
            'Live stream',
            _isLiveConnected ? 'Connected' : 'Disconnected',
          ),
          if (_selectedVendor == CameraVendor.dahuaXvr)
            _statLine('Primary channel', 'Channel $_selectedCameraChannel'),
          _statLine('Last frame', lastFrame),
          _statLine(
            'Last match score',
            '${_lastSimilarity.toStringAsFixed(1)}%',
          ),
          _statLine('Last alert', lastAlert),
        ],
      ),
    );
  }

  Widget _buildInstructionsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF221612),
        borderRadius: BorderRadius.circular(22),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How It Works',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 12),
          Text(
            '1. Choose Hikvision IP Camera or Dahua XVR from the device type selector.\n'
            '2. Enter the device login if the camera or XVR is protected.\n'
            '3. In Dahua mode, set the XVR camera count and choose the primary channel.\n'
            '4. Dahua live video now uses RTSP on the primary channel instead of repeated snapshot polling.\n'
            '5. Use "Take Picture From IP Cam" and "Select Target and Save Alert" on the primary channel for alert monitoring.',
            style: TextStyle(color: Color(0xFFF0DDD1), height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _statLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFF6B5648),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Color(0xFF241511),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFeedPanel(ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_selectedVendor == CameraVendor.hikvision)
          _buildFrameCard(
            title: 'Live Streaming Box',
            subtitle: _isLiveStreaming
                ? (_isLiveConnected
                      ? 'Fast refreshing preview from the Hikvision camera.'
                      : 'Camera is disconnected. The live box will reconnect automatically.')
                : 'Press "Start Live Stream Box" to begin live preview.',
            bytes: _liveFrameBytes,
            accentColor: const Color(0xFF116466),
            emptyText: 'Live stream preview has not started yet.',
            badgeText: _isLiveConnected ? 'LIVE' : 'DISCONNECTED',
            onDoubleTap: _liveFrameBytes == null
                ? null
                : () {
                    setState(() {
                      _fullscreenLiveChannel = _selectedCameraChannel;
                      _isLiveFullscreenVisible = true;
                    });
                  },
          )
        else
          _buildDahuaRtspCard(),
        const SizedBox(height: 20),
        _buildFrameCard(
          title: 'Live IP Camera Frame',
          subtitle:
              'Current captured picture used for manual save and monitoring.',
          bytes: _currentFrameBytes,
          accentColor: colorScheme.primary,
          emptyText: 'No frame captured yet.',
          badgeText: _isFetchingFrame ? 'Updating...' : 'SNAPSHOT',
        ),
        const SizedBox(height: 20),
        _buildFrameCard(
          title: 'Alert Target Box',
          subtitle:
              'Selected face or object crop used for monitoring and alerting.',
          bytes: _targetFrameBytes,
          accentColor: const Color(0xFF9B3D2A),
          emptyText: 'No alert target saved yet.',
          badgeText: _targetFrameBytes == null ? 'EMPTY' : 'ARMED',
        ),
      ],
    );
  }

  Widget _buildFrameCard({
    required String title,
    required String subtitle,
    required Uint8List? bytes,
    required Color accentColor,
    required String emptyText,
    required String badgeText,
    VoidCallback? onDoubleTap,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x15000000),
            blurRadius: 26,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: accentColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(color: Color(0xFF70594C)),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: GestureDetector(
              onDoubleTap: onDoubleTap,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: const Color(0xFFEDE2D8),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.18),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: bytes == null
                    ? Center(
                        child: Text(
                          emptyText,
                          style: const TextStyle(
                            color: Color(0xFF7A6659),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            bytes,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                            errorBuilder: (context, error, stackTrace) =>
                                const Center(
                                  child: Text('Frame could not be displayed.'),
                                ),
                          ),
                          if (onDoubleTap != null)
                            Positioned(
                              right: 14,
                              bottom: 14,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.5),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Text(
                                  'Double tap for full screen',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDahuaRtspCard() {
    final connected = _dahuaChannelConnected[_selectedCameraChannel] ?? false;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x15000000),
            blurRadius: 26,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: Color(0xFF116466),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dahua RTSP Live Stream',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Primary channel $_selectedCameraChannel live stream from the Dahua XVR.',
                      style: const TextStyle(color: Color(0xFF70594C)),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF116466).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  connected ? 'LIVE' : 'DISCONNECTED',
                  style: const TextStyle(
                    color: Color(0xFF116466),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: GestureDetector(
              onDoubleTap: _dahuaVideoController == null
                  ? null
                  : () {
                      setState(() {
                        _fullscreenLiveChannel = _selectedCameraChannel;
                        _isLiveFullscreenVisible = true;
                      });
                    },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  color: const Color(0xFFEDE2D8),
                  border: Border.all(
                    color: const Color(0xFF116466).withValues(alpha: 0.18),
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: _dahuaVideoController == null
                    ? const Center(
                        child: Text(
                          'Press "Start Live Stream Box" to open Dahua RTSP live video.',
                          style: TextStyle(
                            color: Color(0xFF7A6659),
                            fontWeight: FontWeight.w600,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          Video(
                            controller: _dahuaVideoController!,
                            controls: NoVideoControls,
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            right: 14,
                            bottom: 14,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: const Text(
                                'Double tap for full screen',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAlarmOverlay() {
    final snapshot = _currentFrameBytes;

    return Positioned.fill(
      child: Material(
        color: const Color(0xEE3A0808),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFFFFEBEA), Color(0xFFF4B1A6)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'ALERT DETECTED',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                            color: Color(0xFF7A120C),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          'Matching person detected under the IP camera at ${_lastAlertAt == null ? '--:--:--' : _formatTime(_lastAlertAt!)}.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF5C1B15),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Expanded(
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              border: Border.all(
                                color: const Color(0xFFAE2012),
                                width: 4,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: snapshot == null
                                ? const Center(
                                    child: Text(
                                      'No matching snapshot available.',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  )
                                : Image.memory(snapshot, fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(height: 18),
                        Text(
                          'Similarity score: ${_lastSimilarity.toStringAsFixed(1)}%',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF5C1B15),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFAE2012),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                      ),
                      onPressed: _toggleMuteAlarm,
                      icon: Icon(
                        _alarmMuted ? Icons.volume_off : Icons.volume_up,
                      ),
                      label: Text(_alarmMuted ? 'Muted' : 'Mute Alarm'),
                    ),
                    FilledButton.tonalIcon(
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                      ),
                      onPressed: () => _dismissAlarm(keepMonitoring: true),
                      icon: const Icon(Icons.check_circle_outline),
                      label: const Text('Dismiss, Keep Monitoring'),
                    ),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white70),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 16,
                        ),
                      ),
                      onPressed: () => _dismissAlarm(keepMonitoring: false),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: const Text('Dismiss and Stop'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveFullscreenOverlay() {
    final fullscreenChannel = _fullscreenLiveChannel ?? _selectedCameraChannel;
    final bytes = _selectedVendor == CameraVendor.hikvision
        ? _liveFrameBytes
        : null;
    final badgeText = _selectedVendor == CameraVendor.hikvision
        ? (_isLiveConnected ? 'LIVE' : 'DISCONNECTED')
        : ((_dahuaChannelConnected[fullscreenChannel] ?? false)
              ? 'LIVE'
              : 'DISCONNECTED');
    final title = _selectedVendor == CameraVendor.hikvision
        ? 'Live Streaming Box'
        : 'Dahua Camera $fullscreenChannel';

    return Positioned.fill(
      child: Material(
        color: const Color(0xF4101B22),
        child: SafeArea(
          child: Stack(
            children: [
              Center(
                child: _selectedVendor == CameraVendor.dahuaXvr
                    ? (_dahuaVideoController == null
                          ? const Text(
                              'Live stream is disconnected.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : Video(
                              controller: _dahuaVideoController!,
                              controls: AdaptiveVideoControls,
                              fit: BoxFit.contain,
                            ))
                    : (bytes == null
                          ? const Text(
                              'Live stream is disconnected.',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : InteractiveViewer(
                              minScale: 1,
                              maxScale: 5,
                              child: Image.memory(
                                bytes,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.low,
                              ),
                            )),
              ),
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: () {
                        setState(() {
                          _isLiveFullscreenVisible = false;
                          _fullscreenLiveChannel = null;
                        });
                      },
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF116466).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: const Color(
                            0xFF116466,
                          ).withValues(alpha: 0.65),
                        ),
                      ),
                      child: Text(
                        badgeText,
                        style: const TextStyle(
                          color: Color(0xFF7CE3DF),
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
