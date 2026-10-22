# 01: التقاط التحميلات من المتصفح

المصدر: `IDMGCExt.crx`، النسخة 6.43.1، Manifest V3. الكود مضغوط (Closure Compiler) وفيه نصوص مشفّرة بـ ROT13. النسخة المرتّبة موجودة في `ext/pretty/background.js`، وأرقام الأسطر تحت مأخوذة منها.

## 1. شو بيعمل (السلوك)

### 1.1 الاتصال بالبرنامج (`Ba`، الأسطر 727-748)
- أول شي بتحاول الإضافة تفتح WebSocket على `ws://127.0.0.1:1001/?cid=<client>&rnd=<random>`، باسم subprotocol هو `plugin.v3.internetdownloadmanager.com`.
- إذا ما زبط، بتستخدم Native Messaging: `chrome.runtime.connectNative("com.tonec.idm")`، وهاد بيشغّل `IDMMsgHost.exe` اللي اسمه مسجّل بالـ Registry.
- إذا انقطع الاتصال بتعيد المحاولة، والانتظار بيزيد كل مرة (`5000ms × عدد المحاولات`) لحد 120 دورة.
- بتبعت heartbeat كل 15 ثانية (`Ma`).
- لما يفتح الاتصال، بتبعت للبرنامج نسخة المتصفح ولغته (`Na`).

### 1.2 الإعدادات بتجي من البرنامج مش من الإضافة
- قواعد الالتقاط موجودة في `this.j[...]`، وأغلبها regex بيبعتها البرنامج:
  - `j[1]`: امتدادات الملفات اللي بتنلقط.
  - `j[9]`: مواقع مستثناة.
  - `j[19]`: روابط مستثناة.
  - `j[17]`: روابط بتتحوّل لصفحة `captured.html` من خلال `declarativeNetRequest`.
- **يعني الإضافة "غبية" والقرار عند التطبيق.** هاد تصميم منيح ومنعتمده.

### 1.3 مسار 1: التقاط تحميل بدأه المتصفح (`qb` و`rb` و`lc`، الأسطر 1105-1189)
1. `downloads.onCreated`: المتصفح بلّش ينزّل، والإضافة **بتوقّفه فوراً** (`downloads.pause`).
2. `downloads.onDeterminingFilename`: بتفحص الامتداد مقابل `j[1]`، وبتتأكد إن الموقع والرابط مش مستثنيين.
   - إذا ما تطابق: `downloads.resume`، وبيكمّل المتصفح التحميل عادي.
3. إذا تطابق: بتجمّع الكوكيز للرابط (`U` ← `chrome.cookies`)، وبتبعت للبرنامج رسالة نوعها `13` وفيها:
   `url, final url, file name, totalBytes, mime, referrer, cookies, userAgent`
4. إذا البرنامج قبل: `downloads.cancel`، وتحميل المتصفح بيتلغى وبيكمّله البرنامج.
   إذا رفض أو فشل الإرسال: `downloads.resume`.

### 1.4 مسار 2: مراقبة الطلبات (`webRequest`، الأسطر 562-596 و2662-2721)
- بتراقب `onBeforeRequest`، و`onBeforeSendHeaders` (لحتى تاخد الهيدرز الحقيقية مع الكوكيز)، و`onHeadersReceived`.
- من الرد بتقرأ `Content-Type` و`Content-Disposition` والحالة.
- `Hc()` بتقرر شو بيصير: 1 = تجاهل، 3 أو 4 = لقطه وابعته للبرنامج.
- هيك بتلتقط ملفات الفيديو والصوت اللي بتنطلب بـ XHR أو media. وبتحسب hash للرابط مع الهيدرز (djb2) لحتى ما يتكرر نفس الملف.

### 1.5 قائمة الكليك يمين (`Ea`، السطر 986)
- "Download with IDM" على رابط أو صورة أو فيديو، وكمان "Download all links".
- بتبعت رسالة `14` وفيها `url, referrer, pageUrl, cookies, userAgent`.

### 1.6 زر التحميل فوق الفيديو
- `content.js` بينحقن بكل صفحة (`all_frames`، `document_start`).
- `document.js` بينحقن بالصفحة نفسها، ووظيفته يلتقط روابط الوسائط من المشغّلات.
- **هاد الجزء لسا ما حللناه بالتفصيل.**

## 2. بروتوكول الرسائل (خاص بـ IDM، مش رح ننسخه)
نص بالشكل `MSG#<seq>#<type>#<subtype>#<flags>:<a1>:<a2>,<field>=<len>:<str>,<field>=<num>;`
- كل حقل إله رقم: `6` = url، `50` = referrer، `51` = cookies، `54` = userAgent، `100` = filename، `103` = size، `127` = mime.

## 3. القرارات لنسختنا على الماك
| IDM | نسختنا |
|---|---|
| WebSocket على `127.0.0.1:1001` وNative Messaging كبديل | **Native Messaging بس** (أأمن، لأنه ما بيفتح port لأي برنامج على الجهاز) |
| بروتوكول نصي خاص | JSON (هيك بيشتغل Native Messaging أصلاً) |
| Chrome وEdge وFirefox | Chrome وEdge وBrave، وSafari Web Extension (بتنضاف للتطبيق نفسه) |
| القواعد بتجي من التطبيق | نفس الفكرة: التطبيق بيبعت `captureRules` للإضافة لما تتصل |

### رسائل نسختنا (مسودة)
```json
// extension → app
{"type":"hello","browser":"chrome","version":"1.0.0","lang":"ar"}
{"type":"capture","url":"…","finalUrl":"…","filename":"…","size":123,"mime":"…",
 "referrer":"…","cookies":"a=b; c=d","userAgent":"…","source":"download|request|menu"}
// app → extension
{"type":"rules","extensions":["zip","dmg","mp4"],"excludeHosts":[],"minSize":0}
{"type":"captureResult","id":"…","accepted":true}
```

## 4. أسئلة لسا مفتوحة
- [ ] `Hc()`: كيف بالضبط بتقرر تلتقط طلب XHR أو media.
- [ ] `content.js` و`document.js`: كيف بيظهر زر "Download this video".
- [ ] شو الإعدادات الافتراضية للامتدادات (لازم نشوف `IDMan.exe` أو `defexclist.txt`).
