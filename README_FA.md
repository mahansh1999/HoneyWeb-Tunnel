<div dir="rtl">

# HoneyWeb Tunnel

تانل معکوس سریع و پایدار بین سرور ورودی (ایران) و سرور خروجی (خارج)، نوشته‌شده با Go و نگهداری‌شده توسط HoneyWeb. [English](README.md)

> Based on BackPack by Amin Mohammadi (AminMGMT)
> https://github.com/AminMGMT/BackPack
>
> HoneyWeb Tunnel نسخه تغییریافته BackPack است و تحت مجوز AGPL-3.0 منتشر می‌شود. جزئیات در `LICENSE`، `NOTICE` و `TRADEMARK.md` است. بخش انتقال داده BackPack از Backhaul ساخته Musixal گرفته شده است (AGPL-3.0).

## نصب

روی سرور ایران (با root):

```bash
curl -fsSLO https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/install.sh
bash install.sh server --transport wssmux --tunnel-port 9090 --port 540
```

نصب سرور، فرمان دقیق نصب سمت خارج را همراه Token چاپ می‌کند. روی سرور خارج (با root):

```bash
curl -fsSLO https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/install.sh
bash install.sh client --transport wssmux --server ENTRY_IP:9090 --token TOKEN
```

- **مخزن خصوصی:** پیش از اجرا `GITHUB_TOKEN` را تنظیم کنید. یا فایل‌های Release را روی سرور بیاورید و `--binary ./hwtunnel-linux-amd64` بدهید. Installer آن را با `SHA256SUMS` کنارش بررسی می‌کند.
- **ایمنی:** اگر پورتی اشغال باشد یا تانل هم‌نام وجود داشته باشد، Installer پیش از نوشتن هر فایلی متوقف می‌شود.
- **`upgrade`:** فقط Binary را عوض می‌کند و Configها هرگز بازنویسی نمی‌شوند.
- **`rollback`:** به Binary قبلی برمی‌گردد.

## HoneyWeb Recommended

همان تنظیماتی که ترافیک Production HoneyWeb را حمل می‌کند، با ظرفیت صریح متناسب با اوج. هدف آن کیفیت اتصال است. جزئیات و شاهد هر مقدار: [honeyweb/RECOMMENDED.md](honeyweb/RECOMMENDED.md).

</div>
