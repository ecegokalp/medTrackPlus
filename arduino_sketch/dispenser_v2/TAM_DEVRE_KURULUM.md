# MedTrack Plus — Tam Devre Kurulum Kılavuzu (v2 / MAX98357A)

Bu kılavuz **bitmiş cihazın** tüm bileşenlerini (4 step motor, 4 hall sensör, ultrasonik mesafe, buton, RGB LED, I2S hoparlör) ESP32-S3-N16R8 üzerine adım adım nasıl kuracağını anlatır. Firmware: `dispenser_v2.ino`.

> Önemli: Pinler firmware ile **birebir aynı** olmalı. Pin değiştirirsen kodda da değiştir.

---

## 0. Genel kurallar (önce oku)

- **Tüm GND'ler ortak.** ESP32 GND, powerbank iki USB'sinin GND'si, motorların, sensörlerin, LED'in, hoparlör amfisinin GND'si — hepsi aynı hatta. Bu olmadan hiçbir şey düzgün çalışmaz.
- **Güç verirken GPIO0/strapping pinlerine dokunma.** Buton GPIO41'de; sorun yok.
- **Lehim yerine breadboard + jumper** kullan (daha güvenilir). Lehim şartsa parlak, dolgun lehim yap, soğurken kıpırdatma.
- Bağlamadan önce **5V rayı ↔ GND** kısa devre var mı multimetre (beep) ile kontrol et — ötmemeli.

---

## 1. Güç mimarisi

Powerbank'te **2 USB çıkışı** var:

| Kaynak | Nereye | Ne besler |
|--------|--------|-----------|
| Powerbank USB #1 | ESP32-S3 USB-C | ESP32'nin tamamı |
| Powerbank USB #2 | Kesilmiş USB kablosu → **5V rayı** | HC-SR04 VCC + MAX98357A VIN |
| ESP32 **3V3** pini | Breadboard 3V3 rayı | Hall(x4) VCC, ULN2003 "+" (motor) |
| ESP32 **GND** | Ortak GND rayı | Her şey |

- **5V rayı:** USB #2 kablosundaki kırmızı (+5V) ve siyah (GND). Multimetre ile doğrula (~5V).
- **3V3 rayı:** ESP'nin 3V3 pininden bir jumper ile breadboard rayına.
- **Ortak GND rayı:** ESP GND + 5V rayının GND'si birbirine köprülenir.

> Motorlar **sıralı** çalışır (aynı anda tek motor döner), o yüzden ESP 3V3 regülatörü tek motora yeter. Tork yetmezse tek bir motorun ULN2003 "+" ucunu ESP'nin **5V** pinine alabilirsin (yine ayrı ray gerekmez).

---

## 2. Pin haritası (firmware ile birebir)

| Bileşen | Pin(ler) |
|--------|----------|
| Hall 1 / 2 / 3 / 4 (OUT) | GPIO **1 / 2 / 3 / 4** |
| Motor 1 (IN1,IN2,IN3,IN4) | **5, 6, 7, 15** |
| Motor 2 (IN1,IN2,IN3,IN4) | **16, 17, 18, 8** |
| Motor 3 (IN1,IN2,IN3,IN4) | **9, 10, 11, 12** |
| Motor 4 (IN1,IN2,IN3,IN4) | **13, 14, 21, 38** |
| HC-SR04 TRIG / ECHO | **39 / 40** (ECHO bölücü ile) |
| Buton | **41** |
| Durum LED'i (tek renk, 2 bacak) | **42** (47/46 boşta) |
| MAX98357A BCLK / LRC / DIN | **46 / 47 / 48** |

Kullanılmayan: GPIO48 boşta. **GPIO 19/20 (USB), 26-32 (flash), 33-37 (PSRAM) KULLANILMAZ.**

---

## 3. Step motorlar (4 × 28BYJ-48 + ULN2003)

Her motor bir ULN2003 sürücü kartına takılır. ULN2003'ün ESP'ye giden 6 pini var: IN1, IN2, IN3, IN4, (+), (−).

