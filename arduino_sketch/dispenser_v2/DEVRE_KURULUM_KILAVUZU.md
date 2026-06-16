# MedTrack Plus — Devre Kurulum Kılavuzu (Sıfırdan, Bebek Adımlarıyla)

Bu kılavuz, hiç elektronik bilmeyen biri için yazıldı. Her adımı **sırayla** yap,
ve her parçayı ekledikten sonra **test et**. Acele etme — bir seferde her şeyi
bağlayıp sonra "çalışmıyor" demek yerine, tek tek ekleyip her birini doğrularsak
hata bulmak çok kolay olur.

---

## 0. ÖNCE GÜVENLİK (oku, atla geçme)

- **18650 bataryalara dikkat.** + ve − uçlarını **asla birbirine değdirme** (kısa
  devre). Kısa devre olursa batarya ısınır, şişer, hatta yanar.
- **Ters bağlama yok.** Kırmızı = artı (+), siyah = eksi (−). VCC'ye eksi, GND'ye artı
  verirsen cihaz yanar.
- **Bağlantı yaparken gücü kes.** Kablo takıp çıkarırken USB bağlı olmasın.
- Lehim yaparken havalandır, sıcak ucu cilde değdirme.

---

## 1. KAVRAMLAR — Breadboard ve Güç Rayları

### Breadboard nasıl çalışır?
Breadboard'da delikler gizli metal şeritlerle bağlıdır:

- **Kenardaki uzun çizgili sıralar (kırmızı + ve mavi −):** "Güç rayları". Bir ray
  boyunca **tüm delikler birbirine bağlı**. Gücü buraya veririz.
- **Ortadaki dikey 5'li gruplar:** Her grup kendi içinde bağlı. ESP32'nin bir
  bacağını bir gruba takarsan, oradaki diğer delikler o bacağa bağlanır.
- **Ortadaki vadi:** Sol/sağ yarıyı ayırır. ESP32 vadinin üstüne oturur.

### Bizim güç rayı planımız (ÇOK ÖNEMLİ)
Bu projede **ayrı bir 5V rayına gerek YOK** çünkü motorlar ESP32'den beslenecek.
Sadece şu rayları kullanacağız:

