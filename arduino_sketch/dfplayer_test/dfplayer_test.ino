/* ===========================================================================
 *  DFPlayer Mini TANI TESTI
 * ---------------------------------------------------------------------------
 *  DFPlayer'in kablo/guc/seri haberlesmesi dogru mu kontrol eder.
 *  (Calma icin MP3 gerekir; MP4 calmaz. Bu test once modul YANIT veriyor mu
 *   ona bakar, sonra calmayi dener.)
 *
 *  Baglanti (ana koddaki ile ayni):
 *    DFPlayer VCC  -> 5V rayi
 *    DFPlayer GND  -> GND rayi (ortak toprak!)
 *    ESP GPIO48 (TX) -> 1k direnc -> DFPlayer RX
 *    DFPlayer TX     -> ESP GPIO45 (RX)
 *    Hoparlor -> DFPlayer SPK_1 / SPK_2
 * =========================================================================== */

#include <DFRobotDFPlayerMini.h>

#define DF_TX 17   // ESP -> DFPlayer RX  (eski: 48)
#define DF_RX 18   // DFPlayer TX -> ESP  (eski: 45)

HardwareSerial dfSerial(1);
DFRobotDFPlayerMini df;

void setup() {
  Serial.begin(115200);
  delay(800);
  Serial.println("\n=== DFPlayer TANI TESTI ===");

  // UART1: (baud, format, RXpin, TXpin)
  dfSerial.begin(9600, SERIAL_8N1, DF_RX, DF_TX);
  delay(200);

  Serial.println("DFPlayer baslatiliyor...");
  if (!df.begin(dfSerial)) {
    Serial.println(">>> YANIT YOK! Sunlari kontrol et:");
    Serial.println("    1) VCC gercekten 5V mi? (powerbank acik, keep-alive direnci var mi)");
    Serial.println("    2) GND ortak mi? (DFPlayer GND = ESP GND ayni ray)");
    Serial.println("    3) ESP GPIO48 -> 1k -> DF RX  ve  DF TX -> ESP GPIO45 (capraz!)");
    Serial.println("    4) Karti DFPlayer'a tam taktin mi?");
    return;  // burada kal
  }

  Serial.println(">>> DFPlayer YANIT VERDI - kablo/guc/seri DOGRU!");
  delay(300);

  int n = df.readFileCounts();
  Serial.print("Karttaki CALINABILIR (mp3/wav) dosya sayisi: ");
  Serial.println(n);
  if (n <= 0) {
    Serial.println("   -> 0 cikti: kartta CALINABILIR dosya yok.");
    Serial.println("      (MP4 dosyalar SAYILMAZ/CALINMAZ. 0001.mp3 gibi MP3 lazim.)");
  } else {
    Serial.println("   -> mp3 var, 1. parcayi calmayi deniyorum...");
    df.volume(25);
    df.play(1);
  }
}

void loop() {
  // DFPlayer olaylarini (bitti/hata) yazdir
  if (df.available()) {
    uint8_t type = df.readType();
    int val = df.read();
    if (type == DFPlayerPlayFinished) { Serial.print("Parca bitti: #"); Serial.println(val); }
    else if (type == DFPlayerError)   { Serial.print("DFPlayer hata kodu: "); Serial.println(val); }
  }
  delay(50);
}
