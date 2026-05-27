import 'dart:async';
import 'dart:convert';
import 'dart:io'
    show Platform, HttpHeaders, HttpClient, HttpClientRequest, HttpClientResponse;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as appsflyer_core;

import 'package:challengerevtwo/push_reviera.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show
    MethodChannel,
    SystemChrome,
    SystemUiOverlayStyle,
    MethodCall,
    VoidCallback;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'app_reviera.dart';
import 'loader_reviera.dart';

// ============================================================================
// Константы
// ============================================================================

const String dressRetroLoadedOnceKey = 'loaded_once';
const String dressRetroStatEndpoint = 'https://srcapi.reierachall.sbs/stat';
const String dressRetroCachedFcmKey = 'cached_fcm';
const String dressRetroCachedDeepKey = 'cached_deep_push_uri';

const Set<String> kBankSchemes = {
  'td',
  'rbc',
  'cibc',
  'scotiabank',
  'bmo',
  'bmodigitalbanking',
  'desjardins',
  'tangerine',
  'nationalbank',
  'simplii',
  'dominotoronto',
};

const Set<String> kBankDomains = {
  'td.com',
  'tdcanadatrust.com',
  'easyweb.td.com',
  'rbc.com',
  'royalbank.com',
  'online.royalbank.com',
  'cibc.com',
  'cibc.ca',
  'online.cibc.com',
  'scotiabank.com',
  'scotiaonline.scotiabank.com',
  'bmo.com',
  'bmo.ca',
  'bmodigitalbanking.com',
  'desjardins.com',
  'tangerine.ca',
  'nbc.ca',
  'nationalbank.ca',
  'simplii.com',
  'simplii.ca',
  'dominotoronto.com',
  'dominobank.com',
};

// ============================================================================
// Лёгкие сервисы
// ============================================================================

class NcupLoggerService {
  static final NcupLoggerService SharedInstance =
  NcupLoggerService._InternalConstructor();

  NcupLoggerService._InternalConstructor();

  factory NcupLoggerService() => SharedInstance;

  final Connectivity NcupConnectivity = Connectivity();

  void NcupLogInfo(Object message) => print('[I] $message');
  void NcupLogWarn(Object message) => print('[W] $message');
  void NcupLogError(Object message) => print('[E] $message');
}

class NcupNetworkService {
  final NcupLoggerService NcupLogger = NcupLoggerService();

  Future<void> NcupPostJson(
      String url,
      Map<String, dynamic> data,
      ) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: <String, String>{'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (error) {
      NcupLogger.NcupLogError('postJson error: $error');
    }
  }
}

// ============================================================================
// Утилита: одновременное сохранение JSON в localStorage и SharedPreferences
// ============================================================================

Future<void> NcupSaveJsonToLocalStorageAndPrefs({
  required InAppWebViewController? controller,
  required String key,
  required Map<String, dynamic> data,
}) async {
  final String jsonString = jsonEncode(data);

  if (controller != null) {
    try {
      await controller.evaluateJavascript(
        source: "localStorage.setItem('$key', JSON.stringify($jsonString));",
      );
    } catch (e, st) {
      NcupLoggerService().NcupLogError(
          'NcupSaveJsonToLocalStorageAndPrefs localStorage error: $e\n$st');
    }
  }

  try {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, jsonString);
  } catch (e, st) {
    NcupLoggerService().NcupLogError(
        'NcupSaveJsonToLocalStorageAndPrefs prefs error: $e\n$st');
  }
}

// ============================================================================
// Профиль устройства
// ============================================================================

class NcupDeviceProfile {
  String? NcupDeviceId;
  String? NcupSessionId = '';
  String? NcupPlatformName;
  String? NcupOsVersion;
  String? NcupAppVersion;
  String? NcupLanguageCode;
  String? NcupTimezoneName;
  bool NcupPushEnabled = false;

  bool NcupSafeAreaEnabled = false;
  String? NcupSafeAreaColor;

  // *** CHANGED: по умолчанию false, чтобы хуки не ставились,
  // пока сервер явно не пришлёт fpscashier=true
  bool safecasher = false;

  String? NcupBaseUserAgent;

  Map<String, dynamic>? NcupLastPushData;

  Map<String, dynamic>? NcupSavels;

  Future<void> NcupInitialize() async {
    final DeviceInfoPlugin ncupDeviceInfoPlugin = DeviceInfoPlugin();

    if (Platform.isAndroid) {
      final AndroidDeviceInfo ncupAndroidInfo =
      await ncupDeviceInfoPlugin.androidInfo;
      NcupDeviceId = ncupAndroidInfo.id;
      NcupPlatformName = 'android';
      NcupOsVersion = ncupAndroidInfo.version.release;
    } else if (Platform.isIOS) {
      final IosDeviceInfo ncupIosInfo = await ncupDeviceInfoPlugin.iosInfo;
      NcupDeviceId = ncupIosInfo.identifierForVendor;
      NcupPlatformName = 'ios';
      NcupOsVersion = ncupIosInfo.systemVersion;
    }

    final PackageInfo ncupPackageInfo = await PackageInfo.fromPlatform();
    NcupAppVersion = ncupPackageInfo.version;
    NcupLanguageCode = Platform.localeName.split('_').first;
    NcupTimezoneName = tz_zone.local.name;
    NcupSessionId = 'test-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> NcupToMap({String? fcmToken}) => <String, dynamic>{
    'fcm_token': fcmToken ?? 'missing_token',
    'device_id': NcupDeviceId ?? 'missing_id',
    'app_name': 'reierachall',
    'instance_id': NcupSessionId ?? 'missing_session',
    'platform': NcupPlatformName ?? 'missing_system',
    'os_version': NcupOsVersion ?? 'missing_build',
    'app_version': "1.4.1"?? 'missing_app',
    'language': NcupLanguageCode ?? 'en',
    'timezone': NcupTimezoneName ?? 'UTC',
    'push_enabled': NcupPushEnabled,
    'safe_area_native': NcupSafeAreaEnabled,
    'useragent': NcupBaseUserAgent ?? 'unknown_useragent',
    'savels': NcupSavels ?? <String, dynamic>{},
    'fpscashier': safecasher,
  };
}

// ============================================================================
// AppsFlyer Spy
// ============================================================================

class NcupAnalyticsSpyService {
  appsflyer_core.AppsFlyerOptions? NcupAppsFlyerOptions;
  appsflyer_core.AppsflyerSdk? NcupAppsFlyerSdk;

  String NcupAppsFlyerUid = '';
  String NcupAppsFlyerData = '';

  Map<String, dynamic>? NcupAppsFlyerOneLinkData;

  void NcupStartTracking({VoidCallback? onUpdate}) {
    final appsflyer_core.AppsFlyerOptions ncupConfig =
    appsflyer_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId:'6773317973',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );

    NcupAppsFlyerOptions = ncupConfig;
    NcupAppsFlyerSdk = appsflyer_core.AppsflyerSdk(ncupConfig);

    NcupAppsFlyerSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );

    NcupAppsFlyerSdk?.startSDK(
      onSuccess: () =>
          NcupLoggerService().NcupLogInfo('RetroCarAnalyticsSpy started'),
      onError: (int code, String msg) => NcupLoggerService()
          .NcupLogError('RetroCarAnalyticsSpy error $code: $msg'),
    );

    NcupAppsFlyerSdk?.onInstallConversionData((dynamic value) {
      NcupAppsFlyerData = value.toString();
      onUpdate?.call();
    });

    NcupAppsFlyerSdk?.getAppsFlyerUID().then((dynamic value) {
      NcupAppsFlyerUid = value.toString();
      onUpdate?.call();
    });
  }

  void NcupSetOneLinkData(Map<String, dynamic> data) {
    NcupAppsFlyerOneLinkData = data;
    NcupLoggerService()
        .NcupLogInfo('NcupAnalyticsSpyService: OneLink data updated: $data');
  }
}

// ============================================================================
// FCM фон
// ============================================================================

@pragma('vm:entry-point')
Future<void> NcupFcmBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();

  NcupLoggerService().NcupLogInfo('bg-fcm: ${message.messageId}');
  NcupLoggerService().NcupLogInfo('bg-data: ${message.data}');

  final dynamic ncupLink = message.data['uri'];
  if (ncupLink != null) {
    try {
      final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
      await ncupPrefs.setString(
        dressRetroCachedDeepKey,
        ncupLink.toString(),
      );
    } catch (e) {
      NcupLoggerService().NcupLogError('bg-fcm save deep failed: $e');
    }
  }
}

// ============================================================================
// FCM Bridge — токен
// ============================================================================

class NcupFcmBridge {
  final NcupLoggerService NcupLogger = NcupLoggerService();

  static const MethodChannel _tokenChannel =
  MethodChannel('com.example.fcm/token');

  String? NcupToken;
  final List<void Function(String)> NcupTokenWaiters =
  <void Function(String)>[];

  String? get NcupFcmToken => NcupToken;

  Timer? _requestTimer;
  int _requestAttempts = 0;
  final int _maxAttempts = 10;

  NcupFcmBridge() {
    _tokenChannel.setMethodCallHandler((MethodCall NcupCall) async {
      if (NcupCall.method == 'setToken') {
        final String NcupTokenString = NcupCall.arguments as String;
        NcupLogger.NcupLogInfo(
            'NcupFcmBridge: got token from native channel = $NcupTokenString');
        if (NcupTokenString.isNotEmpty) {
          NcupSetToken(NcupTokenString);
        }
      }
    });

    NcupRestoreToken();
    _requestNativeToken();
    _startRequestTimer();
  }

  Future<void> _requestNativeToken() async {
    try {
      NcupLogger.NcupLogInfo('NcupFcmBridge: request native getToken()');
      final String? token =
      await _tokenChannel.invokeMethod<String>('getToken');
      if (token != null && token.isNotEmpty) {
        NcupLogger.NcupLogInfo(
            'NcupFcmBridge: native getToken() returns $token');
        NcupSetToken(token);
      } else {
        NcupLogger.NcupLogWarn(
            'NcupFcmBridge: native getToken() returned empty');
      }
    } catch (e) {
      NcupLogger.NcupLogWarn('NcupFcmBridge: getToken invoke error: $e');
    }
  }

  void _startRequestTimer() {
    _requestTimer?.cancel();
    _requestAttempts = 0;

    _requestTimer = Timer.periodic(const Duration(seconds: 5), (Timer t) async {
      if ((NcupToken ?? '').isNotEmpty) {
        NcupLogger.NcupLogInfo(
            'NcupFcmBridge: token already set, stop request timer');
        t.cancel();
        return;
      }

      if (_requestAttempts >= _maxAttempts) {
        NcupLogger.NcupLogWarn(
            'NcupFcmBridge: max getToken attempts reached, stop timer');
        t.cancel();
        return;
      }

      _requestAttempts++;
      NcupLogger.NcupLogInfo(
          'NcupFcmBridge: retry getToken() attempt #$_requestAttempts');
      await _requestNativeToken();
    });
  }

  Future<void> NcupRestoreToken() async {
    try {
      final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
      final String? ncupCachedToken =
      ncupPrefs.getString(dressRetroCachedFcmKey);
      if (ncupCachedToken != null && ncupCachedToken.isNotEmpty) {
        NcupLogger.NcupLogInfo(
            'NcupFcmBridge: restored cached token = $ncupCachedToken');
        NcupSetToken(ncupCachedToken, notify: false);
      }
    } catch (e) {
      NcupLogger.NcupLogError('NcupRestoreToken error: $e');
    }
  }

  Future<void> NcupPersistToken(String newToken) async {
    try {
      final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
      await ncupPrefs.setString(dressRetroCachedFcmKey, newToken);
    } catch (e) {
      NcupLogger.NcupLogError('NcupPersistToken error: $e');
    }
  }

  void NcupSetToken(
      String newToken, {
        bool notify = true,
      }) {
    NcupToken = newToken;
    NcupPersistToken(newToken);

    if (notify) {
      for (final void Function(String) ncupCallback
      in List<void Function(String)>.from(NcupTokenWaiters)) {
        try {
          ncupCallback(newToken);
        } catch (error) {
          NcupLogger.NcupLogWarn('fcm waiter error: $error');
        }
      }
      NcupTokenWaiters.clear();
    }
  }

