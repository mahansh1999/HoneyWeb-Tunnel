<div dir="rtl">

# HoneyWeb Tunnel

تانل معکوس سریع و پایدار بین سرور ورودی (ایران) و سرور خروجی (خارج)، نوشته‌شده با Go و نگهداری‌شده توسط HoneyWeb. [English](README.md)

> Based on BackPack by Amin Mohammadi (AminMGMT)
> https://github.com/AminMGMT/BackPack
>
> HoneyWeb Tunnel نسخه تغییریافته BackPack است و تحت مجوز AGPL-3.0 منتشر می‌شود. جزئیات در `LICENSE`، `NOTICE` و `TRADEMARK.md` است. بخش انتقال داده BackPack از Backhaul ساخته Musixal گرفته شده است (AGPL-3.0).

## نصب (دو دستور)

**۱. روی سرور ایران** (با root):

```bash
bash <(curl -fsSL https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/iran.sh)
```

اسکریپت این موارد را می‌پرسد و بقیه را خودش نصب می‌کند:
- **Transport:** نحوه ارتباط دو سرور. `wssmux` و `tcpmux` گزینه‌های HoneyWeb Recommended هستند.
- **پورت تانل:** پورتی روی سرور ایران که سرور خارج به آن وصل می‌شود.
- **پورت‌های کاربر:** پورت‌هایی که کاربران به آن وصل می‌شوند. مثال‌ها:
  - `443`: به همان پورت 443 روی سرور خارج می‌رود.
  - `443=8443`: به پورت 8443 روی سرور خارج می‌رود.
  - `443,8443`: چند پورت با هم.

در پایان یک **لینک نصب** (`hwt://...`) و یک دستور آماده چاپ می‌کند.

**۲. روی سرور خارج** (با root) همان دستور را اجرا کنید. چیزی نمی‌پرسد؛ خودش نصب و وصل می‌شود:

```bash
bash <(curl -fsSL https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/kharej.sh) hwt://...
```

- لینک آدرس ایران، Transport، پورت‌ها، ظرفیت و Token را دارد، همراه یک Checksum. لینکی که نصفه کپی شده باشد پذیرفته نمی‌شود.
- **ظرفیت پیش‌فرض** (از اوج واقعی Production خودمان):
  - `wssmux`: Pool برابر 896، یعنی 7168 اتصال هم‌زمان.
  - `tcpmux` و `wsmux`: Pool برابر 512، یعنی 4096 اتصال هم‌زمان.
  - عدد دلخواه: `iran.sh --pool N`.
- **لینک را خصوصی نگه دارید.** Token تانل داخل آن است.

| Transport | توضیح |
|---|---|
| `wssmux` | WebSocket + TLS، چندگانه (Recommended) |
| `tcpmux` | TCP، چندگانه (Recommended) |
| `wsmux` | WebSocket، چندگانه، بدون TLS |
| `tcp`، `ws`، `wss` | یک اتصال تانل برای هر کاربر |
| `stealth` | TCP با رمزنگاری Noise، بدون اثر انگشت TLS |
| `kcp`، `quic` | روی UDP، برای مسیرهای پراتلاف |

- **ایمنی:** اگر پورتی اشغال باشد دوباره پرسیده می‌شود. هیچ سرویس یا تانل موجودی تغییر نمی‌کند.
- **مدیریت:**
  - وضعیت: `bash iran.sh status`
  - حذف: `bash iran.sh uninstall --name NAME`
  - به‌روزرسانی Binary: `bash iran.sh upgrade`
- **مخزن خصوصی:** پیش از اجرا `export GITHUB_TOKEN=...` را تنظیم کنید. یا فایل‌های Release را در یک پوشه روی سرور بگذارید و `bash iran.sh` را از همان‌جا اجرا کنید.
- **بدون پرسش:** `iran.sh --transport wssmux --tunnel-port 9090 --port 443 --yes`

## HoneyWeb Recommended

همان تنظیماتی که ترافیک Production HoneyWeb را حمل می‌کند، با ظرفیت صریح متناسب با اوج. هدف آن کیفیت اتصال است. جزئیات و شاهد هر مقدار: [honeyweb/RECOMMENDED.md](honeyweb/RECOMMENDED.md).

</div>
