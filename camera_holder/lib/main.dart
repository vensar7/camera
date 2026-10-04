import 'dart:async';
import 'dart:convert';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_web_auth/flutter_web_auth.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher_string.dart';

// Конфигурация OAuth — client_id заполнен пользователем. Client secret не сохраняется в коде.
const String YANDEX_CLIENT_ID = '';
const String REDIRECT_URI = 'https://oauth.yandex.com/verification_code';
final _secureStorage = FlutterSecureStorage();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Camera → Yandex.Disk',
      home: CameraUploaderPage(),
    );
  }
}

class CameraUploaderPage extends StatefulWidget {
  const CameraUploaderPage({Key? key}) : super(key: key);

  @override
  State<CameraUploaderPage> createState() => _CameraUploaderPageState();
}

class _CameraUploaderPageState extends State<CameraUploaderPage> {
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  bool _isRecording = false;
  bool _isUploading = false;
  bool _isInitializingCamera = true;
  String? _cameraError;
  String? _token;

  @override
  void initState() {
    super.initState();
    _initToken();
    _initCamera();
  }

  Future<void> _initToken() async {
    final t = await _secureStorage.read(key: 'yandex_oauth_token');
    setState(() => _token = t);
  }

  Future<void> _initCamera() async {
    if (mounted) {
      setState(() {
        _isInitializingCamera = true;
        _cameraError = null;
      });
    }
    await _controller?.dispose();
    _controller = null;
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        throw Exception('Устройство не обнаружило ни одной камеры.');
      }

