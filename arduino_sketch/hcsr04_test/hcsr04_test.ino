/* ===========================================================================
 *  HC-SR04 TEST - ultrasonik mesafe sensorunu seri monitorden gor
 * ---------------------------------------------------------------------------
 *  Mesafeyi cm olarak surekli ekrana basar. Elini yaklastir/uzaklastir,
 *  deger degismeli.
 *
 *  Baglanti (ana koddaki ile ayni):
 *    VCC  -> 5V rayi   (ya da 3.3V uyumlu modul ise 3V3 rayi)
 *    GND  -> GND rayi  (ortak toprak!)
 *    TRIG -> GPIO 39
 *    ECHO -> GPIO 40   (5V besliyorsan 1k/2k gerilim bolucu ile!)
 *
 *  BEKLENEN:
 *    - Onunde acik alan: birkac on/yuz cm.
 *    - Elini ~10 cm'e yaklastirinca: ~10 yazmali.
 *    - "ZAMAN ASIMI" yaziyorsa: yanit gelmiyor (kablo/güc/bolucu sorunu).
 * =========================================================================== */

#define TRIG_PIN 39
#define ECHO_PIN 40

// Kac cm altinda "kullanici yakin" sayilacak (ana kodda PRESENCE_CM = 45)
#define PRESENCE_CM 45

long readDistanceCm() {
  digitalWrite(TRIG_PIN, LOW);  delayMicroseconds(3);
  digitalWrite(TRIG_PIN, HIGH); delayMicroseconds(10);
  digitalWrite(TRIG_PIN, LOW);
  // ECHO HIGH suresi (us). 30 ms timeout ~ 5 metre.
  long dur = pulseIn(ECHO_PIN, HIGH, 30000);
  if (dur == 0) return -1;        // yanit yok
  return dur / 58;                // us -> cm
}

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(TRIG_PIN, OUTPUT);
  pinMode(ECHO_PIN, INPUT);
  digitalWrite(TRIG_PIN, LOW);
  Serial.println("\n=== HC-SR04 TEST ===");
  Serial.println("Elini yaklastir/uzaklastir, mesafe degismeli.");
}

void loop() {
  long cm = readDistanceCm();
  if (cm < 0) {
    Serial.println("ZAMAN ASIMI - yanit yok (VCC/GND/TRIG/ECHO veya bolucu kontrol et)");
  } else {
    Serial.print("Mesafe = ");
    Serial.print(cm);
    Serial.print(" cm");
    if (cm <= PRESENCE_CM) Serial.print("   <-- KULLANICI YAKIN (present)");
    Serial.println();
  }
  delay(300);
}
