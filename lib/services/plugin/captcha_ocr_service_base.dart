class CaptchaOcrResult {
  const CaptchaOcrResult({
    required this.code,
    required this.rawText,
    required this.provider,
  });

  final String code;
  final String rawText;
  final String provider;
}

abstract class CaptchaOcrService {
  const CaptchaOcrService();

  bool get isEnabled;

  bool get shouldAutoSubmit => false;

  Future<CaptchaOcrResult?> recognizeDataUrl(String dataUrl);
}

class DisabledCaptchaOcrService extends CaptchaOcrService {
  const DisabledCaptchaOcrService();

  @override
  bool get isEnabled => false;

  @override
  Future<CaptchaOcrResult?> recognizeDataUrl(String dataUrl) async => null;
}
