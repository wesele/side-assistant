import 'dart:convert';
import 'package:http/http.dart' as http;

class WebSearchResult {
  final String title;
  final String url;
  final String snippet;

  const WebSearchResult({
    required this.title,
    required this.url,
    required this.snippet,
  });

  Map<String, dynamic> toMap() => {
        'title': title,
        'url': url,
        'snippet': snippet,
      };
}

class WebSearchService {
  final http.Client? _injectedClient;

  WebSearchService({http.Client? client}) : _injectedClient = client;

  static const Map<String, String> _browserHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };

  static const Map<String, String> _mobileHeaders = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36',
    'Accept':
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  };

  /// 执行免配置网页搜索并返回结构化结果列表。
  /// - 若包含天气查询意图，优先补充 Open-Meteo 实时与未来 5 日权威气象数据；
  /// - 常规网页搜索按 360 移动搜索 (m.so.com) -> Bing -> DuckDuckGo 顺序获取。
  Future<List<WebSearchResult>> search(
    String query, {
    int maxResults = 5,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) return [];

    final client = _injectedClient ?? http.Client();
    final combined = <WebSearchResult>[];
    try {
      // 0. 若是天气类查询，且非单元测试注入的受限 MockClient，尝试获取精确气象数据
      if (_injectedClient == null && isWeatherQuery(cleanQuery)) {
        try {
          final weatherResult = await _searchOpenMeteoWeather(client, cleanQuery);
          if (weatherResult != null) {
            combined.add(weatherResult);
          }
        } catch (_) {}
      }

      // 1. 尝试 Bing 搜索
      try {
        final bingResults = await _searchBing(
          client,
          cleanQuery,
          maxResults: maxResults,
        );
        for (final r in bingResults) {
          if (combined.length >= maxResults) break;
          combined.add(r);
        }
        if (combined.length >= maxResults) {
          return combined;
        }
      } catch (_) {}

      // 2. 尝试 360 移动网页搜索（无验证码拦截，适合中文及综合资讯）
      if (combined.length < maxResults) {
        try {
          final soResults = await _searchSoMobile(
            client,
            cleanQuery,
            maxResults: maxResults - combined.length,
          );
          for (final r in soResults) {
            if (combined.length >= maxResults) break;
            combined.add(r);
          }
          if (combined.isNotEmpty) {
            return combined;
          }
        } catch (_) {}
      }

      // 3. 回退尝试 DuckDuckGo HTML 版
      if (combined.isEmpty) {
        try {
          final ddgResults = await _searchDuckDuckGo(
            client,
            cleanQuery,
            maxResults: maxResults,
          );
          if (ddgResults.isNotEmpty) {
            return ddgResults;
          }
        } catch (_) {}
      }

      return combined;
    } finally {
      if (_injectedClient == null) {
        client.close();
      }
    }
  }

  /// 执行网页搜索并格式化为供大模型阅读的紧凑文本结果
  Future<String> searchAndFormat(
    String query, {
    int maxResults = 5,
  }) async {
    final cleanQuery = query.trim();
    if (cleanQuery.isEmpty) {
      return 'Search query is empty.';
    }
    try {
      final results = await search(cleanQuery, maxResults: maxResults);
      if (results.isEmpty) {
        return 'No web search results found for "$cleanQuery".';
      }
      final buffer = StringBuffer();
      buffer.writeln('Web search results for "$cleanQuery":');
      for (var i = 0; i < results.length; i++) {
        final r = results[i];
        buffer.writeln('[${i + 1}] ${r.title}');
        if (r.url.isNotEmpty) {
          buffer.writeln('URL: ${r.url}');
        }
        if (r.snippet.isNotEmpty) {
          buffer.writeln('Snippet: ${r.snippet}');
        }
        buffer.writeln();
      }
      return buffer.toString().trim();
    } catch (e) {
      return 'Web search failed for "$cleanQuery": $e';
    }
  }

  Future<List<WebSearchResult>> _searchBing(
    http.Client client,
    String query, {
    required int maxResults,
  }) async {
    final uri = Uri.https('cn.bing.com', '/search', {
      'q': query,
      'ensearch': '0',
    });
    final response = await client
        .get(uri, headers: _browserHeaders)
        .timeout(const Duration(seconds: 6));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return [];
    }
    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    return parseBingHtml(html, maxResults: maxResults);
  }

  Future<List<WebSearchResult>> _searchSoMobile(
    http.Client client,
    String query, {
    required int maxResults,
  }) async {
    final uri = Uri.https('m.so.com', '/s', {
      'q': query,
    });
    final response = await client
        .get(uri, headers: _mobileHeaders)
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return [];
    }
    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    return parseSoMobileHtml(html, maxResults: maxResults);
  }

  Future<List<WebSearchResult>> _searchDuckDuckGo(
    http.Client client,
    String query, {
    required int maxResults,
  }) async {
    final uri = Uri.https('html.duckduckgo.com', '/html/', {
      'q': query,
    });
    final response = await client
        .get(uri, headers: _browserHeaders)
        .timeout(const Duration(seconds: 6));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return [];
    }
    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    return parseDuckDuckGoHtml(html, maxResults: maxResults);
  }

  /// 判断查询是否包含天气预报意图
  static bool isWeatherQuery(String query) {
    final lower = query.toLowerCase();
    return RegExp(
      r'(天气|气温|温度|下雨|降雪|气象|预报|weather|forecast|temperature|tiempo|clima)',
    ).hasMatch(lower);
  }

  /// 从天气查询串中提取城市/地点名称（剥离日期与天气修饰词）
  static String extractLocationFromWeatherQuery(String query) {
    var cleaned = query
        .replaceAll(RegExp(r'\d{4}\s*年|\d{1,2}\s*月|\d{1,2}\s*[日号]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(today|tomorrow|weather|forecast|temperature|el|tiempo|en|mañana|in|for|of|jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december|\d{1,4})\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'(今天|明天|后天|大后天|昨日|昨天|今日|明日|未来|一周|七天|7天|15天|天气预报|天气|气温|温度|怎么样|如何|查询|最新|实时|预报|的)',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[?？,，。!！:：;；\s]+'), ' ')
        .trim();
    if (cleaned.isEmpty) return query.trim();
    final parts = cleaned.split(' ').where((s) => s.trim().isNotEmpty).toList();
    return parts.first.trim();
  }

  Future<WebSearchResult?> _searchOpenMeteoWeather(
    http.Client client,
    String query,
  ) async {
    final location = extractLocationFromWeatherQuery(query);
    if (location.isEmpty) return null;

    final geoUri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': location,
      'count': '1',
      'language': 'zh',
    });
    final geoResp = await client
        .get(geoUri, headers: _browserHeaders)
        .timeout(const Duration(seconds: 6));
    if (geoResp.statusCode < 200 || geoResp.statusCode >= 300) return null;

    final geoData =
        jsonDecode(utf8.decode(geoResp.bodyBytes, allowMalformed: true));
    if (geoData is! Map) return null;
    final geoResults = geoData['results'] as List?;
    if (geoResults == null || geoResults.isEmpty) return null;

    final place = geoResults.first as Map;
    final placeName = place['name']?.toString() ?? location;
    final country = place['country']?.toString() ?? '';
    final lat = place['latitude']?.toString() ?? '';
    final lon = place['longitude']?.toString() ?? '';
    if (lat.isEmpty || lon.isEmpty) return null;

    final fcUri = Uri.https('api.open-meteo.com', '/v1/forecast', {
      'latitude': lat,
      'longitude': lon,
      'current':
          'temperature_2m,relative_humidity_2m,weather_code,wind_speed_10m',
      'daily':
          'weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max',
      'timezone': 'auto',
      'forecast_days': '5',
    });
    final fcResp = await client
        .get(fcUri, headers: _browserHeaders)
        .timeout(const Duration(seconds: 6));
    if (fcResp.statusCode < 200 || fcResp.statusCode >= 300) return null;

    final fcData =
        jsonDecode(utf8.decode(fcResp.bodyBytes, allowMalformed: true));
    if (fcData is! Map) return null;

    final current = fcData['current'] as Map?;
    final daily = fcData['daily'] as Map?;
    final sb = StringBuffer();
    if (current != null) {
      final temp = current['temperature_2m'];
      final hum = current['relative_humidity_2m'];
      final wCode = (current['weather_code'] as num?)?.toInt();
      final wind = current['wind_speed_10m'];
      sb.write(
        '当前实况(${current['time']}): ${_wmoDescription(wCode)}，气温 $temp°C，湿度 $hum%，风速 ${wind}km/h。',
      );
    }
    if (daily != null) {
      final times = (daily['time'] as List?) ?? const [];
      final codes = (daily['weather_code'] as List?) ?? const [];
      final maxTemps = (daily['temperature_2m_max'] as List?) ?? const [];
      final minTemps = (daily['temperature_2m_min'] as List?) ?? const [];
      final precip =
          (daily['precipitation_probability_max'] as List?) ?? const [];
      sb.write(' 未来逐日预报: ');
      for (var i = 0; i < times.length; i++) {
        final dateStr = times[i];
        final desc = _wmoDescription(
          i < codes.length ? (codes[i] as num?)?.toInt() : null,
        );
        final tMax = i < maxTemps.length ? maxTemps[i] : '?';
        final tMin = i < minTemps.length ? minTemps[i] : '?';
        final pop = i < precip.length ? precip[i] : 0;
        final label = i == 0
            ? '今天($dateStr)'
            : (i == 1 ? '明天($dateStr)' : '$dateStr');
        sb.write('$label: $desc, 最低$tMin°C~最高$tMax°C, 降水概率$pop%; ');
      }
    }

    return WebSearchResult(
      title:
          '$placeName${country.isNotEmpty ? " ($country)" : ""} 实时与未来5天官方气象预报',
      url: 'https://open-meteo.com/',
      snippet: sb.toString().trim(),
    );
  }

  static String _wmoDescription(int? code) {
    switch (code) {
      case 0:
        return '晴朗';
      case 1:
        return '大部晴朗';
      case 2:
        return '局部多云';
      case 3:
        return '阴天/多云';
      case 45:
      case 48:
        return '有雾';
      case 51:
      case 53:
      case 55:
        return '毛毛雨';
      case 61:
      case 63:
      case 65:
        return '小到中雨/大雨';
      case 71:
      case 73:
      case 75:
        return '降雪';
      case 80:
      case 81:
      case 82:
        return '阵雨';
      case 95:
      case 96:
      case 99:
        return '雷阵雨';
      default:
        return '多云';
    }
  }

  /// 解析 360 移动搜索结果页 HTML
  static List<WebSearchResult> parseSoMobileHtml(
    String html, {
    int maxResults = 5,
  }) {
    final results = <WebSearchResult>[];
    final h3Matches = RegExp(
      r'<h3\b[^>]*>([\s\S]*?)<\/h3>',
      caseSensitive: false,
    ).allMatches(html).toList();

    for (var i = 0; i < h3Matches.length; i++) {
      if (results.length >= maxResults) break;
      final m = h3Matches[i];
      final h3Inner = m.group(1) ?? '';
      final title = _cleanHtmlText(h3Inner);
      if (title.isEmpty ||
          title.contains('相关推荐') ||
          title.contains('猜您关注') ||
          title.contains('其他人还在搜') ||
          title.contains('相关搜索')) {
        continue;
      }

      String url = 'https://m.so.com';
      final aMatch = RegExp(
        r'href="([^"]+)"',
        caseSensitive: false,
      ).firstMatch(h3Inner);
      if (aMatch != null) {
        url = _decodeHtmlEntities(aMatch.group(1) ?? '');
      }

      final nextStart = m.end;
      final nextEnd = (i + 1 < h3Matches.length)
          ? h3Matches[i + 1].start
          : (nextStart + 1200 < html.length ? nextStart + 1200 : html.length);
      final rawAfter = html
          .substring(nextStart, nextEnd)
          .replaceAll(
            RegExp(r'<script[\s\S]*?<\/script>', caseSensitive: false),
            ' ',
          )
          .replaceAll(
            RegExp(r'<style[\s\S]*?<\/style>', caseSensitive: false),
            ' ',
          );
      var snippet = _cleanHtmlText(rawAfter);
      if (snippet.length > 260) {
        snippet = '${snippet.substring(0, 260)}...';
      }
      if (snippet.isEmpty) continue;

      results.add(
        WebSearchResult(
          title: title,
          url: url,
          snippet: snippet,
        ),
      );
    }
    return results;
  }

  /// 解析 Bing 搜索结果页 HTML（提取 `<li class="b_algo">` 块）
  static List<WebSearchResult> parseBingHtml(
    String html, {
    int maxResults = 5,
  }) {
    final results = <WebSearchResult>[];
    final algoBlocks = RegExp(
      r'<li\b[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>([\s\S]*?)<\/li>',
      caseSensitive: false,
    ).allMatches(html);

    for (final match in algoBlocks) {
      if (results.length >= maxResults) break;
      final block = match.group(1) ?? '';

      // 提取 <h2> 内的 <a href="...">title</a>
      final h2Match = RegExp(
        r'<h2\b[^>]*>[\s\S]*?<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>[\s\S]*?<\/h2>',
        caseSensitive: false,
      ).firstMatch(block);
      if (h2Match == null) continue;

      final rawUrl = _decodeHtmlEntities(h2Match.group(1) ?? '').trim();
      final title = _cleanHtmlText(h2Match.group(2) ?? '');
      if (title.isEmpty || rawUrl.isEmpty) continue;

      // 提取摘要段落 <p ...> 或 <div class="b_caption">
      String snippet = '';
      final pMatch = RegExp(
        r'<p\b[^>]*>([\s\S]*?)<\/p>',
        caseSensitive: false,
      ).firstMatch(block);
      if (pMatch != null) {
        snippet = _cleanHtmlText(pMatch.group(1) ?? '');
      } else {
        final captionMatch = RegExp(
          r'<div\b[^>]*class="[^"]*\bb_caption\b[^"]*"[^>]*>([\s\S]*?)<\/div>',
          caseSensitive: false,
        ).firstMatch(block);
        if (captionMatch != null) {
          snippet = _cleanHtmlText(captionMatch.group(1) ?? '');
        }
      }

      results.add(
        WebSearchResult(
          title: title,
          url: rawUrl,
          snippet: snippet,
        ),
      );
    }
    return results;
  }

  /// 解析 DuckDuckGo HTML 搜索结果页
  static List<WebSearchResult> parseDuckDuckGoHtml(
    String html, {
    int maxResults = 5,
  }) {
    final results = <WebSearchResult>[];
    final titleMatches = RegExp(
      r'<a\b[^>]*class="[^"]*\bresult__a\b[^"]*"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)<\/a>',
      caseSensitive: false,
    ).allMatches(html).toList();

    final snippetMatches = RegExp(
      r'<a\b[^>]*class="[^"]*\bresult__snippet\b[^"]*"[^>]*>([\s\S]*?)<\/a>',
      caseSensitive: false,
    ).allMatches(html).toList();

    for (var i = 0; i < titleMatches.length; i++) {
      if (results.length >= maxResults) break;
      final tMatch = titleMatches[i];
      var rawUrl = _decodeHtmlEntities(tMatch.group(1) ?? '').trim();
      final uddgMatch = RegExp(r'[?&]uddg=([^&]+)').firstMatch(rawUrl);
      if (uddgMatch != null) {
        try {
          rawUrl = Uri.decodeComponent(uddgMatch.group(1)!);
        } catch (_) {}
      }
      final title = _cleanHtmlText(tMatch.group(2) ?? '');
      if (title.isEmpty) continue;

      final snippet = i < snippetMatches.length
          ? _cleanHtmlText(snippetMatches[i].group(1) ?? '')
          : '';

      results.add(
        WebSearchResult(
          title: title,
          url: rawUrl,
          snippet: snippet,
        ),
      );
    }
    return results;
  }

  static String _cleanHtmlText(String raw) {
    final withoutTags = raw.replaceAll(RegExp(r'<[^>]+>'), ' ');
    return _decodeHtmlEntities(withoutTags)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _decodeHtmlEntities(String input) {
    return input
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&#x27;', "'")
        .replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1) ?? '');
      return code != null ? String.fromCharCode(code) : m.group(0)!;
    });
  }
}
