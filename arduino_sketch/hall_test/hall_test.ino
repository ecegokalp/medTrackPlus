/* ===========================================================================
 *  HALL SENSOR TEST - SS49E'yi seri monitorden gor
 * ---------------------------------------------------------------------------
 *  Tek bir SS49E sensorunu test eder. Ham ADC degerini ekrana basar.
 *
 *  Baglanti (yazili/duz yuz sana donuk, bacaklar asagi, soldan saga):
 *    SOL bacak  = VCC  -> 3V3 rayi
 *    ORTA bacak = GND  -> GND rayi
 *    SAG bacak  = OUT  -> GPIO 1
 *
 *  BEKLENEN:
 *    - Miknatis YOKKEN deger ~2048 civari (orta seviye).
 *    - Miknatisi yaklastirinca deger YUKARI (>2900) veya ASAGI (<1200) gider
 *      (miknatisin hangi kutbuna gore).
 *
 *  SORUN TESHISI:
 *    - Deger surekli ~4095 (en yuksek) ve miknatisa tepki vermiyorsa
 *        -> SOL ve SAG bacaklari (VCC <-> OUT) ters baglamissin, yer degistir.
 *    - Deger surekli ~0 ise -> VCC bagli degil / yanlis rayda.
 *    - Deger ~2048 ve miknatisa tepki veriyorsa -> DOGRU baglamissin!
 * =========================================================================== */

#define HALL_PIN 1

void setup() {
  Serial.begin(115200);
  delay(500);
  analogReadResolution(12);   // 0..4095
  pinMode(HALL_PIN, INPUT);
  Serial.println("\n=== HALL TEST (GPIO1) ===");
  Serial.println("Miknatis yokken ~2048 olmali. Miknatisi yaklastir, deger degismeli.");
}

void loop() {
  int v = analogRead(HALL_PIN);
  Serial.print("ADC = ");
  Serial.print(v);

  if (v > 2900)      Serial.println("   <-- MIKNATIS yakin (yukari)");
  else if (v < 1200) Serial.println("   <-- MIKNATIS yakin (asagi)");
  else if (v > 3900) Serial.println("   (cok yuksek - VCC/OUT ters olabilir!)");
  else               Serial.println("   (orta - miknatis uzak)");

  delay(200);
}
