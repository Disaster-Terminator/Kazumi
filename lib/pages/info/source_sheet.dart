import 'package:flutter/material.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/info/info_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:kazumi/services/plugin/plugin_search_service.dart';
import 'package:kazumi/pages/collect/collect_controller.dart';
import 'package:kazumi/bean/widget/error_widget.dart';
import 'dart:async';
import 'dart:convert';
import 'package:kazumi/services/plugin/captcha_ocr_service.dart';
import 'package:kazumi/services/plugin/captcha_verification_service.dart';
import 'package:kazumi/plugins/anti_crawler_config.dart';
import 'package:kazumi/utils/device.dart';

enum _CaptchaVerificationPhase {
  idle,
  silentRunning,
  silentFailed,
  manualRunning,
}

class _CaptchaVerificationKey {
  const _CaptchaVerificationKey({
    required this.pluginName,
    required this.keyword,
    required this.searchUrl,
    required this.captchaType,
  });

  final String pluginName;
  final String keyword;
  final String searchUrl;
  final int captchaType;

  @override
  bool operator ==(Object other) {
    return other is _CaptchaVerificationKey &&
        other.pluginName == pluginName &&
        other.keyword == keyword &&
        other.searchUrl == searchUrl &&
        other.captchaType == captchaType;
  }

  @override
  int get hashCode => Object.hash(pluginName, keyword, searchUrl, captchaType);
}

class _CaptchaVerificationRun {
  final ValueNotifier<_CaptchaVerificationPhase> phase =
      ValueNotifier<_CaptchaVerificationPhase>(_CaptchaVerificationPhase.idle);
  CaptchaVerificationService? service;
  StreamSubscription<String?>? imageSub;
  Timer? timeout;
  bool silentAttempted = false;
  bool imageHandled = false;
  bool disposed = false;

  bool get isRunning =>
      phase.value == _CaptchaVerificationPhase.silentRunning ||
      phase.value == _CaptchaVerificationPhase.manualRunning;

  Future<void> dispose() async {
    disposed = true;
    timeout?.cancel();
    timeout = null;
    await imageSub?.cancel();
    imageSub = null;
    service?.dispose();
    service = null;
    phase.dispose();
  }
}

class SourceSheet extends StatefulWidget {
  const SourceSheet({
    super.key,
    required this.tabController,
    required this.infoController,
  });

  final TabController tabController;
  final InfoController infoController;

  @override
  State<SourceSheet> createState() => _SourceSheetState();
}

