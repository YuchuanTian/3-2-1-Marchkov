import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';

class AuthService extends ChangeNotifier {
  User? _user;
  String _loginResponse = '';
  final http.Client _client = http.Client();
  String _password = '';
  PersistCookieJar? _cookieJar; // 改为可空类型

  AuthService() {
    _initCookieJar();
  }

  Future<void> _initCookieJar() async {
    final appDocDir = await getApplicationDocumentsDirectory();
    final appDocPath = appDocDir.path;
    _cookieJar = PersistCookieJar(
      ignoreExpires: true,
      storage: FileStorage("$appDocPath/.cookies/"),
    );
    notifyListeners(); // 通知监听器 _cookieJar 已初始化
  }

  bool get isLoggedIn => _user != null;
  String get username => _user?.username ?? '';
  String get loginResponse => _loginResponse;
  String get password => _password;

  // 添加 cookies getter
  Future<String> get cookies async {
    if (_cookieJar == null) {
      await _initCookieJar(); // 如果 _cookieJar 还没初始化，等待初始化完成
    }
    final iaaaCookies =
        await _cookieJar!.loadForRequest(Uri.parse('https://iaaa.pku.edu.cn'));
    final wprocCookies =
        await _cookieJar!.loadForRequest(Uri.parse('https://wproc.pku.edu.cn'));
    final allCookies = [...iaaaCookies, ...wprocCookies];
    return allCookies
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  Future<void> login(String username, String password) async {
    try {
      if (_cookieJar == null) {
        await _initCookieJar();
      }
      HttpClient httpClient = HttpClient();

      HttpClientRequest request = await httpClient.postUrl(
        Uri.parse('https://iaaa.pku.edu.cn/iaaa/oauthlogin.do'),
      );
      request.followRedirects = false;
      request.headers.set(
          HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded');
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      );

      request.write(Uri(queryParameters: {
        'appid': 'wproc',
        'userName': username,
        'password': password,
        'redirUrl':
            'https://wproc.pku.edu.cn/site/login/cas-login?redirect_url=https://wproc.pku.edu.cn/v2/reserve/',
      }).query);

      HttpClientResponse response = await request.close();
      String responseBody = await response.transform(utf8.decoder).join();

      List<Cookie> cookies = response.cookies;
      await _cookieJar!
          .saveFromResponse(Uri.parse('https://iaaa.pku.edu.cn'), cookies);

      if (response.statusCode == 200) {
        final jsonResponse = json.decode(responseBody);
        final token = jsonResponse['token'];

        await _fetchWprocCookies(httpClient, token);

        _user = User(username: username, token: token);
        _password = password;

        await _saveCredentials(username, password);
        notifyListeners();
      } else {
        throw Exception('登录失败: ${response.statusCode}');
      }

      httpClient.close();
    } catch (e) {
      print('登录过程中发生错误: $e');
      throw Exception('登录失败: $e');
    }
  }

  /// 使用 token 进行 GET 请求以获取 wproc 的 cookies
  Future<void> _fetchWprocCookies(HttpClient httpClient, String token) async {
    // 构建 GET 请求的 URL
    final uri = Uri.parse(
        'https://wproc.pku.edu.cn/site/login/cas-login?redirect_url=https://wproc.pku.edu.cn/v2/reserve/&_rand=0.6441813796046802&token=$token');

    // 创建 GET 请求
    HttpClientRequest getRequest = await httpClient.getUrl(uri);
    getRequest.followRedirects = false;
    getRequest.headers.set(
      HttpHeaders.userAgentHeader,
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    );

    // 发送 GET 请求并获取响应
    HttpClientResponse getResponse = await getRequest.close();

    // 读取响应
    String getResponseBody = await getResponse.transform(utf8.decoder).join();
    print('第二次请求响应状态码: ${getResponse.statusCode}');
    print('第二次请求响应体: $getResponseBody');
    print('第二次 Set-Cookie: ${getResponse.headers['set-cookie']}');

    // 保存第二次请求的 cookies
    List<Cookie> wprocCookies = getResponse.cookies;
    await _cookieJar!
        .saveFromResponse(Uri.parse('https://wproc.pku.edu.cn'), wprocCookies);

    print('wproc 的 cookies 已保存到 cookie jar 中。');
  }

  Future<void> logout() async {
    _user = null;
    _loginResponse = '';
    await _clearCredentials();
    if (_cookieJar != null) {
      await _cookieJar!.deleteAll();
    }
    notifyListeners();
  }

  Future<void> _saveCredentials(String username, String password) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('username', username);
    await prefs.setString('password', password);
  }

  Future<void> _clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('username');
    await prefs.remove('password');
  }

  Future<void> loadUsername() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('username');
    if (savedUsername != null) {
      _user = User(username: savedUsername, token: '');
      notifyListeners();
    }
  }

  Future<void> loadCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUsername = prefs.getString('username');
    final savedPassword = prefs.getString('password');
    if (savedUsername != null && savedPassword != null) {
      _user = User(username: savedUsername, token: '');
      _password = savedPassword;
      notifyListeners();
    }
  }

  Future<http.Response> get(Uri url) async {
    if (_cookieJar == null) {
      await _initCookieJar();
    }
    final cookies = await _cookieJar!.loadForRequest(url);
    final cookieString =
        cookies.map((cookie) => '${cookie.name}=${cookie.value}').join('; ');

    return await _client.get(
      url,
      headers: {
        'Cookie': cookieString,
        'User-Agent':
            'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      },
    );
  }
}
