
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

class AssetWebViewScreen extends StatefulWidget {
  /// Путь к HTML-файлу в ассетах, например 'assets/vacation_challenge.html'.
  final String assetPath;

  /// Заголовок AppBar. Если null — AppBar не показывается.
  final String? title;

  /// Базовый URL, который будет видеть страница (`window.location.href`).
  /// Важен, если на странице есть relative-ссылки (./img.png) или localStorage:
  /// localStorage привязан к origin, поэтому стабильный baseUrl
  /// гарантирует, что данные сохранятся между запусками.
  final String baseUrl;

  /// Цвет фона до загрузки страницы.
  final Color backgroundColor;

  const AssetWebViewScreen({
    Key? key,
    required this.assetPath,
    this.title,
    this.baseUrl = 'https://localhost/',
    this.backgroundColor = Colors.black,
  }) : super(key: key);

  @override
  State<AssetWebViewScreen> createState() => _AssetWebViewScreenState();
}

class _AssetWebViewScreenState extends State<AssetWebViewScreen> {
  InAppWebViewController? _controller;
  bool _loading = true;
  String? _html;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAsset();
  }

  Future<void> _loadAsset() async {
    try {
      final String html = await rootBundle.loadString(widget.assetPath);
      if (!mounted) return;
      setState(() {
        _html = html;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось загрузить ${widget.assetPath}\n$e';
        _loading = false;
      });
    }
  }

  InAppWebViewSettings _settings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      javaScriptCanOpenWindowsAutomatically: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useShouldOverrideUrlLoading: true,
      transparentBackground: true,

      // Важно для работы CDN-ссылок (Tailwind, Chart.js, Font Awesome)
      // и для нормальной работы localStorage:
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,

      // Смешанный контент (https-страница загружает http-ресурсы)
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,

      // iOS
      allowsBackForwardNavigationGestures: true,

      // Android
      supportZoom: true,
      builtInZoomControls: false,
      displayZoomControls: false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final PreferredSizeWidget? appBar = widget.title == null
        ? null
        : AppBar(
      title: Text(widget.title!),
      backgroundColor: widget.backgroundColor,
      foregroundColor: Colors.white,
      elevation: 0,
      leading: Navigator.canPop(context)
          ? IconButton(
        icon: const Icon(Icons.arrow_back_ios_new, size: 20),
        onPressed: () => Navigator.pop(context),
      )
          : null,
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: () => _controller?.reload(),
        ),
      ],
    );

    return Scaffold(
      backgroundColor: widget.backgroundColor,
      appBar: appBar,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: <Widget>[
            if (_html != null) _buildWebView(),
            if (_loading) _buildLoader(),
            if (_error != null) _buildError(),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _html!,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: WebUri(widget.baseUrl),
        // Для Android — historyUrl нужен, чтобы кнопка "назад" работала корректно
        historyUrl: WebUri(widget.baseUrl),
      ),
      initialSettings: _settings(),
      onWebViewCreated: (InAppWebViewController c) {
        _controller = c;
      },
      onLoadStart: (controller, uri) {
        if (!mounted) return;
        setState(() {
          _loading = true;
        });
      },
      onLoadStop: (controller, uri) {
        if (!mounted) return;
        setState(() {
          _loading = false;
        });
      },
      onReceivedError: (controller, request, error) {
        // Игнорируем ошибки сторонних ресурсов (CDN недоступен и т.п.),
        // показываем экран ошибки только при провале основного документа.
        if (request.isForMainFrame ?? false) {
          if (!mounted) return;
          setState(() {
            _error = 'Ошибка загрузки: ${error.description}';
            _loading = false;
          });
        }
      },
      onConsoleMessage: (controller, msg) {
        // Полезно для дебага HTML/JS
        debugPrint('[WebView console] ${msg.messageLevel}: ${msg.message}');
      },
      shouldOverrideUrlLoading: (controller, navAction) async {
        final Uri? uri = navAction.request.url;
        if (uri == null) return NavigationActionPolicy.ALLOW;

        // Разрешаем все http(s)/about/data/file/blob/наш baseUrl
        final String scheme = uri.scheme.toLowerCase();
        const Set<String> allowed = <String>{
          'http', 'https', 'about', 'data', 'file', 'blob', ''
        };
        if (allowed.contains(scheme)) {
          return NavigationActionPolicy.ALLOW;
        }

        // Прочие схемы (mailto/tel/прочие deep links) можно открыть внешне
        // через url_launcher, но в этом примере просто блокируем.
        debugPrint('Blocked external scheme: $scheme ($uri)');
        return NavigationActionPolicy.CANCEL;
      },
    );
  }

  Widget _buildLoader() {
    return Container(
      color: widget.backgroundColor,
      child: const Center(
        child: CircularProgressIndicator(
          valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00F0FF)),
          strokeWidth: 2,
        ),
      ),
    );
  }

  Widget _buildError() {
    return Container(
      color: widget.backgroundColor,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(
              Icons.error_outline,
              color: Color(0xFFFF453A),
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () {
                setState(() {
                  _error = null;
                  _loading = true;
                  _html = null;
                });
                _loadAsset();
              },
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF00F0FF),
                foregroundColor: Colors.black,
              ),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}