      final camera = _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      final controller = CameraController(
        camera,
        ResolutionPreset.medium,
        enableAudio: true,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      debugPrint('Camera init error: $e');
      if (mounted) setState(() => _cameraError = e.toString());
    } finally {
      if (mounted) setState(() => _isInitializingCamera = false);
    }
  }

  Future<void> _login() async {
    if (YANDEX_CLIENT_ID.startsWith('<')) {
      _showMessage('Please set YANDEX_CLIENT_ID in code (lib/main.dart)');
      return;
    }

    // verification_code flow (out-of-band) — открываем страницу авторизации в браузере,
    // пользователь копирует код и вставляет его в приложение
    if (REDIRECT_URI.contains('oauth.yandex.com/verification_code')) {
      final authUrl = Uri.https('oauth.yandex.com', '/authorize', {
        'response_type': 'code',
        'client_id': YANDEX_CLIENT_ID,
        'redirect_uri': REDIRECT_URI,
        'scope': 'cloud_api:disk.write',
      }).toString();

      final opened =
          await launchUrlString(authUrl, mode: LaunchMode.externalApplication);
      if (!opened) {
        _showMessage('Не удалось открыть браузер для авторизации');
        return;
      }

      final code = await _promptForText(
        title: 'Вставьте verification code',
        hint: 'Код из страницы Yandex',
      );
      if (code == null || code.trim().isEmpty) {
        _showMessage('Код не введён');
        return;
      }

      final clientSecret = await _promptForText(
        title: 'Client secret (если требуется)',
        hint: 'Оставьте пустым, если не нужно',
        obscure: true,
      );

      await _exchangeCodeForToken(code.trim(), clientSecret?.trim());
      return;
    }

    // Default: implicit flow using custom scheme redirect
    final authUrl = Uri.https('oauth.yandex.com', '/authorize', {
      'response_type': 'token',
      'client_id': YANDEX_CLIENT_ID,
      'redirect_uri': REDIRECT_URI,
      'scope': 'cloud_api:disk.write',
    }).toString();

    try {
      final result = await FlutterWebAuth.authenticate(
          url: authUrl, callbackUrlScheme: _callbackSchemeFrom(REDIRECT_URI));
      // result may contain fragment with access_token
      final uri = Uri.parse(result);
      String? token;
      if (uri.fragment.isNotEmpty) {
        final fragParams = Uri.splitQueryString(uri.fragment);
        token = fragParams['access_token'];
      } else if (uri.queryParameters.containsKey('access_token')) {
        token = uri.queryParameters['access_token'];
      }
      if (token != null) {
        await _secureStorage.write(key: 'yandex_oauth_token', value: token);
        setState(() => _token = token);
        _showMessage('Авторизация успешна');
      } else {
        _showMessage('Не удалось получить access_token');
      }
    } catch (e) {
      _showMessage('Авторизация отменена или ошибка: $e');
    }
  }

  Future<String?> _promptForText(
      {required String title, String hint = '', bool obscure = false}) async {
    if (!mounted) return null;
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(hintText: hint),
          obscureText: obscure,
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('OK')),
        ],
      ),
    );
    return result;
  }

  Future<void> _exchangeCodeForToken(String code, String? clientSecret) async {
    try {
      final body = {
        'grant_type': 'authorization_code',
        'code': code,
        'client_id': YANDEX_CLIENT_ID,
        'redirect_uri': REDIRECT_URI,
      };
      if (clientSecret != null && clientSecret.isNotEmpty)
        body['client_secret'] = clientSecret;

      final resp =
          await http.post(Uri.https('oauth.yandex.com', '/token'), body: body);
      if (resp.statusCode == 200) {
        final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
        final token = parsed['access_token'] as String?;
        if (token != null) {
          await _secureStorage.write(key: 'yandex_oauth_token', value: token);
          setState(() => _token = token);
          _showMessage('Авторизация успешна');
        } else {
          _showMessage(
              'Не удалось получить access_token при обмене: ${resp.body}');
        }
      } else {
        _showMessage('Ошибка обмена кода: ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      _showMessage('Ошибка обмена кода: $e');
    }
  }

  String _callbackSchemeFrom(String redirect) {
    // 'com.example.cameraapp://oauth' -> 'com.example.cameraapp'
    final idx = redirect.indexOf('://');
    if (idx > 0) return redirect.substring(0, idx);
    return redirect;
  }

  Future<void> _logout() async {
    await _secureStorage.delete(key: 'yandex_oauth_token');
    setState(() => _token = null);
    _showMessage('Выход выполнен');
  }

  String _fileTimestamp() {
    final now = DateTime.now();
    String twoDigits(int value) => value.toString().padLeft(2, '0');
    String threeDigits(int value) => value.toString().padLeft(3, '0');

    return '${now.year}-${twoDigits(now.month)}-${twoDigits(now.day)}_'
        '${twoDigits(now.hour)}-${twoDigits(now.minute)}-'
        '${twoDigits(now.second)}-${threeDigits(now.millisecond)}';
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      final xfile = await _controller!.takePicture();
      final name = 'photo_${_fileTimestamp()}.jpg';
      await _uploadFile(xfile, '/CameraApp/$name');
    } catch (e) {
      _showMessage('Ошибка съемки: $e');
    }
  }

  Future<void> _startVideo() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      await _controller!.prepareForVideoRecording();
      await _controller!.startVideoRecording();
      setState(() => _isRecording = true);
    } catch (e) {
      _showMessage('Ошибка начала записи: $e');
    }
  }

  Future<void> _stopVideo() async {
    if (_controller == null || !_controller!.value.isRecordingVideo) return;
    try {
      final xfile = await _controller!.stopVideoRecording();
      setState(() => _isRecording = false);
      final ext = p.extension(xfile.name);
      final name = 'video_${_fileTimestamp()}$ext';
      await _uploadFile(xfile, '/CameraApp/$name');
    } catch (e) {
      _showMessage('Ошибка остановки записи: $e');
    }
  }

  Future<void> _uploadFile(XFile file, String remotePath) async {
    if (_token == null) {
      _showMessage('Требуется авторизация Yandex');
      return;
    }
    setState(() => _isUploading = true);
    try {
      final folderUri = Uri.https(
        'cloud-api.yandex.net',
        '/v1/disk/resources',
        {'path': '/CameraApp'},
      );
      final folderResponse = await http.put(
        folderUri,
        headers: {'Authorization': 'OAuth $_token'},
      );
      if (folderResponse.statusCode != 201 &&
          folderResponse.statusCode != 409) {
        _showMessage(
          'Не удалось создать папку CameraApp: '
          '${folderResponse.statusCode} ${folderResponse.body}',
        );
        return;
      }

      final uri = Uri.https('cloud-api.yandex.net', '/v1/disk/resources/upload',
          {'path': remotePath, 'overwrite': 'true'});
      final resp =
          await http.get(uri, headers: {'Authorization': 'OAuth $_token'});
      if (resp.statusCode != 200) {
        if (resp.statusCode == 403) {
          if (!mounted) return;
          await showDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Нет доступа к записи на Яндекс.Диск'),
              content: const SingleChildScrollView(
                child: Text(
                  'Проверьте настройки OAuth-приложения:\n'
                  '• В разделе «Доступ к данным» должно быть разрешение '
                  '«Запись в любом месте на Диске» (cloud_api:disk.write).\n'
                  '• Если приложение создано для авторизации пользователей, '
                  'создайте приложение типа «Для доступа к API или отладки» '
                  'с этим разрешением — тип существующего приложения изменить нельзя.\n'
                  '• Отзовите старый доступ на id.yandex.ru/personal/data-access, '
                  'затем выйдите из аккаунта в приложении и войдите снова.\n'
                  'Также проверьте, что на Диске есть свободное место.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Понятно'),
                ),
              ],
            ),
          );
        } else {
          _showMessage(
            'Ошибка получения upload href: ${resp.statusCode} ${resp.body}',
          );
        }
        return;
      }
      final parsed = jsonDecode(resp.body) as Map<String, dynamic>;
      final uploadHref = parsed['href'] as String?;
      if (uploadHref == null) {
        _showMessage(
            'Не удалось получить ссылку для загрузки. Ответ: ${resp.body}');
        return;
      }

      final bytes = await file.readAsBytes();
      final putResp = await http.put(Uri.parse(uploadHref),
          body: bytes, headers: {'Content-Type': 'application/octet-stream'});
      if (putResp.statusCode == 201 || putResp.statusCode == 200) {
        _showMessage('Файл успешно загружен: $remotePath');
      } else {
        _showMessage('Ошибка загрузки: ${putResp.statusCode} ${putResp.body}');
      }
    } catch (e) {
      _showMessage('Ошибка загрузки: $e');
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  void _showMessage(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera → Yandex.Disk'),
        actions: [
          if (_token == null)
            TextButton(
              onPressed: _login,
              child: const Text('Login', style: TextStyle(color: Colors.white)),
            )
          else
            TextButton(
              onPressed: _logout,
              child:
                  const Text('Logout', style: TextStyle(color: Colors.white)),
            )
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _isInitializingCamera
                  ? const CircularProgressIndicator()
                  : _cameraError != null
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.camera_alt_outlined, size: 48),
                            const SizedBox(height: 12),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              child: Text(
                                'Не удалось запустить камеру:\n$_cameraError',
                                textAlign: TextAlign.center,
                              ),
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton(
                              onPressed: _initCamera,
                              child: const Text('Повторить'),
                            ),
                          ],
                        )
                      : _controller == null || !_controller!.value.isInitialized
                          ? const Text('Камера не инициализирована')
                          : CameraPreview(_controller!),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                ElevatedButton.icon(
                  onPressed: _isUploading ? null : _takePhoto,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Фото'),
                ),
                ElevatedButton.icon(
                  onPressed: _isUploading
                      ? null
                      : (_isRecording ? _stopVideo : _startVideo),
                  icon: Icon(_isRecording ? Icons.stop : Icons.videocam),
                  label: Text(_isRecording ? 'Stop' : 'Видео'),
                ),
                if (_isUploading) const CircularProgressIndicator(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Text(_token == null ? 'Не авторизован' : 'Авторизован'),
          )
        ],
      ),
    );
  }
}