| Ray | Ne taşıyacak | Etiketle |
|-----|--------------|----------|
| Bir KIRMIZI ray | **3.3V** (ESP32'nin 3V3 pininden) | "3V3" yaz |
| TÜM MAVİ raylar | **GND (ortak eksi)** | hepsi birbirine bağlı |

> 5V gereken tek iki şey var: **HC-SR04** (ESP32'nin 5V pininden) ve
> **DFPlayer/hoparlör** (ikinci USB'den). Onlara aşağıda ayrıca değineceğiz.

> **Altın kural:** Tüm GND (mavi) rayları birbirine + ESP32 GND'sine + powerbank
> eksisine bağlı olmalı. "Ortak toprak" olmadan hiçbir şey çalışmaz. En sık hata budur.

---

## 2. GÜÇ MİMARİSİ — Neyi nereden besleyeceğiz?

Powerbank'inde **sadece 2 USB çıkışı** var. Şöyle kullanacağız:

```
[Powerbank USB #1] --(USB-A→USB-C kablo)--> [ESP32-S3 USB-C]
        ESP32'yi sürekli besler. ESP32 içeride 3.3V üretir,
        ayrıca USB'den gelen 5V'u "5V pini"nde dışarı verir.

[Powerbank USB #2] --(kesik USB kablo: kırmızı=5V, siyah=GND)-->
        [DFPlayer VCC + GND]   (hoparlör DFPlayer'a bağlı)
```

Hangi parça nereden beslenir:

| Parça | VCC nereden? | Neden |
|-------|--------------|-------|
| ESP32-S3 | USB #1 (USB-C) | Sürekli açık |
| 4× ULN2003 motor "+" | **ESP32 3V3 pini** | Motorlar sıralı çalışır (tek motor), 3.3V regülatöre yeter |
| 4× SS49E Hall (VCC) | **ESP32 3V3 pini** | 5V verirsen çıkışı 3.3V'u aşıp ADC'yi yakar |
| RGB/durum LED | **ESP32 3V3 pini** (dirençle) | Düşük akım |
| Buton | pin + dahili pull-up | Güç gerekmez |
| HC-SR04 (VCC) | **ESP32 5V pini** | 5V ister; ESP'nin 5V pini USB 5V'unu taşır |
| DFPlayer Mini (VCC) | **USB #2 (5V)** | Ses çalarken akım çeker, ayrı beslemek daha temiz |
| Hoparlör | DFPlayer'ın SPK çıkışına | DFPlayer sürer |

> **Motor voltajı notu:** 28BYJ-48 motorlar normalde 5V'tur. ESP32'nin 3.3V'unda
> tork ~%40 azalır. Ama (a) aynı anda tek motor döndüğü için akım sorun değil,
> (b) çarktaki dişli redüksiyonu torku çoğalttığı için hafif çark için **genelde
> yeterlidir**. Eğer motor zayıf kalır/zorlanırsa: motorların "+" ucunu ESP32'nin
> **5V pinine** al (yine ESP'den, ayrı ray gerekmez). Önce 3V3 ile dene; yetmezse 5V'a geç.

> **Geliştirme sırasında (kod yüklerken):** ESP32'yi PC'den USB-C ile besle.
> DFPlayer'ı powerbank USB #2'den besle. GND'leri ortak yap (DFPlayer GND →
> breadboard GND → ESP GND). Bu kadar.

---

## 3. MALZEME KONTROL LİSTESİ

- [ ] ESP32-S3 kartı (breadboard'da ortada)
- [ ] 2 breadboard (yan yana)
- [ ] Powerbank kartı + 18650 paketi (şarjlı)
- [ ] 1× USB-A → USB-C kablo (ESP32 beslemesi)
- [ ] 1× eski USB kablosu (kesip DFPlayer'a 5V vermek için)
- [ ] 4× 28BYJ-48 motor + 4× ULN2003 sürücü
- [ ] 4× SS49E Hall sensör + 4× N52 mıknatıs
- [ ] HC-SR04 ultrasonik sensör
- [ ] 1 buton (4 bacaklı tactile)
- [ ] 3 bacaklı çift renk LED (Kırmızı+Yeşil ortak katot)
- [ ] DFPlayer Mini + hoparlör + microSD
- [ ] Jumper kablolar (erkek-erkek), bol
- [ ] Dirençler: 2× 220Ω (LED), 1× 1kΩ + 1× 2kΩ (HC-SR04 ECHO), 1× 1kΩ (DFPlayer RX)

---

## 4. PIN HARİTASI (kodla birebir aynı)

ESP32'nin üstünde her bacağın yanında **GPIO numarası** yazar. Numaraya göre bağla.

| İşlev | ESP32 GPIO |
|-------|-----------|
| Hall sensör 1 / 2 / 3 / 4 (OUT) | 1 / 2 / 3 / 4 |
| Motor 1 (ULN2003 IN1,IN2,IN3,IN4) | 5, 6, 7, 15 |
| Motor 2 (IN1,IN2,IN3,IN4) | 16, 17, 18, 8 |
| Motor 3 (IN1,IN2,IN3,IN4) | 9, 10, 11, 12 |
| Motor 4 (IN1,IN2,IN3,IN4) | 13, 14, 21, 38 |
| HC-SR04 TRIG | 39 |
| HC-SR04 ECHO (bölücü ile) | 40 |
| Buton | 41 |
| LED Kırmızı / Yeşil / Mavi | 42 / 47 / 46 |
| DFPlayer: ESP TX→DF RX / DF TX→ESP RX | 48 / 45 |

> **ESP32-S3-N16R8 notu:** Bu modülde **GPIO 26–32 dahili flash**, **GPIO 33–37
> oktal PSRAM** için ayrılmıştır — bunları KULLANMA. Yukarıdaki pinlerin hepsi
> N16R8'de serbesttir. (GPIO43/44 = TX/RX bazı kompakt kartlarda header'a
> çıkmaz; o yüzden maviyi GPIO46'ya aldık.) GPIO46 strapping pinidir ama LED
> çıkışı olarak güvenle kullanılır. Kartında 46 da yoksa: 38 hariç kullanılmayan
> başka bir pin seç (örn. 0'ı tercih etme — boot strap) ve `#define LED_BLUE`'yu değiştir.

---

## 5. ADIM ADIM KURULUM

Her adımdan sonra **gücü ver, test et, sonra gücü kesip bir sonrakine geç.**

### ADIM 1 — Rayları hazırla
1. ESP32'nin **GND** pinine jumper tak → **mavi (−) raya**. Bu ray = ortak GND.
2. İki breadboard'un tüm mavi raylarını jumper'la birbirine bağla (tek GND olsun).
3. ESP32'nin **3V3** pinine jumper tak → **3V3 diye etiketlediğin kırmızı raya**.
   Bu ray = 3.3V (motorlar, Hall, LED buradan beslenecek).

### ADIM 2 — ESP32'yi besle, hayatta mı bak
1. ESP32'yi USB-C ile PC'ne veya powerbank USB #1'e bağla.
2. Kart üstündeki güç LED'i yanmalı.

### ADIM 3 — Durum LED'i (4 bacaklı RGB, en kolay parça, ilk bunu test et)
4 bacaklı RGB LED: **R, G, B ve ortak** bacak. Ortak bacak genelde en uzun olandır.
İki tip vardır:
- **Ortak katot:** ortak bacak GND'ye gider. (En yaygın — kodda `COMMON_ANODE 0`.)
- **Ortak anot:** ortak bacak 3V3'e gider. (Bu tipteysen kodda `COMMON_ANODE 1` yap.)

1. LED'i breadboard'a tak (4 bacak 4 ayrı gruba).
2. R bacak grubuna **220Ω**, ucundan jumper → **GPIO 42**.
3. G bacak grubuna **220Ω**, ucundan jumper → **GPIO 47**.
4. B bacak grubuna **220Ω**, ucundan jumper → **GPIO 46**.
5. Ortak bacak → **GND rayı** (ortak katotsa) **veya 3V3 rayı** (ortak anotsa).
6. Kod yüklendikten sonra: açılış/eşleşmede LED **mavi** yanıp söner, online olunca
   **yeşil** yanar. Yanmazsa: ortak bacağı doğru raya bağladığından emin ol; renkler
   karışıksa R/G/B bacaklarının pinlerini eşleştir; hiç yanmıyorsa LED tipini
   (katot/anot) kontrol edip `COMMON_ANODE` değerini değiştir.

> Her renk bacağına ayrı 220Ω direnç koy. Direnç olmadan LED'i pine bağlama.

### ADIM 4 — Buton
1. Butonu vadiye yerleştir (2 bacak solda, 2 sağda).
2. Bir bacak → **GPIO 41**.
3. Çapraz köşedeki bacak → **GND rayı**.
4. Kod dahili pull-up kullanır; ek direnç yok.
5. Test: butona basınca log'da "user_confirm" / ses çıkar. Olmazsa diğer çifti dene.

### ADIM 5 — Hall sensörler (4 adet)
SS49E: 3 bacak (VCC, GND, OUT — üstündeki yazıyı kontrol et).
1. Her sensör **VCC → 3V3 rayı** (5V'a DEĞİL!).
2. **GND → GND rayı**.
3. **OUT →** sensör1→GPIO1, sensör2→GPIO2, sensör3→GPIO3, sensör4→GPIO4.
4. Test: Önce tek sensörle. Mıknatısı yaklaştır; ADC değeri değişmeli
   (yokken ~2048, yaklaşınca yükselir/düşer).

### ADIM 6 — HC-SR04 (5V + gerilim bölücüsü)
1. **VCC → ESP32'nin 5V pini** (HC-SR04 5V ister; bu pin USB 5V'unu verir).
   - Kartında "5V" veya "VBUS" yazan pini bul, oradan jumper'la HC-SR04 VCC'ye git.
2. **GND → GND rayı**.
3. **TRIG → GPIO 39** (doğrudan).
4. **ECHO → GPIO 40 AMA DOĞRUDAN DEĞİL.** ECHO 5V verir, GPIO 3.3V'luk — bölücü yap:
   ```
   ECHO ──[1kΩ]──┬──[2kΩ]── GND
                 │
              GPIO40
   ```
   - ECHO'dan 1kΩ → bir gruba (X). X'ten 2kΩ → GND. X'ten jumper → GPIO40.
5. Test: eline yaklaştır; presence tetiklenmeli.

> **Alternatif:** Elinde 3.3V uyumlu "HC-SR04+" varsa VCC'yi 3V3'e bağla,
> ECHO'yu doğrudan GPIO40'a ver, bölücü gerekmez.

### ADIM 7 — Bir step motor + ULN2003 (önce tek motorla)
1. Motorun beyaz fişini ULN2003 soketine tak.
2. ULN2003 **"−" (GND) → GND rayı**.
3. ULN2003 **"+" (VCC) → 3V3 rayı.** (Motor gücü ESP'nin 3.3V'undan.)
4. IN1-4 → Motor 1 için: IN1→GPIO5, IN2→GPIO6, IN3→GPIO7, IN4→GPIO15.
5. Test: dispense komutu tetikle (uygulamadan veya Developer Mock Alarm'dan).
   Motor bir bölme (15°) dönmeli.
   - Dönüyor ama zayıf/zorlanıyorsa: ULN2003 "+" ucunu **3V3 yerine ESP'nin 5V
     pinine** al. Tork artar.
   - Hiç dönmüyorsa: IN bağlantıları ve ortak GND'yi kontrol et.

> ULN2003 üstündeki 4 LED, hangi bobinin aktif olduğunu gösterir — dönerken
> sırayla yanıp sönerler. Bağlantı doğru mu görmek için iyi ipucu.

### ADIM 8 — Diğer 3 motoru ekle
- Motor 2 IN1-4 → GPIO 16, 17, 18, 8
- Motor 3 IN1-4 → GPIO 9, 10, 11, 12
- Motor 4 IN1-4 → GPIO 13, 14, 21, 38
- Hepsinin "+" → 3V3 rayı (veya tork için 5V pini), "−" → GND rayı.

> Kod motorları **sıralı** sürer — aynı anda hep tek motor döner. O yüzden 4'ünü de
> ESP'den beslemek sorun olmaz. (Eğer ileride aynı anda birden fazla motoru
> döndürmek istersen o zaman 5V/ayrı kaynak gerekir; mevcut tasarımda gerekmez.)

### ADIM 9 — DFPlayer Mini + hoparlör
1. microSD'ye MP3'leri koy: **0001.mp3** (ilaç zamanı), **0002.mp3** (stok az),
   **0003.mp3** (alındı), **0004.mp3** (uyarı). Kartı DFPlayer'a tak.
2. DFPlayer **VCC → USB #2'nin 5V'u** (kesik kablonun kırmızısı).
3. DFPlayer **GND → GND rayı** (USB #2'nin siyahı da bu raya; ortak GND şart).
4. **ESP32 GPIO 48 → 1kΩ → DFPlayer RX.**
5. **DFPlayer TX → ESP32 GPIO 45.**
6. Hoparlörün iki ucu → DFPlayer **SPK_1** ve **SPK_2** (doğrudan bataryaya bağlama).
7. Test: dispense yap; "alındı" sesi çıkmalı.

---

## 6. KODU YÜKLEMEK

1. Arduino IDE → Boards Manager → "esp32 by Espressif" kur.
2. **Tools → Board → ESP32S3 Dev Module**.
3. Tools ayarları (ESP32-S3-N16R8 için):
   - USB CDC On Boot: **Enabled**
   - Flash Size: **16MB (128Mb)**
   - PSRAM: **OPI PSRAM**   (N16R8 oktal PSRAM kullanır — bu şart, yanlışsa kart resetlenir)
   - Flash Mode: **QIO 80MHz**
   - **Partition Scheme: "Huge APP (3MB No OTA/1MB SPIFFS)"** veya
     **"16M Flash (3MB APP/9.9MB FATFS)"**  ← ÖNEMLİ! Varsayılan şema (1.25MB)
     WiFi+BLE+Firebase ile YETMEZ, "Sketch too big" hatası verir. Mutlaka 3MB app seç.
   - Port: ESP32'nin bağlı olduğu COM portu
4. Library Manager'dan kur:
   - "Firebase Arduino Client Library for ESP8266 and ESP32" (Mobizt)
   - "AccelStepper" (Mike McCauley)
   - "DFRobotDFPlayerMini" (DFRobot)
5. `dispenser_v2.ino`'da `FIREBASE_API_KEY` ve `FIREBASE_DATABASE_URL`'yi doldur.
6. **Upload**. İlk açılışta WiFi yoksa BLE provisioning'e girer (LED kırmızı yanıp
   söner); mobil uygulamadan WiFi bilgisini gönder.

---

## 7. KALİBRASYON

### A) `STEPS_PER_SLOT` (tek bölme = kaç motor adımı)
- Şu an `1850` (tahmini). Bir çarkı tek dispense ile döndür, **tam 15°** dönüyor mu bak.
  Fazlaysa azalt, azsa artır. (Tam tur = 24 bölme; tur adımı / 24 = bir bölme.)

### B) Hall eşikleri `HALL_HIGH_THRESHOLD` / `HALL_LOW_THRESHOLD`
- Seri monitör (115200) aç. Mıknatıs uzaktayken ~2048; yaklaşınca >2900 veya <1200
  olmalı. Sapma azsa mıknatısı yaklaştır ya da eşikleri ölçtüğün değere göre güncelle.

---

## 8. SORUN GİDERME

| Belirti | Olası neden | Çözüm |
|---------|-------------|-------|
| Hiçbir şey çalışmıyor | Ortak GND yok | Tüm GND'leri + ESP GND + powerbank − birbirine bağla |
| Motor dönmüyor | 3V3 rayı / IN bağlantısı yok | ULN2003 "+" 3V3'te mi, IN'ler doğru GPIO'da mı? |
| Motor zayıf/zorlanıyor | 3.3V tork düşük | Motor "+" ucunu ESP'nin 5V pinine al |
| ESP resetleniyor (motor dönerken) | Tek motor bile çok çekiyor | Motor "+" → 5V pini; gerekirse motor hızını düşür |
| Pin yandı / garip davranış | HC-SR04 ECHO'yu doğrudan bağladın | Mutlaka gerilim bölücü kullan |
| Hall değeri değişmiyor | VCC 5V'a bağlı / sensör ters | VCC'yi 3V3'e al, bacak sırasını kontrol et |
| LED yanmıyor | Ters / direnç yok | Çevir, 220Ω ekle |
| Ses yok | SD/dosya adı, TX/RX ters | 0001.mp3 vb.; GPIO48→RX(1k), GPIO45←TX, ortak GND |
| WiFi bağlanmıyor | 2.4GHz değil / şifre | ESP sadece 2.4GHz; BLE'den tekrar gönder; 3sn buton = fabrika ayarı |

---

## 9. ÖZET BAĞLANTI LİSTESİ (hızlı referans)

```
GÜÇ:
  Powerbank USB #1 → USB-C → ESP32 (besleme)
  Powerbank USB #2 → kesik kablo: kırmızı → DFPlayer VCC, siyah → GND rayı
  ESP32 3V3 pini → 3V3 rayı   (motorlar, Hall, LED)
  ESP32 GND pini → GND rayı   (tüm GND'ler ortak!)
  ESP32 5V pini  → HC-SR04 VCC (ve tork için motorlara opsiyonel)

LED (4 bacak RGB):
  R → 220Ω → GPIO42 ; G → 220Ω → GPIO47 ; B → 220Ω → GPIO46
  ortak → GND (ortak katot)  veya  3V3 (ortak anot, kodda COMMON_ANODE 1)

BUTON:
  bir bacak → GPIO41 ; çapraz bacak → GND

HALL x4:
  VCC → 3V3 rayı ; GND → GND rayı ; OUT → GPIO 1 / 2 / 3 / 4

HC-SR04:
  VCC → ESP 5V pini ; GND → GND rayı
  TRIG → GPIO39
  ECHO → [1kΩ] → düğüm → GPIO40 ; düğüm → [2kΩ] → GND

MOTOR 1 (ULN2003):  +→3V3, −→GND, IN1234 → 5,6,7,15
MOTOR 2:            +→3V3, −→GND, IN1234 → 16,17,18,8
MOTOR 3:            +→3V3, −→GND, IN1234 → 9,10,11,12
MOTOR 4:            +→3V3, −→GND, IN1234 → 13,14,21,38
  (tork yetmezse hepsinin "+" ucunu ESP'nin 5V pinine al)

DFPLAYER:
  VCC → USB #2 5V ; GND → GND rayı
  GPIO48 → 1kΩ → DF RX ; DF TX → GPIO45
  Hoparlör → SPK_1, SPK_2
```

İyi çalışmalar! Takıldığın adımı söyle, o parçayı tek tek çözeriz.
