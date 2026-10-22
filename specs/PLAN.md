# خطة: مدير تحميل لنظام macOS بخصائص IDM

## القاعدة الأساسية (Clean-room)

- **منفهم السلوك، وما مننسخ الكود.** من IDM بنطلع *مواصفات* (شو بيعمل، وإيمتى، وليش)، وبعدها منكتب الكود من الصفر.
- ما منستخدم أي شي من IDM: لا كود، ولا أيقونات، ولا صور، ولا نصوص، ولا الاسم، ولا بروتوكول التواصل الخاص فيهم.
- ما منلمس أي شي إله علاقة بالترخيص أو الحماية (`CProtection`, `CSignVerifier`, `CHardwareSNs`).

---

## المرحلة 1: الفهم (Reverse engineering → مواصفات)

كل جزء بيطلع منه ملف مواصفات في `specs/`:

| # | الجزء | المصدر في IDM | المخرَج |
|---|---|---|---|
| 1.1 | إضافة المتصفح: كيف بتلقط التحميلات وبتسلّمها للبرنامج | `IDMGCExt.crx` (JS) | `specs/01-browser-capture.md` ✅ بدأ |
| 1.2 | محرك التحميل: تقسيم الملف، تعدد الاتصالات، التقسيم الديناميكي، الاستكمال | `IDMan.exe`: `CDownload`, `CFragmentsList`, `CMaxConnNumbers`, `CInetConnector` | `specs/02-download-engine.md` ✅ الأساس |
| 1.3 | البروتوكولات: HTTP/HTTPS، FTP، بروكسي، كوكيز، تسجيل دخول | `CSocks`, `CFTPProxyConnection`, `CWebAuthorization`, `CCookieMonster` | `specs/03-protocols.md` |
| 1.4 | الفيديو: HLS (m3u8)، DASH، دمج الصوت مع الصورة | `CM3UParser`, `CMp4DashReader`, `CSidxParser`, `CTSReader` | `specs/04-video-grabber.md` |
| 1.5 | الطوابير والجدولة وتحديد السرعة | `CDownloadQueue`, `CSchedulerInfo`, `CSpeedLimiter` | `specs/05-queues-scheduler.md` |
| 1.6 | التخزين: قاعدة البيانات، الملفات المؤقتة، التصنيفات | `CIDMDatabase`, `DwnlData`, `IDMFType.dat` | `specs/06-storage.md` |
| 1.7 | Site Grabber (سحب موقع كامل) | `CIDMSpider` | `specs/07-site-grabber.md` |
| 1.8 | الواجهة وتجربة الاستخدام | نوافذ وقوائم من الـ resources | `specs/08-ui.md` |

الأدوات: REA + Ghidra للكود المترجم، وقراءة مباشرة لملفات الجافاسكربت.

---

## المرحلة 2: البناء على الماك

### التقنية المقترحة

- **التطبيق:** Swift 6 و SwiftUI، تطبيق Mac أصلي (موجود عندك Xcode 27).
- **محرك التحميل:** مكتبة Swift مستقلة (Swift Package) فيها منطق التقسيم والاتصالات، ومنفصلة عن الواجهة لحتى نقدر نختبرها لحالها.
- **الشبكة:** `URLSession` مع طلبات `Range`، بجلسة لكل اتصال. وFTP لاحقاً بمكتبة منفصلة.
- **التخزين:** SQLite (من خلال GRDB أو SwiftData).
- **الفيديو:** قارئ m3u8 وDASH من عنا، والدمج بـ `AVFoundation` أو `ffmpeg`.
- **إضافة المتصفح:** Chrome وEdge (Manifest V3) وSafari Web Extension، بتحكي مع التطبيق بـ Native Messaging وبروتوكول JSON بسيط من تصميمنا.

### ترتيب البناء (كل خطوة بتشتغل وبتنفحص قبل اللي بعدها)

1. **محرك تحميل CLI:** ملف واحد، تقسيم لـ N قطع، تنزيل متوازي، تجميع، استكمال بعد الانقطاع. مع اختبارات.
2. **التقسيم الديناميكي:** لما قطعة تخلص، بتاخد نص القطعة الأبطأ (هاد سر سرعة IDM).
3. **واجهة SwiftUI:** قائمة التحميلات، التقدم، إيقاف واستكمال، والتصنيفات.
4. ✅ **التخزين والطوابير والجدولة وحد السرعة.**
5. ✅ **إضافة كروم وNative Messaging:** التقاط التحميلات من المتصفح.
6. **التقاط الفيديو:** HLS وDASH.
7. **Safari، وSite Grabber، وFTP.**
8. **التغليف:** توقيع التطبيق، notarization، وملف DMG.

---

## سجل النتائج

| النتيجة | الدليل | الثقة |
|---|---|---|
| الـ installer عبارة عن برنامج صغير + 192 ملف مضغوط بـ zlib وراه، والأسماء جاية من سكريبت `<DEST>` | تفكيك الملف | ملاحظة مباشرة |
| `IDMan.exe`: C++ مع MFC، Visual Studio 2008، 32-bit، مش مضغوط | PE headers، RTTI | ملاحظة مباشرة |
| HTTP مكتوب من الصفر فوق sockets، وOpenSSL بيتحمّل وقت التشغيل | strings، imports | استنتاج قوي |
| التحميل المتعدد بيستخدم `Range: bytes=a-b` | strings | ملاحظة مباشرة |
| الإضافة بتحاول WebSocket على `127.0.0.1:1001` أول، وإذا ما زبط بتستخدم Native Messaging (`com.tonec.idm`) | background.js:191، 727-748 | ملاحظة مباشرة |