Her ULN2003 için:
1. **Motor soketini** (beyaz 5'li) ULN2003'e tak.
2. ULN2003 **(+) → 3V3 rayı**, **(−) → GND rayı**.
3. IN1..IN4 → ESP'nin o motora ait 4 pini (yukarıdaki tablo).
   - Örn. **Motor 1:** IN1→GPIO5, IN2→GPIO6, IN3→GPIO7, IN4→GPIO15.

> Kodda `HALF4WIRE` ve `(IN1, IN3, IN2, IN4)` sırası kullanılır; sen sadece IN1→IN4'ü tabloya göre bağla, kod sırayı halleder.
> Motor ters yöne dönerse: o motorun **IN1↔IN3** (veya soketi) ters çevir.

---

## 4. Hall sensörler (4 × SS49E) + mıknatıs

SS49E'nin 3 bacağı (yazılı/düz yüz sana dönük, bacaklar aşağı, soldan sağa): **VCC, GND, OUT**.

Her sensör için:
1. **VCC (sol) → 3V3 rayı**
2. **GND (orta) → GND rayı**
3. **OUT (sağ) → ilgili Hall pini** (Hall1→GPIO1, Hall2→GPIO2, Hall3→GPIO3, Hall4→GPIO4)

Mıknatıs: her çarkın **home (1.) bölmesine** bir N52 mıknatıs göm. Çark dönerken mıknatıs sensörün önünden geçince ADC değeri sıçrar → firmware orayı "home / 1. bölme" kabul eder.

> Test: `hall_test.ino`. Mıknatıs yokken ~2048, yaklaşınca >2900 veya <1200 olmalı. Eşikler kodda `HALL_HIGH_THRESHOLD`/`HALL_LOW_THRESHOLD`.

---

## 5. HC-SR04 ultrasonik mesafe sensörü

4 pin: VCC, TRIG, ECHO, GND.
1. **VCC → 5V rayı** (5V ister, 3.3V'da güvenilmez)
2. **GND → GND rayı**
3. **TRIG → GPIO39** (doğrudan)
4. **ECHO → GERİLİM BÖLÜCÜ → GPIO40**

**ECHO bölücü (zorunlu):** ECHO 5V çıkar, ESP pini 3.3V toleranslı. Bölücü:
```
ECHO --[ R1 ]--+--> GPIO40
               |
             [ R2 ]
               |
              GND
```
- R1 ≈ 1kΩ, R2 ≈ 2kΩ ideal (≈3.3V verir). Elinde yoksa **R1=R2** (örn. iki adet 10k) bile ~2.5V verir, çalışır.

> Test: `hcsr04_test.ino`. Elini yaklaştır/uzaklaştır, cm değişmeli.

---

## 6. Buton (çok fonksiyonlu)

1. Butonun **bir bacağı → GPIO41**
2. **Çapraz köşedeki bacak → GND**

Dahili pull-up kullanılır, ek direnç yok. İşlevler:

- **1 basış** → LED aç/kapa (cihaz çalışıyor mu göstergesi)
- **2 basış** → stok bildir (log)
- **3 basış** → BLE kurulum moduna geç (WiFi'yi yeniden ayarlamak için)
- **basılı tut (≥3 sn)** → fabrika ayarlarına dön (reset)

> Test: `button_test.ino`.

---

## 7. Durum LED'i (tek renkli, 2 bacaklı)

Basit tek renkli LED kullanılır (RGB'den vazgeçildi). 2 bacak:
1. **Uzun bacak (anot) → 220Ω → GPIO42**
2. **Kısa bacak (katot) → GND**

(LED ters yanmıyorsa iki bacağı yer değiştir.)

**Davranış (firmware'de otomatik):**
- BLE / internete bağlanma beklenirken → **hızlı yanıp söner**
- İnternete bağlanınca → **3 kez uzun yanıp söner**, sonra söner
- Butona **1 basış → yakar**, tekrar **1 basış → söndürür**
- İlaç verilirken → sabit yanar; offline → yanıp söner

> Tek pin (GPIO42) kullanılır; eski RGB pinleri 47/46 boştadır.

---

## 8. Ses: MAX98357A I2S amfi + hoparlör

| MAX98357A | ESP32 / güç |
|-----------|-------------|
| VIN | **5V rayı** |
| GND | **GND rayı (ortak!)** |
| DIN | **GPIO48** |
| BCLK | **GPIO46** |
| LRC | **GPIO47** |
| GAIN | boş (varsayılan 9dB); daha yüksek için GND'ye |
| SD | **3V3'e** (çipi tam etkinleştir — önemli) |
| + / − | **hoparlör** (kutup farketmez) |

> Hoparlörü **5V'a değil**, MAX'in **+/−** çıkışına bağla.
> Cızırtı/kısık olursa: lehimleri yeniden ak, VIN'in gerçekten 5V olduğunu ve **ortak GND**'yi doğrula, GAIN'i GND'ye al.
> Test: `max98357_test.ino` (ESP8266Audio kütüphanesi gerekir).

---

## 9. Arduino IDE ayarları (yükleme öncesi)

Tools menüsü:
- **Board:** ESP32S3 Dev Module
- **Flash Size:** 16MB (128Mb)
- **PSRAM:** OPI PSRAM
- **Partition Scheme:** Huge APP (3MB No OTA/1MB SPIFFS)
- **USB CDC On Boot:** Enabled  ← (Seri Monitör USB'den; GPIO43/44 boşalır)
- **Upload Speed:** 921600

**Kütüphaneler** (Library Manager): Firebase Arduino Client (Mobizt), AccelStepper, **ESP8266Audio** (Earle Philhower).

> `alarm_tr_wav.h` dosyası `dispenser_v2.ino` ile aynı klasörde olmalı (gömülü ses). Mevcut.

---

## 10. Kurulum sırası (önerilen)

1. Güç raylarını kur (5V, 3V3, ortak GND). Multimetre ile doğrula, kısa devre yok.
2. ESP32'yi tak, boş sketch yükle (board ayarlarını doğrula).
3. Tek tek **test sketch**leriyle her bileşeni doğrula: LED → buton → hall(x4) → HC-SR04 → MAX98357A → her motor.
4. Hepsi geçince **`dispenser_v2.ino`** yükle.
5. İlk açılışta cihaz BLE ile WiFi ister (uygulamadan eşle) → Firebase'e bağlanır → çarkları **sırayla** home'a getirir.
6. Uygulamada **Developer → Device Hardware → Device Control Panel** ile her şeyi manuel test et (motor, sync, ses, sensör telemetrisi, loglar).

---

## 11. Kalibrasyon: `STEPS_PER_SLOT`

Firmware'de `STEPS_PER_SLOT = 1850` başlangıç değeridir. Doğru değeri bul:
1. Control Panel'den bir çarkı "+1 bölme" döndür.
2. Çark tam 1 bölme dönmüyorsa, `motor_step` ile elle deneyip kaç adımda tam 1 bölme döndüğünü ölç.
3. O değeri `STEPS_PER_SLOT`'a yaz, tekrar yükle.

---

## 12. Developer / Device Control Panel (uygulama)

Uygulamada **Developer Mode → Device Hardware → Device Control Panel**:
- **Canlı izleme:** Hall ADC (x4) + home rozetleri, ultrasonik mesafe + present, motor konumları, WiFi/RSSI/heap/uptime.
- **Manuel motor:** her çark için ±1 bölme, özel adım, Home, Dağıt.
- **Senkronizasyon:** Home All (sıralı), Refill Sync (çark), Refill Sync All (sıralı). *Mıknatıs algılanınca o bölme 1. bölme olur; çarklar **sırayla** (paralel değil) senkronlanır.*
- **Ses testi:** alarm sesini çal.
- **LED testi:** 6 durum.
- **Makine logları:** canlı, temizlenebilir.

> Bu ekran sadece geliştirici modunda görünür; canlı/üretim akışına dahil değildir. Önce burada her şeyi test et.