class _SourceSheetState extends State<SourceSheet>
    with SingleTickerProviderStateMixin {
  final VideoPageController videoPageController =
      Modular.get<VideoPageController>();
  final CollectController collectController = Modular.get<CollectController>();
  final PluginsController pluginsController = Modular.get<PluginsController>();
  late String keyword;

  /// Concurrent plugin search service.
  PluginSearchService? pluginSearchService;

  /// Captcha verification service (created on demand)
  CaptchaVerificationService? _captchaVerificationService;

  /// Timeout timer waiting for captcha verification result
  Timer? _captchaVerifyTimer;
  final CaptchaOcrService _captchaOcrService = createCaptchaOcrService();
  final Map<_CaptchaVerificationKey, _CaptchaVerificationRun>
      _captchaVerificationRuns =
      <_CaptchaVerificationKey, _CaptchaVerificationRun>{};

  @override
  void initState() {
    keyword = widget.infoController.bangumiItem.nameCn == ''
        ? widget.infoController.bangumiItem.name
        : widget.infoController.bangumiItem.nameCn;
    pluginSearchService =
        PluginSearchService(infoController: widget.infoController);
    pluginSearchService?.queryAllSource(keyword);
    super.initState();
  }

  @override
  void dispose() {
    pluginSearchService?.cancel();
    pluginSearchService = null;
    _captchaVerificationService?.dispose();
    _captchaVerificationService = null;
    _captchaVerifyTimer?.cancel();
    _captchaVerifyTimer = null;
    final runs = List<_CaptchaVerificationRun>.from(
      _captchaVerificationRuns.values,
    );
    _captchaVerificationRuns.clear();
    for (final run in runs) {
      unawaited(run.dispose());
    }
    super.dispose();
  }

  /// 根据插件的验证类型分发到对应的验证对话框
  void showAntiCrawlerDialog(Plugin plugin) {
    switch (plugin.antiCrawlerConfig.captchaType) {
      case CaptchaType.customJavaScript:
        showCustomScriptDialog(plugin);
        break;
      case CaptchaType.autoClickButton:
        showButtonClickDialog(plugin);
        break;
      default:
        _startManualCaptchaVerification(plugin);
    }
  }

  String _searchUrlFor(Plugin plugin) {
    return plugin.searchURL.replaceAll(
      '@keyword',
      Uri.encodeQueryComponent(keyword),
    );
  }

  _CaptchaVerificationKey _captchaVerificationKeyFor(Plugin plugin) {
    return _CaptchaVerificationKey(
      pluginName: plugin.name,
      keyword: keyword,
      searchUrl: _searchUrlFor(plugin),
      captchaType: plugin.antiCrawlerConfig.captchaType,
    );
  }

  _CaptchaVerificationRun _runFor(_CaptchaVerificationKey key) {
    return _captchaVerificationRuns.putIfAbsent(
      key,
      () => _CaptchaVerificationRun(),
    );
  }

  bool _shouldAttemptSilentCaptcha(Plugin plugin) {
    return plugin.antiCrawlerConfig.captchaType == CaptchaType.imageCaptcha &&
        _captchaOcrService.isEnabled &&
        _captchaOcrService.shouldAutoSubmit;
  }

  void _scheduleSilentCaptchaVerification(Plugin plugin) {
    final key = _captchaVerificationKeyFor(plugin);
    final run = _runFor(key);
    if (run.disposed || run.silentAttempted || run.isRunning) return;
    run.silentAttempted = true;
    KazumiLogger().i(
      '[CaptchaOcrService] captcha challenge route: plugin=${plugin.name}, enabled=${_captchaOcrService.isEnabled}, autosubmit=${_captchaOcrService.shouldAutoSubmit}',
      forceLog: true,
    );
    unawaited(
      _trySilentCaptchaVerification(
        plugin,
        _captchaOcrService,
        key: key,
        run: run,
      ),
    );
  }

  void _startManualCaptchaVerification(Plugin plugin) {
    final key = _captchaVerificationKeyFor(plugin);
    final run = _runFor(key);
    if (run.disposed || run.isRunning) return;
    showCaptchaDialog(plugin, key: key, run: run);
  }

  Future<void> _trySilentCaptchaVerification(
    Plugin plugin,
    CaptchaOcrService ocrService, {
    required _CaptchaVerificationKey key,
    required _CaptchaVerificationRun run,
  }) async {
    if (run.disposed || run.isRunning) return;
    run.phase.value = _CaptchaVerificationPhase.silentRunning;
    run.imageHandled = false;
    await run.imageSub?.cancel();
    run.imageSub = null;
    run.timeout?.cancel();
    run.timeout = null;
    run.service?.dispose();
    run.service = CaptchaVerificationService();
    final captchaService = run.service!;
    final searchUrl = key.searchUrl;
    var finished = false;

    Future<void> finish({required bool verified}) async {
      if (finished) return;
      finished = true;
      run.timeout?.cancel();
      run.timeout = null;
      await run.imageSub?.cancel();
      run.imageSub = null;
      if (run.disposed) {
        if (run.service == captchaService) {
          run.service = null;
        }
        captchaService.dispose();
        return;
      }
      if (verified) {
        run.phase.value = _CaptchaVerificationPhase.idle;
        run.service = null;
        captchaService.dispose();
        pluginSearchService?.querySource(keyword, plugin.name);
      } else {
        KazumiLogger().i(
          '[CaptchaOcrService] silent captcha verification failed for ${plugin.name}; manual verification remains available',
          forceLog: true,
        );
        await captchaService.saveAndUnload(plugin.name);
        run.phase.value = _CaptchaVerificationPhase.silentFailed;
        run.service = null;
        captchaService.dispose();
      }
    }

    run.timeout = Timer(const Duration(seconds: 60), () {
      unawaited(finish(verified: false));
    });

    run.imageSub = captchaService.onCaptchaImageUrl.listen((imageUrl) async {
      if (finished || imageUrl == null) return;
      if (run.imageHandled) return;
      run.imageHandled = true;
      KazumiLogger().i(
        '[CaptchaOcrService] silent captcha image received for ${plugin.name}: ${imageUrl.length} chars',
        forceLog: true,
      );
      final result = await ocrService.recognizeDataUrl(imageUrl);
      if (finished) return;
      if (result == null) {
        await finish(verified: false);
        return;
      }

      run.timeout?.cancel();
      run.timeout = Timer(const Duration(seconds: 10), () {
        unawaited(finish(verified: false));
      });

      try {
        await captchaService.submitCaptcha(
          captchaCode: result.code,
          inputXpath: plugin.antiCrawlerConfig.captchaInput,
          buttonXpath: plugin.antiCrawlerConfig.captchaButton,
          pluginName: plugin.name,
          onVerified: () => unawaited(finish(verified: true)),
        );
      } catch (error) {
        KazumiLogger().w(
          '[CaptchaOcrService] silent captcha submit failed for ${plugin.name}: $error',
          forceLog: true,
        );
        await finish(verified: false);
      }
    });

    try {
      await captchaService.loadForCaptcha(
        searchUrl,
        plugin.antiCrawlerConfig.captchaImage,
        inputXpath: plugin.antiCrawlerConfig.captchaInput,
      );
    } catch (error) {
      KazumiLogger().w(
        '[CaptchaOcrService] silent captcha load failed for ${plugin.name}: $error',
        forceLog: true,
      );
      await finish(verified: false);
    }
  }

  void showCaptchaDialog(
    Plugin plugin, {
    _CaptchaVerificationKey? key,
    _CaptchaVerificationRun? run,
  }) {
    key ??= _captchaVerificationKeyFor(plugin);
    final activeRun = run ?? _runFor(key);
    if (activeRun.disposed || activeRun.isRunning) return;
    activeRun.phase.value = _CaptchaVerificationPhase.manualRunning;

    /// flag whether verification has passed, used to distinguish normal dismissal from cancellation in onDismiss
    bool verified = false;

    activeRun.service?.dispose();
    activeRun.service = CaptchaVerificationService();
    final searchUrl = key.searchUrl;
    final captchaService = activeRun.service!;

    Future<void> submitCaptcha(String captchaCode) async {
      await captchaService.submitCaptcha(
        captchaCode: captchaCode.trim(),
        inputXpath: plugin.antiCrawlerConfig.captchaInput,
        buttonXpath: plugin.antiCrawlerConfig.captchaButton,
        pluginName: plugin.name,
        onVerified: () {
          _captchaVerifyTimer?.cancel();
          _captchaVerifyTimer = null;
          verified = true;
          activeRun.phase.value = _CaptchaVerificationPhase.idle;
          KazumiDialog.dismiss();
          // show a 3s countdown progress dialog before re-querying,
          // to avoid triggering rate limits immediately after verification.
          KazumiDialog.showTimedSuccessDialog(
            title: '验证成功',
            message: '正在重新检索，请稍候…',
            onComplete: () =>
                pluginSearchService?.querySource(keyword, plugin.name),
          );
        },
      );
      // submitCaptcha completes after the JS button click is fired.
      // Start the 8-second timeout only NOW, waiting for the webview to
      // detect the captcha disappearing and call onVerified.
      if (!verified) {
        _captchaVerifyTimer?.cancel();
        _captchaVerifyTimer = Timer(const Duration(seconds: 8), () {
          if (!verified) {
            KazumiDialog.dismiss();
          }
        });
      }
    }

    KazumiDialog.show(
      onDismiss: () async {
        _captchaVerifyTimer?.cancel();
        _captchaVerifyTimer = null;
        final captchaService = activeRun.service;
        activeRun.service = null;
        if (!verified) {
          activeRun.phase.value = _CaptchaVerificationPhase.idle;
          await captchaService?.saveAndUnload(plugin.name);
          captchaService?.dispose();
          pluginSearchService?.querySource(keyword, plugin.name);
        } else {
          captchaService?.dispose();
        }
      },
      builder: (context) => _CaptchaDialog(
        pluginName: plugin.name,
        captchaImageStream: captchaService.onCaptchaImageUrl,
        onReady: () => unawaited(captchaService.loadForCaptcha(
          searchUrl,
          plugin.antiCrawlerConfig.captchaImage,
          inputXpath: plugin.antiCrawlerConfig.captchaInput,
        )),
        onSubmit: submitCaptcha,
      ),
    );
  }

  void showButtonClickDialog(Plugin plugin) {
    showAutomatedVerifyDialog(
      plugin,
      statusText: '${plugin.name} 正在自动完成验证，请稍候',
      detailText: '已检测到验证按钮并模拟点击，等待验证通过…',
      startVerification: (captchaService, searchUrl, onVerified) {
        return captchaService.loadForButtonClick(
          url: searchUrl,
          buttonXpath: plugin.antiCrawlerConfig.captchaButton,
          pluginName: plugin.name,
          onVerified: onVerified,
        );
      },
    );
  }

  void showCustomScriptDialog(Plugin plugin) {
    showAutomatedVerifyDialog(
      plugin,
      statusText: '${plugin.name} 正在执行验证脚本，请稍候',
      detailText: '已加载验证页面并执行自定义脚本，等待验证通过…',
      startVerification: (captchaService, searchUrl, onVerified) {
        return captchaService.loadForCustomScript(
          url: searchUrl,
          script: plugin.antiCrawlerConfig.captchaScript,
          pluginName: plugin.name,
          onVerified: onVerified,
        );
      },
    );
  }

  void showAutomatedVerifyDialog(
    Plugin plugin, {
    required String statusText,
    required String detailText,
    required Future<void> Function(
      CaptchaVerificationService captchaService,
      String searchUrl,
      void Function() onVerified,
    ) startVerification,
  }) {
    bool verified = false;

    _captchaVerificationService?.dispose();
    _captchaVerificationService = CaptchaVerificationService();

    final captchaService = _captchaVerificationService!;
    final searchUrl = plugin.searchURL
        .replaceAll('@keyword', Uri.encodeQueryComponent(keyword));

    void onVerified() {
      if (verified) return;
      verified = true;
      KazumiDialog.dismiss();
      KazumiDialog.showTimedSuccessDialog(
        title: '验证成功',
        message: '正在重新检索，请稍候…',
        onComplete: () =>
            pluginSearchService?.querySource(keyword, plugin.name),
      );
    }

    unawaited(startVerification(captchaService, searchUrl, onVerified));

    KazumiDialog.show(
      onDismiss: () async {
        final captchaService = _captchaVerificationService;
        _captchaVerificationService = null;
        if (verified) {
          captchaService?.dispose();
        } else {
          await captchaService?.saveAndUnload(plugin.name);
          captchaService?.dispose();
          pluginSearchService?.querySource(keyword, plugin.name);
        }
      },
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  '自动验证中',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                const CircularProgressIndicator(),
                const SizedBox(height: 12),
                Text(
                  detailText,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => KazumiDialog.dismiss(),
                    child: Text(
                      '取消',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget buildPluginView(Plugin plugin, List<Widget> cardList) {
    final status = widget.infoController.pluginSearchStatus[plugin.name];
    if (status == 'pending') {
      return const Center(child: CircularProgressIndicator());
    }
    if (status == 'captcha') {
      final key = _captchaVerificationKeyFor(plugin);
      final run = _runFor(key);
      return _CaptchaChallengeView(
        pluginName: plugin.name,
        run: run,
        shouldAttemptSilent: _shouldAttemptSilentCaptcha(plugin),
        onSilentAttempt: () => _scheduleSilentCaptchaVerification(plugin),
        onManualPressed: () => showAntiCrawlerDialog(plugin),
        onRetryPressed: () =>
            pluginSearchService?.querySource(keyword, plugin.name),
      );
    }
    if (status == 'noResult') {
      return GeneralErrorWidget(
        errMsg: '${plugin.name} 无结果 使用别名或左右滑动以切换到其他视频来源',
        actions: [
          GeneralErrorButton(
            onPressed: () => showAliasSearchDialog(plugin.name),
            text: '别名检索',
          ),
          GeneralErrorButton(
            onPressed: () => showCustomSearchDialog(plugin.name),
            text: '手动检索',
          ),
        ],
      );
    }
    if (status == 'error') {
      return GeneralErrorWidget(
        errMsg: '${plugin.name} 检索失败 重试或左右滑动以切换到其他视频来源',
        actions: [
          GeneralErrorButton(
            onPressed: () =>
                pluginSearchService?.querySource(keyword, plugin.name),
            text: '重试',
          ),
        ],
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            children: cardList,
          ),
        ),
        if (cardList.isNotEmpty) showSupplementarySearchEntry(plugin.name),
      ],
    );
  }

  /// 构建结果列表底部补充检索入口，便于已有结果不准确时换用别名或手动检索关键词
  Widget showSupplementarySearchEntry(String pluginName) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 4, 18, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 2,
                runSpacing: 4,
                children: [
                  Text(
                    '结果不准确？',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.color
                              ?.withValues(alpha: 0.75),
                        ),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      textStyle: Theme.of(context).textTheme.bodySmall,
                    ),
                    onPressed: () => showAliasSearchDialog(pluginName),
                    child: const Text('别名检索'),
                  ),
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      textStyle: Theme.of(context).textTheme.bodySmall,
                    ),
                    onPressed: () => showCustomSearchDialog(pluginName),
                    child: const Text('手动检索'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void showAliasSearchDialog(String pluginName) {
    if (widget.infoController.bangumiItem.alias.isEmpty) {
      KazumiDialog.showToast(message: '无可用别名，试试手动检索');
      return;
    }
    KazumiDialog.show(
      builder: (context) {
        return _AliasDialog(
          aliases: widget.infoController.bangumiItem.alias,
          onAliasSelected: (alias) {
            KazumiDialog.dismiss();
            pluginSearchService?.querySource(alias, pluginName);
          },
          onAliasesChanged: () {
            collectController
                .updateLocalCollect(widget.infoController.bangumiItem);
          },
        );
      },
    );
  }

  void showCustomSearchDialog(String pluginName) {
    String customKeyword = '';

    void submit(String value) {
      final alias = value.trim();
      if (alias.isEmpty) {
        return;
      }
      widget.infoController.bangumiItem.alias.add(alias);
      collectController.updateLocalCollect(widget.infoController.bangumiItem);
      KazumiDialog.dismiss();
      pluginSearchService?.querySource(alias, pluginName);
    }

    KazumiDialog.show(
      builder: (context) {
        return AlertDialog(
          title: const Text('输入别名'),
          content: TextField(
            onChanged: (value) => customKeyword = value,
            onSubmitted: (keyword) {
              submit(keyword);
            },
          ),
          actions: [
            TextButton(
              onPressed: () {
                KazumiDialog.dismiss();
              },
              child: Text(
                '取消',
                style: TextStyle(color: Theme.of(context).colorScheme.outline),
              ),
            ),
            TextButton(
              onPressed: () {
                submit(customKeyword);
              },
              child: const Text(
                '确认',
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        body: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.center,
                    dividerHeight: 0,
                    controller: widget.tabController,
                    tabs: pluginsController.pluginList
                        .map(
                          (plugin) => Observer(
                            builder: (context) {
                              return Tab(
                                child: Row(
                                  children: [
                                    Text(
                                      plugin.name,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: Theme.of(context)
                                              .textTheme
                                              .titleMedium!
                                              .fontSize,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .onSurface),
                                    ),
                                    const SizedBox(width: 5.0),
                                    Container(
                                      width: 8.0,
                                      height: 8.0,
                                      decoration: BoxDecoration(
                                        color: switch (widget.infoController
                                            .pluginSearchStatus[plugin.name]) {
                                          'success' => Colors.green,
                                          'noResult' => Colors.orange,
                                          'captcha' => Colors.blue,
                                          'error' => Colors.red,
                                          _ => Colors.grey,
                                        },
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        )
                        .toList(),
                  ),
                ),
                IconButton(
                  onPressed: () {
                    int currentIndex = widget.tabController.index;
                    launchUrl(
                      Uri.parse(pluginsController
                          .pluginList[currentIndex].searchURL
                          .replaceFirst(
                              '@keyword', Uri.encodeQueryComponent(keyword))),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  icon: const Icon(Icons.open_in_browser_rounded),
                ),
                const SizedBox(width: 4),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: Observer(
                builder: (context) => TabBarView(
                  controller: widget.tabController,
                  children: List.generate(pluginsController.pluginList.length,
                      (pluginIndex) {
                    var plugin = pluginsController.pluginList[pluginIndex];
                    var cardList = <Widget>[];
                    for (var searchResponse
                        in widget.infoController.pluginSearchResponseList) {
                      if (searchResponse.pluginName == plugin.name) {
                        for (var searchItem in searchResponse.data) {
                          cardList.add(
                            Card(
                              elevation: 0,
                              margin: const EdgeInsets.only(
                                  left: 10, right: 10, top: 10),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () async {
                                  KazumiDialog.showLoading(
                                    msg: '获取中',
                                    barrierDismissible: isDesktop(),
                                    onDismiss: () {
                                      videoPageController.cancelQueryRoads();
                                    },
                                  );
                                  videoPageController.bangumiItem =
                                      widget.infoController.bangumiItem;
                                  videoPageController.currentPlugin = plugin;
                                  videoPageController.title = searchItem.name;
                                  videoPageController.src = searchItem.src;
                                  try {
                                    await videoPageController.queryRoads(
                                        searchItem.src, plugin.name);
                                    KazumiDialog.dismiss();
                                    Modular.to.pushNamed('/video/');
                                  } catch (_) {
                                    KazumiLogger().w(
                                        "PluginSearchService: failed to query video playlist");
                                    KazumiDialog.dismiss();
                                  }
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(20),
                                  child: Text(searchItem.name),
                                ),
                              ),
                            ),
                          );
                        }
                      }
                    }
                    return buildPluginView(plugin, cardList);
                  }),
                ),
              ),
            )
          ],
        ),
      ),
    );
  }
}

class _CaptchaChallengeView extends StatefulWidget {
  const _CaptchaChallengeView({
    required this.pluginName,
    required this.run,
    required this.shouldAttemptSilent,
    required this.onSilentAttempt,
    required this.onManualPressed,
    required this.onRetryPressed,
  });

  final String pluginName;
  final _CaptchaVerificationRun run;
  final bool shouldAttemptSilent;
  final VoidCallback onSilentAttempt;
  final VoidCallback onManualPressed;
  final VoidCallback onRetryPressed;

  @override
  State<_CaptchaChallengeView> createState() => _CaptchaChallengeViewState();
}

class _CaptchaChallengeViewState extends State<_CaptchaChallengeView> {
  @override
  void initState() {
    super.initState();
    _scheduleSilentAttemptIfNeeded();
  }

  @override
  void didUpdateWidget(covariant _CaptchaChallengeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.run != widget.run ||
        oldWidget.shouldAttemptSilent != widget.shouldAttemptSilent) {
      _scheduleSilentAttemptIfNeeded();
    }
  }

  void _scheduleSilentAttemptIfNeeded() {
    if (!widget.shouldAttemptSilent ||
        widget.run.silentAttempted ||
        widget.run.isRunning) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !widget.shouldAttemptSilent ||
          widget.run.silentAttempted ||
          widget.run.isRunning) {
        return;
      }
      widget.onSilentAttempt();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_CaptchaVerificationPhase>(
      valueListenable: widget.run.phase,
      builder: (context, phase, _) {
        final isRunning = phase == _CaptchaVerificationPhase.silentRunning ||
            phase == _CaptchaVerificationPhase.manualRunning;
        final message = switch (phase) {
          _CaptchaVerificationPhase.silentRunning =>
            '${widget.pluginName} 正在自动验证，请稍候',
          _CaptchaVerificationPhase.silentFailed =>
            '${widget.pluginName} 自动验证失败，可手动验证',
          _CaptchaVerificationPhase.manualRunning =>
            '${widget.pluginName} 正在手动验证，请稍候',
          _ => '${widget.pluginName} 需要验证码验证',
        };
        final manualText =
            phase == _CaptchaVerificationPhase.silentFailed ? '手动验证' : '进行验证';
        return GeneralErrorWidget(
          errMsg: message,
          actions: [
            FilledButton.tonal(
              onPressed: isRunning ? null : widget.onManualPressed,
              child: Text(manualText),
            ),
            FilledButton.tonal(
              onPressed: isRunning ? null : widget.onRetryPressed,
              child: const Text('重试'),
            ),
          ],
        );
      },
    );
  }
}

class _CaptchaDialog extends StatefulWidget {
  const _CaptchaDialog({
    required this.pluginName,
    required this.captchaImageStream,
    required this.onReady,
    required this.onSubmit,
  });

  final String pluginName;
  final Stream<String?> captchaImageStream;
  final VoidCallback onReady;
  final Future<void> Function(String captchaCode) onSubmit;

  @override
  State<_CaptchaDialog> createState() => _CaptchaDialogState();
}

class _CaptchaDialogState extends State<_CaptchaDialog> {
  final ValueNotifier<String?> _captchaImageNotifier =
      ValueNotifier<String?>(null);
  final ValueNotifier<bool> _submittingNotifier = ValueNotifier<bool>(false);
  final TextEditingController _captchaCodeController = TextEditingController();
  late final StreamSubscription<String?> _imageSub;
  String _captchaCode = '';

  @override
  void initState() {
    super.initState();
    _imageSub = widget.captchaImageStream.listen((url) {
      if (!mounted || url == null) return;
      _captchaImageNotifier.value = url;
    });
    widget.onReady();
  }

  @override
  void dispose() {
    _imageSub.cancel();
    _captchaCodeController.dispose();
    _captchaImageNotifier.dispose();
    _submittingNotifier.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submittingNotifier.value) return;
    final captchaCode = _captchaCode.trim();
    if (captchaCode.isEmpty) {
      KazumiDialog.showToast(message: '请输入验证码');
      return;
    }
    _submittingNotifier.value = true;
    await widget.onSubmit(captchaCode);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '验证码验证',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.pluginName} 需要验证码验证',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              ValueListenableBuilder<String?>(
                valueListenable: _captchaImageNotifier,
                builder: (context, imageUrl, _) {
                  if (imageUrl == null) {
                    return const Column(
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在加载验证码图片...'),
                      ],
                    );
                  }
                  return ValueListenableBuilder<bool>(
                    valueListenable: _submittingNotifier,
                    builder: (context, isSubmitting, _) {
                      return Column(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.memory(
                              base64Decode(imageUrl.split(',').last),
                              height: 80,
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, _) =>
                                  const Text('图片解码失败'),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _captchaCodeController,
                            autofocus: true,
                            enabled: !isSubmitting,
                            onChanged: (value) => _captchaCode = value,
                            decoration: const InputDecoration(
                              labelText: '请输入验证码',
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: isSubmitting ? null : (_) => _submit(),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 20),
              ListenableBuilder(
                listenable: Listenable.merge([
                  _captchaImageNotifier,
                  _submittingNotifier,
                ]),
                builder: (context, _) {
                  final isImageLoading = _captchaImageNotifier.value == null;
                  final isSubmitting = _submittingNotifier.value;
                  final isDisabled = isImageLoading || isSubmitting;
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => KazumiDialog.dismiss(),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: isDisabled ? null : _submit,
                        child: isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('提交'),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AliasDialog extends StatefulWidget {
  const _AliasDialog({
    required this.aliases,
    required this.onAliasSelected,
    required this.onAliasesChanged,
  });

  final List<String> aliases;
  final ValueChanged<String> onAliasSelected;
  final VoidCallback onAliasesChanged;

  @override
  State<_AliasDialog> createState() => _AliasDialogState();
}

class _AliasDialogState extends State<_AliasDialog> {
  late final ValueNotifier<List<String>> aliasNotifier =
      ValueNotifier<List<String>>(List.from(widget.aliases));

  @override
  void dispose() {
    aliasNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 560,
        child: ValueListenableBuilder<List<String>>(
          valueListenable: aliasNotifier,
          builder: (context, aliasList, child) {
            return ListView(
              shrinkWrap: true,
              children: aliasList.asMap().entries.map((entry) {
                final index = entry.key;
                final alias = entry.value;
                return ListTile(
                  title: Text(alias),
                  trailing: IconButton(
                    onPressed: () {
                      KazumiDialog.show(
                        builder: (context) {
                          return AlertDialog(
                            title: const Text('删除确认'),
                            content: const Text('删除后无法恢复，确认要永久删除这个别名吗？'),
                            actions: [
                              TextButton(
                                onPressed: () {
                                  KazumiDialog.dismiss();
                                },
                                child: Text(
                                  '取消',
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline),
                                ),
                              ),
                              TextButton(
                                onPressed: () {
                                  KazumiDialog.dismiss();
                                  widget.aliases.removeAt(index);
                                  aliasNotifier.value =
                                      List.from(widget.aliases);
                                  widget.onAliasesChanged();
                                  if (widget.aliases.isEmpty) {
                                    Navigator.of(this.context).pop();
                                  }
                                },
                                child: const Text('确认'),
                              ),
                            ],
                          );
                        },
                      );
                    },
                    icon: Icon(Icons.delete),
                  ),
                  onTap: () => widget.onAliasSelected(alias),
                );
              }).toList(),
            );
          },
        ),
      ),
    );
  }
}
