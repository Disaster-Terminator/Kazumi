import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/captcha_ocr_service_base.dart';

CaptchaOcrService createCaptchaOcrService() {
  final provider = Platform.environment['KAZUMI_CAPTCHA_OCR_PROVIDER'];
  if (provider == 'ddddocr-uv') {
    return const UvDdddOcrCaptchaOcrService();
  }
  return const DisabledCaptchaOcrService();
}

class UvDdddOcrCaptchaOcrService extends CaptchaOcrService {
  const UvDdddOcrCaptchaOcrService();

  static const String _pythonScript = r'''
import pathlib
import re
import sys

import ddddocr

img = pathlib.Path(sys.argv[1]).read_bytes()
ocr = ddddocr.DdddOcr(show_ad=False)
text = ocr.classification(img, png_fix=True)
print(re.sub(r"\s+", "", text))
''';

  @override
  bool get isEnabled => true;

  @override
  bool get shouldAutoSubmit =>
      Platform.environment['KAZUMI_CAPTCHA_OCR_AUTOSUBMIT'] == '1';

  @override
  Future<CaptchaOcrResult?> recognizeDataUrl(String dataUrl) async {
    final commaIndex = dataUrl.indexOf(',');
    if (commaIndex < 0) {
      KazumiLogger().w('[CaptchaOcrService] invalid data URL');
      return null;
    }

    Directory? tempDir;
    try {
      final bytes = base64Decode(dataUrl.substring(commaIndex + 1));
      tempDir = await Directory.systemTemp.createTemp('kazumi-captcha-');
      final imageFile =
          File('${tempDir.path}${Platform.pathSeparator}captcha.png');
      await imageFile.writeAsBytes(bytes, flush: true);
      final uvExecutable =
          Platform.environment['KAZUMI_CAPTCHA_OCR_UV'] ?? 'uv';

      final result = await Process.run(
        uvExecutable,
        [
          'run',
          '--with',
          'ddddocr',
          'python',
          '-c',
          _pythonScript,
          imageFile.path,
        ],
      ).timeout(const Duration(seconds: 45));

      if (result.exitCode != 0) {
        KazumiLogger().w(
          '[CaptchaOcrService] ddddocr failed: ${result.stderr}',
          forceLog: true,
        );
        return null;
      }

      final rawText = result.stdout.toString().trim();
      final code = _normalizeLikelyNumericCaptcha(rawText);
      if (code.isEmpty) {
        KazumiLogger().w(
          '[CaptchaOcrService] ddddocr returned unusable text: $rawText',
          forceLog: true,
        );
        return null;
      }

      KazumiLogger().i(
        '[CaptchaOcrService] ddddocr recognized captcha: raw=$rawText, code=$code',
        forceLog: true,
      );
      return CaptchaOcrResult(
        code: code,
        rawText: rawText,
        provider: 'ddddocr-uv',
      );
    } on TimeoutException {
      KazumiLogger().w('[CaptchaOcrService] ddddocr timed out');
      return null;
    } catch (error) {
      KazumiLogger().w('[CaptchaOcrService] ddddocr error: $error');
      return null;
    } finally {
      try {
        await tempDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  String _normalizeLikelyNumericCaptcha(String rawText) {
    final compact = rawText.replaceAll(RegExp(r'\s+'), '');
    final normalized = compact
        .replaceAll(RegExp('[oO]'), '0')
        .replaceAll(RegExp('[iIlL]'), '1')
        .replaceAll(RegExp('[sS]'), '5')
        .replaceAll(RegExp('[bB]'), '8');
    if (normalized.length >= 4 &&
        normalized.length <= 6 &&
        RegExp(r'^[0-9]+$').hasMatch(normalized)) {
      return normalized;
    }
    if (Platform.environment['KAZUMI_CAPTCHA_OCR_ALLOW_ALPHANUMERIC'] == '1' &&
        compact.length >= 4 &&
        compact.length <= 6 &&
        RegExp(r'^[0-9A-Za-z]+$').hasMatch(compact)) {
      return compact;
    }
    return '';
  }
}