  Future<void> NcupWaitForToken(
      Function(String token) ncupOnToken,
      ) async {
    try {
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      if ((NcupToken ?? '').isNotEmpty) {
        ncupOnToken(NcupToken!);
        return;
      }

      NcupTokenWaiters.add(ncupOnToken);
    } catch (error) {
      NcupLogger.NcupLogError('NcupWaitForToken error: $error');
    }
  }

  void dispose() {
    _requestTimer?.cancel();
  }
}

// ============================================================================
// Splash / Hall
// ============================================================================

class NcupHall extends StatefulWidget {
  const NcupHall({Key? key}) : super(key: key);

  @override
  State<NcupHall> createState() => _NcupHallState();
}

class _NcupHallState extends State<NcupHall> {
  final NcupFcmBridge NcupFcmBridgeInstance = NcupFcmBridge();
  bool NcupNavigatedOnce = false;
  Timer? NcupFallbackTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    NcupFcmBridgeInstance.NcupWaitForToken((String ncupToken) {
      NcupGoToHarbor(ncupToken);
    });

    NcupFallbackTimer = Timer(
      const Duration(seconds: 8),
          () => NcupGoToHarbor(''),
    );
  }

  void NcupGoToHarbor(String ncupSignal) {
    if (NcupNavigatedOnce) return;
    NcupNavigatedOnce = true;
    NcupFallbackTimer?.cancel();

    Navigator.pushReplacement(
      context,
      MaterialPageRoute<Widget>(
        builder: (BuildContext context) => NcupHarbor(NcupSignal: ncupSignal),
      ),
    );
  }

  @override
  void dispose() {
    NcupFallbackTimer?.cancel();
    NcupFcmBridgeInstance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: PalmGrowLoader(),
        ),
      ),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================

class NcupBosunViewModel {
  final NcupDeviceProfile NcupDeviceProfileInstance;
  final NcupAnalyticsSpyService NcupAnalyticsSpyInstance;

  NcupBosunViewModel({
    required this.NcupDeviceProfileInstance,
    required this.NcupAnalyticsSpyInstance,
  });

  Map<String, dynamic> NcupDeviceMap(String? fcmToken) =>
      NcupDeviceProfileInstance.NcupToMap(fcmToken: fcmToken);

  Map<String, dynamic> NcupAppsFlyerPayload(
      String? token, {
        String? deepLink,
      }) {
    final Map<String, dynamic> onelinkData =
        NcupAnalyticsSpyInstance.NcupAppsFlyerOneLinkData ??
            <String, dynamic>{};

    return <String, dynamic>{
      'content': <String, dynamic>{
        'af_data': NcupAnalyticsSpyInstance.NcupAppsFlyerData,
        'af_id': NcupAnalyticsSpyInstance.NcupAppsFlyerUid,
        'fb_app_name': 'reierachall',
        'app_name': 'reierachall',
        'onelink': onelinkData,
        'bundle_identifier': 'com.challangereveiera.reviera.challangereveiera',
        'app_version': '1.4.1',
        'apple_id': '6773317973',
        'fcm_token': token ?? 'no_token',
        'device_id': NcupDeviceProfileInstance.NcupDeviceId ?? 'no_device',
        'instance_id':
        NcupDeviceProfileInstance.NcupSessionId ?? 'no_instance',
        'platform': NcupDeviceProfileInstance.NcupPlatformName ?? 'no_type',
        'os_version': NcupDeviceProfileInstance.NcupOsVersion ?? 'no_os',
        'language': NcupDeviceProfileInstance.NcupLanguageCode ?? 'en',
        'timezone': NcupDeviceProfileInstance.NcupTimezoneName ?? 'UTC',
        'push_enabled': NcupDeviceProfileInstance.NcupPushEnabled,
        'useruid': NcupAnalyticsSpyInstance.NcupAppsFlyerUid,
        'safearea': NcupDeviceProfileInstance.NcupSafeAreaEnabled,
        'safearea_color':
        NcupDeviceProfileInstance.NcupSafeAreaColor ?? '',
        'useragent':
        NcupDeviceProfileInstance.NcupBaseUserAgent ?? 'unknown_useragent',
        'push':
        NcupDeviceProfileInstance.NcupLastPushData ?? <String, dynamic>{},
        'deep': deepLink,
        'fpscashier': NcupDeviceProfileInstance.safecasher,
      },
    };
  }
}

class NcupCourierService {
  final NcupBosunViewModel NcupBosun;
  final InAppWebViewController? Function() NcupGetWebViewController;

  NcupCourierService({
    required this.NcupBosun,
    required this.NcupGetWebViewController,
  });

  Future<InAppWebViewController?> _waitForController({
    Duration timeout = const Duration(seconds: 10),
    Duration interval = const Duration(milliseconds: 200),
  }) async {
    final NcupLoggerService logger = NcupLoggerService();
    final DateTime start = DateTime.now();

    while (DateTime.now().difference(start) < timeout) {
      final InAppWebViewController? c = NcupGetWebViewController();
      if (c != null) {
        return c;
      }
      await Future<void>.delayed(interval);
    }

    logger.NcupLogWarn('_waitForController: timeout, controller is still null');
    return null;
  }

  Future<void> NcupPutDeviceToLocalStorage(String? token) async {
    final InAppWebViewController? ncupController = await _waitForController();
    if (ncupController == null) return;

    final Map<String, dynamic> ncupMap = NcupBosun.NcupDeviceMap(token);
    NcupLoggerService().NcupLogInfo("applocal (${jsonEncode(ncupMap)});");

    await NcupSaveJsonToLocalStorageAndPrefs(
      controller: ncupController,
      key: 'app_data',
      data: ncupMap,
    );
  }

  Future<void> NcupSendRawToPage(
      String? token, {
        String? deepLink,
      }) async {
    final InAppWebViewController? ncupController = await _waitForController();
    if (ncupController == null) return;

    final Map<String, dynamic> ncupPayload =
    NcupBosun.NcupAppsFlyerPayload(token, deepLink: deepLink);

    final String ncupJsonString = jsonEncode(ncupPayload);

    NcupLoggerService().NcupLogInfo('SendRawData: $ncupJsonString');

    final String jsSafeJson = jsonEncode(ncupJsonString);
    final String jsCode = 'sendRawData($jsSafeJson);';

    try {
      await ncupController.evaluateJavascript(source: jsCode);
    } catch (e, st) {
      NcupLoggerService()
          .NcupLogError('NcupSendRawToPage evaluateJavascript error: $e\n$st');
    }
  }
}

// ============================================================================
// Статистика
// ============================================================================

Future<String> NcupResolveFinalUrl(
    String startUrl, {
      int maxHops = 10,
    }) async {
  final HttpClient ncupHttpClient = HttpClient();

  try {
    Uri ncupCurrentUri = Uri.parse(startUrl);

    for (int ncupIndex = 0; ncupIndex < maxHops; ncupIndex++) {
      final HttpClientRequest ncupRequest =
      await ncupHttpClient.getUrl(ncupCurrentUri);
      ncupRequest.followRedirects = false;
      final HttpClientResponse ncupResponse = await ncupRequest.close();

      if (ncupResponse.isRedirect) {
        final String? ncupLocationHeader =
        ncupResponse.headers.value(HttpHeaders.locationHeader);
        if (ncupLocationHeader == null || ncupLocationHeader.isEmpty) {
          break;
        }

        final Uri ncupNextUri = Uri.parse(ncupLocationHeader);
        ncupCurrentUri = ncupNextUri.hasScheme
            ? ncupNextUri
            : ncupCurrentUri.resolveUri(ncupNextUri);
        continue;
      }

      return ncupCurrentUri.toString();
    }

    return ncupCurrentUri.toString();
  } catch (error) {
    print('goldenLuxuryResolveFinalUrl error: $error');
    return startUrl;
  } finally {
    ncupHttpClient.close(force: true);
  }
}

Future<void> NcupPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final String ncupResolvedUrl = await NcupResolveFinalUrl(url);

    final Map<String, dynamic> ncupPayload = <String, dynamic>{
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': ncupResolvedUrl,
      'appleID': '6758657360',
      'open_count': '$appSid/$timeStart',
    };

    print('goldenLuxuryStat $ncupPayload');

    final http.Response ncupResponse = await http.post(
      Uri.parse('$dressRetroStatEndpoint/$appSid'),
      headers: <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(ncupPayload),
    );

    print(
        'goldenLuxuryStat resp=${ncupResponse.statusCode} body=${ncupResponse.body}');
  } catch (error) {
    print('goldenLuxuryPostStat error: $error');
  }
}

// ============================================================================
// Банковские утилиты
// ============================================================================

bool NcupIsBankScheme(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  return kBankSchemes.contains(scheme);
}

bool NcupIsBankDomain(Uri uri) {
  final String host = uri.host.toLowerCase();
  if (host.isEmpty) return false;

  for (final String bank in kBankDomains) {
    final String bankHost = bank.toLowerCase();
    if (host == bankHost || host.endsWith('.$bankHost')) {
      return true;
    }
  }
  return false;
}

