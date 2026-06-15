import 'dart:async';

import 'package:webview_windows/webview_windows.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/services/network/proxy_utils.dart';
import 'package:kazumi/webview/captcha/captcha_webview_controller.dart';

class CaptchaWebviewWindowsImpl
    extends CaptchaWebviewController<WebviewController> {
  HeadlessWebview? _headlessWebview;
  final List<StreamSubscription> _subscriptions = [];
  String _currentCaptchaImageXpath = '';
  String _currentInputXpath = '';
  String _currentPageUrl = '';
  String _buttonXpath = '';
  String? _customScript;

  @override
  Future<void> init() async {
    await _setupProxy();
    _headlessWebview ??= HeadlessWebview();
    await _headlessWebview!.run();
    await _headlessWebview!.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);

    // Listen for messages from JavaScript via window.chrome.webview.postMessage
    _subscriptions.add(
      _headlessWebview!.webMessage.listen(_onWebMessage),
    );

    // Inject the active verification script when navigation completes.
    _subscriptions.add(
      _headlessWebview!.loadingState.listen((state) async {
        if (state == LoadingState.navigationCompleted) {
          logEventController
              .add('[Captcha WebView] Navigation completed: $_currentPageUrl');
          if (_currentCaptchaImageXpath.isNotEmpty) {
            await _injectCaptchaScript();
          } else if (_buttonXpath.isNotEmpty) {
            await _injectButtonClickScript(_buttonXpath);
          } else if (_customScript != null) {
            await _injectCustomScript(_customScript!);
          }
        }
      }),
    );

    // After a navigation, detect verification completion for captcha-image
    // and automated flows that marked a verification action as clicked.
    _subscriptions.add(
      _headlessWebview!.loadingState.listen((state) async {
        if (state == LoadingState.navigationCompleted) {
          if (captchaWasFound) {
            final present = await _isCaptchaPresent();
            if (!present && !captchaDisappearedController.isClosed) {
              logEventController
                  .add('[Captcha WebView] Captcha gone after navigation');
              captchaWasFound = false;
              captchaDisappearedController.add(null);
            }
          }
          if (buttonWasClicked && !captchaDisappearedController.isClosed) {
            logEventController.add(
                '[Captcha WebView] Button click → page navigated, verification done');
            buttonWasClicked = false;
            captchaDisappearedController.add(null);
          }
        }
      }),
    );

    initEventController.add(true);
  }

  void _onWebMessage(dynamic message) {
    final msg = message.toString();
    final logMsg = msg.startsWith('captchaImage:')
        ? 'captchaImage:<${msg.length} chars>'
        : msg;
    logEventController.add('[Captcha WebView] WM: $logMsg');
    if (msg.startsWith('captchaImage:')) {
      final src = msg.replaceFirst('captchaImage:', '');
      if (src.isNotEmpty && !captchaImageFoundController.isClosed) {
        captchaWasFound = true;
        logEventController.add(
          '[Captcha WebView] Captcha image event dispatch: '
          '${src.length} chars, hasListener='
          '${captchaImageFoundController.hasListener}',
        );
        captchaImageFoundController.add(src);
      } else {
        logEventController.add(
          '[Captcha WebView] Captcha image event dropped: '
          'empty=${src.isEmpty}, closed=${captchaImageFoundController.isClosed}',
        );
      }
    } else if (msg.startsWith('buttonClicked:')) {
      buttonWasClicked = true;
      logEventController.add('[Captcha WebView] Button clicked flag set');
    } else if (msg.startsWith('captchaGone:')) {
      buttonWasClicked = false;
      if (!captchaDisappearedController.isClosed) {
        captchaDisappearedController.add(null);
      }
    } else if (msg.startsWith('captchaLog:')) {
      logEventController
          .add('[Captcha WebView JS] ${msg.replaceFirst('captchaLog:', '')}');
    }
  }

  Future<bool> _isCaptchaPresent() async {
    if (_currentCaptchaImageXpath.isEmpty || _headlessWebview == null) {
      return false;
    }
    final escaped = _currentCaptchaImageXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    try {
      final result = await _headlessWebview!.executeScript('''
(function() {
  try {
    var r = document.evaluate('$escaped', document, null,
      XPathResult.FIRST_ORDERED_NODE_TYPE, null);
    return r.singleNodeValue ? 'present' : 'absent';
  } catch(e) { return 'absent'; }
})();
''');
      return result?.toString().contains('present') ?? false;
    } catch (e) {
      KazumiLogger().d('[Captcha WebView] _isCaptchaPresent error: $e');
      return false;
    }
  }

  Future<void> _injectCaptchaScript() async {
    if (_currentCaptchaImageXpath.isEmpty) return;
    final escapedXpath = _currentCaptchaImageXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    final escapedInputXpath =
        _currentInputXpath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

    final script = '''
(function() {
  function _log(message) {
    try {
      window.chrome.webview.postMessage('captchaLog:' + String(message));
    } catch(e) {}
  }

  function _describeNode(node) {
    if (!node) return 'node=null';
    return 'tag=' + node.tagName +
      ', src=' + (node.src || '') +
      ', currentSrc=' + (node.currentSrc || '') +
      ', complete=' + node.complete +
      ', natural=' + node.naturalWidth + 'x' + node.naturalHeight +
      ', client=' + node.clientWidth + 'x' + node.clientHeight;
  }

  function _describePageSummary() {
    try {
      var images = document.images ? document.images.length : 0;
      var iframes = document.querySelectorAll('iframe').length;
      return 'readyState=' + document.readyState +
        ', title=' + document.title +
        ', images=' + images +
        ', iframes=' + iframes;
    } catch(e) {
      return 'pageSummaryError=' + e.name + ': ' + e.message;
    }
  }

  var _captchaXpath = '$escapedXpath';
  var _inputXpath = '$escapedInputXpath';
  var _captchaPoller = null;
  var _disappearObserver = null;
  var _lastNodeState = '';
  var _pollCount = 0;
  var _lastNoNodeLogAt = 0;

  _log('CaptchaScript injected on ' + window.location.href);
  _log('Captcha XPath: ' + _captchaXpath);
  if (_inputXpath) _log('Captcha input XPath: ' + _inputXpath);

  function _evalXpath() {
    try {
      var result = document.evaluate(
        _captchaXpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return result.singleNodeValue;
    } catch(e) {
      _log('Captcha XPath evaluation failed: ' + e.message);
      return null;
    }
  }

  function _startDisappearMonitor() {
    if (_disappearObserver) return;
    _disappearObserver = new MutationObserver(function() {
      if (!_evalXpath()) {
        _disappearObserver.disconnect();
        _disappearObserver = null;
        window.chrome.webview.postMessage('captchaGone:');
      }
    });
    _disappearObserver.observe(document.documentElement,
      { childList: true, subtree: true, attributes: true });
  }

  function _captureAsBase64(imgNode, callback) {
    function doCapture() {
      try {
        var canvas = document.createElement('canvas');
        canvas.width = imgNode.naturalWidth || imgNode.width || 100;
        canvas.height = imgNode.naturalHeight || imgNode.height || 40;
        var ctx = canvas.getContext('2d');
        ctx.drawImage(imgNode, 0, 0);
        var dataUrl = canvas.toDataURL('image/png');
        _log('Captcha canvas capture succeeded: ' +
          canvas.width + 'x' + canvas.height + ', bytes=' + dataUrl.length);
        callback(dataUrl);
      } catch(e) {
        _log('Captcha canvas capture failed: ' + e.name + ': ' + e.message);
        callback(null);
      }
    }
    if (imgNode.complete && imgNode.naturalWidth > 0) {
      _log('Captcha image already loaded before capture');
      doCapture();
    } else {
      _log('Captcha image not ready, waiting for load/error: ' +
        _describeNode(imgNode));
      imgNode.addEventListener('load', function() {
        _log('Captcha image load event: ' + _describeNode(imgNode));
        doCapture();
      }, { once: true });
      imgNode.addEventListener('error', function(event) {
        _log('Captcha image error event: ' + _describeNode(imgNode));
        callback(null);
      }, { once: true });
    }
  }

  function _checkForCaptcha() {
    _pollCount += 1;
    var node = _evalXpath();
    if (node) {
      var state = _describeNode(node);
      if (state !== _lastNodeState) {
        _lastNodeState = state;
        _log('Captcha node found: ' + state);
      }
      _captureAsBase64(node, function(dataUrl) {
        if (dataUrl) {
          window.chrome.webview.postMessage('captchaImage:' + dataUrl);
        } else {
          _log('Captcha node exists but no data URL produced');
        }
      });
      _startDisappearMonitor();
      return true;
    }
    var now = Date.now();
    if (_pollCount === 1 || now - _lastNoNodeLogAt >= 3000) {
      _lastNoNodeLogAt = now;
      _log('Captcha node not found yet: poll=' + _pollCount +
        ', summary=' + _describePageSummary());
    }
    return false;
  }

  function _triggerInputFocus() {
    if (!_inputXpath) {
      return false;
    }
    
    try {
      var inputResult = document.evaluate(_inputXpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      var inputEl = inputResult.singleNodeValue;
      
      if (inputEl) {
        if (typeof \$ !== 'undefined' && \$) {
          \$(inputEl).trigger('focus');
          return true;
        } else if (typeof jQuery !== 'undefined' && jQuery) {
          jQuery(inputEl).trigger('focus');
          return true;
        } else {
          inputEl.focus();
          return true;
        }
      }
    } catch(e) {
      window.chrome.webview.postMessage('captchaLog:Failed to trigger input focus - ' + e.message);
    }
    return false;
  }

  // If inputXpath is provided, trigger focus to load captcha (some sites require this)
  _triggerInputFocus();
  
  if (!_checkForCaptcha()) {
    _captchaPoller = setInterval(function() {
      if (_checkForCaptcha()) {
        clearInterval(_captchaPoller);
        _captchaPoller = null;
      }
    }, 500);
  }
})();
''';

    try {
      await _headlessWebview?.executeScript(script);
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] inject script error: $e');
    }
  }

  @override
  Future<void> loadPage(String url, String captchaXpath,
      {String? inputXpath}) async {
    _currentCaptchaImageXpath = captchaXpath;
    _currentInputXpath = inputXpath ?? '';
    _buttonXpath = '';
    _customScript = null;
    buttonWasClicked = false;
    _currentPageUrl = url;
    captchaWasFound = false;
    await _headlessWebview?.loadUrl(url);
  }

  @override
  Future<void> loadPageForButtonClick(String url, String buttonXpath) async {
    _currentCaptchaImageXpath = '';
    _buttonXpath = buttonXpath;
    _customScript = null;
    buttonWasClicked = false;
    _currentPageUrl = url;
    captchaWasFound = false;
    await _headlessWebview?.loadUrl(url);
  }

  @override
  Future<void> loadPageForCustomScript(String url, String script) async {
    _currentCaptchaImageXpath = '';
    _currentInputXpath = '';
    _buttonXpath = '';
    _customScript = script;
    buttonWasClicked = false;
    _currentPageUrl = url;
    captchaWasFound = false;
    await _headlessWebview?.loadUrl(url);
  }

  Future<void> _injectCustomScript(String script) async {
    logEventController.add('[Captcha WebView] Injecting custom script');
    final wrappedScript = '''
(function() {
  try {
    window.KazumiCaptcha = {
      log: function(message) {
        window.chrome.webview.postMessage('captchaLog:' + String(message));
      },
      clicked: function() {
        window.chrome.webview.postMessage('buttonClicked:');
      },
      done: function() {
        window.chrome.webview.postMessage('captchaGone:');
      },
      fail: function(message) {
        window.chrome.webview.postMessage('captchaLog:Custom script failed: ' + String(message));
      }
    };
    window.KazumiCaptcha.log('CustomScript injected on ' + window.location.href);
    if (!${script.trim().isEmpty ? 'false' : 'true'}) {
      window.KazumiCaptcha.fail('empty captchaScript');
      return;
    }
    var __kazumiResult = (function() {
$script
    })();
    if (__kazumiResult === true) {
      window.KazumiCaptcha.done();
    }
  } catch(e) {
    try { window.KazumiCaptcha.fail(e && e.message ? e.message : e); } catch(e2) {}
  }
})();
''';
    try {
      final result = await _headlessWebview?.executeScript(wrappedScript);
      logEventController
          .add('[Captcha WebView] Custom script execute result: $result');
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] injectCustomScript error: $e');
      logEventController
          .add('[Captcha WebView] Custom script inject error: $e');
    }
  }

  Future<void> _injectButtonClickScript(String buttonXpath) async {
    final escaped = buttonXpath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final script = '''
(function() {
  window.chrome.webview.postMessage('captchaLog:ButtonClickScript injected on ' + window.location.href);

  var _xpath = '$escaped';
  var _clicked = false;
  var _poller = null;
  var _disappearObserver = null;

  function evalXpath() {
    try {
      var r = document.evaluate(_xpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return r.singleNodeValue;
    } catch(e) { return null; }
  }

  function startDisappearMonitor() {
    if (_disappearObserver) return;
    _disappearObserver = new MutationObserver(function() {
      if (!evalXpath()) {
        _disappearObserver.disconnect();
        _disappearObserver = null;
        window.chrome.webview.postMessage('captchaGone:');
      }
    });
    _disappearObserver.observe(document.documentElement,
      { childList: true, subtree: true, attributes: true });
  }

  function checkAndClick() {
    var btn = evalXpath();
    if (btn && !_clicked) {
      _clicked = true;
      btn.click();
      window.chrome.webview.postMessage('buttonClicked:');
      startDisappearMonitor();
      return true;
    }
    return false;
  }

  if (!checkAndClick()) {
    _poller = setInterval(function() {
      if (checkAndClick()) { clearInterval(_poller); _poller = null; }
    }, 500);
  }
})();
''';
    try {
      await _headlessWebview?.executeScript(script);
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] injectButtonClickScript error: $e');
    }
  }

  @override
  Future<void> submitCaptchaInteract(
      String captchaCode, String inputXpath, String buttonXpath) async {
    logEventController
        .add('[Captcha WebView] Filling input and clicking button');
    final escapedCode =
        captchaCode.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final escapedInput =
        inputXpath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final escapedButton =
        buttonXpath.replaceAll('\\', '\\\\').replaceAll("'", "\\'");
    final escapedCaptcha = _currentCaptchaImageXpath
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    final script = '''
(function() {
  function evalXpath(xpath) {
    if (!xpath) return null;
    try {
      var r = document.evaluate(xpath, document, null,
        XPathResult.FIRST_ORDERED_NODE_TYPE, null);
      return r.singleNodeValue;
    } catch(e) { return null; }
  }
  function log(message) {
    window.chrome.webview.postMessage('captchaLog:' + message);
  }
  function textOf(node) {
    return [
      node.id || '',
      node.name || '',
      node.className || '',
      node.placeholder || '',
      node.title || '',
      node.getAttribute('aria-label') || '',
      node.textContent || '',
      node.value || ''
    ].join(' ').toLowerCase();
  }
  function scoreInput(input, captchaNode) {
    var text = textOf(input);
    var score = 0;
    if (/验证码|verify|captcha|code|validate|yzm/.test(text)) score += 100;
    var type = (input.type || '').toLowerCase();
    if (!type || /text|search|tel|number/.test(type)) score += 20;
    if (input.disabled || input.readOnly) score -= 200;
    if (captchaNode && input.compareDocumentPosition(captchaNode) & Node.DOCUMENT_POSITION_PRECEDING) {
      score += 5;
    }
    return score;
  }
  function scoreButton(button) {
    var text = textOf(button);
    var score = 0;
    if (/验证|提交|确认|搜索|submit|verify|confirm|search/.test(text)) score += 100;
    if (button.disabled) score -= 200;
    return score;
  }
  function bestByScore(nodes, scorer) {
    var best = null;
    var bestScore = -9999;
    nodes.forEach(function(node) {
      var score = scorer(node);
      if (score > bestScore) {
        best = node;
        bestScore = score;
      }
    });
    return bestScore > 0 ? best : null;
  }
  function surroundingContainer(node) {
    var current = node;
    for (var i = 0; current && i < 4; i += 1) {
      if (current.querySelectorAll) return current;
      current = current.parentElement;
    }
    return document;
  }
  function findFallbackInput(captchaNode) {
    var containers = [];
    if (captchaNode) {
      var current = captchaNode.parentElement;
      for (var i = 0; current && i < 5; i += 1) {
        containers.push(current);
        current = current.parentElement;
      }
    }
    containers.push(document);
    for (var c = 0; c < containers.length; c += 1) {
      var inputs = Array.prototype.slice.call(
        containers[c].querySelectorAll('input:not([type="hidden"]), textarea'));
      var matched = bestByScore(inputs, function(input) {
        return scoreInput(input, captchaNode);
      });
      if (matched) return matched;
    }
    return null;
  }
  function findFallbackButton(inputEl, captchaNode) {
    var containers = [];
    var anchor = inputEl || captchaNode;
    if (anchor) {
      var current = anchor.parentElement;
      for (var i = 0; current && i < 5; i += 1) {
        containers.push(current);
        current = current.parentElement;
      }
    }
    containers.push(document);
    for (var c = 0; c < containers.length; c += 1) {
      var buttons = Array.prototype.slice.call(
        containers[c].querySelectorAll('button, input[type="button"], input[type="submit"], a'));
      var matched = bestByScore(buttons, scoreButton);
      if (matched) return matched;
    }
    return null;
  }
  var captchaEl = evalXpath('$escapedCaptcha');
  var inputEl = evalXpath('$escapedInput');
  if (!inputEl) {
    inputEl = findFallbackInput(captchaEl);
    if (inputEl) {
      log('Input fallback matched: ' + textOf(inputEl));
    }
  }
  if (inputEl) {
    inputEl.focus();
    var nativeInput = Object.getOwnPropertyDescriptor(
      window.HTMLInputElement.prototype, 'value');
    nativeInput.set.call(inputEl, '$escapedCode');
    inputEl.dispatchEvent(new Event('input', { bubbles: true }));
    inputEl.dispatchEvent(new Event('change', { bubbles: true }));
    log('Input filled');
  } else {
    log('Input element not found');
  }
  var btnEl = evalXpath('$escapedButton');
  if (!btnEl) {
    btnEl = findFallbackButton(inputEl, captchaEl);
    if (btnEl) {
      log('Button fallback matched: ' + textOf(btnEl));
    }
  }
  if (btnEl) {
    btnEl.click();
    log('Button clicked');
  } else {
    log('Button element not found');
  }
})();
''';
    try {
      await _headlessWebview?.executeScript(script);
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] submitCaptchaInteract error: $e');
    }
  }

  @override
  Future<String> getCookieString(String pageUrl) async {
    try {
      final result = await _headlessWebview?.getCookies(pageUrl);
      return result ?? '';
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] getCookieString error: $e');
      return '';
    }
  }

  @override
  Future<void> unloadPage() async {
    try {
      await _headlessWebview
          ?.executeScript("window.location.href = 'about:blank';");
    } catch (e) {
      KazumiLogger().d('[Captcha WebView] unloadPage skipped: $e');
    }
  }

  @override
  void dispose() {
    _currentCaptchaImageXpath = '';
    _currentInputXpath = '';
    _buttonXpath = '';
    _customScript = null;
    buttonWasClicked = false;
    _currentPageUrl = '';
    for (final s in _subscriptions) {
      try {
        s.cancel();
      } catch (_) {}
    }
    _subscriptions.clear();
    try {
      captchaImageFoundController.close();
      captchaDisappearedController.close();
      initEventController.close();
      logEventController.close();
    } catch (_) {}
    _headlessWebview?.dispose();
    _headlessWebview = null;
  }

  Future<void> _setupProxy() async {
    final bool proxyEnable = GStorage.getSetting(SettingsKeys.proxyEnable);
    if (!proxyEnable) return;

    final String proxyUrl = GStorage.getSetting(SettingsKeys.proxyUrl);
    final formattedProxy = ProxyUtils.getFormattedProxyUrl(proxyUrl);
    if (formattedProxy == null) return;

    try {
      await WebviewController.initializeEnvironment(
        additionalArguments: '--proxy-server=$formattedProxy',
      );
      KazumiLogger().i('[Captcha WebView] 代理设置成功 $formattedProxy');
    } catch (e) {
      KazumiLogger().e('[Captcha WebView] 设置代理失败 $e');
    }
  }
}
