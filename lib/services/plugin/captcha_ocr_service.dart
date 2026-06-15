import 'captcha_ocr_service_base.dart';
import 'captcha_ocr_service_unsupported.dart'
    if (dart.library.io) 'captcha_ocr_service_io.dart' as impl;

export 'captcha_ocr_service_base.dart';

CaptchaOcrService createCaptchaOcrService() => impl.createCaptchaOcrService();