Future<bool> NcupOpenBank(Uri uri) async {
  try {
    if (NcupIsBankScheme(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }

    if ((uri.scheme == 'http' || uri.scheme == 'https') &&
        NcupIsBankDomain(uri)) {
      final bool ok = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      return ok;
    }
  } catch (e) {
    print('NcupOpenBank error: $e; url=$uri');
  }
  return false;
}

// ============================================================================
// Главный WebView — Harbor
// ============================================================================

class NcupHarbor extends StatefulWidget {
  final String? NcupSignal;

  const NcupHarbor({super.key, required this.NcupSignal});

  @override
  State<NcupHarbor> createState() => _NcupHarborState();
}

class _NcupHarborState extends State<NcupHarbor> with WidgetsBindingObserver {
  InAppWebViewController? NcupWebViewController;

  InAppWebViewController? NcupPopupWebViewController;
  bool _isPopupVisible = false;
  String? _popupUrl;
  CreateWindowAction? _popupCreateAction;

  bool _popupCanGoBack = false;
  String? _popupCurrentUrl;

  bool _isOpeningExternalNewTab = false;
  final Set<String> _handledNewTabUrls = <String>{};

  Timer? _parentInstallTimer;
  Timer? _popupInstallTimer;

  final String NcupHomeUrl = 'https://srcapi.reierachall.sbs/';

  int NcupWebViewKeyCounter = 0;
  DateTime? NcupSleepAt;
  bool NcupVeilVisible = false;
  double NcupWarmProgress = 0.0;
  late Timer NcupWarmTimer;
  final int NcupWarmSeconds = 6;
  bool NcupCoverVisible = true;

  bool NcupLoadedOnceSent = false;
  int? NcupFirstPageTimestamp;

  NcupCourierService? NcupCourier;
  NcupBosunViewModel? NcupBosunInstance;

  String NcupCurrentUrl = '';
  int NcupStartLoadTimestamp = 0;

  final NcupDeviceProfile NcupDeviceProfileInstance = NcupDeviceProfile();
  final NcupAnalyticsSpyService NcupAnalyticsSpyInstance =
  NcupAnalyticsSpyService();

  final Set<String> NcupSpecialSchemes = <String>{
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> NcupExternalHosts = <String>{
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  String? NcupDeepLinkFromPush;

  String? _baseUserAgent;
  String _currentUserAgent = "";
  String? _currentUrl;

  String? _serverUserAgent;

  bool _safeAreaEnabled = false;
  Color _safeAreaBackgroundColor = const Color(0xFF000000);

  bool _startupSendRawDone = false;

  String? _pendingLoadedJs;

  bool _loadedJsExecutedOnce = false;

  bool _isInGoogleAuth = false;

  List<String> _buttonWhitelist = <String>[];
  bool _showBackButton = false;

  bool _backButtonHiddenAfterTap = false;

  bool _isCurrentlyOnGoogle = false;

  static const MethodChannel _appsFlyerDeepLinkChannel =
  MethodChannel('appsflyer_deeplink_channel');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NcupFirstPageTimestamp = DateTime.now().millisecondsSinceEpoch;
    _currentUrl = NcupHomeUrl;

    Future<void>.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          NcupCoverVisible = false;
        });
      }
    });

    Future<void>.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() {
        NcupVeilVisible = true;
      });
    });

    _bindPushChannelFromAppDelegate();
    _bindAppsFlyerDeepLinkChannel();
    NcupBootHarbor();
  }

  bool _isAboutBlankUrl(String? value) {
    final String u = (value ?? '').trim().toLowerCase();
    return u.isEmpty || u == 'about:blank' || u.startsWith('about:blank');
  }

  bool _isAboutBlankUri(Uri? uri) => _isAboutBlankUrl(uri?.toString());

  void _bindAppsFlyerDeepLinkChannel() {
    _appsFlyerDeepLinkChannel.setMethodCallHandler(
          (MethodCall call) async {
        if (call.method == 'onDeepLink') {
          try {
            final dynamic args = call.arguments;

            Map<String, dynamic> payload;

            print(" Data Deepl link ${args.toString()}");
            if (args is Map) {
              payload = Map<String, dynamic>.from(args as Map);
            } else if (args is String) {
              payload = jsonDecode(args) as Map<String, dynamic>;
            } else {
              payload = <String, dynamic>{'raw': args.toString()};
            }

            NcupLoggerService().NcupLogInfo(
              'AppsFlyer onDeepLink from iOS: $payload',
            );

            final dynamic raw = payload['raw'];
            if (raw is Map) {
              final Map<String, dynamic> normalized =
              Map<String, dynamic>.from(raw as Map);

              print("One Link Data $normalized");
              NcupAnalyticsSpyInstance.NcupSetOneLinkData(normalized);
            } else {
              NcupAnalyticsSpyInstance.NcupSetOneLinkData(payload);
            }
          } catch (e, st) {
            NcupLoggerService()
                .NcupLogError('Error in onDeepLink handler: $e\n$st');
          }
        }
      },
    );
  }

  void _bindPushChannelFromAppDelegate() {
    const MethodChannel pushChannel = MethodChannel('com.example.fcm/push');

    pushChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'setPushData') {
        try {
          Map<String, dynamic> pushData;
          if (call.arguments is Map) {
            pushData = Map<String, dynamic>.from(call.arguments);
            print("Get Push Data $pushData");
          } else if (call.arguments is String) {
            pushData =
            jsonDecode(call.arguments as String) as Map<String, dynamic>;
          } else {
            pushData = <String, dynamic>{'raw': call.arguments.toString()};
          }

          NcupLoggerService()
              .NcupLogInfo('Got push data from AppDelegate: $pushData');

          NcupDeviceProfileInstance.NcupLastPushData = pushData;

          final dynamic uriRaw = pushData['uri'] ?? pushData['deep_link'];
          if (uriRaw != null && uriRaw.toString().isNotEmpty) {
            final String u = uriRaw.toString();
            NcupDeepLinkFromPush = u;
            await NcupSaveCachedDeep(u);
          }
        } catch (e, st) {
          NcupLoggerService()
              .NcupLogError('setPushData handler error: $e\n$st');
        }
      }
    });
  }

  bool _isGoogleUrl(Uri uri) {
    final String full = uri.toString().toLowerCase();
    return full.contains('google.com') ||
        full.contains('accounts.google.') ||
        full.contains('googleusercontent.com') ||
        full.contains('gstatic.com');
  }

  Future<void> _applyGoogleUserAgent() async {
    if (NcupWebViewController == null) return;

    const String googleUa = 'random';

    if (_currentUserAgent == googleUa) {
      NcupLoggerService()
          .NcupLogInfo('[UA] Already set to "random" for Google, skip');
      return;
    }

    NcupLoggerService()
        .NcupLogInfo('[UA] Applying GOOGLE User-Agent: $googleUa');

    try {
      await NcupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      _currentUserAgent = googleUa;
      _isCurrentlyOnGoogle = true;
      print('[UA] GOOGLE WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      NcupLoggerService()
          .NcupLogError('Error setting Google User-Agent: $e');
    }
  }

  Future<void> _applyGoogleUserAgentForPopup() async {
    if (NcupPopupWebViewController == null) return;

    const String googleUa = 'random';

    NcupLoggerService()
        .NcupLogInfo('[UA] Applying GOOGLE User-Agent to POPUP: $googleUa');

    try {
      await NcupPopupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: googleUa),
      );
      print('[UA] GOOGLE POPUP USER AGENT: $googleUa');
    } catch (e) {
      NcupLoggerService()
          .NcupLogError('Error setting Google User-Agent for popup: $e');
    }
  }

  Future<void> _updateUserAgentFromServerPayload(
      Map<dynamic, dynamic> root) async {
    String? fullua;
    String? uatail;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['fullua'] != null &&
          content['fullua'].toString().trim().isNotEmpty) {
        fullua = content['fullua'].toString().trim();
      }
      if (content['uatail'] != null &&
          content['uatail'].toString().trim().isNotEmpty) {
        uatail = content['uatail'].toString().trim();
      }
    }

    if (fullua == null &&
        root['fullua'] != null &&
        root['fullua'].toString().trim().isNotEmpty) {
      fullua = root['fullua'].toString().trim();
    }
    if (uatail == null &&
        root['uatail'] != null &&
        root['uatail'].toString().trim().isNotEmpty) {
      uatail = root['uatail'].toString().trim();
    }

    if (uatail == null) {
      final dynamic adata = root['adata'];
      if (adata is Map &&
          adata['uatail'] != null &&
          adata['uatail'].toString().trim().isNotEmpty) {
        uatail = adata['uatail'].toString().trim();
      }
    }

    await _applyUserAgent(fullua: fullua, uatail: uatail);
  }

  Future<void> _applyUserAgent({String? fullua, String? uatail}) async {
    if (NcupWebViewController == null) return;

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      try {
        final ua = await NcupWebViewController!.evaluateJavascript(
          source: "navigator.userAgent",
        );
        if (ua is String && ua.trim().isNotEmpty) {
          _baseUserAgent = ua.trim();
          _currentUserAgent = _baseUserAgent!;
          NcupDeviceProfileInstance.NcupBaseUserAgent = _baseUserAgent;
          NcupLoggerService()
              .NcupLogInfo('Base User-Agent detected: $_baseUserAgent');
        }
      } catch (e) {
        NcupLoggerService()
            .NcupLogWarn('Failed to get base userAgent from JS: $e');
      }
    }

    if (_baseUserAgent == null || _baseUserAgent!.trim().isEmpty) {
      NcupLoggerService()
          .NcupLogWarn('Base User-Agent is still null/empty, skip UA update');
      return;
    }

    NcupLoggerService().NcupLogInfo(
        'Server UA payload: fullua="$fullua", uatail="$uatail", base="$_baseUserAgent"');

    String newUa;
    if (fullua != null && fullua.trim().isNotEmpty) {
      newUa = fullua.trim();
    } else if (uatail != null && uatail.trim().isNotEmpty) {
      newUa = "${_baseUserAgent!}/${uatail.trim()}";
    } else {
      newUa = "${_baseUserAgent!}";
    }

    _serverUserAgent = newUa;
    NcupLoggerService()
        .NcupLogInfo('Server UA calculated and stored: $_serverUserAgent');
  }

  Future<void> _applyNormalUserAgentIfNeeded() async {
    if (NcupWebViewController == null) return;

    if (_isCurrentlyOnGoogle) {
      NcupLoggerService().NcupLogInfo(
          '[UA] Currently on Google page, keeping "random" UA');
      return;
    }

    final String targetUa = _serverUserAgent ?? _baseUserAgent ?? 'random';

    if (targetUa == _currentUserAgent) {
      NcupLoggerService()
          .NcupLogInfo('Normal UA unchanged, keeping: $_currentUserAgent');
      return;
    }

    NcupLoggerService()
        .NcupLogInfo('Applying NORMAL WebView User-Agent: $targetUa');

    try {
      await NcupWebViewController!.setSettings(
        settings: InAppWebViewSettings(userAgent: targetUa),
      );
      _currentUserAgent = targetUa;
      print('[UA] NORMAL WEBVIEW USER AGENT: $_currentUserAgent');
    } catch (e) {
      NcupLoggerService()
          .NcupLogError('Error while setting normal User-Agent "$targetUa": $e');
    }
  }

  Future<void> _switchUserAgentForUrl(Uri? uri) async {
    if (uri == null) return;

    if (_isGoogleUrl(uri)) {
      _isCurrentlyOnGoogle = true;
      await _applyGoogleUserAgent();
    } else {
      if (_isCurrentlyOnGoogle) {
        _isCurrentlyOnGoogle = false;
      }
      await _applyNormalUserAgentIfNeeded();
    }
  }

  Future<void> printJsUserAgent() async {
    if (NcupWebViewController == null) return;

    try {
      final ua = await NcupWebViewController!.evaluateJavascript(
        source: "navigator.userAgent",
      );

      if (ua is String) {
        print('[JS UA] navigator.userAgent = $ua');
      } else {
        print('[JS UA] navigator.userAgent (non-string) = $ua');
      }
    } catch (e, st) {
      print('Error reading navigator.userAgent: $e\n$st');
    }
  }

  Future<void> debugPrintCurrentUserAgent() async {
    NcupLoggerService()
        .NcupLogInfo('[STATE UA] _currentUserAgent = $_currentUserAgent');
    await printJsUserAgent();
  }

  Future<void> NcupLoadLoadedFlag() async {
    final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
    NcupLoadedOnceSent = ncupPrefs.getBool(dressRetroLoadedOnceKey) ?? false;
  }

  Future<void> NcupSaveLoadedFlag() async {
    final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
    await ncupPrefs.setBool(dressRetroLoadedOnceKey, true);
    NcupLoadedOnceSent = true;
  }

  Future<void> NcupLoadCachedDeep() async {
    try {
      final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
      final String? ncupCached = ncupPrefs.getString(dressRetroCachedDeepKey);
      if ((ncupCached ?? '').isNotEmpty) {
        NcupDeepLinkFromPush = ncupCached;
      }
    } catch (_) {}
  }

  Future<void> NcupSaveCachedDeep(String uri) async {
    try {
      final SharedPreferences ncupPrefs = await SharedPreferences.getInstance();
      await ncupPrefs.setString(dressRetroCachedDeepKey, uri);
    } catch (_) {}
  }

  Future<void> NcupSendLoadedOnce({
    required String url,
    required int timestart,
  }) async {
    if (NcupLoadedOnceSent) return;

    final int ncupNow = DateTime.now().millisecondsSinceEpoch;

    await NcupPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: ncupNow,
      url: url,
      appSid: NcupAnalyticsSpyInstance.NcupAppsFlyerUid,
      firstPageLoadTs: NcupFirstPageTimestamp,
    );

    await NcupSaveLoadedFlag();
  }

  void NcupBootHarbor() {
    NcupStartWarmProgress();
    NcupWireFcmHandlers();
    NcupAnalyticsSpyInstance.NcupStartTracking(
      onUpdate: () => setState(() {}),
    );
    NcupBindNotificationTap();
    NcupPrepareDeviceProfile();
  }

  void NcupWireFcmHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage ncupMessage) async {
      final dynamic ncupLink = ncupMessage.data['uri'];
      if (ncupLink != null) {
        final String ncupUri = ncupLink.toString();
        NcupDeepLinkFromPush = ncupUri;
        await NcupSaveCachedDeep(ncupUri);
      } else {
        NcupResetHomeAfterDelay();
      }
    });

    FirebaseMessaging.onMessageOpenedApp
        .listen((RemoteMessage ncupMessage) async {
      final dynamic ncupLink = ncupMessage.data['uri'];
      if (ncupLink != null) {
        final String ncupUri = ncupLink.toString();
        NcupDeepLinkFromPush = ncupUri;
        await NcupSaveCachedDeep(ncupUri);

        NcupNavigateToUri(ncupUri);

        await NcupPushDeviceInfo();
        await NcupPushAppsFlyerData();
      } else {
        NcupResetHomeAfterDelay();
      }
    });
  }

  void NcupBindNotificationTap() {
    MethodChannel('com.example.fcm/notification')
        .setMethodCallHandler((MethodCall call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> ncupPayload =
        Map<String, dynamic>.from(call.arguments);
        final String? ncupUriRaw = ncupPayload['uri']?.toString();

        if (ncupUriRaw != null &&
            ncupUriRaw.isNotEmpty &&
            !ncupUriRaw.contains('Нет URI')) {
          final String ncupUri = ncupUriRaw;
          NcupDeepLinkFromPush = ncupUri;
          await NcupSaveCachedDeep(ncupUri);

          if (!context.mounted) return;

          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute<Widget>(
              builder: (BuildContext context) => NcupTableView(ncupUri),
            ),
                (Route<dynamic> route) => false,
          );

          await NcupPushDeviceInfo();
          await NcupPushAppsFlyerData();
        }
      }
    });
  }

  Future<void> NcupPrepareDeviceProfile() async {
    try {
      await NcupDeviceProfileInstance.NcupInitialize();

      final FirebaseMessaging ncupMessaging = FirebaseMessaging.instance;
      final NotificationSettings ncupSettings =
      await ncupMessaging.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );

      NcupDeviceProfileInstance.NcupPushEnabled =
          ncupSettings.authorizationStatus ==
              AuthorizationStatus.authorized ||
              ncupSettings.authorizationStatus ==
                  AuthorizationStatus.provisional;

      await NcupLoadLoadedFlag();
      await NcupLoadCachedDeep();

      NcupBosunInstance = NcupBosunViewModel(
        NcupDeviceProfileInstance: NcupDeviceProfileInstance,
        NcupAnalyticsSpyInstance: NcupAnalyticsSpyInstance,
      );

      NcupCourier = NcupCourierService(
        NcupBosun: NcupBosunInstance!,
        NcupGetWebViewController: () => NcupWebViewController,
      );
    } catch (error) {
      NcupLoggerService().NcupLogError('prepareDeviceProfile fail: $error');
    }
  }

  void NcupNavigateToUri(String link) async {
    try {
      await NcupWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(link)),
      );
    } catch (error) {
      NcupLoggerService().NcupLogError('navigate error: $error');
    }
  }

  void NcupResetHomeAfterDelay() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      try {
        NcupWebViewController?.loadUrl(
          urlRequest: URLRequest(url: WebUri(NcupHomeUrl)),
        );
      } catch (_) {}
    });
  }

  String? _resolveTokenForShip() {
    if (widget.NcupSignal != null && widget.NcupSignal!.isNotEmpty) {
      return widget.NcupSignal;
    }
    return null;
  }

  Future<void> _sendAllDataToPageTwice() async {
    await NcupPushDeviceInfo();

    Future<void>.delayed(const Duration(seconds: 6), () async {
      await NcupPushDeviceInfo();
      await NcupPushAppsFlyerData();
    });
  }

  Future<void> NcupPushDeviceInfo() async {
    final String? ncupToken = _resolveTokenForShip();

    try {
      await NcupCourier?.NcupPutDeviceToLocalStorage(ncupToken);
    } catch (error) {
      NcupLoggerService().NcupLogError('pushDeviceInfo error: $error');
    }
  }

  Future<void> NcupPushAppsFlyerData() async {
    final String? ncupToken = _resolveTokenForShip();

    try {
      await NcupCourier?.NcupSendRawToPage(
        ncupToken,
        deepLink: NcupDeepLinkFromPush,
      );
    } catch (error) {
      NcupLoggerService().NcupLogError('pushAppsFlyerData error: $error');
    }
  }

  void NcupStartWarmProgress() {
    int ncupTick = 0;
    NcupWarmProgress = 0.0;

    NcupWarmTimer =
        Timer.periodic(const Duration(milliseconds: 100), (Timer timer) {
          if (!mounted) return;

          setState(() {
            ncupTick++;
            NcupWarmProgress = ncupTick / (NcupWarmSeconds * 10);

            if (NcupWarmProgress >= 1.0) {
              NcupWarmProgress = 1.0;
              NcupWarmTimer.cancel();
            }
          });
        });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      NcupSleepAt = DateTime.now();
    }

    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && NcupSleepAt != null) {
        final DateTime ncupNow = DateTime.now();
        final Duration ncupDrift = ncupNow.difference(NcupSleepAt!);

        if (ncupDrift > const Duration(minutes: 25)) {
          NcupReboardHarbor();
        }
      }
      NcupSleepAt = null;
    }
  }

  void NcupReboardHarbor() {
    if (!mounted) return;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              NcupHarbor(NcupSignal: widget.NcupSignal),
        ),
            (Route<dynamic> route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NcupWarmTimer.cancel();

    _parentInstallTimer?.cancel();
    _popupInstallTimer?.cancel();

    NcupWebViewController = null;
    NcupPopupWebViewController = null;

    super.dispose();
  }

  bool NcupIsBareEmail(Uri uri) {
    final String ncupScheme = uri.scheme;
    if (ncupScheme.isNotEmpty) return false;
    final String ncupRaw = uri.toString();
    return ncupRaw.contains('@') && !ncupRaw.contains(' ');
  }

  Uri NcupToMailto(Uri uri) {
    final String ncupFull = uri.toString();
    final List<String> ncupParts = ncupFull.split('?');
    final String ncupEmail = ncupParts.first;
    final Map<String, String> ncupQueryParams = ncupParts.length > 1
        ? Uri.splitQueryString(ncupParts[1])
        : <String, String>{};

    return Uri(
      scheme: 'mailto',
      path: ncupEmail,
      queryParameters: ncupQueryParams.isEmpty ? null : ncupQueryParams,
    );
  }

  Future<bool> NcupOpenMailExternal(Uri mailto) async {
    try {
      final String scheme = mailto.scheme.toLowerCase();
      final String path = mailto.path.toLowerCase();

      NcupLoggerService().NcupLogInfo(
          'NcupOpenMailExternal: scheme=$scheme path=$path uri=$mailto');

      if (scheme != 'mailto') {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        NcupLoggerService()
            .NcupLogInfo('NcupOpenMailExternal: non-mailto result=$ok');
        return ok;
      }

      final bool can = await canLaunchUrl(mailto);
      NcupLoggerService()
          .NcupLogInfo('NcupOpenMailExternal: canLaunchUrl(mailto) = $can');

      if (can) {
        final bool ok = await launchUrl(
          mailto,
          mode: LaunchMode.externalApplication,
        );
        NcupLoggerService()
            .NcupLogInfo('NcupOpenMailExternal: externalApplication result=$ok');
        if (ok) return true;
      }

      NcupLoggerService().NcupLogWarn(
          'NcupOpenMailExternal: no native handler for mailto, fallback to Gmail Web');
      final Uri gmailUri = NcupGmailizeMailto(mailto);
      final bool webOk = await NcupOpenWeb(gmailUri);
      NcupLoggerService()
          .NcupLogInfo('NcupOpenMailExternal: Gmail Web fallback result=$webOk');
      return webOk;
    } catch (e, st) {
      NcupLoggerService()
          .NcupLogError('NcupOpenMailExternal error: $e\n$st; url=$mailto');
      return false;
    }
  }

  Future<bool> NcupOpenMailWeb(Uri mailto) async {
    final Uri ncupGmailUri = NcupGmailizeMailto(mailto);
    return NcupOpenWeb(ncupGmailUri);
  }

  Uri NcupGmailizeMailto(Uri mailUri) {
    final Map<String, String> ncupQueryParams = mailUri.queryParameters;

    final Map<String, String> ncupParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (mailUri.path.isNotEmpty) 'to': mailUri.path,
      if ((ncupQueryParams['subject'] ?? '').isNotEmpty)
        'su': ncupQueryParams['subject']!,
      if ((ncupQueryParams['body'] ?? '').isNotEmpty)
        'body': ncupQueryParams['body']!,
      if ((ncupQueryParams['cc'] ?? '').isNotEmpty)
        'cc': ncupQueryParams['cc']!,
      if ((ncupQueryParams['bcc'] ?? '').isNotEmpty)
        'bcc': ncupQueryParams['bcc']!,
    };

    return Uri.https('mail.google.com', '/mail/', ncupParams);
  }

  bool NcupIsPlatformLink(Uri uri) {
    final String ncupScheme = uri.scheme.toLowerCase();
    if (NcupSpecialSchemes.contains(ncupScheme)) {
      return true;
    }

    if (ncupScheme == 'http' || ncupScheme == 'https') {
      final String ncupHost = uri.host.toLowerCase();

      if (NcupExternalHosts.contains(ncupHost)) {
        return true;
      }

      if (ncupHost.endsWith('t.me')) return true;
      if (ncupHost.endsWith('wa.me')) return true;
      if (ncupHost.endsWith('m.me')) return true;
      if (ncupHost.endsWith('signal.me')) return true;
      if (ncupHost.endsWith('facebook.com')) return true;
      if (ncupHost.endsWith('instagram.com')) return true;
      if (ncupHost.endsWith('twitter.com')) return true;
      if (ncupHost.endsWith('x.com')) return true;
    }

    return false;
  }

  String NcupDigitsOnly(String source) =>
      source.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri NcupHttpizePlatformUri(Uri uri) {
    final String ncupScheme = uri.scheme.toLowerCase();

    if (ncupScheme == 'tg' || ncupScheme == 'telegram') {
      final Map<String, String> ncupQp = uri.queryParameters;
      final String? ncupDomain = ncupQp['domain'];

      if (ncupDomain != null && ncupDomain.isNotEmpty) {
        return Uri.https(
          't.me',
          '/$ncupDomain',
          <String, String>{
            if (ncupQp['start'] != null) 'start': ncupQp['start']!,
          },
        );
      }

      final String ncupPath = uri.path.isNotEmpty ? uri.path : '';

      return Uri.https(
        't.me',
        '/$ncupPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if ((ncupScheme == 'http' || ncupScheme == 'https') &&
        uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (ncupScheme == 'viber') {
      return uri;
    }

    if (ncupScheme == 'whatsapp') {
      final Map<String, String> ncupQp = uri.queryParameters;
      final String? ncupPhone = ncupQp['phone'];
      final String? ncupText = ncupQp['text'];

      if (ncupPhone != null && ncupPhone.isNotEmpty) {
        return Uri.https(
          'wa.me',
          '/${NcupDigitsOnly(ncupPhone)}',
          <String, String>{
            if (ncupText != null && ncupText.isNotEmpty) 'text': ncupText,
          },
        );
      }

      return Uri.https(
        'wa.me',
        '/',
        <String, String>{
          if (ncupText != null && ncupText.isNotEmpty) 'text': ncupText,
        },
      );
    }

    if ((ncupScheme == 'http' || ncupScheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') ||
            uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (ncupScheme == 'skype') {
      return uri;
    }

    if (ncupScheme == 'fb-messenger') {
      final String ncupPath =
      uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final Map<String, String> ncupQp = uri.queryParameters;

      final String ncupId = ncupQp['id'] ?? ncupQp['user'] ?? ncupPath;

      if (ncupId.isNotEmpty) {
        return Uri.https(
          'm.me',
          '/$ncupId',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return Uri.https(
        'm.me',
        '/',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    if (ncupScheme == 'sgnl') {
      final Map<String, String> ncupQp = uri.queryParameters;
      final String? ncupPhone = ncupQp['phone'];
      final String? ncupUsername = ncupQp['username'];

      if (ncupPhone != null && ncupPhone.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#p/${NcupDigitsOnly(ncupPhone)}',
        );
      }

      if (ncupUsername != null && ncupUsername.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/#u/$ncupUsername',
        );
      }

      final String ncupPath = uri.pathSegments.join('/');
      if (ncupPath.isNotEmpty) {
        return Uri.https(
          'signal.me',
          '/$ncupPath',
          uri.queryParameters.isEmpty ? null : uri.queryParameters,
        );
      }

      return uri;
    }

    if (ncupScheme == 'tel') {
      return Uri.parse('tel:${NcupDigitsOnly(uri.path)}');
    }

    if (ncupScheme == 'mailto') {
      return uri;
    }

    if (ncupScheme == 'bnl') {
      final String ncupNewPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https(
        'bnl.com',
        '/$ncupNewPath',
        uri.queryParameters.isEmpty ? null : uri.queryParameters,
      );
    }

    return uri;
  }

  Future<bool> NcupOpenWeb(Uri uri) async {
    try {
      if (await launchUrl(
        uri,
        mode: LaunchMode.inAppBrowserView,
      )) {
        return true;
      }

      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      try {
        return await launchUrl(
          uri,
          mode: LaunchMode.externalApplication,
        );
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> NcupOpenExternal(Uri uri) async {
    try {
      return await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    } catch (error) {
      return false;
    }
  }

  void NcupHandleServerSavedata(String savedata) {
    print('onServerResponse savedata: $savedata');
    if(savedata=='false') {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute<Widget>(
          builder: (BuildContext context) =>
              AssetWebViewScreen(assetPath: 'assets/vacation_challenge.html',),
        ),
      );
    }
  }

  Color _parseHexColor(String hex) {
    String value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length == 6) {
      value = 'FF$value';
    }
    final intColor = int.tryParse(value, radix: 16) ?? 0xFF000000;
    return Color(intColor);
  }

  Future<void> _updateAppDataInLocalStorageFromProfile() async {
    final InAppWebViewController? controller = NcupWebViewController;
    if (controller == null) return;

    final String? token = _resolveTokenForShip();
    final Map<String, dynamic> map =
    NcupDeviceProfileInstance.NcupToMap(fcmToken: token);

    NcupLoggerService()
        .NcupLogInfo('updateAppDataFromProfile: ${jsonEncode(map)}');

    await NcupSaveJsonToLocalStorageAndPrefs(
      controller: controller,
      key: 'app_data',
      data: map,
    );
  }

  void _updateExtraDataFromServerPayload(Map<dynamic, dynamic> root) {
    try {
      final dynamic adataRaw = root['adata'];
      if (adataRaw is Map) {
        final Map adata = adataRaw;

        final dynamic buttonswlRaw = adata['buttonswl'];
        if (buttonswlRaw is List) {
          final List<String> list = buttonswlRaw
              .where((e) => e != null)
              .map((e) => e.toString().trim())
              .where((e) => e.isNotEmpty)
              .toList();
          setState(() {
            _buttonWhitelist = list;
          });
          NcupLoggerService()
              .NcupLogInfo('buttonswl updated: $_buttonWhitelist');
          _updateBackButtonVisibility();
        }

        // --------- fpscashier из adata → профиль → localStorage ---------
        if (adata.containsKey('fpscashier')) {
          final dynamic fpsRaw = adata['fpscashier'];
          bool? fpsValue;

          if (fpsRaw is bool) {
            fpsValue = fpsRaw;
          } else if (fpsRaw is num) {
            fpsValue = fpsRaw != 0;
          } else if (fpsRaw is String) {
            final String v = fpsRaw.toLowerCase().trim();
            if (v == 'true' || v == '1' || v == 'yes') fpsValue = true;
            if (v == 'false' || v == '0' || v == 'no') fpsValue = false;
          }

          if (fpsValue != null) {
            final bool old = NcupDeviceProfileInstance.safecasher;
            NcupDeviceProfileInstance.safecasher = fpsValue;
            NcupLoggerService().NcupLogInfo(
                'fpscashier updated from server payload: $fpsValue');

            _updateAppDataInLocalStorageFromProfile();

            // *** CHANGED: при переходе из false -> true можно (опционально)
            // сразу доустановить хуки на уже открытой странице
            if (!old && fpsValue && NcupWebViewController != null) {
              NcupLoggerService().NcupLogInfo(
                  'fpscashier switched to true, installing JS hooks now');
              _scheduleSafeInstall(NcupWebViewController!, label: 'parent');
            }
          }
        }
        // ----------------------------------------------------------------

        final dynamic savelsRaw = adata['savels'];
        if (savelsRaw is Map) {
          NcupDeviceProfileInstance.NcupSavels =
          Map<String, dynamic>.from(savelsRaw);
          NcupLoggerService().NcupLogInfo(
              'savels stored in profile: ${NcupDeviceProfileInstance.NcupSavels}');
          _updateAppDataInLocalStorageFromProfile();
        }
      }
    } catch (e, st) {
      NcupLoggerService()
          .NcupLogError('Error in _updateExtraDataFromServerPayload: $e\n$st');
    }
  }

  void _updateSafeAreaFromServerPayload(Map<dynamic, dynamic> root) {
    NcupLoggerService()
        .NcupLogInfo('SAFEAREA RAW PAYLOAD: ${jsonEncode(root)}');

    bool? safearea;
    String? bgLightHex;
    String? bgDarkHex;

    final dynamic content = root['content'];
    if (content is Map) {
      if (content['safearea'] != null) {
        final dynamic raw = content['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (content['safearea_color'] != null &&
          content['safearea_color'].toString().trim().isNotEmpty) {
        bgLightHex = content['safearea_color'].toString().trim();
        bgDarkHex = bgLightHex;
      }
    }

    final dynamic adata = root['adata'];
    if (adata is Map) {
      if (safearea == null && adata['safearea'] != null) {
        final dynamic raw = adata['safearea'];
        if (raw is bool) {
          safearea = raw;
        } else if (raw is String) {
          final String v = raw.toLowerCase().trim();
          if (v == 'true' || v == '1' || v == 'yes') safearea = true;
          if (v == 'false' || v == '0' || v == 'no') safearea = false;
        } else if (raw is num) {
          safearea = raw != 0;
        }
      }

      if (adata['bgsareaw'] != null &&
          adata['bgsareaw'].toString().trim().isNotEmpty) {
        bgLightHex = adata['bgsareaw'].toString().trim();
      }
      if (adata['bgsareab'] != null &&
          adata['bgsareab'].toString().trim().isNotEmpty) {
        bgDarkHex = adata['bgsareab'].toString().trim();
      }
    }

    if (safearea == null && root['safearea'] != null) {
      final dynamic raw = root['safearea'];
      if (raw is bool) {
        safearea = raw;
      } else if (raw is String) {
        final String v = raw.toLowerCase().trim();
        if (v == 'true' || v == '1' || v == 'yes') safearea = true;
        if (v == 'false' || v == '0' || v == 'no') safearea = false;
      } else if (raw is num) {
        safearea = raw != 0;
      }
    }

    NcupLoggerService().NcupLogInfo(
        'SAFEAREA PARSED: enabled=$safearea, light=$bgLightHex, dark=$bgDarkHex');

    if (safearea == null) {
      return;
    }

    final Brightness platformBrightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;

    String? chosenHex;
    if (platformBrightness == Brightness.light) {
      chosenHex = bgLightHex ?? bgDarkHex;
    } else {
      chosenHex = bgDarkHex ?? bgLightHex;
    }

    final bool enabled = safearea;
    Color background =
    enabled ? const Color(0xFF1A1A22) : const Color(0xFF000000);

    if (enabled && chosenHex != null && chosenHex.isNotEmpty) {
      background = _parseHexColor(chosenHex);
    }

    setState(() {
      _safeAreaEnabled = enabled;
      _safeAreaBackgroundColor = background;
      NcupDeviceProfileInstance.NcupSafeAreaEnabled = enabled;
      NcupDeviceProfileInstance.NcupSafeAreaColor =
      enabled ? (chosenHex ?? '#1A1A22') : '';
    });

    () async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setBool('safearea_enabled', enabled);
        await prefs.setString(
          'safearea_color',
          NcupDeviceProfileInstance.NcupSafeAreaColor ?? '',
        );
        NcupLoggerService().NcupLogInfo(
          'SafeArea saved to prefs: enabled=$enabled, color="${NcupDeviceProfileInstance.NcupSafeAreaColor}"',
        );
      } catch (e, st) {
        NcupLoggerService().NcupLogError(
            'Error saving SafeArea to prefs: $e\n$st');
      }
    }();

    NcupLoggerService().NcupLogInfo(
        'SAFEAREA STATE UPDATED: enabled=$_safeAreaEnabled, color=$_safeAreaBackgroundColor (brightness=$platformBrightness)');
  }

  bool _matchesButtonWhitelist(String url) {
    if (url.isEmpty) return false;
    if (_buttonWhitelist.isEmpty) return false;
    Uri? uri;
    try {
      uri = Uri.parse(url);
    } catch (_) {
      return false;
    }

    final String host = uri.host.toLowerCase();
    final String full = uri.toString();

    for (final String item in _buttonWhitelist) {
      final String trimmed = item.trim();
      if (trimmed.isEmpty) continue;

      if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
        if (full.startsWith(trimmed)) return true;
      } else {
        final String domain = trimmed.toLowerCase();
        if (host == domain || host.endsWith('.$domain')) return true;
      }
    }

    return false;
  }

  Future<void> _updateBackButtonVisibility() async {
    final String current = _currentUrl ?? NcupCurrentUrl;
    final bool shouldShow = _matchesButtonWhitelist(current);

    if (_backButtonHiddenAfterTap) {
      _backButtonHiddenAfterTap = false;
    }

    if (shouldShow != _showBackButton) {
      if (mounted) {
        setState(() {
          _showBackButton = shouldShow;
        });
      } else {
        _showBackButton = shouldShow;
      }
    }
  }

  Future<void> _handleBackButtonPressed() async {
    if (mounted) {
      setState(() {
        _backButtonHiddenAfterTap = true;
        _showBackButton = false;
      });
    } else {
      _backButtonHiddenAfterTap = true;
      _showBackButton = false;
    }

    if (_isPopupVisible) {
      await _handlePopupBackPressed();
      return;
    }

    if (NcupWebViewController == null) return;
    try {
      if (await NcupWebViewController!.canGoBack()) {
        await NcupWebViewController!.goBack();
      } else {
        await NcupWebViewController!.loadUrl(
          urlRequest: URLRequest(url: WebUri(NcupHomeUrl)),
        );
      }
    } catch (e, st) {
      NcupLoggerService()
          .NcupLogError('Error on back button pressed: $e\n$st');
    }
  }

  InAppWebViewSettings _mainWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: true,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  InAppWebViewSettings _popupWebViewSettings() {
    return InAppWebViewSettings(
      javaScriptEnabled: true,
      isInspectable: true,
      disableDefaultErrorPage: true,
      mediaPlaybackRequiresUserGesture: false,
      allowsInlineMediaPlayback: true,
      allowsPictureInPictureMediaPlayback: true,
      useOnDownloadStart: true,
      javaScriptCanOpenWindowsAutomatically: true,
      useShouldOverrideUrlLoading: true,
      supportMultipleWindows: true,
      transparentBackground: false,
      thirdPartyCookiesEnabled: true,
      sharedCookiesEnabled: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      cacheEnabled: true,
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      allowsBackForwardNavigationGestures: true,
    );
  }

  Future<void> _safeEvaluateJavascript(
      InAppWebViewController? controller, {
        required String source,
        String debugName = 'js',
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      await controller.evaluateJavascript(source: source);
    } catch (e) {
      print('WERLOG: safeEvaluateJavascript error [$debugName]: $e');
    }
  }

  Future<void> _installJsErrorLogger(InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installJsErrorLogger',
      source: r'''
        (function() {
          if (window.__ncupJsLoggerInstalled) return;
          window.__ncupJsLoggerInstalled = true;

          function serializeError(err) {
            try {
              if (!err) return null;
              var plain = {};
              Object.getOwnPropertyNames(err).forEach(function(key) {
                plain[key] = err[key];
              });
              return plain;
            } catch (_) {
              return { message: String(err) };
            }
          }

          window.onerror = function(message, source, lineno, colno, error) {
            try {
              var payload = {
                type: 'onerror',
                message: String(message || ''),
                source: String(source || ''),
                lineno: lineno || 0,
                colno: colno || 0,
                error: serializeError(error)
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger onerror inner fail', e);
            }
          };

          window.addEventListener('unhandledrejection', function(event) {
            try {
              var reason = event.reason;
              var payload = {
                type: 'unhandledrejection',
                reason: serializeError(reason) || { message: String(reason || '') }
              };
              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupJSLogger', payload);
              }
            } catch (e) {
              console.log('NcupJSLogger unhandledrejection inner fail', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installPostMessageBridge(
      InAppWebViewController controller, {
        required String label,
      }) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installPostMessageBridge-$label',
      source: '''
        (function() {
          if (window.__ncupPostMessageBridgeInstalled_$label) return;
          window.__ncupPostMessageBridgeInstalled_$label = true;

          window.addEventListener('message', function(event) {
            try {
              var dataRaw = event.data;
              var dataString;
              try {
                dataString = JSON.stringify(dataRaw);
              } catch (e) {
                dataString = String(dataRaw);
              }

              var payload = {
                label: '$label',
                origin: String(event.origin || ''),
                data: dataString,
                href: String(window.location.href || '')
              };

              console.log('[NCUP postMessage $label]', payload);

              if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                window.flutter_inappwebview.callHandler('NcupPostMessage', payload);
              }

              try {
                var parsed = dataRaw;
                if (typeof parsed === 'string') {
                  parsed = JSON.parse(parsed);
                }
                if (parsed && parsed.type === 'newTab' && parsed.url) {
                  if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                    window.flutter_inappwebview.callHandler('NcupCheckoutAction', parsed);
                  }
                }
              } catch (_) {}
            } catch (e) {
              console.log('NcupPostMessage bridge error', e);
            }
          });
        })();
      ''',
    );
  }

  Future<void> _installCheckoutInterceptor(
      InAppWebViewController controller,
      ) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installCheckoutInterceptor',
      source: r'''
        (function() {
          if (window.__ncupCheckoutInterceptorInstalled) return;
          window.__ncupCheckoutInterceptorInstalled = true;

          function sendToFlutter(data) {
            try {
              if (!data || typeof data !== 'object') return;
              if (data.type === 'newTab' && data.url) {
                console.log('[NCUP checkout interceptor] newTab:', data.url);
                if (
                  window.flutter_inappwebview &&
                  window.flutter_inappwebview.callHandler
                ) {
                  window.flutter_inappwebview.callHandler(
                    'NcupCheckoutAction',
                    data
                  );
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] send error', e);
            }
          }

          function tryParseMaybeJson(value) {
            try {
              if (!value) return null;
              if (typeof value === 'object') {
                return value;
              }
              if (typeof value === 'string') {
                return JSON.parse(value);
              }
              return null;
            } catch (e) {
              return null;
            }
          }

          function tryHandlePayload(payload) {
            try {
              var data = tryParseMaybeJson(payload);
              if (!data) return;

              if (Array.isArray(data)) {
                data.forEach(function(item) {
                  if (item && item.type === 'newTab' && item.url) {
                    sendToFlutter(item);
                  }
                });
                return;
              }

              if (data.type === 'newTab' && data.url) {
                sendToFlutter(data);
                return;
              }

              if (data.savedata) {
                var saved = tryParseMaybeJson(data.savedata);
                if (saved && saved.type === 'newTab' && saved.url) {
                  sendToFlutter(saved);
                  return;
                }
              }

              if (data.data) {
                var nested = tryParseMaybeJson(data.data);
                if (nested && nested.type === 'newTab' && nested.url) {
                  sendToFlutter(nested);
                  return;
                }
              }

              if (data.content) {
                var content = tryParseMaybeJson(data.content);
                if (content && content.type === 'newTab' && content.url) {
                  sendToFlutter(content);
                  return;
                }
              }
            } catch (e) {
              console.log('[NCUP checkout interceptor] handle error', e);
            }
          }

          var originalFetch = window.fetch;
          if (originalFetch) {
            window.fetch = function() {
              return originalFetch.apply(this, arguments).then(function(response) {
                try {
                  var cloned = response.clone();
                  cloned.text().then(function(text) {
                    tryHandlePayload(text);
                  }).catch(function() {});
                } catch (e) {}
                return response;
              });
            };
          }

          var OriginalXHR = window.XMLHttpRequest;
          if (OriginalXHR) {
            window.XMLHttpRequest = function() {
              var xhr = new OriginalXHR();
              var originalOpen = xhr.open;
              var originalSend = xhr.send;

              xhr.open = function() {
                return originalOpen.apply(xhr, arguments);
              };

              xhr.send = function() {
                xhr.addEventListener('load', function() {
                  try {
                    tryHandlePayload(xhr.responseText);
                  } catch (e) {}
                });
                return originalSend.apply(xhr, arguments);
              };

              return xhr;
            };
          }

          var originalOpen = window.open;
          window.open = function(url, target, features) {
            try {
              console.log('[NCUP window.open intercepted]', url, target, features);
            } catch (e) {}

            if (originalOpen) {
              return originalOpen.apply(window, arguments);
            }
            return null;
          };
        })();
      ''',
    );
  }

  Future<void> _installLocalStorageHook(
      InAppWebViewController controller) async {
    await _safeEvaluateJavascript(
      controller,
      debugName: 'installLocalStorageHook',
      source: r'''
        (function() {
          if (window.__ncupLocalStorageHookInstalled) return;
          window.__ncupLocalStorageHookInstalled = true;

          try {
            var originalSetItem = window.localStorage.setItem;
            window.localStorage.setItem = function(key, value) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler('NcupLocalStorageSetItem', {
                    key: String(key),
                    value: String(value)
                  });
                }
              } catch (e) {
                console.log('Ncup localStorage hook error', e);
              }
              return originalSetItem.apply(this, arguments);
            };
          } catch (e) {
            console.log('Ncup localStorage hook init error', e);
          }
        })();
      ''',
    );
  }

  Future<void> _safeInstallAll(
      InAppWebViewController? controller, {
        required String label,
      }) async {
    if (controller == null) return;
    if (!mounted) return;

    // *** CHANGED: хуки ставим только если с сервера пришёл fpscashier=true
    if (!NcupDeviceProfileInstance.safecasher) {
      print('WERLOG: safeInstallAll skipped ($label) because fpscashier=false');
      return;
    }

    try {
      await Future<void>.delayed(
        label == 'popup'
            ? const Duration(milliseconds: 550)
            : const Duration(milliseconds: 250),
      );
      if (!mounted) return;
      await _installJsErrorLogger(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installPostMessageBridge(controller, label: label);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installCheckoutInterceptor(controller);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!mounted) return;
      await _installLocalStorageHook(controller);
    } catch (e) {
      print('WERLOG: safeInstallAll error label=$label error=$e');
    }
  }

  void _scheduleSafeInstall(
      InAppWebViewController controller, {
        required String label,
      }) {
    if (label == 'popup') {
      _popupInstallTimer?.cancel();
      _popupInstallTimer =
          Timer(const Duration(milliseconds: 450), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    } else {
      _parentInstallTimer?.cancel();
      _parentInstallTimer =
          Timer(const Duration(milliseconds: 250), () async {
            if (!mounted) return;
            await _safeInstallAll(controller, label: label);
          });
    }
  }

  Map<String, dynamic>? _tryDecodeMap(dynamic value) {
    try {
      if (value == null) return null;
      if (value is Map) {
        return Map<String, dynamic>.from(value);
      }
      if (value is String) {
        final String trimmed = value.trim();
        if (trimmed.isEmpty) return null;
        final dynamic decoded = jsonDecode(trimmed);
        if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _openExternalForJsonNewTab(Uri uri) async {
    if (_isAboutBlankUri(uri)) return false;

    final String url = uri.toString();

    if (_handledNewTabUrls.contains(url)) {
      print('WERLOG: duplicate JSON newTab ignored url=$url');
      return true;
    }

    _handledNewTabUrls.add(url);

    if (_isOpeningExternalNewTab) {
      print('WERLOG: external newTab already opening, ignored url=$url');
      return false;
    }

    _isOpeningExternalNewTab = true;

    try {
      final bool launched = await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
      print('WERLOG: JSON newTab external launched=$launched url=$url');
      return launched;
    } catch (e) {
      print('WERLOG: JSON newTab external error=$e url=$url');
      return false;
    } finally {
      Future<void>.delayed(const Duration(seconds: 2), () {
        _isOpeningExternalNewTab = false;
      });
    }
  }

  Future<bool> _handleCheckoutAction(dynamic rawPayload) async {
    try {
      Map<String, dynamic>? data = _tryDecodeMap(rawPayload);
      if (data == null) return false;

      if (data.containsKey('savedata')) {
        final Map<String, dynamic>? savedataMap =
        _tryDecodeMap(data['savedata']);
        if (savedataMap != null) {
          data = savedataMap;
        }
      }

      if (data.containsKey('data')) {
        final Map<String, dynamic>? dataMap = _tryDecodeMap(data['data']);
        if (dataMap != null &&
            dataMap['type']?.toString() == 'newTab' &&
            (dataMap['url']?.toString() ?? '').isNotEmpty) {
          data = dataMap;
        }
      }

      if (data.containsKey('content')) {
        final Map<String, dynamic>? contentMap =
        _tryDecodeMap(data['content']);
        if (contentMap != null &&
            contentMap['type']?.toString() == 'newTab' &&
            (contentMap['url']?.toString() ?? '').isNotEmpty) {
          data = contentMap;
        }
      }

      final String type = data['type']?.toString() ?? '';
      final String url = data['url']?.toString() ?? '';

      if (type == 'newTab' && url.isNotEmpty) {
        final Uri? uri = Uri.tryParse(url);
        if (uri == null || _isAboutBlankUri(uri)) {
          print('WERLOG: invalid JSON newTab uri=$url');
          return false;
        }

        print('WERLOG: handle JSON newTab url=$url');
        await _openExternalForJsonNewTab(uri);
        return true;
      }

      return false;
    } catch (e) {
      print('WERLOG: handleCheckoutAction error: $e');
      return false;
    }
  }

  Future<bool> _onCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction request,
      ) async {
    final Uri? ncupUri = request.request.url;
    final String urlString = ncupUri?.toString() ?? '';

    print(
      'WERLOG: MAIN onCreateWindow '
          'windowId=${request.windowId} '
          'url=$urlString '
          'isDialog=${request.isDialog} '
          'hasGesture=${request.hasGesture}',
    );

    if (ncupUri != null) {
      _currentUrl = ncupUri.toString();
      await _updateBackButtonVisibility();

      if (_isGoogleUrl(ncupUri)) {}

      if (NcupIsBankScheme(ncupUri) ||
          ((ncupUri.scheme == 'http' || ncupUri.scheme == 'https') &&
              NcupIsBankDomain(ncupUri))) {
        await NcupOpenBank(ncupUri);
        return false;
      }

      if (NcupIsBareEmail(ncupUri)) {
        final Uri ncupMailto = NcupToMailto(ncupUri);
        await NcupOpenMailExternal(ncupMailto);
        return false;
      }

      final String ncupScheme = ncupUri.scheme.toLowerCase();

      if (ncupScheme == 'mailto') {
        await NcupOpenMailExternal(ncupUri);
        return false;
      }

      if (ncupScheme == 'tel') {
        await launchUrl(ncupUri, mode: LaunchMode.externalApplication);
        return false;
      }

      final String host = ncupUri.host.toLowerCase();
      final bool ncupIsSocial = host.endsWith('facebook.com') ||
          host.endsWith('instagram.com') ||
          host.endsWith('twitter.com') ||
          host.endsWith('x.com');

      if (ncupIsSocial) {
        await NcupOpenExternal(ncupUri);
        return false;
      }

      if (NcupIsPlatformLink(ncupUri)) {
        final Uri ncupWebUri = NcupHttpizePlatformUri(ncupUri);
        await NcupOpenExternal(ncupWebUri);
        return false;
      }
    }

    if (!mounted) return false;

    setState(() {
      _popupCreateAction = request;
      _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
          ? urlString
          : null;
      _popupCurrentUrl = _popupUrl;
      _isPopupVisible = true;
      _popupCanGoBack = false;
    });

    return true;
  }

  Future<bool> _onPopupCreateWindowHandler(
      InAppWebViewController controller,
      CreateWindowAction createWindowAction,
      ) async {
    final Uri? uri = createWindowAction.request.url;
    final String urlString = uri?.toString() ?? '';

    print(
      'WERLOG: POPUP onCreateWindow '
          'windowId=${createWindowAction.windowId} '
          'url=$urlString',
    );

    if (!mounted) return false;

    if (createWindowAction.windowId != null) {
      setState(() {
        _popupCreateAction = createWindowAction;
        _popupUrl = urlString.isNotEmpty && !_isAboutBlankUrl(urlString)
            ? urlString
            : _popupUrl;
        _popupCurrentUrl = _popupUrl;
        _isPopupVisible = true;
      });
      return true;
    }

    if (urlString.isNotEmpty && !_isAboutBlankUrl(urlString)) {
      try {
        await controller.loadUrl(
          urlRequest: URLRequest(url: WebUri(urlString)),
        );
      } catch (e) {
        print('WERLOG: popup inner window.open load error: $e url=$urlString');
      }
    }

    return false;
  }

  void _closePopup() {
    setState(() {
      _isPopupVisible = false;
      _popupUrl = null;
      _popupCurrentUrl = null;
      _popupCreateAction = null;
      _popupCanGoBack = false;
      NcupPopupWebViewController = null;
    });
  }

  Future<void> _closePopupAndNotifyParent({
    String reason = 'closed_by_user',
  }) async {
    try {
      await NcupWebViewController?.evaluateJavascript(
        source: '''
          try {
            window.dispatchEvent(new MessageEvent('message', {
              data: ${jsonEncode({
          'type': 'ncup_popup_closed',
          'reason': reason,
        })},
              origin: window.location.origin
            }));
          } catch(e) {
            console.log('ncup popup close notify failed', e);
          }
        ''',
      );
    } catch (e) {
      print('WERLOG: closePopup notify parent error: $e');
    }
    _closePopup();
  }

  Future<void> _refreshPopupCanGoBack() async {
    final InAppWebViewController? c = NcupPopupWebViewController;
    if (c == null) {
      if (_popupCanGoBack && mounted) {
        setState(() {
          _popupCanGoBack = false;
        });
      }
      return;
    }
    try {
      final bool can = await c.canGoBack();
      if (!mounted) return;
      if (can != _popupCanGoBack) {
        setState(() {
          _popupCanGoBack = can;
        });
      }
    } catch (e) {
      print('WERLOG: _refreshPopupCanGoBack error: $e');
    }
  }

  Future<void> _handlePopupBackPressed() async {
    final InAppWebViewController? c = NcupPopupWebViewController;
    if (c == null) {
      _closePopup();
      return;
    }
    try {
      if (await c.canGoBack()) {
        await c.goBack();
        Future<void>.delayed(const Duration(milliseconds: 300), () {
          _refreshPopupCanGoBack();
        });
      } else {
        await _closePopupAndNotifyParent(reason: 'popup_back_no_history');
      }
    } catch (e) {
      print('WERLOG: _handlePopupBackPressed error: $e');
      _closePopup();
    }
  }

  bool _isCurrentPopupInWhitelist() {
    if (!_isPopupVisible) return false;
    final String popupUrlForCheck = _popupCurrentUrl ?? _popupUrl ?? '';
    return _matchesButtonWhitelist(popupUrlForCheck);
  }

  Widget _buildPopupWebView() {
    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool showBackArrow = !popupInWhitelist && _popupCanGoBack;
    final bool showCloseButton = !popupInWhitelist && !_popupCanGoBack;

    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.96),
        child: Column(
          children: [
            if (!popupInWhitelist) ...[
              SafeArea(
                bottom: false,
                child: Container(
                  color: Colors.black,
                  child: Row(
                    children: [
                      if (showBackArrow)
                        IconButton(
                          icon: const Icon(Icons.arrow_back,
                              color: Colors.white),
                          onPressed: _handlePopupBackPressed,
                        )
                      else if (showCloseButton)
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () {
                            _closePopupAndNotifyParent(reason: 'close_button');
                          },
                        ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(height: 1, color: Colors.white24),
            ],
            Expanded(
              child: InAppWebView(
                windowId: _popupCreateAction?.windowId,
                initialUrlRequest:
                (_popupCreateAction?.windowId == null) && _popupUrl != null
                    ? URLRequest(url: WebUri(_popupUrl!))
                    : null,
                initialSettings: _popupWebViewSettings(),
                onWebViewCreated:
                    (InAppWebViewController popupController) async {
                  NcupPopupWebViewController = popupController;

                  print(
                    'WERLOG: popup created '
                        'windowId=${_popupCreateAction?.windowId} '
                        'initialUrl=${_popupUrl ?? _popupCreateAction?.request.url}',
                  );

                  final String popupInitUrl =
                      _popupUrl ?? _popupCreateAction?.request.url?.toString() ?? '';
                  if (popupInitUrl.isNotEmpty) {
                    final Uri? popupUri = Uri.tryParse(popupInitUrl);
                    if (popupUri != null && _isGoogleUrl(popupUri)) {
                      await _applyGoogleUserAgentForPopup();
                    }
                  }

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupLocalStorageSetItem',
                    callback: (List<dynamic> args) async {
                      try {
                        if (args.isEmpty) return null;
                        final dynamic raw = args.first;
                        if (raw is Map) {
                          final String key = raw['key']?.toString() ?? '';
                          final String value = raw['value']?.toString() ?? '';
                          if (key.isNotEmpty) {
                            final SharedPreferences prefs =
                            await SharedPreferences.getInstance();
                            await prefs.setString(key, value);
                            NcupLoggerService().NcupLogInfo(
                                'NcupLocalStorageSetItem (popup): saved key="$key" len=${value.length}');
                          }
                        }
                      } catch (e, st) {
                        NcupLoggerService().NcupLogError(
                            'NcupLocalStorageSetItem popup handler error: $e\n$st');
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupCheckoutAction',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupCheckoutAction args=$args');
                      if (args.isNotEmpty) {
                        await _handleCheckoutAction(args.first);
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupPostMessage',
                    callback: (List<dynamic> args) async {
                      print('WERLOG: POPUP NcupPostMessage args=$args');
                      if (args.isNotEmpty) {
                        final dynamic first = args.first;
                        if (first is Map && first['data'] != null) {
                          await _handleCheckoutAction(first['data']);
                        } else {
                          await _handleCheckoutAction(first);
                        }
                      }
                      return null;
                    },
                  );

                  popupController.addJavaScriptHandler(
                    handlerName: 'NcupJSLogger',
                    callback: (List<dynamic> args) {
                      print('WERLOG: POPUP JS error payload: $args');
                      return null;
                    },
                  );
                },
                onPermissionRequest: (controller, request) async {
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },
                onLoadStart: (controller, uri) async {
                  print('WERLOG: popup onLoadStart url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (_isGoogleUrl(uri)) {
                      await _applyGoogleUserAgentForPopup();
                    }

                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onLoadStop: (controller, uri) async {
                  print('WERLOG: popup onLoadStop url=$uri');
                  if (uri != null && !_isAboutBlankUri(uri)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = uri.toString();
                      });
                    }
                  }
                  if (!_isAboutBlankUri(uri)) {
                    _scheduleSafeInstall(controller, label: 'popup');
                  }
                  _refreshPopupCanGoBack();
                },
                onUpdateVisitedHistory: (controller, url, isReload) async {
                  if (url != null && !_isAboutBlankUri(url)) {
                    if (mounted) {
                      setState(() {
                        _popupCurrentUrl = url.toString();
                        if (_backButtonHiddenAfterTap) {
                          _backButtonHiddenAfterTap = false;
                        }
                      });
                    }
                  }
                  _refreshPopupCanGoBack();
                },
                onCreateWindow: _onPopupCreateWindowHandler,
                shouldOverrideUrlLoading: (
                    InAppWebViewController controller,
                    NavigationAction navigationAction,
                    ) async {
                  final Uri? uri = navigationAction.request.url;
                  if (uri == null) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isAboutBlankUri(uri)) {
                    return NavigationActionPolicy.ALLOW;
                  }

                  if (_isGoogleUrl(uri)) {
                    await _applyGoogleUserAgentForPopup();
                    return NavigationActionPolicy.ALLOW;
                  }

                  final String scheme = uri.scheme.toLowerCase();

                  if (NcupIsBareEmail(uri)) {
                    final Uri mailto = NcupToMailto(uri);
                    await NcupOpenMailExternal(mailto);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'mailto') {
                    await NcupOpenMailExternal(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme == 'tel') {
                    await launchUrl(uri,
                        mode: LaunchMode.externalApplication);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (NcupIsBankScheme(uri) ||
                      ((scheme == 'http' || scheme == 'https') &&
                          NcupIsBankDomain(uri))) {
                    await NcupOpenBank(uri);
                    return NavigationActionPolicy.CANCEL;
                  }

                  if (scheme != 'http' && scheme != 'https') {
                    print(
                      'WERLOG: popup blocked non-http/https scheme=$scheme url=$uri',
                    );
                    return NavigationActionPolicy.CANCEL;
                  }

                  return NavigationActionPolicy.ALLOW;
                },
                onCloseWindow: (controller) {
                  print('WERLOG: popup onCloseWindow');
                  _closePopup();
                },
                onLoadError: (controller, uri, code, message) async {
                  print(
                    'WERLOG: popup onLoadError url=$uri code=$code msg=$message',
                  );
                },
                onReceivedError: (controller, request, error) async {
                  print(
                    'WERLOG: popup onReceivedError '
                        'url=${request.url} '
                        'type=${error.type} '
                        'desc=${error.description}',
                  );
                },
                onReceivedHttpError:
                    (controller, request, errorResponse) async {
                  print(
                    'WERLOG: popup onReceivedHttpError '
                        'url=${request.url} '
                        'status=${errorResponse.statusCode} '
                        'reason=${errorResponse.reasonPhrase}',
                  );
                },
                onConsoleMessage: (controller, consoleMessage) {
                  print(
                    'WERLOG: popup console: '
                        '${consoleMessage.messageLevel} ${consoleMessage.message}',
                  );
                },
                onDownloadStartRequest: (controller, req) async {
                  print(
                      'WERLOG: popup download for url=${req.url}, opening external');
                  await NcupOpenExternal(req.url);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    NcupBindNotificationTap();

    final Color bgColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget webView = Stack(
      children: <Widget>[
        if (NcupCoverVisible)
          const Center(child: PalmGrowLoader())
        else
          Container(
            color: bgColor,
            child: Stack(
              children: <Widget>[
                InAppWebView(
                  key: ValueKey<int>(NcupWebViewKeyCounter),
                  initialSettings: _mainWebViewSettings(),
                  initialUrlRequest: URLRequest(
                    url: WebUri(NcupHomeUrl),
                  ),
                  onWebViewCreated:
                      (InAppWebViewController controller) async {
                    NcupWebViewController = controller;
                    _currentUrl = NcupHomeUrl;

                    NcupBosunInstance ??= NcupBosunViewModel(
                      NcupDeviceProfileInstance: NcupDeviceProfileInstance,
                      NcupAnalyticsSpyInstance: NcupAnalyticsSpyInstance,
                    );

                    NcupCourier ??= NcupCourierService(
                      NcupBosun: NcupBosunInstance!,
                      NcupGetWebViewController: () => NcupWebViewController,
                    );

                    try {
                      final ua = await controller.evaluateJavascript(
                        source: "navigator.userAgent",
                      );
                      if (ua is String && ua.trim().isNotEmpty) {
                        _baseUserAgent = ua.trim();
                        _currentUserAgent = _baseUserAgent!;
                        NcupDeviceProfileInstance.NcupBaseUserAgent =
                            _baseUserAgent;
                        NcupLoggerService().NcupLogInfo(
                            'Initial WebView User-Agent: $_baseUserAgent');
                        print(
                            '[UA] INITIAL WEBVIEW USER AGENT: $_baseUserAgent');
                      }
                    } catch (e) {
                      NcupLoggerService().NcupLogWarn(
                          'Failed to read navigator.userAgent on create: $e');
                    }

                    await _applyNormalUserAgentIfNeeded();

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupLocalStorageSetItem',
                      callback: (List<dynamic> args) async {
                        try {
                          if (args.isEmpty) return null;
                          final dynamic raw = args.first;
                          if (raw is Map) {
                            final String key =
                                raw['key']?.toString() ?? '';
                            final String value =
                                raw['value']?.toString() ?? '';
                            if (key.isNotEmpty) {
                              final SharedPreferences prefs =
                              await SharedPreferences.getInstance();
                              await prefs.setString(key, value);
                              NcupLoggerService().NcupLogInfo(
                                  'NcupLocalStorageSetItem (main): saved key="$key" len=${value.length}');
                            }
                          }
                        } catch (e, st) {
                          NcupLoggerService().NcupLogError(
                              'NcupLocalStorageSetItem main handler error: $e\n$st');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'onServerResponse',
                      callback: (List<dynamic> args) async {
                        if (args.isEmpty) return null;

                        print("Get Data server $args");

                        try {
                          dynamic first = args[0];

                          if (first is List && first.isNotEmpty) {
                            first = first.first;
                          }

                          final bool handled =
                          await _handleCheckoutAction(first);
                          if (handled) {}

                          if (first is Map) {
                            final Map<dynamic, dynamic> root = first;

                            if (root['savedata'] != null) {
                              NcupHandleServerSavedata(
                                  root['savedata'].toString());
                              await _handleCheckoutAction(root['savedata']);
                            }

                            _updateExtraDataFromServerPayload(root);
                            _updateSafeAreaFromServerPayload(root);
                            await _updateUserAgentFromServerPayload(root);

                            await _applyNormalUserAgentIfNeeded();

                            try {
                              if (!_loadedJsExecutedOnce) {
                                final dynamic adataRaw = root['adata'];
                                if (adataRaw is Map) {
                                  final Map adata = adataRaw;
                                  final dynamic loadedJsRaw =
                                  adata['loadedjs'];
                                  if (loadedJsRaw != null) {
                                    final String loadedJs =
                                    loadedJsRaw.toString().trim();
                                    if (loadedJs.isNotEmpty) {
                                      _pendingLoadedJs = loadedJs;
                                      NcupLoggerService().NcupLogInfo(
                                        'loadedjs received, will execute ONCE after 6 seconds',
                                      );

                                      Future<void>.delayed(
                                        const Duration(seconds: 6),
                                            () async {
                                          if (!mounted) return;
                                          if (_loadedJsExecutedOnce) {
                                            NcupLoggerService()
                                                .NcupLogInfo(
                                                'Skipping loadedjs: already executed once');
                                            return;
                                          }
                                          if (NcupWebViewController ==
                                              null) {
                                            NcupLoggerService()
                                                .NcupLogWarn(
                                                'Skipping loadedjs execution: controller is null');
                                            return;
                                          }
                                          final String? jsToRun =
                                              _pendingLoadedJs;
                                          if (jsToRun == null ||
                                              jsToRun.isEmpty) {
                                            return;
                                          }
                                          NcupLoggerService().NcupLogInfo(
                                              'Executing loadedjs from server payload (ONCE, delayed 6s)');
                                          try {
                                            await NcupWebViewController
                                                ?.evaluateJavascript(
                                              source: jsToRun,
                                            );
                                            _loadedJsExecutedOnce = true;
                                          } catch (e, st) {
                                            NcupLoggerService().NcupLogError(
                                                'Error executing delayed loadedjs: $e\n$st');
                                          }
                                        },
                                      );
                                    }
                                  }
                                }
                              } else {
                                NcupLoggerService().NcupLogInfo(
                                    'loadedjs ignored: already executed once earlier');
                              }
                            } catch (e, st) {
                              NcupLoggerService().NcupLogError(
                                  'Error scheduling loadedjs: $e\n$st');
                            }
                          }
                        } catch (e, st) {
                          print('onServerResponse error: $e\n$st');
                        }

                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupCheckoutAction',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupCheckoutAction args=$args');
                          if (args.isNotEmpty) {
                            await _handleCheckoutAction(args.first);
                          }
                        } catch (e) {
                          print(
                              'WERLOG: MAIN NcupCheckoutAction error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupJSLogger',
                      callback: (List<dynamic> args) {
                        try {
                          final dynamic payload =
                          args.isNotEmpty ? args.first : null;
                          print('WERLOG: MAIN JS error payload: $payload');
                        } catch (e) {
                          print('WERLOG: NcupJSLogger handler error: $e');
                        }
                        return null;
                      },
                    );

                    controller.addJavaScriptHandler(
                      handlerName: 'NcupPostMessage',
                      callback: (List<dynamic> args) async {
                        try {
                          print('WERLOG: MAIN NcupPostMessage args=$args');
                          if (args.isNotEmpty) {
                            final dynamic first = args.first;
                            if (first is Map && first['data'] != null) {
                              await _handleCheckoutAction(first['data']);
                            } else {
                              await _handleCheckoutAction(first);
                            }
                          }
                        } catch (e) {
                          print(
                              'WERLOG: NcupPostMessage handler error: $e');
                        }
                        return null;
                      },
                    );
                  },
                  onPermissionRequest: (controller, request) async {
                    return PermissionResponse(
                      resources: request.resources,
                      action: PermissionResponseAction.GRANT,
                    );
                  },
                  onLoadStart:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      NcupStartLoadTimestamp =
                          DateTime.now().millisecondsSinceEpoch;
                    });

                    final Uri? ncupViewUri = uri;
                    if (ncupViewUri != null) {
                      _currentUrl = ncupViewUri.toString();

                      await _switchUserAgentForUrl(ncupViewUri);

                      await _updateBackButtonVisibility();

                      if (NcupIsBareEmail(ncupViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        final Uri ncupMailto = NcupToMailto(ncupViewUri);
                        await NcupOpenMailExternal(ncupMailto);
                        return;
                      }

                      final String ncupScheme =
                      ncupViewUri.scheme.toLowerCase();

                      if (ncupScheme == 'mailto') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await NcupOpenMailExternal(ncupViewUri);
                        return;
                      }

                      if (NcupIsBankScheme(ncupViewUri)) {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                        await NcupOpenBank(ncupViewUri);
                        return;
                      }

                      if (ncupScheme != 'http' && ncupScheme != 'https') {
                        try {
                          await controller.stopLoading();
                        } catch (_) {}
                      }
                    }
                  },
                  onLoadError: (
                      InAppWebViewController controller,
                      Uri? uri,
                      int code,
                      String message,
                      ) async {
                    final int ncupNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String ncupEvent =
                        'InAppWebViewError(code=$code, message=$message)';

                    await NcupPostStat(
                      event: ncupEvent,
                      timeStart: ncupNow,
                      timeFinish: ncupNow,
                      url: uri?.toString() ?? '',
                      appSid: NcupAnalyticsSpyInstance.NcupAppsFlyerUid,
                      firstPageLoadTs: NcupFirstPageTimestamp,
                    );
                  },
                  onReceivedError: (
                      InAppWebViewController controller,
                      WebResourceRequest request,
                      WebResourceError error,
                      ) async {
                    final int ncupNow =
                        DateTime.now().millisecondsSinceEpoch;
                    final String ncupDescription =
                    (error.description ?? '').toString();
                    final String ncupEvent =
                        'WebResourceError(code=$error, message=$ncupDescription)';

                    await NcupPostStat(
                      event: ncupEvent,
                      timeStart: ncupNow,
                      timeFinish: ncupNow,
                      url: request.url?.toString() ?? '',
                      appSid: NcupAnalyticsSpyInstance.NcupAppsFlyerUid,
                      firstPageLoadTs: NcupFirstPageTimestamp,
                    );
                  },
                  onLoadStop:
                      (InAppWebViewController controller, Uri? uri) async {
                    setState(() {
                      NcupCurrentUrl = uri.toString();
                      _currentUrl = NcupCurrentUrl;
                    });

                    if (uri != null) {
                      await _switchUserAgentForUrl(uri);
                    }

                    if (!_isAboutBlankUri(uri)) {
                      _scheduleSafeInstall(controller, label: 'parent');
                    }

                    await debugPrintCurrentUserAgent();

                    await _sendAllDataToPageTwice();
                    await _updateBackButtonVisibility();

                    Future<void>.delayed(
                      const Duration(seconds: 20),
                          () {
                        NcupSendLoadedOnce(
                          url: NcupCurrentUrl.toString(),
                          timestart: NcupStartLoadTimestamp,
                        );
                      },
                    );
                  },
                  onUpdateVisitedHistory:
                      (controller, url, isReload) async {
                    if (url != null && !_isAboutBlankUri(url)) {
                      _currentUrl = url.toString();
                      await _updateBackButtonVisibility();
                      await _switchUserAgentForUrl(url);
                    }
                  },
                  shouldOverrideUrlLoading:
                      (InAppWebViewController controller,
                      NavigationAction action) async {
                    final Uri? ncupUri = action.request.url;
                    if (ncupUri == null) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    _currentUrl = ncupUri.toString();
                    await _updateBackButtonVisibility();

                    if (_isAboutBlankUri(ncupUri)) {
                      return NavigationActionPolicy.ALLOW;
                    }

                    if (_isGoogleUrl(ncupUri)) {
                      _isCurrentlyOnGoogle = true;
                      await _applyGoogleUserAgent();
                      return NavigationActionPolicy.ALLOW;
                    } else {
                      if (_isCurrentlyOnGoogle) {
                        _isCurrentlyOnGoogle = false;
                      }
                      await _applyNormalUserAgentIfNeeded();
                    }

                    if (NcupIsBareEmail(ncupUri)) {
                      final Uri ncupMailto = NcupToMailto(ncupUri);
                      await NcupOpenMailExternal(ncupMailto);
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String ncupScheme = ncupUri.scheme.toLowerCase();

                    if (ncupScheme == 'mailto') {
                      await NcupOpenMailExternal(ncupUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (NcupIsBankScheme(ncupUri)) {
                      await NcupOpenBank(ncupUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if ((ncupScheme == 'http' || ncupScheme == 'https') &&
                        NcupIsBankDomain(ncupUri)) {
                      await NcupOpenBank(ncupUri);

                      if (_isAdobeRedirect(ncupUri)) {
                        if (context.mounted) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AdobeRedirectScreen(uri: ncupUri),
                            ),
                          );
                        }
                        return NavigationActionPolicy.CANCEL;
                      }
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (ncupScheme == 'tel') {
                      await launchUrl(
                        ncupUri,
                        mode: LaunchMode.externalApplication,
                      );
                      return NavigationActionPolicy.CANCEL;
                    }

                    final String host = ncupUri.host.toLowerCase();
                    final bool ncupIsSocial =
                        host.endsWith('facebook.com') ||
                            host.endsWith('instagram.com') ||
                            host.endsWith('twitter.com') ||
                            host.endsWith('x.com');

                    if (ncupIsSocial) {
                      await NcupOpenExternal(ncupUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (NcupIsPlatformLink(ncupUri)) {
                      final Uri ncupWebUri =
                      NcupHttpizePlatformUri(ncupUri);
                      await NcupOpenExternal(ncupWebUri);
                      return NavigationActionPolicy.CANCEL;
                    }

                    if (ncupScheme != 'http' && ncupScheme != 'https') {
                      return NavigationActionPolicy.CANCEL;
                    }

                    return NavigationActionPolicy.ALLOW;
                  },
                  onCreateWindow: _onCreateWindowHandler,
                  onCloseWindow: (controller) {
                    print('WERLOG: MAIN onCloseWindow');
                  },
                  onDownloadStartRequest: (
                      InAppWebViewController controller,
                      DownloadStartRequest req,
                      ) async {
                    await NcupOpenExternal(req.url);
                  },
                  onConsoleMessage: (controller, consoleMessage) {
                    print(
                      'WERLOG: MAIN console: '
                          '${consoleMessage.messageLevel} ${consoleMessage.message}',
                    );
                  },
                ),
                Visibility(
                  visible: !NcupVeilVisible,
                  child: const Center(child: PalmGrowLoader()),
                ),
                if (_isPopupVisible &&
                    (_popupUrl != null || _popupCreateAction != null))
                  _buildPopupWebView(),
              ],
            ),
          ),
      ],
    );

    final bool popupInWhitelist = _isCurrentPopupInWhitelist();

    final bool whitelistMatch =
        (!_isPopupVisible && _showBackButton) || popupInWhitelist;

    final bool shouldShowTopBackBar =
        whitelistMatch && !_backButtonHiddenAfterTap;

    final Color topBarColor =
    _safeAreaEnabled ? _safeAreaBackgroundColor : Colors.black;

    final Widget topBackBar = shouldShowTopBackBar
        ? Container(
      color: topBarColor,
      padding: const EdgeInsets.only(left: 4, right: 4),
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBackButtonPressed,
          ),
        ],
      ),
    )
        : const SizedBox.shrink();

    final Widget fullScreen = Column(
      children: [
        topBackBar,
        Expanded(child: webView),
      ],
    );

    final Widget body = _safeAreaEnabled
        ? SafeArea(
      child: fullScreen,
    )
        : fullScreen;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: bgColor,
        body: SizedBox.expand(
          child: ColoredBox(
            color: bgColor,
            child: body,
          ),
        ),
      ),
    );
  }

  bool _isAdobeRedirect(Uri uri) {
    final String host = uri.host.toLowerCase();
    return host == 'c00.adobe.com';
  }
}

// ---------------------- Экран для c00.adobe.com ----------------------

class AdobeRedirectScreen extends StatelessWidget {
  final Uri uri;

  const AdobeRedirectScreen({super.key, required this.uri});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF111111),
      body: Padding(
        padding: EdgeInsets.all(20),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                "Go to the App Store and download the app.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                ),
              ),
              SizedBox(height: 24),
              SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// main()
// ============================================================================

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(NcupFcmBackgroundHandler);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }

  tz_data.initializeTimeZones();

  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: NcupHall(),
    ),
  );
}